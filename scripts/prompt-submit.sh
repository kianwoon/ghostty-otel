#!/usr/bin/env bash
# Fires on UserPromptSubmit — emit indicator ON + health check listener.
# This hook runs in the correct TTY context, so OSC reaches the terminal.
# Performance budget: <50ms (OSC emit + PID check).
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"

# --- Session key + TTY path derivation (single source of truth) ---
_SESSION_INFO="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh")"
TTY_PATH="$(echo "$_SESSION_INFO" | sed -n '1p')"
SESSION_KEY="$(echo "$_SESSION_INFO" | sed -n '2p')"

PID_FILE="${STATE_DIR}/ghostty-otel-${SESSION_KEY}.pid"

# --- OSC 9;4 emit (tmux-aware) ---
# Uses /dev/tty directly since hook has controlling terminal
emit() {
  local seq="$1"
  if [ -n "${TMUX:-}" ]; then
    local escaped="${seq//$'\033'/$'\033\033'}"
    printf '\033Ptmux;\033%s\033\\' "$escaped" > /dev/tty 2>/dev/null || true
  else
    printf '%b' "$seq" > /dev/tty 2>/dev/null || true
  fi
}

# 1. Emit indicator ON immediately
emit '\033]9;4;3\033\\'
emit '\033]2;claude: calling_llm\033\\'

# 2. Write state file (watchers/hooks can read this)
echo "calling_llm" > "${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt" 2>/dev/null || true

# 3. Check listener health — restart if dead (<2ms when alive)
if [ -f "$PID_FILE" ]; then
  _pid=$(cat "$PID_FILE" 2>/dev/null) || true
  if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
    : # listener alive
  else
    # Listener dead — restart in background (nohup to survive hook exit)
    nohup bash "${PLUGIN_ROOT}/scripts/start-listener.sh" > /dev/null 2>&1 &
  fi
else
  # No PID file — start listener
  nohup bash "${PLUGIN_ROOT}/scripts/start-listener.sh" > /dev/null 2>&1 &
fi

# 4. Ensure watcher is running (with lock to prevent duplicates)
WATCHER_PID_FILE="${STATE_DIR}/ghostty-watcher-${SESSION_KEY}.pid"
WATCHER_LOCK="${STATE_DIR}/ghostty-watcher-${SESSION_KEY}.lock"

_start_watcher() {
  GHOSTTY_OTEL_TTY="$TTY_PATH" \
  GHOSTTY_OTEL_SESSION_KEY="$SESSION_KEY" \
  nohup bash "${PLUGIN_ROOT}/scripts/otel-watcher.sh" > /dev/null 2>&1 &
}

if mkdir "$WATCHER_LOCK" 2>/dev/null; then
  if [ -f "$WATCHER_PID_FILE" ]; then
    _wpid=$(cat "$WATCHER_PID_FILE" 2>/dev/null) || true
    if [ -n "$_wpid" ] && kill -0 "$_wpid" 2>/dev/null; then
      rmdir "$WATCHER_LOCK" 2>/dev/null || true
    else
      _start_watcher
      rmdir "$WATCHER_LOCK" 2>/dev/null || true
    fi
  else
    _start_watcher
    rmdir "$WATCHER_LOCK" 2>/dev/null || true
  fi
else
  : # Another hook is already starting the watcher
fi

exit 0
