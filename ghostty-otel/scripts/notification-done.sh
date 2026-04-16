#!/usr/bin/env bash
# Fires on Notification — NO-OP for now.
# The OTEL listener is the authoritative source for state transitions.
# Notification events fire mid-work (tool progress, subagent updates), so we
# cannot assume they mean "idle." Let the HoldTimer manage idle detection.
set -u

# This hook is now a no-op. The OTEL listener handles all state transitions.
# Keeping it in hooks.json for potential future use (e.g., filtering specific
# notification types), but for now it does nothing to avoid race conditions.
exit 0
