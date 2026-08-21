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

HTTP-порты backend и frontend доступны только внутри сети Compose. При
использовании домена Caddy автоматически получает и обновляет публичный
сертификат. Для IP-адреса Caddy использует локально доверенный сертификат, если
не подключён внешний IP-сертификат.

## Образы контейнеров

По умолчанию используются:

```text
ghcr.io/looneman1/voxhold-backend:latest
ghcr.io/looneman1/voxhold-frontend:latest
```

Ссылки на backend и frontend независимы и принимают как теги, так и digest:

```dotenv
VOXHOLD_BACKEND_IMAGE=ghcr.io/looneman1/voxhold-backend:sha-<commit>
VOXHOLD_FRONTEND_IMAGE=ghcr.io/example/custom-voxhold-ui@sha256:<digest>
```

Для воспроизводимых обновлений вместо `latest` предпочтительнее тег релиза или
неизменяемый digest. Для приватных образов перед установкой или обновлением
выполните `docker login`.
Задачи миграции и первоначальной настройки всегда используют точно тот же образ,
что и сервис backend.

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

Установщик создаёт исключённый из Git файл `.env` с правами `600`. Для загрузки
настроенных образов и перезапуска выбранного режима:

```bash
cd voxhold-deploy
./update.sh
```

Создание согласованной резервной копии SQLite:

```bash
./backup.sh
```

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
