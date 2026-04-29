---
name: spokesman
description: Thin user-interaction layer for the AgentMesh agentic workflow. Bootstraps the system (starts orchestrator.py daemon), then surfaces worker events to the user and relays decisions back to the orchestrator.
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, mkdir *, cat *, echo *, rm *, bash *, sleep *, sed *, python3 *)
hint: "Run the AgentMesh Spokesman (user-interaction layer). Required: --project <key>. Optional: --profile <id>, --max-workers <n> (default 5), --mode <mode> (standard|auto-review, default standard), --review-limit <n> (default 3)"
---

# Spokesman — AgentMesh User-Interaction Layer

**Arguments:** $ARGUMENTS

Parse arguments:
- `--project <key>` — required, NoteCove project key (e.g. `WORK`)
- `--profile <id>` — optional, defaults to `kmq9h71tepf95rac2b59xdbsq2`
- `--max-workers <n>` — optional, max concurrent workers, defaults to `5`
- `--mode <mode>` — optional, running mode, defaults to `standard`
  - `standard` — user reviews plans and PRs manually; reviewers spawn only on explicit request
  - `auto-review` — plan-reviewers and PR-reviewers spawn automatically; user only approves final PR
- `--review-limit <n>` — optional, max auto-review cycles per task before escalating to user, defaults to `3`

If `--project` is not provided, stop and ask the user.

---

## Paths (fixed)

```
AGENTMESH=~/agentmesh
SPOKESMAN_QUEUE=~/agentmesh/signals/spokesman-queue
ORCHESTRATOR_CMDS=~/agentmesh/signals/orchestrator-cmds
SPOKESMAN_ACKS=~/agentmesh/signals/spokesman-acks
LOG=~/agentmesh/signals/events.log
MODE_FILE=~/agentmesh/signals/mode
```

## CMD_SEQ Counter

The Spokesman maintains a per-session command sequence counter `CMD_SEQ` (starts at 0). Each command sent to orchestrator.py gets a unique sequence number; the orchestrator writes an ACK with that number to `spokesman-acks` and fires `spokesman-ack-<CMD_SEQ>`.

Initialize at startup alongside `LOG` and `MODE`:
```bash
CMD_SEQ=0
```

### Sending a command to orchestrator.py

Every command send in the event handlers below follows this pattern (substitute the actual `<slug>`, `<cmd>`, and optional `|<args>`):

```bash
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|<cmd>" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
# Wait for ACK — confirms orchestrator.py executed the command
# IMPORTANT: call this Bash block with timeout=600000 to avoid spurious wakeups
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

When the command has extra args, use `echo "${CMD_SEQ}|<slug>|<cmd>|<args>"` instead.

---

## Phase 0: Bootstrap

```bash
bash ~/agentmesh/scripts/bootstrap.sh --project <PROJECT> --profile <profile> --mode <mode> --max-workers <max-workers> --review-limit <review-limit>
LOG=~/agentmesh/signals/events.log
# Persist mode to file so it survives Spokesman restarts
echo "<mode>" > ~/agentmesh/signals/mode
CMD_SEQ=0
TRIAGE_FOLDER=$(cat ~/agentmesh/signals/triage_folder)
```

Announce to the user: "Spokesman ready. Orchestrator running. Picking up Ready tasks..."

---

## Phase 0.5: Startup Recovery

After bootstrap, scan for any tasks currently in `Attention` state. These represent events that were fired before this Spokesman session started (e.g., from a previous session that crashed). Re-queue them so the event loop surfaces them to the user.

```bash
_attention_slugs=$(notecove task list --project <PROJECT> --state Attention --json | \
  python3 -c "import sys,json; [print(t['slug']['short']) for t in json.load(sys.stdin)]" 2>/dev/null || echo "")

for _slug in $_attention_slugs; do
  # Derive event type from last event:* comment on the task
  _last_event=$(notecove task show "$_slug" --format markdown-with-comments | \
    grep "^- " | grep -oP 'event:\S+' | tail -1 2>/dev/null || echo "")
  # Dedup guard: skip if already queued (prevents double-entry race with orchestrator.py)
  if [ -n "$_last_event" ] && ! grep -q "^${_slug}:" ~/agentmesh/signals/spokesman-queue 2>/dev/null; then
    echo "${_slug}:${_last_event}" >> ~/agentmesh/signals/spokesman-queue
  fi
done
```

If any entries were added to the spokesman-queue by the recovery scan, process them directly (jump to step 1b) before entering the normal event loop wait. If the queue is empty, proceed to the main event loop.

---

## Phase 1: Event Loop

### 1a. Wait for event

Re-read all runtime state from files at the top of each wakeup cycle — the Spokesman holds zero in-memory state across cycles:

```bash
MODE=$(cat ~/agentmesh/signals/mode 2>/dev/null || echo "standard")
TRIAGE_FOLDER=$(cat ~/agentmesh/signals/triage_folder 2>/dev/null || echo "")
LOG=~/agentmesh/signals/events.log
```

Then block:

```bash
tmux wait-for spokesman-event
```

### 1a.5. Check orchestrator heartbeat

After each wakeup, verify that orchestrator.py is still alive. If the heartbeat file is stale (not updated in >90 seconds), auto-restart orchestrator.py and inform the user.

```bash
HEARTBEAT=~/agentmesh/signals/orchestrator.heartbeat
RESTART_CMD=$(cat ~/agentmesh/signals/orchestrator-restart-cmd 2>/dev/null || echo "")

if [ -n "$RESTART_CMD" ] && [ -f "$HEARTBEAT" ]; then
  last_modified=$(stat -f %m "$HEARTBEAT" 2>/dev/null || stat -c %Y "$HEARTBEAT" 2>/dev/null)
  now=$(date +%s)
  age=$((now - last_modified))
  if [ "$age" -gt 90 ]; then
    printf '%s\tspokesman    \torchestrator-restarted\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
    echo "⚠  Orchestrator heartbeat stale (${age}s). Restarting orchestrator.py..."
    tmux kill-window -t orchestrator:orchestrator 2>/dev/null || true
    sleep 1
    tmux new-window -t orchestrator -n orchestrator
    tmux send-keys -t orchestrator:orchestrator "$RESTART_CMD" Enter
    echo "Orchestrator restarted. Continuing..."
  fi
fi
```

The `orchestrator-restart-cmd` file is written by `bootstrap.sh` and contains the exact command used to launch orchestrator.py (with the same project, mode, max-workers, and profile arguments).

If `$HEARTBEAT` does not exist (e.g., shortly after bootstrap before orchestrator.py writes its first heartbeat), the check is silently skipped.

### 1b. Drain spokesman-queue

```bash
SPOKESMAN_QUEUE=~/agentmesh/signals/spokesman-queue

while [ -s "$SPOKESMAN_QUEUE" ]; do
  # Atomic drain: rename so orchestrator.py can append to a fresh file concurrently
  TMP_QUEUE="${SPOKESMAN_QUEUE}.draining"
  mv "$SPOKESMAN_QUEUE" "$TMP_QUEUE" 2>/dev/null || break
  entries=$(cat "$TMP_QUEUE")
  rm -f "$TMP_QUEUE"

  for entry in $entries; do
    # Handle event: <slug>:<event-type>[:<data>]
    slug=$(echo "$entry" | cut -d: -f1)
    event_rest=$(echo "$entry" | cut -d: -f2-)
    # handle_event $slug $event_rest
  done
done
```

### 1c. Handle each event

Fetch task title for display:
```bash
task_info=$(notecove task show <slug> --json)
title=$(echo "$task_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))")
seq=$(cat ~/agentmesh/signals/<slug>.seq 2>/dev/null || echo "0")
```

Dispatch on event type:

```
case "$event_rest" in
  event:task-ready)       → task triage (auto, decide agent type, spawn)
  event:completion)       → completion announcement (auto, no user input)
  event:pr-merged-auto-approved) → PR auto-merge announcement (auto, no user input)
  event:shutdown)         → all tasks complete, run Exit phase and stop
  event:questions)        → questions attention
  event:plan-ready)       → plan-ready attention
  event:pr-submitted:*)   → PR submitted (standard mode): needs user decision (approve / review / feedback / abort)
  event:pr-ready:*)       → PR validated (auto-review mode, post-review): ready for final user approval
  event:plan-review-complete) → post-plan-review attention
  event:pr-review-complete)   → post-PR-review attention
  event:review-limit-reached:plan) → plan review limit escalation (requires user decision)
  event:review-limit-reached:pr:*) → PR review limit escalation (requires user decision)
  event:ideas-ready)      → brainstormer ideation
  event:selection-ready)  → brainstormer selection
  *)                      → unknown (log and tell user)
esac
```

---

### Event: `event:task-ready` — new task needs triage

Auto-handle — no user input needed. Read the full task and decide which agent type to spawn.

```bash
task_json=$(notecove task show <slug> --json)
task_md=$(notecove task show <slug> --format markdown-with-comments)
title=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))")
```

Decide agent type using your judgment — you have access to the full task title, description, and any linked context:

- **brainstormer**: the task explicitly asks to generate ideas, explore options, brainstorm approaches, or produce a menu of possibilities for the user to choose from
- **planner**: the task has multiple distinct deliverables or clearly involves coordinating several separate concerns that need decomposition into subtasks before implementation can begin
- **worker**: any other concrete, well-defined implementation task (the default)

Then dispatch:
```bash
printf '%s\tspokesman    \ttask-triaged\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
echo "<slug>|spawn|<agent-type>" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

Tell the user: "Triaged `<slug> — <title>` → spawning **<agent-type>**."

---

### Event: `event:completion` — brainstormer/planner completion

Auto-acknowledge — no user input needed.

```bash
printf '%s\tspokesman    \tagent-completion-ack\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

Tell the user: "Agent task `<slug> — <title>` completed successfully."

---

### Event: `event:pr-merged-auto-approved` — PR auto-merged

Auto-acknowledge — no user input needed.

Tell the user: "PR for `<slug> — <title>` was merged automatically — approved."

---

### Event: `event:shutdown` — all tasks complete

Received from orchestrator.py when active worker count is zero and no Ready tasks remain.

Tell the user: "All tasks complete. Shutting down."

Run the Exit phase immediately (see below).

---

### Event: `event:questions` — worker question

```
── Attention needed ─────────────────────────────
Task: <slug> — <title>
The worker is waiting for your input.
Open NoteCove to review and answer the QUESTIONS note, then say 'continue'.
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If user says 'continue':**
```bash
printf '%s\tspokesman    \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

**If user provides feedback inline:**
```bash
printf '%s\tspokesman    \tattention-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "<feedback>"
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

---

### Event: `event:plan-ready` — plan ready for review

```
── Attention needed ─────────────────────────────
Task: <slug> — <title>
The worker has a plan ready for review.
Open NoteCove to read the PLAN note, then say 'continue'.
(Or say 'spawn reviewer' to have a plan reviewer agent critique the plan first.)
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If user says 'continue':**
```bash
printf '%s\tspokesman    \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

**If user says 'spawn reviewer':**
```bash
printf '%s\tspokesman    \tplan-reviewer-requested\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|spawn-plan-reviewer" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

Tell the user: "Plan reviewer spawned. It will signal when the review is complete."

**If user provides feedback (plan revision):**
```bash
printf '%s\tspokesman    \tattention-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "<feedback>"
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

---

### Event: `event:pr-submitted:<pr-url>` — PR submitted, needs user decision (standard mode)

Fired by the orchestrator in standard mode when a worker signals PR-ready for the first time.
The PR has not yet been reviewed — the user can approve directly, spawn a reviewer, give feedback, or abort.

Extract PR URL from event: `pr_url=${event_rest#event:pr-submitted:}`

```
── PR Submitted ─────────────────────────────────
Task: <slug> — <title>
The worker has submitted a PR and is awaiting your decision.
PR: <pr_url>
Note: a background monitor is running — if the PR is merged, it will be auto-approved.
Options:
  • 'approve'  — accept the PR as-is
  • 'review'   — spawn an AI reviewer to review the PR on your behalf
  • feedback   — provide feedback for the worker to act on
  • 'abort'    — mark the task Won't Do
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If 'approve':**
```bash
printf '%s\tspokesman    \treview-approved\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|pr-approved" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

**If 'review' — spawn pr-reviewer:**
```bash
printf '%s\tspokesman    \treviewer-requested\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|kill-pr-monitor" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|spawn-pr-reviewer" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

Tell the user: "PR reviewer spawned. It will signal when the review is complete — you will see it as an Attention event for this task."

**If feedback provided:**
```bash
printf '%s\tspokesman    \treview-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "<feedback>"
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|kill-pr-monitor" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

**If 'abort':**
```bash
printf '%s\tspokesman    \treview-aborted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state "Won't Do"
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|kill-pr-monitor" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|abort" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

---

### Event: `event:pr-ready:<pr-url>` — PR validated, ready for final approval (auto-review mode)

Fired by the orchestrator in auto-review mode after the PR has already been reviewed by an AI reviewer
and the worker has applied any requested fixes. The PR is validated — no reviewer option is shown.

Extract PR URL from event: `pr_url=${event_rest#event:pr-ready:}`

```
── PR Ready (reviewed) ──────────────────────────
Task: <slug> — <title>
The worker's PR has been reviewed and is ready for your final approval.
PR: <pr_url>
Note: a background monitor is running — if the PR is merged, it will be auto-approved.
Options:
  • 'approve'  — accept the PR
  • feedback   — provide feedback for the worker to act on
  • 'abort'    — mark the task Won't Do
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If 'approve':**
```bash
printf '%s\tspokesman    \treview-approved\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
echo "<slug>|pr-approved" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

**If feedback provided:**
```bash
printf '%s\tspokesman    \treview-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "<feedback>"
notecove task change <slug> --state Doing
echo "<slug>|kill-pr-monitor" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
echo "<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

**If 'abort':**
```bash
printf '%s\tspokesman    \treview-aborted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state "Won't Do"
echo "<slug>|kill-pr-monitor" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
echo "<slug>|abort" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

---

### Event: `event:plan-review-complete` — plan review done

Read the reviewer's summary from the last task comment:
```bash
_comments_raw=$(notecove task show <slug> --format markdown-with-comments)
_reviewer_summary=$(echo "$_comments_raw" | grep "^- " | tail -1 | sed 's/^- [^:]*:[[:space:]]*//' | sed 's/^event:plan-review-complete[[:space:]]*//')
```

```
── Attention needed (plan reviewed) ─────────────
Task: <slug> — <title>
A plan reviewer has completed their review.

Review summary:
<_reviewer_summary>

Options:
  - Say 'continue' to accept the plan and resume the worker
  - Say 'reject review' to discard the review and continue with the original plan
  - Provide feedback for the worker to revise the plan
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If 'continue':**
```bash
printf '%s\tspokesman    \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "Plan accepted after review."
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
# Kill plan-reviewer window
tmux kill-window -t workers:plan-rev-<slug> 2>/dev/null || true
```

**If 'reject review':**
```bash
printf '%s\tspokesman    \treview-rejected\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "Plan review rejected by user. Continuing with original plan."
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
tmux kill-window -t workers:plan-rev-<slug> 2>/dev/null || true
```

**If feedback:**
```bash
printf '%s\tspokesman    \tattention-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "<feedback>"
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
tmux kill-window -t workers:plan-rev-<slug> 2>/dev/null || true
```

---

### Event: `event:pr-review-complete` — PR review done

Read the reviewer's summary from the last task comment:
```bash
_comments_raw=$(notecove task show <slug> --format markdown-with-comments)
_reviewer_summary=$(echo "$_comments_raw" | grep "^- " | tail -1 | sed 's/^- [^:]*:[[:space:]]*//' | sed 's/^event:pr-review-complete[[:space:]]*//')
_pr_url=$(echo "$_comments_raw" | grep "^- " | grep -oP 'event:pr-ready:\S+' | tail -1 | sed 's/event:pr-ready://')
```

```
── PR Review Ready ──────────────────────────────
Task: <slug> — <title>
An AI review has been completed.
PR: <_pr_url>

Review summary:
<_reviewer_summary>

Options:
  • 'approve'   — accept the PR (review validated)
  • feedback    — give feedback to the worker
  • 're-review' — spawn a new pr-reviewer
  • 'abort'     — mark the task Won't Do
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If 'approve':**
```bash
printf '%s\tspokesman    \treview-approved\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|pr-approved" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
# Kill pr-reviewer window
tmux kill-window -t workers:pr-rev-<slug> 2>/dev/null || true
```

**If feedback:**
```bash
printf '%s\tspokesman    \treview-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "<feedback>"
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
tmux kill-window -t orchestrator:pr-mon-<slug> 2>/dev/null || true
tmux kill-window -t workers:pr-rev-<slug> 2>/dev/null || true
```

**If 're-review':**
```bash
tmux kill-window -t workers:pr-rev-<slug> 2>/dev/null || true
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|spawn-pr-reviewer" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

Tell the user: "New PR reviewer spawned."

**If 'abort':**
```bash
printf '%s\tspokesman    \treview-aborted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state "Won't Do"
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|kill-pr-monitor" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|abort" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
tmux kill-window -t workers:pr-rev-<slug> 2>/dev/null || true
```

---

### Event: `event:review-limit-reached:plan` — plan auto-review limit reached

The orchestrator has hit the auto-review cycle limit for plan reviews and is escalating to the user.

```
── Auto-review limit reached (plan) ─────────────
Task: <slug> — <title>
Auto-review limit reached — the plan has been reviewed <n> times automatically.
Manual review required.
Open NoteCove to read the PLAN note and any REVIEW notes, then say 'continue'.
(Or say 'spawn reviewer' to run one additional plan reviewer.)
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If user says 'continue':**
```bash
printf '%s\tspokesman    \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Doing
echo "<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

**If user says 'spawn reviewer':**
```bash
printf '%s\tspokesman    \tplan-reviewer-requested\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
echo "<slug>|spawn-plan-reviewer" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

Tell the user: "Plan reviewer spawned. It will signal when the review is complete."

**If user provides feedback (plan revision):**
```bash
printf '%s\tspokesman    \tattention-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "<feedback>"
notecove task change <slug> --state Doing
echo "<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

---

### Event: `event:review-limit-reached:pr:*` — PR auto-review limit reached

Extract PR URL from event: `pr_url=${event_rest#event:review-limit-reached:pr:}`

The orchestrator has hit the auto-review cycle limit for PR reviews and is escalating to the user.

Spawn pr-monitor before showing prompt:
```bash
echo "<slug>|spawn-pr-monitor|<pr_url>" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

```
── Auto-review limit reached (PR) ───────────────
Task: <slug> — <title>
Auto-review limit reached — the PR has been reviewed automatically the maximum number of times.
Manual review required.
PR: <pr_url>
Note: a background monitor is running — if the PR is merged, it will be auto-approved.
Options:
  • 'approve'  — accept the PR
  • 'review'   — spawn one additional AI reviewer
  • feedback   — provide feedback for the worker to act on
  • 'abort'    — mark the task Won't Do
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If 'approve':**
```bash
printf '%s\tspokesman    \treview-approved\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Done
echo "<slug>|done" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

**If 'review' — spawn pr-reviewer:**
```bash
printf '%s\tspokesman    \treviewer-requested\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
echo "<slug>|kill-pr-monitor" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
echo "<slug>|spawn-pr-reviewer" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

Tell the user: "PR reviewer spawned. It will signal when the review is complete — you will see it as an Attention event for this task."

**If feedback provided:**
```bash
printf '%s\tspokesman    \treview-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "<feedback>"
notecove task change <slug> --state Doing
echo "<slug>|kill-pr-monitor" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
echo "<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

**If 'abort':**
```bash
printf '%s\tspokesman    \treview-aborted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state "Won't Do"
echo "<slug>|kill-pr-monitor" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
echo "<slug>|abort" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
```

---

### Event: `event:ideas-ready` — brainstormer ideation

```
── Brainstormer: Ideas Ready ────────────────────
Task: <slug> — <title>
The brainstormer has generated a new ideas note.
Open NoteCove to review the IDEAS note and respond with:
  - Feedback or a request for more/different ideas
  - 'select' — when you are satisfied and ready to pick ideas to create as tasks
─────────────────────────────────────────────────
```

Wait for the user to respond. Write response as ANSWER note or task comment, set Doing, and resume:
```bash
printf '%s\tspokesman    \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Spokesman" "<user-response>"
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

---

### Event: `event:selection-ready` — brainstormer selection

```
── Brainstormer: Select Ideas ───────────────────
Task: <slug> — <title>
The brainstormer has prepared a SELECTION note with all ideas.
Open NoteCove to check the ideas you want to create as tasks and adjust dependencies.
When done, say 'continue'.
─────────────────────────────────────────────────
```

Wait for the user to say 'continue', then:
```bash
printf '%s\tspokesman    \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Doing
CMD_SEQ=$((CMD_SEQ + 1))
echo "${CMD_SEQ}|<slug>|resume" >> ~/agentmesh/signals/orchestrator-cmds
tmux wait-for -S orchestrator-cmd-event
while true; do
  tmux wait-for "spokesman-ack-${CMD_SEQ}" 2>/dev/null || true
  grep -q "^${CMD_SEQ}|" "$SPOKESMAN_ACKS" 2>/dev/null && break
done
```

---

### Event: `event:anomaly-detected:*` — orchestrator anomaly alert

Auto-acknowledge — no user input required (unless the user wants to investigate).

Extract the anomaly description: `anomaly=${event_rest#event:anomaly-detected:}`

```bash
printf '%s\tspokesman    \tanomaly-detected\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

Display a warning to the user:

```
⚠ Orchestrator anomaly detected
Anomaly: <anomaly>
The orchestrator has logged this to events.log.
No action required unless you want to investigate.
```

Continue draining the queue without waiting for user input.

---

### Unknown event

```bash
printf '%s\tspokesman    \tunknown-event\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

Tell the user: "Warning: Unrecognized event `<event_rest>` for task `<slug> — <title>`. Please inspect in NoteCove and say 'resume', 'approve', or 'abort' as appropriate."

Wait for user response and act accordingly.

---

### 1d. Loop back

After draining the queue, go back to Step 1a. All in-memory state (`MODE`, `TRIAGE_FOLDER`, `LOG`) is re-read from files at the top of 1a on each iteration — the Spokesman relies on no bash variables that persist across wakeup cycles.

---

## Exit

When no workers remain and no Ready tasks exist (orchestrator.py shuts down):

```bash
printf '%s\tspokesman    \tshutdown\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
# Kill any remaining reviewer windows (not tracked in signals/workers)
tmux list-windows -t workers -F "#{window_name}" 2>/dev/null | grep -E '^(plan-rev-|pr-rev-)' | while read win; do
  tmux kill-window -t "workers:$win" 2>/dev/null || true
done
# Kill the orchestrator.py window
tmux kill-window -t orchestrator:orchestrator 2>/dev/null || true
tmux kill-window -t orchestrator:dispatcher 2>/dev/null || true
tmux kill-window -t orchestrator:watchdog 2>/dev/null || true
tmux kill-window -t orchestrator:folder-cleanup 2>/dev/null || true
# Kill any remaining pr-monitor windows
tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null | grep "^pr-mon-" | while read _win; do
  tmux kill-window -t "orchestrator:${_win}" 2>/dev/null || true
done
rm -f ~/agentmesh/signals/queue ~/agentmesh/signals/workers
rm -f ~/agentmesh/signals/spokesman-queue ~/agentmesh/signals/orchestrator-cmds
rm -f "$SPOKESMAN_ACKS"
rm -f ~/agentmesh/signals/*.merged
rm -f ~/agentmesh/signals/*.reviewed
rm -f ~/agentmesh/signals/*.review-start
rm -f ~/agentmesh/signals/triage_folder
rm -f ~/agentmesh/signals/mode
```

Tell the user: "All tasks complete. Spokesman shutting down."

---

## Global Principles

- **The spokesman never spawns workers directly** — all spawning is delegated to orchestrator.py via `orchestrator-cmds`.
- **The spokesman always sets NoteCove state BEFORE sending commands** — state must be set before the resume signal fires (invariant from Critical Rules).
- **Queue-as-source-of-truth** — the spokesman-queue entry carries the full event type; no NoteCove comment parsing for routing.
- **Always drain the full spokesman-queue** before going back to wait.
- **Always write NoteCove state changes BEFORE sending the command to orchestrator.py** — orchestrator.py fires the tmux signal immediately; if state hasn't been updated yet, the worker reads wrong state.
- **Always wait for ACK after every command** — use the `CMD_SEQ` counter pattern for every command send. The ACK loop confirms orchestrator.py executed the command (e.g., the spawn actually happened) before the Spokesman moves on.
- **The spokesman is the only human-facing layer** — it never does any work autonomously beyond routing and display.
- **Zero in-memory state across wakeup cycles** — `MODE`, `TRIAGE_FOLDER`, and `LOG` are re-read from `signals/mode`, `signals/triage_folder`, and a fixed path at the top of every wakeup cycle. No bash variable set in one cycle is relied upon in the next. This makes the Spokesman fully restartable: a new session picks up from NoteCove state with no data loss.
