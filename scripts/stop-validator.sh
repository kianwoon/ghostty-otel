#!/usr/bin/env bash
# stop-validator.sh — Command hook for Stop event
# Reads transcript, decides allow/block. Writes "done" on allow.
# Input: JSON on stdin. Output: {"ok":true} or {"ok":false,"systemMessage":"..."}
set -uo pipefail  # no -e — we handle errors explicitly

INPUT="$(cat)" || INPUT=""

# ── Session key derivation (session_id → SID file lookup) ──────────
# Stop hooks are detached subprocesses — /dev/tty NOT available.
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
SESSION_KEY="${GHOSTTY_OTEL_SESSION_KEY:-}"
if [[ -z "$SESSION_KEY" ]]; then
    _sid="${INPUT#*\"session_id\":\"}"
    [[ "$_sid" != "$INPUT" ]] && _sid="${_sid%%\"*}" || _sid=""
    if [[ -n "$_sid" ]]; then
        _sf="${STATE_DIR}/ghostty-sid-${_sid}" 2>/dev/null
        # Try direct reverse-lookup file first
        if [[ ! -f "$_sf" ]]; then
            # Fall back to scanning SID files
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
fi

# ── Helpers ────────────────────────────────────────────────────────
# Write state and allow stop
allow_stop() {
    if [[ -n "$SESSION_KEY" ]]; then
        _st="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"
        printf '%s' "done" > "$_st" 2>/dev/null || true
    fi
    echo '{"ok":true}'
    exit 0
}

# Block stop — write working state so indicator stays active
block_stop() {
    if [[ -n "$SESSION_KEY" ]]; then
        _st="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"
        printf '%s' "working" > "$_st" 2>/dev/null || true
    fi
    echo "{\"ok\":false,\"systemMessage\":\"$1\"}"
    exit 0
}

# ── Gate 0: stop_hook_active → allow ──────────────────────────────
if [[ "$INPUT" == *'"stop_hook_active":true'* ]]; then
    allow_stop
fi

# ── Gate 0b: Ralph Loop active → allow ────────────────────────────
RALPH_STATE_FILE=".claude/ralph-loop.local.md"
if [[ -f "$RALPH_STATE_FILE" ]]; then
    if grep -q '^active:.*true' "$RALPH_STATE_FILE" 2>/dev/null; then
        allow_stop
    fi
fi

TRANSCRIPT_PATH="${TRANSCRIPT_PATH:-}"

# ── Gate 1: No transcript → allow ────────────────────────────────
if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
    allow_stop
fi

# ── Transcript analysis (single jq pass) ─────────────────────────
# Parse all metrics in ONE invocation to avoid re-reading large files.
HAS_REAL_TOOLS=0
HAS_ERRORS=0
HAS_INCOMPLETE=0
TASK_BLOCK_REASON=""

if command -v jq >/dev/null 2>&1; then
    _result=$(jq -r '
        # Count real tool calls
        (reduce (inputs | select(.tool != null and (.tool | IN("Write","Edit","Bash","Read","Glob","Grep","Agent","Task","Skill","WebSearch","LSP","NotebookEdit")))) as $_ (0; . + 1)) as $tools |
        # Count errors
        (reduce (inputs | select(.toolError != null)) as $_ (0; . + 1)) as $errors |
        # Check incomplete
        (if [inputs | select(.partialOutput == true or .incomplete == true or .interrupted == true)] | length > 0 then 1 else 0 end) as $inc |
        # Check incomplete tasks
        (reduce (inputs | select(.tool == "TaskCreate" or .tool == "TaskUpdate") | .input // .content // "" | select(test("pending|in_progress"))) as $_ (0; . + 1)) as $inc_tasks |
        "\($tools)\($errors)\($inc)\($inc_tasks)"
    ' "$TRANSCRIPT_PATH" 2>/dev/null) || _result="0000"

    _tools="${_result:0:1}"
    _errors="${_result:1:1}"
    _incomplete="${_result:2:1}"
    _inc_tasks="${_result:3:1}"

    [[ "$_tools" -gt 0 ]] 2>/dev/null && HAS_REAL_TOOLS=1
    [[ "$_errors" -gt 0 ]] 2>/dev/null && HAS_ERRORS=1
    [[ "$_incomplete" -gt 0 ]] 2>/dev/null && HAS_INCOMPLETE=1
    [[ "$_inc_tasks" -gt 0 ]] 2>/dev/null && TASK_BLOCK_REASON="${_inc_tasks} incomplete tasks detected — continue working"
else
    # Fallback: grep (single pass)
    if grep -qE '"tool":"(Write|Edit|Bash|Read|Glob|Grep|Agent|Task|Skill|WebSearch|LSP|NotebookEdit)"' "$TRANSCRIPT_PATH" 2>/dev/null; then
        HAS_REAL_TOOLS=1
    fi
    if grep -q '"toolError"' "$TRANSCRIPT_PATH" 2>/dev/null; then
        HAS_ERRORS=1
    fi
fi

# ── Task completion check ────────────────────────────────────────
if [[ -n "$TASK_BLOCK_REASON" ]]; then
    block_stop "$TASK_BLOCK_REASON"
fi

# ── Decision logic ────────────────────────────────────────────────
if [[ "$HAS_REAL_TOOLS" -eq 0 ]]; then
    block_stop "Agent stopped without executing any real tools — continuing task"
fi

if [[ "$HAS_ERRORS" -gt 0 ]] && [[ "$HAS_INCOMPLETE" -gt 0 ]]; then
    block_stop "Tool errors detected and execution incomplete — continuing to resolve"
fi

# ── Default: allow ───────────────────────────────────────────────
allow_stop
