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

# Megapolos в devMode запускает локальный ansible под uid 0 (см. core Process.ts) с
# become — поэтому ядро ДОЛЖНО работать от root. Автоматически НЕ поднимаемся: запуск
# под root — осознанное решение пользователя (он сам пишет sudo).
if [ "$(id -u)" -ne 0 ]; then
  error "Megapolos требует root (в devMode ядро спавнит локальный ansible под uid 0).
       Запусти через sudo, например:
         curl -fsSL https://raw.githubusercontent.com/skulidropek/megapolos-deploy/deploy/deploy.sh | bash
       или, если скрипт скачан:
         bash deploy.sh"
fi

# sudo может отсутствовать (минимальный образ) — он нужен внутренним вызовам
if ! command -v sudo &>/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq 2>/dev/null && apt-get install -y sudo -qq 2>/dev/null || true
fi

INSTALL_DIR="${MEGAPOLOS_DIR:-/opt/megapolos}"   # системный путь, не зависит от $HOME/способа запуска
CORE_DIR="$INSTALL_DIR/megapolos-core"
CORE_REPO="${MEGAPOLOS_CORE_REPO:-https://github.com/skulidropek/megapolos-core.git}"
CORE_BRANCH="${MEGAPOLOS_CORE_BRANCH:-self-signed-certs}"

DB_USER="megapolos"; DB_PASS="pgdata"; DB_NAME="megapolos"; CORE_PORT="5100"
DB_PORT="5432"                                   # реальное значение выберет setup_postgres
PG_CONTAINER="megapolos-postgres"
PG_IMAGE="${MEGAPOLOS_PG_IMAGE:-postgres:17}"   # дамп newpostgresql.sql от pg_dump 18 (нужен PG>=17)

# выбрать свободный TCP-порт начиная с заданного (где никто не слушает на 127.0.0.1)
pick_free_port() {
  local p=${1:-5432}
  while (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null; do exec 3>&- 3<&-; p=$((p+1)); done
  echo "$p"
}

# приложение для авто-деплоя (по умолчанию — Megapolos GUI). Пусто = не деплоить.
GUI_REPO="${MEGAPOLOS_GUI_REPO:-https://gitlab.com/megapolos/megapolos-gui.git}"
# .localhost — браузеры (Edge/Chrome) сами резолвят *.localhost в 127.0.0.1 (без hosts/DNS),
# поэтому любой {app}.megapolos.localhost открывается без правки hosts
GUI_DOMAIN="${MEGAPOLOS_GUI_DOMAIN:-gui.megapolos.localhost}"

# --- 1. системные зависимости (то, без чего ядро не стартует) ---
install_deps() {
  info "Установка системных зависимостей..."
  export DEBIAN_FRONTEND=noninteractive
  # не роняем установку из-за подвисшего зеркала (частичный fail update — индексы пригодны)
  apt-get update -qq || apt-get update -qq || true
  apt-get install -y curl git python3-pip openssl -qq >/dev/null

  if ! node --version 2>/dev/null | grep -q "^v18"; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null
    apt-get install -y nodejs >/dev/null
  fi
  command -v nodemon &>/dev/null || npm install -g nodemon ts-node >/dev/null
  # PostgreSQL ставить через apt НЕ нужно — поднимем свой в Docker (см. setup_postgres)

  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
    command -v docker &>/dev/null || error "Docker не установился"
  fi
  # запуск dockerd
  if [[ -f /.dockerenv ]]; then
    # внутри контейнера свой dockerd ОБЯЗАН быть на vfs (overlay-в-overlay не монтируется)
    mkdir -p /etc/docker
    grep -q '"vfs"' /etc/docker/daemon.json 2>/dev/null || echo '{ "storage-driver": "vfs" }' | tee /etc/docker/daemon.json >/dev/null
    if ! docker info 2>/dev/null | grep -q 'Storage Driver: vfs'; then
      pkill dockerd 2>/dev/null || true; sleep 2
      bash -c 'nohup dockerd > /var/log/dockerd.log 2>&1 &'
      for i in $(seq 1 20); do docker info &>/dev/null && break; sleep 2; done
    fi
  elif grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    # WSL2: Docker Engine ПРЯМО в дистрибутиве (не Docker Desktop), чтобы ядро+контейнеры
    # были в одной сети → host-net nginx виден на localhost дистрибутива, а WSL2
    # пробрасывает его на Windows localhost. systemd в WSL по умолчанию нет → поднимаем
    # dockerd вручную. overlay2 в WSL2 работает (ядро настоящее), vfs не нужен.
    if ! docker info &>/dev/null; then
      # iptables-legacy — частая необходимость для dockerd в WSL2
      update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
      service docker start 2>/dev/null || true
      docker info &>/dev/null || { pkill dockerd 2>/dev/null || true; sleep 2; bash -c 'nohup dockerd > /var/log/dockerd.log 2>&1 &'; }
      for i in $(seq 1 30); do docker info &>/dev/null && break; sleep 2; done
    fi
  else
    docker info &>/dev/null || { service docker start 2>/dev/null || systemctl start docker 2>/dev/null || true; sleep 2; }
  fi
  docker info &>/dev/null || error "dockerd не запустился (WSL: проверь, что Docker Desktop WSL-интеграция выключена и /var/log/dockerd.log)"
  # swarm init с явным --advertise-addr: в WSL у дистрибутива несколько IP (lo + eth0),
  # и без адреса docker swarm init не может выбрать, какой анонсировать.
  # `|| SWARM_IP=` обязательны: под set -euo pipefail неуспешный $() (напр. нет команды ip)
  # иначе убил бы скрипт молча.
  local SWARM_IP=""
  SWARM_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p') || SWARM_IP=""
  [ -n "$SWARM_IP" ] || SWARM_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || SWARM_IP=""
  docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active \
    || docker swarm init ${SWARM_IP:+--advertise-addr "$SWARM_IP"} 2>/dev/null \
    || docker swarm init --advertise-addr eth0 2>/dev/null || true

  # ansible (современный) + python-зависимости (нужны ansible-модулям docker/crypto)
  apt-get install -y ansible -qq >/dev/null 2>&1 || true
  pip3 install --upgrade pip -q 2>/dev/null || true
  # --ignore-installed: не удалять системный (debian) urllib3 2.x (нет RECORD-файла → pip падает)
  pip3 install 'ansible>=9' docker jsondiff cryptography passlib 'requests<2.32' 'urllib3<2' \
    --break-system-packages --ignore-installed -q 2>/dev/null || \
    pip3 install 'ansible>=9' docker jsondiff cryptography passlib 'requests<2.32' 'urllib3<2' --ignore-installed -q 2>/dev/null || true
  ansible-galaxy collection install community.docker community.general community.crypto >/dev/null 2>&1 || true
  success "Зависимости установлены"
}

# --- 2. клонирование ядра ---
clone_core() {
  info "Клонирование megapolos-core ($CORE_BRANCH)..."
  mkdir -p "$INSTALL_DIR"
  # прошлый прогон запускал ядро/bootstrap под sudo → часть файлов (temp/, data/,
  # repositories/) принадлежит root. Заберём владение каталогом, иначе git pull /
  # npm / последующая чистка упрутся в "Permission denied".
  chown -R "$(id -u):$(id -g)" "$INSTALL_DIR" 2>/dev/null || true
  if [[ -d "$CORE_DIR/.git" ]]; then
    git -C "$CORE_DIR" pull --ff-only 2>/dev/null || true
  else
    # форсим удаление через sudo — каталог мог остаться от прошлого sudo-прогона
    # с root-овыми файлами (обычный rm их не возьмёт → git clone упадёт "not empty")
    rm -rf "$CORE_DIR"
    git clone --branch "$CORE_BRANCH" "$CORE_REPO" "$CORE_DIR"
  fi
  success "Ядро склонировано"
}

# --- 3. PostgreSQL (свой контейнер на свободном порту — без конфликта с чужим 5432) ---
setup_postgres() {
  info "Настройка PostgreSQL (Docker)..."
  # уже есть наш контейнер — переиспользуем его (и его порт), не теряя данные
  if docker ps -a --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    docker start "$PG_CONTAINER" >/dev/null 2>&1 || true
    # `|| true` — под pipefail неуспешный docker port убил бы скрипт молча
    DB_PORT=$(docker port "$PG_CONTAINER" 5432/tcp 2>/dev/null | head -1 | sed 's/.*://') || true
    DB_PORT=${DB_PORT:-5432}
  else
    # выбрать свободный порт (если 5432 занят чужим postgres — возьмём 5433/5434/…)
    DB_PORT=$(pick_free_port 5432)
    info "Свободный порт для PostgreSQL: $DB_PORT"
    docker run -d --name "$PG_CONTAINER" --restart unless-stopped \
      -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB="$DB_NAME" \
      -p "127.0.0.1:$DB_PORT:5432" "$PG_IMAGE" >/dev/null \
      || error "не удалось запустить контейнер $PG_CONTAINER"
  fi
  # дождаться готовности РЕАЛЬНЫМ запросом: pg_isready может пройти во время init-рестарта
  # официального образа, после чего следующий psql упадёт. select 1 успешен только когда БД
  # реально принимает подключения.
  local ok=""
  for i in $(seq 1 60); do
    docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "select 1" >/dev/null 2>&1 && { ok=1; break; }
    sleep 1
  done
  [[ -n "$ok" ]] || error "PostgreSQL не поднялся (docker logs $PG_CONTAINER)"
  # схема: грузим, если таблиц ещё нет (покрывает и создание, и переиспользование пустого).
  # `|| true` обязателен: под set -euo pipefail неуспешный psql в $(...) убил бы скрипт молча.
  local tn=0
  tn=$(docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d '[:space:]') || true
  [[ -z "$tn" ]] && tn=0
  if [[ "$tn" -lt 1 ]]; then
    info "Загрузка схемы БД..."
    docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=0 -U "$DB_USER" -d "$DB_NAME" \
      < "$CORE_DIR/install/newpostgresql.sql" >/dev/null 2>&1 || true
  fi
  success "PostgreSQL поднят в Docker на 127.0.0.1:$DB_PORT (контейнер $PG_CONTAINER)"
}

# --- 4. конфиг + npm install ---
configure_core() {
  info "Конфигурация ядра (devMode)..."
  local secret; secret=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)
  cat > "$CORE_DIR/config/config.json" <<EOF
{
  "secret": "$secret",
  "connectionString": "postgres://$DB_USER:$DB_PASS@127.0.0.1:$DB_PORT/$DB_NAME",
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
    npm run bootstrap) || error "install.ts завершился с ошибкой"
  success "Оркестрация Megapolos завершена"

  info "Запуск ядра (megapolos-core)..."
  # лог НЕ в /tmp: на новых Ubuntu fs.protected_regular не даёт писать в чужой файл
  # в sticky-каталоге даже root. Кладём рядом с установкой.
  local CORE_LOG="$INSTALL_DIR/core.log"
  pkill -f "nodemon index.ts" 2>/dev/null || true
  pkill -f "ts-node index.ts" 2>/dev/null || true
  fuser -k ${CORE_PORT}/tcp 2>/dev/null || true
  sleep 3
  nohup bash -c "cd '$CORE_DIR' && nodemon index.ts" > "$CORE_LOG" 2>&1 &
  local t=60
  while [[ $t -gt 0 ]]; do grep -q "Server is running on port" "$CORE_LOG" 2>/dev/null && break; sleep 2; ((t-=2)); done
  grep -q "Server is running on port" "$CORE_LOG" || error "Ядро не запустилось (см. $CORE_LOG)"
  ROOT_TOKEN=$(grep -oP "token: '\K[^']+" "$CORE_LOG" 2>/dev/null | head -1)
  success "Ядро запущено"
}

print_summary() {
  echo ""
  echo -e "${GREEN}====================================================${NC}"
  echo -e "${GREEN}  Megapolos развёрнут (оркестрация через install.ts)${NC}"
  echo -e "${GREEN}====================================================${NC}"
  echo -e "  Backend:  http://localhost:${CORE_PORT}"
  echo -e "  PostgreSQL: 127.0.0.1:${DB_PORT} (контейнер ${PG_CONTAINER})"
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
