#!/usr/bin/env bash
# SubagentStop hook: auto-proceed if subagent is busy
# Delegates to shared proceed-by-state.sh
exec "${0%/*}/proceed-by-state.sh"
