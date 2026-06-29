#!/bin/zsh
set -u

mode="${1:-turn_start}"
script_path="${0:A}"
base="${script_path:h}"
collector="$base/system-health-context"
legacy_collector="$base/system-health-context.sh"
latest_dir="${SYSTEM_HEALTH_HOOK_LATEST_DIR:-$base/latest}"
mkdir -p "$latest_dir"

case "$mode" in
  turn_start|turn_end) ;;
  *) mode="turn_start" ;;
esac

tmp="$latest_dir/${mode}.$$"
err="$latest_dir/${mode}.$$.err"
out="$latest_dir/${mode}.txt"

if [[ -x "$collector" ]]; then
  "$collector" "$mode" > "$tmp" 2> "$err"
elif [[ -x "$legacy_collector" ]]; then
  "$legacy_collector" "$mode" > "$tmp" 2> "$err"
else
  {
    echo "System Health Context"
    echo
    echo "Use this as cheap local machine context."
    echo "System health collector missing: $collector"
  } > "$tmp"
fi

mv "$tmp" "$out"
if [[ -s "$err" ]]; then
  mv "$err" "$latest_dir/${mode}.err"
else
  rm -f "$err"
fi

cat "$out"
exit 0
