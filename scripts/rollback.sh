#!/usr/bin/env bash
# rollback.sh — One-command plugin rollback to a previously released version
#
# Usage: ./scripts/rollback.sh <version>
#
# <version> can be:
#   v2.13.0   (with leading v)
#   2.13.0    (without — normalized automatically)
#
# What it does:
#   1. Normalizes the version argument to vX.Y.Z
#   2. Verifies the git tag vX.Y.Z exists; aborts if not
#   3. Verifies the working tree is clean; aborts if dirty
#   4. Restores plugins/agentic-workflows/ and scripts/ from the tag
#      (file-level restore — HEAD is NOT moved)
#   5. Rebuilds skills via build.sh
#   6. Reloads the plugin via `claude plugin update`
#   7. Prints a summary, including a reminder that HEAD is unchanged

set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION_FILE="$AGENTMESH/VERSION"
BUILD_SH="$AGENTMESH/plugins/agentic-workflows/build.sh"

# ── Argument validation ───────────────────────────────────────────────────────
VERSION_ARG="${1:-}"
if [[ -z "$VERSION_ARG" ]]; then
    echo "Usage: $(basename "$0") <version>" >&2
    echo "  Example: $(basename "$0") v2.13.0" >&2
    exit 1
fi

# Normalize: strip leading 'v', then prepend it
VERSION_BARE="${VERSION_ARG#v}"
TAG="v${VERSION_BARE}"

# Basic semver format check
if ! [[ "$VERSION_BARE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version must be in X.Y.Z format (got: '$VERSION_ARG')" >&2
    exit 1
fi

# ── Verify tag exists ─────────────────────────────────────────────────────────
cd "$AGENTMESH"
if ! git tag --list "$TAG" | grep -q "^${TAG}$"; then
    echo "Error: git tag '$TAG' does not exist." >&2
    echo "  Available tags:" >&2
    git tag --list 'v*' | sort -V | tail -10 | sed 's/^/    /' >&2
    exit 1
fi

# ── Verify working tree is clean ──────────────────────────────────────────────
DIRTY=$(git status --porcelain)
if [[ -n "$DIRTY" ]]; then
    echo "Error: working tree has uncommitted changes — rolling back on a dirty state is unsafe." >&2
    echo "  Please commit or stash your changes first." >&2
    echo "" >&2
    echo "  Uncommitted changes:" >&2
    git status --short | sed 's/^/    /' >&2
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)

echo "Rolling back to $TAG (from branch: $CURRENT_BRANCH)"
echo ""

# ── Restore plugin and scripts from tag ──────────────────────────────────────
echo "Step 1/3: Restoring files from $TAG..."
git checkout "$TAG" -- plugins/agentic-workflows/
git checkout "$TAG" -- scripts/

# Read version from the restored VERSION file to confirm what we got
RESTORED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || echo "unknown")

# ── Rebuild skills ─────────────────────────────────────────────────────────────
echo "Step 2/3: Rebuilding skills..."
"$BUILD_SH"

# ── Reload plugin ─────────────────────────────────────────────────────────────
echo "Step 3/3: Reloading plugin..."
RELOAD_STATUS=0
claude plugin update agentic-workflows@agentmesh || RELOAD_STATUS=$?

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Rollback complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Rolled back to : $TAG (plugin version $RESTORED_VERSION)"
echo " Files restored : plugins/agentic-workflows/, scripts/"
if [[ $RELOAD_STATUS -eq 0 ]]; then
    echo " Plugin reload  : OK"
else
    echo " Plugin reload  : FAILED (exit $RELOAD_STATUS) — run manually:"
    echo "   claude plugin update agentic-workflows@agentmesh"
fi
echo ""
echo " NOTE: HEAD is still on branch '$CURRENT_BRANCH' — this was a"
echo " file-level restore only, not a branch reset. Your git history"
echo " is unchanged. To make the rollback permanent, commit the"
echo " restored files or create a new release."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
