# System Health Hook

A small reference spec and collector for giving coding agents local machine context
before and after work.

## Why This Exists

Coding agents often do not inspect the health of the machine they are working on
unless the user explicitly says something feels wrong. That is backwards: agents
clone repos, spawn browsers, start dev servers, run tests, create worktrees, and
write caches. They should have basic local system context before and after they
do that work.

Two real incidents motivated this project:

- On a MacBook Air, the internal SSD was already around 97% full. An agent cloned
  a temporary Parallax checkout anyway, pushing disk usage to about 99%.
- During an agent evaluation run, a headless Chrome profile was left running for
  about three hours. Codex missed it until prompted; one renderer was consuming
  roughly a full CPU core.

These are exactly the kinds of issues system-health-aware agents should notice:
low disk before creating large artifacts, browser automation left behind after a
task, helper processes burning CPU, stale dev servers, runaway logs, or network
load affecting other people on the same connection.

This is not meant to make agents timid, or make them refuse work just because
the machine is under pressure. If the work can be done, they should still do it.
The hook is a reminder layer: know the machine you are running on, avoid adding
pointless churn, and clean up safe, clearly-owned leftovers when the work is done.

The hook is intentionally boring:

- read-only
- fixed-shape
- telemetry-only
- local machine context
- no cleanup decisions
- no process killing
- no file deletion
- no task blocking

The agent receives the telemetry, interprets it, investigates further when relevant,
and cleans up only resources it can safely attribute to its own work.

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

The hook can run at turn start and turn end. The reference script is stateless; a
runtime may add turn deltas if it already tracks them.

## Reference Collector

```sh
bin/system-health-context.sh turn_start
bin/system-health-context.sh turn_end
```

The collector targets macOS first and degrades fields to `unknown` when a command
is unavailable or too expensive.

## Codex Hook Example

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
