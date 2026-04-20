#!/usr/bin/env bash
# Anti-stall hook: detects "planning without executing" pattern
# Fires on SubagentStop and TeammateIdle — checks if agent produced tool output
# If agent only planned but didn't execute, forces continuation
set -u

# Read stdin for stop_hook_active guard (infinite-loop prevention)
INPUT="$(cat)"

if echo "$INPUT" | command jq -e '.stop_hook_active == true' >/dev/null 2>&1; then
    echo '{"ok":true}'
    exit 0
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"

SESSION_INFO="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh")"
SESSION_KEY="$(echo "$SESSION_INFO" | sed -n '2p')"

STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"
TRANSCRIPT_PATH="${TRANSCRIPT_PATH:-}"

# Read current state
CURRENT_STATE=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\n') || echo "idle"

# If state is already working, no action needed
case "$CURRENT_STATE" in
  calling_llm*|tool_running*|tool_exec*) echo '{"ok":true}'; exit 0 ;;
esac

# Check transcript for planning-without-executing pattern
if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]] && command -v jq >/dev/null 2>&1; then
    # Count real tool calls vs planning/summary messages
    TOOL_CALLS=$(jq -r '
        select(.tool != null) |
        select(.tool | IN("Write", "Edit", "Bash", "Agent", "Task")) |
        .tool
    ' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    # Check for task planning without execution
    TASK_CREATES=$(jq -r '
        select(.tool == "TaskCreate") |
        .tool
    ' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    # If tasks were created but no real tools executed, it's planning-without-executing
    if [[ "$TASK_CREATES" -gt 0 ]] && [[ "$TOOL_CALLS" -eq 0 ]]; then
        echo '{"ok":false,"systemMessage":"Tasks were planned but no implementation tools were executed — start implementing now"}'
        exit 0
    fi

    # If no tool calls at all, force continue
    if [[ "$TOOL_CALLS" -eq 0 ]]; then
        echo '{"ok":false,"systemMessage":"No real tool calls detected — continue working on your assigned task"}'
        exit 0
    fi
fi

echo '{"ok":true}'
