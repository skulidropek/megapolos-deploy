# Megapolos — Руководство по развёртыванию

## Быстрый старт (один скрипт)

```bash
curl -sSL https://raw.githubusercontent.com/skulidropek/megapolos-deploy/deploy/deploy.sh \
  | sudo bash -- --dev
```

> Скрипт устанавливает всё необходимое и выводит URL + root-токен для входа.

---

## Что устанавливает скрипт

| Компонент | Зачем нужен |
|---|---|
| Node.js 18 | Запуск megapolos-core и megapolos-gui |
| PostgreSQL | База данных |
| nodemon + ts-node | Запуск TypeScript-бэкенда |
| Docker | Билд и запуск контейнеров |
| Docker Swarm | Оркестрация (`docker stack deploy`) |
| Ansible | Деплой через плейбуки (`deploy_swarm_dev_mode.yml`) |
| python3-docker | Нужен Ansible-модулю community.docker |
| python3-jsondiff | Нужен Ansible-модулю docker_stack |
| community.docker | Ansible-коллекция с модулями docker_stack, docker_swarm |

---

## Системные требования

| | Минимум | Рекомендуется |
|---|---|---|
| ОС | Ubuntu 20.04 / Debian 11 | Ubuntu 22.04 LTS |
| RAM | 1 GB | 2+ GB |
| Диск | 10 GB | 20+ GB |
| Node.js | 18.x | 18.x |
| PostgreSQL | 14+ | 16 |

---

## Ручная установка (шаг за шагом)

### 1. Системные зависимости

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs

# PostgreSQL
apt-get install -y postgresql postgresql-contrib

# Утилиты
apt-get install -y git curl

# nodemon + ts-node
npm install -g nodemon ts-node

# Docker
curl -fsSL https://get.docker.com | sh

# Ansible + Python зависимости для Docker-деплоя
apt-get install -y ansible python3-docker python3-jsondiff

# Ansible-коллекция community.docker
ansible-galaxy collection install community.docker
```

### 2. Docker Swarm

Megapolos деплоит контейнеры через Docker Swarm (`docker stack deploy`):

```bash
docker swarm init
```

> Если уже в swarm-кластере — пропустить.

### 3. Клонирование репозиториев

```bash
cd ~
git clone https://gitlab.com/megapolos/megapolos-core.git
git clone https://gitlab.com/megapolos/megapolos-gui.git
```

### 4. Настройка PostgreSQL

```bash
service postgresql start

sudo -u postgres psql -c "CREATE USER megapolos WITH PASSWORD 'pgdata';"
sudo -u postgres psql -c "CREATE DATABASE megapolos OWNER megapolos;"

# Применить схему
sudo -u postgres psql -d megapolos -f ~/megapolos-core/install/newpostgresql.sql

# ВАЖНО: без этих грантов бэкенд падает с "permission denied for table user"
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO megapolos;"
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO megapolos;"
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON SCHEMA public TO megapolos;"
```

### 5. Конфигурация бэкенда

Создать `~/megapolos-core/config/config.json`:

```json
{
  "secret": "замени-на-случайную-строку",
  "connectionString": "postgres://megapolos:pgdata@localhost:5432/megapolos",
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
```

> **devMode: true** — запускает контейнеры локально без SSH, использует локальный Docker daemon.  
> **noRoot: true** — позволяет запускать без sudo (только для dev).

### 6. Конфигурация фронтенда

```bash
echo '{"server": "http://localhost:5100"}' > ~/megapolos-gui/public/config/config.json
```

> Если доступ с внешнего URL (CloudFlare tunnel, nginx) — указать внешний адрес бэкенда.  
> Иначе браузер будет обращаться к `localhost:5100` своей машины, а не сервера.

### 7. Запуск

```bash
# Установить зависимости
cd ~/megapolos-core && npm install
cd ~/megapolos-gui && npm install

# Запустить бэкенд (нужен root для Process.ts uid:0)
cd ~/megapolos-core && sudo nodemon index.ts
```

При первом запуске в консоли появится **root-токен**:
```
[ { name: 'root', token: 'eyJhbG...' } ]
Server is running on port 5100
```

```bash
# Запустить фронтенд (в другом терминале)
cd ~/megapolos-gui && npm run dev
```

### 8. Вход в систему

1. Открыть `http://localhost:3000`
2. Вставить root-токен из консоли
3. Нажать **LOGIN**

---

## Полный цикл: создание и запуск приложения

После того как Megapolos запущен, для деплоя контейнера нужно:

### Шаг 1 — Добавить репозиторий

Через GUI: ПУСК → Code and applications → Repositories → Add Repository  
Или через GraphQL:

```graphql
mutation {
  createRepository(values: {
    name: "my-app"
    url: "/path/to/repo"   # или git URL для remote
    repositoryType: "local" # "local" или "remote"
  }) { id }
}
```

> Репозиторий должен содержать `Dockerfile` в корне.

### Шаг 2 — Создать ноду

Через GUI: ПУСК → Nodes and instances → Nodes → Add node  
Или через GraphQL:

```graphql
mutation {
  createNode(values: { name: "localhost", host: "localhost", user: "root", password: "root" }) { id }
}
```

> В **devMode** нода всегда использует локальный Docker, независимо от `host`.  
> Бэкенд **должен запускаться от root** — процессы внутри `Process.ts` выполняются с `uid: 0`.

### Шаг 3 — Создать приложение

```graphql
mutation {
  installApp(input: { name: "my-app", description: "My Application" })
}
```

### Шаг 4 — Создать образ

```graphql
mutation {
  createImage(values: {
    name: "my-app"
    image: "my-app"          # имя Docker-образа
    innerPort: 80            # порт внутри контейнера
    buildNumber: 1
    app: "<APP_ID>"
    repository: "<REPO_ID>"  # репозиторий с Dockerfile
  }) { id }
}
```

### Шаг 5 — Собрать образ

```graphql
mutation {
  buildImage(imageId: "<IMAGE_ID>")
}
```

Megapolos запускает `docker build -t my-app:1 .` в директории репозитория.  
В devMode образ не пушится в registry.

### Шаг 6 — Создать конфигурацию и версию

```graphql
mutation {
  createConfiguration(appId: "<APP_ID>", configurationData: { name: "default", services: [] }) { id }
}

mutation {
  createAppVersion(
    appVersionData: { app: "<APP_ID>", configuration: "<CONF_ID>", buildNumber: 1, version: "1.0.0" }
    images: [{ imageId: "<IMAGE_ID>" }]
  ) { id }
}
```

### Шаг 7 — Создать и запустить инстанс

```graphql
mutation {
  createConfiguratedInstance(
    appVersionId: "<VERSION_ID>"
    instanceData: {
      name: "my-instance"
      containers: [{
        name: "my-app"
        role: "app"
        node: "<NODE_ID>"
        image: "<IMAGE_ID>"
        outerPort: 8080
        volumes: []
        dbs: []
        envs: []
      }]
    }
  ) { id }
}
```

### Шаг 8 — Деплоить контейнер

```graphql
# Это запускает Ansible → docker stack deploy
mutation {
  updateNodesOfImage(imageId: "<IMAGE_ID>")
}
```

> Именно `updateNodesOfImage`, а **не** `startAppInstance` — последний только меняет статус в БД.  
> Под капотом запускается: `ansible-playbook deploy_swarm_dev_mode.yml`  
> Что создаёт Docker Swarm service и запускает контейнер.

---

## Внешний доступ

### CloudFlare Tunnel (рекомендуется для быстрого старта)

```bash
# Установка
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared

# Туннель для бэкенда — скопировать URL и вставить в config.json GUI
cloudflared tunnel --url http://localhost:5100 &

# Туннель для фронтенда
cloudflared tunnel --url http://localhost:3000 &
```

> ⚠️ При доступе с внешнего URL браузер отправляет GraphQL-запросы к `server` из `config.json`.  
> Если там `http://localhost:5100` — запросы идут на localhost пользователя, а не сервера.  
> Нужно указать внешний URL бэкенда.

### Vite allowedHosts

При доступе через внешний URL Vite блокирует запросы. Добавить в `megapolos-gui/vite.config.ts`:

```typescript
server: {
  allowedHosts: true,
}
```

---

## Prod-режим (systemd)

```bash
./deploy.sh --prod
```

Создаёт и включает:
- `/etc/systemd/system/megapolos-core.service`
- `/etc/systemd/system/megapolos-gui.service`

```bash
# Управление
sudo systemctl status megapolos-core megapolos-gui
sudo journalctl -u megapolos-core -f
```

---

## Troubleshooting

### `permission denied for table user`
```bash
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO megapolos;"
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO megapolos;"
```

### `spawn EPERM` при сборке образа
Бэкенд запускает команды с `uid: 0`. Нужен запуск от root:
```bash
sudo nodemon index.ts
```

### `jsondiff is not installed` (Ansible)
```bash
sudo apt-get install -y python3-jsondiff
# или
python3 -m pip install jsondiff --break-system-packages
```

### `No module named 'docker'` (Ansible)
```bash
sudo apt-get install -y python3-docker
```

### `Blocked request` в браузере (Vite)
Добавить `allowedHosts: true` в `vite.config.ts` (см. раздел выше).

### Браузер не подключается к бэкенду (Network error)
Проверить `public/config/config.json` — `server` должен быть внешним URL при доступе не с localhost.

### Токен root не появился в логах
Бэкенд уже запускался — пользователь создан. Найти токен в БД:
```bash
sudo -u postgres psql -d megapolos -c 'SELECT name, token FROM "user";'
```

### Docker Swarm not initialized
```bash
docker swarm init
```

---

## Флаги скрипта

```bash
./deploy.sh --dev              # Dev-режим: nodemon + vite dev server
./deploy.sh --prod             # Prod-режим: systemd services + built frontend
./deploy.sh --dev --tunnel     # Dev + CloudFlare tunnels (внешний доступ)
./deploy.sh --prod --tunnel    # Prod + CloudFlare tunnels
```

Переменные окружения:
```bash
MEGAPOLOS_DIR=/opt/megapolos ./deploy.sh --dev   # установить в другую директорию
```
