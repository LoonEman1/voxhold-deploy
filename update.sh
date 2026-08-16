#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"

if [[ ! -f .env ]]; then
    echo ".env is missing. Run install.sh first." >&2
    exit 1
fi

edge_upstream="$(awk -F= '$1 == "EDGE_UPSTREAM" {print $2}' .env | tr -d '\"')"
compose_args=()
if [[ "$edge_upstream" == "frontend:8080" ]]; then
    compose_args=(--profile web)
fi

docker compose pull
docker compose "${compose_args[@]}" up -d --remove-orphans
docker compose ps
