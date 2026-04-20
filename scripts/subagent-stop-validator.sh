#!/usr/bin/env bash
# Stop validator for SubagentStop and TeammateIdle hooks
# Checks transcript for real tool usage and unresolved errors
set -euo pipefail

INPUT="$(cat)"

if echo "$INPUT" | command jq -e '.stop_hook_active == true' >/dev/null 2>&1; then
    echo '{"ok":true}'
    exit 0
fi

TRANSCRIPT_PATH="${TRANSCRIPT_PATH:-}"

if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
    echo '{"ok":true}'
    exit 0
fi

HAS_REAL_TOOLS=0
HAS_ERRORS=0

if command -v jq >/dev/null 2>&1; then
    TOOL_COUNT=$(jq -r '
        select(.tool != null) |
        select(.tool | IN("Write", "Edit", "Bash", "Read", "Glob", "Grep", "Agent", "Task", "Skill", "WebSearch", "mcp__", "LSP", "NotebookEdit")) |
        .tool
    ' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    ERROR_COUNT=$(jq -r '
        select(.toolError != null) |
        .toolError
    ' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    [[ "$TOOL_COUNT" -gt 0 ]] && HAS_REAL_TOOLS=1
    [[ "$ERROR_COUNT" -gt 0 ]] && HAS_ERRORS=1
else
    if grep -q '"tool":"\("Write"\|"Edit"\|"Bash"\|"Read"\|"Glob"\|"Grep"\|"Agent"\|"Task"\|"Skill"\|"WebSearch"\|"mcp__"\|"LSP"\|"NotebookEdit"\)' "$TRANSCRIPT_PATH" 2>/dev/null; then
        HAS_REAL_TOOLS=1
    fi
    if grep -q '"toolError"' "$TRANSCRIPT_PATH" 2>/dev/null; then
        HAS_ERRORS=1
    fi
fi

if [[ "$HAS_REAL_TOOLS" -eq 0 ]]; then
    echo '{"ok":false,"systemMessage":"Agent stopped without executing any real tools — continuing task"}'
    exit 0
fi

if [[ "$HAS_ERRORS" -gt 0 ]]; then
    echo '{"ok":false,"systemMessage":"Agent had tool errors — continuing to resolve"}'
    exit 0
fi

echo '{"ok":true}'
