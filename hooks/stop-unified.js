#!/usr/bin/env node

/**
 * Unified Stop/StopFailure Hook (v5)
 *
 * Combines recovery + audio announcement + ghostty indicator management.
 * Handles Stop and StopFailure events with context limit recovery,
 * crash recovery, incomplete intent detection, and completion announcements.
 *
 * Exit codes: 0 = allow stop, 2 = block stop with feedback
 */

'use strict';

var fs = require('fs');
var path = require('path');
var os = require('os');
var childProcess = require('child_process');

// ── Configuration ────────────────────────────────────────────────
var MAX_BLOCKS = 3;
var HOME_DIR = process.env.STALL_HOOK_STATE_DIR || os.homedir();
var STATE_FILE = path.join(HOME_DIR, '.claude', 'state', 'stop-unified-state.json');
var STATE_TTL_MS = 3600000;
var STATE_DIR = process.env.GHOSTTY_OTEL_STATE_DIR || '/tmp';
var PERMISSIONS_MARKER = path.join(HOME_DIR, '.claude', 'state', '.osascript-ok');

var COOLDOWN_CONTINUE_MS = 30000;
var COOLDOWN_COMPACT_MS = 60000;
var COOLDOWN_INCOMPLETE_MS = 30000;
var DELAY_CONTINUE_S = 5;
var DELAY_COMPACT_S = 3;
var MAX_INCOMPLETE_RECOVERIES = 3;

// ── Patterns ──────────────────────────────────────────────────────
var CRASH_PATTERNS = [
  'undefined is not an object', 'cannot read property', 'cannot read properties',
  'uncaught exception', 'typeerror:', 'referenceerror:', 'socket connection was closed',
  'socket hang up', 'econnreset', 'econnrefused', 'fetch failed', 'network error',
  'unexpected end of stream', 'api error'
];

var CONTEXT_LIMIT_PATTERNS = [
  'context window', 'context length', 'context limit', 'token limit', 'max tokens',
  'max_output_tokens', 'maximum context', 'too many tokens', 'exceeds maximum',
  'context_length_exceeded', 'reduce the length'
];

var COMPLETION_MARKERS = [
  /\[COMPLETE\]/i, /\[QUALITY\s+\d/i, /\[PROGRESS\s+\d\/\d\]/i,
  /(?:all |every )?(?:test|check|step|task)s?\s+(?:pass|complete|done|finish)/i,
  /(?:no |zero )(?:error|warning|failure|issue)s?\s*(?:found|reported|remaining)?$/i,
  /(?:build|compile|lint|deploy|commit|merge)\s+(?:succeed|pass|complete|done)/i,
  /task completed/i, /changes applied/i
];

// Tightened patterns — avoid false positives on normal colons/commas
var INCOMPLETE_INTENT_PATTERNS = [
  /\b(?:let me|i'll|i will|now i'll|starting|launching|creating|building|fixing|implementing|adding|setting up)\s+\S.{10,}(?:\s+and\s+|\s+then\s+|\s+,\s*|$)/i,
  /(?:and|then|also|next|after that|finally)\s*$/mi,
  /^\s*\d+[.)]\s+\S.{5,50}(?:\s+[a-z]\s*$|$)/mi,
  /\b(?:in parallel|using (?:\d+\s+)?agents?|spawning (?:\d+\s+)?agents?)\b/i
];

var AGENT_ANNOUNCE_PATTERNS = [
  /(?:let me|i'll|i will|now i'll|starting|launching)\s+.{0,30}\s+(?:agents?|subagent|workers?|team)\b/i,
  /(?:spawning|launching|using|starting)\s+(?:\d+\s+)?(?:agents?|subagent|workers?|tasks?)/i,
  /in parallel/i,
  /using\s+\d+\s+(?:agents?|workers?|subagents?)\s+for/i
];

var AGENT_TOOL_NAMES = ['Agent', 'Task', 'SendMessage'];

// ── Session key cache (per-process) ───────────────────────────────
var _cachedSessionKey = null;

function getSessionKey(sessionId) {
  if (_cachedSessionKey) return _cachedSessionKey;
  var sid = process.env.GHOSTTY_OTEL_SESSION_KEY || '';
  if (!sid && sessionId) {
    // Try reverse-lookup file first: /tmp/ghostty-sid-{session_id}
    var reversePath = path.join(STATE_DIR, 'ghostty-sid-' + sessionId);
    try {
      sid = fs.readFileSync(reversePath, 'utf8').trim();
    } catch (_) {
      // Fall back to scanning SID files (rare)
      try {
        var files = fs.readdirSync(STATE_DIR);
        for (var i = 0; i < files.length; i++) {
          var f = files[i];
          if (f.indexOf('ghostty-sid-') !== 0) continue;
          // Skip non-matching files quickly by checking name first
          try {
            var content = fs.readFileSync(path.join(STATE_DIR, f), 'utf8');
            if (content.trim() === sessionId) {
              sid = f.replace('ghostty-sid-', '');
              _cachedSessionKey = sid;
              // Also create reverse-lookup for future fast path
              try {
                fs.writeFileSync(reversePath, f.replace('ghostty-sid-', ''));
              } catch (_) {}
              break;
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
  }
  _cachedSessionKey = sid;
  return sid;
}

// ── Ghostty state ─────────────────────────────────────────────────
function setGhosttyState(state, sessionId) {
  try {
    var sid = getSessionKey(sessionId);
    if (!sid) return;
    var stateFile = path.join(STATE_DIR, 'ghostty-indicator-state-' + sid + '.txt');
    var tmpFile = stateFile + '.tmp.' + process.pid;
    fs.writeFileSync(tmpFile, state);
    fs.renameSync(tmpFile, stateFile);
  } catch (_) { /* best-effort */ }
}

// ── Helpers ──────────────────────────────────────────────────────
function sayAsync(text) {
  try {
    childProcess.spawn('say', [text], {
      stdio: 'ignore', detached: true
    }).unref();
  } catch (_) {}
}

function readStdin() {
  return new Promise(function (resolve) {
    var data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', function (c) { data += c; });
    process.stdin.on('end', function () { resolve(data.trim()); });
    process.stdin.on('error', function () { resolve(''); });
  });
}

function matchesAny(text, patterns) {
  var lower = (text || '').toLowerCase();
  return patterns.some(function (p) { return lower.indexOf(p) !== -1; });
}

function extractText(msg) {
  if (typeof msg === 'string') return msg;
  if (!msg || typeof msg !== 'object') return '';
  if (typeof msg.content === 'string') return msg.content;
  if (Array.isArray(msg.content)) {
    return msg.content.map(function (b) {
      if (!b) return '';
      if (typeof b === 'string') return b;
      if (b.type === 'text' && b.text) return b.text;
      return '';
    }).join(' ');
  }
  return '';
}

function loadState() {
  try {
    var all = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    var cutoff = Date.now() - STATE_TTL_MS;
    Object.keys(all).forEach(function (k) {
      if (k === 'recovery' || k === 'incomplete_') return;
      if (k.indexOf('incomplete_') === 0) return;
      if (all[k].lastBlock && all[k].lastBlock < cutoff) delete all[k];
    });
    if (!all.recovery) {
      all.recovery = { lastRecover: 0, count: 0, lastCompact: 0, compactCount: 0 };
    }
    return all;
  } catch (_) {
    return { recovery: { lastRecover: 0, count: 0, lastCompact: 0, compactCount: 0 } };
  }
}

function saveState(state) {
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify(state), 'utf8');
  } catch (_) {}
}

function checkOsascriptPermissions() {
  if (fs.existsSync(PERMISSIONS_MARKER)) return true;
  try {
    var result = childProcess.spawnSync('osascript', ['-e', 'return true'], { timeout: 5000 });
    if (result.status === 0) {
      try {
        fs.mkdirSync(path.dirname(PERMISSIONS_MARKER), { recursive: true });
        fs.writeFileSync(PERMISSIONS_MARKER, new Date().toISOString(), 'utf8');
      } catch (_) {}
      return true;
    }
    process.stderr.write('[stop-unified] osascript permissions not granted. Auto-recovery disabled.\n');
    return false;
  } catch (_) { return false; }
}

function scheduleRecoveryKeystroke(text, delaySeconds) {
  var script = 'sleep ' + delaySeconds +
    ' && osascript -e \'tell application "System Events" to keystroke "' + text + '"\'' +
    ' -e \'tell application "System Events" to key code 36\'';
  childProcess.spawn('bash', ['-c', script], { stdio: 'ignore', detached: true }).unref();
}

function announceCompletion(msg) {
  var text = extractText(msg);
  var toolNames = [];
  if (msg && typeof msg === 'object' && Array.isArray(msg.content)) {
    for (var i = 0; i < msg.content.length; i++) {
      var b = msg.content[i];
      if (b && b.type === 'tool_use' && b.name) toolNames.push(b.name);
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

  // Gate 0: stop_hook_active → no-op
  if (input.stop_hook_active) { process.exit(0); }

  // Gate 0b: Ralph Loop active → no-op
  var ralphStateFile = path.join(process.cwd(), '.claude', 'ralph-loop.local.md');
  try {
    if (fs.existsSync(ralphStateFile)) {
      var ralphContent = fs.readFileSync(ralphStateFile, 'utf8');
      if (/^active:\s*true\b/m.test(ralphContent)) { process.exit(0); }
    }
  } catch (_) {}

  function _timing(event) {
    var elapsed = Date.now() - _t0;
    if (elapsed > 100) {
      try {
        var line = JSON.stringify({
          ts: new Date().toISOString(),
          hook: 'stop-unified',
          event: event,
          ms: elapsed,
          session: String(input.session_id || '').substring(0, 8)
        });
        fs.appendFileSync(path.join(os.homedir(), '.claude', 'hooks', 'hook-timing.log'), line + '\n');
      } catch (_) {}
    }
  }

  var lastMsg = extractText(input.last_assistant_message);
  var sessionId = input.session_id || 'default';
  var isStopFailure = !!input.error;
  var allText = [lastMsg, input.error || '', input.error_details || '', input.error_type || ''].join(' ');

  // Gate 1: StopFailure → allow
  if (isStopFailure) { _timing('allow-stopfailure'); setGhosttyState('done', sessionId); process.exit(0); }

  // Gate 2: Empty message → allow
  if (!lastMsg || lastMsg.trim().length === 0) { _timing('allow-empty'); setGhosttyState('done', sessionId); process.exit(0); }

  // Gate 3: Completion markers → allow + announce
  for (var i = 0; i < COMPLETION_MARKERS.length; i++) {
    if (COMPLETION_MARKERS[i].test(lastMsg)) {
      setGhosttyState('done', sessionId);
      announceCompletion(input.last_assistant_message);
      _timing('allow-completion-marker');
      process.exit(0);
    }
  }

  // Gate 4: Max blocks → allow
  var state = loadState();
  var sessionState = state[sessionId] || { count: 0, lastBlock: 0 };
  if (sessionState.count >= MAX_BLOCKS) {
    setGhosttyState('done', sessionId);
    announceCompletion(input.last_assistant_message);
    process.stderr.write('[stop-unified] Max blocks (' + MAX_BLOCKS + ') reached. Allowing stop.\n');
    _timing('allow-max-blocks');
    process.exit(0);
  }

  // Recovery 1: Context limit → auto-compact
  if (matchesAny(allText, CONTEXT_LIMIT_PATTERNS)) {
    var now = Date.now();
    var elapsed = now - (state.recovery.lastCompact || 0);
    if (elapsed < COOLDOWN_COMPACT_MS) {
      process.stderr.write('[stop-unified] Context limit but within cooldown (' + Math.round(elapsed / 1000) + 's). Skipping.\n');
      _timing('skip-cooldown-compact');
      setGhosttyState('done', sessionId);
      process.exit(0);
    }
    state.recovery.lastCompact = now;
    state.recovery.compactCount = (state.recovery.compactCount || 0) + 1;
    saveState(state);
    process.stderr.write('[stop-unified] Context limit. Auto-compacting in ' + DELAY_COMPACT_S + 's (#' + state.recovery.compactCount + ')\n');
    if (checkOsascriptPermissions()) { scheduleRecoveryKeystroke('/compact', DELAY_COMPACT_S); }
    _timing('auto-compact');
    process.exit(0);
  }

  // Recovery 2: Incomplete intent → BLOCK
  (function detectIncompleteIntent() {
    var toolNames = [];
    var rawMsg = input.last_assistant_message;
    if (rawMsg && typeof rawMsg === 'object' && Array.isArray(rawMsg.content)) {
      for (var k = 0; k < rawMsg.content.length; k++) {
        var blk = rawMsg.content[k];
        if (blk && blk.type === 'tool_use' && blk.name) toolNames.push(blk.name);
      }
    }
    var hasAgentTool = toolNames.some(function(n) { return AGENT_TOOL_NAMES.indexOf(n) >= 0; });
    var hasEditTool = toolNames.some(function(n) { return n === 'Edit' || n === 'Write' || n === 'NotebookEdit'; });
    var hasBashTool = toolNames.some(function(n) { return n === 'Bash'; });
    var toolCount = toolNames.length;

    var intentHits = 0;
    var intentReasons = [];
    for (var p = 0; p < AGENT_ANNOUNCE_PATTERNS.length; p++) {
      if (AGENT_ANNOUNCE_PATTERNS[p].test(lastMsg)) { intentHits++; intentReasons.push('announced-action'); break; }
    }
    for (var q = 0; q < INCOMPLETE_INTENT_PATTERNS.length; q++) {
      if (INCOMPLETE_INTENT_PATTERNS[q].test(lastMsg)) { intentHits++; intentReasons.push('incomplete-sentence'); break; }
    }

    var COMPLETED_PATTERNS = [/\bfixed\b/i, /\bdone\b/i, /\bcompleted\b/i, /\bapplied\b/i, /\bimplemented\b/i, /\bupdated\b/i, /\bsolved\b/i];
    var isCompletedResponse = COMPLETED_PATTERNS.some(function(p) { return p.test(lastMsg); });
    if (intentHits >= 2 && isCompletedResponse) return;

    if (intentHits < 2) return;

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
      if (/^say\s/i.test(bashInput.trim())) { workDispatched = false; }
    }

    if (workDispatched) return;

    // Inline work: no tool calls but substantive text response = work done in message
    if (toolCount === 0 && lastMsg.trim().length > 200) return;

    // Text-only threshold: no tools at all requires stronger intent signals
    if (toolCount === 0 && intentHits < 3) return;

    var nowIn = Date.now();
    var incompleteKey = 'incomplete_' + sessionId;
    var incompleteState = state[incompleteKey] || { count: 0, lastRecover: 0 };
    var elapsedIn = nowIn - incompleteState.lastRecover;

    if (incompleteState.count >= MAX_INCOMPLETE_RECOVERIES) {
      process.stderr.write('[stop-unified] Incomplete intent: max recoveries (' + MAX_INCOMPLETE_RECOVERIES + ') reached. Allowing stop.\n');
      return;
    }
    if (incompleteState.count > 0 && elapsedIn < COOLDOWN_INCOMPLETE_MS) {
      process.stderr.write('[stop-unified] Incomplete intent: within cooldown (' + Math.round(elapsedIn / 1000) + 's). Allowing stop.\n');
      return;
    }

    state[incompleteKey] = { count: incompleteState.count + 1, lastRecover: nowIn };
    saveState(state);

    process.stderr.write('[stop-unified] STOP BLOCKED — incomplete intent (' + (incompleteState.count + 1) + '/' + MAX_INCOMPLETE_RECOVERIES + ')\n' +
      'Reasons: ' + intentReasons.join(', ') + '\n' +
      'Tools: [' + (toolNames.length > 0 ? toolNames.join(', ') : 'none') + ']\n');
    setGhosttyState('working', sessionId);
    _timing('block-incomplete-intent');
    process.exit(2);
  })();

  // Recovery 3: Crash/network → auto-continue
  if (matchesAny(allText, CRASH_PATTERNS)) {
    var now = Date.now();
    var elapsed = now - state.recovery.lastRecover;
    if (elapsed < COOLDOWN_CONTINUE_MS) {
      process.stderr.write('[stop-unified] Within cooldown (' + Math.round(elapsed / 1000) + 's). Skipping auto-continue.\n');
      _timing('skip-cooldown-continue');
      setGhosttyState('done', sessionId);
      process.exit(0);
    }
    state.recovery.lastRecover = now;
    state.recovery.count++;
    saveState(state);
    process.stderr.write('[stop-unified] Recoverable error. Auto-continue in ' + DELAY_CONTINUE_S + 's (#' + state.recovery.count + ')\n');
    if (checkOsascriptPermissions()) { scheduleRecoveryKeystroke('continue', DELAY_CONTINUE_S); }
    _timing('auto-continue');
    process.exit(0);
  }

  // Default: allow + announce
  setGhosttyState('done', sessionId);
  announceCompletion(input.last_assistant_message);
  _timing('allow-default');
  process.exit(0);
}

main().catch(function () { process.exit(0); });
