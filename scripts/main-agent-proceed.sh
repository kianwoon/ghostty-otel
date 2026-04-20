#!/usr/bin/env bash
# StopFailure hook: auto-proceed if main agent is busy
# Delegates to shared proceed-by-state.sh
exec "${0%/*}/proceed-by-state.sh"
