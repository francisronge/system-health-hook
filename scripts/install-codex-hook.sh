#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
codex_home="${CODEX_HOME:-$HOME/.codex}"
install_dir="${SYSTEM_HEALTH_HOOK_INSTALL_DIR:-$codex_home/hooks/system-health-context}"
config="${CODEX_CONFIG:-$codex_home/config.toml}"
wrapper="$install_dir/system-health-codex-hook.zsh"

mkdir -p "$install_dir" "$(dirname "$config")"
cp "$repo_root/bin/system-health-context.sh" "$install_dir/system-health-context.sh"
cp "$repo_root/bin/system-health-codex-hook.zsh" "$wrapper"
chmod 755 "$install_dir/system-health-context.sh" "$wrapper"

if [[ ! -f "$config" ]]; then
  : > "$config"
fi

snippet="$(cat <<EOF
[hooks]
UserPromptSubmit = [
  { prompt = { command = "$wrapper", args = ["turn_start"], timeout = 5, statusMessage = "Collecting system health context" } }
]
Stop = [
  { command = "$wrapper", args = ["turn_end"], timeout = 8, statusMessage = "Collecting end-of-turn system health" }
]
EOF
)"

hook_entries="$(cat <<EOF
UserPromptSubmit = [
  { prompt = { command = "$wrapper", args = ["turn_start"], timeout = 5, statusMessage = "Collecting system health context" } }
]
Stop = [
  { command = "$wrapper", args = ["turn_end"], timeout = 8, statusMessage = "Collecting end-of-turn system health" }
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
echo "  $install_dir/system-health-context.sh"
echo "  $wrapper"
echo
echo "Smoke test:"
echo "  $wrapper turn_start"
