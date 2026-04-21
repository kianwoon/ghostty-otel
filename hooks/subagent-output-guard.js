#!/usr/bin/env node

/**
 * PostToolUse Hook: Subagent Output Guard
 *
 * Detects large Agent/Task tool outputs and stores full output to disk.
 * Emits additionalContext with a metadata banner so the main model
 * knows the output was truncated and where to find the full version.
 *
 * NOTE: PostToolUse hooks can use hookSpecificOutput with additionalContext
 * to emit advisory banners to the main model. This does not replace the
 * tool output but provides metadata about truncated content stored on disk.
 *
 * This pairs with subagent-guard.js (PreToolUse) which injects
 * output limit instructions into subagent prompts to prevent large
 * outputs from being generated in the first place.
 *
 * Matcher: Agent|Task
 * Trigger: PostToolUse
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

// Configuration
const OUTPUT_DIR = path.join(os.homedir(), '.claude', 'state', 'agent-outputs');
const WARN_THRESHOLD = 4000; // chars — emit warning above this
const MAX_AGE_MS = 3600000; // 1 hour TTL for stored output files

function readStdin() {
  return new Promise(function (resolve) {
    var data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', function (chunk) { data += chunk; });
    process.stdin.on('end', function () {
      try {
        resolve(data.trim() ? JSON.parse(data) : null);
      } catch (_) {
        resolve(null);
      }
    });
    process.stdin.on('error', function () { resolve(null); });
  });
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

  // TTL cleanup: remove files older than MAX_AGE_MS
  try {
    var files = fs.readdirSync(OUTPUT_DIR);
    var cutoff = Date.now() - MAX_AGE_MS;
    for (var i = 0; i < files.length; i++) {
      try {
        var stat = fs.statSync(path.join(OUTPUT_DIR, files[i]));
        if (stat.mtimeMs < cutoff) fs.unlinkSync(path.join(OUTPUT_DIR, files[i]));
      } catch (_) {}
    }
  } catch (_) {}

  // Extract output text (handle string or object)
  var rawOutput = input.tool_response;
  var outputText;
  if (typeof rawOutput === 'string') {
    outputText = rawOutput;
  } else if (rawOutput && typeof rawOutput === 'object') {
    outputText = JSON.stringify(rawOutput, null, 2);
  } else {
    outputText = String(rawOutput || '');
  }

  var size = outputText.length;

  // Pass through if under threshold
  if (size < WARN_THRESHOLD) {
    process.exit(0);
  }

  // Store full output to disk
  try {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  } catch (_) { /* best-effort */ }

  var timestamp = Date.now();
  var suffix = Math.random().toString(36).slice(2, 8);
  var filename = timestamp + '-' + toolName + '-' + suffix + '.txt';
  var filepath = path.join(OUTPUT_DIR, filename);

  try {
    fs.writeFileSync(filepath, outputText, 'utf8');
  } catch (_) {
    process.exit(0); // don't block on write failure
  }

  // Emit additionalContext warning banner
  // This is visible to the main model but does NOT replace the tool output
  var warning =
    '[SUBAGENT OUTPUT WARNING] ' + toolName + ' returned ' + size + ' characters. ' +
    'Full output saved to: ' + filepath + '\n' +
    'The output above is large and may consume significant context. ' +
    'Read the saved file only if the summarized information is insufficient.';

  var response = {
    hookSpecificOutput: {
      hookEventName: 'PostToolUse',
      additionalContext: warning
    }
  };

  process.stdout.write(JSON.stringify(response) + '\n');
  process.exit(0);
}

main().catch(function () {
  process.exit(0); // never block on hook errors
});
