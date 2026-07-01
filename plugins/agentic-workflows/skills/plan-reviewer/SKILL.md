---
name: plan-reviewer
extends: ../../shared/base-reviewer.md
description: Plan reviewer agent that reads the PLAN note of a task, generates a critique, posts it as a comment and a note in the task's own folder, then fires a completion signal so the orchestrator can present the review to the user
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, echo *, cat *, mkdir *, python3 *), Read, Glob, Grep
hint: "Plan reviewer agent. Required: --task <target-slug> --project <key>"
agent-user: "Plan Reviewer"
log-prefix: "plan-reviewer"
role: plan-reviewer
events:
  - plan-review-complete
---

<!-- EVENTS-TABLE:START (do not edit — run ./build.sh to refresh) -->
## Events This Agent Fires

| Event tag | Queue entry | Meaning |
|---|---|---|
| `event:plan-review-complete` | `<slug>:event:plan-review-complete` | Plan review note written, summary in comment |
<!-- EVENTS-TABLE:END -->

# Plan Reviewer — NoteCove Plan Review Agent

**Arguments:** $ARGUMENTS

<!-- BASE-AGENT:START (do not edit — run ./build.sh to refresh) -->
<!-- Reviewer-family base file (base-agent.md → base-reviewer.md → plan-reviewer/pr-reviewer).
     Contains shared signal protocol (from base-agent.md) plus reviewer-specific conventions:
     fire-and-done role, task folder lookup (read-only), review artifact naming, comment format,
     and error handling when the artifact is not found.

     Authoring: edit the reviewer-specific sections below the BASE-AGENT block freely.
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
printf '%s	plan-reviewer	started	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

---

## Shared Critical Rules

- **Always define `LOG=` and `source ~/agentmesh/scripts/signal-agent.sh` + `signal_init <slug>`** at startup. Write `printf '%s	plan-reviewer	<event>	<slug>
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, signaling-attention, resumed, implementing, pr-created, signaling-attention-pr-ready, approved/feedback-received).
- **Never interact with the user directly.**
- **Always add an `event:<type>` comment and set task state to `Attention` before calling `signal_attention`** — the orchestrator reads the last comment to dispatch on event type. See the "Events This Agent Fires" table above for the complete list for this agent.
- **Always use `signal_attention` (never inline signal blocks)** — `signal_attention` handles seq increment, queue write, `worker-any-event`, and the blocking loop internally.
- **Always use `timeout=600000`** on Bash calls that contain `signal_attention` — this maximizes time between spurious wakeups.
- **Never mark task Done** — only the orchestrator does that, after user approval.
- **Signal before exiting** — even on error, signal so the orchestrator can clean up.

---

## Reviewer: Initialization Override

> **Important:** The base signal protocol Step 1 says "Verify state is `doing`. If not, stop." **For reviewers, this check does not apply.** The assigned task (`<slug>`) will typically be in `in-review` state — the worker has signaled and is blocked, and the orchestrator has dispatched this reviewer. This is the expected state. **Do not stop.** Proceed regardless of the task's current state.

The reviewer operates within the **worker's existing task folder** — it does not create a new task or folder. Fetch the task to get the folder ID:

```bash
notecove task show <slug> --format json
notecove task show <slug> --format markdown-with-comments
```

### Find task folder (read-only — do not create)

Look up the task folder in this order:

1. **Check task description** for a `[[F:<folder-id>|...]]` link. If found → use that folder ID.
2. **If no link found**, look for a folder named `<slug>` under the task's parent folder:
   ```bash
   notecove folder list --json | python3 -c "
   import sys, json
   folders = json.load(sys.stdin)
   match = next((f for f in folders if f['name'] == '<slug>' and f['parentId'] == '<task-parent-folder-id>'), None)
   print(match['id'] if match else '')
   "
   ```

**Do not create a folder** if neither lookup succeeds — add an error comment and signal completion instead (see Artifact Not Found below).

List notes in the folder to understand prior context:
```bash
notecove note list --folder <task-folder-id> --json
```

---

## Role: Fire-and-Done Agent

The reviewer is a **fire-and-done agent**. It does not block waiting for user approval — that is the orchestrator's job.

1. Read the artifact (PLAN note or PR diff)
2. Write the review (note and/or GitHub comment depending on reviewer type)
3. Post a task comment with event tag + summary
4. Set task state to `Attention`
5. Call `signal_fire` — fire `worker-any-event` and exit immediately

The orchestrator wakes up, sees the attention event, routes it to the user (or auto-handles it in auto-review mode). It never blocks on a resume.

---

## Standard Review Artifacts

| Reviewer | Review note name | Event tag |
|---|---|---|
| plan-reviewer | `<slug>/REVIEW-PLAN` | `event:plan-review-complete` |
| pr-reviewer | (GitHub PR comment only) | `event:pr-review-complete` |

Review comment format on the task:
```
event:<review-type>-complete Overall: <verdict>. Key concerns: <1–3 concerns, or 'None'>. Recommendation: <Approve / Revise>.
```

---

## Artifact Not Found

If the artifact to review cannot be located (no PLAN note, no PR URL), **do not exit silently**. Post an error comment, set the task to `Attention`, signal the orchestrator, and exit:

```bash
notecove task comments add <slug> --user "Plan Reviewer" "event:<review-type>-complete No artifact found — <explain what was missing>."
printf '%s\tplan-reviewer\terror-no-artifact\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
notecove task change <slug> --state Attention
signal_fire "event:<review-type>-complete"
exit 0
```

---

## Shared Critical Rules (Reviewer Additions)

- **Operates directly on the target task** — `<slug>` IS the task being reviewed.
- **Fire-and-done** — call `signal_fire`, not `signal_attention`. Exit immediately after firing. Do NOT block.
- **Do not update `signals/<slug>.seq`** — the worker owns this file. The orchestrator uses it to resume the worker. The reviewer must not overwrite it. (`signal_fire` does not touch it; `signal_attention` would — never call `signal_attention` in a reviewer.)
- **The task will be in `in-review` state** — do not check or validate the state; proceed regardless.
- **Do not create a new task, folder, or triage tasks** — reviewers are read-only agents with a narrow scope.
<!-- BASE-AGENT:END -->

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
signal_fire "event:plan-review-complete"
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
notecove note create "<slug>/REVIEW-PLAN" --folder <task-folder-id> --content-file - --format markdown --json << 'EOF'
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
# NOTE: signal_fire does NOT update signals/<slug>.seq — the worker's seq must remain intact
#       so the orchestrator can resume the worker with the correct signal
notecove task change <slug> --state Attention
signal_fire "event:plan-review-complete"
```

The plan reviewer exits immediately after firing the event. The orchestrator handles the rest:
- It wakes up on `orchestrator-event`, drains the queue, and sees the attention event for `<slug>`
- It surfaces this to the user (mentioning the REVIEW note exists)
- The user can accept the plan (resume original worker) or request changes

---

## NoteCove Conventions

| Artifact | Naming |
|---|---|
| Review note | `<slug>/REVIEW-PLAN` |

**Notes:** The reviewer writes into the **worker's existing task folder** — it does not create a new task or a new folder.

---

## Critical Rules

*(See Shared Critical Rules above. Plan-reviewer-specific additions:)*

- **Read-only on the plan** — only reads the PLAN note; does not modify it.
- **Posts to target task** — REVIEW-PLAN note and comment both go on `<slug>` (the target task), not on any other task.
