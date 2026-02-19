# Claude Task System

System code for the Claude Task System (CTS) and Ralph Pro integration running on labmachine.

## Structure

- `cts-v2/src/` — CTS v2 supervisor, scheduler, watcher, invokers, and libraries
- `ralph-pro/` — Ralph Pro monitoring scripts (healthcheck, fixer, daily digest, overnight monitor)
- `state-dir/` — Shared utility scripts (status dashboard, monitoring checks, audit watcher)
- `systemd/` — Systemd user unit files for all services and timers

## State Directory

Runtime state lives at `~/.claude-task-system/` with namespaced subdirectories:
- `cts/` — CTS v2 runtime state (events, tasks, sessions, locks)
- `ralph-pro/` — Ralph Pro state (monitor state, snapshots, fix requests)
- `shared/` — Shared state (logs, audit, usage, journal)

## Quick Status

```bash
~/.claude-task-system/cts-status.sh
```
