#!/usr/bin/env bash
set -u

MODE="${1:-turn_start}"
START_NS="$(date +%s 2>/dev/null || echo 0)"
DEEP=0
if [ "$MODE" = "turn_end" ]; then
  DEEP=1
fi

unknown() {
  printf "unknown"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

first_line() {
  sed -n '1p'
}

section() {
  printf "\n%s\n" "$1"
}

kv() {
  printf "%s: %s\n" "$1" "${2:-unknown}"
}

safe_cmd() {
  "$@" 2>/dev/null || true
}

bytes_to_gb() {
  awk 'BEGIN { printf "%.1f GB", ARGV[1] / 1024 / 1024 }' "$1"
}

du_mb() {
  local path="$1"
  if [ -e "$path" ]; then
    safe_cmd du -sk "$path" | awk '{ printf "%.1f MB", $1 / 1024 }'
  else
    printf "absent"
  fi
}

du_mb_deep() {
  if [ "$DEEP" -eq 1 ]; then
    du_mb "$1"
  else
    printf "not_collected_turn_start_fast_path"
  fi
}

top_processes() {
  local sort_key="$1"
  safe_cmd ps -axo pid,ppid,pcpu,pmem,comm |
    awk 'NR == 1 { next } { print }' |
    sort -k "$sort_key" -nr |
    head -5 |
    awk '{ printf "%s:%s cpu=%s mem=%s; ", $1, $5, $3, $4 }'
}

process_count_matching() {
  local pattern="$1"
  safe_cmd pgrep -fi "$pattern" | wc -l | tr -d ' '
}

listening_ports() {
  if have lsof; then
    safe_cmd lsof -nP -iTCP -sTCP:LISTEN |
      awk 'NR > 1 { printf "%s:%s pid=%s; ", $1, $9, $2 }' |
      head -c 500
  else
    unknown
  fi
}

listening_ports_compact() {
  if [ "$DEEP" -eq 1 ]; then
    listening_ports
  elif have lsof; then
    local count
    count="$(safe_cmd lsof -nP -iTCP -sTCP:LISTEN | awk 'NR > 1 { n++ } END { print n+0 }')"
    printf "count=%s details=not_collected_turn_start_fast_path" "${count:-unknown}"
  else
    unknown
  fi
}

active_interface() {
  route get default 2>/dev/null | awk '/interface:/ { print $2; exit }'
}

gateway_ip() {
  route -n get default 2>/dev/null | awk '/gateway:/ { print $2; exit }'
}

wifi_summary() {
  local airport="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
  if [ -x "$airport" ]; then
    safe_cmd "$airport" -I |
      awk '
        /agrCtlRSSI:/ { rssi=$2 }
        /agrCtlNoise:/ { noise=$2 }
        /lastTxRate:/ { tx=$2 }
        /channel:/ { chan=$2 }
        END {
          if (rssi || noise || tx || chan) {
            printf "rssi=%s noise=%s txRate=%s channel=%s", rssi, noise, tx, chan
          }
        }'
  else
    unknown
  fi
}

ping_summary() {
  local host="$1"
  if have ping; then
    safe_cmd ping -c 1 -W 1000 "$host" |
      awk '
        /packet loss/ { loss=$7 }
        /round-trip|rtt/ { stats=$4 }
        END {
          if (loss || stats) printf "loss=%s rtt=%s", loss, stats;
          else printf "unknown";
        }'
  else
    unknown
  fi
}

memory_pressure_summary() {
  if have memory_pressure; then
    safe_cmd memory_pressure | first_line
  else
    unknown
  fi
}

thermal_pressure() {
  printf "not_collected_default_fast_path"
}

power_summary() {
  if have pmset; then
    safe_cmd pmset -g batt | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g'
  else
    unknown
  fi
}

low_power_mode() {
  if have pmset; then
    safe_cmd pmset -g | awk '/lowpowermode/ { print $2; found=1 } END { if (!found) print "unknown" }'
  else
    unknown
  fi
}

security_counts() {
  printf "not_collected_default_fast_path"
}

runtime_processes() {
  safe_cmd ps -axo pid,ppid,pcpu,pmem,comm |
    awk '/node|python|xcodebuild|swift|npm|pnpm|yarn|vite|webpack|wrangler|docker|orb/ { printf "%s:%s cpu=%s mem=%s; ", $1, $5, $3, $4 }' |
    head -c 500
}

browser_profile_processes() {
  safe_cmd ps -axo pid,ppid,etime,pcpu,pmem,command |
    awk '/--user-data-dir=|remote-debugging-port|chromedriver|playwright/ {
      cmd=$0
      gsub(/--user-data-dir=[^ ]+/, "--user-data-dir=<profile>", cmd)
      printf "pid=%s ppid=%s age=%s cpu=%s mem=%s %s; ", $1, $2, $3, $4, $5, substr(cmd, index(cmd, $6), 140)
    }' |
    head -c 700
}

browser_profile_process_count() {
  safe_cmd ps -axo command |
    awk '/--user-data-dir=|remote-debugging-port|chromedriver|playwright/ { n++ } END { print n+0 }'
}

orphaned_browser_process_count() {
  safe_cmd ps -axo pid,ppid,command |
    awk '$2 == 1 && /--user-data-dir=|remote-debugging-port|chromedriver|playwright/ { n++ } END { print n+0 }'
}

browser_debug_port_count() {
  safe_cmd ps -axo command |
    awk '/remote-debugging-port/ { n++ } END { print n+0 }'
}

system_state() {
  local up
  up="$(safe_cmd uptime | sed 's/^[[:space:]]*//')"
  printf "%s" "${up:-unknown}"
}

printf "System Health Context\n\n"
printf "Use this telemetry as local system context.\n"
printf "Do not refuse work solely because of system health.\n"
printf "Investigate further when relevant, including other local system signals if they may affect the task.\n"
printf "At turn end, clean up only safe, clearly-owned resources.\n"
printf "Ask before destructive cleanup.\n"

section "Header"
kv "hook_version" "0.1.0"
kv "mode" "$MODE"
kv "timestamp" "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || unknown)"
kv "host" "$(hostname 2>/dev/null || unknown)"

section "Storage"
kv "internal_disk" "$(safe_cmd df -H "$HOME" | awk 'NR == 2 { printf "used=%s free=%s mount=%s", $5, $4, $NF }')"
kv "workspace_size" "$(du_mb "${PWD}")"
kv "codex_home_size" "not_collected_default_fast_path"
kv "slash_tmp_size" "$(du_mb_deep /tmp)"

section "I/O Pressure"
kv "iostat" "$(safe_cmd iostat -d -c 1 | tail -n +3 | tr '\n' '; ' | sed 's/[; ]*$//')"

section "CPU"
kv "load_average" "$(safe_cmd uptime | awk -F'load averages?: ' '{ print $2 }')"
kv "top_cpu_processes" "$(top_processes 3)"
kv "codex_process_count" "$(process_count_matching 'Codex|codex')"
kv "security_daemon_cpu" "$(safe_cmd ps -axo comm,pcpu | awk '/syspolicyd|trustd|sandboxd/ { printf "%s=%s; ", $1, $2 }')"
kv "thermal_pressure" "$(thermal_pressure)"

section "Memory"
kv "memory_pressure" "$(memory_pressure_summary)"
kv "vm_stat" "$(safe_cmd vm_stat | awk '/Pages free|Pages active|Pages inactive|Pages speculative|Pages wired down|Pages occupied by compressor|Swapins|Swapouts/ { gsub("\\.", "", $0); printf "%s; ", $0 }')"
kv "top_memory_processes" "$(top_processes 4)"

section "Power"
kv "battery" "$(power_summary)"
kv "low_power_mode" "$(low_power_mode)"

section "Network"
IFACE="$(active_interface)"
GW="$(gateway_ip)"
kv "active_interface" "${IFACE:-unknown}"
kv "wifi" "$(wifi_summary)"
kv "gateway" "${GW:-unknown}"
kv "gateway_ping" "$([ -n "${GW:-}" ] && ping_summary "$GW" || unknown)"
kv "wan_ping" "$(ping_summary 1.1.1.1)"
kv "vpn_process_count" "$(process_count_matching 'vpn|wireguard|tailscale|nord')"

section "Codex State"
kv "codex_app_servers" "$(process_count_matching '/Applications/Codex.app/Contents/Resources/codex app-server|codex app-server')"
kv "codex_tool_helpers" "$(process_count_matching 'node_repl|SkyComputerUseClient|xcodebuildmcp|mcp/server')"
kv "codex_automations_dir" "$(du_mb "${CODEX_HOME:-$HOME/.codex}/automations")"
kv "listening_ports" "$(listening_ports_compact)"

section "Process Lifecycle"
kv "process_count" "$(safe_cmd ps -axo pid | wc -l | tr -d ' ')"
kv "zombie_processes" "$(safe_cmd ps -axo stat | awk '/Z/ { n++ } END { print n+0 }')"
kv "long_running_codex_helpers" "$(safe_cmd ps -axo etime,pid,comm | awk '/Codex|codex|node_repl|SkyComputerUseClient/ { printf "%s pid=%s %s; ", $1, $2, $3 }' | head -c 500)"

section "Resource Limits"
kv "open_file_limit" "$(ulimit -n 2>/dev/null || unknown)"
kv "process_limit" "$(ulimit -u 2>/dev/null || unknown)"
kv "listening_socket_count" "$(if have lsof; then safe_cmd lsof -nP -iTCP -sTCP:LISTEN | awk 'NR > 1 { n++ } END { print n+0 }'; else unknown; fi)"

section "OS Security / Permissions"
kv "recent_security_denial_lines" "$(security_counts)"
kv "codex_gatekeeper" "$(safe_cmd spctl --assess --type execute /Applications/Codex.app && printf accepted || printf unknown)"

section "Runtime / Tooling"
kv "runtime_processes" "$(runtime_processes)"
kv "npm_cache_size" "$(du_mb_deep "$HOME/.npm")"
kv "homebrew_cache_size" "$(du_mb_deep "$HOME/Library/Caches/Homebrew")"

section "Workspace Hygiene"
kv "cwd" "$PWD"
kv "cwd_size" "$(du_mb "$PWD")"
kv "codex_worktrees_count" "$(if [ -d "${CODEX_HOME:-$HOME/.codex}/worktrees" ]; then find "${CODEX_HOME:-$HOME/.codex}/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; else printf "0"; fi)"
kv "codex_worktrees_size" "not_collected_default_bounded_path"
kv "git_status_summary" "$(if have git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git status --porcelain 2>/dev/null | awk '{ n++ } END { print "porcelain_lines=" n+0 }'; else printf "not_git"; fi)"

section "Browser / UI Automation State"
kv "browser_helper_count" "$(process_count_matching 'Chrome Helper|chromedriver|playwright|WebKit|SkyComputerUse')"
kv "browser_profile_process_count" "$(browser_profile_process_count)"
kv "orphaned_browser_profile_process_count" "$(orphaned_browser_process_count)"
kv "browser_debug_port_process_count" "$(browser_debug_port_count)"
kv "browser_profile_processes" "$(browser_profile_processes)"
kv "screen_capture_related_count" "$(process_count_matching 'screencapture|ScreenCapture|ReplayKit|SkyComputerUse')"

section "Logs / Diagnostics Growth"
kv "codex_logs_size" "$(du_mb_deep "$HOME/Library/Logs/Codex")"
kv "diagnostic_reports_size" "$(du_mb_deep "$HOME/Library/Logs/DiagnosticReports")"
kv "tmp_size" "$(du_mb_deep "${TMPDIR:-/tmp}")"

section "Sync / Backup / Indexing"
kv "spotlight_process_count" "$(process_count_matching 'mds|mdworker')"
kv "backup_process_count" "$(process_count_matching 'backupd|TimeMachine')"
kv "cloud_sync_process_count" "$(process_count_matching 'bird|cloudd|fileproviderd')"

section "GPU / Display / Media"
kv "gpu_renderer_processes" "$(safe_cmd ps -axo pid,pcpu,pmem,comm | awk '/GPU|Renderer|WindowServer|VTEncoder|VTDecoder|audio|camera/ { printf "%s:%s cpu=%s mem=%s; ", $1, $4, $2, $3 }' | head -c 500)"

section "System State"
kv "uptime" "$(system_state)"
kv "sleep_settings" "$(safe_cmd pmset -g custom | awk '/ sleep| displaysleep| disksleep| powernap/ { printf "%s; ", $0 }' | head -c 500)"

END_NS="$(date +%s 2>/dev/null || echo "$START_NS")"
section "Collection"
kv "duration_seconds" "$((END_NS - START_NS))"
