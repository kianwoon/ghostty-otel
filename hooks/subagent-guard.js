#!/usr/bin/env node

/**
 * PreToolUse Hook: Subagent Guard (unified)
 *
 * Combines two previously-separate hooks into one process:
 *   1. agent-param-guard: Auto-repairs missing required Agent/Task params
 *   2. subagent-output-prompt: Appends output size limit block to prompt
 *
 * Saves ~30ms per Agent/Task call by eliminating a separate Node.js process.
 *
 * Matcher: Agent|Task
 * Trigger: PreToolUse
 */

var OUTPUT_LIMIT_BLOCK = '\n<subagent_output_limit>\nCRITICAL: Response MUST be under 2000 chars (~300 words). Summarize in 2-3 bullets.\nNever paste file contents — reference paths. Write code to files, report path + 1-line summary.\nNever include full stack traces — error + fix only.\n</subagent_output_limit>';

function readStdin() {
  return new Promise(function(resolve) {
    var data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', function(chunk) { data += chunk; });
    process.stdin.on('end', function() {
      try { resolve(data.trim() ? JSON.parse(data) : null); }
      catch (_) { resolve(null); }
    });
    process.stdin.on('error', function() { resolve(null); });
  });
}

async function main() {
  var input = await readStdin();
  if (!input) process.exit(0);

  var toolName = input.tool_name || '';
  if (toolName !== 'Agent' && toolName !== 'Task') process.exit(0);

  var toolInput = input.tool_input || {};
  var repaired = [];
  var needsRepair = false;

  // ── Phase 1: Param repair ──────────────────────────────────────

  if (!toolInput.description || typeof toolInput.description !== 'string' || toolInput.description.trim() === '') {
    toolInput.description = 'Agent delegation';
    needsRepair = true;
    repaired.push('description');
  }

  if (toolName === 'Agent') {
    if (!toolInput.subagent_type || typeof toolInput.subagent_type !== 'string' || toolInput.subagent_type.trim() === '') {
      toolInput.subagent_type = 'general-purpose';
      needsRepair = true;
      repaired.push('subagent_type');
    }
  }

  // ── Phase 2: Output limit injection ────────────────────────────

  var recognizedFields = ['prompt', 'request', 'objective', 'question', 'query', 'task'];
  var fieldName = recognizedFields.find(function(f) { return f in toolInput; });

  // Fallback: use 'prompt' if no recognized field found
  if (!fieldName) {
    toolInput.prompt = toolInput.prompt || '';
    fieldName = 'prompt';
  }

  // Ensure prompt field exists if not already set
  if (!toolInput[fieldName] || typeof toolInput[fieldName] !== 'string' || toolInput[fieldName].trim() === '') {
    toolInput[fieldName] = 'Execute the delegated task.';
    needsRepair = true;
    repaired.push(fieldName);
  }

  var prompt = toolInput[fieldName];

  // Skip if already injected (idempotent)
  if (prompt.indexOf('subagent_output_limit') === -1) {
    toolInput[fieldName] = prompt + OUTPUT_LIMIT_BLOCK;
    needsRepair = true;
    repaired.push('output-limit');
  }

  // ── Output ─────────────────────────────────────────────────────

  if (!needsRepair) process.exit(0);

  process.stderr.write('[subagent-guard] Modified ' + toolName + ': ' + repaired.join(', ') + '\n');

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: 'Guard applied: ' + repaired.join(', '),
      updatedInput: toolInput
    }
  }) + '\n');
  process.exit(0);
}

main().catch(function() { process.exit(0); });
