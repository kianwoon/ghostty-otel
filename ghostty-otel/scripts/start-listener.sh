#!/usr/bin/env bash
# Start the OTEL listener daemon for ghostty-otel plugin.
# Called from SessionStart hook. Safe to call multiple times (idempotent).
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PORT="${GHOSTTY_OTEL_PORT:-4318}"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
LOG_FILE="${GHOSTTY_OTEL_LOG:-/tmp/ghostty-otel.log}"

# Derive session key from TTY (same logic as ghostty-state.sh)
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

PID_FILE="${STATE_DIR}/ghostty-otel-${SESSION_KEY}.pid"

# Check if already running
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    # Already running — just ensure OTEL env is set
    exit 0
  fi
  rm -f "$PID_FILE"
fi

# Start listener in background
GHOSTTY_OTEL_PORT="$PORT" \
GHOSTTY_OTEL_STATE_DIR="$STATE_DIR" \
GHOSTTY_OTEL_SESSION_KEY="$SESSION_KEY" \
GHOSTTY_OTEL_LOG="$LOG_FILE" \
python3 "${PLUGIN_ROOT}/scripts/otel-listener.py" >/dev/null 2>&1 &
LISTENER_PID=$!
echo "$LISTENER_PID" > "$PID_FILE"

# Wait briefly to verify startup
sleep 0.3
if ! kill -0 "$LISTENER_PID" 2>/dev/null; then
  rm -f "$PID_FILE"
  exit 1
fi

# Write OTEL env vars to CLAUDE_ENV_FILE (persists for session)
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  # Only add if not already present
  if ! grep -q "OTEL_EXPORTER_OTLP_ENDPOINT" "$CLAUDE_ENV_FILE" 2>/dev/null; then
    cat >> "$CLAUDE_ENV_FILE" << EOF
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:${PORT}
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
export OTEL_TRACES_EXPORTER=otlp
export OTEL_SERVICE_NAME=claude-code
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
EOF
  fi
fi

exit 0
