# Гайд по работе с Megapolos

Полный цикл: установка → запуск → деплой контейнера — основан на реальном опыте.

---

## Часть 1 — Установка Megapolos

### 1.1 Что нужно установить

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs

# PostgreSQL
apt-get install -y postgresql postgresql-contrib

# Утилиты для запуска TypeScript-бэкенда
npm install -g nodemon ts-node

# Docker + Docker Swarm (нужен для деплоя контейнеров)
curl -fsSL https://get.docker.com | sh
docker swarm init

# Ansible + Python-зависимости (нужны для docker stack deploy)
apt-get install -y ansible python3-docker python3-jsondiff
ansible-galaxy collection install community.docker
```

> ⚠️ **DEBIAN_FRONTEND=noninteractive** обязателен — иначе `tzdata` зависает на интерактивном вопросе о часовом поясе.

### 1.2 Клонировать репозитории

```bash
git clone https://gitlab.com/megapolos/megapolos-core.git ~/megapolos-core
git clone https://gitlab.com/megapolos/megapolos-gui.git ~/megapolos-gui
```

### 1.3 Настроить PostgreSQL

```bash
service postgresql start

sudo -u postgres psql -c "CREATE USER megapolos WITH PASSWORD 'pgdata';"
sudo -u postgres psql -c "CREATE DATABASE megapolos OWNER megapolos;"

# Применить схему
sudo -u postgres psql -d megapolos -f ~/megapolos-core/install/newpostgresql.sql

# БЕЗ ЭТИХ ГРАНТОВ бэкенд падает с "permission denied for table user"
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO megapolos;"
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO megapolos;"
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON SCHEMA public TO megapolos;"
```

### 1.4 Настроить конфиг бэкенда

Файл `~/megapolos-core/config/config.json`:
```json
{
  "secret": "любая-случайная-строка",
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

> `devMode: true` — запускает контейнеры локально без SSH, использует локальный Docker daemon.

### 1.5 Настроить конфиг фронтенда

```bash
echo '{"server": "http://localhost:5100"}' > ~/megapolos-gui/public/config/config.json
```

> ⚠️ Если доступ через внешний URL (CloudFlare tunnel, nginx) — нужно указать **внешний адрес бэкенда**, иначе браузер будет отправлять GraphQL-запросы на свой localhost.

### 1.6 Установить npm зависимости и запустить

```bash
cd ~/megapolos-core && npm install
cd ~/megapolos-gui && npm install

# Запустить бэкенд (от root — Process.ts использует uid:0)
cd ~/megapolos-core && nodemon index.ts
```

При первом запуске в консоли появится root-токен:
```
[ { name: 'root', token: 'eyJhbG...' } ]
Server is running on port 5100
```

```bash
# Запустить фронтенд (в другом терминале)
cd ~/megapolos-gui && npm run dev
# или с доступом снаружи:
npm run dev -- --host 0.0.0.0
```

### 1.7 Войти в систему

1. Открыть `http://localhost:3000`
2. Вставить root-токен в поле → нажать **LOGIN**

**Если LOGIN не работает** (токен набран, но страница не меняется):
```javascript
// В консоли браузера (F12):
localStorage.setItem('megapolos.token', 'eyJhbG...<твой токен>...');
location.reload();
```

---

## Часть 2 — Внешний доступ (CloudFlare tunnel)

Если сервер внутри Docker-контейнера без публичного IP:

```bash
# Установка cloudflared
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared

# Туннель для бэкенда
cloudflared tunnel --url http://localhost:5100 &
# Скопировать URL вида https://xxx.trycloudflare.com → вставить в public/config/config.json

# Обновить конфиг фронтенда с внешним URL бэкенда
echo '{"server": "https://xxx.trycloudflare.com"}' > ~/megapolos-gui/public/config/config.json

# Туннель для фронтенда
cloudflared tunnel --url http://localhost:3000 &
```

> Также нужно добавить `allowedHosts: true` в `vite.config.ts` фронтенда — иначе Vite блокирует запросы с внешнего домена.

---

## Часть 3 — Деплой приложения через Megapolos UI

Правильный порядок:

```
Репозиторий → Нода → App → Image → Build
→ Configuration → App Version → Instance (из версии) → Update nodes
```

> ⚠️ Инстанс создаётся **на основе App Version**, а не напрямую из образа. Это позволяет версионировать приложения и управлять несколькими инстансами одной версии.

---

### 3.1 Добавить репозиторий

**ПУСК → repositories → ADD REPOSITORY**
- Name: `test-app`
- URL: `/home/dev/test-app` (локальный путь или git URL)
- Type: `local`

> Репозиторий должен содержать `Dockerfile` в корне.

Пример минимального `Dockerfile`:
```dockerfile
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

---

### 3.2 Добавить ноду

**ПУСК → nodes → ADD NODE**
- Name: `localhost`
- Host: `localhost`
- User: `root`
- Password: `root`

> В `devMode` нода использует локальный Docker daemon независимо от поля Host.

---

### 3.3 Создать приложение

**ПУСК → apps → CREATE NEW APP**
- Name: `test-app`
- Description: любая

---

### 3.4 Создать образ

Внутри app → **Images → добавить образ**:
- Name: `test-app`
- Docker image name: `test-app`
- Inner port: `80`
- Repository: выбрать `test-app`

Образ описывает **как собирать и запускать** один контейнер: какой Dockerfile использовать, на каком порту слушать.

---

### 3.5 Собрать образ

Нажать **Build image** (кнопка у образа).

Megapolos запустит `docker build -t test-app:1 .` в директории репозитория.
Статус изменится на **Built**.

Прогресс: **ПУСК → logs** → запись `Build image test-app`.

---

### 3.6 Создать конфигурацию

Внутри app → **ADD CONFIGURATION**
- Name: `default`

Конфигурация описывает **состав сервисов** приложения — какие образы входят в версию, как они взаимодействуют. Один app может иметь несколько конфигураций (например: `default`, `with-redis`, `minimal`).

---

### 3.7 Создать версию приложения

Внутри app → **ADD APP VERSION**
- Version: `1.0.0`
- Configuration: выбрать `default`
- Images: добавить `test-app`

App Version — это **зафиксированный снапшот** конфигурации + набора образов. Инстансы запускаются именно из версий.

---

### 3.8 Создать инстанс из версии

Внутри app → выбрать версию `1.0.0` → **CREATE INSTANCE FROM THIS VERSION**

- Instance name: `test-instance`
- Container:
  - Name: `test-app`
  - Node: `localhost`
  - Outer port: `8080`

> Создание инстанса из версии гарантирует что запускается именно та версия, которая была протестирована. Можно создать несколько инстансов одной версии на разных нодах.

---

### 3.9 Задеплоить контейнер

Нажать **Update nodes** (кнопка у образа внутри app).

Это запускает:
```
Update nodes → Ansible → deploy_swarm_dev_mode.yml → docker stack deploy
```

> ⚠️ **Именно `Update nodes`**, а не `BUILD` или `RESTART` — только эта кнопка реально деплоит контейнер через Ansible.

Прогресс: **ПУСК → logs** → запись `Update node localhost`.

---

### 3.10 Проверить результат

- **ПУСК → nodes → localhost** → раздел Containers → `test-app: running`
- **ПУСК → instances → test-instance** → статус `running`, URL `http://localhost:8080`

```bash
docker service ls          # показывает запущенный Swarm-сервис
curl http://localhost:8080  # ответ из контейнера
```

---

### Схема зависимостей

```
App
├── Image (test-app) ──── Repository (test-app)
│     └── [Build image]
├── Configuration (default)
│     └── App Version (1.0.0) ──── Image (test-app)
│           └── [CREATE INSTANCE FROM THIS VERSION]
│                 └── Instance (test-instance)
│                       └── Container → Node (localhost) → port 8080
│                             └── [Update nodes] → docker stack deploy
```

---

## Часть 4 — Доступ к контейнеру изнутри Docker

Если Megapolos запущен внутри Docker-контейнера, порт `8080` опубликован на хост-машине (`0.0.0.0:8080->80/tcp`), но `localhost:8080` изнутри контейнера недоступен.

**Как найти IP хост-машины:**
```python
with open('/proc/net/route') as f:
    for line in f:
        parts = line.split()
        if parts[1] == '00000000':  # default route
            gw = int(parts[2], 16)
            print(f'{gw&0xff}.{(gw>>8)&0xff}.{(gw>>16)&0xff}.{(gw>>24)&0xff}')
# → обычно 172.17.0.1
```

```bash
curl http://172.17.0.1:8080                      # работает через docker bridge gateway
cloudflared tunnel --url http://172.17.0.1:8080  # туннель для внешнего доступа
```

---

## Часть 5 — Troubleshooting

| Ошибка | Причина | Решение |
|---|---|---|
| `tzdata` зависает при установке | нет `DEBIAN_FRONTEND=noninteractive` | Добавить перед `apt-get` |
| `permission denied for table user` | нет GRANT на таблицы | Выдать гранты (см. 1.3) |
| `spawn EPERM` при сборке образа | нет прав root | Запускать бэкенд через `sudo` |
| `jsondiff is not installed` | нет Python-пакета | `apt install python3-jsondiff` |
| `No module named 'docker'` | нет Python-пакета | `apt install python3-docker` |
| `Blocked request` в браузере | Vite блокирует внешний домен | Добавить `allowedHosts: true` в `vite.config.ts` |
| LOGIN не работает | `localStorage.megapolos.token = ""` | Установить токен через консоль браузера (F12) |
| `localhost:8080` недоступен внутри Docker | Swarm порты привязаны к хосту | Использовать `172.17.0.1:8080` (docker bridge gateway) |
| Нода показывает "node is down" в списке | Баг отображения UI | Открыть детали ноды — там статус `running` |

---

## Быстрый старт одной командой

```bash
curl -sSL https://raw.githubusercontent.com/skulidropek/megapolos-deploy/deploy/deploy.sh \
  | sudo bash -- --dev
```

Скрипт устанавливает всё автоматически и выводит root-токен и URL.
