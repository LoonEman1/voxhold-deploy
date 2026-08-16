#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"
mkdir -p backups

backend_container="$(docker compose ps -q backend)"
if [[ -z "$backend_container" ]]; then
    echo "Backend container is not created." >&2
    exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="voxhold-$timestamp.tar.gz"

echo "Stopping backend briefly for a consistent SQLite backup..."
docker compose stop backend
docker run --rm \
    --volumes-from "$backend_container" \
    -v "$DEPLOY_DIR/backups:/backup" \
    alpine:3.22 \
    tar czf "/backup/$backup_name" -C /app data
docker compose start backend

echo "Backup created: backups/$backup_name"
