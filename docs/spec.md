# System Health Hook Spec

## Purpose

Give an agent cheap local machine context before each turn and require one
bounded investigation before finishing when strong system pressure is visible.

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
The second emits `{}` unless attention is required, in which case it emits one
`decision: block` continuation. If `stop_hook_active` is true, it always emits
`{}` to prevent repeated continuation.

The continuation must preserve the original task: investigate only as far as
needed, adapt or clean up safe resources owned by that task, and then finish the
original request. It must not replace the requested result with a health report.

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

Use this snapshot as operational context.
Do not refuse work solely because of system health.
If Attention is required, investigate the listed facts before adding more load. Do not wait for the user to notice.
Do not recite healthy values.
Helpers listed may belong to other active sessions; own only what this session started.
At turn end, clean up only safe, clearly-owned resources.
Ask before destructive cleanup.
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
- a recognized tool helper using at least one full core in the current sample
- a recognized Codex/tool process with high lifetime-average CPU, large current
  memory, sustained writes, or excessive wakeups

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

## Privacy

The hook should emit system metadata, not private content. It must not print
secrets, environment variable values, tokens, clipboard contents, document bodies,
browser history, message contents, file contents, or process command lines.
Process classification may inspect argv, but it must stop after `argc` entries
and must not read the environment block returned by `KERN_PROCARGS2`.
