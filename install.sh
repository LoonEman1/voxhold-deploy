#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"
umask 077

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required. Install Docker Engine and Docker Compose first." >&2
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose v2 is required." >&2
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

echo "Deployment mode:"
echo "  1) backend + native client only"
echo "  2) backend + website + native client"
read -r -p "Choose [1/2]: " mode

case "$mode" in
    1) edge_upstream="backend:8080"; compose_args=() ;;
    2) compose_args=(--profile web) ;;
    *) echo "Choose 1 or 2." >&2; exit 1 ;;
esac

read -r -p "Backend image [$backend_image]: " selected_backend_image
backend_image=${selected_backend_image:-$backend_image}

if [[ "$mode" == "2" ]]; then
    read -r -p "Frontend image [$frontend_image]: " selected_frontend_image
    frontend_image=${selected_frontend_image:-$frontend_image}
    read -r -p "Frontend internal port [$frontend_port]: " selected_frontend_port
    frontend_port=${selected_frontend_port:-$frontend_port}
    if [[ ! "$frontend_port" =~ ^[0-9]+$ ]] || (( frontend_port < 1 || frontend_port > 65535 )); then
        echo "Frontend port must be between 1 and 65535." >&2
        exit 1
    fi
    edge_upstream="frontend:$frontend_port"
fi

read -r -p "Public domain or IP address: " public_host
if [[ -z "$public_host" || "$public_host" =~ [[:space:]] ]]; then
    echo "A public domain or IP address is required." >&2
    exit 1
fi

read -r -p "Instance name [Voxhold]: " instance_name
instance_name=${instance_name:-Voxhold}
read -r -p "Owner username [owner]: " bootstrap_username
bootstrap_username=${bootstrap_username:-owner}
read -r -s -p "Owner password (empty = generate once): " bootstrap_password
printf '\n'

read -r -p "Public WebRTC IP [$public_host]: " webrtc_public_ip
webrtc_public_ip=${webrtc_public_ip:-$public_host}

if [[ "$public_host" =~ ^[0-9a-fA-F:.]+$ ]]; then
    echo "Warning: Caddy uses a locally trusted certificate for IP addresses by default."
    echo "Native clients must trust that CA; for a public website, use a domain or mount an IP certificate."
fi

cat > .env <<EOF
VOXHOLD_BACKEND_IMAGE=$(dotenv_quote "$backend_image")
VOXHOLD_FRONTEND_IMAGE=$(dotenv_quote "$frontend_image")
VOXHOLD_FRONTEND_PORT=$(dotenv_quote "$frontend_port")
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

echo "Pulling Voxhold images..."
docker compose "${compose_args[@]}" pull
echo "Starting Voxhold..."
docker compose "${compose_args[@]}" up -d
docker compose ps

echo
echo "Voxhold is running at: https://$public_host"
echo "Native client base URL: https://$public_host"
