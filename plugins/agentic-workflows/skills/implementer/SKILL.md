---
name: implementer
extends: ../../shared/base-implementer.md
description: Implementer agent that picks up an assigned NoteCove task, implements it by writing code and creating a PR, and talks to the user entirely through NoteCove comments — never interacts with the user directly
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, git *, gh pr *, echo *, cat *, mkdir *, python3 *), Read, Glob, Grep, Edit, Write
hint: "Implementer agent for an assigned task. Required: --task <slug> --project <key>"
agent-user: "Implementer"
log-prefix: "implementer  "
role: implementer
---

# Implementer — NoteCove Task Implementer Agent

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
LOG=~/agentmesh/signals/events.log
HELPER=~/agentmesh/scripts/agent-notecove.sh
```

---

## How You Talk To The User

**NoteCove is the only interaction surface.** There is no orchestrator relaying messages and no chat interface — you and the user communicate directly through the task itself:

- **Comments** carry the conversation, in both directions. You post; the user replies; you read the reply.
- **Notes** carry artifacts. Plans, findings, question sets, designs — anything longer than a short paragraph.
- **Task state** carries intent. Only you and the user change it.

Each agent runs with a **sidecar** — a generic watcher process (`scripts/sidecar.sh`) that monitors your task and, when the user comments or changes the state, **types a message into your Claude REPL**. You do not block and you do not poll: you hand the task back and end your turn, and the reply arrives as a new turn.

### The interaction cycle

```bash
post_summary "<brief summary of what you just did>"
request_attention "Attention"
```

`request_attention` sets the task state and **returns immediately** — it does not wait. End your turn once it returns. Anything you write after it in the same turn will not be reached by the user's reply.

### Resuming after a message

A delivered message looks like `[agentmesh] New activity on <slug> — …`. Start that turn by getting back into working shape:

```bash
source ~/agentmesh/scripts/agent-notecove.sh
agent_init "<slug>" "Implementer"
resume_work                # back to Doing — you are working again
read_inbox                 # what the sidecar had to tell you
```

`read_inbox` prints line-delimited JSON and clears the inbox:

```
{"kind":"comment","id":"...","author":"gara","content":"looks good, ship it","created":...}
{"kind":"state-change","from":"doing","to":"...","to_name":"Won't Do"}
{"kind":"pr-merged","url":"https://github.com/foo/bar/pull/1","note":"PR was merged. Set the task to Done."}
```

An **empty** `read_inbox` is normal, not an error: a message can arrive for a change you have already drained. Nothing new means carry on with what you were doing.

### Messages can arrive while you are working

That is the point of delivering them rather than signalling: a message typed into your REPL mid-turn is queued by Claude Code and handed to you when the current turn ends. So a reply is no longer stuck behind your next `request_attention`.

When one arrives mid-work, read the inbox, fold what it says into what you are doing, and **stay in `Doing`** — you are still working. Only `request_attention` hands the task back.

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

- Call `resume_work` (→ `Doing`) as the first action of **every** working turn: on startup, and again each time a delivered message puts you back to work. `Doing` means "an agent is working on this right now".
- Call `request_attention` (→ `Attention`) only when you are finished for now and the user has the task. A task left in `Attention` while you work misreports both.
- Never run a bare `notecove task change --state ...`. `set_state` (which `resume_work`, `request_attention` and `finish_task` all go through) records the state in `signals/<slug>.self-state` first, so the sidecar can tell your own move from the user's. Without that marker your own writes come back to you as messages.
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

Call `watch_pr "$PR_URL"` right after creating it, before `request_attention`:

```bash
watch_pr "$PR_URL"
```

That starts a monitor which delivers a message to you when the PR is merged, so a user who merges on GitHub instead of commenting `approve` still gets a response. Without it, a merge is invisible to you and the task sits in `Attention` indefinitely.

### If you were restarted mid-task

You may be a replacement for a worker that died. The launcher spawns a fresh worker for any task left in `Doing` or `Attention` with no live worker window, so finding existing notes in your task folder is normal, not an error.

Read them before doing anything: a `PLAN`, `QUESTIONS-<N>`, or `COMPLETION` note means that work is already done. Pick up from where it left off rather than repeating it, and check the task's comments for the conversation so far.

Also drain your inbox at startup (`read_inbox`, Step 1 below). A reply the user left while the previous worker was dying is still sitting there, and nothing will deliver it again.

---

## Step 1: Initialize

```bash
LOG=~/agentmesh/signals/events.log
source ~/agentmesh/scripts/agent-notecove.sh
agent_init "<slug>" "Implementer"
resume_work                # claim the task: Doing
read_inbox                 # drain anything left by a previous worker
printf '%s\timplementer  \tstarted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

`agent_init` does two things besides setting your handle. It clears `signals/<slug>.launching`, the flag the launcher uses to keep its next scan from spawning a second worker for this task while you were booting — claiming the task by setting `Doing` is what releases it. And it writes `signals/<slug>.ready`, the sidecar's gate for typing into your REPL: until it exists the sidecar records changes in your inbox but delivers nothing, because `spawn-agent.sh` may still be typing your skill invocation and a message would land in the middle of that command line. That is why Step 1 drains the inbox.

The handle passed to `agent_init` **must** match the `--user` value your comments carry (`Implementer`) — the sidecar filters your own comments by author name, so a mismatch makes you wake yourself on every comment you write.

---

## Shared Critical Rules

- **Always `source ~/agentmesh/scripts/agent-notecove.sh` + `agent_init <slug> "Implementer"`** at startup, and define `LOG=`. Write `printf '%s\timplementer  \t<event>\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, awaiting-user, resumed, implementing, pr-created, approved/feedback-received).
- **Never interact with the user outside NoteCove.** No terminal output intended for them, no other channel.
- **Always post a summary comment before `request_attention`** — otherwise the user is handed a task with no explanation of what you want.
- **Keep comments brief.** A few sentences. Artifacts belong in notes.
- **`request_attention` does not block — end your turn after it.** Do not poll the inbox, do not sleep, do not call it in a loop. The sidecar starts your next turn by typing a message into your REPL.
- **Call `resume_work` at the top of every working turn.** `Doing` while you work, `Attention` only when the user has the task.
- **Never change state with a bare `notecove task change --state ...`** — go through `resume_work` / `request_attention` / `finish_task`, which record the move so the sidecar does not report it back to you.
- **An empty `read_inbox` is not an error.** It means nothing new; carry on.
- **Always finish with `finish_task "<state>" "<project>"`** — never a bare `notecove task change --state Done`. It is what releases blocked dependents and stops your sidecar; nothing else does.
- **If the user set the terminal state**, call `finish_cleanup "<project>"` instead — their state stands, but the cleanup is still owed.
- **Call `watch_pr "$PR_URL"` after creating a PR** — otherwise a merge on GitHub never reaches you.
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
printf '%s\timplementer  \tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
post_summary "<brief summary — a few sentences; link any note you wrote>"
request_attention "Attention"
```

**Then end your turn.** Do not poll, do not sleep, do not run anything else. The sidecar delivers the user's reply into your REPL as a new turn; your next turn starts with `resume_work` and `read_inbox`.

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

```bash
notecove note create "<slug>/PLAN" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Implementation Plan

**Task:** <slug> — <title>

## Phase 1: <name>
- <step>

## Phase 2: <name>
- <step>
EOF
```

Set task to Attention and signal for plan review:
```bash
printf '%s\timplementer  \tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
post_summary "Wrote <slug>/PLAN — <one line on the approach>"
request_attention "Attention"
```

**Then end your turn.** The sidecar delivers the user's reply into your REPL as a new turn — see *Resuming after a message* in the shared section above. Nothing you write after this point in the same turn will be reached by that reply.

After confirmed resume:
1. Read the inbox for the user's feedback.
2. If no significant changes needed → proceed directly to Phase 4 without re-signaling.
3. If the plan needs revision → update the `<slug>/PLAN` note, then post a summary of what changed and `request_attention` again:
```bash
printf '%s\timplementer  \tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
post_summary "Revised <slug>/PLAN — <one line on what changed>"
request_attention "Attention"
```

**Then end your turn.** The sidecar delivers the user's reply into your REPL as a new turn — see *Resuming after a message* in the shared section above. Nothing you write after this point in the same turn will be reached by that reply.
Repeat steps 1–3 until the user approves the plan.

---

## Phase 4: Implementation

### 4a. Pull latest main and create git worktree

Fetch the latest main branch and create an isolated worktree for this task:

```bash
# Fetch latest main without disturbing the current worktree's branch
git fetch origin main

# Create a new worktree branching from origin/main
REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_PATH="${REPO_ROOT}/agentmesh-<slug>"
git worktree add "$WORKTREE_PATH" -b <slug>-impl origin/main

# All subsequent implementation and commit work happens inside the worktree
cd "$WORKTREE_PATH"
```

Using a worktree per task ensures parallel workers never conflict on branch checkouts, and every worker always starts from the latest upstream main.

### 4b. Implement

Log the start of implementation:
```bash
printf '%s\timplementer  \timplementing\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

- Write tests first, then implement
- Follow existing code patterns
- Keep changes minimal and scoped to the plan

### 4c. Update workflow docs if applicable

After implementing, check whether any changes touch workflow-defining files. If so, update `docs/agentic-workflow.md` in the worktree to keep documentation accurate.

**Workflow-defining files:**
- `scripts/` (launcher.py, sidecar.sh, agent-notecove.sh, watchdog.sh) — in the agentmesh worktree
- `CLAUDE.md` — in the agentmesh worktree
- `plugins/agentic-workflows/skills/*/SKILL.md` — skills (in the agentmesh worktree)
- `plugins/agentic-workflows/shared/base-agent.md` — base agent (in the agentmesh worktree)

```bash
# Changes in the agentmesh worktree relative to origin/main
WORKTREE_CHANGES=$(git diff --name-only origin/main -- scripts/ CLAUDE.md plugins/agentic-workflows/ 2>/dev/null || true)

if [ -n "$WORKTREE_CHANGES" ]; then
  echo "Workflow-related changes detected — updating docs/agentic-workflow.md"
  # 1. Read docs/agentic-workflow.md and the changed files
  # 2. Update the relevant sections to reflect the changes
  # 3. Sync the NoteCove note:
  notecove note edit 69727mvfcq15fp9v9db2pv8mec --content-file docs/agentic-workflow.md
fi
```

If changes are detected, read `docs/agentic-workflow.md` and the changed files, then update the relevant sections of the document before syncing.

### 4d. Log completion and proceed to PR

Add a task comment summarizing what was done:
```bash
notecove task comments add <slug> --user "Implementer" "Implementation complete: <brief summary>"
```

Proceed directly to Phase 5. After creating the PR, post a summary with the PR URL and `request_attention`.

---

## Phase 5: PR Creation

### 5a. Commit

```bash
git commit -m "$(cat <<'EOF'
<type>(<scope>): <summary> [<slug>]

- <what and why>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

### 5b. Push and create PR

Before pushing, verify you are on the task branch — never push to `main`:
```bash
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "main" ]; then
  echo "ABORT: On main branch — worktree setup failed. Do not push." >&2
  exit 1
fi
```

Capture the PR URL from `gh pr create` output — it is used in the completion note:
```bash
git push -u origin "$CURRENT_BRANCH"
PR_URL=$(gh pr create --title "<type>(<scope>): <summary> [<slug>]" --body "$(cat <<'EOF'
## Summary
<what this PR does>

## Changes
- <file>: <what changed>

## Test plan
<how to verify>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)")
echo "PR created: $PR_URL"
# Start the merge monitor so a merge on GitHub reaches you even if the user
# never comments `approve`.
watch_pr "$PR_URL"
```

### 5c. Signal Attention (PR ready)

Create a completion note (now that the PR URL is available):
```bash
notecove note create "<slug>/COMPLETION" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Implementation Complete

## What was done
<summary>

## PR
<PR-URL>
EOF
```

Log the PR creation and signal `Attention` (PR ready):
```bash
printf '%s\timplementer  \tpr-created\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```
```bash
printf '%s\timplementer  \tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
post_summary "PR ready: $PR_URL — <one line on what changed>"
request_attention "Attention"
```

**Then end your turn.** The sidecar delivers the user's reply into your REPL as a new turn — see *Resuming after a message* in the shared section above. Nothing you write after this point in the same turn will be reached by that reply.

Read the inbox and act on what it says:
- **`approve`** — the user accepted the PR. Log `printf '%s\timplementer  \tapproved\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"`, then `finish_task "Done" "<project>"` and exit.
- **`abort`** — `finish_task "Won't Do" "<project>"` and exit.
- **A `state-change` you did not make** — the user set a terminal state themselves. Call `finish_cleanup "<project>"` and exit; do not overwrite their state.
- **Anything else is feedback.** Log `printf '%s\timplementer  \tfeedback-received\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"`, then fetch the PR comments too:
  ```bash
  gh pr view "$PR_URL" --comments
  ```
  Apply any needed fixes (amend or push additional commits), then re-signal with the appropriate event.

  After pushing the fixes, post a summary of what changed and `request_attention` again:
  ```bash
  printf '%s\timplementer  \tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  post_summary "PR updated: $PR_URL — <one line on what changed>"
  request_attention "Attention"
  ```

  **Then end your turn.** The sidecar delivers the user's reply into your REPL as a new turn — see *Resuming after a message* in the shared section above. Nothing you write after this point in the same turn will be reached by that reply.

  When you consider the PR complete and it is ready for the user's final call:
  ```bash
  printf '%s\timplementer  \tawaiting-user\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  post_summary "PR ready for your call: $PR_URL — <one line on what changed>"
  request_attention "Attention"
  ```

  **Then end your turn.** The sidecar delivers the user's reply into your REPL as a new turn — see *Resuming after a message* in the shared section above. Nothing you write after this point in the same turn will be reached by that reply.

  Repeat until state is `done`.

---

## NoteCove Conventions

| Artifact | Naming |
|---|---|
| Questions | `<slug>/QUESTIONS-<N>` |
| Plan | `<slug>/PLAN` |
| Completion | `<slug>/COMPLETION` |

**Task states used by implementer**: `Doing` (working), `Attention` (needs user input, plan review, or PR ready)
**Task states you set yourself**: `Done` (after the user approves), `Won't Do` (on abort)

---

## Critical Rules

*(See Shared Critical Rules above. Implementer-specific additions:)*

- **Never push to `main`** — always work in the task worktree (`WORKTREE_PATH`) on branch `<slug>-impl`. Phase 5b includes a guard that aborts if `git branch --show-current` returns `main`.
- **The PR-ready Attention loop breaks on `done` OR `doing`** — `done` means approved (exit), `doing` means feedback (continue working and re-signal `Attention` when ready).
