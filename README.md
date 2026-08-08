# System Health Hook

A tiny macOS-first system health context hook for Codex and other coding agents.

It gives the agent a cheap read on the machine before each turn and reminds it to
clean up after the work, without turning the health check into another source of
churn.

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
- Codex browser tooling left a persistent Node-REPL kernel running for four and a
  half hours. It was using roughly one and a half CPU cores, had an 11 GB physical
  footprint, and had peaked at 40 GB. The old hook reduced it to a generic
  `ChatGPT` process and did not make the problem visible.
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

The collector combines a 100 ms live sample with durable counters already kept
by macOS. The live sample shows what is busy now. Process age, lifetime CPU,
physical and peak memory, disk I/O, and wakeups keep long-running tooling visible
even when the short sample lands during a quiet moment.

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
- workspace filesystem walks

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

Treat this as operational context, not decoration.
Do not refuse work solely because of system health.
If a signal could affect the work, investigate before adding load and adapt.
Do not recite healthy values.
Helpers listed may belong to other active sessions; own only what this session started.
At turn end, clean up only safe, clearly-owned resources.
Ask before destructive cleanup.

Header: hook_version=0.4.0 mode=turn_start timestamp=... host=...
Storage: disk=10% free=1789G
CPU: cores=18 busy=8.4% load=3.73/3.15/2.79 top=node_repl[5960]:166%/4h33m
Security: syspolicyd=0.0% trustd=0.0% sandboxd=0.0%
Memory: pressure=normal ram=68.7G free=9.0G inactive=31.7G compressed=3.8G wired=3.5G swap=0.4G top=node_repl[5960]:11.0G/peak=40.0G/4h33m
Power: source=AC battery=100% charging=not_charging low_power=off thermal_pressure=nominal
Network: route=en0 rx=29KB/s tx=51KB/s gateway=192.168.1.1 gateway_tcp=3.3ms wan_tcp=7.8ms
WiFi: interface=en0 associated=yes rssi=-53dBm noise=-96dBm channel=36 tx=1080Mbps
Codex: hosts=13 helpers=18 (mcp=7 node_repl=5 computer_use=2 xcodebuildmcp=4) app_servers=2 oldest=(mcp=6h31m node_repl=5h28m computer_use=2h4m xcodebuildmcp=5h28m)
CodexResources: cpu=node_repl[5960]:now=166%/avg=150%/age=4h33m memory=node_repl[5960]:11.0G/peak=40.0G io=node_repl[5960]:read_avg=1.2MB/s/total=20.0G/write_avg=123KB/s/total=2.0G
Lifecycle: uptime=6h33m processes=484 zombies=0 orphaned_helpers=0
BrowserAutomation: processes=12 profiles=1 orphaned=0 debug_ports=0
Collection: 138ms
```

`Network` follows the kernel's default route, including a VPN tunnel. `WiFi`
still describes the physical wireless link, so the two lines can be different.

`thermal_pressure=nominal` means macOS is not currently throttling the machine.
It does not mean the laptop is cool. CPU use and process resource lines are what
make a heat source visible before thermal throttling starts.

The example values above are illustrative. The hook reports raw facts and leaves
the investigation and response to the agent.

## Performance Budget

The hook remains a single short-lived process. On the machine used to develop
version 0.4, nine comparable runs had a median of 145 ms for the installed 0.3
collector and 148 ms for the 0.4 release collector. The 100 ms live sample still
accounts for most of that time.

Performance is part of correctness here. New default signals should use bounded
native APIs, fit inside the existing sample window, and be benchmarked before
release.

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

Test with compiler warnings treated as errors:

```sh
swift test -Xswiftc -warnings-as-errors
```

Run:

```sh
.build/debug/system-health-context turn_start
.build/debug/system-health-context --json turn_start
```

## License

MIT
