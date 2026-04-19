#!/usr/bin/env bash
# Per-session watcher: polls state file and emits OSC 9;4 to THIS TTY.
# Started by hooks (SessionStart, prompt-submit.sh).
# Runs in correct TTY context — can emit OSC to /dev/tty.
# Dies when state file disappears (session ended).
set -u

# --- Session key derivation (single source of truth) ---
# Prefer GHOSTTY_OTEL_SESSION_KEY if set (passed by hook before nohup detach)
# Then try GHOSTTY_OTEL_TTY (TTY path captured before nohup detach)
# Finally fall back to session-key.sh
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -n "${GHOSTTY_OTEL_SESSION_KEY:-}" ]; then
  SESSION_KEY="$GHOSTTY_OTEL_SESSION_KEY"
elif [ -n "${GHOSTTY_OTEL_TTY:-}" ]; then
  SESSION_KEY="$(basename "$GHOSTTY_OTEL_TTY" | tr '/' '_' | tr -cd 'a-zA-Z0-9_-')"
else
  # session-key.sh outputs TWO lines: TTY_PATH, then SESSION_KEY
  # Take the second line
  SESSION_KEY="$(bash "${PLUGIN_ROOT}/scripts/session-key.sh" | sed -n '2p')"
fi

STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"
STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}"
PID_FILE="${STATE_DIR}/ghostty-watcher-${SESSION_KEY}.pid"
GLOBAL_LISTENER_PID_FILE="${STATE_DIR}/ghostty-otel.pid"
WATCHER_LOG="${GHOSTTY_OTEL_WATCHER_LOG:-/tmp/ghostty-watcher-${SESSION_KEY}.log}"
MAX_LOG_BYTES=300

# Rotate log if it exceeds MAX_LOG_BYTES (snap to line boundary)
rotate_log() {
  local log="${1:-}"
  if [ -n "$log" ] && [ -f "$log" ]; then
    local size
    size=$(wc -c < "$log" 2>/dev/null | tr -d ' ') || size=0
    if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
      # Keep last MAX_LOG_BYTES bytes, drop first line to snap to line boundary
      tail -c "$MAX_LOG_BYTES" "$log" | tail -n +2 > "${log}.tmp" 2>/dev/null && \
        mv "${log}.tmp" "$log" 2>/dev/null || true
    fi
  fi
}

# Write to log with automatic rotation
log_write() {
  local msg="$1"
  local log="${2:-$WATCHER_LOG}"
  if [ -n "$log" ]; then
    rotate_log "$log"
    echo "$msg" >> "$log" 2>/dev/null || true
  fi
}

# --- OSC 9;4 emit (tmux-aware) ---
# Uses GHOSTTY_OTEL_TTY if set (captured before nohup detachment), else /dev/tty
_otel_tty="${GHOSTTY_OTEL_TTY:-/dev/tty}"
emit() {
  local seq="$1"
  if [ -n "${TMUX:-}" ]; then
    local escaped="${seq//$'\033'/$'\033\033'}"
    printf '\033Ptmux;\033%s\033\\' "$escaped" > "$_otel_tty" 2>/dev/null || true
  else
    printf '%b' "$seq" > "$_otel_tty" 2>/dev/null || true
  fi
}

# --- OSC code from state text ---
state_to_osc() {
  case "$1" in
    calling_llm*)    echo 3 ;;
    tool_running*)   echo 3 ;;
    tool_exec*)      echo 3 ;;
    working*)        echo 3 ;;   # legacy prompt-submit state
    waiting_input)   echo 2 ;;
    subagent_idle)   echo 2 ;;
    looping*)        echo 2 ;;
    idle)            echo 0 ;;
    done)            echo 0 ;;   # fallback recovery state
    failure*)        echo 2 ;;
    *)               echo 0 ;;
  esac
}

# --- Prevent duplicate watchers (atomic lock) ---
WATCHER_LOCK="${STATE_DIR}/ghostty-watcher-${SESSION_KEY}.lock"

if [ -f "$PID_FILE" ]; then
  _old=$(cat "$PID_FILE" 2>/dev/null) || true
  if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
    exit 0
  fi
  rm -f "$PID_FILE"
fi

# Acquire lock before writing PID
if ! mkdir "$WATCHER_LOCK" 2>/dev/null; then
  # Another instance is starting — wait briefly and check
  sleep 0.2
  if [ -f "$PID_FILE" ]; then
    _old2=$(cat "$PID_FILE" 2>/dev/null) || true
    if [ -n "$_old2" ] && kill -0 "$_old2" 2>/dev/null; then
      rmdir "$WATCHER_LOCK" 2>/dev/null || true
      exit 0
    fi
  fi
  # Lock holder seems stuck — force through
fi

echo $$ > "$PID_FILE"
rmdir "$WATCHER_LOCK" 2>/dev/null || true
log_write "[$(date +%H:%M:%S)] watcher started pid=$$ key=$SESSION_KEY tty=${_otel_tty}"

# --- Main poll loop ---
# Ghostty resets OSC 9;4 state after ~15s of inactivity.
# We must re-emit the current state at least once every 3s as keep-alive.
KEEPALIVE_ITERS=30   # 30 × 0.1s = 3s
LISTENER_CHECK_ITERS=50  # 50 × 0.1s = 5s
_iter=0

STATE_TEXT=""
_file_missing_count=0
_restart_attempts=0
MAX_RESTART_ATTEMPTS=3
while true; do
  _iter=$((_iter + 1))

  # State file gone → session may have ended or listener dead
  if [ ! -f "$STATE_FILE.txt" ]; then
    _file_missing_count=$((_file_missing_count + 1))
    if [ "$_file_missing_count" -ge 10 ]; then
      # Missing for ~5s — check if listener can recreate it
      if [ -f "$GLOBAL_LISTENER_PID_FILE" ]; then
        _lpid=$(cat "$GLOBAL_LISTENER_PID_FILE" 2>/dev/null) || true
        if [ -n "$_lpid" ] && kill -0 "$_lpid" 2>/dev/null; then
          # Listener alive but no state file — create a default
          echo "idle" > "${STATE_FILE}.txt" 2>/dev/null || true
          _file_missing_count=0
          continue
        fi
      fi
      # Listener dead — try to restart (capped attempts)
      if [ "$_restart_attempts" -ge "$MAX_RESTART_ATTEMPTS" ]; then
        log_write "[$(date +%H:%M:%S)] max restart attempts reached, exiting"
        break
      fi
      _restart_attempts=$((_restart_attempts + 1))
      log_write "[$(date +%H:%M:%S)] listener dead, restart attempt $_restart_attempts/$MAX_RESTART_ATTEMPTS"
      GHOSTTY_OTEL_SESSION_KEY="$SESSION_KEY" \
      GHOSTTY_OTEL_STATE_DIR="$STATE_DIR" \
      GHOSTTY_OTEL_TTY="${_otel_tty}" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      bash "${PLUGIN_ROOT}/scripts/start-listener.sh" > /dev/null 2>&1
      sleep 2
      if [ -f "$STATE_FILE.txt" ]; then
        _file_missing_count=0
        _restart_attempts=0
        continue
      fi
      _file_missing_count=0
      log_write "[$(date +%H:%M:%S)] waiting for state file to reappear"
      sleep 5
      continue
    fi
    sleep 0.5
    continue
  fi
  _file_missing_count=0
  _restart_attempts=0

  NEW_TEXT=$(cat "$STATE_FILE.txt" 2>/dev/null | tr -d '\n')
  # Skip empty reads (race during rename) — keep last known state
  if [ -z "$NEW_TEXT" ]; then
    sleep 0.1
    continue
  fi

  _state_changed=0
  if [ "$NEW_TEXT" != "$STATE_TEXT" ]; then
    STATE_TEXT="$NEW_TEXT"
    _state_changed=1
  fi

  # Emit on state change OR keep-alive interval
  if [ "$_state_changed" -eq 1 ] || [ $(( _iter % KEEPALIVE_ITERS )) -eq 0 ]; then
    OSC=$(state_to_osc "$STATE_TEXT")
    # OSC 9;4: graphical progress bar
    emit "\033]9;4;${OSC}\033\\"
    # OSC 2: window title with TTY and state
    _tty_short="$(basename "$_otel_tty")"
    if [ "$OSC" = "0" ]; then
      emit "\033]2;${_tty_short} claude: idle\033\\"
    else
      emit "\033]2;${_tty_short} claude: ${STATE_TEXT}\033\\"
    fi
    # Debug log (only on state change to avoid spam)
    if [ "$_state_changed" -eq 1 ]; then
      log_write "[$(date +%H:%M:%S)] state=${STATE_TEXT} osc=${OSC} tty=${_otel_tty}"
    fi
  fi

  # --- Listener health check (PID-based, no lsof) ---
  if [ $(( _iter % LISTENER_CHECK_ITERS )) -eq 0 ]; then
    if [ -f "${STATE_DIR}/ghostty-otel.pid" ]; then
      _lpid=$(cat "${STATE_DIR}/ghostty-otel.pid" 2>/dev/null) || true
      if [ -z "$_lpid" ] || ! kill -0 "$_lpid" 2>/dev/null; then
        GHOSTTY_OTEL_SESSION_KEY="$SESSION_KEY" \
        GHOSTTY_OTEL_STATE_DIR="$STATE_DIR" \
        GHOSTTY_OTEL_TTY="$_otel_tty" \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        bash "${PLUGIN_ROOT}/scripts/start-listener.sh" > /dev/null 2>&1 &
      fi
    fi
  fi

  sleep 0.1
done

rm -f "$PID_FILE"
exit 0
