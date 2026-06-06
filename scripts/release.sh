#!/usr/bin/env bash
# release.sh — Workflow-level release for AgentMesh
#
# Usage: ./scripts/release.sh [patch|minor|major]
#
# What it does:
#   1. Validates the bump type argument
#   2. Pulls latest from remote (git pull --rebase)
#   3. Reads current version from VERSION
#   4. Computes the next semver version
#   5. Aborts if the tag already exists (idempotency guard)
#   6. Writes the new version to VERSION
#   7. Generates changelog entry and prepends to CHANGELOG.md
#   8. Commits VERSION and CHANGELOG.md
#   9. Creates an annotated git tag vX.Y.Z
#  10. Pushes commit and tag to remote
#  11. Reloads the plugin via `claude plugin update`
#  12. Prints a summary
#
# Note: plugin.json version is independent of the workflow version.
# Plugin version is bumped by developers when changing skills or scripts
# (enforced by the pre-commit hook). The workflow version here tracks
# releases of the overall tool — multiple plugin bumps may land in one
# workflow release, or a script-only change with no plugin bump may
# still warrant a workflow release.

set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION_FILE="$AGENTMESH/VERSION"
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

# ── Pull latest from remote ───────────────────────────────────────────────────
echo "Step 1/7: Pulling latest from remote..."
cd "$AGENTMESH"
git pull --rebase

# ── Read current version ──────────────────────────────────────────────────────
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "Error: VERSION file not found at $VERSION_FILE" >&2
    exit 1
fi

CURRENT_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")

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
if git tag --list "$TAG" | grep -q "^${TAG}$"; then
    echo "Error: git tag '$TAG' already exists. Aborting without making any changes." >&2
    exit 1
fi

echo "Releasing: $CURRENT_VERSION → $NEXT_VERSION  ($BUMP_TYPE bump)"
echo ""

# ── Write new version to VERSION ─────────────────────────────────────────────
echo "Step 2/7: Updating VERSION to $NEXT_VERSION..."
echo "$NEXT_VERSION" > "$VERSION_FILE"

# ── Generate changelog entry and prepend to CHANGELOG.md ─────────────────────
echo "Step 3/7: Updating CHANGELOG.md..."
CHANGELOG_ENTRY=$("$CHANGELOG_SH" 2>/dev/null || true)
CHANGELOG_HEADER="## v${NEXT_VERSION} — $(date -u +%Y-%m-%d)"

if [[ -n "$CHANGELOG_ENTRY" ]]; then
    SECTION="${CHANGELOG_HEADER}"$'\n'"${CHANGELOG_ENTRY}"
else
    SECTION="${CHANGELOG_HEADER}"$'\n'"No file changes detected between releases."
fi

# Prepend section below the CHANGELOG.md header (before the first ## section or at EOF)
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
echo "Step 4/7: Committing..."
git add "$VERSION_FILE"
git add "$CHANGELOG_MD"

git commit -m "release: v${NEXT_VERSION}"

# ── Create annotated tag ──────────────────────────────────────────────────────
echo "Step 5/7: Creating annotated tag $TAG..."
git tag -a "$TAG" -m "AgentMesh $NEXT_VERSION"

# ── Push commit and tag to remote ─────────────────────────────────────────────
echo "Step 6/7: Pushing to remote..."
git push
git push origin "$TAG"

# ── Reload plugin ─────────────────────────────────────────────────────────────
echo "Step 7/7: Reloading plugin..."
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
