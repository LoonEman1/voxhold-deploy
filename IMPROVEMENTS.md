# План улучшений качества и стабильности — Voxhold-deploy

Архитектурный разбор deploy-репозитория. Факты с путями, приоритеты P0 (уронить прод может скоро)
→ P3 (структурное). Дополняет [README.webrtc-fixes.ru.md](README.webrtc-fixes.ru.md) и основные README.

## Что уже хорошо

- Контейнерный hardening: `read_only` + `cap_drop: ALL` + `no-new-privileges` + tmpfs
  noexec/nosuid/nodev у migrate/bootstrap/backend/caddy/coturn (compose.yaml:24-29, 44-49, 68-73,
  116-120, 180-186).
- coturn на host networking вместо сотен docker-proxy; denied-peer-ip против SSRF; healthcheck
  только у backend — без фиктивных TCP-проверок.
- Caddy: автоматический TLS для домена и публичного IP (короткоживущие LE-сертификаты,
  Caddyfile.ip:11-16), `/api/*` напрямую в backend.
- `.env` с umask 077, идемпотентные миграции в update.sh, атомарные записи через mktemp+mv.
- Образы caddy/coturn/alpine pinned по тегам.

## P0 — вероятные инциденты в ближайший месяц

### P0.1. backup.sh: хрупкая последовательность и отсутствие жизненного цикла бэкапов

Факты:
- `backup.sh:18-24`: после `docker compose stop backend` выполняется `docker run` helper-контейнера;
  при его сбое скрипт завершается по `set -Eeuo pipefail`, **не выполнив** `docker compose start backend`
  → backend остаётся остановлен до ручного вмешательства.
- Ротация отсутствует: `./backups/voxhold-*.tar.gz` копятся бесконечно (риск исчерпания диска).
- Нет проверки свободного места перед созданием архива.
- Нет restore-скрипта и процедуры проверки восстановления.
- Нет расписания: запуск только вручную.

Предложения:
1. `trap 'docker compose start backend' EXIT` — гарантированный подъём backend при любом исходе.
2. Ротация: хранить N последних архивов (`ls -1t | tail -n +8 | xargs rm -f`), параметр в `.env`.
3. Проверка свободного места (размер volume × коэффициент ≤ df available), отказ с понятной ошибкой.
4. `restore.sh` с явным предупреждением о перезаписи данных + шаг «проверить восстановление»
   в README (реальное поднятие копии на другом порту).
5. systemd timer / cron для ежедневного запуска + внешний ping-мониторинг (healthchecks.io-style):
   отсутствие пинга об успешном бэкапе = алерт.

### P0.2. Неротируемые логи Docker

Факт: во всём compose.yaml нет блока `logging:`; дефолтный json-file driver пишет без лимитов.
При verbose-логах coturn/backend диск VPS будет исчерпан — самый вероятный инцидент через месяц работы.

Предложение:

```yaml
x-logging: &default-logging
  driver: json-file
  options: { max-size: "10m", max-file: "5" }

services:
  backend:
    logging: *default-logging
  # ... и всем остальным сервисам
```

### P0.3. healthz не отражает состояние зависимостей

Факт: `GET /healthz` → всегда 204 без обращения к БД. Контейнер остаётся healthy при мёртвой SQLite;
Caddy и compose-проверки продолжают считать сервис рабочим (backend-репо, cmd/api/main.go:290-292).

Предложение: healthz выполняет дешёвый `SELECT 1` с таймаутом; при деградации — 503.
Оставить отдельный лёгкий `/livez` (без БД) для load-balancer логики, если понадобится.

### P0.4. Лимиты ресурсов контейнеров

Факт: нет ни mem/cpu лимитов, ни ulimits ни у одного сервиса. Утечка или runaway-горутина съедает
всю память VPS → OOM-killer убивает случайный процесс (возможно caddy или сам backend).

Предложение: `mem_limit`/`cpus` для каждого сервиса (backend ~512m–1g, caddy 256m, coturn 256m,
frontend 128m); coturn дополнительно `ulimits: { nofile: 262144 }` — образ сам заявляет поддержку
~262k сессий при высоком nofile (лог coturn «max supported number of TURN sessions»).

## P1 — edge и эксплуатация

### P1.1. Security headers на edge

Факт: в Caddyfile/Caddyfile.ip нет ни одной директивы `header`. Frontend-nginx отдаёт headers только
для статики — **все ответы `/api/*` идут мимо nginx напрямую из backend без HSTS/nosniff/X-Frame-Options**
(backend тоже их не отдаёт).

Предложение: единая точка — Caddy:

```caddyfile
header {
    Strict-Transport-Security "max-age=31536000"
    X-Content-Type-Options nosniff
    X-Frame-Options DENY
    Referrer-Policy strict-origin-when-cross-origin
    -Server
}
encode zstd gzip
```

CSP осторожно (WS + медиа), начать с HSTS/nosniff/frame-options — они не ломают ничего.

### P1.2. Секреты

- `TURN_PASSWORD` передаётся argv (`--user=...:${TURN_PASSWORD:-}`, compose.yaml:137) → виден в
  `docker inspect`/`ps` любому пользователю хоста. Перейти на mounted `turnserver.conf` (секрет в файле
  0600, tmpfs или bind-mount).
- Сгенерированный пароль владельца извлекается из `docker compose logs bootstrap`
  (install.sh:425-435) → секрет попадает в docker logs. Заменить на одноразовый файл в volume с
  инструкцией прочитать и удалить.

### P1.3. Обновления и откат

- По умолчанию `latest` (compose.yaml:3,52,82) + bootstrap качает реф `main`. Предложить установку по
  тегам релизов по умолчанию, `main` — явно.
- `update.sh`: перед `up` автоматически выполнять backup.sh (флаг `--skip-backup` для отказа);
  хранить last-good digest и добавить `./update.sh --rollback`.

### P1.4. Наблюдаемость оператора

Сейчас: `docker compose ps/logs` и healthcheck backend. Минимум без развёртывания Prometheus:
- cron-скрипт: `curl -f https://host/healthz`, `df -P`, свежесть последнего бэкапа → уведомление
  (Telegram bot API / ntfy.sh) при аномалиях.
- Позже: экспонирование метрик backend (см. план Voxhold-backend) и лёгкий scraper.

### P1.5. Дисковый сторож

SQLite под нагрузкой при исчерпании диска = повреждение базы. Cron `df -P /var/lib/docker` с порогом
85% → алерт; backup.sh уже должен проверять место (P0.1).

## P2 — надёжность поставки

- bootstrap.sh: проверять sha256 скачанного tar.gz (публиковать checksums рядом) и предупреждать,
  если ставится `main`.
- Сегментация сети: выделить data-plane сеть для backend↔БД-зависимостей; frontend не должен иметь
  маршрут до всего (сейчас одна плоская сеть `app`).
- Frontend-контейнер: добавить `read_only` + `cap_drop: ALL` как у остальных (сейчас только
  no-new-privileges, compose.yaml:94-95).
- Рассмотреть digest-pinning образов в примерах документации.

## P3 — структурное (осознанно, позже)

- Embedded-миграции в бинаре backend → убрать отдельный сервис `migrate` из compose (минус один
  движущийся компонент и условие `service_completed_successfully`).
- litestream (непрерывная репликация SQLite в S3/B2) — превращает RPO из «последний ручной бэкап»
  в секунды; совместимо с текущим single-file стеком.
- Единый make/task-файл операционных процедур: `make backup|restore|update|logs|smoke`.

## Чего не делать

- Kubernetes/Swarm, распределённый rate limiting, внешние очереди — оверинжиниринг для одного VPS.
- Автоматических auto-update'ов контейнеров (watchtower) без окна тестирования.

## Рекомендуемый порядок

```
День 1:   P0.1 (trap+rotation+restore), P0.2 (log rotation)
День 2:   P0.3 (healthz+БД),            P0.4 (limits+ulimits)
Неделя 2: P1.1 (Caddy headers),         P1.2 (секреты), P1.4-P1.5 (сторожа)
Позже:    P1.3, P2, P3
```

## Статус реализации (после ревью VOXHOLD_REVIEW.md)

Реализовано по скорректированным рекомендациям ревью:

- D-P0.1: backup.sh переписан (flock, проверка места, `.partial` → `tar -tzf` → атомарный
  rename, sha256, DR-manifest без секретов, retention `BACKUP_KEEP_COUNT`, offsite
  `BACKUP_OFFSITE_DIR/CMD`, trap восстанавливает исходное состояние backend).
- Новый restore.sh: безопасный режим (новый volume) и `--into-existing` с checksum-проверкой.
- Новый watchdog.sh + systemd/voxhold-{backup,watchdog}.{service,timer} (объединяет D-P1.4/D-P1.5).
- D-P0.2: json-file max-size=10m/max-file=5 для всех сервисов.
- D-P0.4: mem_limit для всех сервисов, nofile 262144 у coturn (CPU-limits сознательно нет).
- D-P1.1: security headers + encode zstd/gzip в обоих Caddyfile, `/readyz` проксируется.
- D-P2.3: frontend read_only+tmpfs+cap_drop как в эталонном compose frontend.
- D-P1.3 (частично): update.sh делает страховочный бэкап, ждёт healthcheck, пишет
  `.last-good.env`, добавлен `./update.sh --rollback`; prompt тегов в install.sh не менялся.
