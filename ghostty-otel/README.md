# ghostty-otel

OpenTelemetry-based indicator control for the [Ghostty](https://ghostty.org) terminal.

Receives Claude Code's OTEL spans in real time and **directly controls the Ghostty indicator** via OSC 9;4 sequences — providing sub-5ms indicator response with rich metadata about what Claude is doing.

## What It Detects

| OTEL Span | State | OSC Code | Indicator |
|-----------|-------|----------|-----------|
| `claude_code.llm_request` | `calling_llm` | `3` (busy) | ON |
| `claude_code.tool` | `tool_running` | `3` (busy) | ON |
| `claude_code.tool.execution` | `tool_exec` | `3` (busy) | ON |
| `claude_code.tool.blocked_on_user` | `waiting_input` | `0` (clear) | OFF |
| `claude_code.interaction` | `idle` | `0` (clear) | OFF |

## Architecture

```
OTEL spans ──▶ otel-listener.py ──┬── OSC 9;4 ──▶ Ghostty indicator (PRIMARY)
                                   ├── .json state file (rich metadata)
                                   ├── .txt state file  (plain text compat)
                                   ├── sentinel file    (heartbeat compat)
                                   ├── heartbeat thread (re-emit every 3s)
                                   └── watchdog thread  (liveness signal)

Hooks ──▶ ghostty-state.sh (COMPLEMENT only):
  PreCompact       → keepalive (OTEL doesn't see compaction)
  PostToolUseFail  → error indicator (red)
  SessionStart     → clear indicator + start OTEL listener
  SessionEnd       → done (safety net)
  Notification     → done (faster than OTEL idle span)
```

`prompt-submit.sh` emits OSC 9;4;3 immediately on user input — covers the gap before the first OTEL span arrives.

## State Files

Each session writes to `${STATE_DIR}/ghostty-indicator-state-${SESSION_KEY}`:

| File | Format | Purpose |
|------|--------|---------|
| `.json` | `{"state":"calling_llm","ts":"...","meta":{"model":"..."}}` | Rich metadata for external consumers |
| `.txt` | `working\n` or `done\n` | Plain text for ghostty-state.sh backward compat |

## Installation

```bash
claude plugin add kianwoonwong/ghostty-otel
```

That's it. The plugin auto-configures OTEL telemetry. **No manual settings.json edits needed.**

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GHOSTTY_OTEL_PORT` | `4318` | OTLP HTTP server port |
| `GHOSTTY_OTEL_STATE_DIR` | `/tmp` | Directory for state files |
| `GHOSTTY_OTEL_LOG` | (empty) | Log file path (empty = no logging) |

### Session Key

Derived from TTY device — ensures multiple Claude Code sessions in different terminals get independent indicators:
- `tty` command → basename of `/dev/pts/N` or `/dev/ttysNNN`
- Falls back to `ps -o tty=` → basename
- Falls back to `"tty"`

## Performance

- **OTEL listener**: <5ms per span (file I/O + OSC emit)
- **OSC emission**: direct TTY write (no subprocess)
- **State writes**: atomic via tmp+rename
- **Heartbeat**: daemon thread re-emits OSC every 3s while active
- **Watchdog**: writes timestamp every 10s — other processes can detect dead listener
- **prompt-submit.sh**: <50ms (file I/O + OSC emit, no subprocess)
- **tmux passthrough**: automatic DCS wrapping when `TMUX` is set

## License

MIT
