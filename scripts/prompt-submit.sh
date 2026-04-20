#!/usr/bin/env bash
# Fires on UserPromptSubmit — emit indicator ON + health check listener.
# This hook runs in the correct TTY context, so OSC reaches the terminal.
# Performance budget: <10ms (OSC emit + PID check).
set -u

_raw_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "${_raw_root}/scripts/resolve-cache.sh"
PLUGIN_ROOT=$(resolve_plugin_root)
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"

# --- Inline session key derivation (no subshell, no sed) ---
# Hook runs in correct TTY context — readlink /dev/tty is the fast path.
TTY_PATH=$(readlink /dev/tty 2>/dev/null) || TTY_PATH=$(stat -f "%Y" /dev/tty 2>/dev/null) || TTY_PATH="/dev/tty"
SESSION_KEY=$(basename "$TTY_PATH" | tr '/' '_' | tr -cd 'a-zA-Z0-9_-')

PID_FILE="${STATE_DIR}/ghostty-otel-${SESSION_KEY}.pid"

# --- Create SID mapping file (session.id → session_key) ---
_stdin_json="$(cat 2>/dev/null)" || true
_session_id=""
if [ -n "$_stdin_json" ]; then
  # Bash parameter expansion — no grep/cut forks
  _match="${_stdin_json#*\"session_id\":\"}"
  if [ "$_match" != "$_stdin_json" ]; then
    _session_id="${_match%%\"*}"
  fi
  if [ -z "$_session_id" ]; then
    _tp="${_stdin_json#*\"transcript_path\":\"}"
    if [ "$_tp" != "$_stdin_json" ]; then
      _tp="${_tp%%\"*}"
      _session_id="${_tp##*/}"
      _session_id="${_session_id%.jsonl}"
    fi
  fi
fi
if [ -z "$_session_id" ]; then
  TRANSCRIPT_PATH_FILE="${STATE_DIR}/ghostty-transcript-path-${SESSION_KEY}"
  if [ -f "$TRANSCRIPT_PATH_FILE" ]; then
    _transcript_path="$(cat "$TRANSCRIPT_PATH_FILE" 2>/dev/null)" || true
    if [ -n "$_transcript_path" ]; then
      _session_id="${_transcript_path##*/}"
      _session_id="${_session_id%.jsonl}"
    fi
  fi
fi
if [ -n "$_session_id" ]; then
  echo "$_session_id" > "${STATE_DIR}/ghostty-sid-${SESSION_KEY}" 2>/dev/null || true
fi

# --- OSC 9;4 emit (tmux-aware) ---
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
STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"
_tmpf="${STATE_FILE}.tmp.$$"
printf 'calling_llm' > "$_tmpf" && mv "$_tmpf" "$STATE_FILE" 2>/dev/null || true

# 3. Check listener health — restart if dead
if [ -f "$PID_FILE" ]; then
  _pid=$(cat "$PID_FILE" 2>/dev/null) || true
  if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
    : # listener alive
  else
    nohup bash "${PLUGIN_ROOT}/scripts/start-listener.sh" > /dev/null 2>&1 &
  fi
else
  nohup bash "${PLUGIN_ROOT}/scripts/start-listener.sh" > /dev/null 2>&1 &
fi

# 4. Ensure watcher is running (PID-based check, no lock dir)
WATCHER_PID_FILE="${STATE_DIR}/ghostty-watcher-${SESSION_KEY}.pid"
_wpid=$(cat "$WATCHER_PID_FILE" 2>/dev/null) || true
if [ -z "$_wpid" ] || ! kill -0 "$_wpid" 2>/dev/null; then
  GHOSTTY_OTEL_TTY="$TTY_PATH" GHOSTTY_OTEL_SESSION_KEY="$SESSION_KEY" \
    nohup bash "${PLUGIN_ROOT}/scripts/otel-watcher.sh" > /dev/null 2>&1 &
fi

exit 0
