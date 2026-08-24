#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"
umask 077

usage() {
    cat <<'EOF'
Usage: ./update.sh [--backend-version <version>]
Использование: ./update.sh [--backend-version <версия>]

Without arguments, the script pulls the image references currently stored in
.env. Use --backend-version 0.2.0 (or v0.2.0) to switch the official backend
image to an exact published release before updating the stack.

Без аргументов скрипт загружает образы, уже указанные в .env. Используйте
--backend-version 0.2.0 (или v0.2.0), чтобы перед обновлением переключить
официальный образ backend на точный опубликованный релиз.
EOF
}

backend_version=""
case "$#" in
    0) ;;
    2)
        if [[ "$1" != "--backend-version" ]]; then
            usage >&2
            exit 2
        fi
        backend_version="${2#v}"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if [[ -n "$backend_version" ]] &&
   [[ ! "$backend_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    echo "Invalid backend version: $backend_version" >&2
    echo "Некорректная версия backend: $backend_version" >&2
    exit 2
fi

if [[ ! -f .env ]]; then
    echo ".env is missing. Run install.sh first." >&2
    exit 1
fi

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

# Upgrade .env files created before public IP certificates were supported.
if ! grep -q '^VOXHOLD_CADDYFILE=' .env; then
    public_host="$(awk -F= '$1 == "PUBLIC_HOST" {print $2}' .env | tail -n 1 | tr -d '\"')"
    tls_mode="domain"
    caddyfile="./Caddyfile"
    caddy_site_address="$public_host"
    if is_ipv4_address "$public_host" || is_ipv6_address "$public_host"; then
        tls_mode="ip"
        caddyfile="./Caddyfile.ip"
        if is_ipv6_address "$public_host"; then
            caddy_site_address="[$public_host]"
        fi
    fi

    migration_env="$(mktemp "$DEPLOY_DIR/.env.migration.XXXXXX")"
    awk \
        -v mode="$tls_mode" \
        -v caddyfile="$caddyfile" \
        -v site="$caddy_site_address" '
        { print }
        /^VOXHOLD_TLS_MODE=/ { has_mode = 1 }
        /^CADDY_SITE_ADDRESS=/ { has_site = 1 }
        END {
            if (!has_mode) print "VOXHOLD_TLS_MODE=\"" mode "\""
            print "VOXHOLD_CADDYFILE=\"" caddyfile "\""
            if (!has_site) print "CADDY_SITE_ADDRESS=\"" site "\""
        }
    ' .env >"$migration_env"
    chmod 600 "$migration_env"
    mv -- "$migration_env" .env
    echo "TLS configuration migrated: $tls_mode"
    echo "Конфигурация TLS обновлена: $tls_mode"
fi

# Upgrade .env files created before WebRTC ICE configuration was split into
# browser clients (WEBRTC_CLIENT_ICE_*, served through the authenticated
# runtime endpoint) and the backend's own Pion sessions (WEBRTC_SERVER_ICE_*,
# normally empty on a public deployment). Idempotent: a migrated file is left
# untouched on subsequent runs.
env_value() {
    sed -n "s/^$1=//p" .env | tail -n 1 | sed 's/^"//; s/"$//'
}

has_env_key() {
    grep -q "^$1=" .env
}

legacy_ice_present=0
if grep -q '^WEBRTC_ICE_' .env; then
    legacy_ice_present=1
fi

client_ice_servers="$(env_value WEBRTC_CLIENT_ICE_SERVERS)"
if [[ -z "$client_ice_servers" ]] && (( legacy_ice_present )); then
    client_ice_servers="$(env_value WEBRTC_ICE_SERVERS)"
fi
client_ice_username="$(env_value WEBRTC_CLIENT_ICE_USERNAME)"
if [[ -z "$client_ice_username" ]] && (( legacy_ice_present )); then
    client_ice_username="$(env_value WEBRTC_ICE_USERNAME)"
fi
client_ice_credential="$(env_value WEBRTC_CLIENT_ICE_CREDENTIAL)"
if [[ -z "$client_ice_credential" ]] && (( legacy_ice_present )); then
    client_ice_credential="$(env_value WEBRTC_ICE_CREDENTIAL)"
fi
server_ice_servers="$(env_value WEBRTC_SERVER_ICE_SERVERS)"
server_ice_username="$(env_value WEBRTC_SERVER_ICE_USERNAME)"
server_ice_credential="$(env_value WEBRTC_SERVER_ICE_CREDENTIAL)"
user_quota="$(env_value TURN_USER_QUOTA)"
# A shared TURN_USERNAME cannot use per-user quotas; keep the explicit 0 when
# the variable is missing so the total-quota bound is the only limit.
[[ "$user_quota" =~ ^[0-9]+$ ]] || user_quota=0

turn_relay_port_min="$(env_value TURN_RELAY_PORT_MIN)"
turn_relay_port_max="$(env_value TURN_RELAY_PORT_MAX)"
[[ "$turn_relay_port_min" =~ ^[0-9]+$ ]] || turn_relay_port_min=49160
[[ "$turn_relay_port_max" =~ ^[0-9]+$ ]] || turn_relay_port_max=49559
if (( turn_relay_port_max < turn_relay_port_min )); then
    turn_relay_port_max=$turn_relay_port_min
fi
# One allocation roughly consumes one relay port, so the total quota must
# never exceed the real capacity of the configured range (a legacy 100-port
# range therefore keeps a quota of 100 until the firewall range is widened).
total_quota="$(( turn_relay_port_max - turn_relay_port_min + 1 ))"

compose_profiles="$(env_value COMPOSE_PROFILES)"
if ! has_env_key COMPOSE_PROFILES; then
    edge_upstream_for_profiles="$(env_value EDGE_UPSTREAM)"
    compose_profiles=""
    if [[ "$edge_upstream_for_profiles" == frontend:* ]]; then
        compose_profiles="web"
    fi
    # Enable the coturn profile only when client ICE actually points at this
    # deployment's built-in coturn and TURN authentication is configured.
    turn_listen_port_for_profiles="$(env_value TURN_LISTEN_PORT)"
    [[ "$turn_listen_port_for_profiles" =~ ^[0-9]+$ ]] || turn_listen_port_for_profiles=3478
    built_in_turn_host="$(env_value WEBRTC_PUBLIC_IP)"
    if is_ipv6_address "$built_in_turn_host"; then
        built_in_turn_host="[$built_in_turn_host]"
    fi
    if [[ -n "$(env_value TURN_PASSWORD)" ]] &&
       [[ "$client_ice_servers" == *"turn:${built_in_turn_host}:${turn_listen_port_for_profiles}?"* ]]; then
        compose_profiles="${compose_profiles:+$compose_profiles,}turn"
    fi
fi

migration_needed=0
for env_key in \
    COMPOSE_PROFILES \
    WEBRTC_CLIENT_ICE_SERVERS \
    WEBRTC_CLIENT_ICE_USERNAME \
    WEBRTC_CLIENT_ICE_CREDENTIAL \
    WEBRTC_SERVER_ICE_SERVERS \
    WEBRTC_SERVER_ICE_USERNAME \
    WEBRTC_SERVER_ICE_CREDENTIAL \
    TURN_USER_QUOTA \
    TURN_TOTAL_QUOTA; do
    has_env_key "$env_key" || migration_needed=1
done
# The legacy trio doubles as a compatibility alias for the published backend:
# re-sync it whenever it is missing or diverged from the client values.
if [[ "$(env_value WEBRTC_ICE_SERVERS)" != "$client_ice_servers" ]] ||
   [[ "$(env_value WEBRTC_ICE_USERNAME)" != "$client_ice_username" ]] ||
   [[ "$(env_value WEBRTC_ICE_CREDENTIAL)" != "$client_ice_credential" ]]; then
    migration_needed=1
fi

if (( migration_needed )); then
    migration_env="$(mktemp "$DEPLOY_DIR/.env.migration.XXXXXX")"
    awk \
        -v profiles="$compose_profiles" \
        -v client_servers="$client_ice_servers" \
        -v client_username="$client_ice_username" \
        -v client_credential="$client_ice_credential" \
        -v server_servers="$server_ice_servers" \
        -v server_username="$server_ice_username" \
        -v server_credential="$server_ice_credential" \
        -v user_quota="$user_quota" \
        -v total_quota="$total_quota" '
        # Legacy WEBRTC_ICE_* lines are re-appended below, kept in sync with
        # WEBRTC_CLIENT_ICE_*: the currently published backend still reads
        # only the legacy names for both its own Pion sessions and the
        # runtime browser endpoint.
        /^WEBRTC_ICE_SERVERS=/ || /^WEBRTC_ICE_USERNAME=/ || /^WEBRTC_ICE_CREDENTIAL=/ {
            next
        }
        {
            if      ($0 ~ /^COMPOSE_PROFILES=/)             has_profiles = 1
            else if ($0 ~ /^WEBRTC_CLIENT_ICE_SERVERS=/)    has_client_servers = 1
            else if ($0 ~ /^WEBRTC_CLIENT_ICE_USERNAME=/)   has_client_username = 1
            else if ($0 ~ /^WEBRTC_CLIENT_ICE_CREDENTIAL=/) has_client_credential = 1
            else if ($0 ~ /^WEBRTC_SERVER_ICE_SERVERS=/)    has_server_servers = 1
            else if ($0 ~ /^WEBRTC_SERVER_ICE_USERNAME=/)   has_server_username = 1
            else if ($0 ~ /^WEBRTC_SERVER_ICE_CREDENTIAL=/) has_server_credential = 1
            else if ($0 ~ /^TURN_USER_QUOTA=/)              has_user_quota = 1
            else if ($0 ~ /^TURN_TOTAL_QUOTA=/)             has_total_quota = 1
            print
            next
        }
        END {
            if (!has_profiles)           print "COMPOSE_PROFILES=\"" profiles "\""
            if (!has_client_servers)     print "WEBRTC_CLIENT_ICE_SERVERS=\"" client_servers "\""
            if (!has_client_username)    print "WEBRTC_CLIENT_ICE_USERNAME=\"" client_username "\""
            if (!has_client_credential)  print "WEBRTC_CLIENT_ICE_CREDENTIAL=\"" client_credential "\""
            if (!has_server_servers)     print "WEBRTC_SERVER_ICE_SERVERS=\"" server_servers "\""
            if (!has_server_username)    print "WEBRTC_SERVER_ICE_USERNAME=\"" server_username "\""
            if (!has_server_credential)  print "WEBRTC_SERVER_ICE_CREDENTIAL=\"" server_credential "\""
            if (!has_user_quota)         print "TURN_USER_QUOTA=\"" user_quota "\""
            if (!has_total_quota)        print "TURN_TOTAL_QUOTA=\"" total_quota "\""
            print "WEBRTC_ICE_SERVERS=\"" client_servers "\""
            print "WEBRTC_ICE_USERNAME=\"" client_username "\""
            print "WEBRTC_ICE_CREDENTIAL=\"" client_credential "\""
        }
    ' .env >"$migration_env"
    chmod 600 "$migration_env"
    mv -- "$migration_env" .env

    echo "WebRTC ICE configuration migrated: browser clients use WEBRTC_CLIENT_ICE_*, legacy WEBRTC_ICE_* kept in sync for the current backend."
    echo "Конфигурация WebRTC ICE обновлена: браузеры используют WEBRTC_CLIENT_ICE_*, legacy-переменные WEBRTC_ICE_* синхронизированы для текущего backend."
fi

if [[ -n "$backend_version" ]]; then
    backend_image="ghcr.io/looneman1/voxhold-backend:$backend_version"
    temporary_env="$(mktemp "$DEPLOY_DIR/.env.tmp.XXXXXX")"
    cleanup() {
        if [[ -n "${temporary_env:-}" && -f "$temporary_env" ]]; then
            rm -f -- "$temporary_env"
        fi
    }
    trap cleanup EXIT

    awk -v replacement="VOXHOLD_BACKEND_IMAGE=\"$backend_image\"" '
        /^VOXHOLD_BACKEND_IMAGE=/ {
            print replacement
            found = 1
            next
        }
        { print }
        END {
            if (!found) {
                print replacement
            }
        }
    ' .env > "$temporary_env"
    chmod 600 "$temporary_env"
    mv -- "$temporary_env" .env
    temporary_env=""

    echo "Backend release selected: $backend_version"
    echo "Выбран релиз backend: $backend_version"
fi

# COMPOSE_PROFILES is persisted in .env by the migration above (and by the
# current installer), so plain compose commands operate on exactly the service
# set selected during installation — no CLI --profile flags required.
docker compose pull
docker compose up -d --remove-orphans
docker compose ps
