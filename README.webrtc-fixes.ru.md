# Deploy-изменения после WebRTC-фиксов backend и frontend

Этот документ — отдельный post-fix чек-лист для `Voxhold-deploy`. Применять его нужно после того, как в опубликованные образы backend и frontend попадут изменения из плана совместимости и восстановления WebRTC.

Документ не заменяет основной [README.ru.md](README.ru.md). Он описывает только миграцию production deploy под новые media-контракты.

## Ожидаемые изменения в backend и frontend

Перед deploy-миграцией должны быть готовы следующие контракты:

- backend предоставляет авторизованный `GET /api/v1/webrtc/config`;
- endpoint возвращает браузерные ICE servers и `ice_transport_policy: "all"`;
- backend различает ICE-конфигурацию браузерных клиентов и собственных Pion-сессий;
- frontend больше не читает `VITE_WEBRTC_ICE_SERVERS`, `VITE_WEBRTC_ICE_USERNAME` и `VITE_WEBRTC_ICE_CREDENTIAL`;
- frontend загружает ICE-конфигурацию после авторизации и передаёт её во все voice/stream/P2P `RTCPeerConnection`;
- frontend умеет продолжать host-only работу с явным предупреждением, если runtime ICE endpoint временно недоступен.

Не выкатывать новый frontend раньше совместимого backend: иначе клиент не сможет получить runtime ICE-конфигурацию.

## Почему deploy тоже нужно изменить

Текущий deploy записывает TURN в `WEBRTC_ICE_*`. Эти значения одновременно получает backend Pion, а браузерный frontend ожидает build-time `VITE_WEBRTC_*`.

После фиксов правильная схема должна быть такой:

```text
coturn -> WEBRTC_CLIENT_ICE_* -> backend HTTP endpoint -> browser

public UDP 50000/50001 -> WEBRTC_SERVER_ICE_* (обычно пусто) -> backend Pion
```

Backend на публичном сервере уже публикует host candidates через `WEBRTC_PUBLIC_IP` и открытые UDP-порты. Если дополнительно передавать ему TURN, каждая Pion-сессия может создать лишний relay allocation. TURN здесь нужен прежде всего браузерам и P2P-соединениям.

## Целевой `.env`

Пример для web-режима со встроенным coturn:

```dotenv
COMPOSE_PROFILES=web,turn

WEBRTC_PUBLIC_IP=203.0.113.10
WEBRTC_UDP_PORT=50000
WEBRTC_STREAM_UDP_PORT=50001

TURN_USERNAME=voxhold
TURN_PASSWORD=<long-random-password>
TURN_REALM=voxhold
TURN_LISTEN_PORT=3478
TURN_RELAY_PORT_MIN=49160
TURN_RELAY_PORT_MAX=49559
TURN_USER_QUOTA=0
TURN_TOTAL_QUOTA=400

WEBRTC_CLIENT_ICE_SERVERS="turn:203.0.113.10:3478?transport=udp,turn:203.0.113.10:3478?transport=tcp"
WEBRTC_CLIENT_ICE_USERNAME="voxhold"
WEBRTC_CLIENT_ICE_CREDENTIAL="<same-password-as-TURN_PASSWORD>"

# На стандартном public deploy backend использует собственные UDP listeners.
WEBRTC_SERVER_ICE_SERVERS=
WEBRTC_SERVER_ICE_USERNAME=
WEBRTC_SERVER_ICE_CREDENTIAL=
```

Допустимые `COMPOSE_PROFILES`:

- `web,turn` — backend, web frontend и встроенный coturn;
- `web` — backend и web frontend без встроенного TURN;
- `turn` — backend/native deployment со встроенным coturn;
- пустое значение — только основные сервисы без frontend и coturn.

`iceTransportPolicy` должен оставаться `all`. Нельзя принудительно переводить всех пользователей на relay: direct UDP обычно даёт меньшую задержку и не расходует TURN capacity.

## Обязательные изменения по файлам

### `compose.yaml`

1. Использовать переменную listener port вместо жёсткого `3478`:

```yaml
- "--listening-port=${TURN_LISTEN_PORT:-3478}"
```

2. Вынести квоты в `.env`:

```yaml
- "--user-quota=${TURN_USER_QUOTA:-0}"
- "--total-quota=${TURN_TOTAL_QUOTA:-400}"
```

Текущий coturn использует один общий `TURN_USERNAME=voxhold`. Поэтому `user-quota=16` ограничивает весь инстанс шестнадцатью allocations, а не шестнадцатью allocations на реального пользователя Voxhold. До перехода на временные персональные TURN credentials per-user quota должна быть `0`, а общий предел задаётся `TURN_TOTAL_QUOTA`.

3. Оставить host networking и UDP relay range. Не публиковать сотни отдельных Docker ports: это вернёт лишние `docker-proxy` процессы, от которых текущая конфигурация уже защищена.

4. Исправить комментарий `TURN relay for WebRTC P2P`: новый runtime client ICE используется также браузерными voice/server-stream sessions как fallback.

5. Не добавлять фиктивный healthcheck, проверяющий только открытый TCP-порт. Такой check не доказывает, что TURN authentication и Allocate работают. Полноценную проверку выполнять отдельным smoke test.

### `install.sh`

1. Генерировать `COMPOSE_PROFILES` и сохранять его в `.env`, а не полагаться только на временные CLI `--profile`.
2. Записывать `WEBRTC_CLIENT_ICE_*` вместо старых общих `WEBRTC_ICE_*`.
3. Оставлять `WEBRTC_SERVER_ICE_*` пустыми для стандартной установки с публичными UDP 50000/50001.
4. Записывать `TURN_USER_QUOTA` и `TURN_TOTAL_QUOTA`.
5. Использовать `TURN_LISTEN_PORT` и при запуске coturn, и при создании browser URL, и в firewall-подсказке.
6. Корректно формировать IPv6 TURN URL.

Для IPv4:

```text
turn:203.0.113.10:3478?transport=udp
```

Для IPv6:

```text
turn:[2001:db8::10]:3478?transport=udp
```

Значение `WEBRTC_PUBLIC_IP` при этом остаётся без квадратных скобок; скобки нужны только вокруг IPv6 host в URL.

7. Не печатать `TURN_PASSWORD` и `WEBRTC_CLIENT_ICE_CREDENTIAL` в stdout или диагностике.

### `update.sh`

Добавить идемпотентную миграцию старого `.env`:

1. Если `WEBRTC_CLIENT_ICE_SERVERS` отсутствует, скопировать в него прежнее `WEBRTC_ICE_SERVERS`.
2. Аналогично мигрировать username и credential.
3. Добавить пустые `WEBRTC_SERVER_ICE_*`, если их нет.
4. Добавить `TURN_USER_QUOTA=0` и подходящий `TURN_TOTAL_QUOTA`.
5. Если relay range остаётся старым диапазоном из 100 портов, не выставлять quota выше реальной вместимости без одновременного расширения firewall range.
6. Сформировать `COMPOSE_PROFILES` из текущих настроек:
   - добавить `web`, если `EDGE_UPSTREAM` начинается с `frontend:`;
   - добавить `turn`, если client ICE содержит URL встроенного coturn и присутствует `TURN_PASSWORD`.
7. После успешной миграции удалить legacy `WEBRTC_ICE_*` или оставить их только на один совместимый релиз. Нельзя долго хранить две конфликтующие конфигурации без понятного приоритета.
8. Сохранить существующие гарантии: временный файл через `mktemp`, права `0600`, атомарный `mv`, отсутствие credential в выводе.

После появления `COMPOSE_PROFILES` стандартные команды `docker compose up`, `pull`, `down` и `config` будут работать с тем же набором сервисов, что installer/update scripts.

### `.env.example`

Добавить:

```dotenv
COMPOSE_PROFILES=web,turn
TURN_USER_QUOTA=0
TURN_TOTAL_QUOTA=400
WEBRTC_CLIENT_ICE_SERVERS=
WEBRTC_CLIENT_ICE_USERNAME=
WEBRTC_CLIENT_ICE_CREDENTIAL=
WEBRTC_SERVER_ICE_SERVERS=
WEBRTC_SERVER_ICE_USERNAME=
WEBRTC_SERVER_ICE_CREDENTIAL=
```

Удалить старое описание `WEBRTC_ICE_*` после окончания переходного периода.

### `README.md` и `README.ru.md`

Документировать:

- runtime-путь ICE-конфигурации: `.env -> backend -> authenticated API -> browser`;
- отсутствие необходимости пересобирать frontend при смене TURN;
- обязательные firewall ports при встроенном coturn;
- отличие direct backend UDP и TURN relay ports;
- внешний TURN/TLS для сетей, блокирующих обычный TURN/TCP;
- реальную вместимость relay range и общую allocation quota;
- безопасную проверку endpoint без вывода credential.

## Что не нужно менять

### Caddy

Текущие `Caddyfile` и `Caddyfile.ip` уже направляют `/api/*` напрямую в backend. Новый `/api/v1/webrtc/config` автоматически попадёт в правильный upstream.

TURN credentials не должны передаваться frontend-контейнеру через environment и не должны попадать в статический JavaScript bundle.

### Media UDP ports

Сохраняются:

- `50000/udp` — backend voice SFU;
- `50001/udp` — backend stream SFU.

TURN является дополнительным fallback, а не заменой этим портам.

## Firewall

Для web deployment:

```text
80/tcp                 HTTP/ACME
443/tcp                HTTPS/WebSocket
50000/udp              voice SFU
50001/udp              stream SFU
3478/udp               TURN client transport
3478/tcp               TURN client transport fallback
49160-49559/udp        TURN relay allocations
```

Если выбран другой `TURN_LISTEN_PORT` или relay range, firewall и документация должны меняться вместе с `.env`.

Не закрывать 50000/50001 после добавления TURN: иначе штатные server-mode соединения начнут зависеть от relay и получат лишнюю задержку.

## TURN/TLS

Встроенный coturn сейчас запускается с `--no-tls`, а публичный `443/tcp` занят Caddy. Поэтому добавление `turns:` на тот же IP и порт без дополнительной архитектуры невозможно.

Для закрытых корпоративных сетей использовать один из вариантов:

1. внешний managed TURN с `turns:turn.example.com:443?transport=tcp`;
2. отдельный IP/hostname, где `443/tcp` принадлежит coturn;
3. отдельный L4 TLS/SNI proxy, маршрутизирующий HTTPS и TURN/TLS.

Первый вариант проще и безопаснее для начального production. Его URL также передаётся через `WEBRTC_CLIENT_ICE_SERVERS`.

Не включать `turns:` в installer по умолчанию без сертификата и реального listener: браузер будет тратить время на заведомо неработающий ICE server.

## Порядок выкладки

1. Сделать backup SQLite через `./backup.sh`.
2. Сохранить защищённую копию текущего `.env` вне репозитория.
3. Убедиться, что backend image уже поддерживает runtime endpoint и новые client/server env.
4. Убедиться, что frontend image больше не зависит от `VITE_WEBRTC_ICE_*`.
5. Обновить deploy-файлы и выполнить миграцию `.env`.
6. Сначала поднять backend и проверить `/healthz`.
7. Проверить `/api/v1/webrtc/config` с авторизованной сессией.
8. Поднять frontend и coturn через сохранённые `COMPOSE_PROFILES`.
9. Выполнить direct UDP и TURN smoke tests.
10. Только после проверки удалить legacy `WEBRTC_ICE_*`.

## Проверки до запуска

```bash
bash -n install.sh
bash -n update.sh
docker compose config --quiet
docker compose config --services
```

При `COMPOSE_PROFILES=web,turn` список сервисов должен содержать `frontend` и `coturn` без ручного `--profile`.

Если установлен ShellCheck:

```bash
shellcheck install.sh update.sh
```

## Проверки после запуска

```bash
docker compose ps
docker compose logs --tail=100 backend
docker compose logs --tail=100 coturn
```

Проверить runtime endpoint авторизованным запросом. Не выводить JSON целиком в общие CI-логи, потому что ответ содержит credential. В локальной защищённой консоли можно вывести только URLs и наличие полей:

```bash
curl -fsS \
  -H "Authorization: Bearer $VOXHOLD_TEST_TOKEN" \
  https://voxhold.example.com/api/v1/webrtc/config \
  | jq '{urls: [.ice_servers[].urls], has_username: ([.ice_servers[].username] | any), has_credential: ([.ice_servers[].credential] | any), policy: .ice_transport_policy}'
```

Не сохранять bearer token или полный endpoint response в shell history и CI artifacts.

## Browser smoke tests

### Direct path

1. Обычная сеть без блокировки UDP.
2. Подключиться к голосу и открыть трансляцию.
3. В `chrome://webrtc-internals` или `about:webrtc` проверить выбранную candidate pair.
4. Ожидается direct `host`/`srflx`, а не обязательный `relay`.

### TURN/UDP

1. Проверить клиента за NAT, где direct pair не устанавливается.
2. Убедиться, что собирается relay candidate и медиасессия подключается.
3. Проверить голос и server/P2P stream отдельно.

### TURN/TCP

1. Заблокировать UDP на тестовом клиентском сегменте, не на production-сервере.
2. Убедиться, что выбирается relay candidate с TCP transport.
3. Проверить, что recovery не создаёт бесконечные allocations после reconnect.

### Quality guard

Во всех сценариях проверить, что deploy-изменения не меняют:

- выбранное пользователем разрешение;
- FPS;
- video/audio max bitrate;
- `degradationPreference: maintain-resolution`;
- negotiated codec policy frontend/backend.

TURN/TCP может иметь большую задержку из-за природы TCP, но он используется только когда direct UDP невозможен.

## Критерии готовности

Deploy-миграция завершена, когда:

- `docker compose up -d` без дополнительных flags поднимает выбранные web/turn профили;
- browser runtime endpoint возвращает актуальные значения из `.env` без пересборки frontend;
- backend не создаёт собственные TURN allocations в стандартном public deployment;
- IPv4 и IPv6 TURN URLs корректны;
- общий coturn limit не блокирует приложение после 16 allocations;
- direct UDP остаётся основным маршрутом;
- TURN/UDP и TURN/TCP проверены на реальной медиасессии;
- credential отсутствуют в bundle, diagnostics, общих логах и CI artifacts;
- краткий WebSocket/media outage восстанавливается предусмотренными backend/frontend recovery-механизмами.

## Следующий этап, не блокирующий первый rollout

После стабилизации можно заменить общий `TURN_USERNAME/TURN_PASSWORD` на coturn TURN REST authentication:

- coturn запускается с `--use-auth-secret` и `--static-auth-secret`;
- backend создаёт краткоживущий username вида `<expiry>:<user-id>`;
- credential вычисляется как Base64 HMAC от username;
- endpoint возвращает TTL;
- quota и диагностика работают на отдельных временных usernames;
- утёкший credential перестаёт работать после TTL.

Не смешивать static user и `use-auth-secret` в одной конфигурации: coturn рекомендует выбрать один механизм авторизации.

## Ссылки

- [Docker Compose profiles](https://docs.docker.com/compose/how-tos/profiles/)
- [Пример production-конфигурации coturn](https://github.com/coturn/coturn/blob/master/examples/etc/turnserver.conf)
- [Основной WebRTC-план Voxhold](../Voxhold-backend/docs/Agent/Plans/webrtc-browser-compatibility-resilience.md)
