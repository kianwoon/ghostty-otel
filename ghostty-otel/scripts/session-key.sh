#!/usr/bin/env bash
# Derive a stable session key and TTY path for ghostty-otel.
# Outputs two lines: session_key and tty_path.
# Safe to source or call as subshell.
set -u

# --- TTY path resolution ---
_resolve_tty() {
  local _tty_path=""

  # Method 1: Try /dev/tty directly (always works if we have a controlling terminal)
  if [ -e /dev/tty ]; then
    _tty_path=$(readlink /dev/tty 2>/dev/null || true)
    if [ -z "$_tty_path" ]; then
      # stat /dev/tty to get the minor device number
      _tty_path=$(stat -f "%Y" /dev/tty 2>/dev/null || true)
    fi
  fi

  # Method 2: tty command (may return "not a tty" — must check)
  if [ -z "$_tty_path" ]; then
    local _tty_out=$(tty 2>/dev/null) || true
    if [ -n "$_tty_out" ] && [ "$_tty_out" != "not a tty" ]; then
      _tty_path="$_tty_out"
    fi
  fi

  # Method 3: Parent process TTY via ps
  if [ -z "$_tty_path" ]; then
    local _tty_ps=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ') || true
    if [ -n "$_tty_ps" ] && [ "$_tty_ps" != "??" ]; then
      _tty_path="/dev/$_tty_ps"
    fi
  fi

  # Method 4: Walk up process tree
  if [ -z "$_tty_path" ]; then
    local _pid=$$
    for _ in $(seq 5); do
      _tty_ps=$(ps -o tty= -p $_pid 2>/dev/null | tr -d ' ') || true
      if [ -n "$_tty_ps" ] && [ "$_tty_ps" != "??" ]; then
        _tty_path="/dev/$_tty_ps"
        break
      fi
      _pid=$(ps -o ppid= -p $_pid 2>/dev/null | tr -d ' ') || break
    done
  fi

  echo "${_tty_path:-/dev/tty}"
}

# --- Session key derivation ---
_resolve_key() {
  local _tty_path="$1"

  # Extract just the device name (e.g., ttys003 from /dev/ttys003)
  local _dev_name=$(basename "$_tty_path" 2>/dev/null | tr '/' '_' | tr -cd 'a-zA-Z0-9_-')
  if [ -n "$_dev_name" ]; then
    echo "$_dev_name"
  else
    echo "tty"
  fi
}

# --- Main output ---
# Line 1: TTY path (for watcher emit target)
# Line 2: Session key (for state file naming)
# Usage: read _tty _key <<< "$(bash session-key.sh)"
TTY_PATH=$(_resolve_tty)
SESSION_KEY=$(_resolve_key "$TTY_PATH")

echo "$TTY_PATH"
echo "$SESSION_KEY"
