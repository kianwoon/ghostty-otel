# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Plugin Does

A Claude Code plugin that receives OTEL spans and drives Ghostty's progress indicator (OSC 9;4) and window title (OSC 2) in real time. Also auto-proceeds stalled agents and detects loops.

## Architecture

```
Claude Code ──OTEL spans──▶ otel-listener.py ──state files──▶ otel-watcher.sh ──OSC──▶ Ghostty
   │                              │                                │
   │                              ├── HoldTimer (60s anti-flap)    ├── OSC 9;4 (progress)
   │                              ├── LLM-pending re-arm           └── OSC 2 (title)
   │                              ├── Loop detection (consecutive tools)
   │                              └── Multi-session routing
   │
   └── Hooks ──▶ shell scripts ──▶ state files / auto-proceed
```

**otel-listener.py** (Python HTTP server on :4318): Receives OTLP JSON, maps span names to states, writes per-session state files. Core internals:
- `HoldTimer`: defers idle spans 60s to prevent indicator flashing between LLM responses. Re-arms on LLM-pending spans (up to 10 re-arms / 10 min).
- `_last_completed` flag: `busy→idle` without completion → `subagent_idle` state
- `_consecutive_tools`: tracks same-tool repetitions; ≥ threshold → `looping` state
- Session routing: `session.id` attribute → session_key via `/tmp/ghostty-sid-*` files

**otel-watcher.sh**: Per-session poll loop (100ms interval). Reads state file, maps to OSC codes (0=idle, 2=red/attention, 3=busy), emits with tmux DCS wrapping when `$TMUX` is set. Keep-alive every 3s.

**Session key**: Derived from TTY device basename (e.g., `ttys003`) via `session-key.sh` (4 fallback methods). Session ID→key mapping stored in `/tmp/ghostty-sid-{key}` files.

**State file format**: `/tmp/ghostty-indicator-state-{key}.txt` — single line: `state[:metadata...]` (e.g., `calling_llm:MiniMax-M2.7[1m]:True`, `looping:Bash`).

## Hook System

All hooks in `hooks/hooks.json`, matcher `"*"`:

| Event | Type | Script/Prompt | Purpose |
|---|---|---|---|
| Stop | prompt | transcript validator | Block stop if task incomplete; `stop_hook_active` guard prevents infinite loops |
| StopFailure | command | `main-agent-proceed.sh` | Auto-proceed main agent on stale idle |
| SubagentStop | command + prompt | `subagent-proceed.sh` + validator | Dual: fast state-file check + transcript completeness check |
| TeammateIdle | command | `teammate-proceed.sh` | Auto-proceed stalled teammate |
| SessionStart | command | `start-listener.sh` | Start singleton listener + per-session watcher |
| UserPromptSubmit | command | `prompt-submit.sh` | Immediate OSC emit (gap coverage before first OTEL span) |
| SessionEnd | command | `session-cleanup.sh` | Kill watcher + remove state files |

**Proceed hooks** (main-agent, subagent, teammate): Check state file for busy states (`calling_llm`, `tool_running`, `tool_exec`, `subagent_idle`, `looping`) and output `{"ok":false,"systemMessage":"proceed — continue your previous task"}` to force continuation.

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `GHOSTTY_OTEL_PORT` | `4318` | OTLP HTTP port |
| `GHOSTTY_OTEL_STATE_DIR` | `/tmp` | State/PID file directory |
| `GHOSTTY_OTEL_HOLD_SECONDS` | `60` | Idle defer (anti-flap) |
| `GHOSTTY_OTEL_LLM_MAX_REARMS` | `10` | Safety cap on LLM re-arms |
| `GHOSTTY_OTEL_LOOP_THRESHOLD` | `5` | Same-tool reps before `looping` |
| `GHOSTTY_OTEL_LOG` | (empty) | Listener log path |

## Testing

No test framework. Validate changes manually:
- `python3 -c "import json; json.load(open('hooks/hooks.json'))"` — validate hooks.json
- `python3 -c "import py_compile; py_compile.compile('scripts/otel-listener.py', doraise=True)"` — validate Python syntax
- Test `state_to_osc()` in otel-watcher.sh by sourcing and calling with state strings
- Test `check_loop()` by importing logic inline with lowered threshold
- Test proceed hooks by creating a temp state file and running the script

## Key Constraints

- Listener is **singleton** — one process serves all sessions. `start-listener.sh` uses PID file + `lsof` for dedup.
- Watcher is **per-session** — one per TTY, started by hooks. Atomic `mkdir` lock prevents duplicates.
- State writes use **atomic rename** (`tmp` → final) to prevent partial reads.
- `prompt-submit.sh` writes `calling_llm` **immediately** on user input — covers the ~100-200ms gap before first OTEL span.
- OTEL `calling_llm` spans arrive **after** LLM completion, so the listener only updates HoldTimer (doesn't write state) for them.
- OSC 9;4 resets after ~15s of inactivity — watcher re-emits every 3s as keep-alive.
