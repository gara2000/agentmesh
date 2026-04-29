#!/usr/bin/env bash
# build.sh — Resolves 'extends' in skill frontmatter, refreshes BASE-AGENT marker blocks,
#            and expands the {{AGENTMESH}} path variable in all skill files.
#
# Usage:
#   ./build.sh              # refresh all skills with 'extends' frontmatter
#   ./build.sh worker       # refresh a specific skill by name
#
# How it works:
#   1. Scans skills/*/SKILL.md for an 'extends: <path>' frontmatter key.
#   2. Resolves the path relative to the skill directory.
#   3. Replaces the content between <!-- BASE-AGENT:START --> and <!-- BASE-AGENT:END -->
#      with the content of the referenced base file.
#   4. Expands {{AGENTMESH}} to the repo root (resolved via git) in every skill file.
#
# The {{AGENTMESH}} placeholder allows skill source files to stay portable across
# machines — run ./build.sh after cloning to stamp the correct absolute path.
#
# To add a new role that inherits the shared base:
#   1. Create skills/<role>/SKILL.md with 'extends: ../../shared/base-agent.md' in frontmatter.
#   2. Add <!-- BASE-AGENT:START --> and <!-- BASE-AGENT:END --> markers where the shared
#      content should be injected.
#   3. Run ./build.sh to populate the markers.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$PLUGIN_DIR/skills"
FILTER="${1:-}"

# Use ~/agentmesh as the canonical path — portable across machines without hardcoding
# the absolute home directory path. The shell expands ~ at runtime when the skill runs.
AGENTMESH_PATH="~/agentmesh"

updated=0
skipped=0

for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
    skill_name="$(basename "$(dirname "$skill_md")")"

    # Apply filter if provided
    if [ -n "$FILTER" ] && [ "$skill_name" != "$FILTER" ]; then
        continue
    fi

    # Extract 'extends' value from YAML frontmatter
    extends_val="$(awk '/^---$/{if(NR==1){in_fm=1; next} else {exit}} in_fm && /^extends:/{print; exit}' "$skill_md" | sed 's/^extends:[[:space:]]*//')"

    if [ -z "$extends_val" ]; then
        skipped=$((skipped + 1))
        continue
    fi

    # Resolve path relative to the skill's own directory
    skill_dir="$(dirname "$skill_md")"
    base_file="$skill_dir/$extends_val"

    if [ ! -f "$base_file" ]; then
        echo "ERROR: base file not found: $base_file (referenced from $skill_md)" >&2
        exit 1
    fi

    # Check that the markers exist in the skill file
    if ! grep -q '<!-- BASE-AGENT:START' "$skill_md"; then
        echo "ERROR: no <!-- BASE-AGENT:START --> marker found in $skill_md" >&2
        echo "       Add <!-- BASE-AGENT:START --> and <!-- BASE-AGENT:END --> where shared content should go." >&2
        exit 1
    fi

    # Replace content between markers using Python (handles multiline reliably)
    python3 - "$skill_md" "$base_file" << 'PYEOF'
import sys, re

skill_file = sys.argv[1]
base_file  = sys.argv[2]

with open(skill_file) as f:
    content = f.read()
with open(base_file) as f:
    base_content = f.read().rstrip('\n')

start_marker = '<!-- BASE-AGENT:START (do not edit — run ./build.sh to refresh) -->'
end_marker   = '<!-- BASE-AGENT:END -->'
replacement  = f'{start_marker}\n{base_content}\n{end_marker}'

pattern = r'<!-- BASE-AGENT:START.*?-->.*?<!-- BASE-AGENT:END -->'
if not re.search(pattern, content, re.DOTALL):
    print(f"ERROR: markers not found in {skill_file}", file=sys.stderr)
    sys.exit(1)

new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open(skill_file, 'w') as f:
    f.write(new_content)
PYEOF

    echo "  ✓ $skill_name  ←  $(basename "$base_file")"
    updated=$((updated + 1))
done

if [ "$updated" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "No skills found in $SKILLS_DIR"
    exit 1
fi

# Expand {{AGENTMESH}} in all skill files (covers both 'extends' skills and standalone ones)
expanded=0
for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
    skill_name="$(basename "$(dirname "$skill_md")")"

    # Apply filter if provided
    if [ -n "$FILTER" ] && [ "$skill_name" != "$FILTER" ]; then
        continue
    fi

    if grep -q '{{AGENTMESH}}' "$skill_md" 2>/dev/null; then
        sed -i '' "s|{{AGENTMESH}}|$AGENTMESH_PATH|g" "$skill_md"
        echo "  ✓ $skill_name — expanded {{AGENTMESH}} → $AGENTMESH_PATH"
        expanded=$((expanded + 1))
    fi
done

echo ""
echo "Done. $updated skill(s) updated, $skipped skill(s) skipped (no 'extends'), $expanded skill(s) path-expanded."
