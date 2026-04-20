#!/usr/bin/env bash
# Shared proceed-by-state logic for SubagentStop/TeammateIdle/StopFailure hooks
# Detects stale idle (agent went idle mid-task) and auto-proceeds via structured JSON output.
set -u

# Read stdin for stop_hook_active guard (infinite-loop prevention)
INPUT="$(cat)"

# Guard against infinite loops — if stop_hook_active is true, allow the stop
if echo "$INPUT" | command jq -e '.stop_hook_active == true' >/dev/null 2>&1; then
    echo '{"ok":true}'
    exit 0
fi

_raw_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "${_raw_root}/scripts/resolve-cache.sh"
PLUGIN_ROOT=$(resolve_plugin_root)
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
HOLD_SECONDS="${GHOSTTY_OTEL_HOLD_SECONDS:-60}"

SESSION_INFO="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh")"
SESSION_KEY="$(echo "$SESSION_INFO" | sed -n '2p')"

# Fail-closed: if session-key.sh fails, block to prevent mid-task stop
# The stop_hook_active guard above prevents infinite loops from this case
if [ -z "$SESSION_KEY" ]; then
    echo '{"ok":false,"systemMessage":"proceed — session resolution failed, assuming busy"}'
    exit 0
fi

STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"

current=""
if [ -f "$STATE_FILE" ]; then
    current=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\n' | cut -d: -f1)
fi

# Staleness check: if state file hasn't been updated in > HOLD_SECONDS+5,
# the state is likely stale (HoldTimer expired but listener didn't write idle)
# Allow the stop in this case to prevent false-positive proceeds
if [ -n "$current" ] && [ "$current" != "idle" ]; then
    STATE_MTIME=$(stat -f '%m' "$STATE_FILE" 2>/dev/null || stat -c '%Y' "$STATE_FILE" 2>/dev/null || echo "0")
    CURRENT_TIME=$(date +%s)
    STATE_AGE=$((CURRENT_TIME - STATE_MTIME))
    if [ "$STATE_AGE" -ge "$((HOLD_SECONDS + 5))" ]; then
        echo '{"ok":true}'
        exit 0
    fi
fi

case "$current" in
  calling_llm|tool_running|tool_exec|subagent_idle|looping)
    # Agent stopped while still busy, or already detected as stale
    echo '{"ok":false,"systemMessage":"proceed — continue your previous task"}'
    exit 0
    ;;
esac

echo '{"ok":true}'
exit 0
