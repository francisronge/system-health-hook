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
- During a Babel run, two forgotten `computer_use` workers were still alive after
  26-33 hours. One was using roughly two CPU cores and 9.5 GB of memory. macOS
  still reported nominal thermals, and Codex did not investigate until I asked.

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

The collector reports facts and applies a small set of fixed attention rules. The
agent still investigates the cause, decides what to do, and only cleans up
resources it can clearly tie to its own work.

## How It Works

The default collector is a native Swift CLI:

```text
UserPromptSubmit -> system-health-context -> compact system snapshot -> exits
Stop            -> system-health-context -> quiet or a UI warning -> exits
```

There is no daemon, no local server, no always-on monitor, and no automatic
cleanup.

New installs call the native binary directly. A small shell wrapper remains for
older installations.

The collector combines a 100 ms live sample with durable counters already kept
by macOS. The live sample shows what is busy now. Process age, lifetime CPU,
physical and peak memory, disk I/O, and wakeups keep long-running tooling visible
even when the short sample lands during a quiet moment.

At the end of a turn, Codex runs a smaller snapshot without the network probes.
If a fixed rule flags resource use, Stop emits a UI warning. Otherwise it stays
quiet. It never restarts the agent, blocks a tool, kills a process, or deletes a
file. The warning does not create a cleanup turn.

The start-of-turn guidance asks the agent to account for available capacity and
clean up verified leftovers as part of the work, including helpers it reused.
It should check ownership and protect active or shared resources.

The hook does not run between those events. Cleanup and any targeted checks
depend on the agent following instructions. It cannot guarantee cleanup, prevent
every runaway, or have zero cost. Legitimate heavy work can also trigger a warning.

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
- local machine context
- deterministic attention rules
- no cleanup decisions
- no process killing
- no file deletion
- no tool or user-request blocking
- no end-of-turn continuation

## Output Shape

Default text output is a compact card:

```text
System Health Context

Keep the user's task primary. These readings are advisory, not a reason by themselves to refuse, delay, reduce scope, or start a separate health investigation.
Use the available capacity when planning resource-heavy work. Avoid unnecessary copies and unbounded process spawning; preserve the requested result.
When readings suggest a relevant risk or wasted resources, make a brief targeted check as part of the work. High usage or an old PID alone does not prove a runaway. No broad audits or polling loops.
Before finishing, clean up verified unneeded resources from this task, including helpers it reused. Prefer closing or resetting through the owning tool, and verify cleanup. Protect active or shared resources; establish ownership before stopping processes or deleting files.
Briefly mention material risks or verified cleanup without replacing the requested result. Keep healthy readings out of the reply.

Attention: flagged node_repl[5960] age=4h33m ppid=5900 cpu_now=166% cpu_avg=150% memory=11.0G
Header: hook_version=0.6.1 mode=turn_start timestamp=... host=...
Storage: disk=10% free=1789G
CPU: cores=18 busy=8.4% load=3.73/3.15/2.79 top=node_repl[5960]:166%/4h33m
Security: syspolicyd=0.0% trustd=0.0% sandboxd=0.0%
Memory: pressure=normal ram=68.7G free=9.0G inactive=31.7G compressed=3.8G wired=3.5G swap=0.4G top=node_repl[5960]:11.0G/peak=40.0G/4h33m
Power: source=AC battery=100% charging=not_charging low_power=off
Thermals: sensor_avg=49.3C sensor_max=57.2C cpu_sensor_avg=57.2C cpu_sensor_max=57.2C gpu_sensor_avg=46.2C gpu_sensor_max=46.2C soc_sensor_avg=44.6C soc_sensor_max=44.6C fans=2:1350rpm/max=5349rpm,1459rpm/max=5777rpm macos_state=nominal
Network: route=en0 rx=29KB/s tx=51KB/s gateway=192.168.1.1 gateway_tcp=3.3ms wan_tcp=7.8ms
WiFi: interface=en0 associated=yes rssi=-53dBm noise=-96dBm channel=36 tx=1080Mbps
Codex: hosts=13 helpers=18 (mcp=7 node_repl=5 computer_use=2 xcodebuildmcp=4) app_servers=2 oldest=(mcp=6h31m node_repl=5h28m computer_use=2h4m xcodebuildmcp=5h28m)
CodexResources: cpu=node_repl[5960]:now=166%/avg=150%/age=4h33m memory=node_repl[5960]:11.0G/peak=40.0G io=node_repl[5960]:read_avg=1.2MB/s/total=20.0G/write_avg=123KB/s/total=2.0G
Lifecycle: uptime=6h33m processes=484 zombies=0 parent_pid_1_helpers=0
BrowserAutomation: processes=12 profiles=1 parent_pid_1=0 debug_ports=0
Collection: 198ms
```

`Network` follows the kernel's default route, including a VPN tunnel. `WiFi`
still describes the physical wireless link, so the two lines can be different.

`macos_state` is Apple's coarse thermal state. The temperatures and fan RPM are
direct sensor readings. A nominal macOS state does not override those values or
the process resource lines.

On Apple Silicon, the collector first reads a small targeted set of AppleSMC
sensors for CPU, GPU, SoC, and fan RPM. If those are unavailable, it falls back
to the HID temperature hub. These interfaces are private and undocumented, so a
missing reading is reported as `unavailable`, never guessed.

The example values above are illustrative. The hook reports raw facts and leaves
the investigation and response to the agent.

## Performance Budget

The hook remains a single short-lived process. In three interleaved end-of-turn
release runs per version on the development M5 Pro, version 0.6 used a median
104 ms of CPU time and finished in 211 ms, compared with 178 ms CPU and 283 ms
elapsed for version 0.5. These are local measurements, not a guarantee for every
machine. The collector still waits for a 100 ms live sample.

`Collection` now includes building the snapshot's text fields. Earlier versions
stopped that timer too soon, so compare total elapsed and CPU time when measuring
changes. Nothing stays running between hook calls.

Performance is part of correctness here. New default signals should use bounded
native APIs, fit inside the existing sample window, and be benchmarked before
release.

JSON is available for tests and integrations:

```sh
.build/debug/system-health-context --json turn_start
```

## Install For Codex

Clone the repo, then run the installer:

Requires Xcode Command Line Tools (Swift 6+) and Python 3.11+ for installation.
Python is not used when the hook runs.

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

The installer registers both events in `~/.codex/config.toml`, repairs older
registrations for this hook, and preserves other hooks and settings. It creates
a private backup before changing the config. If it cannot safely preserve the
config, it stops with an error. It then checks both registrations, compares the
installed binary with the build, and prints its version.

Rerun the installer after updating the repo. Pulling new code does not update the
installed copy by itself.

Codex may ask you to review new or changed hooks. Review the path and trust it if
it points to the hook you just installed. After that, the Hooks page should show
entries for `UserPromptSubmit` and `Stop`.

To check the installed hook directly:

```sh
~/.codex/hooks/system-health-context/system-health-context --codex-hook turn_start
python3 scripts/configure-codex-hook.py ~/.codex/config.toml ~/.codex/hooks/system-health-context/system-health-context --check
```

## Manual Codex Config

Install the collector somewhere stable, then register it as a command hook:

```toml
[hooks]
UserPromptSubmit = [
  { hooks = [ { type = "command", command = "/path/to/system-health-context --codex-hook turn_start", timeout = 5, statusMessage = "Collecting system health context" } ] }
]
Stop = [
  { hooks = [ { type = "command", command = "/path/to/system-health-context --codex-hook turn_end", timeout = 5, statusMessage = "Checking end-of-turn system health" } ] }
]
```

The binary emits developer-context JSON for `UserPromptSubmit` and
notification JSON for `Stop`. It never emits a blocking decision. Individual
sensor failures remain non-fatal.

## Development

Build:

```sh
swift build --product system-health-context
```

Test with compiler warnings treated as errors:

```sh
swift test -Xswiftc -warnings-as-errors
python3 -B -m unittest discover -s Tests -p 'test_*.py'
```

Run:

```sh
.build/debug/system-health-context turn_start
.build/debug/system-health-context --json turn_start
.build/debug/system-health-context --codex-hook turn_start
```

## License

MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the thermal sensor
implementation's upstream notice.
