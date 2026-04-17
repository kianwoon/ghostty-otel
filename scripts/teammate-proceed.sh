#!/usr/bin/env bash
# TeammateIdle hook: detects stale idle (teammate went idle mid-task)
# and auto-proceeds by exiting code 2 with a continue message.
# Input: JSON on stdin with last_assistant_message, agent_id, agent_type
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"

SESSION_INFO="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh")"
SESSION_KEY="$(echo "$SESSION_INFO" | sed -n '2p')"

STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"

current=""
if [ -f "$STATE_FILE" ]; then
  current=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\n' | cut -d: -f1)
fi

case "$current" in
  calling_llm|tool_running|tool_exec|subagent_idle)
    # Teammate stopped while still busy, or already detected as stale
    echo '{"decision":"block","reason":"proceed — continue your previous task"}'
    exit 0
    ;;
esac
exit 0
