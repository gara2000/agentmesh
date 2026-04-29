---
name: orchestrator
description: Orchestrates worker agents picking up Ready tasks from NoteCove, routing worker attention requests to the user, and managing worker lifecycles via tmux
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, mkdir *, cat *, echo *, rm *, bash *, sleep *, sed *, python3 *)
hint: "Run the NoteCove task orchestrator. Required: --project <key>. Optional: --profile <id>, --max-workers <n> (default 5), --mode <mode> (standard|auto-review, default standard)"
---

# Orchestrator — NoteCove Task Agent Orchestrator

**Arguments:** $ARGUMENTS

Parse arguments:
- `--project <key>` — required, NoteCove project key (e.g. `WORK`)
- `--profile <id>` — optional, defaults to `kmq9h71tepf95rac2b59xdbsq2`
- `--max-workers <n>` — optional, max concurrent workers, defaults to `5`
- `--mode <mode>` — optional, running mode, defaults to `standard`
  - `standard` — user reviews plans and PRs manually; reviewers are spawned on explicit user request
  - `auto-review` — plan-reviewers and pr-reviewers are spawned automatically; reviews are passed back to workers; user is only interrupted for questions and final PR approval

If `--project` is not provided, stop and ask the user.

---

## Paths (fixed)

```
AGENTMESH=~/agentmesh
QUEUE=$AGENTMESH/signals/queue
WORKERS=$AGENTMESH/signals/workers
DISPATCHER=$AGENTMESH/scripts/dispatcher.sh
WATCHDOG=$AGENTMESH/scripts/watchdog.sh
FOLDER_CLEANUP=$AGENTMESH/scripts/folder-cleanup.sh
LOG=$AGENTMESH/signals/events.log
```

---

## Phase 0: Bootstrap

```bash
bash ~/agentmesh/scripts/bootstrap.sh --project <PROJECT> --profile <profile>
LOG=~/agentmesh/signals/events.log
MODE=<mode>  # set from --mode argument, default "standard"
TRIAGE_FOLDER=$(cat ~/agentmesh/signals/triage_folder)
```

Announce to the user: "Orchestrator bootstrapped. Dispatcher and watchdog running."

---

## Phase 1: Task Pickup

Fetch up to `max-workers` Ready tasks:
```bash
notecove task list --state Ready --project <PROJECT> --limit <max-workers> --json
```

If no tasks found, tell the user and stop.

For each task (highest priority first — lowest `priority` number):
1. Announce: slug, title, priority
2. Mark Doing: `notecove task change <slug> --state Doing`
3. Log: `printf '%s\torchestrator \ttask-picked-up\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"`
4. Decide agent type (see below), then spawn it

### Deciding the agent type

Read the task title and description. There are three agent types: **brainstormer**, **planner**, and **worker**. Evaluate in this order:

**1. Spawn a brainstormer** if the task is open-ended ideation with no concrete implementation steps.

Heuristics for "needs brainstorming":
- The title/description contains keywords like "brainstorm", "ideate", "come up with ideas", "explore options", "think through", "ideas for", "options for", "what should we"
- The task has no clear acceptance criteria or deliverable — it is asking for creative exploration
- The task explicitly says to brainstorm or generate ideas

**2. Spawn a planner** if the task is a concrete implementation task that is too large for a single PR.

Heuristics for "needs planning":
- The description lists multiple independent components or features
- The title/description contains phrases like "multiple", "several", "and also", "as well as", "in addition", "various"
- The task clearly involves distinct areas of the codebase that would produce separate PRs
- The task explicitly says it needs to be split or decomposed

**3. Spawn a worker** for everything else — single-PR implementation tasks.

When in doubt between brainstormer and planner → use planner (brainstorming implies no known solution).
When in doubt between planner and worker → use worker (decomposition should only be used when clearly needed).

### Spawning a worker

```bash
bash ~/agentmesh/scripts/spawn-agent.sh workers <task-slug> /worker <task-slug> <PROJECT>
echo "<task-slug> <task-slug>" >> ~/agentmesh/signals/workers
printf '%s\torchestrator \tworker-spawned\t<task-slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

### Spawning a planner

```bash
bash ~/agentmesh/scripts/spawn-agent.sh workers <task-slug> /planner <task-slug> <PROJECT>
echo "<task-slug> <task-slug>" >> ~/agentmesh/signals/workers
printf '%s\torchestrator \tplanner-spawned\t<task-slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

### Spawning a brainstormer

```bash
bash ~/agentmesh/scripts/spawn-agent.sh workers <task-slug> /brainstormer <task-slug> <PROJECT>
echo "<task-slug> <task-slug>" >> ~/agentmesh/signals/workers
printf '%s\torchestrator \tbrainstormer-spawned\t<task-slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

### Spawning a plan reviewer

In `standard` mode, plan reviewers are only spawned when the user explicitly requests one during an Attention event. In `auto-review` mode, they are spawned automatically when a plan is ready (see Phase 2 event loop). The spawning logic lives in that section in both cases.

The plan reviewer operates directly on the target task — no separate coordination task is created. It posts a REVIEW note and a comment in the task's own folder, then re-triggers Attention via `worker-any-event`. The orchestrator returns to the event loop immediately after spawning; the reviewer's completion comes back as a normal Attention event.

After spawning all initial workers, enter the event loop.

---

## Labeled Block References

The following named operations are referenced throughout the event loop. Each delegates to `$AGENTMESH/scripts/task-done.sh`.

**Choosing the right call:**

- `«resume-and-close-worker»` — worker is blocked; fire resume signal, unblock dependents, clean up:
  ```bash
  bash $AGENTMESH/scripts/task-done.sh <slug> <PROJECT> ${resume_sig}
  ```
- `«close-worker»` — worker is already gone or not blocked (crash path, abort after external state change); unblock dependents, clean up without resume:
  ```bash
  bash $AGENTMESH/scripts/task-done.sh <slug> <PROJECT>
  ```

`task-done.sh` handles: optional resume signal → kill worker windows → unregister from `signals/workers` → remove seq file → unblock-dependents retry loop.

### «pr-terminal»

Used after a PR is approved or aborted. Kill the pr-monitor window, remove PR signal files, then call `task-done.sh` (which handles unblock-dependents and worker cleanup). Attempt to pick up the next Ready task.

```bash
tmux kill-window -t orchestrator:pr-mon-<slug> 2>/dev/null || true
rm -f ~/agentmesh/signals/<slug>.merged
rm -f ~/agentmesh/signals/<slug>.reviewed
bash $AGENTMESH/scripts/task-done.sh <slug> <PROJECT> ${resume_sig}
```

Attempt to pick up the next Ready task.

---

## Phase 2: Event Loop

### 2a. Wait for an event

```bash
tmux wait-for orchestrator-event
```

### 2b. Drain queue (loop until empty)

```bash
QUEUE=~/agentmesh/signals/queue

while [ -s "$QUEUE" ]; do
  slugs=$(cat "$QUEUE")
  : > "$QUEUE"

  for slug in $slugs; do
    # handle event for $slug (see 2c)
  done
done
```

After processing all slugs, check the queue again before going back to `tmux wait-for`.

### 2c. Handle event for a task slug

Read task state and the worker's current sequence number:
```bash
state=$(notecove task show <slug> --json | python3 -c "import sys,json; print(json.load(sys.stdin).get('stateId',''))")
seq=$(cat ~/agentmesh/signals/<slug>.seq 2>/dev/null || echo "0")
resume_sig="<slug>-resume-${seq}"
printf '%s\torchestrator \tevent-received:%s\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$state" >> "$LOG"
```

`resume_sig` is the exact signal the worker is blocking on — use it verbatim in all `tmux wait-for -S` calls below.

---

#### If state = `attention`

Determine what kind of attention event this is by parsing the `event:` tag from the last comment:

```bash
_comments_raw=$(notecove task show <slug> --format markdown-with-comments)

# Extract the last comment's body (first line of the last "^- Author: ..." entry)
_last_comment_body=$(echo "$_comments_raw" | grep "^- " | tail -1 | sed 's/^- [^:]*:[[:space:]]*//')

# Extract the event tag (format: event:<type>[:<data>])
_event_tag=$(echo "$_last_comment_body" | grep -oP 'event:\S+' | head -1)

# Extract reviewer summary (everything after the event tag prefix, for display)
_reviewer_summary=$(echo "$_last_comment_body" | sed 's/^event:[^ ]* //')

# Extract PR URL: scan all comments for the most recent event:pr-ready: entry
_pr_url=$(echo "$_comments_raw" | grep "^- " | grep -oP 'event:pr-ready:\S+' | tail -1 | sed 's/event:pr-ready://')
```

Dispatch on `_event_tag`:

```
case "$_event_tag" in
  event:pr-review-complete*)   → post-PR-review attention
  event:plan-review-complete*) → post-plan-review attention
  event:completion)            → brainstormer/planner completion
  event:selection-ready)       → brainstormer-selection
  event:ideas-ready)           → brainstormer-ideation
  event:pr-ready:*)            → PR-ready attention (_pr_url already extracted above)
  event:plan-ready)            → plan-ready attention
  event:questions)             → worker question
  *)                           → unexpected (log and tell user)
esac
```

Handle each case:

---

**`event:pr-review-complete` → post-PR-review attention:**

A pr-reviewer has finished reviewing the PR and set this task to Attention. The worker is blocked waiting for either `done` (approve) or `doing` (feedback).

**If `MODE=auto-review`:** automatically pass the review to the worker — do not prompt the user.

```bash
printf '%s\torchestrator \tpr-review-passed-to-worker\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "PR review complete (auto-review mode). Read the reviewer's comment and the GitHub PR comments. Apply any needed fixes and re-signal when ready."
notecove task change <slug> --state Doing
touch ~/agentmesh/signals/<slug>.reviewed
tmux wait-for -S ${resume_sig}
# Clean up the pr-reviewer window
tmux kill-window -t workers:pr-rev-<slug> 2>/dev/null || true
```

**Continue to the next slug in the queue drain loop.** The worker will re-signal when ready; the next PR-ready event will go directly to the user for final approval (`.reviewed` flag prevents another auto-review cycle).

**If `MODE=standard`:**

Tell the user:
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
  • 're-review' — spawn a new pr-reviewer (optionally share context first)
  • 'abort'     — mark the task Won't Do
─────────────────────────────────────────────────
```

Wait for the user to respond.

- **If 'approve':** handle exactly like the **PR approve** path below.
- **If feedback:** add feedback comment, set Doing, fire resume:
  ```bash
  notecove task comments add <slug> --user "Orchestrator" "<feedback>"
  notecove task change <slug> --state Doing
  printf '%s\torchestrator \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  tmux wait-for -S ${resume_sig}
  # Kill pr-monitor — a fresh one spawns when the worker re-signals PR-ready
  tmux kill-window -t orchestrator:pr-mon-<slug> 2>/dev/null || true
  rm -f ~/agentmesh/signals/<slug>.merged
  ```
- **If 're-review':** same as the PR-ready 'review' flow below (set `In Review`, spawn pr-reviewer, re-enter event loop).
- **If 'abort':** handle exactly like the **PR abort** path below.

---

**`event:completion` → brainstormer/planner completion:**

The agent has finished creating subtasks (or completed with no tasks) and marked the parent Done. Auto-acknowledge — no user interaction is needed.

```bash
printf '%s\torchestrator \tagent-completion-ack\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Done
```

```bash
bash $AGENTMESH/scripts/task-done.sh <slug> <PROJECT> ${resume_sig}
```

Announce to the user: "Agent task <slug> — <title> completed. Picking up next task."
Attempt to pick up the next Ready task.

---

**`event:selection-ready` → brainstormer-selection:**

The brainstormer has presented the selection note. Tell the user:
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
printf '%s\torchestrator \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
```

---

**`event:ideas-ready` → brainstormer-ideation:**

The brainstormer has produced a new round of ideas. Tell the user:
```
── Brainstormer: Ideas Ready ────────────────────
Task: <slug> — <title>
The brainstormer has generated a new ideas note.
Open NoteCove to review the IDEAS note and respond with:
  - Feedback or a request for more/different ideas
  - 'select' — when you are satisfied and ready to pick ideas to create as tasks
─────────────────────────────────────────────────
```

Wait for the user to respond, then write the response as an ANSWER note or add a comment, set Doing, and resume:
```bash
printf '%s\torchestrator \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "<user-response>"
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
```

---

**`event:pr-ready:*` → PR-ready attention:**

The worker has created a PR and is waiting for user action. `_pr_url` is extracted from the event tag (`${_event_tag#event:pr-ready:}`). This is the primary review-and-approve path.

**First, check if the PR was already merged** (flag set by pr-monitor, or the PR merged before the orchestrator processed this event):
```bash
if [ -f "~/agentmesh/signals/<slug>.merged" ]; then
  printf '%s\torchestrator \tpr-auto-approved\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  notecove task change <slug> --state Done
fi
```

If the merged flag was set: Announce: "PR for <slug> — <title> was merged automatically — approved." Run «pr-terminal». **Do not continue to the rest of this block.**

**If `MODE=auto-review`** and the merged flag was not set: check whether a review has already been done for this task.

```bash
_reviewed_flag="~/agentmesh/signals/<slug>.reviewed"
```

**If `_reviewed_flag` exists** (review was already passed back to the worker): remove the flag and fall through to **standard mode** below — the user gets the final approval opportunity now.

```bash
rm -f "$_reviewed_flag"
```

**If `_reviewed_flag` does NOT exist**: automatically spawn a pr-reviewer — do not prompt the user.

```bash
# auto-review mode: spawn pr-reviewer immediately
printf '%s\torchestrator \treviewer-spawning\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state "In Review"
bash ~/agentmesh/scripts/spawn-agent.sh workers pr-rev-<slug> /pr-reviewer <slug> <PROJECT>
printf '%s\torchestrator \treviewer-spawned\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

**Continue to the next slug in the current queue drain loop** (do NOT call `tmux wait-for orchestrator-event` — the reviewer signals asynchronously via the normal fan-in path when done). The review will come back as a post-PR-review Attention event and be passed to the worker automatically.

**If `MODE=standard`** and the merged flag was not set: spawn the pr-monitor and present options to the user:
```bash
printf '%s\torchestrator \tpr-monitor-spawned\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
tmux new-window -t orchestrator -n pr-mon-<slug> 2>/dev/null || true
tmux send-keys -t "orchestrator:pr-mon-<slug>" "bash ~/agentmesh/scripts/pr-monitor.sh <slug> <_pr_url>" Enter
```

Tell the user:
```
── PR Ready ─────────────────────────────────────
Task: <slug> — <title>
The worker believes the task is complete.
PR: <_pr_url>
Note: a background monitor is running — if the PR is merged, it will be auto-approved.
Options:
  • 'approve'  — accept the PR
  • 'review'   — spawn an AI reviewer to review the PR on your behalf
  • feedback   — provide feedback for the worker to act on
  • 'abort'    — mark the task Won't Do
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If 'review' requested:**

Set the task to `In Review` (reviewer in progress), then spawn a pr-reviewer. The reviewer will post its review as a GitHub PR comment and set the task back to `Attention`.

```bash
printf '%s\torchestrator \treviewer-spawning\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state "In Review"

# Spawn reviewer in its own temporary window
bash ~/agentmesh/scripts/spawn-agent.sh workers pr-rev-<slug> /pr-reviewer <slug> <PROJECT>
printf '%s\torchestrator \treviewer-spawned\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

Tell the user: "Reviewer spawned. It will signal when the review is complete — you will see it as an Attention event for this task."

**Continue to the next slug in the current queue drain loop** (do NOT call `tmux wait-for orchestrator-event` — the reviewer signals asynchronously via the normal `worker-any-event` → `orchestrator-event` path when done).

**If approved:** (**PR approve path** — also used by post-PR-review approval above)
```bash
printf '%s\torchestrator \treview-approved\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Done
```

Run «pr-terminal».

**If feedback provided:**
```bash
printf '%s\torchestrator \treview-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "<feedback>"
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
# Kill pr-monitor — a fresh one spawns when the worker re-signals PR-ready
tmux kill-window -t orchestrator:pr-mon-<slug> 2>/dev/null || true
rm -f ~/agentmesh/signals/<slug>.merged
```

**If aborted (user says 'abort' or 'won't do'):** (**PR abort path** — also used by post-PR-review abort above)
```bash
printf '%s\torchestrator \treview-aborted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state "Won't Do"
```

Run «pr-terminal».

---

**`event:plan-ready` → plan-ready:**

The worker has finished writing the PLAN note and is waiting for review/approval.

**If `MODE=auto-review`:** automatically spawn a plan-reviewer — do not prompt the user.

```bash
# auto-review mode: spawn plan-reviewer immediately
printf '%s\torchestrator \tplan-reviewer-spawned\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state "In Review"
bash ~/agentmesh/scripts/spawn-agent.sh workers plan-rev-<slug> /plan-reviewer <slug> <PROJECT>
# Continue to the next slug in the queue drain loop — do NOT call tmux wait-for orchestrator-event; reviewer fires worker-any-event when done
```

**If `MODE=standard`:** prompt the user.

```
── Attention needed ─────────────────────────────
Task: <slug> — <title>
The worker has a plan ready for review.
Open NoteCove to read the PLAN note, then say 'continue'.
(Or say 'spawn reviewer' to have a plan reviewer agent critique the plan first.)
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If user says 'continue' (standard mode):**
```bash
printf '%s\torchestrator \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
```

**If user says 'spawn reviewer' (standard mode):**

Set the task to `In Review` (reviewer in progress), then spawn the plan reviewer. It will post a comment, then re-trigger an Attention event. The orchestrator returns to the event loop immediately.

```bash
printf '%s\torchestrator \tplan-reviewer-spawned\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state "In Review"
bash ~/agentmesh/scripts/spawn-agent.sh workers plan-rev-<slug> /plan-reviewer <slug> <PROJECT>
# Continue to the next slug in the queue drain loop — do NOT call tmux wait-for orchestrator-event; reviewer fires worker-any-event when done
```

**If user provides feedback on the plan (standard mode — request plan revision):**
```bash
printf '%s\torchestrator \tattention-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "<feedback>"
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
```

---

**`event:questions` → worker question:**

The worker is asking questions and needs user input.

Both modes surface this to the user:
```
── Attention needed ─────────────────────────────
Task: <slug> — <title>
The worker is waiting for your input.
Open NoteCove to review and answer, then say 'continue'.
─────────────────────────────────────────────────
```

Wait for the user to respond.

**If user says 'continue':**
```bash
printf '%s\torchestrator \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
```

**If user provides feedback:**
```bash
printf '%s\torchestrator \tattention-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "<feedback>"
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
```

---

**`event:plan-review-complete` → post-plan-review:**

The plan-reviewer has completed and set this task to Attention. The worker is blocked waiting to be resumed.

**Note:** The orchestrator always resumes the worker regardless of the reviewer's verdict. The worker reads the last reviewer comment (brief summary in task comments) and the REVIEW note in its task folder (full plan review details) to understand what was said and decides how to proceed.

**If `MODE=auto-review`:** automatically resume the worker with a comment — do not prompt the user.

```bash
# auto-review mode: pass review to worker and resume immediately
printf '%s\torchestrator \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "Plan review complete (auto-review mode). Review the reviewer's comment and the REVIEW note in your task folder before implementing."
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
# Clean up the plan-reviewer window
tmux kill-window -t workers:plan-rev-<slug> 2>/dev/null || true
```

**If `MODE=standard`:** prompt the user.

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

**If user says 'continue' (standard mode):**
```bash
printf '%s\torchestrator \tattention-resumed\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "Plan accepted after review."
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
# Kill the plan-reviewer window now that the review is resolved
tmux kill-window -t workers:plan-rev-<slug> 2>/dev/null || true
```

**If user says 'reject review' (standard mode):**
```bash
printf '%s\torchestrator \treview-rejected\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "Plan review rejected by user. Continuing with original plan."
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
# Kill the plan-reviewer window now that the review is resolved
tmux kill-window -t workers:plan-rev-<slug> 2>/dev/null || true
```

**If user provides feedback (standard mode — request plan revision):**
```bash
printf '%s\torchestrator \tattention-feedback\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "<feedback>"
notecove task change <slug> --state Doing
tmux wait-for -S ${resume_sig}
# Kill the plan-reviewer window now that the review is resolved
tmux kill-window -t workers:plan-rev-<slug> 2>/dev/null || true
```

**`*` (unknown event tag or no tag) → unexpected attention:**

```bash
printf '%s\torchestrator \tunexpected-attention\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

Tell the user: "Warning: Attention event for <slug> — <title> has an unrecognized event tag: `<_event_tag>` (last comment: `<_last_comment_body>`). Please inspect the task in NoteCove and say 'resume', 'approve', or 'abort' as appropriate."

Wait for the user to respond and act accordingly. Continue to the next slug in the queue drain loop.

---

#### If state = `in-review` (safety fallback — should not occur)

`In Review` is now set exclusively by the orchestrator when it dispatches a reviewer agent. Workers and planners no longer set this state. If this event appears in the queue, it indicates a stale signal or unexpected state change.

```bash
printf '%s\torchestrator \tunexpected-in-review\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

Tell the user: "Warning: Unexpected `in-review` state for <slug> — <title>. This may be a stale signal from a previous session. Please inspect the task in NoteCove and say 'resume', 'approve', or 'abort' as appropriate."

Wait for the user to respond and act accordingly. Continue to the next slug in the current queue drain loop (do NOT call `tmux wait-for orchestrator-event`).

---

#### If state = `won't-do` (task aborted externally — e.g. via NoteCove directly)

```bash
printf '%s\torchestrator \ttask-wont-do\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
rm -f ~/agentmesh/signals/<slug>.reviewed
```

Tell the user: "Task <slug> — <title> was marked Won't Do. Cleaning up."

```bash
bash $AGENTMESH/scripts/task-done.sh <slug> <PROJECT>
```

Attempt to pick up the next Ready task.

---

#### If state = `doing` (worker crashed — detected by watchdog)

```bash
printf '%s\torchestrator \tworker-crash-requeued\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task comments add <slug> --user "Orchestrator" "Worker crashed — restarting automatically."
# Kill stale pr-monitor if running from a previous session
tmux kill-window -t orchestrator:pr-mon-<slug> 2>/dev/null || true
rm -f ~/agentmesh/signals/<slug>.merged
```

```bash
bash $AGENTMESH/scripts/task-done.sh <slug> <PROJECT>
```

```bash
# Spawn a fresh worker directly in the workers session
notecove task change <slug> --state Doing
bash ~/agentmesh/scripts/spawn-agent.sh workers <slug> /worker <slug> <PROJECT>
echo "<slug> <slug>" >> ~/agentmesh/signals/workers
```

---

#### Any other state

Log: "Unexpected state `<state>` for <slug>."

```bash
bash $AGENTMESH/scripts/task-done.sh <slug> <PROJECT>
```

---

### 2d. Loop back

Go back to Step 2a.

---

## Exit

When no workers remain and no Ready tasks exist:

```bash
printf '%s\torchestrator \tshutdown\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
# Kill any remaining reviewer windows (not tracked in signals/workers)
tmux list-windows -t workers -F "#{window_name}" 2>/dev/null | grep -E '^(plan-rev-|pr-rev-)' | while read win; do
  tmux kill-window -t "workers:$win" 2>/dev/null || true
done
tmux kill-window -t orchestrator:dispatcher 2>/dev/null || true
tmux kill-window -t orchestrator:watchdog 2>/dev/null || true
tmux kill-window -t orchestrator:folder-cleanup 2>/dev/null || true
# Kill any remaining pr-monitor windows
tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null | grep "^pr-mon-" | while read _win; do
  tmux kill-window -t "orchestrator:${_win}" 2>/dev/null || true
done
rm -f ~/agentmesh/signals/queue ~/agentmesh/signals/workers
rm -f ~/agentmesh/signals/*.merged
rm -f ~/agentmesh/signals/*.reviewed
rm -f ~/agentmesh/signals/triage_folder
```

Tell the user: "All tasks complete. Orchestrator shutting down."

---

## Global Principles

- **The orchestrator never reads or lists NoteCove notes** — it determines event type and surfaces review results exclusively from task comments.
- **The user is the one who reads and answers worker questions** — directly in NoteCove.
- **Task state is the only coordination channel** — `Attention`, `In Review`, `Doing`, `Done`.
- **`In Review` is ONLY set by the orchestrator** — it means a reviewer agent (plan-reviewer or pr-reviewer) is currently running. Workers and planners always use `Attention` to signal they need user attention, regardless of the phase (questions, plan ready, PR ready).
- **Always drain the full queue** before going back to wait.
- **Always set task state BEFORE firing the resume signal** — the worker reads state immediately after unblocking; if the signal fires before state is updated, the worker sees the old state and deadlocks or spins. This invariant must hold in every code path: attention handling, approval, and feedback.
- **`auto-review` mode does not eliminate all user interaction** — questions always require user input, and the user still approves the final PR. Only plan reviews and the first PR review cycle are automated. The `.reviewed` flag (`signals/<slug>.reviewed`) ensures the review is passed to the worker exactly once; on the next PR-ready signal the orchestrator presents the PR to the user directly.
- **In `auto-review` mode, reviewer verdict is not read by the orchestrator** — the worker is always resumed regardless of reviewer verdict (Approve / Needs revision). For plan reviews, the worker reads the reviewer comment (task comments) and the REVIEW note (full details) and decides how to proceed. For PR reviews, the worker reads the reviewer comment (task comments) and the GitHub PR comments (full review) and decides how to proceed.
- **Event tag dispatch** — every Attention signal must be preceded by an `event:<type>` comment. The orchestrator reads the last comment's body, extracts the `event:` tag, and dispatches on it. No string-content heuristics or commenter-name checks are used for routing. Supported tags: `event:questions`, `event:plan-ready`, `event:pr-ready:<url>`, `event:ideas-ready`, `event:selection-ready`, `event:completion`, `event:plan-review-complete`, `event:pr-review-complete`.
