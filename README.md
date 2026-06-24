# System Health Hook

A small reference spec and collector for giving coding agents local machine context
before and after work.

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

## License

MIT
