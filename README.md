# System Health Hook

A small macOS-first collector that gives Codex and other coding agents a quick
read on the machine before they start work and after they finish.

## Why This Exists

Agents are good at jumping into code, but they usually do not look at the
computer they are running on unless you tell them something feels off. That is
how you end up with big clones on nearly-full disks, forgotten browser profiles,
stale dev servers, and helper processes eating CPU in the background.

Two real things that happened for me:

- On a MacBook Air, the internal SSD was already around 97% full. An agent cloned
  a temporary Parallax checkout anyway, pushing disk usage to about 99%.
- During an agent evaluation run, a headless Chrome profile was left running for
  about three hours. Codex missed it until prompted; one renderer was consuming
  roughly a full CPU core.

That is the problem this hook is for. Before an agent clones a repo, runs a
build, opens a browser, or starts a server, it should have a quick local
snapshot. When it finishes, it should notice obvious leftovers it owns and clean
them up safely.

This is not meant to make agents timid, or make them refuse work just because the
machine is under pressure. If the work can be done, they should still do it. The
hook is a reminder layer: know the machine you are running on, avoid adding
pointless churn, and clean up safe, clearly-owned leftovers when the work is
done.

The hook is intentionally boring:

- read-only
- fixed-shape
- telemetry-only
- local machine context
- no cleanup decisions
- no process killing
- no file deletion
- no task blocking

The hook only reports facts. The agent decides what those facts mean, investigates
more if needed, and only cleans up resources it can clearly tie to its own work.

## Shape

The hook emits:

- a short agent instruction
- collection metadata
- fixed local system telemetry sections

Telemetry domains:

- Storage
- I/O Pressure
- CPU
- Memory
- Power
- Network
- Codex State
- Process Lifecycle
- Resource Limits
- OS Security / Permissions
- Runtime / Tooling
- Workspace Hygiene
- Browser / UI Automation State
- Logs / Diagnostics Growth
- Sync / Backup / Indexing
- GPU / Display / Media
- System State

The hook can run at turn start and turn end. The reference script is stateless.
A runtime that already tracks turns can add deltas.

## Reference Collector

```sh
bin/system-health-context.sh turn_start
bin/system-health-context.sh turn_end
```

The collector targets macOS first and degrades fields to `unknown` when a command
is unavailable or too expensive.

## Install For Codex

Clone the repo, then run the installer:

```sh
git clone https://github.com/francisronge/system-health-hook.git
cd system-health-hook
./scripts/install-codex-hook.sh
```

The installer copies the hook to:

```text
~/.codex/hooks/system-health-context/
```

If `~/.codex/config.toml` does not already have a `[hooks]` section, the installer
adds the Codex config for you and creates a timestamped backup. If you already
have hooks, it installs the files and prints the small config block to merge.

Codex may ask you to review new or changed hooks. That is expected. Review the
path and trust it if it points to the hook you just installed.

To check the hook directly:

```sh
~/.codex/hooks/system-health-context/system-health-codex-hook.zsh turn_start
```

## Manual Codex Config

Install the collector somewhere stable, then register it as a command-backed
prompt hook so the agent receives the system health context:

```toml
[hooks]
UserPromptSubmit = [
  { prompt = { command = "/path/to/system-health-codex-hook.zsh", args = ["turn_start"], timeout = 5, statusMessage = "Collecting system health context" } }
]
Stop = [
  { command = "/path/to/system-health-codex-hook.zsh", args = ["turn_end"], timeout = 8, statusMessage = "Collecting end-of-turn system health" }
]
```

The wrapper should exit successfully even when individual probes fail, and may
write the latest collected context to disk for debugging.

## License

MIT
