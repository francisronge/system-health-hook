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

binary_tmp="$(mktemp "$install_dir/.system-health-context.XXXXXX")"
wrapper_tmp="$(mktemp "$install_dir/.system-health-codex-hook.XXXXXX")"
cp "$built_binary" "$binary_tmp"
cp "$repo_root/bin/system-health-codex-hook.zsh" "$wrapper_tmp"
chmod 755 "$binary_tmp" "$wrapper_tmp"
mv -f "$binary_tmp" "$installed_binary"
binary_tmp=""
mv -f "$wrapper_tmp" "$wrapper"
wrapper_tmp=""

if [[ ! -f "$config" ]]; then
  : > "$config"
fi

turn_start_command="$(toml_escape "\"$installed_binary\" --codex-hook turn_start")"
turn_end_command="$(toml_escape "\"$installed_binary\" --codex-hook turn_end")"

snippet="$(cat <<EOF
[hooks]
UserPromptSubmit = [
  { hooks = [ { type = "command", command = "$turn_start_command", timeout = 5, statusMessage = "Collecting system health context" } ] }
]
Stop = [
  { hooks = [ { type = "command", command = "$turn_end_command", timeout = 5, statusMessage = "Checking end-of-turn system health" } ] }
]
EOF
)"

start_entry="$(cat <<EOF
UserPromptSubmit = [
  { hooks = [ { type = "command", command = "$turn_start_command", timeout = 5, statusMessage = "Collecting system health context" } ] }
]
EOF
)"

stop_entry="$(cat <<EOF
Stop = [
  { hooks = [ { type = "command", command = "$turn_end_command", timeout = 5, statusMessage = "Checking end-of-turn system health" } ] }
]
EOF
)"

has_start=false
has_stop=false
if grep -F -- "--codex-hook turn_start" "$config" | grep -Fq -- "system-health-context" \
  || grep -F -- "system-health-codex-hook.zsh" "$config" | grep -Fq -- "turn_start"; then
  has_start=true
fi
if grep -F -- "--codex-hook turn_end" "$config" | grep -Fq -- "system-health-context" \
  || grep -F -- "system-health-codex-hook.zsh" "$config" | grep -Fq -- "turn_end"; then
  has_stop=true
fi

if [[ "$has_start" == true && "$has_stop" == true ]]; then
  echo "System Health Hook is already configured in $config"
elif ! grep -Eq '^\[\[?hooks([.]|])' "$config"; then
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
  echo "Installed hook files, but $config already has hooks."
  echo
  echo "Add the missing entries to the existing hooks configuration:"
  echo
  if [[ "$has_start" == false ]]; then
    printf '%s\n' "$start_entry"
  fi
  if [[ "$has_stop" == false ]]; then
    printf '%s\n' "$stop_entry"
  fi
fi

echo
echo "Hook files:"
echo "  $install_dir/system-health-context"
echo "  $wrapper"
echo
echo "Smoke test:"
echo "  $installed_binary --codex-hook turn_start"
