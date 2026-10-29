#!/usr/bin/env bash
# Restore a Voxhold backup created by backup.sh.
#
# Safe mode (default): extracts into a NEW docker volume and prints the
# commands to switch over. Production data is never touched.
# Overwrite mode (--into-existing): stops the backend and replaces the
# contents of the current voxhold_data volume, restoring its original state
# on any failure. Use only with a matching schema version (see manifest).
#
# Usage: ./restore.sh backups/voxhold-<timestamp>.tar.gz [--into-existing]
set -Eeuo pipefail

# Disable MSYS path mangling of POSIX-looking arguments (no-op on Linux).
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"

usage() {
    cat <<'EOF'
Usage: ./restore.sh <archive.tar.gz> [--into-existing]
РСЃРїРѕР»СЊР·РѕРІР°РЅРёРµ: ./restore.sh <Р°СЂС…РёРІ.tar.gz> [--into-existing]

Default mode restores the archive into a new volume and leaves production
untouched. --into-existing replaces the current database volume (backend is
stopped for the duration).
EOF
}

archive=""
into_existing=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --into-existing) into_existing=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            [[ -z "$archive" ]] || { usage >&2; exit 2; }
            archive="$1"; shift
            ;;
    esac
done

[[ -f "$archive" ]] || { echo "Archive not found: $archive" >&2; exit 1; }
[[ "$archive" == *.tar.gz ]] || { echo "Expected a .tar.gz archive." >&2; exit 1; }
[[ "$(basename "$archive")" != *.partial ]] || { echo "Refusing to restore a .partial archive." >&2; exit 1; }

backend_container="$(docker compose ps -q backend)"
[[ -n "$backend_container" ]] || { echo "Backend container is not created." >&2; exit 1; }

current_volume="$(docker inspect -f \
    '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}' \
    "$backend_container")"
[[ -n "$current_volume" ]] || { echo "Could not resolve the data volume of the backend container." >&2; exit 1; }

echo "Verifying archive..."
if [[ -f "${archive}.sha256" ]]; then
    expected="$(awk '{print $1}' "${archive}.sha256")"
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || { echo "Checksum mismatch: ${archive}.sha256" >&2; exit 1; }
else
    echo "NOTE: no checksum sidecar (${archive}.sha256); skipping checksum verification." >&2
fi
# grep -q would SIGPIPE tar under pipefail; consume the full listing.
if ! tar -tzf "$archive" | grep '^data/' >/dev/null; then
    echo "Archive does not contain a data/ entry." >&2
    exit 1
fi

if (( into_existing )); then
    target_volume="$current_volume"

    backend_was_running=0
    if [[ "$(docker inspect -f '{{.State.Running}}' "$backend_container")" == "true" ]]; then
        backend_was_running=1
    fi
    restore_backend() {
        if (( backend_was_running )); then
            docker compose start backend >/dev/null 2>&1 \
                || echo "WARNING: could not restart backend automatically; run: docker compose start backend" >&2
        fi
    }
    trap restore_backend EXIT
    echo "Stopping backend for the overwrite..."
    docker compose stop backend

    echo "Overwriting volume $target_volume ..."
    docker run --rm -i \
        --volume "$target_volume:/app" \
        alpine:3.22 \
        sh -c '
            set -e
            mkdir /incoming
            tar xz -C /incoming data
            test -d /incoming/data
            # Stage the incoming tree completely and preserve the current tree
            # before touching the volume root. Recover it if replacement fails.
            tar cf /previous.tar -C /app .
            replacing=0
            recover() {
                code=$?
                trap - EXIT
                if [ "$code" -ne 0 ] && [ "$replacing" = 1 ]; then
                    rm -rf /incoming/data
                    find /app -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
                    tar xf /previous.tar -C /app || echo "WARNING: restore rollback failed; recover from the verified archive" >&2
                fi
                exit "$code"
            }
            trap recover EXIT
            replacing=1
            find /app -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
            cp -a /incoming/data/. /app/
            chown -R 10001:10001 /app
            chmod 770 /app
            trap - EXIT
        '  \
        <"$archive"
    trap - EXIT
    if (( backend_was_running )); then
        docker compose start backend
    fi
    echo "Restore complete: production volume $target_volume was replaced."
else
    target_volume="voxhold_data_restore_$(date -u +%Y%m%dT%H%M%SZ)_$$"
    docker volume create "$target_volume" >/dev/null
    echo "Restoring into a NEW volume $target_volume ..."
    docker run --rm -i \
        --volume "$target_volume:/app" \
        alpine:3.22 \
        sh -c 'set -e; tar xz -C /app --strip-components=1 data; chown -R 10001:10001 /app; chmod 770 /app' \
        <"$archive"

    cat <<EOF

Safe restore complete. The production volume ($current_volume) was NOT modified.

To switch over, keep the old volume and merge this volume mapping into a
recovery Compose override (do not overwrite an existing override):

volumes:
  voxhold_data:
    external: true
    name: $target_volume

Select the image versions matching the backup manifest, then use that override
with docker compose up -d. Do not delete $current_volume until recovery is verified.

To discard the restored copy instead:
  docker volume rm $target_volume
EOF
fi

echo "Next steps: check 'docker compose logs --tail=50 backend' and GET /healthz."

