#!/usr/bin/env bash
# Fires on Notification — display macOS notification + speech announcement.
# Receives JSON on stdin with message, title, session_id, etc.
# Includes session context (project dir + TTY) for multi-session identification.
set -u

_stdin="$(cat 2>/dev/null)" || true
[ -z "$_stdin" ] && exit 0

# Extract message and title from stdin JSON (no jq dependency)
_msg="$(echo "$_stdin" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')" || true
_title="$(echo "$_stdin" | grep -o '"title":"[^"]*"' | head -1 | sed 's/"title":"//;s/"$//')" || true

# Build session context: project dir basename + TTY
_project="$(basename "${PWD:-unknown}" 2>/dev/null || echo "unknown")"
_tty="$(basename "$(tty 2>/dev/null)" 2>/dev/null || echo "")"
if [ -n "$_tty" ] && [ "$_tty" != "not a tty" ]; then
  _session_label="${_project} (${_tty})"
else
  _session_label="$_project"
fi

# Title includes session context
[ -z "$_title" ] && _title="Claude Code"
_title_full="${_title} — ${_session_label}"

# Fallback message
[ -z "$_msg" ] && _msg="Needs your input"

# Sanitize for osascript (escape double quotes)
_msg_clean="$(echo "$_msg" | sed 's/"/\\"/g')" || true
_title_clean="$(echo "$_title_full" | sed 's/"/\\"/g')" || true
_session_clean="$(echo "$_session_label" | sed 's/"/\\"/g')" || true

# 1. macOS notification (visual) — subtitle shows session, body shows message
if [ -n "$_msg_clean" ]; then
  osascript -e "display notification \"${_msg_clean}\" with title \"Claude Code\" subtitle \"${_session_clean}\"" 2>/dev/null || true
fi

# 2. Speech announcement — contextual for multi-session awareness
if [ -n "$_session_label" ]; then
  say "Claude Code in ${_session_label} needs your input" 2>/dev/null &
fi

exit 0
