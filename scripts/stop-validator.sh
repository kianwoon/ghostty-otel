#!/usr/bin/env bash
# Stop validator - command hook replacement for prompt-based Stop hook
# Reads transcript from $TRANSCRIPT_PATH and outputs {"ok":true/false}
# Input: JSON on stdin with optional stop_hook_active flag

set -euo pipefail

# Read hook input (JSON)
INPUT="$(cat)"

# Check for stop_hook_active guard
if echo "$INPUT" | command jq -e '.stop_hook_active == true' >/dev/null 2>&1; then
    echo '{"ok":true}'
    exit 0
fi

# Check if Ralph Loop is active — skip blocking to avoid conflicts
# Ralph has its own Stop hook that manages iteration boundaries
RALPH_STATE_FILE=".claude/ralph-loop.local.md"
if [[ -f "$RALPH_STATE_FILE" ]]; then
    _ralph_active=$(grep '^active:' "$RALPH_STATE_FILE" | sed 's/active: *//' | tr -d ' ')
    if [[ "$_ralph_active" == "true" ]]; then
        echo '{"ok":true}'
        exit 0
    fi
fi

TRANSCRIPT_PATH="${TRANSCRIPT_PATH:-}"

# Exit with allow if no transcript (safer default)
if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
    echo '{"ok":true}'
    exit 0
fi

# Check transcript for real tool usage (Write, Edit, Bash, Read, etc)
# Exclude: LLM-only calls (no tools), thinking, internal operations
HAS_REAL_TOOLS=0
HAS_ERRORS=0
INCOMPLETE=0

# Use jq to parse JSONL transcript and check for tool calls
if command -v jq >/dev/null 2>&1; then
    # Count tool executions (excluding internal operations)
    TOOL_COUNT=$(jq -r '
        select(.tool != null) |
        select(.tool | IN("Write", "Edit", "Bash", "Read", "Glob", "Grep", "Agent", "Task", "Skill", "WebSearch", "mcp__", "LSP", "NotebookEdit")) |
        .tool
    ' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    # Check for tool failures
    ERROR_COUNT=$(jq -r '
        select(.toolError != null) |
        .toolError
    ' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    # Check for incomplete executions (partial outputs, interrupted operations)
    INCOMPLETE_MARKER=$(jq -r '
        select(.partialOutput == true or .incomplete == true or .interrupted == true) |
        "found"
    ' "$TRANSCRIPT_PATH" 2>/dev/null | head -1 || echo "")

    if [[ "$TOOL_COUNT" -gt 0 ]]; then
        HAS_REAL_TOOLS=1
    fi
    if [[ "$ERROR_COUNT" -gt 0 ]]; then
        HAS_ERRORS=1
    fi
    if [[ -n "$INCOMPLETE_MARKER" ]]; then
        INCOMPLETE=1
    fi
else
    # Fallback: grep for tool usage if jq not available
    if grep -q '"tool":"\("Write"\|"Edit"\|"Bash"\|"Read"\|"Glob"\|"Grep"\|"Agent"\|"Task"\|"Skill"\|"WebSearch"\|"mcp__"\|"LSP"\|"NotebookEdit"\)' "$TRANSCRIPT_PATH" 2>/dev/null; then
        HAS_REAL_TOOLS=1
    fi
    if grep -q '"toolError"' "$TRANSCRIPT_PATH" 2>/dev/null; then
        HAS_ERRORS=1
    fi
fi

# --- Task completion check ---
# Look for task list patterns and block stop if incomplete tasks exist
if command -v jq >/dev/null 2>&1; then
    # Pattern 1: "N tasks (X done, Y in_progress|active, Z open)" — capture in_progress count
    LAST_TASK_SUMMARY=$(jq -r '
        select(.content != null) |
        .content |
        capture("\\d+\\s+tasks?\\s*\\((\\d+)\\s+done,?\\s*(\\d+)\\s+(?:in\\s+progress|active|in_progress|pending),?\\s*(\\d+)\\s+open\\)"; "g") |
        "\(.done)/\(.remaining)/\(.open)"
    ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1 || echo "")

    # Pattern 2: "X/Y tasks complete|done" — fraction format
    FRACTION_SUMMARY=$(jq -r '
        select(.content != null) |
        .content |
        capture("(\\d+)/(\\d+)\\s+tasks?\\s+(?:complete|done|finished)"; "g") |
        "\(.done)/\(.total)"
    ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1 || echo "")

    # Check TaskCreate/TaskUpdate for pending or in_progress tasks
    INCOMPLETE_TASKS=$(jq -r '
        select(.tool == "TaskCreate" or .tool == "TaskUpdate") |
        .input // .content // ""
    ' "$TRANSCRIPT_PATH" 2>/dev/null | grep -cE '"status":"(pending|in_progress)"' 2>/dev/null || echo "0")

    if [[ -n "$LAST_TASK_SUMMARY" ]]; then
        REMAINING=$(echo "$LAST_TASK_SUMMARY" | cut -d'/' -f2 | tr -d ' ')
        OPEN_TASKS=$(echo "$LAST_TASK_SUMMARY" | cut -d'/' -f3 | tr -d ' ')
        TOTAL_INCOMPLETE=$((REMAINING + OPEN_TASKS))
        if [[ "$TOTAL_INCOMPLETE" -gt 0 ]] 2>/dev/null; then
            echo "{\"ok\":false,\"systemMessage\":\"${TOTAL_INCOMPLETE} tasks still incomplete (in progress or open) — continue working\"}"
            exit 0
        fi
    fi

    if [[ -n "$FRACTION_SUMMARY" ]]; then
        DONE=$(echo "$FRACTION_SUMMARY" | cut -d'/' -f1 | tr -d ' ')
        TOTAL=$(echo "$FRACTION_SUMMARY" | cut -d'/' -f2 | tr -d ' ')
        if [[ "$DONE" -lt "$TOTAL" ]] 2>/dev/null; then
            echo "{\"ok\":false,\"systemMessage\":\"${DONE}/${TOTAL} tasks done — continue working on remaining tasks\"}"
            exit 0
        fi
    fi

    if [[ "$INCOMPLETE_TASKS" -gt 0 ]] 2>/dev/null; then
        echo "{\"ok\":false,\"systemMessage\":\"${INCOMPLETE_TASKS} incomplete tasks detected (pending or in_progress) — continue working\"}"
        exit 0
    fi
fi

# --- Decision logic ---
if [[ "$HAS_REAL_TOOLS" -eq 0 ]]; then
    # No real tools executed - likely premature stop
    echo '{"ok":false,"systemMessage":"Agent stopped without executing any real tools — continuing task"}'
    exit 0
fi

if [[ "$HAS_ERRORS" -gt 0 ]] && [[ "$INCOMPLETE" -gt 0 ]]; then
    # Errors and incomplete - agent likely gave up
    echo '{"ok":false,"systemMessage":"Tool errors detected and execution incomplete — continuing to resolve"}'
    exit 0
fi

# Otherwise, allow stop — signal completion to watcher
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
SESSION_KEY="${GHOSTTY_OTEL_SESSION_KEY:-}"

# Derive session key if not provided (Stop hooks don't have it in env)
if [[ -z "$SESSION_KEY" ]]; then
    PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    SESSION_KEY="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh" | sed -n '2p')"
fi

DEBUG_LOG="/tmp/ghostty-stop-debug.log"
echo "[$(date '+%H:%M:%S')] stop-validator: SESSION_KEY=$SESSION_KEY PLUGIN_ROOT=${PLUGIN_ROOT:-unset} TRANSCRIPT_PATH=${TRANSCRIPT_PATH:-unset}" >> "$DEBUG_LOG"

if [[ -n "$SESSION_KEY" ]]; then
    _state_file="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"
    echo "done" > "$_state_file" 2>/dev/null
    _rc=$?
    echo "[$(date '+%H:%M:%S')] wrote done to $_state_file (rc=$_rc)" >> "$DEBUG_LOG"
else
    echo "[$(date '+%H:%M:%S')] ERROR: no SESSION_KEY derived" >> "$DEBUG_LOG"
fi
echo '{"ok":true}'
