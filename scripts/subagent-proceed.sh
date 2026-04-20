#!/usr/bin/env bash
# SubagentStop hook: state-file busy check
# Delegates to shared proceed-by-state.sh
set -u
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
bash "${PLUGIN_ROOT}/scripts/proceed-by-state.sh"
