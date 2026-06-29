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
    latest_dir="${SYSTEM_HEALTH_HOOK_LATEST_DIR}"
    mkdir -p "$latest_dir"
    tmp="$latest_dir/${mode}.$$"
    err="$latest_dir/${mode}.$$.err"
    out="$latest_dir/${mode}.txt"
    trap 'rm -f "$tmp" "$err"' EXIT
    "$collector" "$mode" > "$tmp" 2> "$err"
    mv "$tmp" "$out"
    if [[ -s "$err" ]]; then
      mv "$err" "$latest_dir/${mode}.err"
    else
      rm -f "$err"
    fi
    cat "$out"
  else
    exec "$collector" "$mode"
  fi
else
  echo "System Health Context"
  echo
  echo "Use this as cheap local machine context."
  echo "System health collector missing: $collector"
fi
