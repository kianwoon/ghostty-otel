#!/usr/bin/env bash
# release.sh — Deploy ghostty-otel plugin changes
# Usage: bash scripts/release.sh ["commit message"]
#
# Steps:
#   1. Validate JSON files (hooks.json, settings.json, plugin.json)
#   2. Validate Python syntax (otel-listener.py)
#   3. Verify all hook script references resolve
#   4. Ensure scripts are executable
#   5. Sync repo → marketplace directory
#   6. Reinstall plugin from local marketplace
#   7. Commit and push to remote
set -euo pipefail

MSG="${1:-chore: update ghostty-otel plugin}"
REPO="/Users/kianwoonwong/Downloads/ghostty-otel"
MARKETPLACE="/Users/kianwoonwong/claude-marketplaces/kianwoon/ghostty-otel"
PLUGIN_NAME="ghostty-otel@kianwoon"

cd "$REPO"

echo "=== Step 1: Validate JSON ==="
python3 -c "import json; json.load(open('hooks/hooks.json'))" && echo "  hooks.json OK"
python3 -c "import json; json.load(open('.claude/settings.json'))" && echo "  settings.json OK"
python3 -c "import json; json.load(open('.claude-plugin/plugin.json'))" && echo "  plugin.json OK"

echo ""
echo "=== Step 2: Validate Python ==="
python3 -c "import py_compile; py_compile.compile('scripts/otel-listener.py', doraise=True)" && echo "  otel-listener.py OK"

echo ""
echo "=== Step 3: Verify script references ==="
for script in $(grep -oP 'scripts/\K[^\s"]+' hooks/hooks.json | sort -u); do
  if [ -f "scripts/$script" ]; then
    echo "  $script OK"
  else
    echo "  ⚠️ MISSING: scripts/$script"
    exit 1
  fi
done

echo ""
echo "=== Step 4: Fix permissions ==="
find scripts -name '*.sh' -exec chmod +x {} \;
chmod +x scripts/otel-listener.py
echo "  All scripts executable"

echo ""
echo "=== Step 5: Sync to marketplace ==="
# Sync all scripts
for f in scripts/*.sh scripts/*.py; do
  cp "$f" "$MARKETPLACE/$f"
done
# Sync hooks, settings, manifest, README, CLAUDE.md
cp hooks/hooks.json "$MARKETPLACE/hooks/hooks.json"
cp .claude/settings.json "$MARKETPLACE/.claude/settings.json"
cp .claude-plugin/plugin.json "$MARKETPLACE/.claude-plugin/plugin.json"
cp README.md "$MARKETPLACE/README.md"
[ -f CLAUDE.md ] && cp CLAUDE.md "$MARKETPLACE/CLAUDE.md"
echo "  Synced all files"

echo ""
echo "=== Step 6: Reinstall plugin ==="
claude plugin install "$PLUGIN_NAME" --scope user

echo ""
echo "=== Step 7: Git commit + push ==="
git add -A
git status --short
git commit -m "$MSG" || echo "  Nothing to commit"
git push origin main

echo ""
echo "=== Done ==="
