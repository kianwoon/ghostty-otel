#!/usr/bin/env bash
# subagent-stop-validator.sh — Validates SubagentStop and TeammateIdle
# Single-pass transcript check: tool count, errors, planning-without-executing.
# Blocks stop if agent stalled or only planned without executing.
# Input: JSON on stdin. Output: {"ok":true} or {"ok":false,"systemMessage":"..."}
set -uo pipefail  # no -e — we handle errors explicitly

INPUT="$(cat)" || INPUT=""

# ── Gate: stop_hook_active → allow ──────────────────────────────
if [[ "$INPUT" == *'"stop_hook_active":true'* ]] || [[ "$INPUT" == *'"stop_hook_active": true'* ]]; then
    echo '{"ok":true}'
    exit 0
fi

TRANSCRIPT_PATH="${TRANSCRIPT_PATH:-}"

# ── No transcript → allow ───────────────────────────────────────
if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
    echo '{"ok":true}'
    exit 0
fi

# ── Single-pass transcript analysis ─────────────────────────────
# All metrics in ONE jq invocation to avoid re-reading large files.
HAS_TOOLS=0
HAS_ERRORS=0
HAS_TASK_CREATES=0
BLOCK_REASON=""

if command -v jq >/dev/null 2>&1; then
    _result=$(jq -r '
        [inputs | select(.tool != null and (.tool | IN("Write","Edit","Bash","Read","Glob","Grep","Agent","Task","Skill","WebSearch","LSP","NotebookEdit")))] | length as $tools |
        [inputs | select(.toolError != null)] | length as $errors |
        [inputs | select(.tool == "TaskCreate")] | length as $tasks |
        "\($tools)\($errors)\($tasks)"
    ' "$TRANSCRIPT_PATH" 2>/dev/null) || _result="000"

    _tools="${_result:0:1}"
    _errors="${_result:1:1}"
    _tasks="${_result:2:1}"

    [[ "$_tools" -gt 0 ]] 2>/dev/null && HAS_TOOLS=1
    [[ "$_errors" -gt 0 ]] 2>/dev/null && HAS_ERRORS=1
    [[ "$_tasks" -gt 0 ]] 2>/dev/null && HAS_TASK_CREATES=1
else
    # Fallback: grep
    if grep -qE '"tool":"(Write|Edit|Bash|Read|Glob|Grep|Agent|Task|Skill|WebSearch|LSP|NotebookEdit)"' "$TRANSCRIPT_PATH" 2>/dev/null; then
        HAS_TOOLS=1
    fi
    if grep -q '"toolError"' "$TRANSCRIPT_PATH" 2>/dev/null; then
        HAS_ERRORS=1
    fi
    if grep -q '"tool":"TaskCreate"' "$TRANSCRIPT_PATH" 2>/dev/null; then
        HAS_TASK_CREATES=1
    fi
fi

# ── Decision logic ───────────────────────────────────────────────
# Priority: no tools > planning-without-executing > errors > allow

if [[ "$HAS_TOOLS" -eq 0 ]]; then
    if [[ "$HAS_TASK_CREATES" -gt 0 ]]; then
        echo '{"ok":false,"systemMessage":"Tasks planned but no implementation tools executed — start implementing now"}'
    else
        echo '{"ok":false,"systemMessage":"No real tool calls detected — continue working on your assigned task"}'
    fi
    exit 0
fi

if [[ "$HAS_ERRORS" -gt 0 ]]; then
    echo '{"ok":false,"systemMessage":"Tool errors detected — continue to resolve them"}'
    exit 0
fi

echo '{"ok":true}'
