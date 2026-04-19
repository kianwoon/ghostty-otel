#!/usr/bin/env bash
# StopFailure hook: detects stale idle (main agent went idle mid-task)
# and auto-proceeds via structured JSON decision output.
# Input: JSON on stdin with session_id, reason, transcript_path, cwd
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"

SESSION_INFO="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh")"
SESSION_KEY="$(echo "$SESSION_INFO" | sed -n '2p')"

# Fail-closed: if session-key.sh fails, block to prevent mid-task stop
if [ -z "$SESSION_KEY" ]; then
  echo '{"decision":"block","reason":"proceed — session resolution failed, assuming busy"}'
  exit 0
fi

STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"

current=""
if [ -f "$STATE_FILE" ]; then
  current=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\n' | cut -d: -f1)
fi

case "$current" in
  calling_llm|tool_running|tool_exec|subagent_idle|looping|waiting_input)
    # Main agent stopped while still busy, or already detected as stale
    echo '{"decision":"block","reason":"proceed — continue your previous task"}'
    exit 0
    ;;
esac
exit 0