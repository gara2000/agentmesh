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
#   6. Rebuilds all skills via build.sh AND produces a versioned bundle in releases/vX.Y.Z/
#   7. Generates changelog entry and prepends to CHANGELOG.md
#   8. Commits the changed files
#   9. Creates an annotated git tag
#  10. Reloads the plugin via `claude plugin update`
#  11. Prints a summary
#
# The bundle at releases/vX.Y.Z/ is gitignored (see .gitignore). To install a
# specific version from a bundle:
#   git checkout vX.Y.Z
#   ./plugins/agentic-workflows/build.sh --bundle
#   claude plugin install ~/agentmesh/releases/vX.Y.Z/

set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGIN_JSON="$AGENTMESH/plugins/agentic-workflows/.claude-plugin/plugin.json"
BUILD_SH="$AGENTMESH/plugins/agentic-workflows/build.sh"
CHANGELOG_SH="$AGENTMESH/scripts/changelog.sh"
CHANGELOG_MD="$AGENTMESH/CHANGELOG.md"

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
echo "Step 1/6: Updating plugin.json to $NEXT_VERSION..."
python3 -c "
import json
with open('$PLUGIN_JSON') as f:
    data = json.load(f)
data['version'] = '$NEXT_VERSION'
with open('$PLUGIN_JSON', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"

# ── Rebuild all skills and produce versioned bundle ───────────────────────────
echo "Step 2/6: Rebuilding skills and bundling..."
"$BUILD_SH" --bundle

# ── Generate changelog entry and prepend to CHANGELOG.md ─────────────────────
echo "Step 3/6: Updating CHANGELOG.md..."
CHANGELOG_ENTRY=$("$CHANGELOG_SH" 2>/dev/null || true)
CHANGELOG_HEADER="## v${NEXT_VERSION} — $(date -u +%Y-%m-%d)"

if [[ -n "$CHANGELOG_ENTRY" ]]; then
    SECTION="${CHANGELOG_HEADER}"$'\n'"${CHANGELOG_ENTRY}"
else
    SECTION="${CHANGELOG_HEADER}"$'\n'"No file changes detected between releases."
fi

# Prepend section below the CHANGELOG.md header (before the first ## section or at EOF)
EXISTING_CONTENT=$(cat "$CHANGELOG_MD")
# Split at first blank line after the preamble (the header block ends with a blank line)
# Strategy: insert after the first non-empty header block, before any existing ## entries
if grep -q '^## ' "$CHANGELOG_MD"; then
    # Insert before the first ## entry
    python3 - "$CHANGELOG_MD" "$SECTION" << 'PYEOF'
import sys

path = sys.argv[1]
section = sys.argv[2]

with open(path) as f:
    content = f.read()

lines = content.split('\n')
insert_at = None
for i, line in enumerate(lines):
    if line.startswith('## '):
        insert_at = i
        break

if insert_at is not None:
    new_lines = lines[:insert_at] + [section, ''] + lines[insert_at:]
else:
    new_lines = lines + ['', section]

with open(path, 'w') as f:
    f.write('\n'.join(new_lines))
PYEOF
else
    # No existing ## sections — append after existing content
    printf '\n%s\n' "$SECTION" >> "$CHANGELOG_MD"
fi
echo "  Added: $CHANGELOG_HEADER"

# ── Stage and commit ──────────────────────────────────────────────────────────
echo "Step 4/6: Committing..."
cd "$AGENTMESH"

# Stage plugin.json, all rebuilt skill files, and the updated changelog
git add "$PLUGIN_JSON"
# Stage all SKILL.md files under the plugin directory (build output)
git add plugins/agentic-workflows/skills/
git add plugins/agentic-workflows/shared/
git add "$CHANGELOG_MD"

COMMIT_MSG="release: bump plugin to v${NEXT_VERSION}"
git commit -m "$COMMIT_MSG"

# ── Create annotated tag ──────────────────────────────────────────────────────
echo "Step 5/6: Creating annotated tag $TAG..."
git tag -a "$TAG" -m "agentic-workflows plugin $NEXT_VERSION"

# ── Reload plugin ─────────────────────────────────────────────────────────────
echo "Step 6/6: Reloading plugin..."
RELOAD_STATUS=0
claude plugin update agentic-workflows@agentmesh || RELOAD_STATUS=$?

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
BUNDLE_DIR="$AGENTMESH/releases/$TAG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Release complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Old version : $CURRENT_VERSION"
echo " New version : $NEXT_VERSION"
echo " Tag created : $TAG"
echo " Bundle      : $BUNDLE_DIR"
if [[ $RELOAD_STATUS -eq 0 ]]; then
    echo " Plugin reload: OK"
else
    echo " Plugin reload: FAILED (exit $RELOAD_STATUS) — run manually:"
    echo "   claude plugin update agentic-workflows@agentmesh"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
