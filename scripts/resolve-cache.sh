#!/usr/bin/env bash
# resolve-cache.sh — Returns the correct runtime directory for ghostty-otel.
# Priority: cache > script location > CLAUDE_PLUGIN_ROOT
# Works for: GitHub installs, marketplace installs, local dev
# Usage: source this file and call resolve_plugin_root
set -u

resolve_plugin_root() {
  # 1. Cache (the ONLY valid runtime path for installed plugins)
  # Find the latest version in cache (sorted = highest version last)
  for dir in "${HOME}/.claude/plugins/cache/kianwoon/ghostty-otel/"*/; do
    if [ -d "$dir" ]; then
      _latest="${dir%/}"
    fi
  done
  if [ -n "${_latest:-}" ]; then
    echo "$_latest"
    return
  fi

  # 2. Script location (works for local dev)
  echo "$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")/.." && pwd)"
}

# When sourced: does nothing (caller uses resolve_plugin_root)
# When executed directly: print the resolved path
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_plugin_root
fi
