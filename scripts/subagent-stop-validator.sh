#!/usr/bin/env bash
# subagent-stop-validator.sh — Alias to anti-stall.sh
# SubagentStop and TeammateIdle use both scripts — delegate to shared logic.
exec "${0%/*}/anti-stall.sh"
