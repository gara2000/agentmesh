#!/usr/bin/env bash
# build.sh — Resolves 'extends' in skill frontmatter, refreshes BASE-AGENT marker blocks,
#            expands <!-- SIGNAL: <name> --> macros to full bash signal blocks,
#            substitutes per-skill variables ({{AGENT_USER}}, {{LOG_PREFIX}}, {{ROLE}}),
#            generates per-skill EVENTS-TABLE sections from 'events:' frontmatter,
#            and expands the {{AGENTMESH}} path variable in all skill files.
#
# Usage:
#   ./build.sh                        # refresh all skills with 'extends' frontmatter
#   ./build.sh worker                 # refresh a specific skill by name
#   ./build.sh --update-family-bases  # propagate base-agent.md changes into family base files
#
# Inheritance model:
#   base-agent.md (pure signal protocol)
#     └── base-implementer.md  (+ folder management, exploration, questions, triage)
#     └── base-reviewer.md     (+ fire-and-done role, folder lookup, review conventions)
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
#   Propagates base-agent.md content into base-implementer.md and base-reviewer.md.
#   This is ONLY a marker-replacement step — it does NOT run SIGNAL macro expansion,
#   variable substitution ({{AGENT_USER}} etc.), or EVENTS-TABLE generation. Those steps
#   require per-skill frontmatter values and are only valid during skill builds.
#   Run --update-family-bases whenever base-agent.md changes, then run ./build.sh to
#   rebuild all skills.
#
# How skill building works:
#   1. Scans skills/*/SKILL.md for an 'extends: <path>' frontmatter key.
#   2. Resolves the path relative to the skill directory.
#   3. Reads the base file; strips its inner BASE-AGENT delimiter lines (flattens nested markers).
#   4. Replaces the skill's BASE-AGENT block with the flattened base content.
#   5. Expands <!-- SIGNAL: <name> --> markers into full bash signal-block code snippets.
#      Errors clearly if an unknown macro name is encountered.
#   6. Substitutes {{AGENT_USER}}, {{LOG_PREFIX}}, and {{ROLE}} from frontmatter.
#      Errors if any key is missing.
#   7. Generates per-skill EVENTS-TABLE from 'events:' frontmatter list.
#   8. Expands {{AGENTMESH}} in all skill files.
#
# To add a new role that inherits the shared base:
#   1. Create skills/<role>/SKILL.md with 'extends: ../../shared/base-implementer.md'
#      (or base-reviewer.md for reviewer roles) in frontmatter.
#      Declare 'agent-user', 'log-prefix', and 'role' keys — all three are required.
#   2. Add <!-- BASE-AGENT:START --> and <!-- BASE-AGENT:END --> markers where shared
#      content should be injected.
#   3. Add <!-- EVENTS-TABLE:START --> / <!-- EVENTS-TABLE:END --> markers and 'events:'
#      frontmatter list.
#   4. Use <!-- SIGNAL: <name> --> markers where signal blocks are needed.
#   5. Run ./build.sh to populate the markers.

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

new_content = re.sub(pattern, replacement, content, flags=re.DOTALL, count=1)

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

new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

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
    # --- blocking macros (signal_attention) ---
    'questions': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-attention\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:questions"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:questions" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    'plan-ready': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-attention\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:plan-ready"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:plan-ready" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    'plan-revised': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-attention\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:plan-revised"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:plan-revised" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    'ideas-ready': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-attention\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:ideas-ready"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:ideas-ready" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    'selection-ready': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-attention\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:selection-ready"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:selection-ready" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    'design-ready': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-design\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:design-ready"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:design-ready" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed-from-design\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    'design-revised': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-design-revised\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:design-revised"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:design-revised" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed-from-design-revised\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    'completion': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-attention\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:completion"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:completion" "done"
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    # --- PR blocking macros (signal_attention, break on done OR doing) ---
    'pr-ready': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-attention\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:pr-ready:$PR_URL"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
# Break on either \'done\' (approved) or \'doing\' (feedback given)
signal_attention "event:pr-ready:$PR_URL" "done" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    'pr-revised': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-attention\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:pr-revised:$PR_URL"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
# Break on either \'done\' (approved) or \'doing\' (feedback given)
signal_attention "event:pr-revised:$PR_URL" "done" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    'pr-ready-final': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tsignaling-attention\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "{{AGENT_USER}}" "event:pr-ready-final:$PR_URL"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
# Break on either \'done\' (approved) or \'doing\' (feedback given)
signal_attention "event:pr-ready-final:$PR_URL" "done" "doing"
printf '%s\\t{{LOG_PREFIX}}\\tresumed\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```''',

    # --- fire-and-done macros (signal_fire, no blocking) ---
    'plan-review-complete': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tplan-review-complete\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
# NOTE: signal_fire does NOT update signals/<slug>.seq — the worker\'s seq must remain intact
#       so the orchestrator can resume the worker with the correct signal
notecove task change <slug> --state Attention
signal_fire "event:plan-review-complete"
```''',

    'pr-review-complete': '''\
```bash
printf '%s\\t{{LOG_PREFIX}}\\tpr-review-complete\\t<slug>\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
# NOTE: signal_fire does NOT update signals/<slug>.seq — the worker\'s seq must remain intact
#       so the orchestrator can resume the worker with the correct signal
notecove task change <slug> --state Attention
signal_fire "event:pr-review-complete"
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

    # Generate and inject EVENTS-TABLE from frontmatter 'events:' list
    python3 - "$skill_md" "$PLUGIN_DIR/shared/protocol.yaml" << 'PYEOF'
import sys, re

skill_file    = sys.argv[1]
protocol_file = sys.argv[2]

# Load event meanings from protocol.yaml (single source of truth).
# url_bearing events are keyed as '<name>:<url>' to match the skill frontmatter convention.
try:
    import yaml
    with open(protocol_file) as f:
        protocol = yaml.safe_load(f)
    EVENT_MEANINGS = {}
    for name, attrs in protocol.get("events", {}).items():
        meaning     = attrs.get("meaning", "")
        url_bearing = attrs.get("url_bearing", False)
        key = f"{name}:<url>" if url_bearing else name
        EVENT_MEANINGS[key] = meaning
except FileNotFoundError:
    print(f"ERROR: protocol.yaml not found at {protocol_file}", file=sys.stderr)
    sys.exit(1)

with open(skill_file) as f:
    content = f.read()

# Extract frontmatter
fm_match = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
if not fm_match:
    sys.exit(0)  # no frontmatter — skip
fm = fm_match.group(1)

# Extract 'events:' YAML list
events_block = re.search(r'^events:\n((?:  - .+\n?)+)', fm, re.MULTILINE)
if not events_block:
    sys.exit(0)  # no events: list — skip (not all skills have one)

events = re.findall(r'  - (.+)', events_block.group(1))

# Validate all event names against the static lookup
unknown = [e for e in events if e not in EVENT_MEANINGS]
if unknown:
    print(f"ERROR: unknown event name(s) in {skill_file}: {unknown}", file=sys.stderr)
    print(f"       Valid event names: {list(EVENT_MEANINGS.keys())}", file=sys.stderr)
    sys.exit(1)

# Check that EVENTS-TABLE markers exist
start_marker = '<!-- EVENTS-TABLE:START (do not edit — run ./build.sh to refresh) -->'
end_marker   = '<!-- EVENTS-TABLE:END -->'
if start_marker not in content and '<!-- EVENTS-TABLE:START' not in content:
    print(f"ERROR: 'events:' frontmatter found but no <!-- EVENTS-TABLE:START --> marker in {skill_file}", file=sys.stderr)
    print(f"       Add <!-- EVENTS-TABLE:START --> and <!-- EVENTS-TABLE:END --> markers after the frontmatter block.", file=sys.stderr)
    sys.exit(1)

# Generate the events table
rows = []
for event in events:
    tag = f'event:{event}'
    queue_entry = f'`<slug>:{tag}`'
    meaning = EVENT_MEANINGS[event]
    rows.append(f'| `{tag}` | {queue_entry} | {meaning} |')

table = '## Events This Agent Fires\n\n'
table += '| Event tag | Queue entry | Meaning |\n'
table += '|---|---|---|\n'
table += '\n'.join(rows) + '\n'

replacement = f'{start_marker}\n{table}{end_marker}'
pattern = r'<!-- EVENTS-TABLE:START.*?-->.*?<!-- EVENTS-TABLE:END -->'
if not re.search(pattern, content, re.DOTALL):
    print(f"ERROR: EVENTS-TABLE markers not found in {skill_file}", file=sys.stderr)
    sys.exit(1)

new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open(skill_file, 'w') as f:
    f.write(new_content)

skill_name = skill_file.split('/')[-2]
print(f"  ✓ {skill_name} — generated EVENTS-TABLE ({len(events)} event(s))")
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
