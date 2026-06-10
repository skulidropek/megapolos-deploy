# Megapolos — Руководство по развёртыванию

## Быстрый старт (один скрипт)

```bash
curl -sSL https://gitlab.com/megapolos/megapolos-core/-/raw/main/install/deploy.sh | sudo bash -- --prod --tunnel
```

> Или клонируй этот репозиторий и запусти `deploy.sh` локально — см. раздел [Скрипт deploy.sh](#скрипт-deploysh).

---

## Системные требования

| Компонент | Минимум | Рекомендуется |
|---|---|---|
| ОС | Ubuntu 20.04 / Debian 11 | Ubuntu 22.04 LTS |
| CPU | 1 ядро | 2+ ядра |
| RAM | 1 GB | 2+ GB |
| Диск | 5 GB | 20+ GB |
| Node.js | 18.x | 18.x |
| PostgreSQL | 14+ | 16 |
| Docker | опционально | 24+ (для управления контейнерами) |

---

## Ручная установка (шаг за шагом)

### 1. Установка системных зависимостей

```bash
# Node.js 18 (NodeSource)
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# PostgreSQL 16
sudo apt-get install -y postgresql postgresql-contrib

# nodemon + ts-node (глобально)
sudo npm install -g nodemon ts-node
```

### 2. Клонирование репозиториев

```bash
cd ~
git clone https://gitlab.com/megapolos/megapolos-core.git
git clone https://gitlab.com/megapolos/megapolos-gui.git
```

### 3. Настройка PostgreSQL

```bash
# Запуск сервиса
sudo service postgresql start

# Создание пользователя и базы данных
sudo -u postgres psql -c "CREATE USER megapolos WITH PASSWORD 'pgdata';"
sudo -u postgres psql -c "CREATE DATABASE megapolos OWNER megapolos;"

# Применение схемы
sudo -u postgres psql -d megapolos -f ~/megapolos-core/install/newpostgresql.sql

# Выдача прав (ВАЖНО: без этого сервер упадёт с ошибкой permission denied)
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO megapolos;"
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO megapolos;"
sudo -u postgres psql -d megapolos -c "GRANT ALL PRIVILEGES ON SCHEMA public TO megapolos;"
```

### 4. Конфигурация бэкенда (megapolos-core)

Создай файл `~/megapolos-core/config/config.json`:

```json
{
  "secret": "замени-на-случайную-строку",
  "connectionString": "postgres://megapolos:pgdata@localhost:5432/megapolos",
  "registryHost": "",
  "registryUser": "",
  "registryPassword": "",
  "debug": false,
  "devMode": false,
  "publicSchema": false,
  "allowUnauthorized": false,
  "noRoot": false,
  "catalogUrl": ""
}
```

> **Dev-режим**: установи `devMode: true` и `noRoot: true` для запуска без sudo и с localhost-контейнерами.

### 5. Запуск бэкенда

```bash
cd ~/megapolos-core
npm install

# Dev-режим (с hot-reload)
nodemon index.ts

# Prod-режим (разовый запуск)
sudo ts-node index.ts
```

При первом запуске в консоли появится **root-токен**:
```
[ { name: 'root', token: 'eyJhbG...' } ]
Server is running on port 5100
```

Сохрани этот токен — он нужен для входа в интерфейс.

### 6. Конфигурация фронтенда (megapolos-gui)

```bash
# Для локального доступа
echo '{"server": "http://localhost:5100"}' > ~/megapolos-gui/public/config/config.json

# Если бэкенд доступен по внешнему URL (см. раздел "Внешний доступ")
echo '{"server": "https://your-backend-url"}' > ~/megapolos-gui/public/config/config.json
```

### 7. Запуск фронтенда

```bash
cd ~/megapolos-gui
npm install

# Dev-режим (порт 3000, с hot-reload)
npm run dev

# Prod-режим (собрать и раздать статику)
npm run build
npx serve build -p 3000
```

### 8. Вход в систему

1. Открой `http://localhost:3000` (или внешний URL)
2. Вставь root-токен из шага 5
3. Нажми **LOGIN**

---

## Внешний доступ

### Вариант A: CloudFlare Tunnel (рекомендуется для быстрого старта)

Не требует домена, публичного IP или настройки firewall.

```bash
# Установка cloudflared
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared

# Туннель для бэкенда
cloudflared tunnel --url http://localhost:5100 &
# Скопируй URL вида https://xxx.trycloudflare.com → вставь в config.json фронтенда

# Туннель для фронтенда
cloudflared tunnel --url http://localhost:3000 &
# Открой полученный URL в браузере
```

> ⚠️ Временные туннели (trycloudflare.com) меняют URL при каждом перезапуске.  
> Для постоянного URL нужен [Cloudflare аккаунт с named tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps).

### Вариант B: Nginx Reverse Proxy

```nginx
server {
    listen 80;
    server_name megapolos.yourdomain.com;

    location / {
        proxy_pass http://localhost:3000;
    }

    location /graphql {
        proxy_pass http://localhost:5100;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

---

## Prod-режим через systemd

```bash
# /etc/systemd/system/megapolos-core.service
[Unit]
Description=Megapolos Core
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=/home/megapolos/megapolos-core
ExecStart=/usr/bin/ts-node index.ts
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
```

```bash
# /etc/systemd/system/megapolos-gui.service
[Unit]
Description=Megapolos GUI
After=megapolos-core.service

[Service]
Type=simple
WorkingDirectory=/home/megapolos/megapolos-gui
ExecStart=/usr/bin/npx serve build -p 3000
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now megapolos-core megapolos-gui
```

---

## Troubleshooting

### `permission denied for table user`
```bash
sudo -u postgres psql -d megapolos -c \
  "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO megapolos;"
sudo -u postgres psql -d megapolos -c \
  "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO megapolos;"
```

### `Blocked request` в браузере (Vite)
Добавь в `megapolos-gui/vite.config.ts`:
```ts
server: {
  allowedHosts: true,
}
```

### Фронтенд не подключается к бэкенду (ошибки в Network)
Проблема: браузер отправляет запросы на `localhost:5100` своей машины, а не сервера.  
Решение: укажи внешний URL бэкенда в `config.json` (CloudFlare tunnel или nginx).

### `You must run this app as root`
Установи в `config.json` бэкенда: `"noRoot": true` (для dev) или запускай через `sudo`.

### Токен root не виден в логах
Бэкенд уже запускался — пользователи созданы. Найди токен в БД:
```bash
sudo -u postgres psql -d megapolos -c "SELECT name, token FROM \"user\";"
```

---

## Стратегия One-Click Install

| Вариант | Команда | Когда использовать |
|---|---|---|
| Bash-скрипт | `curl -sSL <url> \| sudo bash` | Linux-серверы, CI/CD |
| npm CLI | `npx megapolos-cli install` | Dev-машины с Node.js |
| Бинарник | `./megapolos-install` | Полная независимость от окружения |
| Docker Compose | `docker compose up` | Изолированная среда |

Текущий рекомендуемый подход для серверов: **bash-скрипт** (`deploy.sh`) в этом репозитории.  
Следующий шаг: npm-пакет `megapolos-cli` на npmjs.com.
