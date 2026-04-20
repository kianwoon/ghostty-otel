#!/usr/bin/env bash
# Start the OTEL listener daemon for ghostty-otel plugin.
# Called from SessionStart + prompt-submit.sh health check.
# Safe to call multiple times — idempotent.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PORT="${GHOSTTY_OTEL_PORT:-4318}"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
LOG_FILE="${GHOSTTY_OTEL_LOG:-/tmp/ghostty-otel.log}"

# --- Cache sync: marketplace source → plugin cache (prevents staleness) ---
# Runs on SessionStart to ensure cache reflects latest marketplace source.
# Cache dir is ~/.claude/plugins/cache/kianwoon/ghostty-otel/VERSION/
sync_cache() {
  local CACHE_VER
  local MARKET_VER
  local CACHE_DIR

  # Only sync if running from cache (detect by path structure)
  case "$PLUGIN_ROOT" in
    */.claude/plugins/cache/*)
      CACHE_VER=$(python3 -c "import json; print(json.load(open('$PLUGIN_ROOT/.claude-plugin/plugin.json'))['version'])" 2>/dev/null) || return 0
      MARKET_VER=$(python3 -c "import json; print(json.load(open('$HOME/claude-marketplaces/kianwoon/ghostty-otel/.claude-plugin/plugin.json'))['version'])" 2>/dev/null) || return 0
      if [ "$CACHE_VER" != "$MARKET_VER" ]; then
        CACHE_DIR="$(dirname "$PLUGIN_ROOT")"
        rsync -a --delete "$HOME/claude-marketplaces/kianwoon/ghostty-otel/" "$CACHE_DIR/" 2>/dev/null || true
      fi
      ;;
  esac
}
sync_cache

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
