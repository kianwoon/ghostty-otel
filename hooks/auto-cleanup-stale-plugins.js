#!/usr/bin/env node
/**
 * Stale Plugin Cache Cleanup
 * Runs on SessionStart to remove old plugin versions from ~/.claude/plugins/cache/
 * that are no longer referenced in installed_plugins.json.
 */
const fs = require('fs');
const path = require('path');
const os = require('os');

const HOME = os.homedir();
const PLUGINS_JSON = path.join(HOME, '.claude', 'plugins', 'installed_plugins.json');
const CACHE_DIR = path.join(HOME, '.claude', 'plugins', 'cache');

let cleanedDirs = 0;
let freedBytes = 0;

function getActivePaths() {
  try {
    const raw = fs.readFileSync(PLUGINS_JSON, 'utf8');
    const data = JSON.parse(raw);
    if (!data || !data.plugins || typeof data.plugins !== 'object') return new Set();

    const active = new Set();
    for (const entries of Object.values(data.plugins)) {
      if (!Array.isArray(entries)) continue;
      for (const entry of entries) {
        if (entry.installPath) {
          active.add(path.resolve(entry.installPath));
        }
      }
    }
    return active;
  } catch (err) {
    process.stderr.write(`[plugin-cleanup] Could not read ${PLUGINS_JSON}: ${err.message}\n`);
    return null; // null = cannot determine, skip cleanup
  }
}

function dirSize(dirPath) {
  let size = 0;
  try {
    const entries = fs.readdirSync(dirPath, { withFileTypes: true });
    for (const entry of entries) {
      const full = path.join(dirPath, entry.name);
      if (entry.isDirectory()) {
        // Skip node_modules for size calculation speed
        if (entry.name === 'node_modules') continue;
        size += dirSize(full);
      } else {
        try { size += fs.statSync(full).size; } catch (_) {}
      }
    }
  } catch (_) {}
  return size;
}

function main() {
  // Guard: cache dir must exist
  if (!fs.existsSync(CACHE_DIR)) return;

  // Guard: need active paths to make safe decisions
  const activePaths = getActivePaths();
  if (activePaths === null) return; // missing/unreadable file -- skip entirely
  if (activePaths.size === 0) {
    process.stderr.write('[plugin-cleanup] No active paths found — skipping (possible schema change)\n');
    return;
  }

  // Walk: marketplace/plugin-name/version-hash
  const marketplaces = fs.readdirSync(CACHE_DIR, { withFileTypes: true });
  for (const mp of marketplaces) {
    if (!mp.isDirectory()) continue;
    const mpDir = path.join(CACHE_DIR, mp.name);

    const pluginNames = fs.readdirSync(mpDir, { withFileTypes: true });
    for (const pn of pluginNames) {
      if (!pn.isDirectory()) continue;
      const pluginDir = path.join(mpDir, pn.name);

      const versionDirs = fs.readdirSync(pluginDir, { withFileTypes: true });
      for (const vd of versionDirs) {
        if (!vd.isDirectory()) continue;
        const versionPath = path.join(pluginDir, vd.name);

        // Check if this version dir contains .claude-plugin marker
        const marker = path.join(versionPath, '.claude-plugin');
        if (!fs.existsSync(marker)) continue;

        // Resolve to absolute for comparison
        const absPath = path.resolve(versionPath);

        if (!activePaths.has(absPath)) {
          // Stale -- calculate size before deleting
          const size = dirSize(versionPath);
          try {
            fs.rmSync(versionPath, { recursive: true, force: true });
            cleanedDirs++;
            freedBytes += size;
          } catch (err) {
            process.stderr.write(`[plugin-cleanup] Failed to remove ${versionPath}: ${err.message}\n`);
          }
        }
      }
    }
  }

  if (cleanedDirs > 0) {
    const freedMB = (freedBytes / (1024 * 1024)).toFixed(1);
    process.stderr.write(
      `[plugin-cleanup] Removed ${cleanedDirs} stale version(s), freed ${freedMB}MB\n`
    );
  }
}

try {
  main();
} catch (err) {
  process.stderr.write(`[plugin-cleanup] Unexpected error: ${err.message}\n`);
}

// Always exit 0 -- never block session start
process.exit(0);
