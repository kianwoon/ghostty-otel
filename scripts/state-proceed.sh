#!/usr/bin/env bash
# State-based auto-proceed: polls state file and forces proceed when stuck
# Runs every 10s, faster than waiting for Stop/SubagentStop events
set -u

SESSION_KEY="${GHOSTTY_OTEL_SESSION_KEY:-}"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"
IDLE_THRESHOLD_SECONDS=60
WAITING_THRESHOLD_SECONDS=90

# Read current state and timestamp
CURRENT_STATE=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\n') || echo "idle"
STATE_MTIME=$(stat -f '%m' "$STATE_FILE" 2>/dev/null || stat -c '%Y' "$STATE_FILE" 2>/dev/null || echo "0")
CURRENT_TIME=$(date +%s)
STATE_AGE_SECONDS=$((CURRENT_TIME - STATE_MTIME))

# Check if stuck in a non-working state
SHOULD_PROCEED=false
if [ "$CURRENT_STATE" = "subagent_idle" ] && [ "$STATE_AGE_SECONDS" -ge "$IDLE_THRESHOLD_SECONDS" ]; then
  SHOULD_PROCEED=true
  REASON="subagent_idle for ${STATE_AGE_SECONDS}s (threshold: ${IDLE_THRESHOLD_SECONDS}s)"
elif [ "$CURRENT_STATE" = "waiting_input" ] && [ "$STATE_AGE_SECONDS" -ge "$WAITING_THRESHOLD_SECONDS" ]; then
  SHOULD_PROCEED=true
  REASON="waiting_input for ${STATE_AGE_SECONDS}s (threshold: ${WAITING_THRESHOLD_SECONDS}s)"
fi

if [ "$SHOULD_PROCEED" = true ]; then
  # Output proceed message
  printf '{"ok":false,"systemMessage":"proceed — %s"}' "$REASON"
  exit 0
fi

# No action needed
printf '{"ok":true,"systemMessage":"state ok"}'
exit 0
