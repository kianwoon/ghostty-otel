#!/usr/bin/env bash
# SubagentStop hook: detects stale idle (subagent went idle mid-task)
# and auto-proceeds by exiting code 2 with a continue message.
# Input: JSON on stdin with last_assistant_message, agent_id, agent_type
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"

SESSION_INFO="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh")"
SESSION_KEY="$(echo "$SESSION_INFO" | sed -n '2p')"

STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"

# Check if current state is subagent_idle
current=""
if [ -f "$STATE_FILE" ]; then
  current=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\n' | cut -d: -f1)
fi

if [ "$current" = "subagent_idle" ]; then
  echo "proceed — continue your previous task" >&2
  exit 2
fi

exit 0
