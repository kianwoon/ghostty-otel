#!/usr/bin/env bash
# Fires on SessionEnd — clean up state files and background processes.
# Ensures we don't orphan files or processes when Claude exits.
set -u

_raw_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "${_raw_root}/scripts/resolve-cache.sh"
PLUGIN_ROOT=$(resolve_plugin_root)
STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"

# --- Session key + TTY path derivation (single source of truth) ---
_SESSION_INFO="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh")"
SESSION_KEY="$(echo "$_SESSION_INFO" | sed -n '2p')"

# Do NOT kill the singleton listener — it serves all sessions.
# Only clean up this session's state files and watcher.

# Kill the watcher for this session
WATCHER_PID_FILE="${STATE_DIR}/ghostty-watcher-${SESSION_KEY}.pid"
if [ -f "$WATCHER_PID_FILE" ]; then
  _wpid=$(cat "$WATCHER_PID_FILE" 2>/dev/null) || true
  if [ -n "$_wpid" ] && kill -0 "$_wpid" 2>/dev/null; then
    kill "$_wpid" 2>/dev/null || true
  fi
  rm -f "$WATCHER_PID_FILE"
fi

# Remove ALL state files for this session (including extensionless orphan + locks)
STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}"
rm -f "${STATE_FILE}" "${STATE_FILE}.txt" "${STATE_FILE}.txt.tmp" 2>/dev/null || true
rm -f "${STATE_DIR}/ghostty-watcher-${SESSION_KEY}.lock" 2>/dev/null || true

# Remove SID mapping and transcript path files
rm -f "${STATE_DIR}/ghostty-sid-${SESSION_KEY}" 2>/dev/null || true
rm -f "${STATE_DIR}/ghostty-transcript-path-${SESSION_KEY}" 2>/dev/null || true

exit 0
