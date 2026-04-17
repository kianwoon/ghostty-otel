# Idle Detection + Auto-Proceed for Subagents

**Date**: 2026-04-17
**Status**: Approved

## Problem

When a Claude Code subagent (Agent tool or Team teammate) reads a file and finishes its turn, it goes idle. If the turn ended without completing its analysis (no "done" signal), the subagent stalls — the user must manually send "proceed" to resume it.

## Solution

Two-part system: OTEL-driven detection + hook-based auto-proceed.

### Part 1: Detection (`otel-listener.py`)

Track per-session state transitions to detect "stale idle" — an idle span arriving without a prior clean completion.

**Logic**:
- HoldTimer tracks `_last_completed` flag, set when we see a `done` or `waiting_input` span
- When an `idle` span arrives and `_last_completed` is False and `_has_been_busy` is True → write state `subagent_idle`
- When a `done` or `waiting_input` span arrives → set `_last_completed = True`
- When a busy span (`calling_llm`, `tool_running`, `tool_exec`) arrives → set `_last_completed = False`

**State file value**: `subagent_idle` (distinct from `idle` and `waiting_input`)

### Part 2: Notification (`otel-watcher.sh`)

Add `subagent_idle` to `state_to_osc()`:
- `subagent_idle` → OSC code 2 (same visual as waiting_input, but semantically different)
- Window title: `"claude: subagent_idle"` for disambiguation

### Part 3: Auto-Proceed Hooks

**`scripts/subagent-proceed.sh`** — SubagentStop hook:
1. Read state file for current session
2. If state is `subagent_idle` → exit 2 + stderr `"proceed — continue your previous task"`
3. Otherwise → exit 0

**`scripts/teammate-proceed.sh`** — TeammateIdle hook:
1. Same logic as subagent-proceed.sh
2. Exit 2 + "proceed" if stale idle detected

**Performance**: single file read + string match. Under 5ms.

### Part 4: Hook Registration (`hooks.json`)

Add two new hook entries:
- `SubagentStop` → `bash scripts/subagent-proceed.sh` (timeout 5s)
- `TeammateIdle` → `bash scripts/teammate-proceed.sh` (timeout 5s)

## Files Modified

| File | Change |
|------|--------|
| `scripts/otel-listener.py` | Add `_last_completed` tracking, `subagent_idle` state |
| `scripts/otel-watcher.sh` | Add `subagent_idle` → OSC 2 in `state_to_osc()` |
| `scripts/subagent-proceed.sh` | New file — SubagentStop hook |
| `scripts/teammate-proceed.sh` | New file — TeammateIdle hook |
| `hooks/hooks.json` | Add SubagentStop + TeammateIdle entries |

## Edge Cases

- **Race condition**: Busy span arrives right after idle → `_last_completed` resets correctly
- **Multiple idle spans**: Only the first triggers `subagent_idle`; subsequent ones match existing state (no-op)
- **Session cleanup**: `subagent_idle` state cleared by existing session-cleanup.sh on SessionEnd
- **HoldTimer interaction**: Existing hold logic still prevents premature idle during slow LLM calls; `subagent_idle` only triggers after hold expires

## Out of Scope

- Rich heuristics analyzing subagent message content for incompleteness
- MCP server for external message injection
- Team lead auto-SendMessage (handled by TeammateIdle hook + exit 2)
