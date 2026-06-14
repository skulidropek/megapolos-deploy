#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Megapolos production-like локально (БЕЗ обходов TLS)
#
# Отличие от setup-devmode-false.sh: реальный домен + доверенный Root CA.
#   - домен megapolos.local через локальный DNS (/etc/hosts + dnsmasq) →
#     РЕАЛЬНЫЙ IP контейнера (НЕ 127.0.0.1!). Это критично: Docker всегда
#     считает 127.0.0.0/8 insecure и шлёт HTTP, игнорируя CA. Реальный IP → HTTPS.
#   - сертификаты подписаны единым Megapolos Root CA (генерит ядро), SAN DNS:домен
#   - Root CA установлен в системный trust И в Docker daemon trust (certs.d)
#   - НЕТ insecure-registries, НЕТ NODE_TLS_REJECT_UNAUTHORIZED
#   - core доверяет через NODE_EXTRA_CA_CERTS
#
# Локально сертификаты self-signed → config.json идёт под devMode=true. Прод-путь
# (SSH ExternalProcess + push/pull в registry) сохраняется: он выбирается по
# наличию ноды в БД, а не по флагу devMode. Буквальный devMode=false/certbot —
# это путь боевого сервера с публичным доменом (см. ansible-вилку и *.prod.template).
#
# ВСЯ оркестрация (нода, INIT/PREPARE/REGISTRY, деплой) — в install.ts
# (npm run bootstrap). Никаких GraphQL/curl из bash.
#
# Запуск контейнера:
#   docker run -d --name mega --privileged --hostname mega-node \
#     ubuntu:22.04 sleep infinity
#   docker cp setup-production-like.sh mega:/setup.sh
#   docker exec mega bash /setup.sh
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

DOMAIN="${MEGAPOLOS_DOMAIN:-megapolos.local}"
CORE_REPO="${MEGAPOLOS_CORE_REPO:-https://github.com/skulidropek/megapolos-core.git}"
CORE_BRANCH="${MEGAPOLOS_CORE_BRANCH:-self-signed-certs}"
CORE_DIR="/root/megapolos-core"
GUI_REPO="${MEGAPOLOS_GUI_REPO:-https://gitlab.com/megapolos/megapolos-gui.git}"
GUI_DOMAIN="gui.$DOMAIN"
REG_USER="megapolos"; REG_PASS="megapolos"
# Единый Megapolos Root CA, который генерит ядро (НЕ per-node старый путь)
CA="$CORE_DIR/data/ca/ca.crt"
REAL_IP=""; ROOT_TOKEN=""

# --- 1. DNS: wildcard *.домен → РЕАЛЬНЫЙ IP контейнера (не loopback!) ---
setup_dns() {
  REAL_IP=$(hostname -i | awk '{print $1}')
  info "DNS: *.$DOMAIN → $REAL_IP (реальный IP, не loopback)"
  # /etc/hosts — базовые имена (для самого контейнера)
  grep -v "$DOMAIN" /etc/hosts > /tmp/hosts.new
  echo "$REAL_IP $DOMAIN registry.$DOMAIN" >> /tmp/hosts.new
  cat /tmp/hosts.new > /etc/hosts
  # dnsmasq — wildcard: любой <repo>.$DOMAIN резолвится автоматически,
  # чтобы не прописывать каждый домен приложения в /etc/hosts
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y dnsmasq -qq >/dev/null 2>&1
  # upstream для внешних доменов берём из текущего resolv.conf (не хардкодим),
  # на 127.0.0.1 не зацикливаемся
  local upstream; upstream=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')
  [[ -z "$upstream" || "$upstream" == "127.0.0.1" ]] && upstream=8.8.8.8
  # listen/bind на 127.0.0.1 + no-resolv (иначе dnsmasq зациклится на себя через
  # resolv.conf=127.0.0.1); wildcard *.$DOMAIN → реальный IP, внешние → upstream
  pkill dnsmasq 2>/dev/null || true; sleep 1
  dnsmasq --listen-address=127.0.0.1 --bind-interfaces --no-resolv \
    --server="$upstream" --address=/"$DOMAIN"/"$REAL_IP" 2>/dev/null || true
  # система должна спрашивать локальный dnsmasq (bind-mount: пишем в тот же inode)
  echo "nameserver 127.0.0.1" > /etc/resolv.conf
  getent hosts "gui.$DOMAIN" >/dev/null 2>&1 \
    && success "wildcard DNS: *.$DOMAIN → $REAL_IP (dnsmasq на :53)" \
    || error "wildcard DNS *.$DOMAIN не резолвится"
}

# --- 2. dockerd (DinD) БЕЗ insecure-registries ---
setup_dockerd() {
  info "Установка dockerd (vfs, без insecure-registries)..."
  # get.docker.com ставит бинари, но в конце пытается systemctl start (нет systemd
  # в контейнере) и выходит с ненулевым кодом — терпим, dockerd стартуем вручную
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
    command -v docker &>/dev/null || error "Docker не установился"
  fi
  mkdir -p /etc/docker
  echo '{ "storage-driver": "vfs" }' > /etc/docker/daemon.json
  pkill dockerd 2>/dev/null || true; sleep 2
  nohup dockerd > /var/log/dockerd.log 2>&1 &
  for i in $(seq 1 25); do docker info &>/dev/null && break; sleep 2; done
  docker info &>/dev/null || error "dockerd не запустился"
  docker swarm init --advertise-addr "$REAL_IP" 2>/dev/null || true
  success "dockerd готов (storage vfs, swarm active, без обходов)"
}

# --- 3. SSH ---
setup_ssh() {
  info "SSH сервер..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y openssh-server sshpass -qq >/dev/null 2>&1
  echo "root:root" | chpasswd
  sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  mkdir -p /run/sshd; pkill sshd 2>/dev/null || true; /usr/sbin/sshd; sleep 1
  sshpass -p root ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@"$DOMAIN" "echo ok" >/dev/null 2>&1 || error "SSH к $DOMAIN не работает"
  success "SSH к $DOMAIN работает"
}

# --- 4. Зависимости ---
install_deps() {
  info "Зависимости..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y curl git python3-pip openssl ca-certificates -qq >/dev/null 2>&1
  node --version 2>/dev/null | grep -q "^v18" || { curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1; apt-get install -y nodejs -qq >/dev/null 2>&1; }
  command -v psql &>/dev/null || apt-get install -y postgresql postgresql-contrib -qq >/dev/null 2>&1
  command -v nodemon &>/dev/null || npm install -g nodemon ts-node >/dev/null 2>&1
  pip3 install --upgrade pip -q 2>/dev/null
  pip3 install 'ansible>=9' -q 2>/dev/null
  # requests==2.31.0/urllib3<2 ОБЯЗАТЕЛЬНО — иначе docker SDK падает с "chunked"
  pip3 install docker jsondiff cryptography passlib 'requests==2.31.0' 'urllib3<2' -q 2>/dev/null
  ansible-galaxy collection install community.docker community.general community.crypto >/dev/null 2>&1
  success "Зависимости готовы"
}

# --- 5. Репо + БД ---
setup_repos_db() {
  info "Репозиторий ядра + PostgreSQL..."
  [[ -d "$CORE_DIR/.git" ]] || git clone --branch "$CORE_BRANCH" "$CORE_REPO" "$CORE_DIR"
  (cd "$CORE_DIR" && npm install --silent)
  service postgresql start
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='megapolos'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE USER megapolos WITH PASSWORD 'pgdata';\""
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='megapolos'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE DATABASE megapolos OWNER megapolos;\""
  cp "$CORE_DIR/install/newpostgresql.sql" /tmp/schema.sql; chmod 644 /tmp/schema.sql
  su - postgres -c "psql -d megapolos -f /tmp/schema.sql" >/dev/null 2>&1 || true
  for g in "ALL TABLES" "ALL SEQUENCES"; do
    su - postgres -c "psql -d megapolos -c 'GRANT ALL PRIVILEGES ON $g IN SCHEMA public TO megapolos;'" >/dev/null 2>&1
  done
  su - postgres -c "psql -d megapolos -c 'GRANT ALL PRIVILEGES ON SCHEMA public TO megapolos;'" >/dev/null 2>&1
  success "Репо и БД готовы"
}

# --- 6. config (devMode=true, local self-signed, registry=домен) ---
configure_core() {
  info "Запись config.json (devMode=true, registry=$DOMAIN)..."
  # config.json (с секретом) пишем ТОЛЬКО если его нет — иначе рестарт core
  # сгенерит новый секрет и инвалидирует root-токен
  [[ -f "$CORE_DIR/config/config.json" ]] && { success "config.json уже есть"; return; }
  local secret; secret=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)
  cat > "$CORE_DIR/config/config.json" <<EOF
{
  "secret": "$secret",
  "connectionString": "postgres://megapolos:pgdata@localhost:5432/megapolos",
  "registryHost": "$DOMAIN",
  "registryUser": "$REG_USER",
  "registryPassword": "$REG_PASS",
  "debug": false, "devMode": true, "publicSchema": false,
  "allowUnauthorized": false, "noRoot": true, "catalogUrl": ""
}
EOF
  success "config.json записан"
}

# --- 7. Пред-генерация единого Megapolos Root CA (без БД) ---
pregen_ca() {
  info "Генерация единого Megapolos Root CA (install.ts, режим CA-only)..."
  (cd "$CORE_DIR" && MEGAPOLOS_BOOTSTRAP_CA_ONLY=1 npm run bootstrap) \
    || error "не удалось сгенерировать CA"
  [[ -f "$CA" ]] || error "Root CA не найден после генерации ($CA)"
  success "Root CA готов: $CA"
}

# --- 8. Установка Root CA в системный + Docker daemon trust ---
install_ca() {
  info "Установка Root CA в trust (система + docker certs.d)..."
  cp "$CA" /usr/local/share/ca-certificates/megapolos-ca.crt
  update-ca-certificates >/dev/null 2>&1
  mkdir -p "/etc/docker/certs.d/$DOMAIN:443"
  cp "$CA" "/etc/docker/certs.d/$DOMAIN:443/ca.crt"
  success "Root CA установлен в системный trust и в /etc/docker/certs.d/$DOMAIN:443"
}

# --- 9. Оркестрация Megapolos (install.ts) с доверием по CA (без обходов) ---
bootstrap() {
  info "Оркестрация через install.ts (нода, INIT/PREPARE/REGISTRY, деплой)..."
  (cd "$CORE_DIR" && \
    NODE_EXTRA_CA_CERTS="$CA" \
    MEGAPOLOS_NODE_HOST="$DOMAIN" \
    MEGAPOLOS_REGISTRY_HOST="$DOMAIN" \
    MEGAPOLOS_BOOTSTRAP_APP_REPO="$GUI_REPO" \
    MEGAPOLOS_BOOTSTRAP_APP_NAME="megapolos-gui" \
    MEGAPOLOS_BOOTSTRAP_APP_PORT="80" \
    MEGAPOLOS_BOOTSTRAP_APP_DOMAIN="$GUI_DOMAIN" \
    MEGAPOLOS_BOOTSTRAP_APP_OUTER_PORT="3000" \
    npm run bootstrap) || error "install.ts завершился с ошибкой"
  success "Оркестрация Megapolos завершена"
}

# --- 10. Запуск ядра с NODE_EXTRA_CA_CERTS (валидация, без обходов) ---
start_core() {
  info "Запуск megapolos-core (NODE_EXTRA_CA_CERTS)..."
  pkill -f "nodemon index.ts" 2>/dev/null || true
  pkill -f "ts-node index.ts" 2>/dev/null || true
  for i in $(seq 1 15); do
    (exec 3<>/dev/tcp/127.0.0.1/5100) 2>/dev/null || break   # порт свободен
    exec 3>&- 3<&-; sleep 1
  done
  cd "$CORE_DIR"
  NODE_EXTRA_CA_CERTS="$CA" nohup nodemon index.ts > /tmp/core.log 2>&1 &
  for i in $(seq 1 40); do grep -q "Server is running on port" /tmp/core.log 2>/dev/null && break; sleep 2; done
  grep -q "Server is running on port" /tmp/core.log || error "core не запустился"
  ROOT_TOKEN=$(tr -d '\0' < /tmp/core.log | grep -oP "token: '\K[^']+" | head -1)
  success "core запущен"
}

# =============================================================================
setup_dns
setup_dockerd
setup_ssh
install_deps
setup_repos_db
configure_core
pregen_ca       # генерим единый CA ядром
install_ca      # ставим CA в trust ДО оркестрации (docker push/pull валидны)
bootstrap       # install.ts: нода + INIT/PREPARE/REGISTRY + деплой
start_core

# Проверка: secure login без обходов
docker login -u "$REG_USER" -p "$REG_PASS" "$DOMAIN:443" >/dev/null 2>&1 \
  && success "Registry $DOMAIN:443 — HTTPS + CA-валидация (БЕЗ insecure)" \
  || error "Registry login не прошёл"

echo ""
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Megapolos production-like готов (ZERO обходов TLS)${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo -e "  Домен:    https://$DOMAIN  (→ $REAL_IP, реальный IP)"
echo -e "  GUI:      https://$GUI_DOMAIN"
echo -e "  Registry: https://$DOMAIN:443  ($REG_USER/$REG_PASS)"
echo -e "  Root CA:  $CA (в системе + docker trust; GET /api/ca/download)"
echo -e "  core:     devMode=true (local self-signed), NODE_EXTRA_CA_CERTS"
echo -e "  Token:    $ROOT_TOKEN"
echo ""
echo -e "  Образы пушатся/пуллятся через $DOMAIN:443 с полной TLS-проверкой."
echo -e "  Оркестрация выполнена install.ts (без GraphQL/curl из bash)."
echo -e "${GREEN}=====================================================${NC}"
