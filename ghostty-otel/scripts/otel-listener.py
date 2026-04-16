#!/usr/bin/env python3
"""
OTEL State Listener for Ghostty Terminal Indicator
Receives Claude Code's OTEL spans and writes state to a shared file.

State transitions:
  claude_code.llm_request           → calling_llm (thinking/generating)
  claude_code.tool                  → tool_running  (tool_name extracted)
  claude_code.tool.blocked_on_user  → waiting_input
  claude_code.tool.execution        → tool_exec (with success/failure)
  claude_code.interaction           → idle (turn complete)

Performance budget: <5ms per span (just file I/O).
"""

import json
import os
import sys
import signal
import http.server
import socketserver
from datetime import datetime
from pathlib import Path

# --- Configuration ---
PORT = int(os.environ.get("GHOSTTY_OTEL_PORT", "4318"))
STATE_DIR = os.environ.get("GHOSTTY_OTEL_STATE_DIR", "/tmp")
SESSION_KEY = os.environ.get("GHOSTTY_OTEL_SESSION_KEY", "")
LOG_FILE = os.environ.get("GHOSTTY_OTEL_LOG", "")

# State file paths
# Primary state: ghostty-indicator-state-{SESSION_KEY} (ghostty-state.sh writes this)
# LLM-active: ghostty-llm-active-{SESSION_KEY} (OTEL listener writes this, heartbeat reads)
if SESSION_KEY:
    STATE_FILE = f"{STATE_DIR}/ghostty-indicator-state-{SESSION_KEY}"
    LLM_ACTIVE_FILE = f"{STATE_DIR}/ghostty-llm-active-{SESSION_KEY}"
else:
    STATE_FILE = f"{STATE_DIR}/ghostty-otel-state"
    LLM_ACTIVE_FILE = f"{STATE_DIR}/ghostty-otel-llm-active"

HEARTBEAT_FILE = f"{STATE_DIR}/ghostty-otel-heartbeat"

# --- State machine ---
SPAN_STATE_MAP = {
    "claude_code.llm_request": "calling_llm",
    "claude_code.tool": "tool_running",
    "claude_code.tool.blocked_on_user": "waiting_input",
    "claude_code.tool.execution": "tool_exec",
    "claude_code.interaction": "idle",
}


def write_state(state: str, meta: dict = None):
    """Write OTEL state to LLM-active file (heartbeat reads this).
    Also updates the primary ghostty state file for OSC 9;4 emission."""

    entry = {
        "state": state,
        "ts": datetime.now().isoformat(),
    }
    if meta:
        entry["meta"] = meta

    ts = datetime.now().isoformat()

    # 1. Write LLM-active file (this is what the heartbeat polls)
    #    Only update for LLM-calling states; clear on idle/waiting.
    if state == "calling_llm":
        Path(LLM_ACTIVE_FILE).touch()
    elif state in ("waiting_input", "idle"):
        # Clear the LLM-active file when Claude stops calling LLM
        try:
            os.remove(LLM_ACTIVE_FILE)
        except FileNotFoundError:
            pass

    # 2. Also write to ghostty state file for OSC 9;4 emission
    #    Only set state if hooks haven't already set a more specific one.
    if state == "calling_llm":
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(entry, f)
        os.rename(tmp, STATE_FILE)

    # 3. Log if configured
    if LOG_FILE:
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")


def extract_span_info(span: dict) -> tuple:
    """Extract span name and key attributes."""
    name = span.get("name", "")
    attrs = {}
    for attr in span.get("attributes", []):
        key = attr.get("key", "")
        val = attr.get("value", {})
        # Unwrap the typed value
        if "stringValue" in val:
            attrs[key] = val["stringValue"]
        elif "intValue" in val:
            attrs[key] = val["intValue"]
        elif "doubleValue" in val:
            attrs[key] = val["doubleValue"]
        elif "boolValue" in val:
            attrs[key] = val["boolValue"]
    return name, attrs


class OTLPHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging

    def _respond(self, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def _handle(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length > 0 else b""

        if not body:
            self._respond()
            return

        try:
            data = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._respond()
            return

        # Process traces
        if "resourceSpans" in data:
            for rs in data["resourceSpans"]:
                for ss in rs.get("scopeSpans", []):
                    for span in ss.get("spans", []):
                        name, attrs = extract_span_info(span)
                        state = SPAN_STATE_MAP.get(name)
                        if state:
                            meta = {}
                            if state == "calling_llm":
                                meta["model"] = attrs.get("model", "")
                                meta["ttft_ms"] = attrs.get("ttft_ms", "")
                            elif state == "tool_running":
                                meta["tool"] = attrs.get("tool_name", "")
                            elif state == "tool_exec":
                                meta["success"] = attrs.get("success", "")
                            write_state(state, meta)

        self._respond()

    def do_POST(self):
        self._handle()

    def do_GET(self):
        self._handle()


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True
    allow_reuse_port = True


def main():
    # Graceful shutdown
    def shutdown(signum, frame):
        write_state("idle", {"reason": "shutdown"})
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Write initial state
    write_state("idle", {"reason": "listener_start"})

    with ReusableTCPServer(("", PORT), OTLPHandler) as httpd:
        print(f"ghostty-otel listening on :{PORT}", flush=True)
        print(f"state file: {STATE_FILE}", flush=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass

    write_state("idle", {"reason": "listener_stop"})


if __name__ == "__main__":
    main()
