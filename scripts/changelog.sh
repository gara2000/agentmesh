#!/usr/bin/env bash
# changelog.sh — Generate a grouped file-change summary between two git tags
#
# Usage: scripts/changelog.sh [from-tag] [to-tag]
#
# Defaults:
#   from-tag  — second-to-last semver tag (vX.Y.Z), sorted by version
#   to-tag    — latest semver tag (or HEAD if no tags exist yet)
#
# If fewer than two semver tags exist, prints a message and exits 0.
# Output is grouped by area: Skills, Shared, Scripts, Other.

set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ── Resolve tags ──────────────────────────────────────────────────────────────

# Collect all semver tags sorted newest-first
SEMVER_TAGS=$(git -C "$AGENTMESH" tag --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)

if [[ -n "${1:-}" ]]; then
    FROM_TAG="$1"
else
    FROM_TAG=$(echo "$SEMVER_TAGS" | sed -n '2p')
    if [[ -z "$FROM_TAG" ]]; then
        echo "No previous release to compare against."
        exit 0
    fi
fi

if [[ -n "${2:-}" ]]; then
    TO_TAG="$2"
else
    TO_TAG=$(echo "$SEMVER_TAGS" | sed -n '1p')
    if [[ -z "$TO_TAG" ]]; then
        TO_TAG="HEAD"
    fi
fi

# ── Collect changed files ─────────────────────────────────────────────────────

CHANGED=$(git -C "$AGENTMESH" diff --name-only "$FROM_TAG" "$TO_TAG" 2>/dev/null || true)

if [[ -z "$CHANGED" ]]; then
    echo "No files changed between $FROM_TAG and $TO_TAG."
    exit 0
fi

# ── Group files ───────────────────────────────────────────────────────────────

SKILLS=""
SHARED=""
SCRIPTS=""
OTHER=""

while IFS= read -r file; do
    if [[ "$file" == plugins/agentic-workflows/skills/* ]]; then
        # Extract skill name from path: plugins/agentic-workflows/skills/<name>/...
        skill_name=$(echo "$file" | sed 's|plugins/agentic-workflows/skills/||' | cut -d/ -f1)
        # Deduplicate skill names
        if ! echo "$SKILLS" | grep -qx "$skill_name"; then
            SKILLS="${SKILLS}${skill_name}"$'\n'
        fi
    elif [[ "$file" == plugins/agentic-workflows/shared/* ]]; then
        base=$(basename "$file")
        if ! echo "$SHARED" | grep -qx "$base"; then
            SHARED="${SHARED}${base}"$'\n'
        fi
    elif [[ "$file" == scripts/* ]]; then
        base=$(basename "$file")
        if ! echo "$SCRIPTS" | grep -qx "$base"; then
            SCRIPTS="${SCRIPTS}${base}"$'\n'
        fi
    else
        if ! echo "$OTHER" | grep -qx "$file"; then
            OTHER="${OTHER}${file}"$'\n'
        fi
    fi
done <<< "$CHANGED"

# ── Print summary ─────────────────────────────────────────────────────────────

echo "Changes from $FROM_TAG to $TO_TAG:"
echo ""

if [[ -n "$SKILLS" ]]; then
    echo "### Skills"
    echo "$SKILLS" | grep -v '^$' | sort | while IFS= read -r s; do
        echo "  - $s"
    done
    echo ""
fi

if [[ -n "$SHARED" ]]; then
    echo "### Shared"
    echo "$SHARED" | grep -v '^$' | sort | while IFS= read -r s; do
        echo "  - $s"
    done
    echo ""
fi

if [[ -n "$SCRIPTS" ]]; then
    echo "### Scripts"
    echo "$SCRIPTS" | grep -v '^$' | sort | while IFS= read -r s; do
        echo "  - $s"
    done
    echo ""
fi

if [[ -n "$OTHER" ]]; then
    echo "### Other"
    echo "$OTHER" | grep -v '^$' | sort | while IFS= read -r s; do
        echo "  - $s"
    done
    echo ""
fi
