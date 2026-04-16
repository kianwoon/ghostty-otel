#!/usr/bin/env bash
# Fires on UserPromptSubmit — restart heartbeat immediately.
# Ensures indicator turns ON before Claude starts processing.
# Performance budget: <50ms (file I/O only).
set -u

# --- Session key derivation (same as start-listener.sh) ---
_tty=$(tty 2>/dev/null) || true
if [ -z "$_tty" ] || [ "$_tty" = "not a tty" ]; then
  _tty_ps=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ') || true
  if [ -n "$_tty_ps" ] && [ "$_tty_ps" != "??" ]; then
    SESSION_KEY="$(echo "$_tty_ps" | tr '/' '_' | tr -cd 'a-zA-Z0-9_-')"
  else
    SESSION_KEY="tty"
  fi
else
  SESSION_KEY="$(basename "$_tty" | tr '/' '_' | tr -cd 'a-zA-Z0-9_-')"
fi

STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
LLM_ACTIVE="${STATE_DIR}/ghostty-llm-active-${SESSION_KEY}"
ACTIVE_UNTIL="${STATE_DIR}/ghostty-active-until-${SESSION_KEY}"
STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}"
HEARTBEAT_PID="${STATE_DIR}/ghostty-heartbeat-${SESSION_KEY}.pid"

# 1. Signal LLM active immediately (heartbeat polls this)
touch "$LLM_ACTIVE"

# 2. Extend active window by 30s (covers time until first OTEL span arrives)
_now=$(date +%s)
echo $((_now + 30)) > "$ACTIVE_UNTIL"

# 3. Touch state file to update mtime (heartbeat activity signal)
touch "$STATE_FILE" 2>/dev/null || true

# 4. Start heartbeat if not running
if [ -f "$HEARTBEAT_PID" ]; then
  _pid=$(cat "$HEARTBEAT_PID" 2>/dev/null) || true
  if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
    # Heartbeat alive — activity signals already set, nothing more to do
    exit 0
  fi
fi

# Heartbeat not running — start it via ghostty-state.sh
if [ -x "${HOME}/.claude/hooks/ghostty-state.sh" ]; then
  "${HOME}/.claude/hooks/ghostty-state.sh" working
fi

exit 0
