#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
codex_home="${CODEX_HOME:-$HOME/.codex}"
install_dir="${SYSTEM_HEALTH_HOOK_INSTALL_DIR:-$codex_home/hooks/system-health-context}"
config="${CODEX_CONFIG:-$codex_home/config.toml}"
wrapper="$install_dir/system-health-codex-hook.zsh"
built_binary="$repo_root/.build/release/system-health-context"
installed_binary="$install_dir/system-health-context"
binary_tmp=""
wrapper_tmp=""

cleanup_install_temps() {
  [[ -z "$binary_tmp" ]] || rm -f -- "$binary_tmp"
  [[ -z "$wrapper_tmp" ]] || rm -f -- "$wrapper_tmp"
}

trap cleanup_install_temps EXIT

if ! command -v swift >/dev/null 2>&1; then
  echo "Install Xcode Command Line Tools, then rerun this installer." >&2
  exit 1
fi
if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
  echo "Installation needs Python 3.11 or newer. The hook itself only runs Swift." >&2
  exit 1
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/clang-module-cache}"
swift build --disable-sandbox -c release --product system-health-context --package-path "$repo_root"

mkdir -p "$install_dir"
binary_tmp="$(mktemp "$install_dir/.system-health-context.XXXXXX")"
wrapper_tmp="$(mktemp "$install_dir/.system-health-codex-hook.XXXXXX")"
cp "$built_binary" "$binary_tmp"
cp "$repo_root/bin/system-health-codex-hook.zsh" "$wrapper_tmp"
chmod 755 "$binary_tmp" "$wrapper_tmp"
mv -f "$binary_tmp" "$installed_binary"
binary_tmp=""
mv -f "$wrapper_tmp" "$wrapper"
wrapper_tmp=""

python3 "$repo_root/scripts/configure-codex-hook.py" "$config" "$installed_binary"
cmp -s "$built_binary" "$installed_binary"
echo "Installed version: $("$installed_binary" --version)"
echo "Codex may require review of the changed hook commands before running them."
