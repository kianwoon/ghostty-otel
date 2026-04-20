#!/usr/bin/env bash
# proceed-by-state.sh — Shared auto-proceed logic for SubagentStop/TeammateIdle/StopFailure
# Reads state file, blocks stop if agent is busy, allows if idle or stale.
# Input: JSON on stdin (stop_hook_active, session_id, etc.)
# Output: {"ok":true} or {"ok":false,"systemMessage":"..."}
set -uo pipefail

INPUT="$(cat)" || INPUT=""

# ── Gate: stop_hook_active → allow (infinite-loop prevention) ────
if [[ "$INPUT" == *'"stop_hook_active":true'* ]] || [[ "$INPUT" == *'"stop_hook_active": true'* ]]; then
    echo '{"ok":true}'
    exit 0
fi

STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
HOLD_SECONDS="${GHOSTTY_OTEL_HOLD_SECONDS:-60}"

# ── Session key derivation (session_id → SID file lookup) ────────
# Proceed hooks are detached subprocesses — /dev/tty NOT available.
SESSION_KEY="${GHOSTTY_OTEL_SESSION_KEY:-}"
if [[ -z "$SESSION_KEY" ]]; then
    _sid="${INPUT#*\"session_id\":\"}"
    [[ "$_sid" != "$INPUT" ]] && _sid="${_sid%%\"*}" || _sid=""
    if [[ -n "$_sid" ]]; then
        for _f in "${STATE_DIR}"/ghostty-sid-*; do
            [[ -f "$_f" ]] || continue
            read -r _v < "$_f" 2>/dev/null || continue
            if [[ "$_v" == "$_sid" ]]; then
                SESSION_KEY="${_f##*/ghostty-sid-}"
                break
            fi
        done
    fi
fi

# If no session key, allow stop — don't risk infinite block loop
if [[ -z "$SESSION_KEY" ]]; then
    echo '{"ok":true}'
    exit 0
fi

STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"

# ── Read current state ────────────────────────────────────────────
current=""
if [[ -f "$STATE_FILE" ]]; then
    current="$(cat "$STATE_FILE" 2>/dev/null | tr -d '\n' | cut -d: -f1)" || current=""
fi

# ── Staleness check ──────────────────────────────────────────────
# If state file hasn't been updated in > HOLD_SECONDS+5, the state
# is stale (HoldTimer expired but listener didn't write idle).
# Allow the stop to prevent false-positive proceeds.
if [[ -n "$current" ]] && [[ "$current" != "idle" ]] && [[ "$current" != "done" ]]; then
    _now="$(date +%s)" || _now=0
    _mtime="$(stat -f '%m' "$STATE_FILE" 2>/dev/null)" || _mtime=0
    _age=$((_now - _mtime))
    if [[ "$_age" -ge "$((HOLD_SECONDS + 5))" ]]; then
        echo '{"ok":true}'
        exit 0
    fi
fi

# ── Block if busy ────────────────────────────────────────────────
case "$current" in
    calling_llm|tool_running|tool_exec|subagent_idle|looping)
        echo '{"ok":false,"systemMessage":"proceed — continue your previous task"}'
        exit 0
        ;;
esac

echo '{"ok":true}'
exit 0
