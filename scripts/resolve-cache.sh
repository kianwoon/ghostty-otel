#!/usr/bin/env bash
# resolve-cache.sh — Returns the correct runtime directory for ghostty-otel.
# Priority: cache > script location > CLAUDE_PLUGIN_ROOT
# Works for: GitHub installs, marketplace installs, local dev
# Usage: source this file and call resolve_plugin_root
set -u

resolve_plugin_root() {
  # 1. Cache (the ONLY valid runtime path for installed plugins)
  local CACHE="${HOME}/.claude/plugins/cache/kianwoon/ghostty-otel/1.0.0"
  if [ -d "$CACHE" ]; then
    echo "$CACHE"
    return
  fi

  # 2. Any version in cache
  for dir in "${HOME}/.claude/plugins/cache/kianwoon/ghostty-otel/"*/; do
    if [ -d "$dir" ]; then
      echo "${dir%/}"
      return
    fi
  done

  # 3. Script location (works for direct installs)
  echo "$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")/.." && pwd)"
}

# When sourced: does nothing (caller uses resolve_plugin_root)
# When executed directly: print the resolved path
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_plugin_root
fi
