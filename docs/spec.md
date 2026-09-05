# System Health Hook Spec

## Purpose

Give an agent cheap local machine context before each turn and flag resource use
without requiring a separate investigation or another turn.

The hook reports what the machine looks like and evaluates fixed attention
rules. It does not decide what system action to take.

## Non-Goals

- It does not act on the machine.
- It does not block tools or user requests.
- It does not recommend actions.
- It does not identify cleanup candidates.
- It does not delete files.
- It does not kill processes.
- It does not change system settings.

## Default Collector

The default collector is one native Swift executable:

```text
system-health-context
```

New Codex installations call that binary directly. The compatibility wrapper
delegates to the same binary and exits.

There is no daemon, local server, background cache, or always-on monitor.

The collector uses one 100 ms live sample. Durable process counters supplement
that sample so a long-running process remains visible when it happens to be quiet
during the sample.

## CLI

```sh
system-health-context turn_start
system-health-context turn_end
system-health-context --json turn_start
system-health-context --codex-hook turn_start
system-health-context --codex-hook turn_end
system-health-context --version
```

The text format is for agent context. The JSON format is for tests and other
integrations.

For Codex, install `--codex-hook turn_start` on `UserPromptSubmit` and
`--codex-hook turn_end` on `Stop`. The first emits additional developer context.
The second emits `{}` unless attention is flagged, in which case it emits only
`systemMessage`, a UI warning. Neither path emits `decision`, `reason`, or
`continue`. If `stop_hook_active` is true, it returns `{}` before collecting,
avoiding another warning if another hook continued the turn.

Stop does not resume the agent or deliver a cleanup instruction for execution.
Cleanup is part of the start-of-turn guidance. The agent should preserve the
requested result and use targeted checks when relevant, not make health a
prerequisite for ordinary work. This advisory design cannot guarantee compliance.

## Probe Budget

The hook must not create the system-health problem it is trying to expose.

Default collection must stay cheap, bounded, read-only, and short-lived.

Default collection must not run:

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

If a signal needs one of those, it does not belong in the default hook. The agent
can investigate manually when the surface snapshot gives it a reason.

## Agent Payload

The hook output begins with this agent-facing text:

```text
System Health Context

Keep the user's task primary. These readings are advisory, not a reason by themselves to refuse, delay, reduce scope, or start a separate health investigation.
Use the available capacity when planning resource-heavy work. Avoid unnecessary copies and unbounded process spawning; preserve the requested result.
When readings suggest a relevant risk or wasted resources, make a brief targeted check as part of the work. High usage or an old PID alone does not prove a runaway. No broad audits or polling loops.
Before finishing, clean up verified unneeded resources from this task, including helpers it reused. Prefer closing or resetting through the owning tool, and verify cleanup. Protect active or shared resources; establish ownership before stopping processes or deleting files.
Briefly mention material risks or verified cleanup without replacing the requested result. Keep healthy readings out of the reply.
```

## Compact Domains

Default output should stay small enough to read at a glance.

Current domains:

- Attention
- Header
- Storage
- CPU
- Security
- Memory
- Power
- Thermals
- Network
- WiFi
- Codex
- CodexResources
- Lifecycle
- BrowserAutomation
- Collection

Signals that are useful but not cheap enough for the default path should be left
out of the card, not represented as skipped probe noise.

Process output should preserve a useful type and PID without printing command
lines. For Codex and tool helpers, the compact card may include:

- current and lifetime-average CPU
- current and peak physical footprint
- lifetime and average disk I/O
- average wakeups
- process age

Helper categories must be disjoint. A process belongs to one type, so the typed
counts add up to the reported helper total.

`Network` follows the kernel's default route. `WiFi` describes the physical
wireless interface, even when a VPN owns the route.

`Thermals` reports direct sensor values in Celsius, current and maximum fan RPM
when available, and Apple's coarse macOS thermal state. Targeted AppleSMC
readings are preferred; the HID temperature hub is the fallback. Private sensor
APIs may be unavailable or may change, so missing values must remain
`unavailable`.

## Attention Rules

Attention is a pure, deterministic evaluation over the snapshot. It is not a
cleanup decision. At most three reasons are emitted.

Current high-confidence triggers:

- internal disk at least 90% used or less than 20 GB free
- warning or critical memory pressure
- a direct thermal sensor at least 90 C
- serious or critical macOS thermal state
- fan at least 85% of a known maximum, or at least 5000 RPM
- `syspolicyd`, `trustd`, and `sandboxd` using at least 50% CPU in total
- a recognized tool helper at least one minute old using one full core now
- a recognized Codex/tool process at least 30 minutes old with lifetime-average
  CPU at least 50% and current CPU at least 25%
- a helper footprint at least one eighth of RAM (threshold bounded to 1-4 GB),
  or a Codex host footprint at least one quarter of RAM (bounded to 2-8 GB),
  without an age gate
- recognized Codex/tool processes at least ten minutes old averaging at least
  20 MB/s of lifetime writes or 1000 wakeups/s
- when no individual process crosses a threshold, helpers at least one minute
  old collectively using a core or a quarter of RAM (minimum 2 GB)

The process reason includes up to three processes, their PIDs and parent PIDs,
and a count of any additional matches. Collective pressure shows up to three
leading helpers. These thresholds flag readings, not mandatory action. Lifetime
averages do not establish that writes or wakeups are still happening now.

Age, helper count, historical peak memory, or `ppid == 1` alone must not trigger
attention. PID 1 can mean launchd-owned, so the output reports it only as
`parent_pid_1`. The agent investigates ownership and cause before taking action.

## Performance Gate

Changes to the default collector must be benchmarked as a release build. Added
signals should fit inside the existing sample window and should not introduce a
daemon, subprocess fan-out, unbounded enumeration, or repeated deep probes.

`Stop` skips Wi-Fi, route, and WAN probes. It still keeps the 100 ms CPU sample
because current CPU use is part of the attention decision.
When Codex sets `stop_hook_active`, the binary returns `{}` before collecting a
second snapshot.

Each process's CPU delta uses its own monotonic measurement interval. Process
classification is computed once per snapshot and reused. The collector does not
keep history on disk or run between events. Mid-turn rechecks are an instruction
to the agent, not a guaranteed automatic callback.

## Privacy

The hook should emit system metadata, not private content. It must not print
secrets, environment variable values, tokens, clipboard contents, document bodies,
browser history, message contents, file contents, or process command lines.
Process classification may inspect argv, but it must stop after `argc` entries
and must not read the environment block returned by `KERN_PROCARGS2`.
