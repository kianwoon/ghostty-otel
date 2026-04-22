# ghostty-otel

<img width="1536" height="1024" alt="ghostty-otel: real-time Claude Code visibility in Ghostty" src="https://github.com/user-attachments/assets/4d76b8a7-6f07-4b03-b1e2-aec4d0ad6a18" />

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code Plugin](https://img.shields.io/badge/Claude%20Code-Plugin-purple)](https://docs.anthropic.com/en/docs/claude-code)
[![npm version](https://img.shields.io/npm/v/@kianwoon/ghostty-otel.svg)](https://www.npmjs.com/package/@kianwoon/ghostty-otel)

Real-time visibility into Claude Code's internal state for the [Ghostty](https://ghostty.org) terminal.

Receives Claude Code's OpenTelemetry spans and drives **Ghostty's progress indicator** (OSC 9;4) and **window title** (OSC 2) in real time — so you always know what the AI agent is doing, even when you're not looking at the terminal.

## Demo

<!-- Add a GIF or screenshot here showing the indicator in action -->
> **TODO:** Add a demo GIF showing the indicator cycling through states (calling_llm → tool_exec → idle) in a Ghostty window.

## Why This Exists

Claude Code can run for minutes on complex tasks — calling LLMs, executing tools, running agents. Without visibility:

- You switch tabs and come back wondering: "Is Claude still working, or did it stall?"
- An idle agent goes unnoticed while you wait for a response that's never coming
- Tool failures happen silently while the indicator says everything is fine
- A subagent plans tasks but stops before executing any of them
- An agent gets stuck in a tool loop, repeating the same action

**ghostty-otel solves this** by showing Claude's exact state in the terminal indicator and window title — updating in real time as the agent works. The anti-stall system ensures agents keep working on their assigned tasks. Loop detection catches repeated tool calls before they waste tokens.

## What You See

| Claude is... | Indicator | Window Title |
|-------------|-----------|--------------|
| Calling the LLM | Busy (spinning) | `claude: calling_llm:MiniMax-M2.7[1m]` |
| Running a tool | Busy (spinning) | `claude: tool_exec:Read` |
| API error occurred | Attention (red pulsing) | `claude: failure:api_error` |
| Stuck in a tool loop | Attention (red pulsing) | `claude: looping:Bash` |
| Subagent stalled mid-task | Attention (red) | `claude: subagent_idle` |
| Waiting for user input | Attention (red) | `claude: waiting_input` |
| All tasks completed | Idle (off) | `claude: done` |
| Turn complete | Idle (off) | `claude: idle` |

## Quick Start

### Prerequisites

- [Ghostty](https://ghostty.org) terminal
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- Node.js 18+ (for the installer)
- Python 3 (for the OTEL listener)

### Install (one command)

**via npm:**
```bash
npx @kianwoon/ghostty-otel
```

**via GitHub:**
```bash
npx github:kianwoon/ghostty-otel
```

Both commands automatically:
1. Check prerequisites (Claude Code, Node.js, Python 3)
2. Register the plugin marketplace in `~/.claude/settings.json`
3. Enable the plugin
4. Verify the installation

### Install (manual)

If you prefer manual setup, add to `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "kianwoon": {
      "source": { "source": "github", "repo": "kianwoon/ghostty-otel" }
    }
  }
}
```

Then inside Claude Code, run `/plugin` to install `ghostty-otel@kianwoon`.

### Verify

```bash
npx @kianwoon/ghostty-otel status
```

Or manually:

```bash
# Check the listener is running
cat /tmp/ghostty-otel.pid && kill -0 $(cat /tmp/ghostty-otel.pid)

# Check your session's state file
cat /tmp/ghostty-indicator-state-$(tty | xargs basename).txt
```

## How It Works

```
Claude Code ──OTEL spans──▶ otel-listener.py ──state files──▶ otel-watcher.sh ──OSC──▶ Ghostty
   │                              │                                │
   │                              ├── HoldTimer (60s anti-flap)    ├── OSC 9;4 (progress)
   │                              ├── LLM-pending re-arm           ├── OSC 2 (window title)
   │                              ├── Loop detection               └── Keep-alive (3s)
   │                              └── Multi-session routing
   │
   ├─ Hooks ──────────────────────────────────────────────────────────────────────────
   │   │
   │   ├── Stop ──────────────────▶ stop-unified.js
   │   │                              ├── Transcript completeness check
   │   │                              ├── Auto-compact on context limit
   │   │                              └── Auto-continue on recoverable errors
   │   │
   │   ├── SubagentStop/TeammateIdle ──▶ proceed-by-state.sh + anti-stall.sh
   │   │                                  └── Auto-proceed stalled agents
   │   │
   │   ├── PreToolUse ────────────▶ subagent-guard.js
   │   │                              └── Block runaway subagent spawns
   │   │
   │   ├── PostToolUse ───────────▶ subagent-output-guard.js
   │   │                              └── Handle truncated agent output
   │   │
   │   └── PostToolUseFailure ────▶ agent-failure-recovery.js
   │                                  └── Auto-retry failed agent calls
   │
   └── SessionStart ────────────▶ start-listener.sh
                                    └── Singleton listener + per-session watcher
```

## Hook System

All hooks in `hooks/hooks.json`, matcher `"*"`:

| Event | Type | Script | Purpose |
|---|---|---|---|
| Stop | command | `stop-unified.js` | Block premature stop; auto-compact on context limit; auto-continue on errors |
| StopFailure | command | `main-agent-proceed.sh` | Auto-proceed main agent on stale idle |
| SubagentStop | command | `subagent-proceed.sh` + `anti-stall.sh` | Auto-proceed stalled subagents |
| TeammateIdle | command | `teammate-proceed.sh` + `anti-stall.sh` | Auto-proceed stalled teammates |
| SessionStart | command | `auto-cleanup-stale-plugins.js` + `start-listener.sh` | Clean stale plugins; start singleton listener + watcher |
| UserPromptSubmit | command | `prompt-submit.sh` | Immediate OSC emit (gap coverage before first OTEL span) |
| SessionEnd | command | `session-cleanup.sh` | Kill watcher + remove state files |
| PreToolUse | command | `subagent-guard.js` | Block runaway subagent spawns (safety guard) |
| PostToolUse | command | `subagent-output-guard.js` | Handle truncated agent output |
| PostToolUseFailure | command | `agent-failure-recovery.js` | Auto-retry failed Agent/Task calls (up to 3 retries) |

## Anti-Stall & Guard System

Beyond the indicator, ghostty-otel keeps your agents working:

- **Stop guard** (`stop-unified.js`) — analyzes the transcript before allowing Claude to stop. Blocks premature stops when the task is incomplete, auto-compacts on context limit, and auto-continues on recoverable errors.
- **Subagent guard** (`subagent-guard.js`) — prevents runaway nested subagent spawns that waste tokens.
- **Output guard** (`subagent-output-guard.js`) — detects truncated agent output and stores full output to disk for retrieval.
- **Failure recovery** (`agent-failure-recovery.js`) — auto-retries failed Agent/Task calls with error-specific guidance (up to 3 retries per task).
- **Proceed hooks** — auto-proceed stalled main agents, subagents, and teammates by checking state file for busy states.

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `GHOSTTY_OTEL_PORT` | `4318` | OTLP HTTP port |
| `GHOSTTY_OTEL_STATE_DIR` | `/tmp` | State/PID file directory |
| `GHOSTTY_OTEL_HOLD_SECONDS` | `60` | Idle defer (anti-flap) |
| `GHOSTTY_OTEL_LLM_MAX_REARMS` | `10` | Safety cap on LLM re-arms |
| `GHOSTTY_OTEL_LOOP_THRESHOLD` | `5` | Same-tool reps before `looping` |
| `GHOSTTY_OTEL_LOG` | (empty) | Listener log path |

## Architecture Deep-Dive

For plugin developers and contributors.

### Data Flow

```
User types → prompt-submit.sh → OSC emit + state file → Ghostty indicator
    ↓
Claude Code → OTEL span → otel-listener.py (HTTP :4318) → state file
    ↓
otel-watcher.sh (100ms poll) → reads state file → OSC emit → Ghostty
```

### State Machine

```
              ┌──────────────┐
              │   calling_   │◀── prompt-submit.sh (immediate)
              │     llm      │◀── OTEL claude_code.llm_request
              └──────┬───────┘
                     │ LLM responds
              ┌──────▼───────┐
         ┌───▶│  tool_exec   │◀── OTEL claude_code.tool.execution
         │    └──────┬───────┘
         │           │ tool done / tool blocked
         │    ┌──────▼───────────┐
         │    │  waiting_input   │◀── OTEL claude_code.tool.blocked_on_user
         │    └──────────────────┘
         │           │ user responds
         │           ▼
         │    ┌──────────────┐
         └────│ tool_running │◀── OTEL claude_code.tool
              └──────┬───────┘
                     │ task complete
              ┌──────▼───────┐
              │     idle      │◀── OTEL claude_code.interaction
              └──────┬───────┘
                     │ stop hook
              ┌──────▼───────┐
              │     done      │◀── stop-unified.js
              └──────────────┘

Special states:
  failure ──◀── OTEL claude_code.api_error (red pulsing)
  looping ──◀── Same tool ≥5 consecutive times (red pulsing)
  subagent_idle ──◀── busy→idle without completion (red)
```

### Session Routing

Multi-session aware — each terminal gets its own indicator state:

1. **Session key** derived from TTY device (e.g., `ttys003`)
2. **Session ID** (UUID) from OTEL spans mapped to session key via `/tmp/ghostty-sid-*` files
3. **State files** per session: `/tmp/ghostty-indicator-state-{key}.txt`
4. **Watcher** per session: one `otel-watcher.sh` process per TTY

### Key Internals

- **Listener** (`otel-listener.py`): Singleton HTTP server on `:4318`. Receives OTLP JSON, maps spans to states, writes per-session files via atomic rename. Per-session locks prevent TOCTOU races.
- **Watcher** (`otel-watcher.sh`): Per-session poll loop (100ms). Reads state file, maps to OSC codes, emits with tmux DCS wrapping. Keep-alive every 3s. Orphan detection via TTY process check.
- **HoldTimer**: Defers idle transitions by 60s to prevent indicator flashing between LLM responses. Re-arms on LLM-pending spans (up to 10 re-arms / 10 min).
- **Loop detection**: Tracks consecutive same-tool repetitions. Threshold (default 5) triggers `looping` state.

## Contributing

### Dev Setup

```bash
# Clone
git clone https://github.com/kianwoon/ghostty-otel.git
cd ghostty-otel

# Link for development (sync-and-restart.sh copies to cache)
# Just run this to test your changes:
bash scripts/sync-and-restart.sh
```

### Testing

No test framework. Validate changes manually:

```bash
# Validate JSON
python3 -c "import json; json.load(open('hooks/hooks.json'))"

# Validate Python syntax
python3 -c "import py_compile; py_compile.compile('scripts/otel-listener.py', doraise=True)"

# Validate shell syntax
bash -n scripts/*.sh

# Validate JS syntax
node -c hooks/*.js

# Test state mapping — source and call state_to_osc()
bash -c 'source scripts/otel-watcher.sh; state_to_osc "calling_llm"'

# Test proceed hooks — create temp state file and run
echo "tool_running" > /tmp/ghostty-indicator-state-test.txt
GHOSTTY_OTEL_STATE_DIR=/tmp bash scripts/proceed-by-state.sh test
```

### PR Checklist

- [ ] All syntax checks pass (Python, shell, JS)
- [ ] `hooks.json` is valid JSON
- [ ] Tested with `sync-and-restart.sh` — listener and watcher restart cleanly
- [ ] No hardcoded paths or credentials
- [ ] Commit messages follow conventional commits

## Performance

- **OTEL listener**: <5ms per span (file I/O)
- **Watcher poll**: 100ms interval, 3s keep-alive
- **Prompt submit**: <50ms (OSC emit + PID check)
- **State writes**: atomic via tmp + rename
- **tmux**: automatic DCS wrapping when `$TMUX` is set

## Troubleshooting

**Indicator not showing?**
1. Check listener is running: `cat /tmp/ghostty-otel.pid && kill -0 $(cat /tmp/ghostty-otel.pid)`
2. Check watcher is running: `cat /tmp/ghostty-watcher-$(tty | xargs basename).pid`
3. Check state file: `cat /tmp/ghostty-indicator-state-$(tty | xargs basename).txt`

**State stuck at `idle` (no transitions)?**
1. Check SID mapping exists: `ls /tmp/ghostty-sid-$(tty | xargs basename)`
2. If missing, restart the session — SessionStart hook recreates it
3. Check listener log: `tail -20 /tmp/ghostty-otel.log`

**Indicator flashing OFF briefly?**
- The HoldTimer should prevent this. If it still happens, the upstream API may be very slow (>10 min). Increase `GHOSTTY_OTEL_LLM_MAX_REARMS`.

**Multiple sessions showing same state?**
- Session key is derived from TTY. Run `tty` in each terminal to verify they differ.

**Agent stopped mid-task?**
- The anti-stall system should auto-proceed. Check watcher log: `tail -20 /tmp/ghostty-watcher-$(tty | xargs basename).log`
- If `subagent_idle` persists, verify `anti-stall.sh` and `subagent-proceed.sh` are in the plugin hooks

## License

MIT
