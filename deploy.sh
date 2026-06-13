#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Megapolos deploy (dev) — тонкий установщик.
# Ставит то, без чего ядро не запустить (node.js, postgres, docker, ansible),
# поднимает ядро и передаёт ВСЮ оркестрацию самому Megapolos (install.ts):
#   нода -> INIT (nginx, единый CA) -> PREPARE FOR CORE -> INSTALL REGISTRY
#   -> (опц.) деплой приложения с доменом.
# Никаких GraphQL/curl-вызовов из bash — всё делает TypeScript-код мегаполоса.
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# sudo может отсутствовать (внутри контейнера мы root)
if ! command -v sudo &>/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq 2>/dev/null && apt-get install -y sudo -qq 2>/dev/null || true
fi

INSTALL_DIR="${MEGAPOLOS_DIR:-$HOME/megapolos}"
CORE_DIR="$INSTALL_DIR/megapolos-core"
CORE_REPO="${MEGAPOLOS_CORE_REPO:-https://github.com/skulidropek/megapolos-core.git}"
CORE_BRANCH="${MEGAPOLOS_CORE_BRANCH:-self-signed-certs}"

DB_USER="megapolos"; DB_PASS="pgdata"; DB_NAME="megapolos"; DB_PORT="5432"; CORE_PORT="5100"

# приложение для авто-деплоя (по умолчанию — Megapolos GUI). Пусто = не деплоить.
GUI_REPO="${MEGAPOLOS_GUI_REPO:-https://gitlab.com/megapolos/megapolos-gui.git}"
GUI_DOMAIN="${MEGAPOLOS_GUI_DOMAIN:-gui.megapolos.local}"

# --- 1. системные зависимости (то, без чего ядро не стартует) ---
install_deps() {
  info "Установка системных зависимостей..."
  export DEBIAN_FRONTEND=noninteractive
  sudo -E apt-get update -qq
  sudo -E apt-get install -y curl git python3-pip openssl -qq >/dev/null

  if ! node --version 2>/dev/null | grep -q "^v18"; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - >/dev/null
    sudo -E apt-get install -y nodejs >/dev/null
  fi
  command -v psql &>/dev/null || sudo -E apt-get install -y postgresql postgresql-contrib >/dev/null
  command -v nodemon &>/dev/null || sudo npm install -g nodemon ts-node >/dev/null

  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sudo sh >/dev/null 2>&1 || true
    command -v docker &>/dev/null || error "Docker не установился"
  fi
  # запуск dockerd
  if [[ -f /.dockerenv ]]; then
    # внутри контейнера свой dockerd ОБЯЗАН быть на vfs (overlay-в-overlay не монтируется)
    sudo mkdir -p /etc/docker
    grep -q '"vfs"' /etc/docker/daemon.json 2>/dev/null || echo '{ "storage-driver": "vfs" }' | sudo tee /etc/docker/daemon.json >/dev/null
    if ! docker info 2>/dev/null | grep -q 'Storage Driver: vfs'; then
      sudo pkill dockerd 2>/dev/null || true; sleep 2
      sudo bash -c 'nohup dockerd > /var/log/dockerd.log 2>&1 &'
      for i in $(seq 1 20); do docker info &>/dev/null && break; sleep 2; done
    fi
  else
    docker info &>/dev/null || { sudo service docker start 2>/dev/null || sudo systemctl start docker 2>/dev/null || true; sleep 2; }
  fi
  docker info &>/dev/null || error "dockerd не запустился"
  docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active || docker swarm init 2>/dev/null || true

  # ansible (современный) + python-зависимости (нужны ansible-модулям docker/crypto)
  sudo -E apt-get install -y ansible -qq >/dev/null 2>&1 || true
  sudo pip3 install --upgrade pip -q 2>/dev/null || true
  sudo pip3 install 'ansible>=9' docker jsondiff cryptography passlib 'requests<2.32' 'urllib3<2' \
    --break-system-packages -q 2>/dev/null || \
    sudo pip3 install 'ansible>=9' docker jsondiff cryptography passlib 'requests<2.32' 'urllib3<2' -q 2>/dev/null || true
  ansible-galaxy collection install community.docker community.general community.crypto >/dev/null 2>&1 || true
  success "Зависимости установлены"
}

# --- 2. клонирование ядра ---
clone_core() {
  info "Клонирование megapolos-core ($CORE_BRANCH)..."
  mkdir -p "$INSTALL_DIR"
  if [[ -d "$CORE_DIR/.git" ]]; then
    git -C "$CORE_DIR" pull --ff-only 2>/dev/null || true
  else
    rm -rf "$CORE_DIR" 2>/dev/null || true
    git clone --branch "$CORE_BRANCH" "$CORE_REPO" "$CORE_DIR"
  fi
  success "Ядро склонировано"
}

# --- 3. PostgreSQL ---
setup_postgres() {
  info "Настройка PostgreSQL..."
  command -v pg_ctlcluster &>/dev/null && sudo pg_ctlcluster "$(pg_lsclusters -h | awk '{print $1}' | head -1)" "$(pg_lsclusters -h | awk '{print $2}' | head -1)" start 2>/dev/null || true
  sudo service postgresql start 2>/dev/null || true
  sleep 2
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null
  cp "$CORE_DIR/install/newpostgresql.sql" /tmp/megapolos_schema.sql; chmod 644 /tmp/megapolos_schema.sql
  sudo -u postgres psql -d "$DB_NAME" -f /tmp/megapolos_schema.sql 2>/dev/null || true
  rm -f /tmp/megapolos_schema.sql
  for g in "ALL TABLES" "ALL SEQUENCES"; do
    sudo -u postgres psql -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON $g IN SCHEMA public TO $DB_USER;" 2>/dev/null || true
  done
  sudo -u postgres psql -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO $DB_USER;" 2>/dev/null || true
  success "PostgreSQL настроен"
}

# --- 4. конфиг + npm install ---
configure_core() {
  info "Конфигурация ядра (devMode)..."
  local secret; secret=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)
  cat > "$CORE_DIR/config/config.json" <<EOF
{
  "secret": "$secret",
  "connectionString": "postgres://$DB_USER:$DB_PASS@localhost:$DB_PORT/$DB_NAME",
  "registryHost": "localhost",
  "registryUser": "megapolos",
  "registryPassword": "megapolos",
  "debug": false,
  "devMode": true,
  "publicSchema": false,
  "allowUnauthorized": false,
  "noRoot": true,
  "catalogUrl": ""
}
EOF
  info "npm install..."
  (cd "$CORE_DIR" && npm install --silent)
  success "Ядро сконфигурировано"
}

# --- 5. оркестрация мегаполосом (install.ts), затем старт ядра ---
bootstrap_and_start() {
  info "Запуск install.ts (нода, INIT/PREPARE/REGISTRY, деплой) — оркестрация на TS..."
  (cd "$CORE_DIR" && \
    MEGAPOLOS_NODE_HOST="localhost" \
    MEGAPOLOS_BOOTSTRAP_APP_REPO="$GUI_REPO" \
    MEGAPOLOS_BOOTSTRAP_APP_NAME="megapolos-gui" \
    MEGAPOLOS_BOOTSTRAP_APP_PORT="80" \
    MEGAPOLOS_BOOTSTRAP_APP_DOMAIN="$GUI_DOMAIN" \
    MEGAPOLOS_BOOTSTRAP_APP_OUTER_PORT="3000" \
    sudo -E npm run bootstrap) || error "install.ts завершился с ошибкой"
  success "Оркестрация Megapolos завершена"

  info "Запуск ядра (megapolos-core)..."
  sudo pkill -f "nodemon index.ts" 2>/dev/null || true
  sudo pkill -f "ts-node index.ts" 2>/dev/null || true
  sudo fuser -k ${CORE_PORT}/tcp 2>/dev/null || true
  sleep 3
  nohup bash -c "cd '$CORE_DIR' && sudo nodemon index.ts" > /tmp/megapolos-core.log 2>&1 &
  local t=60
  while [[ $t -gt 0 ]]; do grep -q "Server is running on port" /tmp/megapolos-core.log 2>/dev/null && break; sleep 2; ((t-=2)); done
  grep -q "Server is running on port" /tmp/megapolos-core.log || error "Ядро не запустилось (см. /tmp/megapolos-core.log)"
  ROOT_TOKEN=$(grep -oP "token: '\K[^']+" /tmp/megapolos-core.log 2>/dev/null | head -1)
  success "Ядро запущено"
}

print_summary() {
  echo ""
  echo -e "${GREEN}====================================================${NC}"
  echo -e "${GREEN}  Megapolos развёрнут (оркестрация через install.ts)${NC}"
  echo -e "${GREEN}====================================================${NC}"
  echo -e "  Backend:  http://localhost:${CORE_PORT}"
  echo -e "  GUI:      https://${GUI_DOMAIN} (через nginx-домен)"
  echo -e "  Root CA:  http://localhost:${CORE_PORT}/api/ca/download"
  echo -e "  Token:    ${ROOT_TOKEN:-см. /tmp/megapolos-core.log}"
  echo -e "${GREEN}====================================================${NC}"
}

ROOT_TOKEN=""
install_deps
clone_core
setup_postgres
configure_core
bootstrap_and_start
print_summary
