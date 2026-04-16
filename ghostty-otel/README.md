# ghostty-otel

OpenTelemetry-based state detection for the [Ghostty](https://ghostty.org) terminal indicator.

Captures Claude Code's OTEL spans (`llm_request`, `tool` calls, `blocked_on_user`) to drive real-time busy/idle notification states — filling the gap where Claude Code hooks don't fire during extended thinking or API streaming.

## How It Works

```
Claude Code ──OTEL spans──▶ otl-listener.py ──state file──▶ ghostty-state.sh heartbeat ──▶ Ghostty indicator
```

### Detection Chain

1. **SessionStart hook** starts `otel-listener.py` (lightweight HTTP server on port 4318)
2. **Listener** receives OTEL spans from Claude Code and writes state to `/tmp/ghostty-llm-active-{SESSION_KEY}`
3. **Heartbeat** (in `ghostty-state.sh`) polls the LLM-active file every 3s
4. **Indicator** stays ON while LLM-active file exists, clears when Claude goes idle

### Supported States

| OTEL Span | State File | Indicator |
|-----------|-----------|-----------|
| `claude_code.llm_request` | `llm-active` created | ON (busy) |
| `claude_code.tool` | state updated | ON (busy) |
| `claude_code.tool.blocked_on_user` | `llm-active` removed | OFF (idle) |
| `claude_code.interaction` | `llm-active` removed | OFF (idle) |

## Prerequisites

- [Ghostty](https://ghostty.org) terminal emulator
- Claude Code CLI
- Python 3 (for `otel-listener.py`)
- `ghostty-state.sh` hook system (part of [ghostty-claude-hooks](https://github.com/kianwoonwong/ghostty-claude-hooks))

## Installation

1. Install as a Claude Code plugin:
   ```bash
   claude plugin add kianwoonwong/ghostty-otel
   ```

2. Ensure `ghostty-state.sh` is configured with OTEL LLM-active file detection (the heartbeat checks `/tmp/ghostty-llm-active-{SESSION_KEY}`).

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GHOSTTY_OTEL_PORT` | `4318` | OTLP HTTP server port |
| `GHOSTTY_OTEL_STATE_DIR` | `/tmp` | Directory for state files |
| `GHOSTTY_OTEL_LOG` | (empty) | Log file path (empty = no logging) |

### Session Key

Derived from TTY device (same as `ghostty-state.sh`):
- `tty` command → basename of `/dev/pts/N` or `/dev/ttysNNN`
- Falls back to `ps -o tty=` → basename
- Falls back to `"tty"`

This ensures multiple Claude Code sessions in different terminals get independent indicators.

## Architecture

```
┌─────────────┐    OTEL spans     ┌──────────────────┐    state file    ┌──────────────────┐
│ Claude Code  │ ───────────────▶ │ otl-listener.py  │ ──────────────▶ │ /tmp/ghostty-*   │
│ (OTEL SDK)   │  :4318 HTTP/JSON │ (OTLP receiver)  │  llm-active flag │ (heartbeat reads) │
└─────────────┘                   └──────────────────┘                  └──────────────────┘
                                                                            │
                                                                            ▼
                                                                   ┌──────────────────┐
                                                                   │ ghostty-state.sh  │
                                                                   │ heartbeat loop    │
                                                                   │ → OSC 9;4 emit   │
                                                                   └──────────────────┘
```

## Performance

- **OTEL listener**: <5ms per span (file I/O only)
- **Heartbeat check**: stat() syscall (~1ms) every 3s
- **No blocking**: Listener is async HTTP server, state writes are atomic (tmp+rename)
- **Auto-cleanup**: Listener exits on SIGTERM/SIGINT, removes state files on shutdown

## License

MIT
