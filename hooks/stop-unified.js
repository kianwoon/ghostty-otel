#!/usr/bin/env node

/**
 * Unified Stop/StopFailure Hook (v4)
 *
 * Combines recovery + audio announcement + ghostty indicator management.
 *
 * Handles Stop and StopFailure events:
 *   - Context limit → auto-compact (osascript via detached subshell)
 *   - Crash/network error → auto-continue (osascript via detached subshell)
 *   - Audio announcement on completion
 *   - Ghostty indicator cleared on all exit paths
 *
 * Priority order (short-circuits on first match):
 *   0. stop_hook_active → no-op (another stop handler is active)
 *   1. StopFailure → allow (no recovery)
 *   2. Empty message → allow
 *   3. Completion markers → allow + announce
 *   4. Max blocks reached → allow + announce
 *   5. Context limit → auto-compact (detached, survives exit)
 *   6. Crash/network error → auto-continue (detached, survives exit)
 *   7. Incomplete intent → auto-continue (agent announced work but didn't dispatch it)
 *   8. Default → allow + announce
 *
 * Exit codes:
 *   0 → allow stop (or fire-and-forget recovery launched)
 *   2 → block stop with feedback (reserved for future detector use)
 */

var fs = require('fs');
var path = require('path');
var os = require('os');
var childProcess = require('child_process');

// ── Configuration ────────────────────────────────────────────────

var MAX_BLOCKS = 3;
var _home = process.env.STALL_HOOK_STATE_DIR || os.homedir();
var STATE_FILE = path.join(_home, '.claude', 'state', 'stop-unified-state.json');
var STATE_TTL_MS = 3600000;

// Recovery cooldowns
var COOLDOWN_CONTINUE_MS = 30000;
var COOLDOWN_COMPACT_MS = 60000;
var COOLDOWN_INCOMPLETE_MS = 30000;
var DELAY_CONTINUE_S = 5;
var DELAY_COMPACT_S = 3;
var MAX_INCOMPLETE_RECOVERIES = 3;

var PERMISSIONS_MARKER = path.join(_home, '.claude', 'state', '.osascript-ok');

// ── Shared patterns ──────────────────────────────────────────────

var CRASH_PATTERNS = [
  'undefined is not an object',
  'cannot read property',
  'cannot read properties',
  'uncaught exception',
  'typeerror:',
  'referenceerror:',
  'socket connection was closed',
  'socket hang up',
  'econnreset',
  'econnrefused',
  'fetch failed',
  'network error',
  'unexpected end of stream',
  'api error'
];

var CONTEXT_LIMIT_PATTERNS = [
  'context window',
  'context length',
  'context limit',
  'token limit',
  'max tokens',
  'max_output_tokens',
  'maximum context',
  'too many tokens',
  'exceeds maximum',
  'context_length_exceeded',
  'reduce the length'
];

var COMPLETION_MARKERS = [
  /\[COMPLETE\]/i,
  /\[QUALITY\s+\d/i,
  /\[PROGRESS\s+\d\/\d\]/i,
  /(?:all |every )?(?:test|check|step|task)s?\s+(?:pass|complete|done|finish)/i,
  /(?:no |zero )?(?:error|warning|failure|issue)s?\s*(?:found|reported|remaining)?$/i,
  /(?:build|compile|lint|deploy|commit|merge)\s+(?:succeed|pass|complete|done)/i,
  /task completed/i,
  /changes applied/i,
];

// ── Incomplete Intent Detection ──────────────────────────────────
// Patterns: agent announced work but didn't dispatch it (or only
// dispatched a tiny fraction). Detects mid-generation stalls where
// the agent said "Let me do X" then stopped without completing X.
var INCOMPLETE_INTENT_PATTERNS = [
  // Announced multi-step work but stopped
  /(?:let me|i'll|i will|now i'll|starting|launching|creating|building|fixing|implementing|adding|setting up)\s+\S.{10,}(?:\s+and\s+|\s+then\s+|\s+,\s+|$)/i,
  // Trailing incomplete sentences — colon, ellipsis, or sentence that just ends mid-flow
  /:\s*$/m,
  /…\s*$/m,
  /(?:and|then|also|next|after that|finally)\s*$/mi,
  // Numbered/bulleted lists that get cut off mid-list
  /^\s*\d+[.)]\s+\S.{5,50}(?:\s+[a-z]\s*$|$)/mi,
  // "In parallel" or "using agents" but no Agent tool_use seen
  /(?:in parallel|using (?:\d+ )?agents?|spawning (?:\d+ )?agents?)\b/i,
  // Open brace/bracket that was never closed suggesting incomplete thought
  /,\s*$/m,
];

// For the announced-action vs actual-action check
var AGENT_ANNOUNCE_PATTERNS = [
  /let me\s+(?:fix|build|create|add|set up|implement|update|change|modify|rewrite|refactor|test|check|run|launch|spawn)/i,
  /i('ll| will)\s+(?:fix|build|create|add|set up|implement|update|change|modify|rewrite|refactor|test|run|launch|spawn)/i,
  /now\s+(?:i('ll| will)|let me)/i,
  /launching\s+\S.{0,30}\s+(?:agents?|subagent|workers?)/i,
  /spawning\s+\S.{0,30}\s+(?:agents?|subagent|workers?)/i,
  /using\s+(?:\d+\s+)?(?:agents?|subagent|workers?)/i,
  /in parallel/i,
  /starting\s+(?:with\s+)?(?:\d+\s+)?(?:agents?|workers?|tasks?)/i,
];

// Tool names that would indicate the announced work was actually dispatched
var AGENT_TOOL_NAMES = ['Agent', 'Task', 'SendMessage'];

// ── Ghostty state ─────────────────────────────────────────────────

function setGhosttyState(state) {
  // Write state to per-session ghostty-otel state file.
  // Derive session key from env, TTY, or session-key.sh fallback.
  try {
    var sid = process.env.GHOSTTY_OTEL_SESSION_KEY || '';
    if (!sid) {
      var tty = process.env.GHOSTTY_OTEL_TTY || '';
      if (tty) {
        sid = path.basename(tty).replace(/[^a-zA-Z0-9_-]/g, '');
      }
    }
    if (!sid) {
      // Fallback: try session-key.sh
      var result = childProcess.spawnSync('bash', [
        '-c', 'bash "${CLAUDE_PLUGIN_ROOT:-$HOME/Downloads/ghostty-otel}/scripts/session-key.sh" 2>/dev/null | sed -n "2p"'
      ], { timeout: 3000 });
      sid = (result.stdout || '').toString().trim();
    }
    if (!sid) return;
    var stateDir = process.env.GHOSTTY_OTEL_STATE_DIR || '/tmp';
    var stateFile = path.join(stateDir, 'ghostty-indicator-state-' + sid + '.txt');
    var tmpFile = stateFile + '.tmp.' + process.pid;
    fs.writeFileSync(tmpFile, state + '\n');
    fs.renameSync(tmpFile, stateFile);
  } catch (_) { /* best-effort */ }
}

// ── Helpers ──────────────────────────────────────────────────────

/**
 * Fire-and-forget `say` that survives parent exit.
 * Uses nohup + detached subshell so the speech process is fully orphaned
 * and won't be cut off when the parent hook process exits.
 */
function sayAsync(text) {
  try {
    var escaped = text.replace(/'/g, "'\\''");
    childProcess.spawn('bash', ['-c', 'nohup say "' + escaped + '" >/dev/null 2>&1 &'], {
      stdio: 'ignore', detached: true
    }).unref();
  } catch (_) { /* best-effort */ }
}

function readStdin() {
  return new Promise(function (resolve) {
    var data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', function (chunk) { data += chunk; });
    process.stdin.on('end', function () { resolve(data.trim()); });
    process.stdin.on('error', function () { resolve(''); });
  });
}

function matchesAny(text, patterns) {
  var lower = (text || '').toLowerCase();
  return patterns.some(function (p) { return lower.indexOf(p) !== -1; });
}

/**
 * Normalize last_assistant_message to a string.
 * Handles: string, { content: string }, { content: [...] }
 */
function extractText(msg) {
  if (typeof msg === 'string') return msg;
  if (!msg || typeof msg !== 'object') return '';
  if (typeof msg.content === 'string') return msg.content;
  if (Array.isArray(msg.content)) {
    return msg.content.map(function (block) {
      if (!block) return '';
      if (typeof block === 'string') return block;
      if (block.type === 'text' && block.text) return block.text;
      return '';
    }).join(' ');
  }
  return '';
}

// ── State management ─────────────────────────────────────────────

function loadState() {
  try {
    var all = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    var cutoff = Date.now() - STATE_TTL_MS;
    Object.keys(all).forEach(function (k) {
      if (k === 'recovery') return;
      if (all[k].lastBlock && all[k].lastBlock < cutoff) delete all[k];
    });
    if (!all.recovery) {
      all.recovery = { lastRecover: 0, count: 0, lastCompact: 0, compactCount: 0 };
    }
    return all;
  } catch (_) {
    return {
      recovery: { lastRecover: 0, count: 0, lastCompact: 0, compactCount: 0 }
    };
  }
}

function saveState(state) {
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify(state), 'utf8');
  } catch (_) { /* best-effort */ }
}

// ── osascript ────────────────────────────────────────────────────

function checkOsascriptPermissions() {
  if (fs.existsSync(PERMISSIONS_MARKER)) return true;
  try {
    var result = childProcess.spawnSync('osascript', [
      '-e', 'return true'
    ], { timeout: 5000 });
    if (result.status === 0) {
      try {
        fs.mkdirSync(path.dirname(PERMISSIONS_MARKER), { recursive: true });
        fs.writeFileSync(PERMISSIONS_MARKER, new Date().toISOString(), 'utf8');
      } catch (_) { /* best-effort */ }
      return true;
    }
    process.stderr.write(
      '[stop-unified] WARNING: osascript Accessibility permissions not granted.\n' +
      '  Auto-recovery (continue/compact) will NOT work.\n'
    );
    return false;
  } catch (_) { return false; }
}

/**
 * Fire-and-forget osascript keystroke via detached shell subshell.
 * Uses `bash -c 'sleep N && osascript ...'` with detached:true so it
 * survives the parent process exiting via process.exit(0).
 *
 * Previous approach (spawn('sleep').on('close', callback)) was BROKEN:
 * process.exit(0) killed the parent before the callback could fire.
 */
function scheduleRecoveryKeystroke(text, delaySeconds) {
  var escaped = text.replace(/"/g, '\\"');
  var script = 'sleep ' + delaySeconds +
    ' && osascript' +
    ' -e \'tell application "System Events" to keystroke "' + escaped + '"\'' +
    ' -e \'tell application "System Events" to key code 36\'';

  childProcess.spawn('bash', ['-c', script], {
    stdio: 'ignore',
    detached: true
  }).unref();
}

// ── Audio announcement ───────────────────────────────────────────

function announceCompletion(msg) {
  var text = extractText(msg);

  // Check for tool_use blocks in raw content
  var toolNames = [];
  if (msg && typeof msg === 'object' && Array.isArray(msg.content)) {
    for (var i = 0; i < msg.content.length; i++) {
      var block = msg.content[i];
      if (block && block.type === 'tool_use' && block.name) toolNames.push(block.name);
    }
  }

  if (toolNames.length > 0) {
    var edits = 0, reads = 0, execs = 0, agents = 0;
    for (var t = 0; t < toolNames.length; t++) {
      var n = toolNames[t];
      if (n === 'Edit' || n === 'Write' || n === 'NotebookEdit') edits++;
      else if (n === 'Read' || n === 'Grep' || n === 'Glob' || n === 'LSP') reads++;
      else if (n === 'Bash' || n.indexOf('ctx_execute') === 0) execs++;
      else if (n === 'Agent' || n === 'Task') agents++;
    }

    var parts = [];
    if (edits) parts.push(edits + ' edit' + (edits > 1 ? 's' : ''));
    if (reads) parts.push(reads + ' read' + (reads > 1 ? 's' : ''));
    if (execs) parts.push(execs + ' run' + (execs > 1 ? 's' : ''));
    if (agents) parts.push(agents + ' agent' + (agents > 1 ? 's' : ''));

    var summary = parts.length > 0 ? parts.join(', ') : toolNames.length + ' tools';
    sayAsync('Turn done: ' + summary);
    return;
  }

  // String-based announcements
  if (text.indexOf('[COMPLETE]') >= 0 || text.indexOf('[QUALITY') >= 0 || text.indexOf('done and verified') >= 0) {
    sayAsync('Task completed');
  } else if (text.trim().length > 0) {
    sayAsync('Response ready');
  }
}

// ── Main ─────────────────────────────────────────────────────────

async function main() {
  var _t0 = Date.now();
  var raw = await readStdin();
  var input;
  try { input = JSON.parse(raw); } catch (_) { process.exit(0); }

  // ── Gate 0: stop_hook_active → no-op ───────────────────────────
  if (input.stop_hook_active) { process.exit(0); }

  // ── Gate 0b: Ralph Loop active → no-op ─────────────────────────
  // Ralph has its own Stop hook that manages iteration boundaries.
  // Skip all blocking/recovery to avoid conflicting systemMessages and state writes.
  var ralphStateFile = path.join(process.cwd(), '.claude', 'ralph-loop.local.md');
  try {
    if (fs.existsSync(ralphStateFile)) {
      var ralphContent = fs.readFileSync(ralphStateFile, 'utf8');
      if (/^active:\s*true\b/m.test(ralphContent)) { process.exit(0); }
    }
  } catch (_) { /* best-effort */ }

  function _timing(event) {
    var elapsed = Date.now() - _t0;
    if (elapsed > 100) {
      try {
        var line = JSON.stringify({ ts: new Date().toISOString(), hook: 'stop-unified', event: event, ms: elapsed, session: String(input.session_id || '').substring(0, 8) });
        fs.appendFileSync(path.join(os.homedir(), '.claude', 'hooks', 'hook-timing.log'), line + '\n');
      } catch (_) {}
    }
  }

  // Normalize: lastMsg is always a string from here on
  var lastMsg = extractText(input.last_assistant_message);
  var sessionId = input.session_id || 'default';
  var isStopFailure = !!input.error;

  // Combine all text for pattern matching (recovery patterns)
  var allText = [
    lastMsg,
    input.error || '',
    input.error_details || '',
    input.error_type || ''
  ].join(' ');

  // ── Gate 1: StopFailure → allow (no recovery needed) ────────────
  if (isStopFailure) {
    _timing('allow-stopfailure');
    setGhosttyState('done');
    process.exit(0);
  }

  // ── Gate 2: Empty message → allow (no work done) ───────────────
  if (!lastMsg || lastMsg.trim().length === 0) {
    _timing('allow-empty');
    setGhosttyState('done');
    process.exit(0);
  }

  // ── Gate 3: Completion markers → allow + announce ───────────────
  for (var i = 0; i < COMPLETION_MARKERS.length; i++) {
    if (COMPLETION_MARKERS[i].test(lastMsg)) {
      setGhosttyState('done');
      announceCompletion(input.last_assistant_message);
      _timing('allow-completion-marker');
      process.exit(0);
    }
  }

  // ── Gate 4: Max blocks → allow + announce ──────────────────────
  var state = loadState();
  var sessionState = state[sessionId] || { count: 0, lastBlock: 0 };
  if (sessionState.count >= MAX_BLOCKS) {
    setGhosttyState('done');
    announceCompletion(input.last_assistant_message);
    process.stderr.write('[stop-unified] Max blocks (' + MAX_BLOCKS + ') reached. Allowing stop.\n');
    _timing('allow-max-blocks');
    process.exit(0);
  }

  // ── Recovery 1: Context limit → auto-compact ───────────────────
  if (matchesAny(allText, CONTEXT_LIMIT_PATTERNS)) {
    var now = Date.now();
    var elapsed = now - (state.recovery.lastCompact || 0);
    if (elapsed < COOLDOWN_COMPACT_MS) {
      process.stderr.write('[stop-unified] Context limit hit but within compact cooldown (' +
        Math.round(elapsed / 1000) + 's ago). Skipping.\n');
      _timing('skip-cooldown-compact');
      setGhosttyState('done');
      process.exit(0);
    }
    state.recovery.lastCompact = now;
    state.recovery.compactCount = (state.recovery.compactCount || 0) + 1;
    saveState(state);

    process.stderr.write('[stop-unified] Context limit detected. Auto-compacting in ' +
      DELAY_COMPACT_S + 's (compact #' + state.recovery.compactCount + ')\n');

    if (checkOsascriptPermissions()) {
      // Detached subshell survives parent exit — process.exit(0) won't kill it
      scheduleRecoveryKeystroke('/compact', DELAY_COMPACT_S);
    }
    _timing('auto-compact');
    // Don't set ghostty to done — work continues after compact
    process.exit(0);
  }

  // ── Recovery 2: Incomplete intent → BLOCK (agent stall) ─────────
  // Specific stall pattern: agent announced work but didn't dispatch it.
  // Fires BEFORE crash recovery so this more targeted detection takes priority.
  (function detectIncompleteIntent() {
    // Extract tool names from the actual response blocks
    var toolNames = [];
    var rawMsg = input.last_assistant_message;
    if (rawMsg && typeof rawMsg === 'object' && Array.isArray(rawMsg.content)) {
      for (var k = 0; k < rawMsg.content.length; k++) {
        var blk = rawMsg.content[k];
        if (blk && blk.type === 'tool_use' && blk.name) toolNames.push(blk.name);
      }
    }
    var hasAgentTool = toolNames.some(function(n) { return AGENT_TOOL_NAMES.indexOf(n) >= 0; });
    var hasEditTool = toolNames.some(function(n) {
      return n === 'Edit' || n === 'Write' || n === 'NotebookEdit';
    });
    var hasBashTool = toolNames.some(function(n) { return n === 'Bash'; });
    var toolCount = toolNames.length;

    // Count how many intent signals fire
    var intentHits = 0;
    var intentReasons = [];
    for (var p = 0; p < AGENT_ANNOUNCE_PATTERNS.length; p++) {
      if (AGENT_ANNOUNCE_PATTERNS[p].test(lastMsg)) {
        intentHits++;
        intentReasons.push('announced-action');
        break; // one match is enough for this category
      }
    }
    for (var q = 0; q < INCOMPLETE_INTENT_PATTERNS.length; q++) {
      if (INCOMPLETE_INTENT_PATTERNS[q].test(lastMsg)) {
        intentHits++;
        intentReasons.push('incomplete-sentence');
        break; // one match is enough for this category
      }
    }

    // Negative signal: past-tense completion markers → work was already done, allow stop
    var COMPLETED_PATTERNS = [
      /\bfixed\b/i,
      /\bdone\b/i,
      /\bcompleted\b/i,
      /\bapplied\b/i,
      /\bimplemented\b/i,
      /\bupdated\b/i,
      /\bsolved\b/i,
    ];
    var isCompletedResponse = COMPLETED_PATTERNS.some(function(p) { return p.test(lastMsg); });
    if (intentHits >= 2 && isCompletedResponse) return;

    // Require BOTH announced-action AND incomplete-sentence
    if (intentHits < 2) return;

    // Check if announced work was actually dispatched
    var announcedAgents = /(?:agents?|subagent|workers?|in parallel|team)/i.test(lastMsg);
    var announcedEdits = /(?:fix|edit|update|modify|rewrite|refactor|implement|add|create|build)/i.test(lastMsg);
    var announcedShell = /(?:run|execute|test|build|install|start)/i.test(lastMsg);

    var workDispatched = false;
    if (announcedAgents && hasAgentTool) workDispatched = true;
    if (announcedEdits && hasEditTool) workDispatched = true;
    if (announcedShell && hasBashTool && toolCount > 1) workDispatched = true;
    if (toolCount === 1 && toolNames[0] === 'Bash') {
      var bashInput = '';
      if (rawMsg && typeof rawMsg === 'object' && Array.isArray(rawMsg.content)) {
        for (var b = 0; b < rawMsg.content.length; b++) {
          var bb = rawMsg.content[b];
          if (bb && bb.type === 'tool_use' && bb.name === 'Bash' && bb.input && bb.input.command) {
            bashInput = bb.input.command;
            break;
          }
        }
      }
      if (/^say\s/i.test(bashInput.trim())) {
        workDispatched = false;
      }
    }

    if (workDispatched) return; // Work was dispatched, allow stop

    // ── BLOCK stop, force continuation via exit 2 ──
    var nowIn = Date.now();
    var incompleteKey = 'incomplete_' + sessionId;
    var incompleteState = state[incompleteKey] || { count: 0, lastRecover: 0 };
    var elapsedIn = nowIn - incompleteState.lastRecover;

    if (incompleteState.count >= MAX_INCOMPLETE_RECOVERIES) {
      process.stderr.write('[stop-unified] Incomplete intent: max recoveries (' +
        MAX_INCOMPLETE_RECOVERIES + ') reached. Allowing stop.\n');
      return; // fall through to default
    }

    if (incompleteState.count > 0 && elapsedIn < COOLDOWN_INCOMPLETE_MS) {
      process.stderr.write('[stop-unified] Incomplete intent: within cooldown (' +
        Math.round(elapsedIn / 1000) + 's). Allowing stop.\n');
      return; // fall through to default
    }

    state[incompleteKey] = { count: incompleteState.count + 1, lastRecover: nowIn };
    saveState(state);

    var rushMsg = '[stop-unified] STOP BLOCKED — incomplete intent detected (' +
      (incompleteState.count + 1) + '/' + MAX_INCOMPLETE_RECOVERIES + ').\n' +
      'Reasons: ' + intentReasons.join(', ') + '\n' +
      'Tools dispatched: [' + (toolNames.length > 0 ? toolNames.join(', ') : 'none') + ']\n' +
      'You announced work but did NOT execute it. COMPLETE THE TASK NOW.\n' +
      'Resume exactly where you left off — dispatch the announced tool calls immediately.';

    process.stderr.write(rushMsg + '\n');
    setGhosttyState('working');
    _timing('block-incomplete-intent');
    process.exit(2); // BLOCK stop — agent must continue
  })();

  // ── Recovery 3: Crash/network → auto-continue (fallback) ───────
  // Only reached if incomplete intent gate did NOT fire.
  // Broad catch-all for actual errors/exceptions.
  if (matchesAny(allText, CRASH_PATTERNS)) {
    var now = Date.now();
    var elapsed = now - state.recovery.lastRecover;
    if (elapsed < COOLDOWN_CONTINUE_MS) {
      process.stderr.write('[stop-unified] Within cooldown (' +
        Math.round(elapsed / 1000) + 's ago). Skipping auto-continue.\n');
      _timing('skip-cooldown-continue');
      setGhosttyState('done');
      process.exit(0);
    }
    state.recovery.lastRecover = now;
    state.recovery.count++;
    saveState(state);

    process.stderr.write('[stop-unified] Recoverable error detected (' +
      (isStopFailure ? 'StopFailure' : 'Stop') +
      '). Auto-continue in ' + DELAY_CONTINUE_S + 's (recovery #' + state.recovery.count + ')\n');

    if (checkOsascriptPermissions()) {
      // Detached subshell survives parent exit — process.exit(0) won't kill it
      scheduleRecoveryKeystroke('continue', DELAY_CONTINUE_S);
    }
    _timing('auto-continue');
    // Don't set ghostty to done — work continues after recovery
    process.exit(0);
  }

  // ── Default: allow + announce ──────────────────────────────────
  setGhosttyState('done');
  announceCompletion(input.last_assistant_message);
  _timing('allow-default');
  process.exit(0);
}

main().catch(function () { process.exit(0); });
