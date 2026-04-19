# ghostty-otel
<img width="1536" height="1024" alt="ChatGPT Image Apr 17, 2026, 03_46_44 AM" src="https://github.com/user-attachments/assets/4d76b8a7-6f07-4b03-b1e2-aec4d0ad6a18" />

Real-time visibility into Claude Code's internal state for the [Ghostty](https://ghostty.org) terminal.

Receives Claude Code's OpenTelemetry spans and drives **Ghostty's progress indicator** (OSC 9;4) and **window title** (OSC 2) in real time — so you always know what the AI agent is doing, even when you're not looking at the terminal.

## Why This Exists

Claude Code can run for minutes on complex tasks — calling LLMs, executing tools, running agents. Without visibility:

- You switch tabs and come back wondering: "Is Claude still working, or did it stall?"
- An idle agent goes unnoticed while you wait for a response that's never coming
- Tool failures happen silently while the indicator says everything is fine
- A subagent plans tasks but stops before executing any of them

**ghostty-otel solves this** by showing Claude's exact state in the terminal indicator and window title — updating in real time as the agent works. The three-layer anti-stall system ensures agents keep working on their assigned tasks.

## What You See

| Claude is... | Indicator | Window Title |
|-------------|-----------|--------------|
| Calling the LLM | Busy (spinning) | `claude: calling_llm:MiniMax-M2.7[1m]` |
| Running a tool | Busy (spinning) | `claude: tool_exec:Read` |
| Subagent stalled mid-task | Attention (red) | `claude: subagent_idle` |
| Waiting for user input | Attention (red) | `claude: waiting_input` |
| All tasks completed | Idle | `claude: completed` |
| Turn complete | Idle | `claude: idle` |

## How It Works

```
Claude Code ──OTEL spans──▶ otel-listener.py ──state files──▶ otel-watcher.sh ──OSC──▶ Ghostty
   │                              │                                │
   │                              ├── HoldTimer (60s)              ├── OSC 9;4 (progress bar)
   │                              ├── LLM-pending re-arm          └── OSC 2 (window title)
   │                              ├── Loop detection              └── Keep-alive (3s)
   │                              └── Multi-session routing
   │
   └── Hooks ──▶ Anti-stall system ──▶ agents keep working
```

### Core Features

**1. Anti-flapping HoldTimer**
- Idle spans from Claude Code are deferred for 60 seconds before being written to the state file
- Prevents the indicator from flashing OFF between LLM responses (Claude sends `idle` spans while still processing)

**2. LLM-pending re-arm**
- When the last busy span was `calling_llm` (no tool/input span followed), the timer re-arms instead of flushing idle
- Covers slow upstream API calls — indicator stays ON until the LLM actually responds
- Safety cap: 10 re-arms (10 minutes max) prevents orphan busy states

**3. Multi-session support**
- Routes spans to correct session via `session.id` attribute
- Each session gets independent state files and watcher process
- Session key derived from TTY device (ttys000, ttys002, etc.)

**4. Window title (OSC 2)**
- Shows exact state + metadata in terminal window title
- Examples: `claude: calling_llm:MiniMax-M2.7[1m]:True`, `claude: tool_exec:Read`

**5. Gap coverage**
- `UserPromptSubmit` hook emits OSC immediately on user input — covers the gap before the first OTEL span arrives (~100-200ms)

### Three-Layer Anti-Stall System

Claude Code agents sometimes stop prematurely — planning tasks without executing them, stalling mid-task, or yielding to user input when work remains. The anti-stall system prevents this with three independent layers:

**Layer 1: Task completion validator** (`stop-validator.sh`)
- Runs on `Stop` events
- Parses transcript for task list patterns (`N tasks (X done, Y open)`)
- Blocks stop when open tasks remain — forces Claude to keep working
- Also checks for tool errors + incomplete executions
- Guard: `stop_hook_active=true` allows stop to prevent infinite loops

**Layer 2: State-based auto-proceed** (`state-proceed.sh`)
- Runs on every `UserPromptSubmit` event
- Checks state file age: if `subagent_idle` for >60s or `waiting_input` for >90s
- Forces proceed with context message explaining why

**Layer 3: Anti-stall detector** (`anti-stall.sh`)
- Runs on `SubagentStop` events
- Detects "planning without executing" pattern (tasks created, no implementation tools run)
- Detects subagents that stopped without any real tool calls
- Injects continuation message: `"start implementing now"`

### Additional Features

**Loop detection**
- Tracks consecutive identical tool executions per session
- When same tool repeats `GHOSTTY_OTEL_LOOP_THRESHOLD` times (default 5) → `looping` state
- `looping` → OSC 2 (red attention), triggers auto-proceed hooks
- Configurable via `GHOSTTY_OTEL_LOOP_THRESHOLD` env var

**Watcher resilience**
- Max 3 listener restart attempts before graceful exit (prevents zombie watchers)
- Atomic `mkdir` lock prevents duplicate watchers per TTY
- Listener health check every 5s with automatic restart

**Session-aware notifications**
- `notification-done.sh` includes project name and TTY in notification subtitle
- Multi-session awareness — you know which session finished

## Installation

```bash
claude plugin add kianwoonwong/ghostty-otel
```

That's it. The plugin auto-configures OTEL telemetry via `settings.json`. No manual edits needed.

### What gets set up

| Component | Provided by |
|-----------|------------|
| OTEL telemetry config | Plugin's `.claude/settings.json` |
| OTEL listener (Python HTTP server) | `scripts/otel-listener.py` |
| Per-session watcher (OSC emitter) | `scripts/otel-watcher.sh` |
| Prompt submit hook (gap coverage) | `scripts/prompt-submit.sh` |
| Subagent auto-proceed hooks | `scripts/subagent-proceed.sh`, `scripts/teammate-proceed.sh`, `scripts/main-agent-proceed.sh` |
| Anti-stall system | `scripts/anti-stall.sh`, `scripts/state-proceed.sh` |
| Task completion validation | `scripts/stop-validator.sh`, `scripts/subagent-stop-validator.sh` |
| Session lifecycle hooks | `scripts/start-listener.sh`, `scripts/session-cleanup.sh` |
| Session key derivation | `scripts/session-key.sh` |

### Plugin hooks (auto-configured)

| Hook | Scripts | Purpose |
|------|---------|---------|
| `Stop` | `stop-validator.sh` | Validate task completeness + block premature stops |
| `StopFailure` | `main-agent-proceed.sh` | Auto-proceed main agent on stale idle |
| `SubagentStop` | `subagent-proceed.sh` + `anti-stall.sh` + `subagent-stop-validator.sh` | Fast state check + anti-stall + transcript completeness |
| `TeammateIdle` | `teammate-proceed.sh` | Auto-proceed stalled teammates |
| `SessionStart` | `start-listener.sh` | Start OTEL listener + per-session watcher |
| `UserPromptSubmit` | `prompt-submit.sh` + `state-proceed.sh` | Immediate OSC emit + state-based auto-proceed |
| `Notification` | `notification-done.sh` | Session-aware notifications (project + TTY) |
| `SessionEnd` | `session-cleanup.sh` | Clean up state files + watcher |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GHOSTTY_OTEL_PORT` | `4318` | OTLP HTTP server port |
| `GHOSTTY_OTEL_STATE_DIR` | `/tmp` | Directory for state files |
| `GHOSTTY_OTEL_HOLD_SECONDS` | `60` | Seconds to hold before writing idle |
| `GHOSTTY_OTEL_LLM_MAX_REARMS` | `10` | Max timer re-arms while LLM is pending |
| `GHOSTTY_OTEL_LOG` | (empty) | Log file path (empty = no logging) |
| `GHOSTTY_OTEL_WATCHER_LOG` | `/tmp/ghostty-watcher-{key}.log` | Per-session watcher log |
| `GHOSTTY_OTEL_LOOP_THRESHOLD` | `5` | Consecutive same-tool calls before `looping` state |

## State Files

Each session writes to `${GHOSTTY_OTEL_STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}.txt`:

```
calling_llm:MiniMax-M2.7[1m]:True
tool_exec:Read
tool_running:Bash
waiting_input
subagent_idle
looping:Bash
idle
```

Format: `state[:metadata...]` — one line, plain text.

## OTEL Span Mapping

| Claude Code Span | State | Indicator |
|-----------------|-------|-----------|
| `claude_code.llm_request` | `calling_llm` | ON (busy) |
| `claude_code.tool` | `tool_running` | ON (busy) |
| `claude_code.tool.execution` | `tool_exec` | ON (busy) |
| `claude_code.tool.blocked_on_user` | `waiting_input` | OFF (idle) |
| `claude_code.interaction` | `idle` | OFF (idle, after hold) |
| Stale idle (no completion) | `subagent_idle` | ON (osc=2, auto-proceed triggers) |
| Looping (repeated tool) | `looping` | ON (osc=2, auto-proceed triggers) |

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

**Indicator flashing OFF briefly?**
- The HoldTimer should prevent this. If it still happens, the upstream API may be very slow (>10 min). Increase `GHOSTTY_OTEL_LLM_MAX_REARMS`.

**Multiple sessions showing same state?**
- Session key is derived from TTY. Run `tty` in each terminal to verify they differ.

**Agent stopped mid-task?**
- The anti-stall system should auto-proceed. Check watcher log: `tail -20 /tmp/ghostty-watcher-$(tty | xargs basename).log`
- If `subagent_idle` persists, verify `anti-stall.sh` and `subagent-proceed.sh` are in the plugin hooks

## License

MIT
