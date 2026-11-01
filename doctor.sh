#!/usr/bin/env bash
# Read-only installation self-check. Prints OK/WARN/FAIL lines and exits 1 when
# something is FAIL. It never changes the system and never asks for sudo.
set -Eeuo pipefail

# Disable MSYS path mangling of POSIX-looking arguments (no-op on Linux).
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
cd "$DEPLOY_DIR"

env_value() {
    sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1 | sed 's/^"//; s/"$//'
}

failures=0
ok()   { echo "OK:   $1"; }
warn() { echo "WARN: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

[[ -f .env ]] || { echo "FAIL: .env not found in $DEPLOY_DIR"; exit 1; }

public_host="$(env_value PUBLIC_HOST)"
public_ip="$(env_value WEBRTC_PUBLIC_IP)"
profiles="$(env_value COMPOSE_PROFILES)"
public_url="$(env_value VOXHOLD_PUBLIC_URL)"
[[ -n "$public_url" ]] || public_url="https://$public_host"

# 1. .env permissions (secrets live there).
if mode="$(stat -c %a .env 2>/dev/null)"; then
    if [[ "$mode" == "600" ]]; then ok ".env permissions are 600"; else warn ".env permissions are $mode (expected 600): chmod 600 .env"; fi
fi

# 2. DNS of PUBLIC_HOST matches the advertised media address.
if [[ -n "$public_host" && -n "$public_ip" && ! "$public_host" =~ ^[0-9.]+$ ]]; then
    resolved="$(getent ahosts "$public_host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    if [[ -z "$resolved" ]]; then
        fail "$public_host does not resolve"
    elif [[ " $resolved " == *" $public_ip "* ]]; then
        ok "$public_host resolves to WEBRTC_PUBLIC_IP ($public_ip)"
    else
        warn "$public_host resolves to ${resolved}but WEBRTC_PUBLIC_IP is $public_ip"
    fi
fi

# 3. Endpoints.
for path in healthz readyz; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$public_url/$path" 2>/dev/null)" || code=000
    case "$code" in
        200|204) ok "/$path answered HTTP $code" ;;
        404)     warn "/$path answered 404 (backend without this endpoint)" ;;
        *)       fail "/$path answered HTTP $code at $public_url" ;;
    esac
done

# 4. Certificate lifetime.
if [[ "$public_url" == https://* ]] && command -v openssl >/dev/null 2>&1; then
    host="${public_url#https://}"; host="${host%%/*}"
    end="$(echo | timeout 10 openssl s_client -servername "${host%%:*}" -connect "$host$([[ "$host" == *:* ]] || echo :443)" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
    if [[ -n "$end" ]] && epoch="$(date -d "$end" +%s 2>/dev/null)"; then
        days=$(( (epoch - $(date +%s)) / 86400 ))
        if (( days < 7 )); then fail "TLS certificate expires in $days days"; else ok "TLS certificate valid for $days more days"; fi
    else
        warn "could not read the TLS certificate"
    fi
fi

# 5. Containers running and not restart-looping.
if command -v docker >/dev/null 2>&1; then
    for service in backend frontend caddy; do
        # -a: an exited or restarting container must report its state, not "missing".
        id="$(docker compose ps -a -q "$service" 2>/dev/null || true)"
        [[ -n "$id" ]] || { [[ "$service" == caddy ]] && continue; fail "$service container is missing"; continue; }
        state="$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || echo unknown)"
        restarts="$(docker inspect -f '{{.RestartCount}}' "$id" 2>/dev/null || echo 0)"
        if [[ "$state" != "running" ]]; then fail "$service is $state"
        elif (( restarts >= 3 )); then warn "$service restarted $restarts times"
        else ok "$service is running"; fi
    done
else
    warn "docker is not available to this user; container checks skipped"
fi

# 6. TURN secret present when the turn profile is enabled.
if [[ ",$profiles," == *,turn,* ]]; then
    if [[ -n "$(env_value WEBRTC_TURN_SECRET)" || -n "$(env_value TURN_PASSWORD)" ]]; then ok "TURN secret is configured"
    else fail "turn profile is enabled but WEBRTC_TURN_SECRET is empty"; fi
fi

# 7. Free disk space.
root="/var/lib/docker"; [[ -d "$root" ]] || root="$DEPLOY_DIR"
avail_mb="$(df -Pm "$root" | awk 'NR==2 {print $4}')"
if (( avail_mb < 1024 )); then fail "only ${avail_mb}MB free on $root"; else ok "${avail_mb}MB free on $root"; fi

# 8. Firewall (read only; only when ufw is installed and active).
if command -v ufw >/dev/null 2>&1; then
    status="$(ufw status 2>/dev/null || true)"
    if [[ "$status" == *"Status: active"* ]]; then
        # Same defaults as compose.yaml when .env does not set the ports.
        ports=(80/tcp 443/tcp "$(env_value WEBRTC_UDP_PORT | grep . || echo 50000)/udp" "$(env_value WEBRTC_STREAM_UDP_PORT | grep . || echo 50001)/udp")
        if [[ ",$profiles," == *,turn,* ]]; then
            turn_port="$(env_value TURN_LISTEN_PORT | grep . || echo 3478)"
            ports+=("$turn_port/udp" "$turn_port/tcp")
        fi
        for port in "${ports[@]}"; do
            if grep -q "^${port}[[:space:]]" <<<"$status"; then ok "ufw allows $port"; else warn "ufw has no rule for $port"; fi
        done
    else
        warn "ufw is not active or needs root to read; firewall not checked"
    fi
fi

# 9. Backup age and offsite status.
latest="$(ls -1t backups/voxhold-*.tar.gz 2>/dev/null | head -n 1 || true)"
if [[ -z "$latest" ]]; then
    warn "no backups yet in ./backups"
else
    age=$(( ($(date +%s) - $(stat -c %Y "$latest")) / 3600 ))
    if (( age > 26 )); then warn "latest backup is ${age}h old"; else ok "latest backup is ${age}h old"; fi
fi
if [[ -n "$(env_value BACKUP_OFFSITE_DIR)$(env_value BACKUP_OFFSITE_CMD)" ]]; then
    if [[ -f backups/.offsite-status ]] && [[ "$(cut -d' ' -f1 backups/.offsite-status)" == "ok" ]]; then ok "last offsite copy succeeded"
    else warn "offsite backup is configured but its last run did not succeed"; fi
fi

echo
if (( failures > 0 )); then echo "$failures check(s) failed."; exit 1; fi
echo "No failed checks."
