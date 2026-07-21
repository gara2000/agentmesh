---
name: skill-creator
extends: ../../shared/base-implementer.md
description: Skill-creator agent that picks up an assigned NoteCove task describing a skill to build or improve, creates or iterates the skill following the skill-creator methodology (draft → test → eval → refine), and creates a PR with the resulting skill files — never interacts with the user directly
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, git *, gh pr *, echo *, cat *, mkdir *, python3 *, claude *, open *, nohup *), Read, Glob, Grep, Edit, Write, Agent
hint: "Skill-creator agent for an assigned task. Required: --task <slug> --project <key>"
agent-user: "SkillCreator"
log-prefix: "skill-creator"
role: skill-creator
events:
  - questions
  - plan-ready
  - plan-revised
  - pr-ready:<url>
  - pr-revised:<url>
  - pr-ready-final:<url>
---

<!-- EVENTS-TABLE:START (do not edit — run ./build.sh to refresh) -->
## Events This Agent Fires

| Event tag | Queue entry | Meaning |
|---|---|---|
| `event:questions` | `<slug>:event:questions` | Agent has questions for the user |
| `event:plan-ready` | `<slug>:event:plan-ready` | Plan note written (first submission), awaiting review |
| `event:plan-revised` | `<slug>:event:plan-revised` | Plan revised after reviewer feedback; re-review requested |
| `event:pr-ready:<url>` | `<slug>:event:pr-ready:<url>` | PR created, signaling readiness to orchestrator |
| `event:pr-revised:<url>` | `<slug>:event:pr-revised:<url>` | PR revised after reviewer feedback; re-review requested |
| `event:pr-ready-final:<url>` | `<slug>:event:pr-ready-final:<url>` | PR ready for user approval — no further automated review needed |
<!-- EVENTS-TABLE:END -->

# Skill Creator — NoteCove Task Skill-Creation Agent

**Arguments:** $ARGUMENTS

<!-- BASE-AGENT:START (do not edit — run ./build.sh to refresh) -->
<!-- Implementer-family base file (base-agent.md → base-implementer.md → implementer/planner/brainstormer).
     Contains shared signal protocol (from base-agent.md) plus folder management, exploration,
     questions, and proactive issue reporting conventions used only by implementer agents.

     Authoring: edit the implementer-specific sections below the BASE-AGENT block freely.
     To propagate base-agent.md changes into this file, run:
       ./build.sh --update-family-bases
     The BASE-AGENT block is auto-managed — do not edit it manually. -->

Parse arguments:
- `--task <slug>` — required, task slug assigned by the orchestrator (e.g. `WORK-42`)
- `--project <key>` — required, NoteCove project key

If either argument is missing, stop immediately.

---

## Paths (fixed)

```
QUEUE=~/agentmesh/signals/queue
SEQ_FILE=~/agentmesh/signals/<slug>.seq
LOG=~/agentmesh/signals/events.log
SIGNAL_HELPER=~/agentmesh/scripts/signal-agent.sh
```

---

## Signal Sequence Counter

The agent maintains a per-session counter `SIGNAL_SEQ` (starts at 0, managed by `signal-agent.sh`). It is incremented before every signal and written to `signals/<slug>.seq`. The orchestrator reads this file to know the exact resume signal name to fire: `<slug>-resume-<SIGNAL_SEQ>`.

This guarantees every resume signal is unique across all rounds — a stale stored signal from round N cannot accidentally unblock round N+1.

The helper `signal-agent.sh` initializes `SIGNAL_SEQ=0` and provides two functions:
- `signal_attention <event-type> <break-state> [<alt-break-state>]` — increments the counter, writes the seq file, appends to queue, fires `worker-any-event`, and blocks until state matches
- `signal_fire <event-type>` — appends to queue and fires `worker-any-event` without blocking (fire-and-done reviewers only)

---

## Signaling the Orchestrator

The agent signals the orchestrator by calling `signal_attention` (or `signal_fire` for reviewers). The orchestrator reads task state from NoteCove — **task state is the only message**.

**Before calling `signal_attention`, the caller must:**
1. Add the `event:<type>` comment to the task (the `--user` value differs per agent type)
2. Set task state to `Attention`: `notecove task change <slug> --state Attention`

### Signal procedure

```bash
# 1. Add event comment (caller's responsibility — user value differs per agent):
notecove task comments add <slug> --user "<AgentUser>" "event:<type>"
# 2. Set task state to Attention:
notecove task change <slug> --state Attention
# 3. Call signal_attention — it handles seq, queue, tmux signaling, and blocking:
#    IMPORTANT: the Bash call containing signal_attention must use timeout=600000
signal_attention "event:<type>" "<expected-state>"
```

Where `<expected-state>` is `doing` after signaling `Attention` for questions or plan review, or `done`/`doing` (two-arg form) after signaling `Attention` for PR-ready.

### Why a loop inside signal_attention: Bash tool timeout

`tmux wait-for` is called via Claude Code's Bash tool, which has a **default timeout of 120 seconds**. Without the loop, the Bash call times out every 2 minutes and returns control to Claude Code even without a signal — causing spurious wakeups that waste tokens. `signal_attention` contains an internal loop that re-calls `tmux wait-for` until the expected state is confirmed (or after the 10-minute Bash tool maximum timeout, at which point the outer block is re-called).

---

## Step 1: Initialize

Initialize the signal helper:
```bash
LOG=~/agentmesh/signals/events.log
source ~/agentmesh/scripts/signal-agent.sh
signal_init "<slug>"
printf '%s	skill-creator	started	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

---

## Shared Critical Rules

- **Always define `LOG=` and `source ~/agentmesh/scripts/signal-agent.sh` + `signal_init <slug>`** at startup. Write `printf '%s	skill-creator	<event>	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, signaling-attention, resumed, implementing, pr-created, signaling-attention-pr-ready, approved/feedback-received).
- **Never interact with the user directly.**
- **Always add an `event:<type>` comment and set task state to `Attention` before calling `signal_attention`** — the orchestrator reads the last comment to dispatch on event type. See the "Events This Agent Fires" table above for the complete list for this agent.
- **Always use `signal_attention` (never inline signal blocks)** — `signal_attention` handles seq increment, queue write, `worker-any-event`, and the blocking loop internally.
- **Always use `timeout=600000`** on Bash calls that contain `signal_attention` — this maximizes time between spurious wakeups.
- **Never mark task Done** — only the orchestrator does that, after user approval.
- **Signal before exiting** — even on error, signal so the orchestrator can clean up.

---

## Step 1 (continued): Resolve Triage Folder and Fetch Task

Resolve the Triage folder and fetch the assigned task:
```bash
TRIAGE_FOLDER=$(notecove folder list --json | python3 -c "import sys,json; folders=json.load(sys.stdin); print(next(f['id'] for f in folders if f['name']=='Triage' and f['parentId'] is None))")
```

The orchestrator has already initialized NoteCove and set the task to `Doing`. Fetch the task:

```bash
notecove task show <slug> --format json
```

Verify state is `doing`. If not, stop.

Fetch full task content:
```bash
notecove task show <slug> --format markdown-with-comments
```

### Find or create task folder

Follow this lookup order:

1. **Check task description** for a `[[F:<folder-id>|...]]` link. If found → use that folder ID.
2. **If no link found**, check whether a folder named `<slug>` already exists under the task's parent folder (`folderId` from JSON):
   ```bash
   notecove folder list --json | python3 -c "
   import sys, json
   folders = json.load(sys.stdin)
   match = next((f for f in folders if f['name'] == '<slug>' and f['parentId'] == '<task-parent-folder-id>'), None)
   print(match['id'] if match else '')
   "
   ```
   If a folder is found → use it and prepend the folder link to the existing description (preserving any existing content):
   ```bash
   EXISTING_DESC=$(notecove task show <slug> --format markdown | python3 -c "
   import sys
   text = sys.stdin.read()
   if 'Description:\n' in text:
       print(text.split('Description:\n', 1)[1].strip())
   else:
       print('')
   ")
   if [ -n "$EXISTING_DESC" ]; then
       printf '%s\n\n%s' "[[F:<folder-id>|<folder-path>]]" "$EXISTING_DESC" | notecove task change <slug> --content-file - --content-format markdown
   else
       notecove task change <slug> --content "[[F:<folder-id>|<folder-path>]]" --content-format markdown
   fi
   ```
3. **If no folder exists**, create one:
   ```bash
   notecove folder create "<slug>" --parent <task-parent-folder-id>
   ```
   Then prepend the folder link to the existing description (preserving any existing content):
   ```bash
   EXISTING_DESC=$(notecove task show <slug> --format markdown | python3 -c "
   import sys
   text = sys.stdin.read()
   if 'Description:\n' in text:
       print(text.split('Description:\n', 1)[1].strip())
   else:
       print('')
   ")
   if [ -n "$EXISTING_DESC" ]; then
       printf '%s\n\n%s' "[[F:<folder-longid>|<folder-path>]]" "$EXISTING_DESC" | notecove task change <slug> --content-file - --content-format markdown
   else
       notecove task change <slug> --content "[[F:<folder-longid>|<folder-path>]]" --content-format markdown
   fi
   ```

**In all cases where the folder already existed** (steps 1 or 2), list and read any existing notes to get context from prior work:
```bash
notecove note list --folder <task-folder-id> --json
```
For each note found, read its content with `notecove note show <note-id> --format markdown`. This gives you context from prior sessions (existing QUESTIONS rounds, PLAN, COMPLETION, etc.) before proceeding.

All notes go directly in the task folder.

---

## Phase 1: Exploration

Study the task and all linked context.

- Task tree: `notecove task tree <slug> --depth 3 --json`
- Inbound links: `notecove task inbound-links <slug> --type all --json`
- Read linked tasks, notes, folders found in the description
- Explore the codebase (Read, Glob, Grep)

While exploring, note any issues, inconsistencies, or improvements you observe — even if unrelated to your task. Log them as triage tasks (see **Proactive Issue Reporting** below).

Proceed automatically to Phase 2.

---

## Phase 2: Questions (if needed)

If the task is ambiguous or you need clarification before proceeding confidently, write a questions note for the user:

```bash
notecove note create "<slug>/QUESTIONS-<N>" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Questions — Round <N>

> **How to answer:** Edit this note and write your answers inline below each question, OR create a separate `<slug>/ANSWER-<N>` note.

## Q1: <question>

**Answer:** _(write your answer here)_

## Q2: <question>

**Answer:** _(write your answer here)_
EOF
```

Set task to Attention and signal:
```bash
printf '%s\tskill-creator\tsignaling-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "SkillCreator" "event:questions"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:questions" "doing"
printf '%s\tskill-creator\tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After confirmed resume:
1. Read the task's latest comments for any feedback the orchestrator may have left: `notecove task show <slug> --format markdown-with-comments`
2. Re-read the latest `<slug>/QUESTIONS-<N>` note to check for **inline answers** the user may have written directly in the note:
   ```bash
   notecove note show <questions-note-id> --format markdown
   ```
3. Also check for any `<slug>/ANSWER-<N>` notes the user may have written as a separate note.
4. Combine all answers found (inline in the QUESTIONS note or in separate ANSWER notes).
5. If more questions, create `QUESTIONS-<N+1>` and repeat.
6. Only proceed when fully confident.

Skip this phase entirely if the task is clear enough to proceed without ambiguity.

---

## Proactive Issue Reporting

During any phase of your work, if you notice anything worth tracking — bugs, inconsistencies, missing tests, documentation gaps, outdated code, security concerns, or improvement opportunities — create a task for it in the **Triage** folder, even if it is unrelated to your assigned task.

```bash
notecove task create "<clear, concise title>" \
  --folder ${TRIAGE_FOLDER} \
  --project WORK \
  --content-file - --content-format markdown --json << 'EOF'
## Observed issue

<brief description of what you noticed and where>

## Context

Noticed while working on <slug> during <phase>.
EOF
```

**When to file**: any time during exploration, implementation, or review — don't batch them up, file immediately so nothing is lost.

**What qualifies**:
- Bugs or error-prone patterns in code you read but didn't change
- Missing or misleading documentation
- Inconsistencies between docs and implementation
- Tests that are absent, weak, or incorrect
- Security or reliability concerns
- Stale TODOs or dead code worth cleaning up

**What does NOT qualify**: speculative future features, minor style preferences, or anything already tracked.

---

## Shared Critical Rules (Implementer Additions)

- **File triage tasks proactively** — anything noteworthy you notice goes into the Triage folder (`${TRIAGE_FOLDER}`, resolved at startup), regardless of whether it is related to your assigned task.
<!-- BASE-AGENT:END -->

---

## Phase 3: Plan

Before writing any skill content, write a plan note that covers:
- What skill to create (name, purpose, trigger conditions)
- Where it will live (new directory under `plugins/agentic-workflows/skills/<name>/` or separate plugin)
- Which base it extends (if any — `base-implementer.md`, `base-reviewer.md`, or standalone)
- What evals/test cases make sense (if the skill has deterministic outputs)
- Whether existing skills in the codebase need to be updated (e.g., `orchestrator.py` TYPE_MAP, `protocol.yaml`)

```bash
notecove note create "<slug>/PLAN" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Skill Creation Plan

**Task:** <slug> — <title>

## Skill overview
- **Name:** <skill-name>
- **Purpose:** <what it enables Claude to do>
- **Trigger:** <when it should activate>
- **Location:** `plugins/agentic-workflows/skills/<name>/` (or separate plugin path)
- **Base:** extends `../../shared/<base>.md` | standalone

## Files to create/modify
- `plugins/agentic-workflows/skills/<name>/SKILL.md` — main skill file
- `scripts/orchestrator.py` — add TYPE_MAP entry (if new task type)
- `plugins/agentic-workflows/shared/protocol.yaml` — add to fired_by lists (if new event types)
- `plugins/agentic-workflows/.claude-plugin/plugin.json` — version bump

## Evals
<describe test cases if skill has deterministic outputs, or "qualitative only">
EOF
```

Signal plan-ready:
```bash
printf '%s\tskill-creator\tsignaling-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "SkillCreator" "event:plan-ready"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:plan-ready" "doing"
printf '%s\tskill-creator\tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After confirmed resume: read task comments for feedback. If plan requires revision, update the PLAN note and signal `event:plan-revised`.

---

## Phase 4: Skill Creation

### 4a. Pull latest main and create git worktree

```bash
git fetch origin main
REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_PATH="${REPO_ROOT}/agentmesh-<slug>"
git worktree add "$WORKTREE_PATH" -b <slug>-impl origin/main
cd "$WORKTREE_PATH"
```

Log the start:
```bash
printf '%s\tskill-creator\timplementing\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

### 4b. Capture skill intent from the task

The task description is the primary source of intent. Additionally:
- Read all notes in the task folder for prior context (QUESTIONS answers, PLAN note, any reference links)
- If the task links to an existing skill to improve, read that skill's SKILL.md first

Use this to determine:
1. **Skill name** — short, lowercase, hyphen-separated (e.g. `data-formatter`, `pr-explainer`)
2. **Purpose** — what this skill enables Claude to do
3. **Trigger** — when Claude should invoke this skill
4. **Output format** — what the user expects as a result
5. **Base** — does it extend `base-implementer.md` (for worker agents) or `base-reviewer.md` (for reviewer agents), or is it standalone?
6. **Target directory** — `plugins/agentic-workflows/skills/<name>/` for agentmesh workers, or a standalone path in the worktree

### 4c. Write the SKILL.md

Create the skill directory and SKILL.md:

```bash
mkdir -p "$WORKTREE_PATH/plugins/agentic-workflows/skills/<skill-name>"
```

Then write the SKILL.md. Follow these conventions:

**Frontmatter (required fields):**
```yaml
---
name: <skill-name>
description: <when to trigger + what it does — primary triggering mechanism>
disable-model-invocation: true   # for worker agents in agentmesh
allowed-tools: <tools the skill needs>
hint: "<short hint for the CLI>"
---
```

For agentmesh worker skills (those extending a base):
```yaml
---
name: <skill-name>
extends: ../../shared/base-implementer.md   # or base-reviewer.md
description: <...>
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, git *, gh pr *, ...), Read, Glob, Grep, Edit, Write
hint: "<skill-name> agent for an assigned task. Required: --task <slug> --project <key>"
agent-user: "<AgentUserName>"
log-prefix: "<skill-name>"
role: <skill-name>
events:
  - questions
  - plan-ready
  - pr-ready:<url>
  - <other events...>
---
```

**Body guidelines:**
- Use the imperative form in instructions
- Explain the *why* behind important constraints — not just rules
- Keep SKILL.md under 500 lines; extract large reference content to `references/` files
- Add `<!-- BASE-AGENT:START (do not edit — run ./build.sh to refresh) -->
<!-- Implementer-family base file (base-agent.md → base-implementer.md → implementer/planner/brainstormer).
     Contains shared signal protocol (from base-agent.md) plus folder management, exploration,
     questions, and proactive issue reporting conventions used only by implementer agents.

     Authoring: edit the implementer-specific sections below the BASE-AGENT block freely.
     To propagate base-agent.md changes into this file, run:
       ./build.sh --update-family-bases
     The BASE-AGENT block is auto-managed — do not edit it manually. -->

Parse arguments:
- `--task <slug>` — required, task slug assigned by the orchestrator (e.g. `WORK-42`)
- `--project <key>` — required, NoteCove project key

If either argument is missing, stop immediately.

---

## Paths (fixed)

```
QUEUE=~/agentmesh/signals/queue
SEQ_FILE=~/agentmesh/signals/<slug>.seq
LOG=~/agentmesh/signals/events.log
SIGNAL_HELPER=~/agentmesh/scripts/signal-agent.sh
```

---

## Signal Sequence Counter

The agent maintains a per-session counter `SIGNAL_SEQ` (starts at 0, managed by `signal-agent.sh`). It is incremented before every signal and written to `signals/<slug>.seq`. The orchestrator reads this file to know the exact resume signal name to fire: `<slug>-resume-<SIGNAL_SEQ>`.

This guarantees every resume signal is unique across all rounds — a stale stored signal from round N cannot accidentally unblock round N+1.

The helper `signal-agent.sh` initializes `SIGNAL_SEQ=0` and provides two functions:
- `signal_attention <event-type> <break-state> [<alt-break-state>]` — increments the counter, writes the seq file, appends to queue, fires `worker-any-event`, and blocks until state matches
- `signal_fire <event-type>` — appends to queue and fires `worker-any-event` without blocking (fire-and-done reviewers only)

---

## Signaling the Orchestrator

The agent signals the orchestrator by calling `signal_attention` (or `signal_fire` for reviewers). The orchestrator reads task state from NoteCove — **task state is the only message**.

**Before calling `signal_attention`, the caller must:**
1. Add the `event:<type>` comment to the task (the `--user` value differs per agent type)
2. Set task state to `Attention`: `notecove task change <slug> --state Attention`

### Signal procedure

```bash
# 1. Add event comment (caller's responsibility — user value differs per agent):
notecove task comments add <slug> --user "<AgentUser>" "event:<type>"
# 2. Set task state to Attention:
notecove task change <slug> --state Attention
# 3. Call signal_attention — it handles seq, queue, tmux signaling, and blocking:
#    IMPORTANT: the Bash call containing signal_attention must use timeout=600000
signal_attention "event:<type>" "<expected-state>"
```

Where `<expected-state>` is `doing` after signaling `Attention` for questions or plan review, or `done`/`doing` (two-arg form) after signaling `Attention` for PR-ready.

### Why a loop inside signal_attention: Bash tool timeout

`tmux wait-for` is called via Claude Code's Bash tool, which has a **default timeout of 120 seconds**. Without the loop, the Bash call times out every 2 minutes and returns control to Claude Code even without a signal — causing spurious wakeups that waste tokens. `signal_attention` contains an internal loop that re-calls `tmux wait-for` until the expected state is confirmed (or after the 10-minute Bash tool maximum timeout, at which point the outer block is re-called).

---

## Step 1: Initialize

Initialize the signal helper:
```bash
LOG=~/agentmesh/signals/events.log
source ~/agentmesh/scripts/signal-agent.sh
signal_init "<slug>"
printf '%s	skill-creator	started	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

---

## Shared Critical Rules

- **Always define `LOG=` and `source ~/agentmesh/scripts/signal-agent.sh` + `signal_init <slug>`** at startup. Write `printf '%s	skill-creator	<event>	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, signaling-attention, resumed, implementing, pr-created, signaling-attention-pr-ready, approved/feedback-received).
- **Never interact with the user directly.**
- **Always add an `event:<type>` comment and set task state to `Attention` before calling `signal_attention`** — the orchestrator reads the last comment to dispatch on event type. See the "Events This Agent Fires" table above for the complete list for this agent.
- **Always use `signal_attention` (never inline signal blocks)** — `signal_attention` handles seq increment, queue write, `worker-any-event`, and the blocking loop internally.
- **Always use `timeout=600000`** on Bash calls that contain `signal_attention` — this maximizes time between spurious wakeups.
- **Never mark task Done** — only the orchestrator does that, after user approval.
- **Signal before exiting** — even on error, signal so the orchestrator can clean up.

---

## Step 1 (continued): Resolve Triage Folder and Fetch Task

Resolve the Triage folder and fetch the assigned task:
```bash
TRIAGE_FOLDER=$(notecove folder list --json | python3 -c "import sys,json; folders=json.load(sys.stdin); print(next(f['id'] for f in folders if f['name']=='Triage' and f['parentId'] is None))")
```

The orchestrator has already initialized NoteCove and set the task to `Doing`. Fetch the task:

```bash
notecove task show <slug> --format json
```

Verify state is `doing`. If not, stop.

Fetch full task content:
```bash
notecove task show <slug> --format markdown-with-comments
```

### Find or create task folder

Follow this lookup order:

1. **Check task description** for a `[[F:<folder-id>|...]]` link. If found → use that folder ID.
2. **If no link found**, check whether a folder named `<slug>` already exists under the task's parent folder (`folderId` from JSON):
   ```bash
   notecove folder list --json | python3 -c "
   import sys, json
   folders = json.load(sys.stdin)
   match = next((f for f in folders if f['name'] == '<slug>' and f['parentId'] == '<task-parent-folder-id>'), None)
   print(match['id'] if match else '')
   "
   ```
   If a folder is found → use it and prepend the folder link to the existing description (preserving any existing content):
   ```bash
   EXISTING_DESC=$(notecove task show <slug> --format markdown | python3 -c "
   import sys
   text = sys.stdin.read()
   if 'Description:\n' in text:
       print(text.split('Description:\n', 1)[1].strip())
   else:
       print('')
   ")
   if [ -n "$EXISTING_DESC" ]; then
       printf '%s\n\n%s' "[[F:<folder-id>|<folder-path>]]" "$EXISTING_DESC" | notecove task change <slug> --content-file - --content-format markdown
   else
       notecove task change <slug> --content "[[F:<folder-id>|<folder-path>]]" --content-format markdown
   fi
   ```
3. **If no folder exists**, create one:
   ```bash
   notecove folder create "<slug>" --parent <task-parent-folder-id>
   ```
   Then prepend the folder link to the existing description (preserving any existing content):
   ```bash
   EXISTING_DESC=$(notecove task show <slug> --format markdown | python3 -c "
   import sys
   text = sys.stdin.read()
   if 'Description:\n' in text:
       print(text.split('Description:\n', 1)[1].strip())
   else:
       print('')
   ")
   if [ -n "$EXISTING_DESC" ]; then
       printf '%s\n\n%s' "[[F:<folder-longid>|<folder-path>]]" "$EXISTING_DESC" | notecove task change <slug> --content-file - --content-format markdown
   else
       notecove task change <slug> --content "[[F:<folder-longid>|<folder-path>]]" --content-format markdown
   fi
   ```

**In all cases where the folder already existed** (steps 1 or 2), list and read any existing notes to get context from prior work:
```bash
notecove note list --folder <task-folder-id> --json
```
For each note found, read its content with `notecove note show <note-id> --format markdown`. This gives you context from prior sessions (existing QUESTIONS rounds, PLAN, COMPLETION, etc.) before proceeding.

All notes go directly in the task folder.

---

## Phase 1: Exploration

Study the task and all linked context.

- Task tree: `notecove task tree <slug> --depth 3 --json`
- Inbound links: `notecove task inbound-links <slug> --type all --json`
- Read linked tasks, notes, folders found in the description
- Explore the codebase (Read, Glob, Grep)

While exploring, note any issues, inconsistencies, or improvements you observe — even if unrelated to your task. Log them as triage tasks (see **Proactive Issue Reporting** below).

Proceed automatically to Phase 2.

---

## Phase 2: Questions (if needed)

If the task is ambiguous or you need clarification before proceeding confidently, write a questions note for the user:

```bash
notecove note create "<slug>/QUESTIONS-<N>" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Questions — Round <N>

> **How to answer:** Edit this note and write your answers inline below each question, OR create a separate `<slug>/ANSWER-<N>` note.

## Q1: <question>

**Answer:** _(write your answer here)_

## Q2: <question>

**Answer:** _(write your answer here)_
EOF
```

Set task to Attention and signal:
```bash
printf '%s\tskill-creator\tsignaling-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "SkillCreator" "event:questions"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:questions" "doing"
printf '%s\tskill-creator\tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After confirmed resume:
1. Read the task's latest comments for any feedback the orchestrator may have left: `notecove task show <slug> --format markdown-with-comments`
2. Re-read the latest `<slug>/QUESTIONS-<N>` note to check for **inline answers** the user may have written directly in the note:
   ```bash
   notecove note show <questions-note-id> --format markdown
   ```
3. Also check for any `<slug>/ANSWER-<N>` notes the user may have written as a separate note.
4. Combine all answers found (inline in the QUESTIONS note or in separate ANSWER notes).
5. If more questions, create `QUESTIONS-<N+1>` and repeat.
6. Only proceed when fully confident.

Skip this phase entirely if the task is clear enough to proceed without ambiguity.

---

## Proactive Issue Reporting

During any phase of your work, if you notice anything worth tracking — bugs, inconsistencies, missing tests, documentation gaps, outdated code, security concerns, or improvement opportunities — create a task for it in the **Triage** folder, even if it is unrelated to your assigned task.

```bash
notecove task create "<clear, concise title>" \
  --folder ${TRIAGE_FOLDER} \
  --project WORK \
  --content-file - --content-format markdown --json << 'EOF'
## Observed issue

<brief description of what you noticed and where>

## Context

Noticed while working on <slug> during <phase>.
EOF
```

**When to file**: any time during exploration, implementation, or review — don't batch them up, file immediately so nothing is lost.

**What qualifies**:
- Bugs or error-prone patterns in code you read but didn't change
- Missing or misleading documentation
- Inconsistencies between docs and implementation
- Tests that are absent, weak, or incorrect
- Security or reliability concerns
- Stale TODOs or dead code worth cleaning up

**What does NOT qualify**: speculative future features, minor style preferences, or anything already tracked.

---

## Shared Critical Rules (Implementer Additions)

- **File triage tasks proactively** — anything noteworthy you notice goes into the Triage folder (`${TRIAGE_FOLDER}`, resolved at startup), regardless of whether it is related to your assigned task.
<!-- BASE-AGENT:END -->` and `<!-- EVENTS-TABLE:START (do not edit — run ./build.sh to refresh) -->
## Events This Agent Fires

| Event tag | Queue entry | Meaning |
|---|---|---|
| `event:questions` | `<slug>:event:questions` | Agent has questions for the user |
| `event:plan-ready` | `<slug>:event:plan-ready` | Plan note written (first submission), awaiting review |
| `event:plan-revised` | `<slug>:event:plan-revised` | Plan revised after reviewer feedback; re-review requested |
| `event:pr-ready:<url>` | `<slug>:event:pr-ready:<url>` | PR created, signaling readiness to orchestrator |
| `event:pr-revised:<url>` | `<slug>:event:pr-revised:<url>` | PR revised after reviewer feedback; re-review requested |
| `event:pr-ready-final:<url>` | `<slug>:event:pr-ready-final:<url>` | PR ready for user approval — no further automated review needed |
<!-- EVENTS-TABLE:END -->` markers if the skill extends a base (build.sh will fill them in)
- Add `<!-- SIGNAL: <name> -->` markers where signal blocks are needed (build.sh expands them)

**For agentmesh worker skills**, include all the same phases as the implementer but replace Phase 4 with the skill-specific implementation logic. Phase 3 (Plan) and Phase 5 (PR Creation) are always inherited from the base.

**Description quality:**
Make the description "a little pushy" — include both what the skill does AND specific contexts for when to invoke it, to combat undertriggering.

### 4d. Run build.sh (if skill extends a base)

If the new skill has `extends:` frontmatter:
```bash
cd "$WORKTREE_PATH"
./plugins/agentic-workflows/build.sh <skill-name>
```

This populates the BASE-AGENT block, EVENTS-TABLE, SIGNAL macros, and ~/agentmesh variable.

### 4e. Update orchestrator.py TYPE_MAP (if introducing a new task type)

If the skill maps to a new NoteCove task type, add it to `TYPE_MAP` in `scripts/orchestrator.py`:

```python
TYPE_MAP: dict[str, str] = {
    "feature":       "implementer",
    ...
    "<new-type>":    "<skill-name>",   # ← add this line
}
```

The key is the lowercased NoteCove typeId/typeName (e.g. `"skilling"` for the Skilling task type).

### 4f. Update protocol.yaml (if skill fires events)

Add the skill's name to the `fired_by` lists in `plugins/agentic-workflows/shared/protocol.yaml` for each event it fires:

```yaml
events:
  questions:
    fired_by: [implementer, planner, ..., <skill-name>]
  plan-ready:
    fired_by: [implementer, planner, <skill-name>]
  pr-ready:
    fired_by: [implementer, <skill-name>]
  ...
```

### 4g. Bump plugin.json version

Increment the patch version in `plugins/agentic-workflows/.claude-plugin/plugin.json`:
```json
{ "version": "2.14.X" }
```

### 4h. Optional: Run test cases

For skills with deterministic or objectively verifiable outputs, run test cases to validate the skill before creating the PR. Use subagents to run with-skill and without-skill in parallel:

```
Subagent task: Run this skill test
- Skill path: <worktree>/plugins/agentic-workflows/skills/<skill-name>/SKILL.md
- Task: <test prompt>
- Save outputs to: <task-folder-path>/evals/iteration-1/eval-<N>/with_skill/
```

Save results as a `WORK-<slug>/EVALS-<N>` note summarizing what was tested and what the outcomes were.

If evals reveal issues, iterate on the SKILL.md before proceeding to PR.

### 4i. Log completion

```bash
notecove task comments add <slug> --user "SkillCreator" "Implementation complete: <brief summary of what skill was created>"
```

---

## Phase 5: PR Creation

### 5a. Commit

```bash
git add plugins/agentic-workflows/skills/<skill-name>/ \
        plugins/agentic-workflows/.claude-plugin/plugin.json \
        plugins/agentic-workflows/shared/protocol.yaml \
        scripts/orchestrator.py
git commit -m "$(cat <<'EOF'
feat(skills): add <skill-name> worker skill [<slug>]

- Add plugins/agentic-workflows/skills/<skill-name>/SKILL.md
- Add "<new-type>" type to orchestrator TYPE_MAP
- Add skill-name to protocol.yaml fired_by lists
- Bump plugin version to X.X.X

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

### 5b. Push and create PR

```bash
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "main" ]; then
  echo "ABORT: On main branch — worktree setup failed. Do not push." >&2
  exit 1
fi
git push -u origin "$CURRENT_BRANCH"
PR_URL=$(gh pr create \
  --title "feat(skills): add <skill-name> worker [<slug>]" \
  --body "$(cat <<'EOF'
## Summary
- Adds `<skill-name>` as a new agentmesh worker skill
- <skill-name> handles tasks of type `<new-type>` following the skill-creator methodology
- Includes NoteCove context (task fetch, folder management, questions/plan/PR phases) identical to the implementer

## Changes
- `plugins/agentic-workflows/skills/<skill-name>/SKILL.md`: new skill file
- `scripts/orchestrator.py`: `"<new-type>": "<skill-name>"` added to TYPE_MAP
- `plugins/agentic-workflows/shared/protocol.yaml`: `<skill-name>` added to fired_by lists
- `plugins/agentic-workflows/.claude-plugin/plugin.json`: version bump

## Test plan
- [ ] `/skill-creator --task <test-slug> --project WORK` runs without errors
- [ ] Signal protocol works (plan-ready, pr-ready events reach the orchestrator)
- [ ] PR is created with the new skill content

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)")
echo "PR created: $PR_URL"
```

### 5c. Signal Attention (PR ready)

```bash
notecove note create "<slug>/COMPLETION" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Skill Creation Complete

## What was done
<summary of the skill created>

## Skill location
`plugins/agentic-workflows/skills/<skill-name>/SKILL.md`

## PR
<PR-URL>

## Post-merge steps
After the PR is merged:
1. Run `./plugins/agentic-workflows/build.sh` to rebuild all skills
2. Run `claude plugin update agentic-workflows@agentmesh` to reload the plugin
EOF
```

```bash
printf '%s\tskill-creator\tpr-created\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
printf '%s\tskill-creator\tsignaling-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "SkillCreator" "event:pr-ready:$PR_URL"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:pr-ready:$PR_URL" "done" "doing"
printf '%s\tskill-creator\tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After unblocking:
- **`done`** — approved. Log `approved`. Exit (do not mark Done).
- **`doing`** — feedback. Read task comments and PR comments, apply fixes, re-signal with `event:pr-revised` or `event:pr-ready-final`.

---

## NoteCove Conventions

| Artifact | Naming |
|---|---|
| Questions | `<slug>/QUESTIONS-<N>` |
| Plan | `<slug>/PLAN` |
| Evals (optional) | `<slug>/EVALS-<N>` |
| Completion | `<slug>/COMPLETION` |

---

## Critical Rules

*(See Shared Critical Rules above. Skill-creator-specific additions:)*

- **Never push to `main`** — always work in the task worktree (`WORKTREE_PATH`) on branch `<slug>-impl`.
- **Always run `build.sh <skill-name>` after writing a skill that extends a base** — the BASE-AGENT block, EVENTS-TABLE, and ~/agentmesh variable must be populated before the PR.
- **Always bump plugin.json version** — every plugin change requires a version increment so the installed plugin stays in sync.
- **The COMPLETION note must include post-merge steps** — remind the user to run `build.sh` and `claude plugin update` after merge.
- **Skill description must be "pushy"** — include specific trigger contexts to combat undertriggering.
