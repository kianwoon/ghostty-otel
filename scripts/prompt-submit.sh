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

# --- Create SID mapping file (session.id → session_key) ---
# The OTEL listener needs this mapping to route spans to the correct session.
# Claude Code sends JSON on stdin with session_id and transcript_path.
# Primary: parse session_id from stdin JSON.
# Fallback 1: derive from transcript_path in stdin JSON.
# Fallback 2: read from transcript-path file (external ghostty-state.sh).
_stdin_json="$(cat 2>/dev/null)" || true
_session_id=""
if [ -n "$_stdin_json" ]; then
  _session_id="$(echo "$_stdin_json" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)" || true
fi
if [ -z "$_session_id" ]; then
  _tp="$(echo "$_stdin_json" | grep -o '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4)" || true
  if [ -n "$_tp" ]; then
    _session_id="$(basename "$_tp" .jsonl 2>/dev/null)" || true
  fi
fi
if [ -z "$_session_id" ]; then
  TRANSCRIPT_PATH_FILE="${STATE_DIR}/ghostty-transcript-path-${SESSION_KEY}"
  if [ -f "$TRANSCRIPT_PATH_FILE" ]; then
    _transcript_path="$(cat "$TRANSCRIPT_PATH_FILE" 2>/dev/null)" || true
    if [ -n "$_transcript_path" ]; then
      _session_id="$(basename "$_transcript_path" .jsonl 2>/dev/null)" || true
    fi
  fi
fi
if [ -n "$_session_id" ]; then
  echo "$_session_id" > "${STATE_DIR}/ghostty-sid-${SESSION_KEY}" 2>/dev/null || true
fi

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

# 1. Emit indicator ON immediately (gap coverage before first OTEL span)
#    Do NOT write state file — the listener owns it exclusively.
emit '\033]9;4;3\033\\'
emit '\033]2;claude: calling_llm\033\\'

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
