#!/usr/bin/env bash
# Single operator watchdog: public endpoint reachability, free disk space and
# freshness of the latest backup. Prints a report and optionally pushes it to
# WATCHDOG_NOTIFY_URL (e.g. an ntfy.sh topic URL). Exit code is non-zero when
# any critical check fails, so systemd OnFailure= works too.
#
# Configure via .env:
#   VOXHOLD_PUBLIC_URL      https://voxhold.example.com   (default: https://PUBLIC_HOST)
#   WATCHDOG_NOTIFY_URL     https://ntfy.sh/my-secret-topic
#   BACKUP_DISK_MIN_FREE_MB 1024                          (docker data root)
#   BACKUP_MAX_AGE_HOURS    26
set -Eeuo pipefail

# Disable MSYS path mangling of POSIX-looking arguments (no-op on Linux).
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
cd "$DEPLOY_DIR"

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

public_url="$(cfg VOXHOLD_PUBLIC_URL '')"
if [[ -z "$public_url" ]]; then
    public_host="$(env_value PUBLIC_HOST)"
    [[ -n "$public_host" ]] || { echo "watchdog: PUBLIC_HOST is not configured" >&2; exit 2; }
    public_url="https://$public_host"
fi

notify_url="$(cfg WATCHDOG_NOTIFY_URL '')"
disk_min_free_mb="$(cfg BACKUP_DISK_MIN_FREE_MB 1024)"
backup_max_age_hours="$(cfg BACKUP_MAX_AGE_HOURS 26)"

problems=()
warnings=()
report=()

add_problem() { problems+=("$1"); report+=("FAIL: $1"); }
add_warning() { warnings+=("$1"); report+=("WARN: $1"); }
add_ok()      { report+=("OK: $1"); }

# 1. Public endpoint (through Caddy, as real clients see it).
http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$public_url/healthz" 2>/dev/null)" && curl_rc=0 || curl_rc=$?
if [[ $curl_rc -ne 0 ]]; then
    http_code=000
fi
case "$http_code" in
    200|204) add_ok "healthz answered HTTP $http_code" ;;
    404)     # Backend without readyz-aware routing still answers; treat as alive.
             add_ok "healthz answered HTTP 404 (unexpected but reachable)" ;;
    *)       add_problem "healthz unreachable at $public_url/healthz (HTTP $http_code)" ;;
esac

# 2. Docker data root free space.
docker_root="/var/lib/docker"
[[ -d "$docker_root" ]] || docker_root="$DEPLOY_DIR"
avail_mb="$(df -Pm "$docker_root" | awk 'NR==2 {print $4}')"
used_percent="$(df -P "$docker_root" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
if (( avail_mb < disk_min_free_mb )); then
    add_problem "only ${avail_mb}MB free on $docker_root (< ${disk_min_free_mb}MB)"
elif (( used_percent >= 85 )); then
    add_warning "disk usage ${used_percent}% on $docker_root (${avail_mb}MB free)"
else
    add_ok "disk fine: ${avail_mb}MB free (${used_percent}% used)"
fi

# 3. Backup freshness.
latest_backup="$(ls -1t backups/voxhold-*.tar.gz 2>/dev/null | head -n 1 || true)"
if [[ -z "$latest_backup" ]]; then
    add_warning "no backup archives found in ./backups yet"
else
    age_hours=$(( ($(date +%s) - $(stat -c %Y "$latest_backup")) / 3600 ))
    if (( age_hours > backup_max_age_hours )); then
        add_problem "latest backup is ${age_hours}h old (> ${backup_max_age_hours}h): $(basename "$latest_backup")"
    else
        add_ok "latest backup ${age_hours}h old: $(basename "$latest_backup")"
    fi
fi

message="Voxhold watchdog $(date -u '+%Y-%m-%dT%H:%M:%SZ')
${report[*]}"

printf '%s\n' "${report[@]}"

if [[ -n "$notify_url" && ( ${#problems[@]} -gt 0 || ${#warnings[@]} -gt 0 ) ]]; then
    curl -fsS --max-time 10 -X POST \
        -H "Title: Voxhold watchdog" \
        -H "Priority: $([[ ${#problems[@]} -gt 0 ]] && echo high || echo default)" \
        --data-binary "$message" "$notify_url" >/dev/null \
        || echo "watchdog: notification delivery failed" >&2
fi

(( ${#problems[@]} == 0 )) || exit 1
exit 0

