#!/usr/bin/env python3
"""
OTEL State Listener for Ghostty Terminal Indicator
Receives Claude Code's OTEL spans and writes per-session state files.
Multi-session aware: routes spans to correct session via session.id attribute.

State transitions:
  claude_code.llm_request           → calling_llm
  claude_code.tool                  → tool_running
  claude_code.tool.execution        → tool_exec
  claude_code.tool.blocked_on_user  → waiting_input
  claude_code.interaction           → idle
"""

import json
import os
import sys
import signal
import time
import threading
import glob
import http.server
import socketserver

PORT = int(os.environ.get("GHOSTTY_OTEL_PORT", "4318"))
STATE_DIR = os.environ.get("GHOSTTY_OTEL_STATE_DIR", "/tmp")
LOG_FILE = os.environ.get("GHOSTTY_OTEL_LOG", "")
MAX_LOG_BYTES = 300
BUSY_HOLD_SECONDS = float(os.environ.get("GHOSTTY_OTEL_HOLD_SECONDS", "60"))
# Maximum LLM-pending re-arms before forcing idle (safety net).
# Each re-arm adds BUSY_HOLD_SECONDS. 10 × 60s = 10min max wait.
LLM_PENDING_MAX_REARMS = int(os.environ.get("GHOSTTY_OTEL_LLM_MAX_REARMS", "10"))
LOOP_THRESHOLD = int(os.environ.get("GHOSTTY_OTEL_LOOP_THRESHOLD", "5"))

SPAN_STATE_MAP = {
    "claude_code.llm_request": "calling_llm",
    "claude_code.tool": "tool_running",
    "claude_code.tool.blocked_on_user": "waiting_input",
    "claude_code.tool.execution": "tool_exec",
    "claude_code.interaction": "idle",
}


# session.id → session_key mapping (in-memory, refreshed from disk)
_sid_map_lock = threading.Lock()
_sid_map = {}  # session_id → session_key
_sid_map_mtime = 0  # last scan time


class HoldTimer:
    """Per-session hold timer for idle suppression.

    LLM-pending aware: when the last busy span was calling_llm (no
    subsequent tool/input span), the timer re-arms instead of flushing
    idle. This prevents premature idle during slow upstream API calls.

    Tracks _last_completed: set True on done/waiting_input, False on busy.
    When idle arrives and _last_completed is False + _has_been_busy True,
    the state is subagent_idle (stale — subagent went idle mid-task).
    """
    def __init__(self):
        self._lock = threading.Lock()
        self._busy_until = 0.0
        self._has_been_busy = False
        self._defer_timer = None
        self._safety_timer = None
        self._session_key = None  # set when first used
        self._llm_pending = False  # True after calling_llm, cleared by tool/input
        self._llm_rearms = 0       # re-arm counter (safety cap)
        self._last_completed = False  # True when done/waiting_input; False when busy

    def update(self, is_busy: bool, session_key: str, is_llm: bool = False):
        with self._lock:
            if not self._session_key:
                self._session_key = session_key
            if is_busy:
                self._has_been_busy = True
                self._last_completed = False
                self._busy_until = time.monotonic() + BUSY_HOLD_SECONDS
                if is_llm:
                    self._llm_pending = True
                    self._llm_rearms = 0
                else:
                    # tool_running / tool_exec → LLM responded, clear pending
                    self._llm_pending = False
                    self._llm_rearms = 0
                if self._defer_timer:
                    self._defer_timer.cancel()
                    self._defer_timer = None
                # Safety net: force idle if no new busy spans arrive
                if self._safety_timer:
                    self._safety_timer.cancel()
                self._safety_timer = threading.Timer(
                    BUSY_HOLD_SECONDS, self._flush_idle
                )
                self._safety_timer.daemon = True
                self._safety_timer.start()
            else:
                if not self._has_been_busy:
                    return True, self._has_been_busy, self._last_completed
                if time.monotonic() < self._busy_until:
                    delay = self._busy_until - time.monotonic()
                    if self._defer_timer:
                        self._defer_timer.cancel()
                    self._defer_timer = threading.Timer(delay, self._flush_idle)
                    self._defer_timer.daemon = True
                    self._defer_timer.start()
                    return True, self._has_been_busy, self._last_completed
                # Hold period expired — cancel safety timer, caller writes idle
                if self._safety_timer:
                    self._safety_timer.cancel()
                    self._safety_timer = None
        return False, self._has_been_busy, self._last_completed

    def _flush_idle(self):
        with self._lock:
            self._defer_timer = None
            self._safety_timer = None
            key = self._session_key
            llm_pending = self._llm_pending
            rearms = self._llm_rearms
            has_been_busy = self._has_been_busy
            last_completed = self._last_completed
        if not key:
            return
        # LLM pending: re-arm timer instead of flushing idle.
        # Claude sent idle span but LLM response hasn't arrived yet.
        # Keep re-arming until a tool/input span clears _llm_pending,
        # or we hit the safety cap (prevents orphan busy state forever).
        if llm_pending and rearms < LLM_PENDING_MAX_REARMS:
            # Guard: check if stop hook or external agent already set idle.
            # Don't re-arm if state file already shows idle/waiting_input/done.
            state_file = f"{STATE_DIR}/ghostty-indicator-state-{key}.txt"
            try:
                with open(state_file, "r") as f:
                    current = f.read().strip().split(":")[0]
                if current in ("idle", "waiting_input", "done", "completed", "subagent_idle"):
                    # External authority (stop hook) cleared the state —
                    # stop re-arming and cancel the pending flag.
                    with self._lock:
                        self._llm_pending = False
                        self._llm_rearms = 0
                    return
            except (OSError, IOError):
                pass
            with self._lock:
                self._llm_rearms = rearms + 1
                self._safety_timer = threading.Timer(
                    BUSY_HOLD_SECONDS, self._flush_idle
                )
                self._safety_timer.daemon = True
                self._safety_timer.start()
            return
        # Guard: don't stomp on waiting_input or already-idle states
        state_file = f"{STATE_DIR}/ghostty-indicator-state-{key}.txt"
        try:
            with open(state_file, "r") as f:
                current = f.read().strip().split(":")[0]
            if current in ("idle", "waiting_input", "completed", "subagent_idle"):
                return
        except (OSError, IOError):
            pass
        # Detect stale idle: busy→idle without completion marker
        if has_been_busy and not last_completed:
            write_state("subagent_idle", {}, key)
        else:
            write_state("idle", {}, key)

    def clear_timers(self):
        with self._lock:
            if self._defer_timer:
                self._defer_timer.cancel()
                self._defer_timer = None
            if self._safety_timer:
                self._safety_timer.cancel()
                self._safety_timer = None

    def mark_completed(self):
        with self._lock:
            self._last_completed = True


# Per-session hold timers: session_id → HoldTimer
_hold_timers_lock = threading.Lock()
_hold_timers = {}

# Per-session consecutive-tool tracking for loop detection
# session_key → {"tool": tool_name, "count": int}
_consecutive_tools_lock = threading.Lock()
_consecutive_tools = {}


def get_hold_timer(session_id: str) -> HoldTimer:
    with _hold_timers_lock:
        if session_id not in _hold_timers:
            _hold_timers[session_id] = HoldTimer()
        return _hold_timers[session_id]


def check_loop(tool_name: str, session_key: str) -> bool:
    """Track consecutive same-tool executions. Returns True if looping."""
    with _consecutive_tools_lock:
        entry = _consecutive_tools.get(session_key)
        if entry and entry["tool"] == tool_name:
            entry["count"] += 1
        else:
            _consecutive_tools[session_key] = {"tool": tool_name, "count": 1}
        return _consecutive_tools[session_key]["count"] >= LOOP_THRESHOLD


def refresh_sid_map():
    """Scan /tmp/ghostty-sid-* files to build session.id → session_key mapping."""
    global _sid_map, _sid_map_mtime
    now = time.monotonic()
    # Refresh at most once per second
    if now - _sid_map_mtime < 1.0:
        return
    with _sid_map_lock:
        _sid_map_mtime = now
        for f in glob.glob(f"{STATE_DIR}/ghostty-sid-*"):
            try:
                sk = os.path.basename(f).replace("ghostty-sid-", "", 1)
                with open(f, "r") as fh:
                    sid = fh.read().strip()
                if sid and sk:
                    _sid_map[sid] = sk
            except (OSError, IOError):
                pass


def get_session_key(session_id: str) -> str:
    """Look up session_key from session.id. Returns None if unregistered."""
    refresh_sid_map()
    with _sid_map_lock:
        if session_id in _sid_map:
            return _sid_map[session_id]
    return None


def write_state(state: str, meta: dict, session_key: str):
    """Write state to per-session file."""
    if not session_key:
        return
    # Build rich state text
    rich = state
    if meta:
        parts = []
        for k in ("tool", "model", "success"):
            if k in meta and meta[k]:
                parts.append(str(meta[k]))
        if parts:
            rich = f"{state}:{':'.join(parts)}"

    txt_path = f"{STATE_DIR}/ghostty-indicator-state-{session_key}.txt"
    tmp_path = txt_path + ".tmp"
    try:
        with open(tmp_path, "w") as f:
            f.write(rich + "\n")
        os.rename(tmp_path, txt_path)
    except (OSError, IOError):
        pass

    if LOG_FILE:
        try:
            # Rotate: keep last MAX_LOG_BYTES, snap to first newline to avoid partial lines
            try:
                size = os.path.getsize(LOG_FILE)
                if size > MAX_LOG_BYTES:
                    with open(LOG_FILE, "r") as f:
                        content = f.read()
                    # Take last MAX_LOG_BYTES, skip first (partial) line
                    chunk = content[-(MAX_LOG_BYTES):]
                    nl_pos = chunk.find("\n")
                    if nl_pos >= 0:
                        kept = chunk[nl_pos + 1:]  # skip partial first line
                    else:
                        kept = chunk
                    with open(LOG_FILE, "w") as f:
                        f.write(kept)
            except (OSError, IOError):
                pass
            with open(LOG_FILE, "a") as f:
                f.write(f"[{session_key}] {rich}\n")
        except (OSError, IOError):
            pass


def extract_span_info(span: dict) -> tuple:
    """Extract span name and attributes."""
    name = span.get("name", "")
    attrs = {}
    for attr in span.get("attributes", []):
        key = attr.get("key", "")
        val = attr.get("value", {})
        if "stringValue" in val:
            attrs[key] = val["stringValue"]
        elif "intValue" in val:
            attrs[key] = val["intValue"]
        elif "boolValue" in val:
            attrs[key] = val["boolValue"]
    return name, attrs


class OTLPHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _respond(self, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def _handle(self):
        try:
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
                            try:
                                name, attrs = extract_span_info(span)
                                state = SPAN_STATE_MAP.get(name)
                                if not state:
                                    continue

                                # Route to correct session
                                sid = attrs.get("session.id", "")
                                sk = get_session_key(sid) if sid else None
                                if not sk:
                                    continue  # No session registered yet

                                timer = get_hold_timer(sid)

                                if state == "idle":
                                    # Guard: don't overwrite a busy state that was
                                    # set by prompt-submit.sh for a NEW turn.
                                    # OTEL spans arrive AFTER completion, so a
                                    # previous turn's idle span can race with the
                                    # new turn's prompt-submit writing calling_llm.
                                    state_file = f"{STATE_DIR}/ghostty-indicator-state-{sk}.txt"
                                    try:
                                        with open(state_file, "r") as sf:
                                            current = sf.read().strip().split(":")[0]
                                        if current in ("calling_llm", "tool_running",
                                                       "tool_exec", "working",
                                                       "subagent_idle"):
                                            # New turn already started — discard
                                            # stale idle from previous turn
                                            continue
                                    except (OSError, IOError):
                                        pass
                                    # Idle: defer through HoldTimer to prevent
                                    # premature idle between LLM responses
                                    deferred, has_been_busy, last_completed = timer.update(False, sk)
                                    if not deferred:
                                        # Hold expired — detect stale idle vs clean idle
                                        if has_been_busy and not last_completed:
                                            # Busy→idle without done: subagent stalled
                                            write_state("subagent_idle", attrs, sk)
                                        else:
                                            # Clean idle (task completed normally)
                                            write_state(state, attrs, sk)
                                    # else: HoldTimer will flush_idle later
                                elif state == "waiting_input":
                                    # waiting_input always wins — it's the latest lifecycle state.
                                    # No guard needed: overwriting tool_running is correct behavior.
                                    timer.clear_timers()
                                    timer.mark_completed()
                                    write_state(state, attrs, sk)
                                elif state == "calling_llm":
                                    # OTEL llm_request spans arrive AFTER completion.
                                    # Writing calling_llm shows stale state - don't do it.
                                    # Just update HoldTimer to keep indicator busy.
                                    # The actual calling_llm state comes from prompt-submit.sh.
                                    timer.update(True, sk, is_llm=True)
                                else:
                                    # tool_running, tool_exec → write normally
                                    timer.update(True, sk, is_llm=False)
                                    tool_name = attrs.get("tool.name", "")
                                    if tool_name and check_loop(tool_name, sk):
                                        write_state("looping", {"tool": tool_name}, sk)
                                    else:
                                        write_state(state, attrs, sk)
                            except Exception:
                                pass
        except Exception:
            pass
        finally:
            self._respond()

    def do_POST(self):
        self._handle()

    def do_GET(self):
        self._handle()


class ReusableTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    allow_reuse_port = True
    daemon_threads = True


def main():
    def shutdown(signum, frame):
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Clean stale busy states from previous listener crash
    for f in glob.glob(f"{STATE_DIR}/ghostty-indicator-state-*.txt"):
        try:
            with open(f, "r") as fh:
                content = fh.read().strip()
            base = content.split(":")[0] if content else ""
            if base in ("calling_llm", "tool_running", "tool_exec", "working", "tool"):
                with open(f, "w") as fh:
                    fh.write("idle\n")
        except (OSError, IOError):
            pass

    # Clean orphan state files without .txt extension
    for f in glob.glob(f"{STATE_DIR}/ghostty-indicator-state-*"):
        if not f.endswith(".txt") and not f.endswith(".tmp"):
            try:
                os.remove(f)
            except OSError:
                pass

    with ReusableTCPServer(("", PORT), OTLPHandler) as httpd:
        print(f"ghostty-otel listening on :{PORT} (multi-session)", flush=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
