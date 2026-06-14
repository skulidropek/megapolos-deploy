#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Megapolos локально — быстрый self-signed (TLS-bypass)
#
# Поднимает Megapolos локально внутри ОДНОГО контейнера:
#   - SSH (Ansible ходит на ноду по SSH)
#   - собственный dockerd (docker-in-docker) с insecure-registry 127.0.0.1:443
#   - приватный Docker Registry (push/pull образов), Docker Swarm деплой
#
# Сертификаты — локальные self-signed (единый Megapolos Root CA), поэтому
# config.json идёт под devMode=true. Прод-путь (SSH ExternalProcess + push/pull
# в registry) сохраняется: он выбирается по наличию ноды в БД, а не по флагу.
# TLS не валидируется (insecure-registry + NODE_TLS_REJECT_UNAUTHORIZED=0) —
# это и отличает скрипт от setup-production-like.sh (там реальный домен + CA-trust).
#
# ВСЯ оркестрация (нода, INIT/PREPARE/REGISTRY, деплой приложения) выполняется
# самим Megapolos в install.ts (npm run bootstrap). Никаких GraphQL/curl из bash.
#
# ВАЖНО: контейнер должен быть запущен как:
#   docker run -d --name mega --privileged --hostname mega-node \
#     ubuntu:22.04 sleep infinity
# (--privileged обязателен для вложенного dockerd)
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

CORE_REPO="${MEGAPOLOS_CORE_REPO:-https://github.com/skulidropek/megapolos-core.git}"
CORE_BRANCH="${MEGAPOLOS_CORE_BRANCH:-self-signed-certs}"
CORE_DIR="/root/megapolos-core"
GUI_REPO="${MEGAPOLOS_GUI_REPO:-https://gitlab.com/megapolos/megapolos-gui.git}"
GUI_DOMAIN="${MEGAPOLOS_GUI_DOMAIN:-gui.megapolos.local}"
REGISTRY_HOST="127.0.0.1"
REGISTRY_USER="megapolos"
REGISTRY_PASS="megapolos"

# =============================================================================
# 1. Свой Docker daemon (DinD) с insecure-registry и vfs storage
# =============================================================================
setup_dockerd() {
  info "Установка и настройка внутреннего dockerd..."
  # get.docker.com выходит с ненулевым кодом без systemd — терпим, dockerd стартуем вручную
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
    command -v docker &>/dev/null || error "Docker не установился"
  fi

  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<EOF
{
  "insecure-registries": ["${REGISTRY_HOST}:443", "$(hostname):443"],
  "storage-driver": "vfs"
}
EOF
  # vfs обязателен: overlay-поверх-overlay не работает в DinD

  pkill dockerd 2>/dev/null || true
  sleep 2
  nohup dockerd > /var/log/dockerd.log 2>&1 &
  for i in $(seq 1 20); do docker info &>/dev/null && break; sleep 1; done
  docker info &>/dev/null || error "dockerd не запустился"
  docker swarm init --advertise-addr 127.0.0.1 2>/dev/null || true
  success "dockerd готов (vfs, insecure-registry ${REGISTRY_HOST}:443, swarm active)"
}

# =============================================================================
# 2. SSH сервер (Ansible подключается к ноде по SSH)
# =============================================================================
setup_ssh() {
  info "Настройка SSH сервера..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y openssh-server sshpass -qq >/dev/null 2>&1
  echo "root:root" | chpasswd
  sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  mkdir -p /run/sshd
  pkill sshd 2>/dev/null || true
  /usr/sbin/sshd
  sleep 1
  sshpass -p root ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1 "echo ok" >/dev/null 2>&1 || error "SSH к localhost не работает"
  success "SSH к 127.0.0.1 работает (root/root)"
}

# =============================================================================
# 3. Системные зависимости + современный ansible
# =============================================================================
install_deps() {
  info "Установка зависимостей..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y curl git python3-pip openssl -qq >/dev/null 2>&1

  if ! node --version 2>/dev/null | grep -q "^v18"; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1
    apt-get install -y nodejs -qq >/dev/null 2>&1
  fi
  command -v psql &>/dev/null || apt-get install -y postgresql postgresql-contrib -qq >/dev/null 2>&1
  command -v nodemon &>/dev/null || npm install -g nodemon ts-node >/dev/null 2>&1

  # Современный ansible через pip (apt-версия 2.10 не резолвит FQCN коллекций)
  pip3 install --upgrade pip -q 2>/dev/null
  pip3 install 'ansible>=9' -q 2>/dev/null
  # docker SDK ломается с requests>=2.32 — пиним совместимые версии
  pip3 install docker jsondiff cryptography passlib 'requests==2.31.0' 'urllib3<2' -q 2>/dev/null
  ansible-galaxy collection install community.docker community.general community.crypto >/dev/null 2>&1

  success "Зависимости установлены (ansible $(ansible --version 2>/dev/null | head -1 | grep -oP 'core [0-9.]+'))"
}

# =============================================================================
# 4. Клонирование + PostgreSQL
# =============================================================================
setup_repos_db() {
  info "Клонирование ядра..."
  [[ -d "$CORE_DIR/.git" ]] || git clone --branch "$CORE_BRANCH" "$CORE_REPO" "$CORE_DIR"
  (cd "$CORE_DIR" && npm install --silent)

  info "Настройка PostgreSQL..."
  service postgresql start
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='megapolos'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE USER megapolos WITH PASSWORD 'pgdata';\""
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='megapolos'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE DATABASE megapolos OWNER megapolos;\""
  cp "$CORE_DIR/install/newpostgresql.sql" /tmp/schema.sql && chmod 644 /tmp/schema.sql
  su - postgres -c "psql -d megapolos -f /tmp/schema.sql" >/dev/null 2>&1 || true
  for g in "ALL TABLES" "ALL SEQUENCES"; do
    su - postgres -c "psql -d megapolos -c 'GRANT ALL PRIVILEGES ON $g IN SCHEMA public TO megapolos;'" >/dev/null 2>&1
  done
  su - postgres -c "psql -d megapolos -c 'GRANT ALL PRIVILEGES ON SCHEMA public TO megapolos;'" >/dev/null 2>&1
  success "Ядро и БД готовы"
}

# =============================================================================
# 5. Конфиг (devMode=true, local self-signed)
# =============================================================================
configure_core() {
  info "Запись config.json (devMode=true, local self-signed)..."
  # config.json пишем ТОЛЬКО если его ещё нет — иначе перезапись сгенерит новый
  # секрет и инвалидирует root-токен
  [[ -f "$CORE_DIR/config/config.json" ]] && { success "config.json уже есть"; return; }
  local secret; secret=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)
  cat > "$CORE_DIR/config/config.json" <<EOF
{
  "secret": "$secret",
  "connectionString": "postgres://megapolos:pgdata@localhost:5432/megapolos",
  "registryHost": "$REGISTRY_HOST",
  "registryUser": "$REGISTRY_USER",
  "registryPassword": "$REGISTRY_PASS",
  "debug": false,
  "devMode": true,
  "publicSchema": false,
  "allowUnauthorized": false,
  "noRoot": true,
  "catalogUrl": ""
}
EOF
  success "config.json записан"
}

# =============================================================================
# 6. Оркестрация Megapolos (install.ts) — нода, INIT/PREPARE/REGISTRY, деплой
#    NODE_TLS_REJECT_UNAUTHORIZED=0 — dockerode ходит на self-signed nginx:5102
# =============================================================================
bootstrap() {
  info "Оркестрация через install.ts (нода, INIT/PREPARE/REGISTRY, деплой)..."
  (cd "$CORE_DIR" && \
    NODE_TLS_REJECT_UNAUTHORIZED=0 \
    MEGAPOLOS_NODE_HOST="127.0.0.1" \
    MEGAPOLOS_REGISTRY_HOST="$REGISTRY_HOST" \
    MEGAPOLOS_BOOTSTRAP_APP_REPO="$GUI_REPO" \
    MEGAPOLOS_BOOTSTRAP_APP_NAME="megapolos-gui" \
    MEGAPOLOS_BOOTSTRAP_APP_PORT="80" \
    MEGAPOLOS_BOOTSTRAP_APP_DOMAIN="$GUI_DOMAIN" \
    MEGAPOLOS_BOOTSTRAP_APP_OUTER_PORT="3000" \
    npm run bootstrap) || error "install.ts завершился с ошибкой"
  success "Оркестрация Megapolos завершена"
}

# =============================================================================
# 7. Запуск ядра
# =============================================================================
start_core() {
  info "Запуск megapolos-core..."
  pkill -f "nodemon index.ts" 2>/dev/null || true
  pkill -f "ts-node index.ts" 2>/dev/null || true
  for i in $(seq 1 15); do
    (exec 3<>/dev/tcp/127.0.0.1/5100) 2>/dev/null || break   # порт свободен
    exec 3>&- 3<&-; sleep 1
  done
  cd "$CORE_DIR"
  NODE_TLS_REJECT_UNAUTHORIZED=0 nohup nodemon index.ts > /tmp/core.log 2>&1 &
  for i in $(seq 1 40); do grep -q "Server is running on port" /tmp/core.log 2>/dev/null && break; sleep 2; done
  grep -q "Server is running on port" /tmp/core.log || error "core не запустился (см. /tmp/core.log)"
  ROOT_TOKEN=$(tr -d '\0' < /tmp/core.log | grep -oP "token: '\K[^']+" | head -1)
  success "core запущен"
}

# =============================================================================
# Main
# =============================================================================
ROOT_TOKEN=""

setup_dockerd
setup_ssh
install_deps
setup_repos_db
configure_core
bootstrap
start_core

echo ""
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Megapolos готов локально (self-signed, TLS-bypass)${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo -e "  Backend:  http://localhost:5100"
echo -e "  GUI:      https://${GUI_DOMAIN}"
echo -e "  Registry: https://${REGISTRY_HOST}:443  (${REGISTRY_USER}/${REGISTRY_PASS})"
echo -e "  Root CA:  ${CORE_DIR}/data/ca/ca.crt  (или GET /api/ca/download)"
echo -e "  Token:    ${ROOT_TOKEN}"
echo ""
echo -e "  Оркестрация выполнена install.ts (нода, INIT/PREPARE/REGISTRY, деплой)."
echo -e "  Образы пушатся в приватный registry и пуллятся при деплое (как в prod)."
echo -e "${GREEN}=====================================================${NC}"
