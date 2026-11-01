#!/usr/bin/env bash
# Operator recovery commands that run inside the backend image.
#   ./admin.sh reset-password <username>   prints a new one-time password
# Requires a backend image that ships voxhold-admin (Voxhold 2.6+).
set -Eeuo pipefail

# Disable MSYS path mangling of POSIX-looking arguments (no-op on Linux).
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
cd "$DEPLOY_DIR"

usage() {
    echo "usage: $0 reset-password <username>" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
case "$1" in
    reset-password)
        [[ $# -eq 2 && -n "$2" ]] || usage
        exec docker compose run --rm --no-deps --entrypoint voxhold-admin backend reset-password --username "$2"
        ;;
    *) usage ;;
esac
