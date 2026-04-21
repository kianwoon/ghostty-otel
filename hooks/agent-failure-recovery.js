#!/usr/bin/env node

/**
 * PostToolUseFailure Hook: Agent Error Recovery
 *
 * When an Agent/Task tool call fails, this hook analyzes the error
 * and provides targeted recovery guidance. Exit code 2 triggers
 * automatic retry — no user intervention needed.
 *
 * Matcher: Agent|Task
 * Trigger: PostToolUseFailure
 * Behavior: exit 2 → Claude receives feedback and auto-retries
 */

var fs = require('fs');
var path = require('path');
var os = require('os');

var _home = process.env.STALL_HOOK_STATE_DIR || os.homedir();
var STATE_FILE = path.join(_home, '.claude', 'state', 'agent-failure-recovery-state.json');
var MAX_RETRIES = 1; // Allow 1 auto-retry, then stop
var STATE_TTL_MS = 3600000;

var ERROR_GUIDANCE = {
  // Parameter errors
  'invalid tool parameters': {
    fix: 'Check that all required parameters are present: description (3-5 words), prompt (full task context), subagent_type (e.g. "general-purpose", "Explore", "Plan").',
    hint: 'If missing subagent_type, default to "general-purpose".'
  },
  'missing required parameter': {
    fix: 'The Agent tool requires: description, prompt, and subagent_type.',
    hint: 'Add the missing parameter and retry.'
  },
  // Context limits
  'context window': {
    fix: 'Subagent hit context limits. Shorten the prompt or break the task into smaller pieces.',
    hint: 'Use a more specific prompt and avoid including large file contents. Let the agent read files itself.'
  },
  // Timeout
  'timeout': {
    fix: 'The agent timed out. Try with a shorter, more focused task.',
    hint: 'Break complex tasks into 2-3 smaller agent calls instead of one large one.'
  },
  // Rate limit
  'rate limit': {
    fix: 'Rate limited. Wait briefly and retry, or try with a cheaper model (haiku for simple tasks).',
    hint: 'For read-only tasks, consider using subagent_type="Explore" with model="haiku".'
  },
  // Auth / API
  'authentication': {
    fix: 'API authentication error. Check that API keys and base URL are configured correctly.',
    hint: 'This is an infrastructure issue — may need to check env settings.'
  },
  // Client-side JS errors (input_tokens, undefined, etc.)
  'input_tokens': {
    fix: 'API response parsing error. This is a transient client-side issue.',
    hint: 'Retry the same call. If it persists, try a simpler prompt or shorter task.'
  },
  'undefined is not': {
    fix: 'Client-side runtime error. Usually transient.',
    hint: 'Retry the same call. The error is in Claude Code itself, not your prompt.'
  }
};

function readStdin() {
  return new Promise(function(resolve) {
    var data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', function(chunk) { data += chunk; });
    process.stdin.on('end', function() {
      try {
        resolve(data.trim() ? JSON.parse(data) : null);
      } catch (_) {
        resolve(null);
      }
    });
    process.stdin.on('error', function() { resolve(null); });
  });
}

function matchError(errorStr) {
  var lower = (errorStr || '').toLowerCase();
  for (var pattern in ERROR_GUIDANCE) {
    if (lower.indexOf(pattern) !== -1) {
      return ERROR_GUIDANCE[pattern];
    }
  }
  return null;
}

function loadState() {
  try {
    var all = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    var cutoff = Date.now() - STATE_TTL_MS;
    Object.keys(all).forEach(function(k) {
      if (all[k].lastRetry && all[k].lastRetry < cutoff) delete all[k];
    });
    return all;
  } catch (_) {
    return {};
  }
}

function saveState(state) {
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify(state), 'utf8');
  } catch (_) { /* best-effort */ }
}

async function main() {
  var input = await readStdin();
  if (!input) {
    process.exit(0);
  }

  var toolName = input.tool_name || '';
  if (toolName !== 'Agent' && toolName !== 'Task') {
    process.exit(0);
  }

  var error = input.error || '';
  var toolInput = input.tool_input || {};

  // ── Max-retry gate ─────────────────────────────────────────
  var sessionId = input.session_id || 'default';
  var state = loadState();
  var promptSig = (toolInput.prompt || '').slice(0, 80).replace(/[:\n]/g, '_');
  var key = sessionId + ':' + (toolInput.description || 'unnamed') + ':' + promptSig;
  var retries = state[key] || { count: 0, lastRetry: 0 };

  if (retries.count >= MAX_RETRIES) {
    process.stderr.write(
      '[agent-failure-recovery] Max retries (' + MAX_RETRIES +
      ') reached for "' + (toolInput.description || 'unnamed') +
      '". Not auto-retrying — letting Claude handle it.\n'
    );
    process.exit(0); // allow stop, no retry
  }

  // Match against known error patterns
  var guidance = matchError(error);

  retries.count++;
  retries.lastRetry = Date.now();
  state[key] = retries;
  saveState(state);

  var feedback;
  if (guidance) {
    feedback = '[Agent Error Recovery] The ' + toolName + ' call failed.\n' +
      'Error: ' + error + '\n' +
      'Fix: ' + guidance.fix + '\n' +
      guidance.hint;
  } else {
    // Generic fallback — still provide useful guidance
    var subagentType = toolInput.subagent_type || 'unknown';
    var desc = toolInput.description || 'unnamed';
    feedback = '[Agent Error Recovery] ' + toolName + ' call "' + desc + '" failed.\n' +
      'Error: ' + error + '\n' +
      'Subagent type was: ' + subagentType + '\n' +
      'Recovery options:\n' +
      '- Check if the subagent_type is valid (general-purpose, Explore, Plan, etc.)\n' +
      '- Ensure the prompt is clear and self-contained\n' +
      '- Try a simpler task or different model\n' +
      '- If this is a read-only task, use subagent_type="Explore" instead';
  }

  process.stderr.write(feedback + '\n');
  // Exit code 2 = send feedback to Claude and auto-retry
  process.exit(2);
}

main().catch(function() { process.exit(0); });
