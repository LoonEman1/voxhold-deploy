#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Voxhold deployment is supported only on Linux hosts." >&2
    echo "Развёртывание Voxhold поддерживается только на Linux-серверах." >&2
    exit 1
fi

for command_name in curl tar mktemp; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is missing: $command_name" >&2
        echo "Не найдена обязательная команда: $command_name" >&2
        exit 1
    fi
done

repository="LoonEman1/voxhold-deploy"
deploy_ref="${VOXHOLD_DEPLOY_REF:-main}"
install_dir="${VOXHOLD_DEPLOY_DIR:-$PWD/voxhold-deploy}"
archive_url="${VOXHOLD_DEPLOY_ARCHIVE_URL:-https://codeload.github.com/$repository/tar.gz/$deploy_ref}"

if [[ "$install_dir" != /* ]]; then
    install_dir="$PWD/$install_dir"
fi

if [[ -e "$install_dir" ]]; then
    echo "Installation path already exists: $install_dir" >&2
    echo "Каталог установки уже существует: $install_dir" >&2
    echo "Run update.sh there, or choose another VOXHOLD_DEPLOY_DIR." >&2
    echo "Запустите в нём update.sh или задайте другой VOXHOLD_DEPLOY_DIR." >&2
    exit 1
fi

install_parent="$(dirname -- "$install_dir")"
if [[ ! -d "$install_parent" ]]; then
    mkdir -p "$install_parent"
fi

temporary_dir="$(mktemp -d)"
cleanup() {
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

archive_path="$temporary_dir/voxhold-deploy.tar.gz"
extracted_dir="$temporary_dir/extracted"
mkdir -p "$extracted_dir"

echo "Downloading Voxhold deploy ($deploy_ref)..."
echo "Загрузка Voxhold deploy ($deploy_ref)..."
curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --output "$archive_path" \
    "$archive_url"

tar -xzf "$archive_path" -C "$extracted_dir" --strip-components=1

required_files=(
    bootstrap.sh
    compose.yaml
    Caddyfile
    Caddyfile.ip
    install.sh
    update.sh
    backup.sh
    .env.example
)

for required_file in "${required_files[@]}"; do
    if [[ ! -f "$extracted_dir/$required_file" ]]; then
        echo "Downloaded archive is missing: $required_file" >&2
        echo "В загруженном архиве отсутствует: $required_file" >&2
        exit 1
    fi
done

# Check again after the download to avoid replacing a path created in parallel.
if [[ -e "$install_dir" ]]; then
    echo "Installation path was created while downloading: $install_dir" >&2
    echo "Каталог установки был создан во время загрузки: $install_dir" >&2
    exit 1
fi

mv -- "$extracted_dir" "$install_dir"
chmod +x \
    "$install_dir/bootstrap.sh" \
    "$install_dir/install.sh" \
    "$install_dir/update.sh" \
    "$install_dir/backup.sh"

echo "Installed into: $install_dir"
echo "Установлено в: $install_dir"

if [[ "${VOXHOLD_BOOTSTRAP_SKIP_INSTALL:-false}" == "true" ]]; then
    exit 0
fi

if exec 3</dev/tty 2>/dev/null; then
    exec "$install_dir/install.sh" <&3
fi

echo "No interactive terminal detected. Run:" >&2
echo "Интерактивный терминал не найден. Запустите:" >&2
echo "  cd '$install_dir' && ./install.sh" >&2
