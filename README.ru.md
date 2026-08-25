[English](README.md) | Русский

# Развёртывание Voxhold

Файлы для production-развёртывания Voxhold из опубликованных контейнерных
образов. Исходный код backend и frontend на сервере не требуется.

## Поддерживаемая платформа

Скрипты развёртывания поддерживают **только Linux-серверы** (`linux/amd64` и
`linux/arm64`). Docker Desktop на Windows и macOS не является поддерживаемой
production-платформой. Клиенты Voxhold при этом могут работать на любых
платформах, которые поддерживает конкретный клиент.

Необходимое ПО:

- Docker Engine;
- Docker Compose v2;
- `curl` и `tar` для установки через bootstrap.

## Установка одной командой без Git

В каталоге, где должен появиться Voxhold, выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/LoonEman1/voxhold-deploy/main/bootstrap.sh | bash
```

Bootstrap скачает snapshot репозитория в `./voxhold-deploy`, проверит наличие
обязательных файлов и откроет интерактивный установщик. Git не используется.
Целевой каталог не должен существовать заранее.

Если оставить пароль владельца пустым, установщик сгенерирует его при первом
bootstrap и напечатает в итоговом блоке установки. Сразу сохраните пароль:
позже восстановить его из базы данных нельзя.

Для установки в другой каталог:

```bash
curl -fsSL https://raw.githubusercontent.com/LoonEman1/voxhold-deploy/main/bootstrap.sh \
  | VOXHOLD_DEPLOY_DIR="$HOME/voxhold-server" bash
```

После публикации тега релиза для воспроизводимой production-установки укажите
его вместо `main` в обоих местах. Например, для `v1.0.0`:

```bash
curl -fsSL https://raw.githubusercontent.com/LoonEman1/voxhold-deploy/v1.0.0/bootstrap.sh \
  | VOXHOLD_DEPLOY_REF=v1.0.0 bash
```

Передавать удалённый скрипт напрямую в Bash следует только из доверенного
репозитория. Сначала просмотреть скрипт можно так:

```bash
curl -fsSLo bootstrap.sh \
  https://raw.githubusercontent.com/LoonEman1/voxhold-deploy/main/bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

## Режимы развёртывания

Установщик поддерживает:

- только backend для нативных или отдельно размещённых клиентов;
- backend с официальным сайтом Voxhold;
- backend с любым совместимым сторонним образом frontend.

В начале выберите русский или английский язык. Затем установщик спросит режим,
образы контейнеров, публичный адрес, данные первого владельца и необходимость
автозапуска Voxhold после перезагрузки сервера.

Если домена нет, оставьте публичный адрес пустым: установщик определит внешний
IP сервера через HTTPS и использует его для Caddy и WebRTC. Если указан домен,
установщик отдельно определит IP сервера и предложит его как адрес WebRTC.

Рекомендуемый вариант автозапуска назначает backend, frontend и Caddy политику
`unless-stopped`, а также пытается включить службу Docker через systemd. Ответ
«нет» назначает `restart: no`: при установке стек запустится, но после
перезагрузки его потребуется запустить вручную.

## Сеть

Публичные HTTP/HTTPS-порты принадлежат Caddy. Запросы `/api/*`, включая
WebSocket `/api/v1/ws`, всегда направляются сразу в backend. Остальные запросы
в web-режиме направляются в выбранный frontend.

Для публичного сайта направьте A/AAAA-запись домена на сервер и откройте:

- `80/tcp` и `443/tcp` для HTTP/HTTPS;
- `50000/udp` для голоса;
- `50001/udp` для демонстрации экрана.

При включённом встроенном TURN-реле дополнительно откройте `3478/tcp`,
`3478/udp` и диапазон релев `49160-49559/udp` (см. ниже). Не закрывайте
`50000/udp` и `50001/udp` после включения TURN: иначе штатные server-mode
медиасессии будут вынуждены идти через relay с лишней задержкой.

HTTP-порты backend и frontend доступны только внутри сети Compose. Для домена
Caddy автоматически получает и продлевает публично доверенный сертификат. Для
публичного IPv4- или IPv6-адреса Caddy получает публично доверенный
короткоживущий сертификат Let's Encrypt. Устанавливать сертификат на устройства
пользователей не требуется.

IP-сертификат действует около шести дней. Caddy начинает продление примерно в
середине срока действия, повторяет попытки после временных ошибок ACME или сети
и сразу проверяет сохранённый сертификат при каждом запуске контейнера. Поэтому
пропущенное во время выключения сервера продление выполняется после следующего
запуска. Сохраняйте Docker volume `caddy_data`: в нём находятся ACME-аккаунт,
сертификаты и ключи. Публичный IP должен оставаться назначенным серверу, а порты
`80/tcp` и `443/tcp` — быть доступны из интернета для проверки ACME.

## ICE-конфигурация WebRTC и TURN

Браузеры не получают TURN-credentials во время сборки. Runtime-путь выглядит
так:

```text
.env -> backend -> авторизованный GET /api/v1/webrtc/config -> браузер
```

Backend раздаёт значения `WEBRTC_CLIENT_ICE_*` авторизованным браузерным
клиентам с `iceTransportPolicy: all`: direct UDP остаётся основным маршрутом,
а TURN — только fallback. Смена настроек TURN требует лишь перезапуска
backend — пересобирать frontend не нужно.

Отдельные переменные `WEBRTC_SERVER_ICE_*` настраивают собственные Pion-сессии
backend. В стандартном публичном развёртывании они остаются пустыми: backend
публикует host-кандидаты напрямую через `WEBRTC_PUBLIC_IP` и свои UDP-порты;
TURN для Pion создавал бы лишние relay allocations на каждую голосовую или
стримовую сессию.

### Встроенный coturn (профиль «turn»)

coturn использует host networking: он занимает `TURN_LISTEN_PORT` (`3478` по
умолчанию, TCP и UDP) и диапазон релев прямо на хосте. Обязательные порты
файрвола:

- `3478/tcp` + `3478/udp` — клиентский транспорт TURN;
- `49160-49559/udp` — relay allocations (`TURN_RELAY_PORT_MIN`–`MAX`).

Поскольку один общий `TURN_USERNAME` обслуживает всех клиентов,
`TURN_USER_QUOTA` должен оставаться `0`; общий предел allocations задаёт
`TURN_TOTAL_QUOTA`, рассчитанный на ёмкость диапазона (примерно один порт на
allocation). Расширяйте диапазон и соответствующие правила файрвола вместе:
quota выше реальной вместимости портов приведёт к отказам allocations под
нагрузкой.

### Сети, блокирующие обычный TURN

Корпоративные сети иногда блокируют TURN поверх UDP и TCP. Встроенный coturn
работает без TLS и не может предложить `turns:` на том же IP, потому что
`443/tcp` занят Caddy. Используйте внешний managed TURN с URL вида
`turns:turn.example.com:443?transport=tcp` и укажите его в
`WEBRTC_CLIENT_ICE_SERVERS`.

### Безопасная проверка runtime-endpoint

Ответ endpoint содержит credentials. Проверяйте его авторизованным запросом,
не выводя полный JSON:

```bash
curl -fsS \
  -H "Authorization: Bearer $VOXHOLD_TEST_TOKEN" \
  https://voxhold.example.com/api/v1/webrtc/config \
  | jq '{urls: [.ice_servers[].urls], policy: .ice_transport_policy}'
```

Не сохраняйте bearer-токены и полные ответы в shell history или артефактах CI.
Подробнее о миграции и smoke-тестах — в
[README.webrtc-fixes.ru.md](README.webrtc-fixes.ru.md).

## Образы контейнеров

По умолчанию используются:

```text
ghcr.io/looneman1/voxhold-backend:latest
ghcr.io/looneman1/voxhold-frontend:latest
```

Ссылки на backend и frontend независимы и принимают как теги, так и digest:

```dotenv
VOXHOLD_BACKEND_IMAGE=ghcr.io/looneman1/voxhold-backend:latest
VOXHOLD_FRONTEND_IMAGE=ghcr.io/example/custom-voxhold-ui@sha256:<digest>
```

Образы backend публикуются только из Git-тегов наподобие `v0.1.0`. После этого
теги образа `0.1.0`, `0.1` и `latest` указывают на данный релиз. Deploy по
умолчанию использует `latest`, поэтому `./update.sh` загружает последний
стабильный backend. Для предсказуемого production-развёртывания можно указать
точный тег или OCI digest. Для приватных образов
перед установкой или обновлением выполните `docker login`. Задачи миграции и
первоначальной настройки всегда используют точно тот же образ, что и сервис
backend.

## Контракт стороннего frontend

Выберите web-режим, затем укажите образ и его внутренний HTTP-порт. Позже эти
значения можно изменить в `.env`:

```dotenv
VOXHOLD_FRONTEND_IMAGE=ghcr.io/example/custom-voxhold-ui:v1.2.0
VOXHOLD_FRONTEND_PORT=8080
EDGE_UPSTREAM=frontend:8080
```

Совместимый frontend должен:

- раздавать HTTP на указанном внутреннем порту;
- обращаться к API по same-origin адресам `/api/v1/...`;
- подключать WebSocket по same-origin адресу `/api/v1/ws`;
- содержать все необходимые runtime-ресурсы и конфигурацию.

Ему не нужно публиковать порт на хосте или самостоятельно проксировать API.
Запускайте только те контейнерные образы, которым доверяете.

## Настройка, обновление и резервное копирование

Установщик создаёт исключённый из Git файл `.env` с правами `600`. Выбранный
режим развёртывания и вариант TURN сохраняются в `COMPOSE_PROFILES`, поэтому
обычные команды `docker compose up`, `pull` и `down` работают ровно с тем
набором сервисов, который выбран при установке. Для загрузки уже настроенных
образов и перезапуска выбранного режима:

```bash
cd voxhold-deploy
./update.sh
```

Для управления сертификатами не нужны отдельные cron-задачи или systemd-
таймеры. Проверить состояние Caddy и журнал сертификатов можно командами:

```bash
docker compose ps caddy
docker compose logs --tail=100 caddy
```

Состояние сертификатов домена и IP хранится в постоянном volume `caddy_data`.

Чтобы переключить официальный backend на другой точный релиз и обновить стек:

```bash
./backup.sh
./update.sh --backend-version 0.2.0
```

Команда также принимает Git-форму `v0.2.0`. Она намеренно заменяет
`VOXHOLD_BACKEND_IMAGE` на официальный GHCR-образ; для fork, собственного
registry или неизменяемого digest отредактируйте `.env` вручную. Перед сменой
версии прочитайте описание релиза и создайте резервную копию.

Создание согласованной резервной копии SQLite:

```bash
./backup.sh
```

Бэкап ненадолго останавливает backend, проверяет архив до публикации, пишет
checksum-файл и manifest для disaster-recovery без секретов, хранит
`BACKUP_KEEP_COUNT` свежих архивов (по умолчанию 7) и при настроенном
`BACKUP_OFFSITE_DIR` или `BACKUP_OFFSITE_CMD` копирует их offsite.
Расписание задаётся готовыми юнитами:

```bash
sudo cp systemd/voxhold-backup.{service,timer} /etc/systemd/system/
sudo sed -i "s|@DEPLOY_DIR@|$PWD|" /etc/systemd/system/voxhold-backup.*
sudo systemctl daemon-reload && sudo systemctl enable --now voxhold-backup.timer
```

Восстановление сначала в отдельный volume (боевые данные не трогаются), либо
с явной перезаписью живого volume:

```bash
./restore.sh backups/voxhold-<метка>.tar.gz                 # безопасный режим
./restore.sh backups/voxhold-<метка>.tar.gz --into-existing # заменить данные
```

`./watchdog.sh` проверяет публичный endpoint, свободное место и свежесть
бэкапа; уведомления уходят на `WATCHDOG_NOTIFY_URL`, если он задан. Запуск
каждые 15 минут — юниты `systemd/voxhold-watchdog.*` аналогично.

Обновление транзакционно по умолчанию: `./update.sh` делает страховочный
бэкап (отключается через `VOXHOLD_UPDATE_SKIP_BACKUP=1`), ждёт healthcheck
backend и сохраняет ранее работавшие digest образов в `.last-good.env`.
Если обновление ведёт себя плохо — откатите образы `./update.sh --rollback`;
если новый релиз мигрировал схему БД, вместо отката восстановите
соответствующий бэкап (миграции только вперёд).

На время копирования backend ненадолго останавливается, Docker volumes
сохраняются.

Если существующий SQLite volume был создан старым контейнером от root, один раз
исправьте владельца перед первым запуском:

```bash
docker volume ls | grep voxhold_data
docker run --rm --user 0 \
  -v <volume-name>:/app/data \
  alpine:3.22 \
  sh -c 'chown -R 10001:10001 /app/data && chmod 770 /app/data'
```
