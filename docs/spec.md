# System Health Hook Spec

## Purpose

Give an agent cheap local machine context before and after work.

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

If a signal needs one of those, it does not belong in the default hook. The agent
can investigate manually when the surface snapshot gives it a reason.

## Agent Payload

The hook output begins with this agent-facing text:

```text
System Health Context

Use this as cheap local machine context.
Do not refuse work solely because of system health.
If something looks unhealthy, investigate before adding heavier work.
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
- Lifecycle
- BrowserAutomation
- Collection

Signals that are useful but not cheap enough for the default path should be left
out of the card, not represented as skipped probe noise.

## Privacy

The hook should emit system metadata, not private content. It must not print
secrets, environment variable values, tokens, clipboard contents, document bodies,
browser history, message contents, file contents, or process command lines.
