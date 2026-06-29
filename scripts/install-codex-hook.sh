#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
codex_home="${CODEX_HOME:-$HOME/.codex}"
install_dir="${SYSTEM_HEALTH_HOOK_INSTALL_DIR:-$codex_home/hooks/system-health-context}"
config="${CODEX_CONFIG:-$codex_home/config.toml}"
wrapper="$install_dir/system-health-codex-hook.zsh"
binary="$repo_root/.build/release/system-health-context"

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

mkdir -p "$install_dir" "$(dirname "$config")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift toolchain not found. Install Xcode Command Line Tools, then rerun this installer." >&2
  exit 1
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/clang-module-cache}"
swift build --disable-sandbox -c release --product system-health-context --package-path "$repo_root"

cp "$binary" "$install_dir/system-health-context"
cp "$repo_root/bin/system-health-codex-hook.zsh" "$wrapper"
chmod 755 "$install_dir/system-health-context" "$wrapper"

if [[ ! -f "$config" ]]; then
  : > "$config"
fi

turn_start_command="$(toml_escape "\"$wrapper\" turn_start")"

snippet="$(cat <<EOF
[hooks]
UserPromptSubmit = [
  { hooks = [ { type = "command", command = "$turn_start_command", timeout = 5, statusMessage = "Collecting system health context" } ] }
]
EOF
)"

hook_entries="$(cat <<EOF
UserPromptSubmit = [
  { hooks = [ { type = "command", command = "$turn_start_command", timeout = 5, statusMessage = "Collecting system health context" } ] }
]
EOF
)"

if grep -Fq "$wrapper" "$config"; then
  echo "System Health Hook is already configured in $config"
elif ! grep -Eq '^\[hooks\][[:space:]]*$' "$config"; then
  backup="$config.before-system-health-hook-$(date +%Y%m%d-%H%M%S)"
  cp "$config" "$backup"
  {
    cat "$config"
    printf '\n%s\n' "$snippet"
  } > "$config.tmp.$$"
  mv "$config.tmp.$$" "$config"
  echo "Installed System Health Hook."
  echo "Config backup: $backup"
else
  echo "Installed hook files, but $config already has a [hooks] section."
  echo
  echo "Add or merge this into that section:"
  echo
  printf '%s\n' "$hook_entries"
fi

echo
echo "Hook files:"
echo "  $install_dir/system-health-context"
echo "  $wrapper"
echo
echo "Smoke test:"
echo "  $wrapper turn_start"
