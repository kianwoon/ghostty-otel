#!/usr/bin/env bash
# Fires on UserPromptSubmit — emit indicator ON + health check listener.
# This hook runs in the correct TTY context, so OSC reaches the terminal.
# Performance budget: <10ms (OSC emit + PID check).
set -u

STATE_DIR="${GHOSTTY_OTEL_STATE_DIR:-/tmp}"

# --- Session key derivation (inline, no subshells) ---
TTY_PATH=$(readlink /dev/tty 2>/dev/null) || TTY_PATH=""
if [[ -z "$TTY_PATH" ]]; then
    _tty_out=$(tty 2>/dev/null) || true
    if [[ -n "$_tty_out" ]] && [[ "$_tty_out" != "not a tty" ]]; then
        TTY_PATH="$_tty_out"
    fi
fi
if [[ -z "$TTY_PATH" ]]; then
    exit 0  # No TTY — can't emit OSC or derive session key
fi
SESSION_KEY=$(basename "$TTY_PATH" | tr -cd 'a-zA-Z0-9_-')

# --- SID mapping (session.id → session_key) ---
_stdin_json="$(cat 2>/dev/null)" || true
_session_id=""
if [[ -n "$_stdin_json" ]]; then
    _match="${_stdin_json#*\"session_id\":\"}"
    if [[ "$_match" != "$_stdin_json" ]]; then
        _session_id="${_match%%\"*}"
    fi
    if [[ -z "$_session_id" ]]; then
        _tp="${_stdin_json#*\"transcript_path\":\"}"
        if [[ "$_tp" != "$_stdin_json" ]]; then
            _tp="${_tp%%\"*}"
            _session_id="${_tp##*/}"
            _session_id="${_session_id%.jsonl}"
        fi
    fi
fi
if [[ -z "$_session_id" ]]; then
    _tpf="${STATE_DIR}/ghostty-transcript-path-${SESSION_KEY}"
    if [[ -f "$_tpf" ]]; then
        _tpath="$(cat "$_tpf" 2>/dev/null)" || true
        if [[ -n "$_tpath" ]]; then
            _session_id="${_tpath##*/}"
            _session_id="${_session_id%.jsonl}"
        fi
    fi
fi
if [[ -n "$_session_id" ]]; then
    printf '%s' "$_session_id" > "${STATE_DIR}/ghostty-sid-${SESSION_KEY}" 2>/dev/null || true
fi

# Write full transcript path for statusline fallback
if [[ -n "${_tp:-}" ]] && [[ -n "$SESSION_KEY" ]]; then
    printf '%s' "$_tp" > "${STATE_DIR}/ghostty-transcript-path-${SESSION_KEY}" 2>/dev/null || true
fi

# --- OSC 9;4 emit (tmux-aware) ---
emit() {
    local seq="$1"
    if [[ -n "${TMUX:-}" ]]; then
        local escaped="${seq//$'\033'/$'\033\033'}"
        printf '\033Ptmux;\033%s\033\\' "$escaped" > /dev/tty 2>/dev/null || true
    else
        printf '%b' "$seq" > /dev/tty 2>/dev/null || true
    fi
}

# 1. Emit indicator ON immediately
emit '\033]9;4;3\033\\'
emit '\033]2;claude: calling_llm\033\\'

# 2. Write state file (atomic)
STATE_FILE="${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt"
_tmpf="${STATE_FILE}.tmp.$$"
printf 'calling_llm' > "$_tmpf" && mv "$_tmpf" "$STATE_FILE" 2>/dev/null || true

exit 0
