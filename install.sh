#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"
umask 077

echo "Language / Язык:"
echo "  1) English"
echo "  2) Русский"
printf 'Choose / Выберите [1/2]: '
read -r language_choice

case "$language_choice" in
    1) language="en" ;;
    2) language="ru" ;;
    *) echo "Choose 1 or 2. / Выберите 1 или 2." >&2; exit 1 ;;
esac

if [[ "$language" == "ru" ]]; then
    msg_linux_required="Развёртывание Voxhold поддерживается только на Linux-серверах."
    msg_docker_required="Требуется Docker. Установите Docker Engine и Docker Compose."
    msg_compose_required="Требуется Docker Compose v2."
    msg_curl_required="Требуется curl для определения публичного IP."
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
    prompt_public_host="Публичный домен или IP-адрес (пусто = определить IP автоматически): "
    msg_detecting_public_ip="Определение публичного IP сервера..."
    msg_detected_public_ip="Обнаружен публичный IP:"
    msg_public_ip_detection_error="Не удалось автоматически определить публичный IP. Запустите установщик снова и укажите домен или IP вручную."
    prompt_instance_name="Название инстанса [Voxhold]: "
    prompt_owner_username="Имя владельца [owner]: "
    prompt_owner_password="Пароль владельца (пусто = сгенерировать один раз): "
    prompt_webrtc_ip="Публичный WebRTC IP"
    msg_webrtc_ip_error="Публичный WebRTC IP должен быть корректным IPv4- или IPv6-адресом."
    msg_ip_warning="Caddy выпустит для IP-адреса публично доверенный короткоживущий сертификат Let's Encrypt."
    msg_ip_hint="Порты 80/tcp и 443/tcp должны быть доступны из интернета; Caddy автоматически продлевает сертификат и повторяет неудачные попытки."
    msg_systemd_missing="Не удалось автоматически включить Docker при загрузке. Убедитесь, что Docker запускается вместе с системой."
    msg_docker_enable_failed="Не удалось включить службу Docker. Контейнеры настроены на автозапуск, но Docker также должен запускаться вместе с системой."
    msg_pulling="Загрузка образов Voxhold..."
    msg_starting="Запуск Voxhold..."
    msg_running="Voxhold доступен по адресу:"
    msg_native_url="Базовый URL нативного клиента:"
    msg_generated_owner_password="Сгенерированный пароль владельца:"
    msg_save_generated_owner_password="Сохраните этот пароль сейчас: повторно он не будет показан."
    msg_generated_password_unavailable="Не удалось прочитать сгенерированный пароль из журнала bootstrap."
    msg_generated_password_logs_hint="Проверьте журнал командой: docker compose logs bootstrap"
    msg_prompt_turn="Включить встроенный TURN-релей (coturn) для WebRTC P2P? [Д/н]: "
    msg_turn_enabled="TURN включён: контейнер coturn будет запущен, креды записаны в .env."
    msg_turn_disabled="TURN отключён: WebRTC клиенты будут использовать только host-кандидаты."
    msg_turn_firewall="Откройте на файрволе сервера порты: 3478/tcp + 3478/udp (сигналинг TURN) и 49160-49259/udp (медиа-релей)."
else
    msg_linux_required="Voxhold deployment is supported only on Linux hosts."
    msg_docker_required="Docker is required. Install Docker Engine and Docker Compose first."
    msg_compose_required="Docker Compose v2 is required."
    msg_curl_required="curl is required to detect the public IP."
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
    prompt_public_host="Public domain or IP address (empty = detect public IP automatically): "
    msg_detecting_public_ip="Detecting the server's public IP..."
    msg_detected_public_ip="Detected public IP:"
    msg_public_ip_detection_error="Could not detect the public IP automatically. Run the installer again and enter a domain or IP manually."
    prompt_instance_name="Instance name [Voxhold]: "
    prompt_owner_username="Owner username [owner]: "
    prompt_owner_password="Owner password (empty = generate once): "
    prompt_webrtc_ip="Public WebRTC IP"
    msg_webrtc_ip_error="Public WebRTC IP must be a valid IPv4 or IPv6 address."
    msg_ip_warning="Caddy will issue a publicly trusted, short-lived Let's Encrypt certificate for the IP address."
    msg_ip_hint="TCP ports 80 and 443 must be reachable from the internet; Caddy renews the certificate automatically and retries failures."
    msg_systemd_missing="Could not enable Docker at boot automatically. Make sure Docker starts with the system."
    msg_docker_enable_failed="Could not enable the Docker service. Containers are configured to restart, but Docker must also start with the system."
    msg_pulling="Pulling Voxhold images..."
    msg_starting="Starting Voxhold..."
    msg_running="Voxhold is running at:"
    msg_native_url="Native client base URL:"
    msg_generated_owner_password="Generated owner password:"
    msg_save_generated_owner_password="Save this password now; it will not be shown again."
    msg_generated_password_unavailable="Could not read the generated password from the bootstrap log."
    msg_generated_password_logs_hint="Check the log with: docker compose logs bootstrap"
    msg_prompt_turn="Enable the built-in TURN relay (coturn) for WebRTC P2P? [Y/n]: "
    msg_turn_enabled="TURN enabled: the coturn container will start, credentials written to .env."
    msg_turn_disabled="TURN disabled: WebRTC clients will only use host candidates."
    msg_turn_firewall="Open these ports on the server firewall: 3478/tcp + 3478/udp (TURN signaling) and 49160-49259/udp (media relay)."
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

if ! command -v curl >/dev/null 2>&1; then
    echo "$msg_curl_required" >&2
    exit 1
fi

dotenv_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

is_ipv4_address() {
    local address="$1"
    local octets=()
    local octet
    IFS='.' read -r -a octets <<<"$address"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_ipv6_address() {
    local address="$1"
    [[ "$address" == *:* ]] && [[ "$address" =~ ^[0-9a-fA-F:]+$ ]]
}

detect_public_ip() {
    local endpoint
    local detected_ip

    for endpoint in \
        "https://api.ipify.org" \
        "https://checkip.amazonaws.com" \
        "https://icanhazip.com"; do

        detected_ip="$(
            curl \
                --fail \
                --silent \
                --show-error \
                --location \
                --max-time 5 \
                --proto '=https' \
                --tlsv1.2 \
                "$endpoint" 2>/dev/null || true
        )"
        detected_ip="${detected_ip//$'\r'/}"
        detected_ip="${detected_ip//$'\n'/}"

        if is_ipv4_address "$detected_ip" || is_ipv6_address "$detected_ip"; then
            printf '%s' "$detected_ip"
            return 0
        fi
    done

    return 1
}

backend_image="ghcr.io/looneman1/voxhold-backend:latest"
frontend_image="ghcr.io/looneman1/voxhold-frontend:latest"
frontend_port="8080"

echo "$msg_deployment_mode"
echo "  1) $msg_mode_native"
echo "  2) $msg_mode_web"
printf '%s' "$prompt_choose"
read -r mode

case "$mode" in
    1) edge_upstream="backend:8080"; compose_args=() ;;
    2) compose_args=(--profile web) ;;
    *) echo "$msg_choose_error" >&2; exit 1 ;;
esac

printf '%s' "$prompt_autostart"
read -r autostart_answer
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

printf '%s' "$prompt_backend_image [$backend_image]: "
read -r selected_backend_image
backend_image=${selected_backend_image:-$backend_image}

if [[ "$mode" == "2" ]]; then
    printf '%s' "$prompt_frontend_image [$frontend_image]: "
    read -r selected_frontend_image
    frontend_image=${selected_frontend_image:-$frontend_image}
    printf '%s' "$prompt_frontend_port [$frontend_port]: "
    read -r selected_frontend_port
    frontend_port=${selected_frontend_port:-$frontend_port}
    if [[ ! "$frontend_port" =~ ^[0-9]+$ ]] || (( frontend_port < 1 || frontend_port > 65535 )); then
        echo "$msg_port_error" >&2
        exit 1
    fi
    edge_upstream="frontend:$frontend_port"
fi

printf '%s' "$prompt_public_host"
read -r public_host
if [[ -z "$public_host" ]]; then
    echo "$msg_detecting_public_ip"
    if ! public_host="$(detect_public_ip)"; then
        echo "$msg_public_ip_detection_error" >&2
        exit 1
    fi
    echo "$msg_detected_public_ip $public_host"
elif [[ "$public_host" =~ [[:space:]] ]]; then
    echo "$msg_public_ip_detection_error" >&2
    exit 1
fi

printf '%s' "$prompt_instance_name"
read -r instance_name
instance_name=${instance_name:-Voxhold}
printf '%s' "$prompt_owner_username"
read -r bootstrap_username
bootstrap_username=${bootstrap_username:-owner}
printf '%s' "$prompt_owner_password"
read -r -s bootstrap_password
printf '\n'

default_webrtc_ip="$public_host"
if ! is_ipv4_address "$default_webrtc_ip" &&
   ! is_ipv6_address "$default_webrtc_ip"; then
    default_webrtc_ip="$(detect_public_ip || true)"
fi

if [[ -n "$default_webrtc_ip" ]]; then
    printf '%s' "$prompt_webrtc_ip [$default_webrtc_ip]: "
    read -r webrtc_public_ip
    webrtc_public_ip=${webrtc_public_ip:-$default_webrtc_ip}
else
    printf '%s' "$prompt_webrtc_ip: "
    read -r webrtc_public_ip
fi

if ! is_ipv4_address "$webrtc_public_ip" &&
   ! is_ipv6_address "$webrtc_public_ip"; then
    echo "$msg_webrtc_ip_error" >&2
    exit 1
fi

printf '%s' "$msg_prompt_turn"
read -r turn_answer
case "$turn_answer" in
    n|N|no|NO|No|н|Н|нет|НЕТ|Нет)
        enable_turn="false"
        ;;
    *)
        enable_turn="true"
        ;;
esac

if [[ "$enable_turn" == "true" ]]; then
    echo "$msg_turn_enabled"
    turn_username="voxhold"
    turn_password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)"
    ice_servers="turn:${webrtc_public_ip}:3478?transport=udp,turn:${webrtc_public_ip}:3478?transport=tcp"
    ice_username="$turn_username"
    ice_credential="$turn_password"
    compose_args+=(--profile turn)
else
    echo "$msg_turn_disabled"
    turn_username="voxhold"
    turn_password=""
    ice_servers=""
    ice_username=""
    ice_credential=""
fi

tls_mode="domain"
caddy_site_address="$public_host"
caddyfile="./Caddyfile"
if is_ipv4_address "$public_host" || is_ipv6_address "$public_host"; then
    tls_mode="ip"
    caddyfile="./Caddyfile.ip"
    if is_ipv6_address "$public_host"; then
        caddy_site_address="[$public_host]"
    fi
    echo "$msg_ip_warning"
    echo "$msg_ip_hint"
fi

cat > .env <<EOF
VOXHOLD_BACKEND_IMAGE=$(dotenv_quote "$backend_image")
VOXHOLD_FRONTEND_IMAGE=$(dotenv_quote "$frontend_image")
VOXHOLD_FRONTEND_PORT=$(dotenv_quote "$frontend_port")
VOXHOLD_RESTART_POLICY=$(dotenv_quote "$restart_policy")
VOXHOLD_TLS_MODE=$(dotenv_quote "$tls_mode")
VOXHOLD_CADDYFILE=$(dotenv_quote "$caddyfile")
PUBLIC_HOST=$(dotenv_quote "$public_host")
CADDY_SITE_ADDRESS=$(dotenv_quote "$caddy_site_address")
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
TURN_USERNAME=$(dotenv_quote "$turn_username")
TURN_PASSWORD=$(dotenv_quote "$turn_password")
TURN_REALM=voxhold
TURN_LISTEN_PORT=3478
TURN_RELAY_PORT_MIN=49160
TURN_RELAY_PORT_MAX=49259
WEBRTC_ICE_SERVERS=$(dotenv_quote "$ice_servers")
WEBRTC_ICE_USERNAME=$(dotenv_quote "$ice_username")
WEBRTC_ICE_CREDENTIAL=$(dotenv_quote "$ice_credential")
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
if [[ -z "$bootstrap_password" ]]; then
    bootstrap_logs="$(
        docker compose "${compose_args[@]}" logs --no-color bootstrap 2>&1 || true
    )"
    generated_owner_password=""
    while IFS= read -r bootstrap_log_line; do
        case "$bootstrap_log_line" in
            *"generated one-time owner password: "*)
                generated_owner_password="${bootstrap_log_line##*generated one-time owner password: }"
                ;;
        esac
    done <<< "$bootstrap_logs"

    if [[ -n "$generated_owner_password" ]]; then
        echo "$msg_generated_owner_password $generated_owner_password"
        echo "$msg_save_generated_owner_password"
    else
        echo "$msg_generated_password_unavailable" >&2
        echo "$msg_generated_password_logs_hint" >&2
    fi
    unset bootstrap_logs generated_owner_password bootstrap_log_line
    echo
fi
if [[ "$enable_turn" == "true" ]]; then
    echo "$msg_turn_firewall"
fi
echo "$msg_running https://$caddy_site_address"
echo "$msg_native_url https://$caddy_site_address"
