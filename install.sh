#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"
umask 077

echo "Language / Язык:"
echo "  1) English"
echo "  2) Русский"
read -r -p "Choose / Выберите [1/2]: " language_choice

case "$language_choice" in
    1) language="en" ;;
    2) language="ru" ;;
    *) echo "Choose 1 or 2. / Выберите 1 или 2." >&2; exit 1 ;;
esac

if [[ "$language" == "ru" ]]; then
    msg_linux_required="Развёртывание Voxhold поддерживается только на Linux-серверах."
    msg_docker_required="Требуется Docker. Установите Docker Engine и Docker Compose."
    msg_compose_required="Требуется Docker Compose v2."
    msg_deployment_mode="Режим установки:"
    msg_mode_native="только backend + нативный клиент"
    msg_mode_web="backend + сайт + нативный клиент"
    prompt_choose="Выберите [1/2]: "
    msg_choose_error="Выберите 1 или 2."
    prompt_backend_image="Образ backend"
    prompt_frontend_image="Образ frontend"
    prompt_frontend_port="Внутренний порт frontend"
    msg_port_error="Порт frontend должен быть от 1 до 65535."
    prompt_autostart="Запускать Voxhold автоматически после перезагрузки сервера? [Д/н]: "
    msg_yes_no_error="Ответьте да или нет."
    prompt_public_host="Публичный домен или IP-адрес: "
    msg_public_host_error="Необходимо указать публичный домен или IP-адрес."
    prompt_instance_name="Название инстанса [Voxhold]: "
    prompt_owner_username="Имя владельца [owner]: "
    prompt_owner_password="Пароль владельца (пусто = сгенерировать один раз): "
    prompt_webrtc_ip="Публичный WebRTC IP"
    msg_ip_warning="Предупреждение: для IP-адресов Caddy по умолчанию использует локально доверенный сертификат."
    msg_ip_hint="Нативные клиенты должны доверять этому CA; для публичного сайта используйте домен или подключите IP-сертификат."
    msg_systemd_missing="Не удалось автоматически включить Docker при загрузке. Убедитесь, что Docker запускается вместе с системой."
    msg_docker_enable_failed="Не удалось включить службу Docker. Контейнеры настроены на автозапуск, но Docker также должен запускаться вместе с системой."
    msg_pulling="Загрузка образов Voxhold..."
    msg_starting="Запуск Voxhold..."
    msg_running="Voxhold доступен по адресу:"
    msg_native_url="Базовый URL нативного клиента:"
else
    msg_linux_required="Voxhold deployment is supported only on Linux hosts."
    msg_docker_required="Docker is required. Install Docker Engine and Docker Compose first."
    msg_compose_required="Docker Compose v2 is required."
    msg_deployment_mode="Deployment mode:"
    msg_mode_native="backend + native client only"
    msg_mode_web="backend + website + native client"
    prompt_choose="Choose [1/2]: "
    msg_choose_error="Choose 1 or 2."
    prompt_backend_image="Backend image"
    prompt_frontend_image="Frontend image"
    prompt_frontend_port="Frontend internal port"
    msg_port_error="Frontend port must be between 1 and 65535."
    prompt_autostart="Start Voxhold automatically after a server reboot? [Y/n]: "
    msg_yes_no_error="Answer yes or no."
    prompt_public_host="Public domain or IP address: "
    msg_public_host_error="A public domain or IP address is required."
    prompt_instance_name="Instance name [Voxhold]: "
    prompt_owner_username="Owner username [owner]: "
    prompt_owner_password="Owner password (empty = generate once): "
    prompt_webrtc_ip="Public WebRTC IP"
    msg_ip_warning="Warning: Caddy uses a locally trusted certificate for IP addresses by default."
    msg_ip_hint="Native clients must trust that CA; for a public website, use a domain or mount an IP certificate."
    msg_systemd_missing="Could not enable Docker at boot automatically. Make sure Docker starts with the system."
    msg_docker_enable_failed="Could not enable the Docker service. Containers are configured to restart, but Docker must also start with the system."
    msg_pulling="Pulling Voxhold images..."
    msg_starting="Starting Voxhold..."
    msg_running="Voxhold is running at:"
    msg_native_url="Native client base URL:"
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "$msg_linux_required" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "$msg_docker_required" >&2
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "$msg_compose_required" >&2
    exit 1
fi

dotenv_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

backend_image="ghcr.io/looneman1/voxhold-backend:latest"
frontend_image="ghcr.io/looneman1/voxhold-frontend:latest"
frontend_port="8080"

echo "$msg_deployment_mode"
echo "  1) $msg_mode_native"
echo "  2) $msg_mode_web"
read -r -p "$prompt_choose" mode

case "$mode" in
    1) edge_upstream="backend:8080"; compose_args=() ;;
    2) compose_args=(--profile web) ;;
    *) echo "$msg_choose_error" >&2; exit 1 ;;
esac

read -r -p "$prompt_autostart" autostart_answer
case "$autostart_answer" in
    ""|y|Y|yes|YES|Yes|д|Д|да|ДА|Да)
        restart_policy="unless-stopped"
        enable_docker_at_boot="true"
        ;;
    n|N|no|NO|No|н|Н|нет|НЕТ|Нет)
        restart_policy="no"
        enable_docker_at_boot="false"
        ;;
    *) echo "$msg_yes_no_error" >&2; exit 1 ;;
esac

read -r -p "$prompt_backend_image [$backend_image]: " selected_backend_image
backend_image=${selected_backend_image:-$backend_image}

if [[ "$mode" == "2" ]]; then
    read -r -p "$prompt_frontend_image [$frontend_image]: " selected_frontend_image
    frontend_image=${selected_frontend_image:-$frontend_image}
    read -r -p "$prompt_frontend_port [$frontend_port]: " selected_frontend_port
    frontend_port=${selected_frontend_port:-$frontend_port}
    if [[ ! "$frontend_port" =~ ^[0-9]+$ ]] || (( frontend_port < 1 || frontend_port > 65535 )); then
        echo "$msg_port_error" >&2
        exit 1
    fi
    edge_upstream="frontend:$frontend_port"
fi

read -r -p "$prompt_public_host" public_host
if [[ -z "$public_host" || "$public_host" =~ [[:space:]] ]]; then
    echo "$msg_public_host_error" >&2
    exit 1
fi

read -r -p "$prompt_instance_name" instance_name
instance_name=${instance_name:-Voxhold}
read -r -p "$prompt_owner_username" bootstrap_username
bootstrap_username=${bootstrap_username:-owner}
read -r -s -p "$prompt_owner_password" bootstrap_password
printf '\n'

read -r -p "$prompt_webrtc_ip [$public_host]: " webrtc_public_ip
webrtc_public_ip=${webrtc_public_ip:-$public_host}

if [[ "$public_host" =~ ^[0-9a-fA-F:.]+$ ]]; then
    echo "$msg_ip_warning"
    echo "$msg_ip_hint"
fi

cat > .env <<EOF
VOXHOLD_BACKEND_IMAGE=$(dotenv_quote "$backend_image")
VOXHOLD_FRONTEND_IMAGE=$(dotenv_quote "$frontend_image")
VOXHOLD_FRONTEND_PORT=$(dotenv_quote "$frontend_port")
VOXHOLD_RESTART_POLICY=$(dotenv_quote "$restart_policy")
PUBLIC_HOST=$(dotenv_quote "$public_host")
EDGE_UPSTREAM=$(dotenv_quote "$edge_upstream")
DATABASE_PATH=/app/data/voxhold.db
MIGRATIONS_PATH=/app/migrations
RESET_DATABASE=false
INSTANCE_NAME=$(dotenv_quote "$instance_name")
BOOTSTRAP_USERNAME=$(dotenv_quote "$bootstrap_username")
BOOTSTRAP_PASSWORD=$(dotenv_quote "$bootstrap_password")
WEBRTC_PUBLIC_IP=$(dotenv_quote "$webrtc_public_ip")
WEBRTC_UDP_PORT=50000
WEBRTC_MAX_PARTICIPANTS=32
WEBRTC_MAX_AUDIO_BITRATE_KBPS=128
WEBRTC_STREAM_UDP_PORT=50001
WEBRTC_STREAM_MAX_VIEWERS=32
WEBRTC_STREAM_MAX_P2P_VIEWERS=8
WEBRTC_STREAM_MAX_VIDEO_BITRATE_KBPS=16000
WEBRTC_STREAM_MAX_AUDIO_BITRATE_KBPS=320
WEBRTC_ICE_SERVERS=
WEBRTC_ICE_USERNAME=
WEBRTC_ICE_CREDENTIAL=
TRUST_PROXY_HEADERS=true
HTTP_RATE_LIMIT_RPS=25
HTTP_RATE_LIMIT_BURST=50
HTTP_WRITE_RATE_LIMIT_RPS=8
HTTP_WRITE_RATE_LIMIT_BURST=16
AUTH_RATE_LIMIT_PER_MINUTE=10
AUTH_RATE_LIMIT_BURST=5
INVITE_RATE_LIMIT_PER_MINUTE=20
INVITE_RATE_LIMIT_BURST=10
LOGIN_MAX_FAILURES=5
LOGIN_BLOCK_MINUTES=20
WS_CONNECT_RATE_PER_MINUTE=10
WS_CONNECT_RATE_BURST=5
WS_EVENT_RATE_PER_SECOND=30
WS_EVENT_RATE_BURST=60
WS_MAX_CONNECTIONS_PER_IP=20
WS_MAX_CONNECTIONS_PER_USER=5
RATE_LIMIT_MAX_ENTRIES=20000
EOF

if [[ "$enable_docker_at_boot" == "true" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
        if [[ "$EUID" -eq 0 ]]; then
            service_command=(systemctl)
        elif command -v sudo >/dev/null 2>&1; then
            service_command=(sudo systemctl)
        else
            service_command=()
        fi

        if (( ${#service_command[@]} == 0 )) || ! "${service_command[@]}" enable --now docker; then
            echo "$msg_docker_enable_failed" >&2
        fi
    else
        echo "$msg_systemd_missing" >&2
    fi
fi

echo "$msg_pulling"
docker compose "${compose_args[@]}" pull
echo "$msg_starting"
docker compose "${compose_args[@]}" up -d
docker compose ps

echo
echo "$msg_running https://$public_host"
echo "$msg_native_url https://$public_host"
