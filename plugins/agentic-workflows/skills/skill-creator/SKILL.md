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
---

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
- `--task <slug>` — required, task slug assigned by the launcher (e.g. `WORK-42`)
- `--project <key>` — required, NoteCove project key

If either argument is missing, stop immediately.

---

## Paths (fixed)

```
INBOX=~/agentmesh/signals/<slug>.inbox
SEQ_FILE=~/agentmesh/signals/<slug>.seq
LOG=~/agentmesh/signals/events.log
HELPER=~/agentmesh/scripts/agent-notecove.sh
```

---

## How You Talk To The User

**NoteCove is the only interaction surface.** There is no orchestrator relaying messages and no chat interface — you and the user communicate directly through the task itself:

- **Comments** carry the conversation, in both directions. You post; the user replies; you read the reply.
- **Notes** carry artifacts. Plans, findings, question sets, designs — anything longer than a short paragraph.
- **Task state** carries intent. Only you and the user change it.

Each agent runs with a **sidecar** — a generic watcher process (`scripts/sidecar.sh`) that monitors your task and wakes you when the user comments or changes the state. You block for free while waiting; the sidecar does not consume tokens either.

### The interaction cycle

```bash
post_summary "<brief summary of what you just did>"
await_user "Attention"     # blocks — call with timeout=600000
read_inbox                 # what woke you
```

`await_user` sets the task state, publishes the sequence number the sidecar fires, and blocks until something arrives. `read_inbox` prints line-delimited JSON and clears the inbox:

```
{"kind":"comment","id":"...","author":"gara","content":"looks good, ship it","created":...}
{"kind":"state-change","from":"doing","to":"...","to_name":"Won't Do"}
```

### Comments are summaries, not documents

Keep every comment to **a few sentences at most**. A comment is a notification: it tells the user what happened and where to look. Anything longer — reasoning, findings, option analysis, code, tables — goes in a NoteCove note, and the comment names that note.

Write "Wrote PLAN: 8 phases, one PR. Two open risks noted in the Delivery section." — not three paragraphs restating the plan.

### Reading the user's reply

Interpret free text with judgement; the user writes naturally ("the linter is failing", "there are conflicts, resolve them").

Two words are **reserved commands** and must be honoured literally rather than read as feedback:

- `approve` — the work is accepted. Move the task to its terminal state (`Done`) yourself.
- `abort` — stop. Set the task to `Won't Do` and exit.

Echo your reading back in your next comment ("Read as: approve → marking Done") so a misinterpretation is visible to the user instead of silent.

### You own your task's state

You and the user are the only ones who change task state. Nothing else will do it for you:

- Set `Doing` as your first action when you start work.
- Set `Attention` when you need the user (via `await_user`).
- **Finish with `finish_task`**, never a bare state change:

```bash
finish_task "Done" "<project>"        # the user approved
finish_task "Won't Do" "<project>"    # the user aborted
```

`finish_task` sets the state *and* runs the cleanup that has to happen with it: releasing tasks blocked on this one, and stopping this task's sidecar and pr-monitor. Nothing else does either — a bare `notecove task change --state Done` leaves dependent tasks blocked forever and leaks two processes.

If `read_inbox` reports a `state-change` you did not make — the user moved the task to `Won't Do`, `Blocked`, or anything terminal — stop work and exit cleanly rather than continuing. Do not call `finish_task`: the user has already set the state.

### If you were restarted mid-task

You may be a replacement for a worker that died. The launcher spawns a fresh worker for any task left in `Doing` or `Attention` with no live worker window, so finding existing notes in your task folder is normal, not an error.

Read them before doing anything: a `PLAN`, `QUESTIONS-<N>`, or `COMPLETION` note means that work is already done. Pick up from where it left off rather than repeating it, and check the task's comments for the conversation so far.

---

## Step 1: Initialize

```bash
LOG=~/agentmesh/signals/events.log
source ~/agentmesh/scripts/agent-notecove.sh
agent_init "<slug>" "SkillCreator"
notecove task change <slug> --state Doing
printf '%s\tskill-creator\tstarted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

`agent_init` also clears `signals/<slug>.launching`, the flag the launcher uses to keep its next scan from spawning a second worker for this task while you were booting. Claiming the task by setting `Doing` is what releases it.

The handle passed to `agent_init` **must** match the `--user` value your comments carry (`SkillCreator`) — the sidecar filters your own comments by author name, so a mismatch makes you wake yourself on every comment you write.

---

## Shared Critical Rules

- **Always `source ~/agentmesh/scripts/agent-notecove.sh` + `agent_init <slug> "SkillCreator"`** at startup, and define `LOG=`. Write `printf '%s\tskill-creator\t<event>\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, awaiting-user, resumed, implementing, pr-created, approved/feedback-received).
- **Never interact with the user outside NoteCove.** No terminal output intended for them, no other channel.
- **Always post a summary comment before `await_user`** — otherwise the user is woken by a state change with no explanation of what you want.
- **Keep comments brief.** A few sentences. Artifacts belong in notes.
- **Always use `timeout=600000`** on Bash calls containing `await_user`. The Bash tool caps at 10 minutes, so long waits get interrupted; re-calling `await_user` is safe (the announce and the wait are separate, and the wait writes nothing).
- **Always finish with `finish_task "<state>" "<project>"`** — never a bare `notecove task change --state Done`. It is what releases blocked dependents and stops your sidecar; nothing else does.
- **Exit cleanly on a state change you did not make** — the user has taken the task elsewhere. Do not call `finish_task`.
- **Check your task folder for existing notes at startup** — you may be a restarted worker, and repeating finished work wastes the user's time.

---

## Step 1 (continued): Resolve Triage Folder and Fetch Task

Resolve the Triage folder and fetch the assigned task:
```bash
TRIAGE_FOLDER=$(notecove folder list --json | python3 -c "import sys,json; folders=json.load(sys.stdin); print(next(f['id'] for f in folders if f['name']=='Triage' and f['parentId'] is None))")
```

The launcher spawned you but left the task in `Ready` — you claimed it by setting `Doing` in Step 1. Fetch the task:

```bash
notecove task show <slug> --format json
```

Verify the state is `doing` (your own write from Step 1). If it is anything else, the user has moved the task — stop.

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

Comment that the questions are waiting, then block:
```bash
printf '%s\tskill-creator\tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
post_summary "<brief summary — a few sentences; link any note you wrote>"
# IMPORTANT: call this Bash block with timeout=600000
await_user "Attention"
read_inbox
printf '%s\tskill-creator\tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After waking:
1. Read what `read_inbox` returned — the user may have answered directly in a comment.
2. Re-read the latest `<slug>/QUESTIONS-<N>` note to check for **inline answers** written into the note itself:
   ```bash
   notecove note show <questions-note-id> --format markdown
   ```
3. Also check for any `<slug>/ANSWER-<N>` notes the user may have written separately.
4. Combine every answer found — inbox comments, inline note answers, and ANSWER notes.
5. If questions remain, create `QUESTIONS-<N+1>` and repeat.
6. Only proceed when fully confident.

> Users often answer inline in the note rather than in a comment. The note edit may not wake you on its own, so **always re-read the QUESTIONS note after waking**, whatever the inbox says.

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
- **Re-read your QUESTIONS note after every wake** — inline answers written into the note are the most common way users reply, and a note edit does not reliably wake you.
<!-- BASE-AGENT:END -->

---

## Phase 3: Plan

Before writing any skill content, write a plan note that covers:
- What skill to create (name, purpose, trigger conditions)
- Where it will live (new directory under `plugins/agentic-workflows/skills/<name>/` or separate plugin)
- Which base it extends (if any — `base-implementer.md`, `base-reviewer.md`, or standalone)
- What evals/test cases make sense (if the skill has deterministic outputs)
- Whether existing skills in the codebase need to be updated (e.g., `launcher.py` TYPE_MAP and AGENT_AUTHOR)

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
- `scripts/launcher.py` — add TYPE_MAP entry (if new task type)
- `scripts/launcher.py` — add AGENT_AUTHOR entry (comment author name)
- `plugins/agentic-workflows/.claude-plugin/plugin.json` — version bump

## Evals
<describe test cases if skill has deterministic outputs, or "qualitative only">
EOF
```

Signal plan-ready:
```bash
printf '%s\tskill-creator\tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
post_summary "Wrote <slug>/PLAN — <one line on the approach>"
# IMPORTANT: call this Bash block with timeout=600000
await_user "Attention"
read_inbox
printf '%s\tskill-creator\tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After waking: read the inbox for feedback. If the plan needs revision, update the PLAN note, post a summary of what changed, and `await_user` again.

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
- `--task <slug>` — required, task slug assigned by the launcher (e.g. `WORK-42`)
- `--project <key>` — required, NoteCove project key

If either argument is missing, stop immediately.

---

## Paths (fixed)

```
INBOX=~/agentmesh/signals/<slug>.inbox
SEQ_FILE=~/agentmesh/signals/<slug>.seq
LOG=~/agentmesh/signals/events.log
HELPER=~/agentmesh/scripts/agent-notecove.sh
```

---

## How You Talk To The User

**NoteCove is the only interaction surface.** There is no orchestrator relaying messages and no chat interface — you and the user communicate directly through the task itself:

- **Comments** carry the conversation, in both directions. You post; the user replies; you read the reply.
- **Notes** carry artifacts. Plans, findings, question sets, designs — anything longer than a short paragraph.
- **Task state** carries intent. Only you and the user change it.

Each agent runs with a **sidecar** — a generic watcher process (`scripts/sidecar.sh`) that monitors your task and wakes you when the user comments or changes the state. You block for free while waiting; the sidecar does not consume tokens either.

### The interaction cycle

```bash
post_summary "<brief summary of what you just did>"
await_user "Attention"     # blocks — call with timeout=600000
read_inbox                 # what woke you
```

`await_user` sets the task state, publishes the sequence number the sidecar fires, and blocks until something arrives. `read_inbox` prints line-delimited JSON and clears the inbox:

```
{"kind":"comment","id":"...","author":"gara","content":"looks good, ship it","created":...}
{"kind":"state-change","from":"doing","to":"...","to_name":"Won't Do"}
```

### Comments are summaries, not documents

Keep every comment to **a few sentences at most**. A comment is a notification: it tells the user what happened and where to look. Anything longer — reasoning, findings, option analysis, code, tables — goes in a NoteCove note, and the comment names that note.

Write "Wrote PLAN: 8 phases, one PR. Two open risks noted in the Delivery section." — not three paragraphs restating the plan.

### Reading the user's reply

Interpret free text with judgement; the user writes naturally ("the linter is failing", "there are conflicts, resolve them").

Two words are **reserved commands** and must be honoured literally rather than read as feedback:

- `approve` — the work is accepted. Move the task to its terminal state (`Done`) yourself.
- `abort` — stop. Set the task to `Won't Do` and exit.

Echo your reading back in your next comment ("Read as: approve → marking Done") so a misinterpretation is visible to the user instead of silent.

### You own your task's state

You and the user are the only ones who change task state. Nothing else will do it for you:

- Set `Doing` as your first action when you start work.
- Set `Attention` when you need the user (via `await_user`).
- **Finish with `finish_task`**, never a bare state change:

```bash
finish_task "Done" "<project>"        # the user approved
finish_task "Won't Do" "<project>"    # the user aborted
```

`finish_task` sets the state *and* runs the cleanup that has to happen with it: releasing tasks blocked on this one, and stopping this task's sidecar and pr-monitor. Nothing else does either — a bare `notecove task change --state Done` leaves dependent tasks blocked forever and leaks two processes.

If `read_inbox` reports a `state-change` you did not make — the user moved the task to `Won't Do`, `Blocked`, or anything terminal — stop work and exit cleanly rather than continuing. Do not call `finish_task`: the user has already set the state.

### If you were restarted mid-task

You may be a replacement for a worker that died. The launcher spawns a fresh worker for any task left in `Doing` or `Attention` with no live worker window, so finding existing notes in your task folder is normal, not an error.

Read them before doing anything: a `PLAN`, `QUESTIONS-<N>`, or `COMPLETION` note means that work is already done. Pick up from where it left off rather than repeating it, and check the task's comments for the conversation so far.

---

## Step 1: Initialize

```bash
LOG=~/agentmesh/signals/events.log
source ~/agentmesh/scripts/agent-notecove.sh
agent_init "<slug>" "SkillCreator"
notecove task change <slug> --state Doing
printf '%s\tskill-creator\tstarted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

`agent_init` also clears `signals/<slug>.launching`, the flag the launcher uses to keep its next scan from spawning a second worker for this task while you were booting. Claiming the task by setting `Doing` is what releases it.

The handle passed to `agent_init` **must** match the `--user` value your comments carry (`SkillCreator`) — the sidecar filters your own comments by author name, so a mismatch makes you wake yourself on every comment you write.

---

## Shared Critical Rules

- **Always `source ~/agentmesh/scripts/agent-notecove.sh` + `agent_init <slug> "SkillCreator"`** at startup, and define `LOG=`. Write `printf '%s\tskill-creator\t<event>\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, awaiting-user, resumed, implementing, pr-created, approved/feedback-received).
- **Never interact with the user outside NoteCove.** No terminal output intended for them, no other channel.
- **Always post a summary comment before `await_user`** — otherwise the user is woken by a state change with no explanation of what you want.
- **Keep comments brief.** A few sentences. Artifacts belong in notes.
- **Always use `timeout=600000`** on Bash calls containing `await_user`. The Bash tool caps at 10 minutes, so long waits get interrupted; re-calling `await_user` is safe (the announce and the wait are separate, and the wait writes nothing).
- **Always finish with `finish_task "<state>" "<project>"`** — never a bare `notecove task change --state Done`. It is what releases blocked dependents and stops your sidecar; nothing else does.
- **Exit cleanly on a state change you did not make** — the user has taken the task elsewhere. Do not call `finish_task`.
- **Check your task folder for existing notes at startup** — you may be a restarted worker, and repeating finished work wastes the user's time.

---

## Step 1 (continued): Resolve Triage Folder and Fetch Task

Resolve the Triage folder and fetch the assigned task:
```bash
TRIAGE_FOLDER=$(notecove folder list --json | python3 -c "import sys,json; folders=json.load(sys.stdin); print(next(f['id'] for f in folders if f['name']=='Triage' and f['parentId'] is None))")
```

The launcher spawned you but left the task in `Ready` — you claimed it by setting `Doing` in Step 1. Fetch the task:

```bash
notecove task show <slug> --format json
```

Verify the state is `doing` (your own write from Step 1). If it is anything else, the user has moved the task — stop.

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

Comment that the questions are waiting, then block:
```bash
printf '%s\tskill-creator\tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
post_summary "<brief summary — a few sentences; link any note you wrote>"
# IMPORTANT: call this Bash block with timeout=600000
await_user "Attention"
read_inbox
printf '%s\tskill-creator\tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After waking:
1. Read what `read_inbox` returned — the user may have answered directly in a comment.
2. Re-read the latest `<slug>/QUESTIONS-<N>` note to check for **inline answers** written into the note itself:
   ```bash
   notecove note show <questions-note-id> --format markdown
   ```
3. Also check for any `<slug>/ANSWER-<N>` notes the user may have written separately.
4. Combine every answer found — inbox comments, inline note answers, and ANSWER notes.
5. If questions remain, create `QUESTIONS-<N+1>` and repeat.
6. Only proceed when fully confident.

> Users often answer inline in the note rather than in a comment. The note edit may not wake you on its own, so **always re-read the QUESTIONS note after waking**, whatever the inbox says.

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
- **Re-read your QUESTIONS note after every wake** — inline answers written into the note are the most common way users reply, and a note edit does not reliably wake you.
<!-- BASE-AGENT:END -->` and `` markers if the skill extends a base (build.sh will fill them in)
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

### 4e. Update launcher.py TYPE_MAP (if introducing a new task type)

If the skill maps to a new NoteCove task type, add it to `TYPE_MAP` in `scripts/launcher.py`:

```python
TYPE_MAP: dict[str, str] = {
    "feature":       "implementer",
    ...
    "<new-type>":    "<skill-name>",   # ← add this line
}
```

The key is the lowercased NoteCove typeId/typeName (e.g. `"skilling"` for the Skilling task type).

### 4f. Register the comment author in launcher.py

The sidecar filters an agent's own comments by author name, so every new skill
must appear in the `AGENT_AUTHOR` map in `scripts/launcher.py`, mapping its
agent handle to the exact `--user` value its comments carry:

```python
AGENT_AUTHOR: dict[str, str] = {
    ...
    "<skill-name>": "<AgentUser>",
}
```

A missing or mismatched entry makes the agent wake itself on every comment it
writes, which looks like a wakeup loop.

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
        scripts/launcher.py
git commit -m "$(cat <<'EOF'
feat(skills): add <skill-name> worker skill [<slug>]

- Add plugins/agentic-workflows/skills/<skill-name>/SKILL.md
- Add "<new-type>" type to launcher TYPE_MAP
- Add skill-name to launcher AGENT_AUTHOR map
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
- `scripts/launcher.py`: `"<new-type>": "<skill-name>"` added to TYPE_MAP
- `scripts/launcher.py`: `<skill-name>` added to AGENT_AUTHOR map
- `plugins/agentic-workflows/.claude-plugin/plugin.json`: version bump

## Test plan
- [ ] `/skill-creator --task <test-slug> --project WORK` runs without errors
- [ ] Interaction protocol works (post_summary → await_user → read_inbox round-trips with the sidecar)
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
printf '%s\tskill-creator\tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
post_summary "PR ready: $PR_URL — <one line on what changed>"
# IMPORTANT: call this Bash block with timeout=600000
await_user "Attention"
read_inbox
printf '%s\tskill-creator\tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After unblocking:
- **`done`** — approved. Log `approved`. Exit (do not mark Done).
- **Feedback** — read the inbox and the PR comments, apply fixes, then post a summary and `await_user` again.

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
