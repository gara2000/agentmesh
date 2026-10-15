<!-- Implementer-family base file (base-agent.md → base-implementer.md → implementer/planner/brainstormer).
     Contains shared signal protocol (from base-agent.md) plus folder management, exploration,
     questions, and proactive issue reporting conventions used only by implementer agents.

     Authoring: edit the implementer-specific sections below the BASE-AGENT block freely.
     To propagate base-agent.md changes into this file, run:
       ./build.sh --update-family-bases
     The BASE-AGENT block is auto-managed — do not edit it manually. -->

<!-- BASE-AGENT:START (do not edit — run ./build.sh --update-family-bases to refresh) -->
Parse arguments:
- `--task <slug>` — required, task slug assigned by the launcher (e.g. `WORK-42`)
- `--project <key>` — required, NoteCove project key

If either argument is missing, stop immediately.

---

## Paths (fixed)

```
INBOX={{AGENTMESH}}/signals/<slug>.inbox
SEQ_FILE={{AGENTMESH}}/signals/<slug>.seq
LOG={{AGENTMESH}}/signals/events.log
HELPER={{AGENTMESH}}/scripts/agent-notecove.sh
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

If `read_inbox` reports a `state-change` you did not make — the user moved the task to `Won't Do`, `Blocked`, or anything terminal — stop work and exit. Do not call `finish_task`, which would overwrite their state; call `finish_cleanup` instead:

```bash
finish_cleanup "<project>"    # the user set the terminal state; still release dependents
```

The cleanup is still required even though you did not set the state: nothing else releases tasks blocked on this one or stops your sidecar.

### If you create a PR

Call `watch_pr "$PR_URL"` right after creating it, before `await_user`:

```bash
watch_pr "$PR_URL"
```

That starts a monitor which nudges you when the PR is merged, so a user who merges on GitHub instead of commenting `approve` still gets a response. Without it, a merge is invisible to you and the task sits in `Attention` indefinitely.

### If you were restarted mid-task

You may be a replacement for a worker that died. The launcher spawns a fresh worker for any task left in `Doing` or `Attention` with no live worker window, so finding existing notes in your task folder is normal, not an error.

Read them before doing anything: a `PLAN`, `QUESTIONS-<N>`, or `COMPLETION` note means that work is already done. Pick up from where it left off rather than repeating it, and check the task's comments for the conversation so far.

---

## Step 1: Initialize

```bash
LOG={{AGENTMESH}}/signals/events.log
source {{AGENTMESH}}/scripts/agent-notecove.sh
agent_init "<slug>" "{{AGENT_USER}}"
notecove task change <slug> --state Doing
printf '%s\t{{LOG_PREFIX}}\tstarted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

`agent_init` also clears `signals/<slug>.launching`, the flag the launcher uses to keep its next scan from spawning a second worker for this task while you were booting. Claiming the task by setting `Doing` is what releases it.

The handle passed to `agent_init` **must** match the `--user` value your comments carry (`{{AGENT_USER}}`) — the sidecar filters your own comments by author name, so a mismatch makes you wake yourself on every comment you write.

---

## Shared Critical Rules

- **Always `source {{AGENTMESH}}/scripts/agent-notecove.sh` + `agent_init <slug> "{{AGENT_USER}}"`** at startup, and define `LOG=`. Write `printf '%s\t{{LOG_PREFIX}}\t<event>\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, awaiting-user, resumed, implementing, pr-created, approved/feedback-received).
- **Never interact with the user outside NoteCove.** No terminal output intended for them, no other channel.
- **Always post a summary comment before `await_user`** — otherwise the user is woken by a state change with no explanation of what you want.
- **Keep comments brief.** A few sentences. Artifacts belong in notes.
- **Always use `timeout=600000`** on Bash calls containing `await_user`. The Bash tool caps at 10 minutes, so long waits get interrupted; re-calling `await_user` is safe (the announce and the wait are separate, and the wait writes nothing).
- **Always finish with `finish_task "<state>" "<project>"`** — never a bare `notecove task change --state Done`. It is what releases blocked dependents and stops your sidecar; nothing else does.
- **If the user set the terminal state**, call `finish_cleanup "<project>"` instead — their state stands, but the cleanup is still owed.
- **Call `watch_pr "$PR_URL"` after creating a PR** — otherwise a merge on GitHub never reaches you.
- **Check your task folder for existing notes at startup** — you may be a restarted worker, and repeating finished work wastes the user's time.
<!-- BASE-AGENT:END -->

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
<!-- SIGNAL: await -->

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
