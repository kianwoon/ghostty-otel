#!/usr/bin/env bash
# TeammateIdle hook: auto-proceed if teammate is busy
# Delegates to shared proceed-by-state.sh
exec "${0%/*}/proceed-by-state.sh"
