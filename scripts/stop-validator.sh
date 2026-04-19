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
# Look for task list patterns: "N tasks (X done, Y open)" or similar
# If incomplete tasks exist, block stop
if command -v jq >/dev/null 2>&1; then
    # Extract last task summary from transcript
    LAST_TASK_SUMMARY=$(jq -r '
        select(.content != null) |
        .content |
        capture("\\d+\\s+tasks?\\s*\\((\\d+)\\s+done,?\\s*(\\d+)\\s+open\\)"; "g") |
        "\(.done)/\(.open)"
    ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1 || echo "")

    # Also check for TodoWrite patterns with pending tasks
    PENDING_TASKS=$(jq -r '
        select(.tool == "TaskCreate" or .tool == "TaskUpdate") |
        .input // .content // ""
    ' "$TRANSCRIPT_PATH" 2>/dev/null | grep -c '"status":"pending"' 2>/dev/null || echo "0")

    if [[ -n "$LAST_TASK_SUMMARY" ]]; then
        OPEN_TASKS=$(echo "$LAST_TASK_SUMMARY" | cut -d'/' -f2 | tr -d ' ')
        if [[ "$OPEN_TASKS" -gt 0 ]] 2>/dev/null; then
            echo "{\"ok\":false,\"systemMessage\":\"${OPEN_TASKS} tasks still open — continue working on pending tasks\"}"
            exit 0
        fi
    fi

    if [[ "$PENDING_TASKS" -gt 0 ]] 2>/dev/null; then
        echo "{\"ok\":false,\"systemMessage\":\"${PENDING_TASKS} pending tasks detected — continue working\"}"
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

if [[ -n "$SESSION_KEY" ]]; then
    _state_file="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"
    echo "done" > "$_state_file" 2>/dev/null || true
fi
echo '{"ok":true}'
