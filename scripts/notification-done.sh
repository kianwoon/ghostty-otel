#!/usr/bin/env bash
# Fires on Notification — display macOS notification + speech announcement.
# Receives JSON on stdin with message, title, session_id, etc.
# Runs in detached context (no TTY) — uses osascript and say.
set -u

_stdin="$(cat 2>/dev/null)" || true
[ -z "$_stdin" ] && exit 0

# Extract message and title from stdin JSON (no jq dependency)
_msg="$(echo "$_stdin" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')" || true
_title="$(echo "$_stdin" | grep -o '"title":"[^"]*"' | head -1 | sed 's/"title":"//;s/"$//')" || true

# Fallback title
[ -z "$_title" ] && _title="Claude Code"

# Sanitize for osascript (escape double quotes)
_msg_clean="$(echo "$_msg" | sed 's/"/\\"/g')" || true
_title_clean="$(echo "$_title" | sed 's/"/\\"/g')" || true

# 1. macOS notification (visual)
if [ -n "$_msg_clean" ]; then
  osascript -e "display notification \"${_msg_clean}\" with title \"${_title_clean}\"" 2>/dev/null || true
fi

# 2. Speech announcement (audio — harder to miss)
# Truncate long messages and speak in background to avoid blocking
if [ -n "$_msg" ]; then
  # Truncate to ~200 chars for speech (keep it brief)
  _speech="$(echo "$_msg" | cut -c1-200)" || true
  say "$_speech" 2>/dev/null &
fi

exit 0
