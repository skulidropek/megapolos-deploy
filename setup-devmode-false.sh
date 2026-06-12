#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Megapolos devMode=false локальный запуск (полная функциональность)
#
# Поднимает Megapolos с devMode=false локально внутри ОДНОГО контейнера:
#   - SSH (Ansible ходит на ноду по SSH)
#   - собственный dockerd (docker-in-docker) с insecure-registry 127.0.0.1:443
#   - приватный Docker Registry (push/pull образов)
#   - Docker Swarm деплой
#
# Отличие от devMode=true: образы реально пушатся в приватный registry
# и пуллятся оттуда при деплое (как в продакшене), а ноды управляются по SSH.
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
GUI_REPO="${MEGAPOLOS_GUI_REPO:-https://gitlab.com/megapolos/megapolos-gui.git}"
REGISTRY_HOST="127.0.0.1"
REGISTRY_USER="megapolos"
REGISTRY_PASS="megapolos"

# =============================================================================
# 1. Свой Docker daemon (DinD) с insecure-registry и vfs storage
# =============================================================================
setup_dockerd() {
  info "Установка и настройка внутреннего dockerd..."
  command -v docker &>/dev/null || curl -fsSL https://get.docker.com | sh >/dev/null

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
  apt-get install -y curl git python3-pip -qq >/dev/null 2>&1

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
  info "Клонирование репозиториев..."
  [[ -d /root/megapolos-core/.git ]] || git clone --branch "$CORE_BRANCH" "$CORE_REPO" /root/megapolos-core
  [[ -d /root/megapolos-gui/.git ]]  || git clone "$GUI_REPO" /root/megapolos-gui

  info "Настройка PostgreSQL..."
  service postgresql start
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='megapolos'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE USER megapolos WITH PASSWORD 'pgdata';\""
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='megapolos'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE DATABASE megapolos OWNER megapolos;\""
  cp /root/megapolos-core/install/newpostgresql.sql /tmp/schema.sql && chmod 644 /tmp/schema.sql
  su - postgres -c "psql -d megapolos -f /tmp/schema.sql" >/dev/null 2>&1 || true
  for g in "ALL TABLES" "ALL SEQUENCES"; do
    su - postgres -c "psql -d megapolos -c 'GRANT ALL PRIVILEGES ON $g IN SCHEMA public TO megapolos;'" >/dev/null 2>&1
  done
  su - postgres -c "psql -d megapolos -c 'GRANT ALL PRIVILEGES ON SCHEMA public TO megapolos;'" >/dev/null 2>&1
  success "Репозитории и БД готовы"
}

# =============================================================================
# 5. Конфиг devMode=false + запуск core
# =============================================================================
configure_start_core() {
  info "Запись config.json (devMode=false)..."
  local secret; secret=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)
  cat > /root/megapolos-core/config/config.json <<EOF
{
  "secret": "$secret",
  "connectionString": "postgres://megapolos:pgdata@localhost:5432/megapolos",
  "registryHost": "$REGISTRY_HOST",
  "registryUser": "$REGISTRY_USER",
  "registryPassword": "$REGISTRY_PASS",
  "debug": false,
  "devMode": false,
  "publicSchema": false,
  "allowUnauthorized": false,
  "noRoot": true,
  "catalogUrl": ""
}
EOF
  (cd /root/megapolos-core && npm install --silent)

  info "Запуск megapolos-core..."
  pkill -f "ts-node index.ts" 2>/dev/null || true
  sleep 2
  # NODE_TLS_REJECT_UNAUTHORIZED=0 — dockerode ходит на self-signed nginx:5102
  cd /root/megapolos-core
  NODE_TLS_REJECT_UNAUTHORIZED=0 nohup nodemon index.ts > /tmp/core.log 2>&1 &
  for i in $(seq 1 40); do grep -q "Server is running on port" /tmp/core.log 2>/dev/null && break; sleep 2; done
  grep -q "Server is running on port" /tmp/core.log || error "core не запустился (см. /tmp/core.log)"

  ROOT_TOKEN=$(grep -oP "token: '\K[^']+" /tmp/core.log | head -1)
  [[ -n "$ROOT_TOKEN" ]] || error "root-токен не найден"
  success "core запущен (devMode=false)"
}

# =============================================================================
# GraphQL helper
# =============================================================================
gql() {
  curl -s http://localhost:5100/graphql -X POST \
    -H 'Content-Type: application/json' -H "token: $ROOT_TOKEN" \
    -d "{\"query\":$(echo "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
}

# =============================================================================
# 6. Registry-запись + нода + INIT/PREPARE/REGISTRY (через SSH)
# =============================================================================
setup_node() {
  info "Создание DockerRegistry и ноды..."
  gql "mutation { createDockerRegistry(values: { name: \"local\", host: \"$REGISTRY_HOST\", user: \"$REGISTRY_USER\", password: \"$REGISTRY_PASS\", isDefault: true }) { id } }" >/dev/null
  NODE_ID=$(gql "mutation { createNode(values: { name: \"localhost\", host: \"127.0.0.1\", user: \"root\", password: \"root\" }) { id } }" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['data']['createNode']['id'])")
  [[ -n "$NODE_ID" ]] || error "не удалось создать ноду"

  for step in "initNode:INIT" "prepareNodeForCore:PREPARE FOR CORE" "installRegistryToNode:INSTALL REGISTRY"; do
    local mut="${step%%:*}"; local label="${step##*:}"
    info "$label (Ansible по SSH к 127.0.0.1)..."
    gql "mutation { ${mut}(id: \"$NODE_ID\") }" >/dev/null
    sleep 5
    for i in $(seq 1 60); do
      local st; st=$(gql "{ getAllNode { lifeStatus } }" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['getAllNode'][0]['lifeStatus'])" 2>/dev/null)
      [[ "$st" == "running" ]] && break
      sleep 5
    done
    success "$label завершён"
  done

  # Проверка registry
  docker login -u "$REGISTRY_USER" -p "$REGISTRY_PASS" "${REGISTRY_HOST}:443" >/dev/null 2>&1 \
    && success "Registry доступен: ${REGISTRY_HOST}:443" \
    || error "Registry недоступен"
}

# =============================================================================
# Main
# =============================================================================
ROOT_TOKEN=""
NODE_ID=""

setup_dockerd
setup_ssh
install_deps
setup_repos_db
configure_start_core
setup_node

echo ""
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Megapolos devMode=false готов локально!${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo -e "  Backend:  http://localhost:5100  (HTTPS proxy: 5104)"
echo -e "  Registry: https://${REGISTRY_HOST}:443  (${REGISTRY_USER}/${REGISTRY_PASS})"
echo -e "  Root CA:  /data/nginx/ssl/ca/ca.crt"
echo -e "  Token:    ${ROOT_TOKEN}"
echo ""
echo -e "  Дальше: добавь app/image через GUI или API — образы будут"
echo -e "  пушиться в приватный registry и пуллиться при деплое (как в prod)."
echo -e "${GREEN}=====================================================${NC}"
