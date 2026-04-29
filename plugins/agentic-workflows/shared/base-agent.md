Parse arguments:
- `--task <slug>` — required, task slug assigned by the orchestrator (e.g. `WORK-42`)
- `--project <key>` — required, NoteCove project key

If either argument is missing, stop immediately.

---

## Paths (fixed)

```
QUEUE={{AGENTMESH}}/signals/queue
SEQ_FILE={{AGENTMESH}}/signals/<slug>.seq
LOG={{AGENTMESH}}/signals/events.log
```

---

## Signal Sequence Counter

The agent maintains a per-session counter `SIGNAL_SEQ` (starts at 0). It is incremented before every signal and written to `signals/<slug>.seq`. The orchestrator reads this file to know the exact resume signal name to fire: `<slug>-resume-<SIGNAL_SEQ>`.

This guarantees every resume signal is unique across all rounds — a stale stored signal from round N cannot accidentally unblock round N+1.

Initialize at startup:
```bash
SIGNAL_SEQ=0
LOG={{AGENTMESH}}/signals/events.log
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
echo "$SIGNAL_SEQ" > {{AGENTMESH}}/signals/<slug>.seq
# 3. Append slug with event type to queue (format: <slug>:<event-type>)
echo "<slug>:<event-type>" >> {{AGENTMESH}}/signals/queue
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
LOG={{AGENTMESH}}/signals/events.log
TRIAGE_FOLDER=$(notecove folder list --json | python3 -c "import sys,json; folders=json.load(sys.stdin); print(next(f['id'] for f in folders if f['name']=='Triage' and f['parentId'] is None))")
printf '%s\tworker       \tstarted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
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
printf '%s\tworker       \tsignaling-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
SIGNAL_SEQ=$((SIGNAL_SEQ + 1))
echo "$SIGNAL_SEQ" > {{AGENTMESH}}/signals/<slug>.seq
notecove task comments add <slug> --user "Worker" "event:questions"
notecove task change <slug> --state Attention
echo "<slug>:event:questions" >> {{AGENTMESH}}/signals/queue
tmux wait-for -S worker-any-event
# Block until resumed — IMPORTANT: call with timeout=600000
while true; do
  tmux wait-for <slug>-resume-${SIGNAL_SEQ} 2>/dev/null || true
  state=$(notecove task show <slug> --json | python3 -c "import sys,json; print(json.load(sys.stdin)['stateId'])")
  [ "$state" = "doing" ] && break
done
printf '%s\tworker       \tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
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

- **Always define `LOG={{AGENTMESH}}/signals/events.log`** at startup and write `printf '%s\tworker       \t<event>\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, signaling-attention, resumed, implementing, pr-created, signaling-attention-pr-ready, approved/feedback-received).
- **Never interact with the user directly.**
- **Always add an `event:<type>` comment before setting Attention** — the orchestrator reads the last comment to dispatch on event type (event:questions, event:plan-ready, event:pr-ready:<url>, event:ideas-ready, event:selection-ready, event:completion, event:plan-review-complete, event:pr-review-complete). This replaces string-content heuristics.
- **Always set task state before signaling** — orchestrator reads it immediately on wakeup.
- **Always use the shell loop blocking pattern** — never call `tmux wait-for <resume-signal>` bare. The Bash tool times out after 2 minutes (max 10 with `timeout=600000`); the loop re-blocks internally until the expected state is confirmed.
- **Always use `timeout=600000`** on Bash calls that contain the blocking loop — this maximizes time between spurious wakeups.
- **Never mark task Done** — only the orchestrator does that, after user approval.
- **Signal before exiting** — even on error, signal so the orchestrator can clean up.
- **File triage tasks proactively** — anything noteworthy you notice goes into the Triage folder (`${TRIAGE_FOLDER}`, resolved at startup), regardless of whether it is related to your assigned task.
