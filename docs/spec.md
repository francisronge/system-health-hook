# System Health Hook Spec

## Purpose

Give an agent current local machine context before and after work.

## Non-Goals

- It does not act.
- It does not block work.
- It does not recommend actions.
- It does not identify cleanup candidates.
- It does not delete files.
- It does not kill processes.
- It does not change system settings.

## Run Points

- `turn_start`: fast local snapshot before planning.
- `turn_end`: local snapshot after work. Runtimes may add turn deltas if already available.

## Agent Payload

The hook output begins with this agent-facing text:

```text
System Health Context

Use this telemetry as local system context.
Do not refuse work solely because of system health.
Investigate further when relevant, including other local system signals if they may affect the task.
At turn end, clean up only safe, clearly-owned resources.
Ask before destructive cleanup.
```

## Fixed Telemetry Domains

The hook should emit each domain every run. Unknown or unavailable values should be
reported as `unknown`, not omitted.

### Storage

- internal disk usage
- free space
- relevant agent/runtime/workspace cache sizes when cheap to compute

### I/O Pressure

- disk read/write pressure when cheap to sample
- recent heavy disk activity if exposed by the platform

### CPU

- load average
- top CPU processes
- agent runtime process count
- security daemon activity
- thermal pressure

### Memory

- memory pressure
- used/free memory when available
- swap usage
- top memory processes

### Power

- battery percentage
- charging state
- power source
- low power mode when available

### Network

- active interface
- Wi-Fi radio state when available
- local gateway latency when cheap
- WAN latency/loss when cheap and allowed
- high-network processes when available
- VPN state when visible

### Codex State

- Codex app-server count
- Codex helper/tool process count
- active thread count when available
- automation/heartbeat count when available
- listening dev ports

### Process Lifecycle

- long-running child processes
- orphaned or zombie processes
- process age for relevant runtime helpers

### Resource Limits

- open files
- process count
- sockets/listeners
- watcher pressure when available

### OS Security / Permissions

- recent sandbox/TCC/Gatekeeper denial counts when cheap
- security daemon activity
- expected app permission state when available

### Runtime / Tooling

- Docker/VM runtime state
- package manager/cache size when cheap
- Node/Python/Xcode/build/watch processes

### Workspace Hygiene

- worktree count/size/age when cheap
- duplicate checkout hints when cheap
- large generated artifacts when cheap
- untracked build output summary when already available

### Browser / UI Automation State

- browser automation helper processes
- stuck browser drivers
- screen capture/computer-use helper state

### Logs / Diagnostics Growth

- large agent/runtime logs
- crash dumps
- trace/sysdiagnose/test artifact growth when cheap

### Sync / Backup / Indexing

- Spotlight indexing pressure
- Time Machine activity
- cloud sync pressure when visible

### GPU / Display / Media

- GPU/renderer helper pressure
- display capture state when visible
- camera/audio helper state when visible

### System State

- uptime
- sleep/wake recency when cheap
- macOS update/background maintenance activity when visible

## Privacy

The hook should emit system metadata, not private content. It must not print
secrets, environment variable values, tokens, clipboard contents, document bodies,
browser history, message contents, or file contents.
