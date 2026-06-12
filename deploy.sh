#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Megapolos Deploy Script
# Usage:
#   ./deploy.sh --dev              # dev mode
#   ./deploy.sh --dev --tunnel     # dev + cloudflare tunnels (внешний доступ)
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Если sudo не установлен — установить (нужен внутри контейнеров где мы root)
if ! command -v sudo &>/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq 2>/dev/null
  apt-get install -y sudo -qq 2>/dev/null
fi

# --- Args ---
TUNNEL=false
for arg in "$@"; do
  case $arg in
    --dev)    true ;;
    --tunnel) TUNNEL=true ;;
    --help|-h) echo "Usage: $0 [--dev] [--tunnel]"; exit 0 ;;
    *) error "Unknown argument: $arg" ;;
  esac
done

INSTALL_DIR="${MEGAPOLOS_DIR:-$HOME/megapolos}"
CORE_DIR="$INSTALL_DIR/megapolos-core"
GUI_DIR="$INSTALL_DIR/megapolos-gui"
CORE_REPO="${MEGAPOLOS_CORE_REPO:-https://github.com/skulidropek/megapolos-core.git}"
CORE_BRANCH="${MEGAPOLOS_CORE_BRANCH:-self-signed-certs}"
GUI_REPO="${MEGAPOLOS_GUI_REPO:-https://gitlab.com/megapolos/megapolos-gui.git}"

DB_USER="megapolos"; DB_PASS="pgdata"; DB_NAME="megapolos"; DB_PORT="5432"
CORE_PORT="5100"; GUI_PORT="3000"
SECRET=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32 || true)

IN_DOCKER=false
[ -f /.dockerenv ] && IN_DOCKER=true
grep -q docker /proc/1/cgroup 2>/dev/null && IN_DOCKER=true

# GraphQL helper
gql() {
  local query="$1"
  curl -s http://localhost:${CORE_PORT}/graphql -X POST \
    -H "Content-Type: application/json" \
    -H "token: ${ROOT_TOKEN:-}" \
    -d "{\"query\":$(echo "$query" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
    2>/dev/null
}

gql_extract() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)" 2>/dev/null
}

# =============================================================================
# 1. Системные зависимости
# =============================================================================
install_deps() {
  info "Установка зависимостей..."
  export DEBIAN_FRONTEND=noninteractive
  sudo -E apt-get update -qq
  sudo -E apt-get install -y curl git >/dev/null

  if ! node --version 2>/dev/null | grep -q "^v18"; then
    info "Установка Node.js 18..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - >/dev/null
    sudo -E apt-get install -y nodejs >/dev/null
  fi

  if ! command -v psql &>/dev/null; then
    info "Установка PostgreSQL..."
    sudo -E apt-get install -y postgresql postgresql-contrib >/dev/null
  fi

  sudo -E apt-get install -y git curl >/dev/null

  if ! command -v nodemon &>/dev/null; then
    info "Установка nodemon/ts-node..."
    sudo npm install -g nodemon ts-node >/dev/null
  fi

  if ! command -v docker &>/dev/null; then
    info "Установка Docker..."
    curl -fsSL https://get.docker.com | sudo sh >/dev/null
  fi

  if ! docker info &>/dev/null; then
    sudo service docker start 2>/dev/null || sudo systemctl start docker 2>/dev/null || true
    sleep 2
  fi

  if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
    info "Инициализация Docker Swarm..."
    docker swarm init 2>/dev/null || true
  fi

  if ! command -v ansible &>/dev/null; then
    info "Установка Ansible..."
    sudo -E apt-get install -y ansible >/dev/null
  fi

  sudo -E apt-get install -y python3-docker python3-jsondiff >/dev/null
  pip install cryptography --break-system-packages -q 2>/dev/null || true

  if ! ansible-galaxy collection list 2>/dev/null | grep -q "community.docker"; then
    info "Установка community.docker..."
    ansible-galaxy collection install community.docker >/dev/null
  fi

  success "Зависимости установлены"
}

# =============================================================================
# 2. Репозитории
# =============================================================================
clone_repos() {
  info "Клонирование репозиториев в $INSTALL_DIR..."
  mkdir -p "$INSTALL_DIR"

  if [[ -d "$CORE_DIR/.git" ]]; then
    info "megapolos-core уже есть, обновляем..."
    git -C "$CORE_DIR" pull --ff-only 2>/dev/null || true
  else
    rm -rf "$CORE_DIR" 2>/dev/null || true
    git clone --branch "$CORE_BRANCH" "$CORE_REPO" "$CORE_DIR"
  fi

  if [[ -d "$GUI_DIR/.git" ]]; then
    info "megapolos-gui уже есть, обновляем..."
    git -C "$GUI_DIR" pull --ff-only 2>/dev/null || true
  else
    rm -rf "$GUI_DIR" 2>/dev/null || true
    git clone "$GUI_REPO" "$GUI_DIR"
  fi

  success "Репозитории готовы"
}

# =============================================================================
# 3. PostgreSQL
# =============================================================================
start_postgres() {
  if command -v pg_ctlcluster &>/dev/null; then
    PG_VER=$(pg_lsclusters -h | awk '{print $1}' | head -1)
    PG_CL=$(pg_lsclusters -h | awk '{print $2}' | head -1)
    sudo pg_ctlcluster "$PG_VER" "$PG_CL" start 2>/dev/null || true
  fi
  sudo service postgresql start 2>/dev/null || true
  sleep 2
}

setup_postgres() {
  info "Настройка PostgreSQL..."
  start_postgres

  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null

  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null

  # Копируем схему в /tmp чтобы postgres мог её прочитать
  cp "$CORE_DIR/install/newpostgresql.sql" /tmp/megapolos_schema.sql
  chmod 644 /tmp/megapolos_schema.sql
  sudo -u postgres psql -d "$DB_NAME" -f /tmp/megapolos_schema.sql 2>/dev/null || true
  rm -f /tmp/megapolos_schema.sql

  sudo -u postgres psql -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;" 2>/dev/null || true
  sudo -u postgres psql -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;" 2>/dev/null || true
  sudo -u postgres psql -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO $DB_USER;" 2>/dev/null || true

  success "PostgreSQL настроен"
}

# =============================================================================
# 4. Конфиг и запуск бэкенда
# =============================================================================
configure_and_start_core() {
  info "Настройка megapolos-core..."

  cat > "$CORE_DIR/config/config.json" <<EOF
{
  "secret": "$SECRET",
  "connectionString": "postgres://$DB_USER:$DB_PASS@localhost:$DB_PORT/$DB_NAME",
  "registryHost": "",
  "registryUser": "",
  "registryPassword": "",
  "debug": false,
  "devMode": true,
  "publicSchema": false,
  "allowUnauthorized": false,
  "noRoot": true,
  "catalogUrl": ""
}
EOF

  info "Установка npm зависимостей для core..."
  (cd "$CORE_DIR" && npm install --silent)

  info "Запуск megapolos-core (от root)..."
  # Убиваем старые процессы и освобождаем порт
  sudo pkill -f "nodemon index.ts" 2>/dev/null || true
  sudo pkill -f "ts-node index.ts" 2>/dev/null || true
  sudo fuser -k ${CORE_PORT}/tcp 2>/dev/null || true
  sleep 3

  nohup bash -c "cd '$CORE_DIR' && sudo nodemon index.ts" > /tmp/megapolos-core.log 2>&1 &
  CORE_PID=$!

  info "Ожидание запуска core..."
  local timeout=60
  while [[ $timeout -gt 0 ]]; do
    if grep -q "Server is running on port" /tmp/megapolos-core.log 2>/dev/null; then break; fi
    sleep 2; ((timeout-=2))
  done
  [[ $timeout -le 0 ]] && error "Core не запустился за 60 сек. Лог: /tmp/megapolos-core.log"

  ROOT_TOKEN=$(grep -oP "token: '\K[^']+" /tmp/megapolos-core.log 2>/dev/null | head -1)
  [[ -z "$ROOT_TOKEN" ]] && error "Токен не найден в логах"

  success "Core запущен, токен получен"
}

# =============================================================================
# 5. CloudFlare туннель для бэкенда
# =============================================================================
setup_backend_tunnel() {
  info "Поднимаем CloudFlare туннель для бэкенда..."

  if ! command -v cloudflared &>/dev/null; then
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /tmp/cloudflared
    sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
    sudo chmod +x /usr/local/bin/cloudflared
  fi

  cloudflared tunnel --url "http://localhost:${CORE_PORT}" > /tmp/cf-backend.log 2>&1 &
  CF_BACKEND_PID=$!

  BACKEND_URL=""
  for i in $(seq 1 20); do
    BACKEND_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf-backend.log 2>/dev/null | head -1 || true)
    [[ -n "$BACKEND_URL" ]] && break
    sleep 1
  done
  [[ -z "$BACKEND_URL" ]] && error "CloudFlare backend tunnel не запустился"

  success "Backend tunnel: $BACKEND_URL"
}

# =============================================================================
# 6. INIT → PREPARE FOR CORE ноды
# =============================================================================
setup_node() {
  info "Настройка ноды через Megapolos API..."

  # Создать ноду если не существует
  local existing
  existing=$(gql "{ getAllNode { id name } }" | gql_extract "['data']['getAllNode'][0]['id']" 2>/dev/null || true)

  if [[ -z "$existing" ]]; then
    info "Создание ноды localhost..."
    NODE_ID=$(gql "mutation { createNode(values: { name: \"localhost\", host: \"localhost\", user: \"root\", password: \"root\" }) { id } }" | \
      gql_extract "['data']['createNode']['id']")
    [[ -z "$NODE_ID" ]] && error "Не удалось создать ноду"
  else
    NODE_ID="$existing"
    info "Нода уже существует: $NODE_ID"
  fi

  # INIT
  info "Запуск INIT ноды (установка Docker, Ansible, генерация Root CA)..."
  gql "mutation { initNode(id: \"$NODE_ID\") }" > /dev/null

  info "Ожидание завершения INIT..."
  sleep 5
  local timeout=180
  while [[ $timeout -gt 0 ]]; do
    local status
    status=$(gql "{ getAllNode { id lifeStatus } }" | gql_extract "['data']['getAllNode'][0]['lifeStatus']" 2>/dev/null || true)
    [[ "$status" == "running" ]] && break
    sleep 5; ((timeout-=5))
  done

  # Проверяем что Root CA сгенерирован
  if [[ ! -f /data/nginx/ssl/ca/ca.crt ]]; then
    warn "Root CA не найден, пробуем ещё раз..."
    gql "mutation { initNode(id: \"$NODE_ID\") }" > /dev/null
    sleep 30
  fi

  success "INIT завершён"

  # PREPARE FOR CORE
  info "Запуск PREPARE FOR CORE (настройка nginx для Core API)..."
  gql "mutation { prepareNodeForCore(id: \"$NODE_ID\") }" > /dev/null

  info "Ожидание core.conf..."
  local timeout=120
  while [[ $timeout -gt 0 ]]; do
    [[ -f /data/nginx/conf/core.conf ]] && break
    sleep 3; ((timeout-=3))
  done
  [[ ! -f /data/nginx/conf/core.conf ]] && warn "core.conf не появился (возможно уже был)"

  success "PREPARE FOR CORE завершён — Core API доступен на порту 5104 (HTTPS)"

  # INSTALL REGISTRY
  info "Запуск INSTALL REGISTRY (Docker Registry + SSL + htpasswd)..."

  # Создать запись Docker Registry в базе если не существует
  local reg_id
  reg_id=$(gql "{ getAllDockerRegistry { id isDefault } }" | \
    python3 -c "import json,sys; regs=json.load(sys.stdin)['data']['getAllDockerRegistry']; print(regs[0]['id'] if regs else '')" 2>/dev/null || true)

  if [[ -z "$reg_id" ]]; then
    reg_id=$(gql "mutation { createDockerRegistry(values: { name: \"local\", host: \"localhost\", user: \"megapolos\", password: \"megapolos\", isDefault: true }) { id } }" | \
      gql_extract "['data']['createDockerRegistry']['id']")
    info "Docker Registry создан в БД: $reg_id"
  else
    info "Docker Registry уже существует: $reg_id"
  fi

  gql "mutation { installRegistryToNode(id: \"$NODE_ID\") }" > /dev/null

  info "Ожидание завершения INSTALL REGISTRY..."
  # Даём время перейти в "updating", потом ждём "running"
  sleep 5
  local timeout=180
  while [[ $timeout -gt 0 ]]; do
    local status
    status=$(gql "{ getAllNode { id lifeStatus } }" | gql_extract "['data']['getAllNode'][0]['lifeStatus']" 2>/dev/null || true)
    [[ "$status" == "running" ]] && break
    sleep 5; ((timeout-=5))
  done

  success "INSTALL REGISTRY завершён"
}

# =============================================================================
# 7. Деплой Megapolos GUI как приложения
# =============================================================================
deploy_gui() {
  info "Деплой Megapolos GUI через Megapolos..."

  local backend_url="${BACKEND_URL:-http://localhost:${CORE_PORT}}"

  # npm install для GUI
  info "Установка npm зависимостей для GUI..."
  (cd "$GUI_DIR" && npm install --silent)

  # 7.1 Репозиторий
  info "Добавление репозитория megapolos-gui..."
  local repo_id
  repo_id=$(gql "{ getAllRepository { id name } }" | \
    python3 -c "import json,sys; repos=json.load(sys.stdin)['data']['getAllRepository']; \
    gui=[r for r in repos if r['name']=='megapolos-gui']; print(gui[0]['id'] if gui else '')" 2>/dev/null || true)

  if [[ -z "$repo_id" ]]; then
    repo_id=$(gql "mutation { createRepository(values: { name: \"megapolos-gui\", url: \"$GUI_REPO\", repositoryType: \"remote\" }) { id } }" | \
      gql_extract "['data']['createRepository']['id']")
    [[ -z "$repo_id" ]] && error "Не удалось создать репозиторий"
    info "Репозиторий создан: $repo_id"
  else
    info "Репозиторий уже существует: $repo_id"
  fi

  # 7.2 Приложение
  info "Создание приложения megapolos-gui..."
  local app_id
  app_id=$(gql "{ getAllApp { id name } }" | \
    python3 -c "import json,sys; apps=json.load(sys.stdin)['data']['getAllApp']; \
    gui=[a for a in apps if a['name']=='megapolos-gui']; print(gui[0]['id'] if gui else '')" 2>/dev/null || true)

  if [[ -z "$app_id" ]]; then
    gql "mutation { installApp(input: { name: \"megapolos-gui\", description: \"Megapolos GUI\" }) }" > /dev/null
    # installApp returns bool, get ID via getAllApp
    app_id=$(gql "{ getAllApp { id name } }" | \
      python3 -c "import json,sys; apps=json.load(sys.stdin)['data']['getAllApp']; gui=[a for a in apps if a['name']=='megapolos-gui']; print(gui[0]['id'] if gui else '')" 2>/dev/null || true)
    [[ -z "$app_id" ]] && error "Не удалось создать/найти приложение megapolos-gui"
    info "Приложение создано: $app_id"
  else
    info "Приложение уже существует: $app_id"
  fi

  # 7.3 Образ
  info "Создание образа..."
  local image_id
  image_id=$(gql "mutation { createImage(values: { name: \"megapolos-gui\", image: \"megapolos-gui\", innerPort: 80, buildNumber: 1, app: \"$app_id\", repository: \"$repo_id\" }) { id } }" | \
    gql_extract "['data']['createImage']['id']")
  [[ -z "$image_id" ]] && error "Не удалось создать образ"
  info "Образ создан: $image_id"

  # 7.4 Сборка образа
  info "Сборка Docker образа (это может занять несколько минут)..."
  gql "mutation { buildImage(imageId: \"$image_id\") }" > /dev/null

  info "Ожидание сборки..."
  local timeout=300
  while [[ $timeout -gt 0 ]]; do
    local status
    status=$(gql "{ getImage(id: \"$image_id\") { status } }" | \
      gql_extract "['data']['getImage']['status']" 2>/dev/null || true)
    [[ "$status" == "Built" ]] && break
    [[ "$status" == "Failed" ]] && error "Сборка образа провалилась. Проверь логи в ПУСК → logs"
    sleep 5; ((timeout-=5))
  done
  [[ $timeout -le 0 ]] && error "Сборка образа не завершилась за 5 минут"
  success "Образ собран"

  # 7.5 Конфигурация
  info "Создание конфигурации..."
  local conf_id
  conf_id=$(gql "mutation { createConfiguration(appId: \"$app_id\", configurationData: { name: \"default\", services: [] }) { id } }" | \
    gql_extract "['data']['createConfiguration']['id']")
  [[ -z "$conf_id" ]] && error "Не удалось создать конфигурацию"

  # 7.6 Версия приложения
  info "Создание версии приложения 1.0.0..."
  local version_id
  version_id=$(gql "mutation { createAppVersion(appVersionData: { app: \"$app_id\", configuration: \"$conf_id\", buildNumber: 1, version: \"1.0.0\" }, images: [{ imageId: \"$image_id\" }]) { id } }" | \
    gql_extract "['data']['createAppVersion']['id']")
  [[ -z "$version_id" ]] && error "Не удалось создать версию"
  info "Версия создана: $version_id"

  # 7.7 Инстанс из версии
  info "Создание инстанса из версии..."
  local instance_id
  instance_id=$(gql "mutation { createConfiguratedInstance(appVersionId: \"$version_id\", instanceData: { name: \"megapolos-gui\", containers: [{ name: \"megapolos-gui\", role: \"app\", node: \"$NODE_ID\", image: \"$image_id\", outerPort: $GUI_PORT, volumes: [], dbs: [], envs: [{ name: \"MEGAPOLOS_SERVER\", value: \"$backend_url\" }] }] }) { id } }" | \
    gql_extract "['data']['createConfiguratedInstance']['id']")
  [[ -z "$instance_id" ]] && error "Не удалось создать инстанс"
  info "Инстанс создан: $instance_id"

  # 7.8 Деплой (Update nodes)
  info "Деплой контейнера (Update nodes → Ansible → docker stack deploy)..."
  gql "mutation { updateNodesOfImage(imageId: \"$image_id\") }" > /dev/null

  info "Ожидание запуска контейнера..."
  local timeout=120
  while [[ $timeout -gt 0 ]]; do
    local container_status
    container_status=$(docker service ls --format "{{.Name}} {{.Replicas}}" 2>/dev/null | grep "megapolos-gui\|megapolos_megapolos-gui" | awk '{print $2}' | head -1 || true)
    [[ "$container_status" == "1/1" ]] && break
    sleep 5; ((timeout-=5))
  done

  GUI_URL="http://localhost:${GUI_PORT}"
  success "Megapolos GUI задеплоен"
}

# =============================================================================
# 8. CloudFlare туннель для GUI
# =============================================================================
setup_frontend_tunnel() {
  info "Поднимаем CloudFlare туннель для GUI..."

  # Найти реальный IP хоста (для Docker-in-Docker)
  local host_gw
  host_gw=$(python3 -c "
with open('/proc/net/route') as f:
    for line in f:
        parts = line.split()
        if parts[1] == '00000000':
            gw = int(parts[2], 16)
            print(f'{gw&0xff}.{(gw>>8)&0xff}.{(gw>>16)&0xff}.{(gw>>24)&0xff}')
            break
" 2>/dev/null || echo "localhost")

  cloudflared tunnel --url "http://${host_gw}:${GUI_PORT}" > /tmp/cf-frontend.log 2>&1 &

  FRONTEND_URL=""
  for i in $(seq 1 20); do
    FRONTEND_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf-frontend.log 2>/dev/null | head -1 || true)
    [[ -n "$FRONTEND_URL" ]] && break
    sleep 1
  done
  [[ -z "$FRONTEND_URL" ]] && warn "CloudFlare frontend tunnel не запустился, используй http://localhost:${GUI_PORT}"

  success "Frontend tunnel: ${FRONTEND_URL:-http://localhost:${GUI_PORT}}"
}

# =============================================================================
# 9. Итог
# =============================================================================
print_summary() {
  local gui_access="${FRONTEND_URL:-$GUI_URL}"
  local backend_access="${BACKEND_URL:-http://localhost:${CORE_PORT}}"

  echo ""
  echo -e "${GREEN}========================================================${NC}"
  echo -e "${GREEN}  Megapolos успешно развёрнут!${NC}"
  echo -e "${GREEN}========================================================${NC}"
  echo ""
  echo -e "  GUI:     ${BLUE}${gui_access}${NC}"
  echo -e "  Backend: ${BLUE}${backend_access}${NC}"
  echo ""
  echo -e "  Root токен:"
  echo -e "  ${YELLOW}${ROOT_TOKEN}${NC}"
  echo ""
  echo -e "  Root CA сертификат (установи в браузер):"
  echo -e "  ${YELLOW}/data/nginx/ssl/ca/ca.crt${NC}"
  echo ""
  echo -e "  Логи:"
  echo -e "    Core:  tail -f /tmp/megapolos-core.log"
  echo -e "    Nginx: docker logs nginx -f"
  echo -e "    GUI:   docker service logs megapolos_megapolos-gui -f 2>/dev/null || docker service logs test_megapolos-gui -f"
  echo ""
  echo -e "${GREEN}========================================================${NC}"
}

# =============================================================================
# Main
# =============================================================================
ROOT_TOKEN=""
NODE_ID=""
BACKEND_URL=""
FRONTEND_URL=""
GUI_URL="http://localhost:${GUI_PORT}"

install_deps
clone_repos
setup_postgres
configure_and_start_core

if [[ "$TUNNEL" == "true" ]]; then
  setup_backend_tunnel
fi

setup_node
deploy_gui

if [[ "$TUNNEL" == "true" ]]; then
  setup_frontend_tunnel
fi

print_summary
