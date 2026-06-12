#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Megapolos production-like локально (БЕЗ обходов TLS)
#
# Отличие от setup-devmode-false.sh: реальный домен + доверенный Root CA.
#   - домен megapolos.local через локальный DNS (/etc/hosts) → РЕАЛЬНЫЙ IP
#     контейнера (НЕ 127.0.0.1!). Это критично: Docker всегда считает
#     127.0.0.0/8 insecure и шлёт HTTP, игнорируя CA. Реальный IP → HTTPS.
#   - сертификаты подписаны Root CA, с корректным SAN (DNS:домен)
#   - Root CA установлен в системный trust И в Docker daemon trust (certs.d)
#   - НЕТ insecure-registries, НЕТ NODE_TLS_REJECT_UNAUTHORIZED
#   - core доверяет через NODE_EXTRA_CA_CERTS
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
GUI_REPO="${MEGAPOLOS_GUI_REPO:-https://gitlab.com/megapolos/megapolos-gui.git}"
REG_USER="megapolos"; REG_PASS="megapolos"
CA=/data/nginx/ssl/ca/ca.crt
REAL_IP=""; ROOT_TOKEN=""; NODE_ID=""

gql() { curl -s http://localhost:5100/graphql -X POST -H 'Content-Type: application/json' -H "token: $ROOT_TOKEN" \
  -d "{\"query\":$(echo "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"; }

# --- 1. DNS: домен → РЕАЛЬНЫЙ IP контейнера (не loopback!) ---
setup_dns() {
  REAL_IP=$(hostname -i | awk '{print $1}')
  info "DNS: $DOMAIN → $REAL_IP (реальный IP, не loopback)"
  grep -v "$DOMAIN" /etc/hosts > /tmp/hosts.new
  echo "$REAL_IP $DOMAIN registry.$DOMAIN gui.$DOMAIN" >> /tmp/hosts.new
  cat /tmp/hosts.new > /etc/hosts
}

# --- 2. dockerd (DinD) БЕЗ insecure-registries ---
setup_dockerd() {
  info "Установка dockerd (vfs, без insecure-registries)..."
  command -v docker &>/dev/null || curl -fsSL https://get.docker.com | sh >/dev/null
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
  apt-get install -y curl git python3-pip ca-certificates -qq >/dev/null 2>&1
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
  info "Репозитории + PostgreSQL..."
  [[ -d /root/megapolos-core/.git ]] || git clone --branch "$CORE_BRANCH" "$CORE_REPO" /root/megapolos-core
  [[ -d /root/megapolos-gui/.git ]]  || git clone "$GUI_REPO" /root/megapolos-gui
  service postgresql start
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='megapolos'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE USER megapolos WITH PASSWORD 'pgdata';\""
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='megapolos'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE DATABASE megapolos OWNER megapolos;\""
  cp /root/megapolos-core/install/newpostgresql.sql /tmp/schema.sql; chmod 644 /tmp/schema.sql
  su - postgres -c "psql -d megapolos -f /tmp/schema.sql" >/dev/null 2>&1 || true
  for g in "ALL TABLES" "ALL SEQUENCES"; do
    su - postgres -c "psql -d megapolos -c 'GRANT ALL PRIVILEGES ON $g IN SCHEMA public TO megapolos;'" >/dev/null 2>&1
  done
  su - postgres -c "psql -d megapolos -c 'GRANT ALL PRIVILEGES ON SCHEMA public TO megapolos;'" >/dev/null 2>&1
  success "Репо и БД готовы"
}

# --- 6. config (devMode=false, registry=домен) + старт core ---
start_core() {
  local extra_ca="$1"   # путь к CA или пусто (на первом старте CA ещё нет)
  local secret; secret=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)
  cat > /root/megapolos-core/config/config.json <<EOF
{
  "secret": "$secret",
  "connectionString": "postgres://megapolos:pgdata@localhost:5432/megapolos",
  "registryHost": "$DOMAIN",
  "registryUser": "$REG_USER",
  "registryPassword": "$REG_PASS",
  "debug": false, "devMode": false, "publicSchema": false,
  "allowUnauthorized": false, "noRoot": true, "catalogUrl": ""
}
EOF
  [[ -d /root/megapolos-core/node_modules ]] || (cd /root/megapolos-core && npm install --silent)
  pkill -f "ts-node index.ts" 2>/dev/null || true; sleep 2
  cd /root/megapolos-core
  if [[ -n "$extra_ca" ]]; then
    NODE_EXTRA_CA_CERTS="$extra_ca" nohup nodemon index.ts > /tmp/core.log 2>&1 &
  else
    nohup nodemon index.ts > /tmp/core.log 2>&1 &
  fi
  for i in $(seq 1 40); do grep -q "Server is running on port" /tmp/core.log 2>/dev/null && break; sleep 2; done
  grep -q "Server is running on port" /tmp/core.log || error "core не запустился"
  ROOT_TOKEN=$(tr -d '\0' < /tmp/core.log | grep -oP "token: '\K[^']+" | head -1)
}

# --- 7. registry-запись + нода + INIT/PREPARE/REGISTRY ---
setup_node() {
  gql "mutation { createDockerRegistry(values: { name: \"prod\", host: \"$DOMAIN\", user: \"$REG_USER\", password: \"$REG_PASS\", isDefault: true }) { id } }" >/dev/null
  NODE_ID=$(gql "mutation { createNode(values: { name: \"node\", host: \"$DOMAIN\", user: \"root\", password: \"root\" }) { id } }" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['data']['createNode']['id'])")
  for step in "initNode:INIT" "prepareNodeForCore:PREPARE FOR CORE" "installRegistryToNode:INSTALL REGISTRY"; do
    local mut="${step%%:*}"; local label="${step##*:}"
    info "$label (Ansible по SSH к $DOMAIN)..."
    gql "mutation { ${mut}(id: \"$NODE_ID\") }" >/dev/null; sleep 5
    for i in $(seq 1 60); do
      [[ "$(gql "{ getAllNode { lifeStatus } }" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['getAllNode'][0]['lifeStatus'])" 2>/dev/null)" == "running" ]] && break
      sleep 5
    done
    success "$label завершён"
    # Сразу после INIT — установить сгенерированный Root CA в trust-хранилища
    if [[ "$mut" == "initNode" ]]; then install_ca; fi
  done
}

# --- 8. Установка Root CA в системный + Docker daemon trust ---
install_ca() {
  [[ -f "$CA" ]] || error "Root CA не найден ($CA)"
  info "Установка Root CA в trust (система + docker certs.d)..."
  cp "$CA" /usr/local/share/ca-certificates/megapolos-ca.crt
  update-ca-certificates >/dev/null 2>&1
  mkdir -p "/etc/docker/certs.d/$DOMAIN:443"
  cp "$CA" "/etc/docker/certs.d/$DOMAIN:443/ca.crt"
  # перезапуск core с NODE_EXTRA_CA_CERTS (теперь CA есть)
  start_core "$CA"
  success "Root CA доверен; core перезапущен с NODE_EXTRA_CA_CERTS"
}

# =============================================================================
setup_dns
setup_dockerd
setup_ssh
install_deps
setup_repos_db
start_core ""          # первый старт — CA ещё не сгенерирован
setup_node             # INIT генерирует CA → install_ca → рестарт core с CA

# Проверка: secure login без обходов
docker login -u "$REG_USER" -p "$REG_PASS" "$DOMAIN:443" >/dev/null 2>&1 \
  && success "Registry $DOMAIN:443 — HTTPS + CA-валидация (БЕЗ insecure)" \
  || error "Registry login не прошёл"

echo ""
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Megapolos production-like готов (ZERO обходов TLS)${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo -e "  Домен:    https://$DOMAIN  (→ $REAL_IP, реальный IP)"
echo -e "  Registry: https://$DOMAIN:443  ($REG_USER/$REG_PASS)"
echo -e "  Root CA:  $CA (установлен в систему + docker trust)"
echo -e "  core:     devMode=false, NODE_EXTRA_CA_CERTS (валидация)"
echo -e "  Token:    $ROOT_TOKEN"
echo ""
echo -e "  Образы пушатся/пуллятся через $DOMAIN:443 с полной TLS-проверкой."
echo -e "${GREEN}=====================================================${NC}"
