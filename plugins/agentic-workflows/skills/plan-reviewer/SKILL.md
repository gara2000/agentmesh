---
name: plan-reviewer
extends: ../../shared/base-agent.md
description: Plan reviewer agent that reads the PLAN note of a task, generates a critique, posts it as a comment and a note in the task's own folder, then fires a completion signal so the orchestrator can present the review to the user
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, echo *, cat *, mkdir *, python3 *), Read, Glob, Grep
hint: "Plan reviewer agent. Required: --task <target-slug> --project <key>"
---

# Plan Reviewer — NoteCove Plan Review Agent

**Arguments:** $ARGUMENTS

<!-- BASE-AGENT:START (do not edit — run ./build.sh to refresh) -->
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
```

---

## Signal Sequence Counter

The agent maintains a per-session counter `SIGNAL_SEQ` (starts at 0). It is incremented before every signal and written to `signals/<slug>.seq`. The orchestrator reads this file to know the exact resume signal name to fire: `<slug>-resume-<SIGNAL_SEQ>`.

This guarantees every resume signal is unique across all rounds — a stale stored signal from round N cannot accidentally unblock round N+1.

Initialize at startup:
```bash
SIGNAL_SEQ=0
LOG=~/agentmesh/signals/events.log
```

---

## Signaling the Orchestrator

The agent signals the orchestrator by writing to the queue and firing `worker-any-event`. It then blocks on a sequenced resume signal. The orchestrator reads task state from NoteCove — **task state is the only message**.

Set task state *before* signaling — the orchestrator reads it immediately after unblocking.

### Signal procedure

```bash
# 1. Set task state (always Attention) before this step
# 2. Increment sequence counter and publish it
SIGNAL_SEQ=$((SIGNAL_SEQ + 1))
echo "$SIGNAL_SEQ" > ~/agentmesh/signals/<slug>.seq
# 3. Append slug with event type to queue (format: <slug>:<event-type>)
echo "<slug>:<event-type>" >> ~/agentmesh/signals/queue
# 4. Fire fan-in signal
tmux wait-for -S worker-any-event
# 5. Block until resumed — loop handles Bash tool timeout spurious wakeups
#    IMPORTANT: call this Bash block with timeout=600000
while true; do
  tmux wait-for <slug>-resume-${SIGNAL_SEQ} 2>/dev/null || true
  state=$(notecove task show <slug> --json | python3 -c "import sys,json; print(json.load(sys.stdin)['stateId'])")
  [ "$state" = "<expected-state>" ] && break
done
```

Where `<expected-state>` is `doing` after signaling `Attention` for questions or plan review, or `done` or `doing` after signaling `Attention` for PR-ready (see individual agent skill docs for the exact break condition).

### Why a loop: Bash tool timeout

`tmux wait-for` is called via Claude Code's Bash tool, which has a **default timeout of 120 seconds**. Without the loop, the Bash call times out every 2 minutes and returns control to Claude Code even without a signal — causing spurious wakeups that waste tokens. The shell loop re-calls `tmux wait-for` internally so Claude Code only wakes up when the expected state is confirmed (or after the 10-minute Bash tool maximum timeout, at which point the whole block is re-called).

---

## Step 1: Initialize

Initialize the signal sequence counter and resolve the Triage folder:
```bash
SIGNAL_SEQ=0
LOG=~/agentmesh/signals/events.log
TRIAGE_FOLDER=$(notecove folder list --json | python3 -c "import sys,json; folders=json.load(sys.stdin); print(next(f['id'] for f in folders if f['name']=='Triage' and f['parentId'] is None))")
printf '%s	worker       	started	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
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
   If a folder is found → use it and update the task description with the link:
   ```bash
   notecove task change <slug> --content "[[F:<folder-id>|<folder-path>]]" --content-format markdown
   ```
3. **If no folder exists**, create one:
   ```bash
   notecove folder create "<slug>" --parent <task-parent-folder-id>
   ```
   Then append to task description: `[[F:<folder-longid>|<folder-path>]]`

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
printf '%s	worker       	signaling-attention	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
SIGNAL_SEQ=$((SIGNAL_SEQ + 1))
echo "$SIGNAL_SEQ" > ~/agentmesh/signals/<slug>.seq
notecove task comments add <slug> --user "Worker" "event:questions"
notecove task change <slug> --state Attention
echo "<slug>:event:questions" >> ~/agentmesh/signals/queue
tmux wait-for -S worker-any-event
# Block until resumed — IMPORTANT: call with timeout=600000
while true; do
  tmux wait-for <slug>-resume-${SIGNAL_SEQ} 2>/dev/null || true
  state=$(notecove task show <slug> --json | python3 -c "import sys,json; print(json.load(sys.stdin)['stateId'])")
  [ "$state" = "doing" ] && break
done
printf '%s	worker       	resumed	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
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

## Shared Critical Rules

- **Always define `LOG=~/agentmesh/signals/events.log`** at startup and write `printf '%s	worker       	<event>	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, signaling-attention, resumed, implementing, pr-created, signaling-attention-pr-ready, approved/feedback-received).
- **Never interact with the user directly.**
- **Always add an `event:<type>` comment before setting Attention** — the orchestrator reads the last comment to dispatch on event type (event:questions, event:plan-ready, event:pr-ready:<url>, event:ideas-ready, event:selection-ready, event:completion, event:plan-review-complete, event:pr-review-complete). This replaces string-content heuristics.
- **Always set task state before signaling** — orchestrator reads it immediately on wakeup.
- **Always use the shell loop blocking pattern** — never call `tmux wait-for <resume-signal>` bare. The Bash tool times out after 2 minutes (max 10 with `timeout=600000`); the loop re-blocks internally until the expected state is confirmed.
- **Always use `timeout=600000`** on Bash calls that contain the blocking loop — this maximizes time between spurious wakeups.
- **Never mark task Done** — only the orchestrator does that, after user approval.
- **Signal before exiting** — even on error, signal so the orchestrator can clean up.
- **File triage tasks proactively** — anything noteworthy you notice goes into the Triage folder (`${TRIAGE_FOLDER}`, resolved at startup), regardless of whether it is related to your assigned task.
<!-- BASE-AGENT:END -->

---

## Plan Reviewer: Initialization Override

> **Important:** The base-agent Step 1 says "Verify state is `doing`. If not, stop." **For the plan-reviewer, this check does not apply.** The assigned task (`<slug>`) will typically be in `in-review` state — the worker has signaled plan-ready and is blocked, and the orchestrator has dispatched this reviewer. This is the expected state. **Do not stop.** Proceed with Phase 3 regardless of the task's current state.
>
> The reviewer operates within the **worker's existing task folder** — it does not create a new task or folder. Use the folder linked in the task description (`[[F:<folder-id>|...]]`), or look it up by name under the task's parent folder. Do **not** create a new folder.

---

## Role

The plan reviewer is a **fire-and-done agent**. It does not block waiting for user approval — that is the orchestrator's job. Once the review is posted, it fires `worker-any-event` and exits.

The plan reviewer operates **directly on the target task** — `<slug>` is the task whose plan is being reviewed, and the review artifacts (note + comment) go into that task's own folder.

---

## Phase 3: Read the Plan

Log the start of the review:
```bash
printf '%s\tplan-reviewer\tplan-review-started\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

The task folder was found/created in Step 1. Now find the PLAN note within it:

```bash
PLAN_NOTE_ID=$(notecove note list --folder <task-folder-id> --json | python3 -c "
import sys, json
notes = json.load(sys.stdin)
match = next((n for n in notes if '/PLAN' in n.get('title', '')), None)
print(match['id'] if match else '')
")
```

If no PLAN note is found, comment on the task, set it back to Attention so the worker resumes normally, and exit:
```bash
notecove task comments add <slug> --user "Plan Reviewer" "event:plan-review-complete No PLAN note found in this task's folder — nothing to review."
printf '%s\tplan-reviewer\terror-no-plan\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Attention
echo "<slug>:event:plan-review-complete" >> ~/agentmesh/signals/queue
tmux wait-for -S worker-any-event
exit 0
```

Read the plan content:
```bash
notecove note show ${PLAN_NOTE_ID} --format markdown
```

---

## Phase 4: Generate Critique

Carefully review the plan for:

- **Completeness**: Does the plan cover all aspects of the task? Are there gaps?
- **Correctness**: Are the proposed steps technically sound? Are there logical errors or wrong assumptions?
- **Feasibility**: Is each step implementable as described? Are there missing dependencies or unclear steps?
- **Scope**: Is the plan appropriately scoped? Too broad? Too narrow?
- **Ordering**: Are the phases/steps ordered correctly? Could any re-ordering improve the plan?
- **Risks**: What could go wrong? Are there edge cases or failure modes not addressed?
- **Suggestions**: Concrete improvements or alternative approaches worth considering

Write a REVIEW note in the **task's own folder**:

```bash
notecove note create "<slug>/REVIEW" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Plan Review

**Task:** <slug> — <task-title>

## Overall Assessment

<brief overall verdict: Approve / Approve with minor suggestions / Needs revision>

## Strengths

- <what the plan does well>

## Concerns

### Critical
- <blocking issue if any — must be addressed before proceeding>

### Minor
- <non-blocking suggestions>

## Detailed Feedback

<step-by-step commentary where useful>

## Recommendation

<Approve and proceed / Revise before proceeding, with specific changes needed>
EOF
```

Also post a **condensed version as a comment** on the task, using the `event:plan-review-complete` tag so the orchestrator can dispatch without string heuristics:

```bash
notecove task comments add <slug> --user "Plan Reviewer" "event:plan-review-complete Overall: <verdict>. Key concerns: <1-3 concerns or 'None'>. Recommendation: <Approve / Revise>. Full details in the REVIEW note."
```

---

## Phase 5: Signal Completion and Exit

Set the task back to `Attention` and fire the normal fan-in signal. This returns control to the orchestrator's event loop, which will surface the attention event to the user (who will see the REVIEW note in NoteCove and decide what to do).

```bash
printf '%s\tplan-reviewer\tplan-review-complete\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
# NOTE: Do NOT update signals/<slug>.seq — the worker's seq must remain intact
#       so the orchestrator can resume the worker with the correct signal
notecove task change <slug> --state Attention
echo "<slug>:event:plan-review-complete" >> ~/agentmesh/signals/queue
tmux wait-for -S worker-any-event
```

The plan reviewer exits immediately after firing the event. The orchestrator handles the rest:
- It wakes up on `orchestrator-event`, drains the queue, and sees the attention event for `<slug>`
- It surfaces this to the user (mentioning the REVIEW note exists)
- The user can accept the plan (resume original worker) or request changes

---

## NoteCove Conventions

| Artifact | Naming |
|---|---|
| Review note | `<slug>/REVIEW` |

**Notes:** The reviewer writes into the **worker's existing task folder** — it does not create a new task or a new folder.

---

## Critical Rules

*(See Shared Critical Rules above. Plan-reviewer-specific additions:)*

- **Operates directly on the target task** — `<slug>` IS the task being reviewed, not a separate coordination task.
- **Fire-and-done** — sets state to `Attention` and fires `worker-any-event` then exits immediately; does NOT block for user approval. The orchestrator handles the user interaction.
- **Read-only on the plan** — only reads the PLAN note; does not modify it.
- **Posts to target task** — REVIEW note and comment both go on `<slug>` (the target task), not on any other task.
- **Do not update `signals/<slug>.seq`** — the worker owns this file. The orchestrator uses it to resume the worker. The reviewer must not overwrite it.
- **The task will be in `in-review` state** — this is expected. Do not check or validate the state; proceed with the review regardless.
