# System Health Hook

A tiny macOS-first system health context hook for Codex and other coding agents.

It gives the agent a cheap read on the machine before it starts work and after it
finishes, without turning the health check into another source of churn.

## Why This Exists

Agents are good at jumping into code, but they usually do not look at the
computer they are running on unless you tell them something feels off.

That is insane to me. These tools can change your life, and Codex is still my
favorite tool ever. I just do not want the fan screaming to be the first sign
that something is wrong.

That is how you end up with big clones on nearly-full disks, forgotten browser
profiles, stale dev servers, security daemons melting the CPU, and helper
processes eating the machine in the background.

A few real things that happened for me:

- On a MacBook Air, the internal SSD was already around 97% full. An agent cloned
  a temporary Parallax checkout anyway, pushing disk usage to about 99%.
- During a Parallax evaluation run, a headless Chrome profile was left running for
  about three hours. Codex missed it until prompted; one renderer was consuming
  roughly a full CPU core.
- macOS can run security checks around spawned processes through `syspolicyd`,
  `trustd`, and friends. I have seen that turn into brutal CPU churn with Codex:
  an older Full Disk Access/write-access issue was bad enough to crash my M5 Pro,
  and a few days later `syspolicyd` still spiked to roughly 94% while I only had
  two Codex threads and a Parallax eval going.
- Storage got stupid too. Every Parallax eval run had been saving garbage Codex
  did not clean up, and the worktrees were taking an absurd amount of space. I
  had about 1.9 TB used on a Mac I had only owned for a few weeks.

This is not just my machine being weird. Theo talked about the same macOS process
security-check problem on Nerd Snipe at
[28:41-29:47](https://www.youtube.com/watch?v=qfSgN9i5Fd4&t=1721s). There was
also a viral report of a Codex bug hammering SSD writes:
[x.com/hqmank/status/2069020259097735231](https://x.com/hqmank/status/2069020259097735231?s=46).

[![Nerd Snipe clip about macOS process security checks](https://img.youtube.com/vi/qfSgN9i5Fd4/hqdefault.jpg)](https://www.youtube.com/watch?v=qfSgN9i5Fd4&t=1721s)

That is the problem this hook is for. Before an agent clones a repo, runs a build,
opens a browser, starts a server, or spawns a pile of helpers, it should have a
quick local snapshot. When it finishes, it should notice obvious leftovers it
owns and clean them up safely.

This is not meant to make agents timid, or make them refuse work just because the
machine is under pressure. If the work can be done, they should still do it. The
hook is just context: let the agent see the machine, avoid obvious waste, and
clean up safe stuff it clearly owns when the work is done.

The hook only reports facts. The agent decides what those facts mean, investigates
more if needed, and only cleans up resources it can clearly tie to its own work.

## How It Works

The default collector is a native Swift CLI:

```text
Codex hook
  -> system-health-codex-hook.zsh
  -> system-health-context
  -> compact system snapshot
  -> exits
```

There is no daemon, no local server, no always-on monitor, and no automatic
cleanup.

The shell wrapper exists only to fit Codex's command-hook shape. The actual
health collection is done by the native binary.

## Safety Budget

The hook itself cannot become the problem.

The normal collector does not run:

- `log show`
- `spctl`
- `codesign`
- `du`
- `find`
- `lsof`
- `system_profiler`
- `top`
- `ps`
- shell pipelines
- source/repo scans

It uses bounded macOS APIs and system calls instead. If a useful signal is not
cheap enough for the default path, it is left out. The agent can investigate
manually when the surface snapshot shows a real reason.

The hook is intentionally boring:

- read-only
- fixed-shape
- telemetry-only
- local machine context
- no cleanup decisions
- no process killing
- no file deletion
- no task blocking

## Output Shape

Default text output is a compact card:

```text
System Health Context

Use this as cheap local machine context.
Do not refuse work solely because of system health.
If something looks unhealthy, investigate before adding heavier work.
At turn end, clean up only safe, clearly-owned resources.
Ask before destructive cleanup.

Header: hook_version=0.2.0 mode=turn_start timestamp=... host=...
Storage: disk=10% free=1789G workspace=>79.6MB
CPU: load=3.73/3.15/2.79 top=Codex:3.2%, spotlightknowledged:2.3%, Codex:0.3%
Security: syspolicyd=0.0% trustd=0.0% sandboxd=0.0%
Memory: free=30.8G swap=0.0G top=Codex:5.4%, Google Chrome:2.4%, Codex:1.3%
Power: source=AC battery=100% charging=not_charging low_power=off thermal=nominal
Network: interface=en0 gateway=192.168.1.1 gateway_tcp=3.3ms wan_tcp=7.8ms
WiFi: interface=en0 associated=yes rssi=-53dBm noise=-96dBm channel=36 tx=1080Mbps
Codex: processes=27 helpers=13 app_servers=1 mcp=10 mcp_max_age=1h38m node_repl=2 node_repl_max_age=1h38m computer_use=5 computer_use_max_age=1h38m xcodebuildmcp=4 xcodebuildmcp_max_age=1h38m
Lifecycle: processes=426 zombies=0
BrowserAutomation: profiles=13 orphaned=0 debug_ports=0
Collection: 149ms
```

JSON is available for tests and integrations:

```sh
.build/debug/system-health-context --json turn_start
```

## Install For Codex

Clone the repo, then run the installer:

```sh
git clone https://github.com/francisronge/system-health-hook.git
cd system-health-hook
./scripts/install-codex-hook.sh
```

The installer builds the native Swift binary and copies the hook to:

```text
~/.codex/hooks/system-health-context/
```

Installed files:

```text
system-health-context           native collector
system-health-codex-hook.zsh    Codex wrapper
```

If `~/.codex/config.toml` does not already have a `[hooks]` section, the installer
adds the Codex config for you and creates a timestamped backup. If you already
have hooks, it installs the files and prints the small config block to merge.

Codex may ask you to review new or changed hooks. Review the path and trust it if
it points to the hook you just installed. After that, the Hooks page should show
an entry for `UserPromptSubmit`.

To check the installed hook directly:

```sh
~/.codex/hooks/system-health-context/system-health-codex-hook.zsh turn_start
```

## Manual Codex Config

Install the collector somewhere stable, then register it as a command hook:

```toml
[hooks]
UserPromptSubmit = [
  { hooks = [ { type = "command", command = "/path/to/system-health-codex-hook.zsh turn_start", timeout = 5, statusMessage = "Collecting system health context" } ] }
]
```

The wrapper exits successfully even when individual signals are unavailable.

## Development

Build:

```sh
swift build --product system-health-context
```

Run:

```sh
.build/debug/system-health-context turn_start
.build/debug/system-health-context --json turn_start
```

## License

MIT
