# Megapolos — гайд по `deploy.sh`

Тонкий установщик Megapolos для **локальной / dev**-среды. Ставит только то, без чего не
стартует ядро (Node.js 18, PostgreSQL, Docker, Ansible), а **всю остальную оркестрацию
делает сам Megapolos** через `install.ts` (TypeScript, без GraphQL/curl из bash):

```
зависимости → ядро → PostgreSQL → config.json →
install.ts ( нода → INIT → PREPARE FOR CORE → INSTALL REGISTRY → деплой приложения ) →
запуск ядра
```

Режим — `devMode=true`: **локальные self-signed сертификаты** под единым Megapolos Root CA
(без certbot). Certbot/Let's Encrypt включается только при `devMode=false` (прод, реальный домен).

---

## Содержание
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Поднять всё в отдельном Docker-контейнере](#поднять-всё-в-отдельном-docker-контейнере)
- [Сертификаты: что создаётся автоматически](#сертификаты-что-создаётся-автоматически)
- [Что получишь в конце](#что-получишь-в-конце)
- [Настройка через переменные окружения](#настройка-через-переменные-окружения)
- [Доступ к задеплоенному приложению (GUI)](#доступ-к-задеплоенному-приложению-gui)
- [Проверка после установки](#проверка-после-установки)
- [Повторный запуск / переустановка](#повторный-запуск--переустановка)
- [Типичные проблемы](#типичные-проблемы)
- [Связанные скрипты](#связанные-скрипты)

---

## Требования
- **Ubuntu/Debian** (apt), `sudo` с правами root.
- Доступ в интернет.
- Если запускаешь **внутри контейнера** — он должен быть `--privileged` (внутри поднимается
  свой dockerd, docker-in-docker; иначе не соберутся/не задеплоятся образы).
- ~15–25 минут на полный прогон (зависимости + `npm install` + настройка ноды + сборка образа приложения).

> **Требуется root — запускай через `sudo`.** В `devMode` ядро запускает локальный ansible
> под `uid 0` (см. core `Process.ts`) с `become`, поэтому Megapolos должен работать от root.
> Скрипт **не поднимается автоматически**: при запуске не из-под root он завершится с подсказкой
> запустить через `sudo`. Устанавливается в **`/opt/megapolos`** (переопределяется через
> `MEGAPOLOS_DIR`). Всё единообразно root-owned → чистить/удалять через `sudo`.

---

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/skulidropek/megapolos-deploy/deploy/deploy.sh | sudo bash
```

или, если файл уже скачан:

```bash
sudo bash deploy.sh
```

---

## Поднять всё в отдельном Docker-контейнере

Штатный и рекомендуемый для теста сценарий — изолированный `--privileged` контейнер со своим
dockerd, своей БД и своим Megapolos. Хостовый Docker при этом не трогается.

```bash
# 1. создать привилегированный контейнер
docker run -d --name mega --privileged --hostname mega-node ubuntu:22.04 sleep infinity

# 2. поставить curl и скачать скрипт
docker exec mega bash -c "apt-get update -qq && apt-get install -y curl -qq"
docker exec mega bash -c "curl -fsSL https://raw.githubusercontent.com/skulidropek/megapolos-deploy/deploy/deploy.sh -o /deploy.sh"

# 3. запустить detached (не зависит от твоей сессии)
docker exec -d mega bash -c "bash /deploy.sh > /var/log/deploy.log 2>&1"

# 4. следить за прогрессом
docker exec mega tail -f /var/log/deploy.log
```

Важно для контейнера:
- **`--privileged` обязателен.** Скрипт сам переключит вложенный dockerd на `vfs`
  (overlay-в-overlay в DinD не монтируется) — по детекту `/.dockerenv`.
- **Не запускай несколько тяжёлых `--privileged` DinD-прогонов параллельно** — хосту не хватит
  ресурсов и контейнеры упадут (`Exited 255`). Запускай по одному.

---

## PostgreSQL: свой контейнер на свободном порту

Чтобы **не конфликтовать** с уже работающим на хосте PostgreSQL (например, чужим
docker-контейнером, занявшим `5432`), `deploy.sh` поднимает **собственный** PostgreSQL в
Docker:

- выбирает **первый свободный порт** начиная с `5432` (если занят — `5433`, `5434`, …);
- запускает контейнер `megapolos-postgres` (`postgres:14`) с `-p 127.0.0.1:<порт>:5432`,
  ролью/БД `megapolos`/`megapolos` и паролем `pgdata`;
- прописывает выбранный порт в `config.json` (`connectionString`), так что ядро коннектится
  именно к своему postgres;
- при повторном запуске **переиспользует** существующий контейнер и его порт (данные не теряются).

Чужой PostgreSQL на `5432` при этом не трогается. Управление:

```bash
docker logs megapolos-postgres          # логи БД
docker rm -f megapolos-postgres          # снести БД (следующий deploy.sh поднимет заново)
```

> apt-версия PostgreSQL больше не ставится — всё в Docker. Образ можно переопределить через
> `MEGAPOLOS_PG_IMAGE`.

---

## Сертификаты: что создаётся автоматически

При `devMode=true` (а `deploy.sh` ставит именно его) **ничего руками делать не нужно** — вся
цепочка self-signed сертификатов строится сама внутри `install.ts` + ansible:

1. **Ядро генерит единый Megapolos Root CA** один раз — `ensureMegapolosCA()`, кладёт в
   `/opt/megapolos/megapolos-core/data/ca/ca.crt` (+ `ca.key`).
2. При **INIT** ноды этот CA **раздаётся на ноду** (в devMode `runAnsible` инъектит
   `ca_crt`/`ca_key` в данные плейбука — нода НЕ генерит свой CA, использует общий).
3. Сертификаты для ноды/registry и для **домена приложения** подписываются этим CA (`ownca`),
   nginx vhost создаётся автоматически.

То есть никакого certbot и ручных шагов — всё self-signed под одним корневым CA.

Где что лежит:
- **Root CA:** `data/ca/ca.crt` или скачать по `http://localhost:5100/api/ca/download`
- **Доменные/нодовые серты:** на ноде в `/data/nginx/ssl/`

Чтобы домены открывались **без предупреждений браузера** — скачай Root CA и добавь его в
доверенные (система / браузер). Сам деплой и так работает: серты валидны относительно этого CA.

---

## Что получишь в конце

Скрипт печатает итог:

```
Backend:  http://localhost:5100
GUI:      https://gui.megapolos.local
Root CA:  http://localhost:5100/api/ca/download
Token:    <root-токен>
```

- **Backend** — GraphQL/HTTP ядра.
- **Token** — root-токен (нужен для API-запросов; также лежит в `/tmp/megapolos-core.log`).
- **Root CA** — скачай и добавь в доверенные.

---

## Настройка через переменные окружения

Все значения переопределяются перед запуском:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `MEGAPOLOS_DIR` | `/opt/megapolos` | Куда ставить |
| `MEGAPOLOS_CORE_REPO` | `github.com/skulidropek/megapolos-core` | Репозиторий ядра |
| `MEGAPOLOS_CORE_BRANCH` | `self-signed-certs` | Ветка ядра |
| `MEGAPOLOS_GUI_REPO` | `gitlab.com/megapolos/megapolos-gui` | Приложение для авто-деплоя. **Пусто = не деплоить приложение** |
| `MEGAPOLOS_GUI_DOMAIN` | `gui.megapolos.local` | Домен приложения |
| `MEGAPOLOS_PG_IMAGE` | `postgres:14` | Образ для контейнера PostgreSQL |

Примеры:

```bash
# Только ядро, без авто-деплоя GUI:
MEGAPOLOS_GUI_REPO="" bash deploy.sh

# Своё приложение и домен:
MEGAPOLOS_GUI_REPO="https://github.com/me/myapp.git" \
MEGAPOLOS_GUI_DOMAIN="myapp.local" \
bash deploy.sh

# Другая ветка ядра:
MEGAPOLOS_CORE_BRANCH="main" bash deploy.sh
```

> Жёстко зашиты (dev-значения): БД `megapolos/pgdata`, порт ядра `5100`,
> registry `localhost` (`megapolos/megapolos`).

---

## Доступ к задеплоенному приложению (GUI)

`deploy.sh` (в отличие от `setup-production-like.sh`) **не поднимает wildcard-DNS**, поэтому
домен `gui.megapolos.local` сам по себе не резолвится. Варианты:

```bash
# 1. curl с подменой резолва и доверием CA:
curl --cacert /opt/megapolos/megapolos-core/data/ca/ca.crt \
     --resolve gui.megapolos.local:443:127.0.0.1 https://gui.megapolos.local/

# 2. прописать домен в /etc/hosts:
echo "127.0.0.1 gui.megapolos.local" | sudo tee -a /etc/hosts
```

Если нужен полноценный wildcard-DNS + установка CA в системный/Docker trust — это
`setup-production-like.sh`.

---

## Проверка после установки

```bash
# ядро живо:
curl -s http://localhost:5100/api/ca/download -o /dev/null -w "%{http_code}\n"   # 200

# приложение в swarm:
docker service ls                                                                 # …megapolos-gui  1/1

# логи ядра / токен:
grep -a "token:" /tmp/megapolos-core.log
```

---

## Повторный запуск / переустановка

Скрипт частично идемпотентен (ядро `git pull`, БД/роль создаются если нет). Но `configure_core`
**перезаписывает `config.json` новым секретом** при каждом прогоне — это инвалидирует прежний
root-токен. Для чистой переустановки в контейнере проще пересоздать контейнер.

---

## Типичные проблемы

| Симптом | Причина / решение |
|---|---|
| `dockerd не запустился` | Контейнер не `--privileged`. Внутри контейнера он обязателен. |
| Падает на сборке образа / `overlay`-ошибки | dockerd не на `vfs`. В контейнере скрипт ставит `vfs` сам; если демон уже был поднят иначе — убей `dockerd` и дай скрипту перезапустить. |
| Зависает на сборке GUI | Это норма — самый долгий этап (несколько минут). |
| Все контейнеры разом `Exited 255` | Параллельные тяжёлые DinD+vfs прогоны исчерпали ресурсы хоста. Запускай по одному. |
| `gui.megapolos.local` не открывается | `deploy.sh` не поднимает DNS — используй `curl --resolve` или `/etc/hosts` (см. выше). |

---

## Связанные скрипты

| Скрипт | Назначение |
|---|---|
| **`deploy.sh`** | Тонкая dev-установка (этот гайд): self-signed, без DNS/CA-trust. |
| `setup-production-like.sh` | Локально «как прод» **без обходов TLS**: реальный домен + wildcard-DNS (dnsmasq) + единый Root CA в системном и Docker trust. `devMode=true`, без GraphQL из bash. |
| `setup-devmode-false.sh` | Быстрый локальный self-signed через insecure-registry/TLS-bypass (без домена и CA-trust). |

Во всех трёх вся оркестрация (нода, INIT/PREPARE/REGISTRY, деплой приложения) выполняется
самим Megapolos в `install.ts` (`npm run bootstrap`) — никаких GraphQL/curl-вызовов из bash.
