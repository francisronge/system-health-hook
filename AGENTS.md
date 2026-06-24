# Agent Notes

This repo is a small open-source spec and reference collector for local system
health context hooks.

Keep changes small and boring. The hook must remain read-only telemetry plumbing.
Do not add automatic cleanup, process killing, file deletion, or policy decisions
to the hook itself.
