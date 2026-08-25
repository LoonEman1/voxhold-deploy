#!/usr/bin/env bash
# Consistent cold SQLite backup: verifies the archive before publishing it,
# restores the backend's original state on any failure, writes a DR manifest,
# keeps a bounded set of archives and mirrors them offsite when configured.
set -Eeuo pipefail

# Disable MSYS path mangling of POSIX-looking arguments (no-op on Linux).
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

# pwd -W yields a Docker-mountable Windows path under Git Bash/MSYS and
# gracefully falls back to plain pwd on Linux.
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
cd "$DEPLOY_DIR"
mkdir -p backups
chmod 700 backups

env_value() {
    sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1 | sed 's/^"//; s/"$//'
}

# Knob precedence: real environment variable > .env > built-in default.
cfg() {
    local name="$1" default="$2" value="${!1:-}"
    if [[ -z "$value" ]]; then value="$(env_value "$name")"; fi
    if [[ -z "$value" ]]; then value="$default"; fi
    printf '%s' "$value"
}

die() {
    echo "Backup failed: $*" >&2
    exit 1
}

keep_count="$(cfg BACKUP_KEEP_COUNT 7)"
offsite_dir="$(cfg BACKUP_OFFSITE_DIR '')"
offsite_cmd="$(cfg BACKUP_OFFSITE_CMD '')"

# Serialize concurrent invocations (cron + manual). flock is standard on
# Linux servers; without it, fall back to a best-effort advisory note.
use_flock=0
if command -v flock >/dev/null 2>&1; then
    use_flock=1
    exec 9>"backups/.backup.lock"
    flock -n 9 || die "another backup is already running"
else
    echo "NOTE: flock unavailable; concurrent-backup guard skipped." >&2
fi

command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

backend_container="$(docker compose ps -q backend)"
[[ -n "$backend_container" ]] || die "backend container is not created."

# Remember whether the backend served traffic before the backup so that the
# EXIT trap restores exactly the original state.
backend_was_running=0
if [[ "$(docker inspect -f '{{.State.Running}}' "$backend_container")" == "true" ]]; then
    backend_was_running=1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="voxhold-$timestamp.tar.gz"
partial_name="backups/$backup_name.partial"
final_name="backups/$backup_name"
sha_name="backups/$backup_name.sha256"
manifest_file="backups/.manifest.$$"

cleanup() {
    local status=$?
    rm -f -- "$manifest_file"
    rm -f -- "$partial_name"
    if (( status != 0 )); then
        echo "Backend state restored; nothing was published." >&2
    fi
    # Bring the backend back exactly when it was serving before the backup.
    if (( backend_was_running )); then
        docker compose start backend >/dev/null 2>&1 \
            || echo "WARNING: could not restart backend automatically; run: docker compose start backend" >&2
    fi
}
trap cleanup EXIT

# Best-effort database schema version for the recovery manifest.
db_schema_version="$(docker exec "$backend_container" \
    sh -c 'migrate -path "$MIGRATIONS_PATH" -database "sqlite://$DATABASE_PATH" version' 2>/dev/null \
    | grep -oE '[0-9]+' | tail -n 1 || true)"

# Refuse to fill the disk: require roughly three times the uncompressed size.
data_kb="$(docker exec "$backend_container" du -sk /app/data 2>/dev/null | awk '{print $1}' || true)"
if [[ -n "$data_kb" ]] && [[ "$data_kb" =~ ^[0-9]+$ ]] && (( data_kb > 0 )); then
    need_mb=$(( data_kb / 1024 * 3 + 64 ))
    avail_mb="$(df -Pm . | awk 'NR==2 {print $4}')"
    (( avail_mb >= need_mb )) ||
        die "not enough free space: ${need_mb}MB required, ${avail_mb}MB available."
fi

# Disaster-recovery manifest: enough to rebuild elsewhere, zero secrets.
backend_image="$(env_value VOXHOLD_BACKEND_IMAGE)"
frontend_image="$(env_value VOXHOLD_FRONTEND_IMAGE)"
backend_digest="$(docker inspect -f '{{index .RepoDigests 0}}' "$backend_container" 2>/dev/null \
    || docker inspect -f '{{.Image}}' "$backend_container")"
backend_digest="$(printf '%s' "$backend_digest" | tr -d '[:space:]')"
backend_digest="${backend_digest//$'\n'/}"
backend_digest="${backend_digest//$'\r'/}"
cat >"$manifest_file" <<EOF
{
  "created_utc": "$timestamp",
  "hostname": "$(hostname)",
  "public_host": "$(env_value PUBLIC_HOST)",
  "tls_mode": "$(env_value VOXHOLD_TLS_MODE)",
  "compose_profiles": "$(env_value COMPOSE_PROFILES)",
  "backend_image": "$backend_image",
  "backend_image_digest": "$backend_digest",
  "frontend_image": "$frontend_image",
  "webRTC_relay_range": "$(env_value TURN_RELAY_PORT_MIN)-$(env_value TURN_RELAY_PORT_MAX)/udp, listen $(env_value TURN_LISTEN_PORT)",
  "database_schema_version": "${db_schema_version:-unknown}",
  "notes": "Secrets (.env: TURN_PASSWORD, BOOTSTRAP_PASSWORD, tokens) are intentionally excluded; restore them from your secret store."
}
EOF

echo "Stopping backend briefly for a consistent SQLite backup..."
docker compose stop backend

# The helper reads the manifest from stdin and streams the tar to stdout:
# no host-path binds, so the script behaves identically on any platform.
# BusyBox tar cannot combine two -C switches, so stage a flat directory.
docker run --rm -i \
    --volumes-from "$backend_container" \
    alpine:3.22 \
    sh -c '
        set -e
        mkdir /out
        cp -a /app/data /out/data
        cat > /out/manifest.json
        cd /out
        exec tar czf - manifest.json data
    ' \
    <"$manifest_file" >"$partial_name"

# Verify before publishing: integrity first, then an atomic rename.
tar -tzf "$partial_name" >/dev/null || die "archive verification failed"
mv -- "$partial_name" "$final_name"
sha256sum "$final_name" | awk '{print $1}' >"$sha_name"

# Retention: keep the newest keep_count archives (+ checksum sidecars).
while IFS= read -r stale_archive; do
    rm -f -- "$stale_archive" "${stale_archive%.tar.gz}.sha256"
done < <(ls -1t backups/voxhold-*.tar.gz 2>/dev/null | tail -n +"$((keep_count + 1))")

# Offsite copy: directory mirror or custom command (rsync/rclone/restic).
offsite_note="not configured"
if [[ -n "$offsite_dir" ]]; then
    mkdir -p "$offsite_dir"
    cp -f -- "$final_name" "$sha_name" "$offsite_dir/"
    offsite_note="$offsite_dir"
elif [[ -n "$offsite_cmd" ]]; then
    if bash -c "$offsite_cmd" '$final_name'; then
        offsite_note="custom command"
    else
        echo "WARNING: offsite command failed." >&2
        offsite_note="custom command FAILED"
    fi
fi

echo "Backup created: backups/$backup_name"
echo "Checksum:      backups/$backup_name.sha256"
echo "Offsite:       $offsite_note"
echo "Retention:     keeping $keep_count newest archives"

