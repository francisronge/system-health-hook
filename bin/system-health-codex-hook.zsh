#!/bin/zsh
set -u

mode="${1:-turn_start}"
script_path="${0:A}"
base="${script_path:h}"
collector="$base/system-health-context"

case "$mode" in
  turn_start|turn_end) ;;
  *) mode="turn_start" ;;
esac

if [[ -x "$collector" ]]; then
  if [[ -n "${SYSTEM_HEALTH_HOOK_LATEST_DIR:-}" ]]; then
    umask 077
    latest_dir="${SYSTEM_HEALTH_HOOK_LATEST_DIR}"
    mkdir -p "$latest_dir"
    tmp="$latest_dir/${mode}.$$"
    err="$latest_dir/${mode}.$$.err"
    out="$latest_dir/${mode}.txt"
    trap 'rm -f "$tmp" "$err"' EXIT
    "$collector" --codex-hook "$mode" > "$tmp" 2> "$err"
    if [[ -s "$err" ]]; then
      mv -f "$err" "$latest_dir/${mode}.err"
    else
      rm -f "$err"
    fi
    cat "$tmp"
    mv -f "$tmp" "$out"
  else
    exec "$collector" --codex-hook "$mode"
  fi
else
  if [[ "$mode" == "turn_end" ]]; then
    printf '{}\n'
  else
    echo "System Health Context"
    echo
    echo "Use this as cheap local machine context."
    echo "System health collector missing: $collector"
  fi
fi
