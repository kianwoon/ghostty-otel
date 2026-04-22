#!/usr/bin/env node

var fs = require('fs');
var path = require('path');
var os = require('os');
var cp = require('child_process');

var HOME = os.homedir();
var STATE_DIR = process.env.GHOSTTY_OTEL_STATE_DIR || '/tmp';
var SETTINGS_PATH = path.join(HOME, '.claude', 'settings.json');

// ── Helpers ──────────────────────────────────────────────────
function ok(msg) { return '  ✓ ' + msg; }
function warn(msg) { return '  ⚠ ' + msg; }
function fail(msg) { return '  ✗ ' + msg; }

function execSafe(cmd) {
  try { return cp.execFileSync('/bin/sh', ['-c', cmd], { encoding: 'utf8', timeout: 10000 }).trim(); }
  catch (_) { return null; }
}

// ── Status checks ────────────────────────────────────────────
var results = [];

// 1. Plugin registered?
var pluginRegistered = false;
try {
  var settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
  var marketplace = (settings.extraKnownMarketplaces || {})['kianwoon'];
  pluginRegistered = !!marketplace;
  results.push(pluginRegistered
    ? ok('Plugin marketplace registered')
    : fail('Plugin marketplace NOT registered — run: npx ghostty-otel'));
} catch (_) {
  results.push(fail('Cannot read ~/.claude/settings.json'));
}

// 2. Plugin enabled?
var pluginEnabled = false;
try {
  var settings2 = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
  pluginEnabled = settings2.enabledPlugins &&
    settings2.enabledPlugins['ghostty-otel@kianwoon'] === true;
  results.push(pluginEnabled
    ? ok('Plugin enabled')
    : warn('Plugin not enabled — run: npx ghostty-otel'));
} catch (_) {}

// 3. OTEL listener running?
var listenerPid = null;
try {
  listenerPid = fs.readFileSync(path.join(STATE_DIR, 'ghostty-otel.pid'), 'utf8').trim();
  process.kill(parseInt(listenerPid), 0);
  results.push(ok('OTEL listener running (PID ' + listenerPid + ')'));
} catch (_) {
  if (listenerPid) {
    results.push(fail('OTEL listener dead (stale PID ' + listenerPid + ')'));
  } else {
    results.push(warn('OTEL listener not running — starts on next Claude Code session'));
  }
}

// 4. Watcher running?
var ttyPath = execSafe('tty 2>/dev/null');
if (ttyPath && ttyPath !== 'not a tty') {
  var sessionKey = path.basename(ttyPath).replace(/[^a-zA-Z0-9_-]/g, '');
  var watcherPidFile = path.join(STATE_DIR, 'ghostty-watcher-' + sessionKey + '.pid');
  try {
    var wpid = fs.readFileSync(watcherPidFile, 'utf8').trim();
    process.kill(parseInt(wpid), 0);
    results.push(ok('Watcher running (PID ' + wpid + ', session ' + sessionKey + ')'));
  } catch (_) {
    results.push(warn('Watcher not running for session ' + sessionKey));
  }

  // 5. State file
  var stateFile = path.join(STATE_DIR, 'ghostty-indicator-state-' + sessionKey + '.txt');
  try {
    var state = fs.readFileSync(stateFile, 'utf8').trim();
    results.push(ok('State: ' + state + ' (session ' + sessionKey + ')'));
  } catch (_) {
    results.push(warn('No state file yet for session ' + sessionKey));
  }

  // 6. SID mapping
  var sidFiles = fs.readdirSync(STATE_DIR).filter(function(f) {
    return f.indexOf('ghostty-sid-' + sessionKey) === 0;
  });
  results.push(sidFiles.length > 0
    ? ok('SID mapping found (' + sidFiles.length + ' file' + (sidFiles.length > 1 ? 's' : '') + ')')
    : warn('No SID mapping — created on first OTEL span'));
} else {
  results.push(warn('No TTY detected — session-specific checks skipped'));
}

// 7. Active sessions
try {
  var stateFiles = fs.readdirSync(STATE_DIR).filter(function(f) {
    return f.indexOf('ghostty-indicator-state-') === 0 && f.endsWith('.txt');
  });
  if (stateFiles.length > 0) {
    results.push(ok('Active sessions: ' + stateFiles.length));
    stateFiles.forEach(function(f) {
      var key = f.replace('ghostty-indicator-state-', '').replace('.txt', '');
      try {
        var s = fs.readFileSync(path.join(STATE_DIR, f), 'utf8').trim();
        results.push('    ' + key + ': ' + s);
      } catch (_) {}
    });
  }
} catch (_) {}

// ── Output ───────────────────────────────────────────────────
console.log('\nghostty-otel status\n');
results.forEach(function(r) { console.log(r); });

var healthy = pluginRegistered && pluginEnabled && listenerPid;
console.log('\n' + (healthy ? '✓ All systems healthy' : '⚠ Some issues detected — see above'));
console.log('');
