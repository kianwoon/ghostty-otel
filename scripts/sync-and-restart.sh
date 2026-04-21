#!/usr/bin/env bash
# sync-and-restart.sh — Atomic sync + restart from plugin cache
# Ensures ONLY cache-version processes ever run. Kills everything else.
# Usage: bash scripts/sync-and-restart.sh
set -uo pipefail

CACHE_BASE="${HOME}/.claude/plugins/cache/kianwoon/ghostty-otel"
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"

# Resolve cache directory
CACHE_DIR=$(ls -d "${CACHE_BASE}/"*/ 2>/dev/null | head -1)
if [ -z "$CACHE_DIR" ]; then
  echo "[sync-and-restart] ERROR: No cache directory found"
  exit 1
fi
CACHE_DIR="${CACHE_DIR%/}"  # remove trailing slash

# Detect dev mode: source exists outside cache
_raw_root="${CLAUDE_PLUGIN_ROOT:-${CACHE_BASE}/1.0.0}"
SOURCE_DIR=""
if [[ "$_raw_root" != *".claude/plugins/cache"* ]] && [ -d "$_raw_root" ]; then
  SOURCE_DIR="$_raw_root"
fi

echo "[sync-and-restart] Starting..."

# --- 1. Sync source → cache + marketplace (dev mode only) ---
if [ -n "$SOURCE_DIR" ]; then
  echo "[sync-and-restart] Dev mode: syncing ${SOURCE_DIR} → ${CACHE_DIR}"
  rsync -a --delete --exclude='.git' "${SOURCE_DIR}/" "${CACHE_DIR}/" || true
  MARKET_DIR="${HOME}/claude-marketplaces/kianwoon/ghostty-otel"
  if [ -d "$MARKET_DIR" ]; then
    rsync -a --delete --exclude='.git' "${SOURCE_DIR}/" "$MARKET_DIR/" || true
  fi
fi

# --- 2. Kill ALL stale watchers (non-cache paths) ---
echo "[sync-and-restart] Killing stale watchers..."
stale_watchers=$(ps aux | grep otel-watcher | grep -v grep | grep -v "${CACHE_BASE}" | awk '{print $2}' || true)
for pid in $stale_watchers; do
  [ -n "$pid" ] && kill "$pid" 2>/dev/null && echo "  killed stale watcher PID $pid"
done

# --- 3. Kill ALL stale listeners (non-cache paths) ---
echo "[sync-and-restart] Killing stale listeners..."
stale_listeners=$(ps aux | grep otel-listener | grep -v grep | grep -v "${CACHE_BASE}" | awk '{print $2}' || true)
for pid in $stale_listeners; do
  [ -n "$pid" ] && kill "$pid" 2>/dev/null && echo "  killed stale listener PID $pid"
done

# --- 4. Kill ALL existing watchers (force restart from cache) ---
echo "[sync-and-restart] Restarting all watchers from cache..."
for pidfile in "${STATE_DIR}"/ghostty-watcher-*.pid; do
  [ -f "$pidfile" ] || continue
  wpid=$(cat "$pidfile" 2>/dev/null) || true
  [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && kill "$wpid" 2>/dev/null && echo "  killed watcher PID $wpid"
  rm -f "$pidfile"
done

# --- 5. Kill existing listener and restart from cache ---
GLOBAL_PID_FILE="${STATE_DIR}/ghostty-otel.pid"
PORT="${GHOSTTY_OTEL_PORT:-4318}"
LOG_FILE="${GHOSTTY_OTEL_LOG:-/tmp/ghostty-otel.log}"

if [ -f "$GLOBAL_PID_FILE" ]; then
  lpid=$(cat "$GLOBAL_PID_FILE" 2>/dev/null) || true
  [ -n "$lpid" ] && kill "$lpid" 2>/dev/null && echo "  killed listener PID $lpid"
  rm -f "$GLOBAL_PID_FILE"
fi

# Kill any orphan listener on the port
orphan_pids=$(lsof -t -i :"$PORT" 2>/dev/null || true)
for pid in $orphan_pids; do
  [ -n "$pid" ] && kill "$pid" 2>/dev/null && echo "  killed orphan listener PID $pid"
done

sleep 0.5

# Restart listener from CACHE
CACHE_SCRIPT="${CACHE_DIR}/scripts/otel-listener.py"
if [ -f "$CACHE_SCRIPT" ]; then
  GHOSTTY_OTEL_PORT="$PORT" \
  GHOSTTY_OTEL_STATE_DIR="$STATE_DIR" \
  GHOSTTY_OTEL_SESSION_KEY="global" \
  GHOSTTY_OTEL_LOG="$LOG_FILE" \
  nohup python3 "$CACHE_SCRIPT" > /dev/null 2>&1 &
  NEW_PID=$!
  echo "$NEW_PID" > "$GLOBAL_PID_FILE"
  echo "[sync-and-restart] Listener started PID $NEW_PID"
fi

echo "[sync-and-restart] Done. All processes running from cache."
ps aux | grep -E "otel-(listener|watcher)" | grep -v grep || true
