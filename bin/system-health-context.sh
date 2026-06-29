#!/usr/bin/env bash
set -u

MODE="${1:-turn_start}"
START_NS="$(date +%s 2>/dev/null || echo 0)"
DEEP=0
if [ "${SYSTEM_HEALTH_DEEP:-0}" = "1" ]; then
  DEEP=1
elif [ "$MODE" = "turn_end" ] && [ "${SYSTEM_HEALTH_TURN_END_DEEP:-0}" = "1" ]; then
  DEEP=1
fi
DU_TIMEOUT_SECONDS="${SYSTEM_HEALTH_DU_TIMEOUT_SECONDS:-3}"

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

bounded_cmd() {
  local timeout="$1"
  shift
  perl -e '
    use strict;
    use warnings;
    use POSIX ":sys_wait_h";
    my ($timeout, @cmd) = @ARGV;
    pipe(my $reader, my $writer) or exit 1;
    my $pid = fork();
    exit 1 unless defined $pid;
    if ($pid == 0) {
      close $reader;
      open STDOUT, ">&", $writer or exit 1;
      open STDERR, ">", "/dev/null";
      exec @cmd;
      exit 127;
    }
    close $writer;
    my $timed_out = 0;
    local $SIG{ALRM} = sub {
      $timed_out = 1;
      kill "TERM", $pid;
    };
    alarm($timeout);
    while (my $line = <$reader>) {
      print $line;
    }
    alarm(0);
    if ($timed_out) {
      select undef, undef, undef, 0.2;
      kill "KILL", $pid if waitpid($pid, WNOHANG) == 0;
    }
    waitpid($pid, 0);
  ' "$timeout" "$@" 2>/dev/null || true
}

sanitize_log_snippet() {
  sed "s#$HOME#~#g" |
    sed -E 's#https?://[^[:space:]]+#<url>#g; s#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+#<email>#g; s#[[:space:]]+# #g' |
    cut -c 1-220
}

bytes_to_gb() {
  awk 'BEGIN { printf "%.1f GB", ARGV[1] / 1024 / 1024 }' "$1"
}

du_mb() {
  local path="$1"
  if [ -e "$path" ]; then
    perl -MPOSIX=:sys_wait_h -e '
      my ($timeout, $path) = @ARGV;
      pipe(my $reader, my $writer) or exit 1;
      my $pid = fork();
      exit 1 unless defined $pid;
      if ($pid == 0) {
        close $reader;
        open STDOUT, ">&", $writer or exit 1;
        open STDERR, ">", "/dev/null";
        exec "du", "-sk", $path;
        exit 127;
      }
      close $writer;
      my $timed_out = 0;
      local $SIG{ALRM} = sub {
        $timed_out = 1;
        kill "TERM", $pid;
      };
      alarm($timeout);
      my $line = <$reader> // "";
      alarm(0);
      if ($timed_out) {
        select undef, undef, undef, 0.2;
        kill "KILL", $pid if waitpid($pid, WNOHANG) == 0;
        waitpid($pid, 0);
        print "not_collected_bounded_path";
        exit 0;
      }
      waitpid($pid, 0);
      if ($line =~ /^(\d+)/) {
        printf "%.1f MB", $1 / 1024;
      } else {
        print "unknown";
      }
    ' "$DU_TIMEOUT_SECONDS" "$path" 2>/dev/null || printf "unknown"
  else
    printf "absent"
  fi
}

git_worktree_size_signal() {
  local path="$1"
  local top
  if ! have git; then
    return 1
  fi
  top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$top" ] || [ "$top" != "$path" ]; then
    return 1
  fi
  local tracked
  local dirty
  tracked="$(git -C "$path" ls-files 2>/dev/null | wc -l | tr -d ' ')"
  dirty="$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  printf "git_worktree_signal tracked_files=%s dirty=%s" "${tracked:-unknown}" "${dirty:-unknown}"
}

workspace_size_signal() {
  git_worktree_size_signal "$1" || du_mb "$1"
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
  printf "%s\n" "${PS_COMM:-}" |
    awk 'NR == 1 { next } { print }' |
    sort -k "$sort_key" -nr |
    head -5 |
    awk '{ printf "%s:%s cpu=%s mem=%s; ", $1, $5, $3, $4 }'
}

process_count_matching() {
  local pattern="$1"
  printf "%s\n" "${PS_COMMAND:-}" |
    awk -v pat="$pattern" '
      BEGIN { pat=tolower(pat) }
      NR > 1 && tolower($0) ~ pat { n++ }
      END { print n+0 }'
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
  else
    printf "details=not_collected_default_fast_path"
  fi
}

listening_socket_count() {
  if have netstat; then
    safe_cmd netstat -an -p tcp | awk '/LISTEN/ { n++ } END { print n+0 }'
  elif [ "$DEEP" -eq 1 ] && have lsof; then
    safe_cmd lsof -nP -iTCP -sTCP:LISTEN | awk 'NR > 1 { n++ } END { print n+0 }'
  else
    printf "unknown"
  fi
}

active_interface() {
  route get default 2>/dev/null | awk '/interface:/ { print $2; exit }'
}

gateway_ip() {
  route -n get default 2>/dev/null | awk '/gateway:/ { print $2; exit }'
}

interface_kind() {
  local iface="$1"
  if have networksetup; then
    safe_cmd networksetup -listallhardwareports |
      awk -v iface="$iface" '
        /^Hardware Port:/ { port=substr($0, index($0, ":") + 2) }
        /^Device:/ && $2 == iface { print port; found=1; exit }
        END { if (!found) print "unknown" }'
  else
    unknown
  fi
}

interface_status() {
  local iface="$1"
  safe_cmd ifconfig "$iface" |
    awk '
      /status:/ { status=$2 }
      /inet / { inet=$2 }
      /media:/ {
        media=$0
        sub(/^[[:space:]]*media:[[:space:]]*/, "", media)
      }
      END {
        printf "status=%s inet=%s media=%s",
          status ? status : "unknown",
          inet ? "present" : "absent",
          media ? media : "unknown"
      }'
}

wifi_association() {
  local iface="$1"
  if have networksetup; then
    safe_cmd networksetup -getairportnetwork "$iface" |
      awk '
        /Current Wi-Fi Network:/ { print "yes"; found=1; exit }
        /not associated/ { print "no"; found=1; exit }
        END { if (!found) print "unknown" }'
  else
    unknown
  fi
}

wifi_profiler_status() {
  printf "not_collected_default_fast_path"
}

wifi_summary() {
  local iface="${1:-$(active_interface)}"
  local kind
  kind="$(interface_kind "$iface")"
  local status
  status="$(interface_status "$iface")"
  local associated
  associated="$(wifi_association "$iface")"
  local profiler
  profiler="$(wifi_profiler_status)"
  local airport="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
  local radio
  if [ -x "$airport" ]; then
    radio="$(safe_cmd "$airport" -I |
      awk '
        /agrCtlRSSI:/ { rssi=$2 }
        /agrCtlNoise:/ { noise=$2 }
        /lastTxRate:/ { tx=$2 }
        /channel:/ { chan=$2 }
        END {
          if (rssi || noise || tx || chan) {
            printf "rssi=%s noise=%s txRate=%s channel=%s", rssi, noise, tx, chan
          }
        }')"
  else
    radio="rssi=unknown noise=unknown txRate=unknown channel=unknown"
  fi
  printf "interface=%s kind=%s %s associated=%s profiler_status=%s %s" \
    "${iface:-unknown}" "${kind:-unknown}" "${status:-unknown}" "${associated:-unknown}" "${profiler:-unknown}" "${radio:-unknown}"
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
  if have pmset; then
    local therm
    therm="$(bounded_cmd 1 pmset -g therm 2>/dev/null | tr '\n' '; ' | sed 's/[; ]*$//')"
    if [ -n "$therm" ]; then
      printf "%s" "$therm"
      return
    fi
  fi
  printf "unavailable_fast_probe"
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
  if ! have log; then
    printf "log_unavailable"
    return
  fi

  local max_cpu
  max_cpu="$(printf "%s\n" "${PS_COMMAND:-}" |
    awk '/syspolicyd|trustd|sandboxd/ && $0 !~ /system-health-context|awk .*syspolicyd/ {
      if ($4 + 0 > max) max = $4 + 0
    } END { printf "%.1f", max + 0 }')"
  if [ "${SYSTEM_HEALTH_SECURITY_DEEP:-0}" != "1" ]; then
    printf "skipped=deep_log_sampling_opt_in_only max_cpu=%s set_SYSTEM_HEALTH_SECURITY_DEEP=1_to_force" "${max_cpu:-0.0}"
    return
  fi

  local window="${SYSTEM_HEALTH_SECURITY_WINDOW:-2m}"
  local raw
  raw="$(bounded_cmd 2 log show --style compact --last "$window" --predicate 'process == "syspolicyd" OR process == "sandboxd" OR eventMessage CONTAINS[c] "AppleSystemPolicy" OR eventMessage CONTAINS[c] "Sandbox:" OR eventMessage CONTAINS[c] "deny(" OR eventMessage CONTAINS[c] "denied" OR eventMessage CONTAINS[c] "not allowed" OR eventMessage CONTAINS[c] "operation not permitted"')"

  if [ -z "$raw" ]; then
    printf "window=%s lines=0 deny_like=0" "$window"
    return
  fi

  local lines deny_like syspolicyd_lines trustd_lines sandboxd_lines first_line last_line
  lines="$(printf "%s\n" "$raw" | awk 'NF { n++ } END { print n+0 }')"
  deny_like="$(printf "%s\n" "$raw" | awk '{ line=tolower($0) } line ~ /sandbox:|applesystempolicy|deny\(|denied|not allowed|operation not permitted/ { n++ } END { print n+0 }')"
  syspolicyd_lines="$(printf "%s\n" "$raw" | awk '/syspolicyd/ { n++ } END { print n+0 }')"
  trustd_lines="$(printf "%s\n" "$raw" | awk '/trustd/ { n++ } END { print n+0 }')"
  sandboxd_lines="$(printf "%s\n" "$raw" | awk '/sandboxd/ { n++ } END { print n+0 }')"
  first_line="$(printf "%s\n" "$raw" | awk '{ folded=tolower($0) } NF && $0 !~ /^Timestamp/ && folded ~ /sandbox:|applesystempolicy|deny\(|denied|not allowed|operation not permitted|syspolicyd|sandboxd/ { print; exit }' | sanitize_log_snippet)"
  last_line="$(printf "%s\n" "$raw" | awk '{ folded=tolower($0) } NF && $0 !~ /^Timestamp/ && folded ~ /sandbox:|applesystempolicy|deny\(|denied|not allowed|operation not permitted|syspolicyd|sandboxd/ { line=$0 } END { print line }' | sanitize_log_snippet)"

  printf "window=%s trigger=max_security_daemon_cpu:%s lines=%s deny_like=%s syspolicyd_lines=%s trustd_lines=%s sandboxd_lines=%s first=%s last=%s" \
    "$window" "${max_cpu:-unknown}" "$lines" "$deny_like" "$syspolicyd_lines" "$trustd_lines" "$sandboxd_lines" "${first_line:-none}" "${last_line:-none}"
}

security_daemon_cpu_summary() {
  printf "%s\n" "${PS_COMMAND:-}" |
    awk '
      /syspolicyd|trustd|sandboxd/ && $0 !~ /system-health-context|awk .*syspolicyd/ {
        cmd=$0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+/, "", cmd)
        name=cmd
        sub(/^.*\//, "", name)
        sub(/[[:space:]].*$/, "", name)
        printf "%s:%s=%s; ", $1, name, $4
      }'
}

codex_gatekeeper_status() {
  if [ "${SYSTEM_HEALTH_SECURITY_DEEP:-0}" != "1" ]; then
    printf "skipped=deep_security_opt_in_only"
    return
  fi
  safe_cmd spctl --assess --type execute /Applications/Codex.app && printf accepted || printf unknown
}

runtime_processes() {
  printf "%s\n" "${PS_COMM:-}" |
    awk '/node|python|xcodebuild|swift|npm|pnpm|yarn|vite|webpack|wrangler|docker|orb/ { printf "%s:%s cpu=%s mem=%s; ", $1, $5, $3, $4 }' |
    head -c 500
}

browser_profile_processes() {
  printf "%s\n" "${PS_COMMAND:-}" |
    awk '($0 ~ /--user-data-dir=/ || $0 ~ /--remote-debugging-port=/ || $0 ~ /(^|[\/ ])chromedriver([ ]|$)/ || $0 ~ /(^|[\/ ])playwright([ ]|$)/) && $0 !~ /system-health-context|awk .*user-data-dir|SkyComputerUseClient|codex-notify-wrapper|agent-turn-complete/ {
      cmd=$0
      gsub(/--user-data-dir=[^ ]+/, "--user-data-dir=<profile>", cmd)
      printf "pid=%s ppid=%s age=%s cpu=%s mem=%s %s; ", $1, $2, $3, $4, $5, substr(cmd, index(cmd, $6), 140)
    }' |
    head -c 700
}

browser_profile_process_count() {
  printf "%s\n" "${PS_COMMAND:-}" |
    awk '($0 ~ /--user-data-dir=/ || $0 ~ /--remote-debugging-port=/ || $0 ~ /(^|[\/ ])chromedriver([ ]|$)/ || $0 ~ /(^|[\/ ])playwright([ ]|$)/) && $0 !~ /system-health-context|awk .*user-data-dir|SkyComputerUseClient|codex-notify-wrapper|agent-turn-complete/ { n++ } END { print n+0 }'
}

orphaned_browser_process_count() {
  printf "%s\n" "${PS_COMMAND:-}" |
    awk '$2 == 1 && ($0 ~ /--user-data-dir=/ || $0 ~ /--remote-debugging-port=/ || $0 ~ /(^|[\/ ])chromedriver([ ]|$)/ || $0 ~ /(^|[\/ ])playwright([ ]|$)/) && $0 !~ /system-health-context|awk .*user-data-dir|SkyComputerUseClient|codex-notify-wrapper|agent-turn-complete/ { n++ } END { print n+0 }'
}

browser_debug_port_count() {
  printf "%s\n" "${PS_COMMAND:-}" |
    awk '/--remote-debugging-port=/ && $0 !~ /system-health-context|awk .*remote-debugging-port|SkyComputerUseClient|codex-notify-wrapper|agent-turn-complete/ { n++ } END { print n+0 }'
}

process_count_total() {
  printf "%s\n" "${PS_COMM:-}" | awk 'NR > 1 { n++ } END { print n+0 }'
}

zombie_process_count() {
  printf "%s\n" "${PS_STAT:-}" | awk 'NR > 1 && /Z/ { n++ } END { print n+0 }'
}

long_running_codex_helpers() {
  printf "%s\n" "${PS_COMMAND:-}" |
    awk '/Codex|codex|node_repl|SkyComputerUseClient/ {
      cmd=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+/, "", cmd)
      printf "%s pid=%s %s; ", $3, $1, substr(cmd, 1, 120)
    }' |
    head -c 500
}

gpu_renderer_processes() {
  printf "%s\n" "${PS_COMM:-}" |
    awk '/GPU|Renderer|WindowServer|VTEncoder|VTDecoder|audio|camera/ { printf "%s:%s cpu=%s mem=%s; ", $1, $5, $3, $4 }' |
    head -c 500
}

system_state() {
  local up
  up="$(safe_cmd uptime | sed 's/^[[:space:]]*//')"
  printf "%s" "${up:-unknown}"
}

PS_COMM="$(safe_cmd ps -axo pid,ppid,pcpu,pmem,comm)"
PS_COMMAND="$(safe_cmd ps -axo pid,ppid,etime,pcpu,pmem,command)"
PS_STAT="$(safe_cmd ps -axo stat)"

printf "System Health Context\n\n"
printf "Use this telemetry as local system context.\n"
printf "Do not refuse work solely because of system health.\n"
printf "Investigate further when relevant, including other local system signals if they may affect the task.\n"
printf "At turn end, clean up only safe, clearly-owned resources.\n"
printf "Ask before destructive cleanup.\n"

section "Header"
kv "hook_version" "0.1.3"
kv "mode" "$MODE"
kv "timestamp" "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || unknown)"
kv "host" "$(hostname 2>/dev/null || unknown)"

WORKSPACE_SIZE="$(workspace_size_signal "${PWD}")"

section "Storage"
kv "internal_disk" "$(safe_cmd df -H "$HOME" | awk 'NR == 2 { printf "used=%s free=%s mount=%s", $5, $4, $NF }')"
kv "workspace_size" "$WORKSPACE_SIZE"
kv "codex_home_size" "not_collected_default_fast_path"
kv "slash_tmp_size" "$(du_mb_deep /tmp)"

section "I/O Pressure"
kv "iostat" "$(safe_cmd iostat -d -c 1 | tail -n +3 | tr '\n' '; ' | sed 's/[; ]*$//')"

section "CPU"
kv "load_average" "$(safe_cmd uptime | awk -F'load averages?: ' '{ print $2 }')"
kv "top_cpu_processes" "$(top_processes 3)"
kv "codex_process_count" "$(process_count_matching 'Codex|codex')"
kv "security_daemon_cpu" "$(security_daemon_cpu_summary)"
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
kv "process_count" "$(process_count_total)"
kv "zombie_processes" "$(zombie_process_count)"
kv "long_running_codex_helpers" "$(long_running_codex_helpers)"

section "Resource Limits"
kv "open_file_limit" "$(ulimit -n 2>/dev/null || unknown)"
kv "process_limit" "$(ulimit -u 2>/dev/null || unknown)"
kv "listening_socket_count" "$(listening_socket_count)"

section "OS Security / Permissions"
kv "recent_security_denial_lines" "$(security_counts)"
kv "codex_gatekeeper" "$(codex_gatekeeper_status)"

section "Runtime / Tooling"
kv "runtime_processes" "$(runtime_processes)"
kv "npm_cache_size" "$(du_mb_deep "$HOME/.npm")"
kv "homebrew_cache_size" "$(du_mb_deep "$HOME/Library/Caches/Homebrew")"

section "Workspace Hygiene"
kv "cwd" "$PWD"
kv "cwd_size" "$WORKSPACE_SIZE"
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
kv "gpu_renderer_processes" "$(gpu_renderer_processes)"

section "System State"
kv "uptime" "$(system_state)"
kv "sleep_settings" "$(safe_cmd pmset -g custom | awk '/ sleep| displaysleep| disksleep| powernap/ { printf "%s; ", $0 }' | head -c 500)"

END_NS="$(date +%s 2>/dev/null || echo "$START_NS")"
section "Collection"
kv "duration_seconds" "$((END_NS - START_NS))"
