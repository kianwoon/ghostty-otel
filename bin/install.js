#!/usr/bin/env node

var cp = require('child_process');
var fs = require('fs');
var path = require('path');
var os = require('os');

var HOME = os.homedir();
var SETTINGS_PATH = path.join(HOME, '.claude', 'settings.json');
var MARKETPLACE_NAME = 'kianwoon';
var MARKETPLACE_REPO = 'kianwoon/ghostty-otel';
var PLUGIN_NAME = 'ghostty-otel';

// ── Helpers ──────────────────────────────────────────────────
function log(msg) { console.log(msg); }
function ok(msg) { console.log('  ✓ ' + msg); }
function warn(msg) { console.log('  ⚠ ' + msg); }
function fail(msg) { console.log('  ✗ ' + msg); }

function execSafe(cmd) {
  try { return cp.execSync(cmd, { encoding: 'utf8', timeout: 10000 }).trim(); }
  catch (_) { return null; }
}

// ── Step 1: Prerequisites ────────────────────────────────────
log('\nghostty-otel installer\n');
log('Checking prerequisites...');

var hasClaude = execSafe('which claude') !== null;
var hasNode = execSafe('which node') !== null;
var hasPython3 = execSafe('which python3') !== null;

if (hasClaude) ok('Claude Code CLI found');
else { fail('Claude Code CLI not found — install from https://docs.anthropic.com/en/docs/claude-code'); }

if (hasNode) ok('Node.js found');
else fail('Node.js not found');

if (hasPython3) ok('Python 3 found');
else warn('Python 3 not found — OTEL listener requires Python 3');

if (!hasClaude) {
  console.log('\nInstall Claude Code first, then re-run: npx ghostty-otel');
  process.exit(1);
}

// ── Step 2: Register marketplace ─────────────────────────────
log('\nRegistering marketplace...');

var settings = {};
try {
  settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
} catch (_) {
  settings = {};
}

if (!settings.extraKnownMarketplaces) {
  settings.extraKnownMarketplaces = {};
}

if (settings.extraKnownMarketplaces[MARKETPLACE_NAME]) {
  ok('Marketplace "' + MARKETPLACE_NAME + '" already registered');
} else {
  settings.extraKnownMarketplaces[MARKETPLACE_NAME] = {
    source: { source: 'github', repo: MARKETPLACE_REPO }
  };
  try {
    fs.mkdirSync(path.dirname(SETTINGS_PATH), { recursive: true });
    fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2));
    ok('Marketplace "' + MARKETPLACE_NAME + '" registered in settings.json');
  } catch (e) {
    fail('Could not write settings.json: ' + e.message);
    process.exit(1);
  }
}

// ── Step 3: Enable plugin ────────────────────────────────────
log('\nEnabling plugin...');

if (!settings.enabledPlugins) {
  settings.enabledPlugins = {};
}

var pluginId = PLUGIN_NAME + '@' + MARKETPLACE_NAME;
if (settings.enabledPlugins[pluginId]) {
  ok('Plugin already enabled');
} else {
  settings.enabledPlugins[pluginId] = true;
  try {
    fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2));
    ok('Plugin enabled in settings.json');
  } catch (e) {
    fail('Could not write settings.json: ' + e.message);
  }
}

// ── Step 4: Verify ───────────────────────────────────────────
log('\nVerifying installation...');

var STATE_DIR = process.env.GHOSTTY_OTEL_STATE_DIR || '/tmp';
var pidFile = path.join(STATE_DIR, 'ghostty-otel.pid');

try {
  var pid = fs.readFileSync(pidFile, 'utf8').trim();
  process.kill(parseInt(pid), 0);
  ok('OTEL listener running (PID ' + pid + ')');
} catch (_) {
  warn('OTEL listener not running yet — starts automatically on next Claude Code session');
}

var ttyPath = execSafe('tty 2>/dev/null');
if (ttyPath && ttyPath !== 'not a tty') {
  var sessionKey = path.basename(ttyPath).replace(/[^a-zA-Z0-9_-]/g, '');
  var stateFile = path.join(STATE_DIR, 'ghostty-indicator-state-' + sessionKey + '.txt');
  try {
    var state = fs.readFileSync(stateFile, 'utf8').trim();
    ok('Session key: ' + sessionKey + ' (state: ' + state + ')');
  } catch (_) {
    ok('Session key: ' + sessionKey + ' (state file created on first use)');
  }
}

// ── Done ─────────────────────────────────────────────────────
log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
log('ghostty-otel installed!\n');
log('Next steps:');
log('  1. Start a new Claude Code session (or restart)');
log('  2. The indicator activates automatically');
log('  3. Run "npx ghostty-otel status" to check health');
log('');
log('To install inside Claude Code, use: /plugin');
log('');
