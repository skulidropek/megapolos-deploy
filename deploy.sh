#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Megapolos Deploy Script
# Usage:
#   ./deploy.sh --dev              # dev mode (nodemon + vite)
#   ./deploy.sh --prod             # prod mode (systemd services)
#   ./deploy.sh --dev --tunnel     # dev + cloudflare tunnels
#   ./deploy.sh --prod --tunnel    # prod + cloudflare tunnels
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Parse args ---
MODE=""
TUNNEL=false

for arg in "$@"; do
  case $arg in
    --dev)    MODE="dev" ;;
    --prod)   MODE="prod" ;;
    --tunnel) TUNNEL=true ;;
    --help|-h)
      echo "Usage: $0 [--dev|--prod] [--tunnel]"
      exit 0
      ;;
    *) error "Unknown argument: $arg" ;;
  esac
done

[[ -z "$MODE" ]] && error "Specify --dev or --prod"

INSTALL_DIR="${MEGAPOLOS_DIR:-$HOME/megapolos}"
CORE_DIR="$INSTALL_DIR/megapolos-core"
GUI_DIR="$INSTALL_DIR/megapolos-gui"

DB_USER="megapolos"
DB_PASS="pgdata"
DB_NAME="megapolos"
DB_PORT="5432"
CORE_PORT="5100"
GUI_PORT="3000"

SECRET=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32 || true)

# Detect if running inside a Docker container
IN_DOCKER=false
if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
  IN_DOCKER=true
fi

# =============================================================================
# 1. Detect OS
# =============================================================================
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  else
    OS_ID="unknown"
  fi

  if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
  elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
  elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
  else
    error "Unsupported package manager. This script supports apt, dnf, yum."
  fi

  info "OS: $OS_ID, package manager: $PKG_MANAGER, in_docker: $IN_DOCKER"
}

# =============================================================================
# 2. Install system dependencies
# =============================================================================
install_deps() {
  info "Installing system dependencies..."

  if [[ "$PKG_MANAGER" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get update -qq

    # Node.js 18 via NodeSource
    if ! node --version 2>/dev/null | grep -q "^v18"; then
      info "Installing Node.js 18..."
      curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - >/dev/null
      sudo -E apt-get install -y nodejs >/dev/null
    fi

    # PostgreSQL
    if ! command -v psql &>/dev/null; then
      info "Installing PostgreSQL..."
      sudo -E apt-get install -y postgresql postgresql-contrib >/dev/null
    fi

    # Git, curl
    sudo -E apt-get install -y git curl >/dev/null

  elif [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]]; then
    # Node.js 18
    if ! node --version 2>/dev/null | grep -q "^v18"; then
      info "Installing Node.js 18..."
      curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash - >/dev/null
      sudo $PKG_MANAGER install -y nodejs >/dev/null
    fi

    # PostgreSQL
    if ! command -v psql &>/dev/null; then
      info "Installing PostgreSQL..."
      sudo $PKG_MANAGER install -y postgresql-server postgresql-contrib >/dev/null
      sudo postgresql-setup --initdb 2>/dev/null || true
    fi

    sudo $PKG_MANAGER install -y git curl >/dev/null
  fi

  # nodemon + ts-node globally
  if ! command -v nodemon &>/dev/null; then
    info "Installing nodemon and ts-node globally..."
    sudo npm install -g nodemon ts-node >/dev/null
  fi

  success "Dependencies installed"
}

# =============================================================================
# 3. Clone repositories
# =============================================================================
clone_repos() {
  info "Cloning repositories to $INSTALL_DIR..."
  mkdir -p "$INSTALL_DIR"

  if [[ ! -d "$CORE_DIR/.git" ]]; then
    git clone https://gitlab.com/megapolos/megapolos-core.git "$CORE_DIR"
  else
    info "megapolos-core already cloned, pulling latest..."
    git -C "$CORE_DIR" pull --ff-only
  fi

  if [[ ! -d "$GUI_DIR/.git" ]]; then
    git clone https://gitlab.com/megapolos/megapolos-gui.git "$GUI_DIR"
  else
    info "megapolos-gui already cloned, pulling latest..."
    git -C "$GUI_DIR" pull --ff-only
  fi

  success "Repositories ready"
}

# =============================================================================
# 4. Setup PostgreSQL
# =============================================================================
start_postgres() {
  # Try different methods to start PostgreSQL
  if command -v pg_ctlcluster &>/dev/null; then
    PG_VERSION=$(pg_lsclusters -h | awk '{print $1}' | head -1)
    PG_CLUSTER=$(pg_lsclusters -h | awk '{print $2}' | head -1)
    sudo pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" start 2>/dev/null || true
  elif command -v systemctl &>/dev/null && ! $IN_DOCKER; then
    sudo systemctl start postgresql 2>/dev/null || true
  else
    # Inside Docker or no systemd — start directly
    if command -v pg_lsclusters &>/dev/null; then
      PG_VERSION=$(pg_lsclusters -h | awk '{print $1}' | head -1)
      PG_CLUSTER=$(pg_lsclusters -h | awk '{print $2}' | head -1)
      sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_ctl \
        start -D /var/lib/postgresql/$PG_VERSION/$PG_CLUSTER \
        -l /var/log/postgresql/postgres.log 2>/dev/null || true
    fi
  fi

  # Also try service command as fallback
  sudo service postgresql start 2>/dev/null || true
  sleep 3
}

setup_postgres() {
  info "Starting PostgreSQL..."
  start_postgres

  # Create user if not exists
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null | grep -q 1; then
    info "Creating DB user '$DB_USER'..."
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
  fi

  # Create database if not exists
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q 1; then
    info "Creating database '$DB_NAME'..."
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || true
  fi

  # Apply schema
  info "Applying database schema..."
  cp "$CORE_DIR/install/newpostgresql.sql" /tmp/megapolos_schema.sql
  sudo -u postgres psql -d "$DB_NAME" -f /tmp/megapolos_schema.sql 2>/dev/null || true
  rm -f /tmp/megapolos_schema.sql

  # Grant privileges
  info "Granting privileges..."
  sudo -u postgres psql -d "$DB_NAME" -c \
    "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;" 2>/dev/null || true
  sudo -u postgres psql -d "$DB_NAME" -c \
    "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;" 2>/dev/null || true
  sudo -u postgres psql -d "$DB_NAME" -c \
    "GRANT ALL PRIVILEGES ON SCHEMA public TO $DB_USER;" 2>/dev/null || true

  success "PostgreSQL configured"
}

# =============================================================================
# 5. Configure megapolos-core
# =============================================================================
configure_core() {
  info "Configuring megapolos-core..."

  local NO_ROOT="false"
  local DEV_MODE="false"
  [[ "$MODE" == "dev" ]] && NO_ROOT="true" && DEV_MODE="true"

  cat > "$CORE_DIR/config/config.json" <<EOF
{
  "secret": "$SECRET",
  "connectionString": "postgres://$DB_USER:$DB_PASS@localhost:$DB_PORT/$DB_NAME",
  "registryHost": "",
  "registryUser": "",
  "registryPassword": "",
  "debug": false,
  "devMode": $DEV_MODE,
  "publicSchema": false,
  "allowUnauthorized": false,
  "noRoot": $NO_ROOT,
  "catalogUrl": ""
}
EOF

  success "Core config written"
}

# =============================================================================
# 6. Install npm dependencies
# =============================================================================
install_npm() {
  info "Installing npm dependencies for megapolos-core..."
  (cd "$CORE_DIR" && npm install --silent)

  info "Installing npm dependencies for megapolos-gui..."
  (cd "$GUI_DIR" && npm install --silent)

  success "npm dependencies installed"
}

# =============================================================================
# 7. Configure GUI
# =============================================================================
configure_gui() {
  local backend_url="http://localhost:$CORE_PORT"
  echo "{\"server\": \"$backend_url\"}" > "$GUI_DIR/public/config/config.json"
  success "GUI config written (server: $backend_url)"
}

# =============================================================================
# 8. CloudFlare tunnel
# =============================================================================
setup_tunnel() {
  info "Setting up CloudFlare tunnels..."

  if ! command -v cloudflared &>/dev/null; then
    info "Downloading cloudflared..."
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /tmp/cloudflared
    sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
    sudo chmod +x /usr/local/bin/cloudflared
  fi

  # Backend tunnel
  cloudflared tunnel --url "http://localhost:$CORE_PORT" \
    > /tmp/cf-backend.log 2>&1 &
  echo $! > /tmp/cf-backend.pid

  local backend_url=""
  for i in $(seq 1 15); do
    backend_url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf-backend.log 2>/dev/null | head -1 || true)
    [[ -n "$backend_url" ]] && break
    sleep 1
  done
  [[ -z "$backend_url" ]] && error "CloudFlare backend tunnel failed to start"

  echo "{\"server\": \"$backend_url\"}" > "$GUI_DIR/public/config/config.json"
  success "Backend tunnel: $backend_url"

  # Frontend tunnel
  cloudflared tunnel --url "http://localhost:$GUI_PORT" \
    > /tmp/cf-frontend.log 2>&1 &
  echo $! > /tmp/cf-frontend.pid

  local frontend_url=""
  for i in $(seq 1 15); do
    frontend_url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf-frontend.log 2>/dev/null | head -1 || true)
    [[ -n "$frontend_url" ]] && break
    sleep 1
  done
  [[ -z "$frontend_url" ]] && error "CloudFlare frontend tunnel failed to start"

  success "Frontend tunnel: $frontend_url"

  TUNNEL_BACKEND_URL="$backend_url"
  TUNNEL_FRONTEND_URL="$frontend_url"
}

# =============================================================================
# 9a. Start in dev mode
# =============================================================================
start_dev() {
  info "Starting in DEV mode..."

  # Core
  nohup bash -c "cd '$CORE_DIR' && nodemon index.ts" \
    > /tmp/megapolos-core.log 2>&1 &
  echo $! > /tmp/megapolos-core.pid
  info "Core started (PID $(cat /tmp/megapolos-core.pid))"

  # Wait for core to start and extract token
  local token=""
  info "Waiting for core to start..."
  for i in $(seq 1 30); do
    token=$(grep -oP "token: '\K[^']+" /tmp/megapolos-core.log 2>/dev/null | head -1 || true)
    [[ -n "$token" ]] && break
    sleep 1
  done

  # GUI
  nohup bash -c "cd '$GUI_DIR' && npm run dev -- --open false" \
    > /tmp/megapolos-gui.log 2>&1 &
  echo $! > /tmp/megapolos-gui.pid
  info "GUI started (PID $(cat /tmp/megapolos-gui.pid))"

  ROOT_TOKEN="$token"
}

# =============================================================================
# 9b. Start in prod mode (systemd)
# =============================================================================
start_prod() {
  if $IN_DOCKER; then
    warn "Running inside Docker — using dev mode for services (systemd not available)"
    start_dev
    return
  fi

  info "Setting up systemd services..."

  # Build GUI
  info "Building GUI..."
  (cd "$GUI_DIR" && npm run build --silent)

  if ! command -v serve &>/dev/null; then
    sudo npm install -g serve >/dev/null
  fi

  sudo tee /etc/systemd/system/megapolos-core.service > /dev/null <<EOF
[Unit]
Description=Megapolos Core
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=$CORE_DIR
ExecStart=$(which ts-node) index.ts
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  sudo tee /etc/systemd/system/megapolos-gui.service > /dev/null <<EOF
[Unit]
Description=Megapolos GUI
After=megapolos-core.service

[Service]
Type=simple
WorkingDirectory=$GUI_DIR
ExecStart=$(which serve) build -p $GUI_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now megapolos-core megapolos-gui

  local token=""
  info "Waiting for core to start..."
  for i in $(seq 1 30); do
    token=$(sudo journalctl -u megapolos-core -n 50 --no-pager 2>/dev/null \
      | grep -oP "token: '\K[^']+" | head -1 || true)
    [[ -n "$token" ]] && break
    sleep 1
  done

  ROOT_TOKEN="$token"
  success "systemd services enabled and started"
}

# =============================================================================
# 10. Print summary
# =============================================================================
print_summary() {
  echo ""
  echo -e "${GREEN}=====================================================${NC}"
  echo -e "${GREEN}  Megapolos deployed successfully!${NC}"
  echo -e "${GREEN}=====================================================${NC}"
  echo ""
  echo -e "  Mode:    ${BLUE}$MODE${NC}"
  echo ""

  if [[ "$TUNNEL" == "true" ]]; then
    echo -e "  Frontend: ${BLUE}${TUNNEL_FRONTEND_URL:-http://localhost:$GUI_PORT}${NC}"
    echo -e "  Backend:  ${BLUE}${TUNNEL_BACKEND_URL:-http://localhost:$CORE_PORT}${NC}"
  else
    echo -e "  Frontend: ${BLUE}http://localhost:$GUI_PORT${NC}"
    echo -e "  Backend:  ${BLUE}http://localhost:$CORE_PORT${NC}"
  fi

  echo ""
  if [[ -n "${ROOT_TOKEN:-}" ]]; then
    echo -e "  Root token (для входа):"
    echo -e "  ${YELLOW}$ROOT_TOKEN${NC}"
  else
    echo -e "  ${YELLOW}Токен не найден автоматически.${NC}"
    echo -e "  Найди его в логах:"
    if [[ "$MODE" == "dev" ]] || $IN_DOCKER; then
      echo -e "    cat /tmp/megapolos-core.log | grep token"
    else
      echo -e "    sudo journalctl -u megapolos-core | grep token"
    fi
    echo -e "  Или в БД:"
    echo -e "    sudo -u postgres psql -d $DB_NAME -c 'SELECT name, token FROM \"user\";'"
  fi

  echo ""
  echo -e "  Логи:"
  echo -e "    Core: tail -f /tmp/megapolos-core.log"
  echo -e "    GUI:  tail -f /tmp/megapolos-gui.log"
  echo ""
  echo -e "${GREEN}=====================================================${NC}"
}

# =============================================================================
# Main
# =============================================================================
ROOT_TOKEN=""
TUNNEL_BACKEND_URL=""
TUNNEL_FRONTEND_URL=""

detect_os
install_deps
clone_repos
setup_postgres
configure_core
install_npm
configure_gui

if [[ "$MODE" == "dev" ]] || $IN_DOCKER; then
  start_dev
else
  start_prod
fi

if [[ "$TUNNEL" == "true" ]]; then
  sleep 3
  setup_tunnel
fi

print_summary
