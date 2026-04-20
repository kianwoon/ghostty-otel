#!/usr/bin/env bash
# StopFailure hook: state-file busy check
# Delegates to shared proceed-by-state.sh
set -u
_raw_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "${_raw_root}/scripts/resolve-cache.sh"
PLUGIN_ROOT=$(resolve_plugin_root)
bash "${PLUGIN_ROOT}/scripts/proceed-by-state.sh"
