---
name: planner
extends: ../../shared/base-implementer.md
description: Planner agent that receives a task the orchestrator has marked for decomposition, proposes subtasks for user review, and creates them as NoteCove children of the parent task upon approval
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, git *, echo *, cat *, mkdir *, python3 *), Read, Glob, Grep
hint: "Planner agent for task decomposition. Required: --task <slug> --project <key>"
agent-user: "Planner"
log-prefix: "planner      "
role: planner
events:
  - questions
  - plan-ready
  - completion
---

<!-- EVENTS-TABLE:START (do not edit — run ./build.sh to refresh) -->
## Events This Agent Fires

| Event tag | Queue entry | Meaning |
|---|---|---|
| `event:questions` | `<slug>:event:questions` | Agent has questions for the user |
| `event:plan-ready` | `<slug>:event:plan-ready` | Plan note written (first submission), awaiting review |
| `event:completion` | `<slug>:event:completion` | Subtasks created (or skipped), parent marked Done |
<!-- EVENTS-TABLE:END -->

# Planner — NoteCove Task Decomposition Agent

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
printf '%s	planner      	started	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

---

## Shared Critical Rules

- **Always define `LOG=` and `source ~/agentmesh/scripts/signal-agent.sh` + `signal_init <slug>`** at startup. Write `printf '%s	planner      	<event>	<slug>
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
   if 'Description:
' in text:
       print(text.split('Description:
', 1)[1].strip())
   else:
       print('')
   ")
   if [ -n "$EXISTING_DESC" ]; then
       printf '%s

%s' "[[F:<folder-id>|<folder-path>]]" "$EXISTING_DESC" | notecove task change <slug> --content-file - --content-format markdown
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
   if 'Description:
' in text:
       print(text.split('Description:
', 1)[1].strip())
   else:
       print('')
   ")
   if [ -n "$EXISTING_DESC" ]; then
       printf '%s

%s' "[[F:<folder-longid>|<folder-path>]]" "$EXISTING_DESC" | notecove task change <slug> --content-file - --content-format markdown
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
printf '%s\tplanner      \tsignaling-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Planner" "event:questions"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:questions" "doing"
printf '%s\tplanner      \tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
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

## Phase 3: Decomposition Plan

Analyze the task and design the subtask breakdown. Consider:
- **Cohesion**: group related changes that must land together
- **Independence**: each subtask should be implementable after its dependencies, without implicit coupling
- **Size balance**: subtasks should be roughly PR-sized — not trivially small, not sprawling
- **Merge conflict risk**: two subtasks that modify any of the same files must NOT run in parallel — add a sequential dependency between them (one blocks the other) even if there is no logical implementation dependency

For each proposed subtask, identify the specific files it will likely modify (use Glob/Grep on the codebase if needed). Then cross-check all pairs: any pair that shares at least one file gets a `Blocks` relationship. When ordering a merge-conflict pair that has no logical dependency, prefer putting the simpler or more self-contained subtask first.

Create a DECOMPOSITION note proposing the subtasks:

```bash
notecove note create "<slug>/DECOMPOSITION" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Decomposition Plan

**Parent task:** <slug> — <title>

## Proposed Subtasks

### Subtask 1: <name>
- **Description:** <what this subtask accomplishes>
- **Type:** <type — one of: feature, bug, plan, brainstorming, documentation, design, investigation; default: feature>
- **Depends on:** None (or list subtask numbers)
- **Key files:** <specific files this subtask modifies, e.g. `scripts/orchestrator.py`, `plugins/.../SKILL.md`>
- **Acceptance criteria:**
  - <criterion 1>
  - <criterion 2>

### Subtask 2: <name>
- **Description:** <what this subtask accomplishes>
- **Type:** <type — one of: feature, bug, plan, brainstorming, documentation, design, investigation; default: feature>
- **Depends on:** Subtask 1 (logical dependency)
- **Key files:** <specific files this subtask modifies>
- **Acceptance criteria:**
  - <criterion 1>
  - <criterion 2>

## Merge Conflict Analysis

For each pair of subtasks that share at least one file, list the shared file(s) and which task must go first.
Subtasks with no shared files can be omitted from this section to keep it concise.

- Subtask 1 and Subtask 2 both modify `<file>` → Subtask 2 blocked by Subtask 1 (already covered by logical dependency)
- Subtask 3 and Subtask 4 both modify `<file>` → Subtask 4 blocked by Subtask 3 (merge conflict risk — no logical dependency, but must be serialized)

## Execution Order

<Text representation of all dependencies (logical + merge-conflict), e.g.:>
Subtask 1 → Subtask 2 → Subtask 4
Subtask 1 → Subtask 3 → Subtask 4
(Subtasks 2 and 3 can run in parallel after Subtask 1 only if they share no files)
EOF
```

Set task to Attention and signal for decomposition review:
```bash
printf '%s\tplanner      \tsignaling-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Planner" "event:plan-ready"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:plan-ready" "doing"
printf '%s\tplanner      \tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After confirmed resume:
1. Read task comments for feedback: `notecove task show <slug> --format markdown-with-comments`
2. If feedback requests changes → update the DECOMPOSITION note, re-signal Attention.
3. Repeat until no feedback on the decomposition.

---

## Phase 4: Create Child Tasks

Once the decomposition is approved (orchestrator resumes with no objection), create child tasks in NoteCove under the parent task.

Before starting, extract the dependency graph from the DECOMPOSITION note: for each subtask, note which other subtasks it blocks (or is blocked by). Create independent subtasks first so their slugs are available when blocked tasks need to reference them.

Also capture the parent task's folder ID — this is the folder where child tasks must be placed:
```bash
PARENT_TASK_FOLDER_ID=<folderId from the parent task JSON fetched in Step 1>
```

For each proposed subtask (independent ones first, then those with blockers):

**Step A — Create the child task with no content:**

Read the `**Type:**` field for this subtask from the approved DECOMPOSITION note (the user may have changed it during review — use the current value). Default to `feature` if the field is absent.

```bash
# Set state: 'Ready' if this subtask has no blockers; 'Blocked' if blocked by another subtask
CHILD_STATE="Ready"   # or "Blocked" for tasks that depend on others
CHILD_TYPE="feature"  # read from **Type:** field in DECOMPOSITION note for this subtask

CHILD_JSON=$(notecove task create "<title>" \
  --parent <slug> \
  --folder ${PARENT_TASK_FOLDER_ID} \
  --project <PROJECT> \
  --type ${CHILD_TYPE} \
  --state ${CHILD_STATE} \
  --json)
CHILD_SLUG=$(echo "$CHILD_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['slug']['short'])")
CHILD_ID=$(echo "$CHILD_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'])")
```

`--folder ${PARENT_TASK_FOLDER_ID}` places the child task in the same folder as the parent task (the folder that *contains* the parent task, not the planner's own note folder). This is required — omitting it causes tasks to land in the wrong location.

**Step B — Create a folder for the child task (under the task parent folder):**
```bash
CHILD_FOLDER_JSON=$(notecove folder create "${CHILD_SLUG}" --parent ${PARENT_TASK_FOLDER_ID} --json)
CHILD_FOLDER_ID=$(echo "$CHILD_FOLDER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
CHILD_FOLDER_PATH=$(echo "$CHILD_FOLDER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['path'])")
```

**Step C — Create a DESCRIPTION note in the child's folder:**

Because independent subtasks are created first (Step A), their slugs are already known when you write DESCRIPTION notes for blocked subtasks. Fill in the `## Blocked by` section with actual blocker slugs at this point — do not leave it as a placeholder.

```bash
notecove note create "${CHILD_SLUG}/DESCRIPTION" --folder ${CHILD_FOLDER_ID} --content-file - --format markdown --json << 'EOF'
## Context

Part of parent task [[T:<parent-task-id>|<parent-slug>]].

## Description

<Expand on the subtask description from the DECOMPOSITION note. Include what the subtask does, the approach to be taken, and any non-obvious constraints. 2–4 sentences minimum.>

## Key Files

<Files this subtask will modify, copied from the DECOMPOSITION note and annotated with why each file is relevant.>

## Blocked by

<Blocker slug(s) that must complete before this subtask starts, e.g. "WORK-xyz". "None" if this is an independent subtask. Blocker slugs are known at this point — fill them in now.>

## Acceptance Criteria

- <criterion 1>
- <criterion 2>
EOF
```

**Step D — Link the folder in the child task description:**
```bash
notecove task change ${CHILD_SLUG} \
  --content "[[F:${CHILD_FOLDER_ID}|${CHILD_FOLDER_PATH}]]" \
  --content-format markdown \
  --json
```

**Step E — After all child tasks are created, establish blocking links:**

For each dependency identified in the DECOMPOSITION — both **logical dependencies** and **merge conflict pairs** from the "Merge Conflict Analysis" section — create a `--block` link:
```bash
notecove task change <blocked-slug> --block <blocker-slug>
```

This creates the actual "Blocks / Blocked by" relationship in NoteCove. It must be done after all tasks exist so both slugs are known. The `--block <slug>` flag means "add a blocking task" (i.e., `<slug>` blocks the subject), so it must be called on the *blocked* task with the *blocker* as the argument — combined with the `Blocked` state set in Step A, this ensures the orchestrator will not dispatch blocked tasks.

Apply this for **every** pair in the Merge Conflict Analysis, not just logical dependencies. A shared file is sufficient reason to serialize two tasks.

After creating all child tasks and establishing all links, add a comment listing them:
```bash
notecove task comments add <slug> --user "Planner" "Decomposition complete. Created <N> child tasks: <slug-1>, <slug-2>, ..."
```

Then mark the parent task Done (planning complete — children carry the actual work):
```bash
notecove task change <slug> --state Done
```

> **Note:** The orchestrator will still receive the `In Review` signal below and will mark the task Done from its side too — that is fine. `Done` is idempotent.

---

## Phase 5: Signal Completion

```bash
printf '%s\tplanner      \tsignaling-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Planner" "event:completion"
notecove task change <slug> --state Attention
# IMPORTANT: call this Bash block with timeout=600000
signal_attention "event:completion" "done"
printf '%s\tplanner      \tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

Planner exits after confirmed `done` state (orchestrator auto-acks planner completion).

---

## NoteCove Conventions

| Artifact | Naming |
|---|---|
| Questions | `<slug>/QUESTIONS-<N>` |
| Decomposition plan | `<slug>/DECOMPOSITION` |

**Task states used by planner**: `Doing` (working), `Attention` (needs user review or signaling completion)
**Task states set by orchestrator**: `Done` (acknowledged), `Doing` (resumed after review), `In Review` (reviewer agent dispatched)

---

## Critical Rules

*(See Shared Critical Rules above. Planner-specific additions:)*

- **Never create child tasks before the decomposition is approved** — the Attention signal in Phase 3 is the approval gate.
- **Mark parent Done before signaling In Review** — children carry the work; the parent task is complete from a planning perspective.
