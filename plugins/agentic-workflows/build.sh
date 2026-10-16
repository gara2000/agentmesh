#!/usr/bin/env bash
# build.sh — Resolves 'extends' in skill frontmatter, refreshes BASE-AGENT marker blocks,
#            expands <!-- SIGNAL: <name> --> macros to full bash interaction blocks,
#            substitutes per-skill variables ({{AGENT_USER}}, {{LOG_PREFIX}}, {{ROLE}}),
#            and expands the {{AGENTMESH}} path variable in all skill files.
#
# Usage:
#   ./build.sh                        # refresh all skills with 'extends' frontmatter
#   ./build.sh worker                 # refresh a specific skill by name
#   ./build.sh --update-family-bases  # propagate base-agent.md changes into family base files
#
# Inheritance model:
#   base-agent.md (NoteCove comment protocol: arg parsing, paths, post/await/read)
#     └── base-implementer.md  (+ folder management, exploration, questions, triage)
#           └── skills via 'extends:' frontmatter
#
# When a skill 'extends' a family base file (e.g. base-implementer.md), build.sh reads the
# family file as the base content and injects it into the skill's BASE-AGENT block. The family
# file itself contains a nested BASE-AGENT block (the embedded base-agent.md content). To avoid
# double-nesting in the built skill, build.sh strips the two BASE-AGENT delimiter lines from the
# family file before injection — keeping all content between them. The result is a flat,
# idempotent BASE-AGENT block in the skill that contains everything from the family file.
#
# --update-family-bases:
#   Propagates base-agent.md content into the family base files (base-implementer.md).
#   This is ONLY a marker-replacement step — it does NOT run SIGNAL macro expansion or
#   variable substitution ({{AGENT_USER}} etc.). Those steps require per-skill
#   frontmatter values and are only valid during skill builds.
#   Run --update-family-bases whenever base-agent.md changes, then run ./build.sh to
#   rebuild all skills.
#
# How skill building works:
#   1. Scans skills/*/SKILL.md for an 'extends: <path>' frontmatter key.
#   2. Resolves the path relative to the skill directory.
#   3. Reads the base file; strips its inner BASE-AGENT delimiter lines (flattens nested markers).
#   4. Replaces the skill's BASE-AGENT block with the flattened base content.
#   5. Expands <!-- SIGNAL: <name> --> markers into full bash code snippets.
#      Errors clearly if an unknown macro name is encountered.
#   6. Substitutes {{AGENT_USER}}, {{LOG_PREFIX}}, and {{ROLE}} from frontmatter.
#      Errors if any key is missing.
#   7. Expands {{AGENTMESH}} in all skill files.
#
# To add a new role that inherits the shared base:
#   1. Create skills/<role>/SKILL.md with 'extends: ../../shared/base-implementer.md'
#      in frontmatter.
#      Declare 'agent-user', 'log-prefix', and 'role' keys — all three are required.
#      'agent-user' MUST match the --user value the skill writes comments with: the
#      sidecar filters the agent's own comments by author name.
#   2. Add <!-- BASE-AGENT:START --> and <!-- BASE-AGENT:END --> markers where shared
#      content should be injected.
#   3. Use <!-- SIGNAL: await --> at each point the agent hands the task back to the
#      user, and <!-- SIGNAL: resume --> at the top of a turn a delivered message started.
#   4. Run ./build.sh to populate the markers.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$PLUGIN_DIR/skills"
SHARED_DIR="$PLUGIN_DIR/shared"
BASE_AGENT="$SHARED_DIR/base-agent.md"
FILTER="${1:-}"

# Use ~/agentmesh as the canonical path — portable across machines without hardcoding
# the absolute home directory path. The shell expands ~ at runtime when the skill runs.
AGENTMESH_PATH="~/agentmesh"

# ---------------------------------------------------------------------------
# --update-family-bases: propagate base-agent.md into family base files only.
# This is a pure marker-replacement pass — no macro expansion, no variable
# substitution, no EVENTS-TABLE generation (those require per-skill frontmatter).
# ---------------------------------------------------------------------------
if [ "$FILTER" = "--update-family-bases" ]; then
    if [ ! -f "$BASE_AGENT" ]; then
        echo "ERROR: base-agent.md not found: $BASE_AGENT" >&2
        exit 1
    fi
    family_updated=0
    for family_file in "$SHARED_DIR"/base-*.md; do
        fname="$(basename "$family_file")"
        [ "$fname" = "base-agent.md" ] && continue  # skip the root itself
        if ! grep -q '<!-- BASE-AGENT:START' "$family_file" 2>/dev/null; then
            continue  # not a family base file
        fi
        python3 - "$family_file" "$BASE_AGENT" << 'PYEOF'
import sys, re

family_file = sys.argv[1]
base_file   = sys.argv[2]

with open(family_file) as f:
    content = f.read()
with open(base_file) as f:
    base_content = f.read().rstrip('\n')

start_marker = '<!-- BASE-AGENT:START (do not edit — run ./build.sh --update-family-bases to refresh) -->'
end_marker   = '<!-- BASE-AGENT:END -->'
replacement  = f'{start_marker}\n{base_content}\n{end_marker}'

pattern = r'<!-- BASE-AGENT:START.*?-->.*?<!-- BASE-AGENT:END -->'
if not re.search(pattern, content, re.DOTALL):
    print(f"ERROR: BASE-AGENT markers not found in {family_file}", file=sys.stderr)
    sys.exit(1)

new_content = re.sub(pattern, lambda m: replacement, content, flags=re.DOTALL, count=1)

with open(family_file, 'w') as f:
    f.write(new_content)

print(f"  ✓ {family_file.split('/')[-1]}  ←  base-agent.md")
PYEOF
        family_updated=$((family_updated + 1))
    done
    echo ""
    echo "Done. $family_updated family base file(s) updated."
    echo "Run ./build.sh to rebuild all skills."
    exit 0
fi

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

    # Replace content between markers using Python (handles multiline reliably).
    # If the base file is a family file (base-implementer.md, base-reviewer.md), it contains
    # its own BASE-AGENT marker block wrapping the embedded base-agent.md content. Strip those
    # two delimiter lines before injection so the skill ends up with a single flat BASE-AGENT
    # block — no nested markers. Only the delimiter lines are removed; all content between them
    # (and after the end marker) is preserved verbatim.
    python3 - "$skill_md" "$base_file" << 'PYEOF'
import sys, re

skill_file = sys.argv[1]
base_file  = sys.argv[2]

with open(skill_file) as f:
    content = f.read()
with open(base_file) as f:
    base_content = f.read().rstrip('\n')

# Flatten any nested BASE-AGENT marker delimiter lines in the base file content.
# This handles family files that embed base-agent.md via their own BASE-AGENT block.
# Strip only the two delimiter lines; keep all content between them and after END.
base_content = re.sub(r'^<!-- BASE-AGENT:START[^\n]*-->\n', '', base_content, flags=re.MULTILINE)
base_content = re.sub(r'^<!-- BASE-AGENT:END -->\n?', '', base_content, flags=re.MULTILINE)
base_content = base_content.rstrip('\n')

start_marker = '<!-- BASE-AGENT:START (do not edit — run ./build.sh to refresh) -->'
end_marker   = '<!-- BASE-AGENT:END -->'
replacement  = f'{start_marker}\n{base_content}\n{end_marker}'

pattern = r'<!-- BASE-AGENT:START.*?-->.*?<!-- BASE-AGENT:END -->'
if not re.search(pattern, content, re.DOTALL):
    print(f"ERROR: markers not found in {skill_file}", file=sys.stderr)
    sys.exit(1)

new_content = re.sub(pattern, lambda m: replacement, content, flags=re.DOTALL)

with open(skill_file, 'w') as f:
    f.write(new_content)
PYEOF

    # Expand <!-- SIGNAL: <name> --> macros into full bash signal blocks.
    # Must run after BASE-AGENT injection (macros may come from base-agent.md)
    # and before variable substitution (so {{AGENT_USER}}/{{LOG_PREFIX}} in
    # the expansions are resolved in the same substitution pass).
    python3 - "$skill_md" << 'PYEOF'
import sys, re

skill_file = sys.argv[1]

# ---------------------------------------------------------------------------
# Signal macro definitions.
# Each macro expands to a ```bash ... ``` code block.
# {{AGENT_USER}} and {{LOG_PREFIX}} are resolved by the variable-substitution
# step that runs immediately after this one.
# ---------------------------------------------------------------------------
SIGNAL_MACROS = {
    # The comment protocol has exactly one interaction shape: say what happened,
    # hand the task back, end the turn. There are no per-event variants because
    # the orchestrator that used to dispatch on event type is gone.
    #
    # Nothing blocks. The sidecar types a message into this worker's Claude REPL
    # when the user replies, which arrives as a new turn — so anything written
    # after request_attention in the same turn is simply never reached by that
    # reply. <state> defaults to Attention; pass a different state only when the
    # agent is parking the task somewhere else on purpose.
    'await': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tawaiting-user\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
post_summary "<brief summary — a few sentences; link any note you wrote>"
request_attention "Attention"
```

**Then end your turn.** Do not poll, do not sleep, do not run anything else. The sidecar delivers the user's reply into your REPL as a new turn; your next turn starts with `resume_work` and `read_inbox`.''',

    # The other half of the cycle: what to run at the top of a turn that a
    # delivered message started.
    'resume': '''\
```bash
source {{AGENTMESH}}/scripts/agent-notecove.sh
agent_init "<slug>" "{{AGENT_USER}}"
resume_work                # back to Doing — you are working again
read_inbox                 # what the sidecar had to tell you
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',
}

with open(skill_file) as f:
    content = f.read()

def expand_macro(m):
    name = m.group(1).strip()
    if name not in SIGNAL_MACROS:
        print(f"ERROR: unknown SIGNAL macro name '{name}' in {skill_file}", file=sys.stderr)
        print(f"       Valid names: {sorted(SIGNAL_MACROS.keys())}", file=sys.stderr)
        sys.exit(1)
    return SIGNAL_MACROS[name]

new_content = re.sub(r'<!-- SIGNAL: ([^>]+) -->', expand_macro, content)

with open(skill_file, 'w') as f:
    f.write(new_content)

skill_name = skill_file.split('/')[-2]
count = len(re.findall(r'<!-- SIGNAL: [^>]+ -->', content))
if count:
    print(f"  ✓ {skill_name} — expanded {count} SIGNAL macro(s)")
PYEOF

    # Substitute {{AGENT_USER}}, {{LOG_PREFIX}}, and {{ROLE}} from frontmatter
    python3 - "$skill_md" << 'PYEOF'
import sys, re

skill_file = sys.argv[1]

with open(skill_file) as f:
    content = f.read()

# Extract frontmatter (between first two '---' lines)
fm_match = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
if not fm_match:
    print(f"ERROR: no YAML frontmatter found in {skill_file}", file=sys.stderr)
    sys.exit(1)
fm = fm_match.group(1)

def extract_fm_value(fm, key):
    # Match quoted value: key: "value with spaces"
    m = re.search(rf'^{key}:\s*"([^"\n]*)"', fm, re.MULTILINE)
    if m:
        return m.group(1)
    # Match unquoted value (strip trailing whitespace only)
    m = re.search(rf'^{key}:\s*([^"\n]+)', fm, re.MULTILINE)
    return m.group(1).rstrip() if m else None

agent_user = extract_fm_value(fm, 'agent-user')
log_prefix = extract_fm_value(fm, 'log-prefix')
role       = extract_fm_value(fm, 'role')

if agent_user is None:
    print(f"ERROR: 'agent-user' not declared in frontmatter of {skill_file}", file=sys.stderr)
    sys.exit(1)
if log_prefix is None:
    print(f"ERROR: 'log-prefix' not declared in frontmatter of {skill_file}", file=sys.stderr)
    sys.exit(1)
if role is None:
    print(f"ERROR: 'role' not declared in frontmatter of {skill_file}", file=sys.stderr)
    sys.exit(1)

new_content = (content
    .replace('{{AGENT_USER}}', agent_user)
    .replace('{{LOG_PREFIX}}', log_prefix)
    .replace('{{ROLE}}', role))

with open(skill_file, 'w') as f:
    f.write(new_content)

print(f"  ✓ {skill_file.split('/')[-2]} — substituted {{AGENT_USER}}={agent_user!r}, {{LOG_PREFIX}}={log_prefix!r}, {{ROLE}}={role!r}")
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
