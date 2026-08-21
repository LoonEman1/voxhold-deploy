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

edge_upstream="$(awk -F= '$1 == "EDGE_UPSTREAM" {print $2}' .env | tr -d '\"')"
compose_args=()
if [[ "$edge_upstream" == frontend:* ]]; then
    compose_args=(--profile web)
fi

docker compose "${compose_args[@]}" pull
docker compose "${compose_args[@]}" up -d --remove-orphans
docker compose ps
