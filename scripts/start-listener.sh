#!/usr/bin/env bash
# Start the OTEL listener daemon for ghostty-otel plugin.
# Called from SessionStart + prompt-submit.sh health check.
# Safe to call multiple times — idempotent.
set -u

_raw_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "${_raw_root}/scripts/resolve-cache.sh"
PLUGIN_ROOT=$(resolve_plugin_root)
PORT="${GHOSTTY_OTEL_PORT:-4318}"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
LOG_FILE="${GHOSTTY_OTEL_LOG:-/tmp/ghostty-otel.log}"

# --- Sync + restart on SessionStart ---
SYNC_SCRIPT="${PLUGIN_ROOT}/scripts/sync-and-restart.sh"
if [ -f "$SYNC_SCRIPT" ]; then
  bash "$SYNC_SCRIPT" >/dev/null 2>&1 || true
fi

# --- Inject OTEL env vars into session (required for fresh installs) ---
# Plugin .claude/settings.json env block is NOT applied automatically.
# $CLAUDE_ENV_FILE is the supported mechanism for env injection.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  cat >> "$CLAUDE_ENV_FILE" <<'ENVEOF'
CLAUDE_CODE_ENABLE_TELEMETRY=1
CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/json
OTEL_TRACES_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_SERVICE_NAME=claude-code
ENVEOF
fi

# --- Session key + TTY path derivation (single source of truth) ---
# Prefer env vars (passed by watcher auto-recovery) over session-key.sh
if [ -n "${GHOSTTY_OTEL_SESSION_KEY:-}" ] && [ -n "${GHOSTTY_OTEL_TTY:-}" ]; then
  TTY_PATH="$GHOSTTY_OTEL_TTY"
  SESSION_KEY="$GHOSTTY_OTEL_SESSION_KEY"
else
  _SESSION_INFO="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh")"
  TTY_PATH="$(echo "$_SESSION_INFO" | sed -n '1p')"
  SESSION_KEY="$(echo "$_SESSION_INFO" | sed -n '2p')"
fi

# --- SID mapping + transcript path at session start ---
_stdin_json="$(cat 2>/dev/null)" || true
_session_id="${CLAUDE_SESSION_ID:-}"
_transcript_path=""

if [[ -n "$_stdin_json" ]]; then
  # Extract transcript_path from SessionStart stdin
  _tp="${_stdin_json#*\"transcript_path\":\"}"
  if [[ "$_tp" != "$_stdin_json" ]]; then
    _transcript_path="${_tp%%\"*}"
    if [[ -z "$_session_id" ]]; then
      _session_id="${_transcript_path##*/}"
      _session_id="${_session_id%.jsonl}"
    fi
  fi
  # Extract session_id from stdin if not in env
  if [[ -z "$_session_id" ]]; then
    _match="${_stdin_json#*\"session_id\":\"}"
    if [[ "$_match" != "$_stdin_json" ]]; then
      _session_id="${_match%%\"*}"
    fi
  fi
fi

if [[ -n "$_session_id" ]] && [[ -n "$SESSION_KEY" ]]; then
  printf '%s' "$_session_id" > "${STATE_DIR}/ghostty-sid-${SESSION_KEY}" 2>/dev/null || true
fi
if [[ -n "$_transcript_path" ]] && [[ -n "$SESSION_KEY" ]]; then
  printf '%s' "$_transcript_path" > "${STATE_DIR}/ghostty-transcript-path-${SESSION_KEY}" 2>/dev/null || true
fi

# Listener is a singleton — use global PID file (not per-session)
GLOBAL_PID_FILE="${STATE_DIR}/ghostty-otel.pid"

# --- Helper: ensure watcher is running (with lock) ---
ensure_watcher() {
  local WATCHER_PID_FILE="${STATE_DIR}/ghostty-watcher-${SESSION_KEY}.pid"
  local WATCHER_LOCK="${STATE_DIR}/ghostty-watcher-${SESSION_KEY}.lock"

  if [ -f "$WATCHER_PID_FILE" ]; then
    local _wpid=$(cat "$WATCHER_PID_FILE" 2>/dev/null) || true
    if [ -n "$_wpid" ] && kill -0 "$_wpid" 2>/dev/null; then
      return  # watcher alive
    fi
  fi

  # Use mkdir as atomic lock to prevent duplicate watchers
  if ! mkdir "$WATCHER_LOCK" 2>/dev/null; then
    return  # Another process is already starting the watcher
  fi

  # Double-check after acquiring lock
  if [ -f "$WATCHER_PID_FILE" ]; then
    local _wpid2=$(cat "$WATCHER_PID_FILE" 2>/dev/null) || true
    if [ -n "$_wpid2" ] && kill -0 "$_wpid2" 2>/dev/null; then
      rmdir "$WATCHER_LOCK" 2>/dev/null || true
      return
    fi
  fi

  GHOSTTY_OTEL_TTY="$TTY_PATH" \
  GHOSTTY_OTEL_SESSION_KEY="$SESSION_KEY" \
  nohup bash "${PLUGIN_ROOT}/scripts/otel-watcher.sh" > /dev/null 2>&1 &

  rmdir "$WATCHER_LOCK" 2>/dev/null || true
}

# Check if our listener PID is alive
if [ -f "$GLOBAL_PID_FILE" ]; then
  OLD_PID=$(cat "$GLOBAL_PID_FILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    ensure_watcher
    exit 0  # listener alive, watcher ensured
  fi
  rm -f "$GLOBAL_PID_FILE"
fi

# Check if ANY otel-listener is already on this port
if lsof -i :"$PORT" 2>/dev/null | grep -q LISTEN; then
  _other=$(lsof -t -i :"$PORT" 2>/dev/null | head -1)
  if [ -n "$_other" ]; then
    echo "$_other" > "$GLOBAL_PID_FILE"
    ensure_watcher
    exit 0  # reuse existing listener
  fi
fi

# Start listener in background (nohup so it survives hook exit)
GHOSTTY_OTEL_PORT="$PORT" \
GHOSTTY_OTEL_STATE_DIR="$STATE_DIR" \
GHOSTTY_OTEL_SESSION_KEY="global" \
GHOSTTY_OTEL_LOG="$LOG_FILE" \
nohup python3 "${PLUGIN_ROOT}/scripts/otel-listener.py" > /dev/null 2>&1 &
LISTENER_PID=$!
echo "$LISTENER_PID" > "$GLOBAL_PID_FILE"

# Wait briefly to verify startup
sleep 0.3
if ! kill -0 "$LISTENER_PID" 2>/dev/null; then
  rm -f "$GLOBAL_PID_FILE"
  exit 1
fi

# Also ensure watcher starts
ensure_watcher
exit 0
