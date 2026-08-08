# System Health Hook Spec

## Purpose

Give an agent cheap local machine context before each turn and remind it to clean
up safe, clearly-owned resources when the work is done.

The hook reports what the machine looks like. It does not decide what to do.

## Non-Goals

- It does not act.
- It does not block work.
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

The Codex wrapper calls that binary, prints its output, and exits.

There is no daemon, local server, background cache, or always-on monitor.

The collector uses one 100 ms live sample. Durable process counters supplement
that sample so a long-running process remains visible when it happens to be quiet
during the sample.

## CLI

```sh
system-health-context turn_start
system-health-context turn_end
system-health-context --json turn_start
system-health-context --version
```

The text format is for agent context. The JSON format is for tests and other
integrations.

For Codex, install this on `UserPromptSubmit`. Do not register the plaintext
collector as a `Stop` hook; Codex treats `Stop` as a JSON control hook.
The wrapper still returns no-op JSON for `turn_end` so old cached Stop hook
registrations do not show errors.

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

Treat this as operational context, not decoration.
Do not refuse work solely because of system health.
If a signal could affect the work, investigate before adding load and adapt.
Do not recite healthy values.
Helpers listed may belong to other active sessions; own only what this session started.
At turn end, clean up only safe, clearly-owned resources.
Ask before destructive cleanup.
```

## Compact Domains

Default output should stay small enough to read at a glance.

Current domains:

- Header
- Storage
- CPU
- Security
- Memory
- Power
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

The hook reports `thermal_pressure`, not temperature. A nominal pressure state
means macOS is not throttling; it does not mean the machine is cool.

## Performance Gate

Changes to the default collector must be benchmarked as a release build. Added
signals should fit inside the existing sample window and should not introduce a
daemon, subprocess fan-out, unbounded enumeration, or repeated deep probes.

## Privacy

The hook should emit system metadata, not private content. It must not print
secrets, environment variable values, tokens, clipboard contents, document bodies,
browser history, message contents, file contents, or process command lines.
Process classification may inspect argv, but it must stop after `argc` entries
and must not read the environment block returned by `KERN_PROCARGS2`.
