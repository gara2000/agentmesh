---
name: worker
extends: ../../shared/base-agent.md
description: Worker agent that picks up an assigned NoteCove task, works through it autonomously, and signals the orchestrator when input is needed or work is done — never interacts with the user directly
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, git *, gh pr *, echo *, cat *, mkdir *, python3 *), Read, Glob, Grep, Edit, Write
hint: "Worker agent for an assigned task. Required: --task <slug> --project <key>"
---

# Worker — NoteCove Task Worker Agent

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
printf '%s\tworker       \tsignaling-plan\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
SIGNAL_SEQ=$((SIGNAL_SEQ + 1))
echo "$SIGNAL_SEQ" > ~/agentmesh/signals/<slug>.seq
notecove task comments add <slug> --user "Worker" "event:plan-ready"
notecove task change <slug> --state Attention
echo "<slug>:event:plan-ready" >> ~/agentmesh/signals/queue
tmux wait-for -S worker-any-event
# Block until resumed — IMPORTANT: call with timeout=600000
while true; do
  tmux wait-for <slug>-resume-${SIGNAL_SEQ} 2>/dev/null || true
  state=$(notecove task show <slug> --json | python3 -c "import sys,json; print(json.load(sys.stdin)['stateId'])")
  [ "$state" = "doing" ] && break
done
printf '%s\tworker       \tresumed-from-plan\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

After confirmed resume: check task comments for feedback, adjust plan if needed, proceed to Phase 4.

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
printf '%s\tworker       \timplementing\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

- Write tests first, then implement
- Follow existing code patterns
- Keep changes minimal and scoped to the plan

### 4c. Update workflow docs if applicable

After implementing, check whether any changes touch workflow-defining files. If so, update `docs/agentic-workflow.md` in the worktree to keep documentation accurate.

**Workflow-defining files:**
- `scripts/` (dispatcher, watchdog) — in the agentmesh worktree
- `CLAUDE.md` — in the agentmesh worktree
- `~/personal/claude-marketplace/plugins/agentic-workflows/skills/*/SKILL.md` — skills
- `~/personal/claude-marketplace/plugins/agentic-workflows/shared/base-agent.md` — base agent

```bash
# Changes in the agentmesh worktree relative to origin/main
WORKTREE_CHANGES=$(git diff --name-only origin/main -- scripts/ CLAUDE.md 2>/dev/null || true)

# Uncommitted changes in the agentic-workflows marketplace plugin
PLUGIN_CHANGES=$(cd ~/personal/claude-marketplace && git status --porcelain -- plugins/agentic-workflows/ 2>/dev/null | awk '{print $2}' || true)

if [ -n "$WORKTREE_CHANGES" ] || [ -n "$PLUGIN_CHANGES" ]; then
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
notecove task comments add <slug> --user "Worker" "Implementation complete: <brief summary>"
```

Proceed directly to Phase 5. After creating the PR, signal `Attention` so the orchestrator can surface the work to the user.

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

Capture the PR URL from `gh pr create` output — it is used in the CI gate and completion note:
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
```

### 5b-ci. Wait for CI checks to pass

After PR creation, poll required CI checks before surfacing the PR to the user. This ensures the user only sees a PR that has already cleared automated testing.

**Initial delay** — checks may not register on GitHub immediately after PR creation:
```bash
printf '%s\tworker       \tci-wait-start\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
sleep 15
```

**Polling loop** — poll every 30 seconds for up to 10 minutes per Bash call. Use the `bucket` field (not `state`) which `gh pr checks --json` normalizes to: `pass`, `fail`, `pending`, `skipping`, `cancel`. Use `--required` to filter to required checks only.

```bash
CI_RESULT="pending"
CI_DEADLINE=$(( $(date +%s) + 570 ))   # 9.5 min — leaves buffer before 10-min tool timeout

while true; do
  [ "$(date +%s)" -ge "$CI_DEADLINE" ] && break

  CHECKS_JSON=$(gh pr checks "$PR_URL" --required --json name,state,bucket 2>/dev/null || echo "[]")
  CI_RESULT=$(echo "$CHECKS_JSON" | python3 -c "
import sys, json
checks = json.load(sys.stdin)
if not checks:
    print('pass'); sys.exit()
buckets = {c['bucket'] for c in checks}
if any(b in ('fail', 'cancel') for b in buckets):
    print('fail')
elif any(b == 'pending' for b in buckets):
    print('pending')
else:
    print('pass')
")
  [ "$CI_RESULT" = "pass" ] && break
  [ "$CI_RESULT" = "fail" ] && break
  sleep 30
done

printf '%s\tworker       \tci-wait-complete\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
echo "CI_RESULT=$CI_RESULT"
```

**After the polling block:**
- `CI_RESULT=pass` → continue to Phase 5c normally.
- `CI_RESULT=fail` → escalate to user (see below).
- `CI_RESULT=pending` (loop hit the 9.5-minute deadline, CI still running) → re-call the polling block. If CI has not resolved after re-calling it twice (total ~30 minutes), treat as timeout and escalate.

**On CI failure or timeout** — create a QUESTIONS note with details and signal `event:questions`:

```bash
# Collect failure detail for the note
FAILED_CHECKS=$(gh pr checks "$PR_URL" --required --json name,state,bucket 2>/dev/null | python3 -c "
import sys, json
checks = json.load(sys.stdin)
non_pass = [c for c in checks if c['bucket'] not in ('pass', 'skipping')]
if non_pass:
    for c in non_pass:
        print(f\"  - {c['name']}: {c['bucket']}\")
else:
    print('  (checks may have expired or no details available)')
" 2>/dev/null || echo "  (could not retrieve check details)")

CI_QUESTIONS_N=<next-questions-round-number>
notecove note create "<slug>/QUESTIONS-${CI_QUESTIONS_N}" --folder <task-folder-id> --content-file - --format markdown --json << EOF
# CI Gate — Round ${CI_QUESTIONS_N}

Required CI checks did not pass for PR: $PR_URL

## Failed / stalled checks

${FAILED_CHECKS}

> **How to answer:** Edit this note or create a \`<slug>/ANSWER-${CI_QUESTIONS_N}\` note.

## Q1: How should I proceed?

Options:
- **Fix**: Investigate and fix the CI failure. I will push a new commit and re-run CI before signaling PR-ready again.
- **Override**: Proceed to signal PR-ready now (please explain why CI failure is acceptable).

**Answer:** _(write here)_
EOF

printf '%s\tworker       \tsignaling-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
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
printf '%s\tworker       \tresumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

**Reading the user's response** — check the QUESTIONS note for inline answers and any separate ANSWER note:
```bash
notecove note show <ci-questions-note-id> --format markdown
# also check:
notecove note list --folder <task-folder-id> --json  # look for ANSWER-<N> notes
```

- If the response says **fix** → investigate the failure (read `gh run view` or `gh pr checks "$PR_URL"`), make the fix, push a new commit, then re-run the CI polling block (loop back to step 5b-ci). Increment `CI_QUESTIONS_N` for the next escalation if needed.
- If the response says **override / proceed** → skip remaining CI checks and continue to Phase 5c.

### 5c. Signal Attention (PR ready)

Create a completion note (now that the PR URL is available):
```bash
notecove note create "<slug>/COMPLETION" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
# Implementation Complete

## What was done
<summary>

## PR
<PR-URL>

## Test results
<results>
EOF
```

Signal `Attention` (PR ready):
```bash
printf '%s\tworker       \tpr-created\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
printf '%s\tworker       \tsignaling-attention-pr-ready\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
SIGNAL_SEQ=$((SIGNAL_SEQ + 1))
echo "$SIGNAL_SEQ" > ~/agentmesh/signals/<slug>.seq
notecove task change <slug> --state Attention
notecove task comments add <slug> --user "Worker" "event:pr-ready:$PR_URL"
echo "<slug>:event:pr-ready:$PR_URL" >> ~/agentmesh/signals/queue
tmux wait-for -S worker-any-event
# Block until resumed — IMPORTANT: call with timeout=600000
# Break on either 'done' (approved) or 'doing' (feedback given)
while true; do
  tmux wait-for <slug>-resume-${SIGNAL_SEQ} 2>/dev/null || true
  state=$(notecove task show <slug> --json | python3 -c "import sys,json; print(json.load(sys.stdin)['stateId'])")
  { [ "$state" = "done" ] || [ "$state" = "doing" ]; } && break
done
```

After unblocking, check which state was set:
- **`done`** — user approved. Log `printf '%s\tworker       \tapproved\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"`. Worker exits. Do not mark task Done yourself — the orchestrator does that.
- **`doing`** — user provided feedback. Log `printf '%s\tworker       \tfeedback-received\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"`. Read task comments and any new ANSWER notes. Also fetch the PR comments to see any AI review feedback:
  ```bash
  gh pr view "$PR_URL" --comments
  ```
  Then continue working (amend the PR or push additional commits as needed), and re-signal `Attention` when ready.

---

## NoteCove Conventions

| Artifact | Naming |
|---|---|
| Questions | `<slug>/QUESTIONS-<N>` |
| Plan | `<slug>/PLAN` |
| Completion | `<slug>/COMPLETION` |

**Task states used by worker**: `Doing` (working), `Attention` (needs user input, plan review, or PR ready)
**Task states set by orchestrator**: `Done` (approved), `Doing` (resumed), `In Review` (reviewer agent dispatched)

---

## Critical Rules

*(See Shared Critical Rules above. Worker-specific additions:)*

- **Never push to `main`** — always work in the task worktree (`WORKTREE_PATH`) on branch `<slug>-impl`. Phase 5b includes a guard that aborts if `git branch --show-current` returns `main`.
- **The PR-ready Attention loop breaks on `done` OR `doing`** — `done` means approved (exit), `doing` means feedback (continue working and re-signal `Attention` when ready).
