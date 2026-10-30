#!/usr/bin/env bash
# Sourced by install.sh and update.sh, after changing into the deploy directory.

cpu_env_value() {
    sed -n "s/^$1=//p" .env | tail -n 1 | sed 's/^"//; s/"$//'
}

cpu_supports_v3() {
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || return 1
    # glibc checks the complete ISA level and the OS's enabled XSAVE state.
    # Hosts without a capable glibc loader conservatively retain v1.
    local loader
    for loader in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
        if [[ -x "$loader" ]] && LC_ALL=C "$loader" --help 2>/dev/null | grep -F 'x86-64-v3 (supported, searched)' >/dev/null; then
            return 0
        fi
    done
    return 1
}

cpu_set_backend_image() {
    local temporary_env
    temporary_env="$(mktemp .env.cpu.XXXXXX)"
    awk -v image="$1" '
        /^VOXHOLD_BACKEND_IMAGE=/ { print "VOXHOLD_BACKEND_IMAGE=\"" image "\""; next }
        { print }
    ' .env >"$temporary_env"
    chmod 600 "$temporary_env"
    mv -- "$temporary_env" .env
}

cpu_select_backend_image() {
    local image mode base candidate level
    # An exported image override is an explicit operator choice. Compose will
    # use it instead of .env; keep it and preflight the resolved image below.
    [[ -z "${VOXHOLD_BACKEND_IMAGE+x}" ]] || return 0
    image="$(cpu_env_value VOXHOLD_BACKEND_IMAGE)"
    mode="${VOXHOLD_AMD64:-$(cpu_env_value VOXHOLD_AMD64)}"
    mode="${mode:-auto}"
    case "$mode" in auto|v1|v3) ;; *) echo 'VOXHOLD_AMD64 must be auto, v1 or v3' >&2; return 1 ;; esac
    # Custom registries and immutable digest pins belong to the operator.
    [[ "$image" =~ ^ghcr.io/looneman1/voxhold-backend:([a-zA-Z0-9_][a-zA-Z0-9_.-]*)$ ]] || return 0
    if [[ "$(uname -m)" != x86_64 ]]; then
        [[ "$mode" == auto ]] || { echo 'VOXHOLD_AMD64 overrides require an amd64 host' >&2; return 1; }
        # A copied amd64-tagged .env must return to the multi-platform tag.
        base="${image%-amd64-v1}"
        base="${base%-amd64-v3}"
        cpu_set_backend_image "$base"
        return 0
    fi
    base="${image%-amd64-v1}"
    base="${base%-amd64-v3}"
    level=v1
    if [[ "$mode" != v1 ]] && cpu_supports_v3; then
        level=v3
    elif [[ "$mode" == v3 ]]; then
        echo 'Cannot verify full amd64-v3 CPU/OS support; use auto or v1.' >&2
        return 1
    fi
    candidate="$base-amd64-$level"
    if docker manifest inspect "$candidate" >/dev/null 2>&1; then
        cpu_set_backend_image "$candidate"
        echo "Backend CPU image selected: amd64-$level ($candidate)"
    elif [[ "$mode" == v3 ]]; then
        echo "Requested v3 image is unavailable: $candidate" >&2
        return 1
    else
        # Old releases have no suffixed images. Their regular tag is portable.
        cpu_set_backend_image "$base"
        echo "CPU variant unavailable; using portable image: $base"
    fi
}

cpu_preflight_backend() {
    local image marker
    # Read only services.backend.image from Compose's canonical YAML. Unlike
    # --images backend, this does not also return dependency images. A Docker
    # image reference cannot contain whitespace or quote characters.
    image="$(docker compose config --format yaml | awk '
        /^services:$/ { services = 1; next }
        services && /^[^ ]/ { services = 0 }
        services && /^  backend:$/ { backend = 1; next }
        services && /^  [^ ]/ { backend = 0 }
        services && backend && /^    image: / {
            sub(/^    image: /, "")
            gsub(/[\042\047]/, "")
            print
            found = 1
        }
        END { if (!found) exit 1 }
    ')" || return 1
    [[ -n "$image" && "$image" != *$'\n'* ]] || { echo 'Cannot resolve exactly one backend image' >&2; return 1; }
    marker="$(docker image inspect -f '{{index .Config.Labels "io.voxhold.cpu-check"}}' "$image")" || return 1
    if [[ "$marker" == 1 ]]; then
        # No database, published ports or dependent services. Go validates its
        # minimum instruction set before main, including XGETBV OS support.
        docker compose run --rm --no-deps --entrypoint voxhold backend --check-cpu
    fi
}
