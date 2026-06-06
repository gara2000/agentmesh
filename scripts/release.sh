#!/usr/bin/env bash
# release.sh — Git-tag-based release workflow for the agentic-workflows plugin
#
# Usage: ./scripts/release.sh [patch|minor|major]
#
# What it does:
#   1. Validates the bump type argument
#   2. Reads current version from plugin.json
#   3. Computes the next semver version
#   4. Aborts if the tag already exists (idempotency guard)
#   5. Writes the new version to plugin.json
#   6. Rebuilds all skills via build.sh
#   7. Commits the changed files
#   8. Creates an annotated git tag
#   9. Reloads the plugin via `claude plugin update`
#  10. Prints a summary

set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGIN_JSON="$AGENTMESH/plugins/agentic-workflows/.claude-plugin/plugin.json"
BUILD_SH="$AGENTMESH/plugins/agentic-workflows/build.sh"

# ── Argument validation ───────────────────────────────────────────────────────
BUMP_TYPE="${1:-}"
if [[ -z "$BUMP_TYPE" ]]; then
    echo "Usage: $(basename "$0") [patch|minor|major]" >&2
    exit 1
fi
if [[ "$BUMP_TYPE" != patch && "$BUMP_TYPE" != minor && "$BUMP_TYPE" != major ]]; then
    echo "Error: bump type must be 'patch', 'minor', or 'major' (got: '$BUMP_TYPE')" >&2
    exit 1
fi

# ── Read current version ──────────────────────────────────────────────────────
if [[ ! -f "$PLUGIN_JSON" ]]; then
    echo "Error: plugin.json not found at $PLUGIN_JSON" >&2
    exit 1
fi

CURRENT_VERSION=$(python3 -c "
import json, sys
with open('$PLUGIN_JSON') as f:
    data = json.load(f)
print(data['version'])
")

# ── Compute next version ──────────────────────────────────────────────────────
NEXT_VERSION=$(python3 -c "
import sys
parts = '$CURRENT_VERSION'.split('.')
if len(parts) != 3:
    print('Error: unexpected version format: $CURRENT_VERSION', file=sys.stderr)
    sys.exit(1)
major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])
bump = '$BUMP_TYPE'
if bump == 'major':
    major += 1; minor = 0; patch = 0
elif bump == 'minor':
    minor += 1; patch = 0
else:
    patch += 1
print(f'{major}.{minor}.{patch}')
")

TAG="v${NEXT_VERSION}"

# ── Idempotency guard: abort if tag already exists ────────────────────────────
if git -C "$AGENTMESH" tag --list "$TAG" | grep -q "^${TAG}$"; then
    echo "Error: git tag '$TAG' already exists. Aborting without making any changes." >&2
    exit 1
fi

echo "Releasing: $CURRENT_VERSION → $NEXT_VERSION  ($BUMP_TYPE bump)"
echo ""

# ── Write new version to plugin.json ─────────────────────────────────────────
echo "Step 1/5: Updating plugin.json to $NEXT_VERSION..."
python3 -c "
import json
with open('$PLUGIN_JSON') as f:
    data = json.load(f)
data['version'] = '$NEXT_VERSION'
with open('$PLUGIN_JSON', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"

# ── Rebuild all skills ────────────────────────────────────────────────────────
echo "Step 2/5: Rebuilding skills..."
"$BUILD_SH"

# ── Stage and commit ──────────────────────────────────────────────────────────
echo "Step 3/5: Committing..."
cd "$AGENTMESH"

# Stage plugin.json and all rebuilt skill files
git add "$PLUGIN_JSON"
# Stage all SKILL.md files under the plugin directory (build output)
git add plugins/agentic-workflows/skills/
git add plugins/agentic-workflows/shared/

COMMIT_MSG="release: bump plugin to v${NEXT_VERSION}"
git commit -m "$COMMIT_MSG"

# ── Create annotated tag ──────────────────────────────────────────────────────
echo "Step 4/5: Creating annotated tag $TAG..."
git tag -a "$TAG" -m "agentic-workflows plugin $NEXT_VERSION"

# ── Reload plugin ─────────────────────────────────────────────────────────────
echo "Step 5/5: Reloading plugin..."
RELOAD_STATUS=0
claude plugin update agentic-workflows@agentmesh || RELOAD_STATUS=$?

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Release complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Old version : $CURRENT_VERSION"
echo " New version : $NEXT_VERSION"
echo " Tag created : $TAG"
if [[ $RELOAD_STATUS -eq 0 ]]; then
    echo " Plugin reload: OK"
else
    echo " Plugin reload: FAILED (exit $RELOAD_STATUS) — run manually:"
    echo "   claude plugin update agentic-workflows@agentmesh"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
