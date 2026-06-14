# Megapolos на Windows (через WSL2) — пошагово

Запуск Megapolos на Windows идёт **внутри WSL2 Ubuntu** с **Docker Engine прямо в дистрибутиве**
(не через Docker Desktop). Так ядро и контейнеры в одной сети, а WSL2 пробрасывает порты на
Windows `localhost` — и GUI открывается в обычном браузере Windows.

> Почему не Docker Desktop: его контейнеры живут в отдельной VM, и nginx с host-network там
> недостижим из твоего Ubuntu-дистрибутива. Поэтому используем dockerd **в самом дистрибутиве**.

---

## Шаг 1. Поставить Ubuntu в WSL2 (один раз)

В PowerShell (от администратора):
```powershell
wsl --install -d Ubuntu
```
- Если WSL ещё не стоял — после установки потребуется перезагрузка.
- При первом запуске Ubuntu попросит придумать **имя пользователя и пароль** (это твой `sudo`-пароль).
- Проверка: `wsl -l -v` → в списке есть `Ubuntu`, версия `2`.

> Не используй дистрибутив `docker-desktop` (он служебный). Нужен именно `Ubuntu`.

## Шаг 2. Отключить WSL-интеграцию Docker Desktop (один раз)

Docker Desktop → **Settings → Resources → WSL Integration** → **выключить** тумблер у `Ubuntu`
→ **Apply & Restart**.

(Можно вообще не запускать Docker Desktop — Docker мы ставим внутри Ubuntu.)

## Шаг 3. Войти в Ubuntu

```powershell
wsl -d Ubuntu
```
Промпт должен стать вида `username@machine:~$` (обычный bash).

## Шаг 4. Запустить установку

В Ubuntu:
```bash
# чистка прошлых попыток (если были) — ошибки про docker можно игнорировать
sudo rm -rf /opt/megapolos /data/nginx /data/registry /data/swarm 2>/dev/null

# установка (сама поставит Docker Engine, PostgreSQL-в-докере, ядро и развернёт GUI)
curl -fsSL https://raw.githubusercontent.com/skulidropek/megapolos-deploy/deploy/deploy.sh | sudo bash
```
Прогон занимает ~15–25 минут (зависимости + сборка образа GUI). В конце выведет URL и `Token`.

## Шаг 5. Проверить, что всё поднялось (в Ubuntu)

```bash
docker info --format 'Server {{.ServerVersion}}'                       # отвечает (dockerd в дистрибутиве)
docker ps --filter name=nginx --format '{{.Names}} {{.Status}}'        # nginx ... Up
docker service ls                                                       # megapolos_megapolos-gui ... 1/1
curl -sk -o /dev/null -w "nginx443: %{http_code}\n" https://127.0.0.1:443/   # НЕ 000
```

## Шаг 6. Доверить сертификат в Windows (один раз)

Megapolos выдаёт self-signed сертификаты под единым **Megapolos Root CA**. Чтобы браузер не ругался:
1. Скачать CA (в Windows-браузере): `http://localhost:5100/api/ca/download`
2. `Win+R` → `certmgr.msc` → **Доверенные корневые центры сертификации → Сертификаты** →
   ПКМ → **Все задачи → Импорт** → выбрать скачанный `megapolos-root-ca.crt`.

## Шаг 7. Открыть GUI в браузере Windows

```
https://gui.megapolos.localhost
```
Домен `*.megapolos.localhost` браузер (Edge/Chrome) резолвит в `127.0.0.1` **сам** — править
`hosts` НЕ нужно. Любой задеплоенный контейнер с доменом `{имя}.megapolos.localhost` так же
откроется без настройки DNS.

---

## Что куда установилось
- **Ядро (backend):** процесс в Ubuntu, `http://localhost:5100` (и `Token` в выводе / `/opt/megapolos/core.log`).
- **PostgreSQL:** контейнер `megapolos-postgres` (`postgres:17`) на `127.0.0.1:<свободный порт>`.
- **nginx / registry:** контейнеры в Ubuntu-докере; nginx слушает `:443` (проброшен на Windows localhost).
- **Root CA:** `/opt/megapolos/megapolos-core/data/ca/ca.crt` или `http://localhost:5100/api/ca/download`.

## Переустановка начисто
```bash
docker rm -f $(docker ps -aq) 2>/dev/null          # снести все контейнеры
sudo rm -rf /opt/megapolos /data/nginx /data/registry /data/swarm
curl -fsSL https://raw.githubusercontent.com/skulidropek/megapolos-deploy/deploy/deploy.sh | sudo bash
```

## Если что-то не так

| Симптом | Что делать |
|---|---|
| `dockerd не запустился` | Проверь, что WSL-интеграция Docker Desktop **выключена** (Шаг 2). Смотри `/var/log/dockerd.log`. Иногда нужно `sudo update-alternatives --set iptables /usr/sbin/iptables-legacy` и повторить. |
| `curl ... \| bash` → `curl: not found` / `sudo: not found` | Ты в дистрибутиве `docker-desktop`, а не в `Ubuntu`. Зайди `wsl -d Ubuntu`. |
| `DNS_PROBE_FINISHED_NXDOMAIN` в браузере | Домен должен быть на `.localhost` (напр. `gui.megapolos.localhost`), а не `.local`. `.local` браузер сам не резолвит. |
| `nginx443: 000` при `nginx Up` | dockerd не в дистрибутиве (всё ещё Docker Desktop) — проверь Шаг 2 и `docker info` (Server должен быть локальный). |
| Красный замок в браузере | Импортируй Root CA (Шаг 6). |
| После перезагрузки Windows не работает | `dockerd` поднят через nohup и не переживает ребут — просто запусти deploy.sh снова (он переиспользует данные). |

> Полный разбор флагов и переменных окружения — в [README.md](README.md).
