# AgentMesh — Agentic Workflow

AgentMesh is a synchronous multi-agent orchestration system. It picks up tasks from NoteCove, assigns them to autonomous worker agents, and routes all user interaction through a single orchestrator. Workers are never talked to directly by the user.

---

## How the User Interacts

The user only ever interacts with the **orchestrator**. They:

1. Start the orchestrator manually (`/orchestrator --project WORK`).
2. Wait for the orchestrator to surface events — either a worker needing input (`Attention`) or a worker that believes work is done and wants approval (`In Review`).
3. Respond in-session: answer questions, give feedback, or approve the result.
4. The orchestrator relays everything to the worker and resumes it.

The user never opens a worker window, never types commands in a worker session, and never marks tasks Done.

---

## Orchestrator — Worker Relationship

### Task Pickup

The orchestrator polls NoteCove for `Ready` tasks and spawns one agent per task, up to a configurable `max-workers` limit. Each worker lives in its own tmux window inside the `workers` session.

### Signaling

All coordination is synchronous — no polling or idle token consumption.

| Signal | Direction | Meaning |
|---|---|---|
| `worker-any-event` | Worker → Dispatcher | Worker needs the orchestrator's attention |
| `orchestrator-event` | Dispatcher → Orchestrator | Relayed fan-in signal |
| `<slug>-resume-<seq>` | Orchestrator → Worker | Resume the blocked worker |

Workers write their task slug to `signals/queue` and fire `worker-any-event` before blocking. The orchestrator drains the queue after each wakeup, reads the task state in NoteCove, and acts accordingly.

### Task State as the Only Message

The orchestrator never reads worker notes — **task state is the only coordination channel**.

| NoteCove Task State | Meaning |
|---|---|
| `Doing` | Worker is actively working |
| `Attention` | Worker has questions or needs plan review |
| `In Review` | Worker believes work is done; PR is open |
| `Done` | Orchestrator confirmed user approval |

Workers always set state *before* firing a signal so the orchestrator sees the correct state the moment it unblocks.

### Resume Sequence

Each signal round uses a unique sequenced signal name (`<slug>-resume-<N>`). This guarantees a stale resume from round N-1 can never accidentally unblock round N.

---

## Worker Types

### Normal Worker

A **worker** is the standard agent type. It:
1. Reads the assigned task and explores the codebase.
2. Asks clarifying questions via `QUESTIONS-N` notes (signals `Attention`, blocks until answered).
3. Proposes an implementation plan via a `PLAN` note (signals `Attention` for review, blocks until approved).
4. Implements the task in an isolated git worktree branched from `origin/main`.
5. Opens a PR and signals `In Review`.
6. Waits for approval or feedback. If feedback is given, it continues iterating and re-signals `In Review`.

### Planner

A **planner** is spawned when a task is too large or complex for a single PR. It:
1. Analyzes the task and proposes a subtask breakdown in a `DECOMPOSITION` note (signals `Attention` for review).
2. Once the decomposition is approved, creates child tasks in NoteCove with proper dependency links.
3. Independent subtasks are created as `Ready`; blocked subtasks as `Blocked`.
4. After all children are created, marks the parent task `Done` and signals `In Review` to let the orchestrator acknowledge and clean up.

The orchestrator decides whether to spawn a worker or planner based on the task size heuristic (multiple independent components, distinct areas of the codebase, explicit decomposition language in the description).

---

## Dispatcher

The **dispatcher** is a simple bash loop (`scripts/dispatcher.sh`) that runs in a background tmux window:

```
while true; do
  tmux wait-for "worker-any-event"
  tmux wait-for -S "orchestrator-event"
done
```

It provides **fan-in**: multiple workers can fire `worker-any-event` concurrently without events being lost. The orchestrator only ever blocks on `orchestrator-event`, not `worker-any-event` directly. The dispatcher acts as the relay between them.

---

## Watchdog

The **watchdog** (`scripts/watchdog.sh`) runs in a background tmux window and polls every 30 seconds:

1. Reads the worker registry (`signals/workers`) — a list of `<slug> <window-name>` pairs.
2. For each registered worker, checks if its tmux window still exists.
3. If the window is gone and the task state is still `doing` → crash detected: appends the slug to the queue and fires `worker-any-event` to wake the orchestrator.
4. If the window is gone but the task state is `done` or `in-review` → worker finished cleanly; no action needed.
5. Removes the entry from the registry regardless.

The orchestrator handles crash events by re-queuing the task to `Ready` and spawning a fresh worker. **Crash detection latency is at most 60 seconds** (two poll cycles).

---

## Example End-to-End Workflow

```
User: /orchestrator --project WORK

Orchestrator fetches Ready tasks → finds WORK-42 "Add rate limiting to the API"
Orchestrator marks WORK-42 Doing, spawns worker in workers:WORK-42

Worker reads task, explores codebase
Worker creates QUESTIONS-1: "Should the limit be per-IP or per-user?"
Worker sets WORK-42 → Attention, signals, blocks

Dispatcher relays worker-any-event → orchestrator-event
Orchestrator wakes, reads state: Attention
Orchestrator tells user: "WORK-42 needs input — open NoteCove"
User reads QUESTIONS-1, writes ANSWER-1, says "continue"
Orchestrator sets WORK-42 → Doing, fires WORK-42-resume-1

Worker resumes, reads answer, creates PLAN note
Worker sets WORK-42 → Attention, signals, blocks

User reads PLAN in NoteCove, approves, says "continue"
Orchestrator sets WORK-42 → Doing, fires WORK-42-resume-2

Worker creates worktree, implements, writes tests
Worker opens PR #17
Worker creates COMPLETION note, sets WORK-42 → In Review, signals, blocks

Orchestrator tells user: "WORK-42 has a PR — review and approve or give feedback"
User reviews PR, says "approve"
Orchestrator sets WORK-42 → Done, fires WORK-42-resume-3
Orchestrator kills workers:WORK-42 window

Worker unblocks, confirms state=done, exits
```

---

## Why NoteCove?

### Tasks Are Lightweight

NoteCove tasks hold only the title, state, priority, and a brief description. Implementation details, questions, plans, and completion notes live in the task's dedicated folder as separate notes. This keeps tasks scannable and avoids bloating them with context the orchestrator doesn't need.

### Context Belongs to the Worker, Not the Orchestrator

The orchestrator reads task state only — it never reads notes. Notes are the worker's private scratchpad. This separation means the orchestrator stays simple and scalable regardless of how much detail workers accumulate in their folders.

### Single Workspace for Agents and Humans

The user and agents share the same NoteCove space. Questions appear as notes the user reads and answers naturally. Plans appear as notes the user reviews before the worker starts coding. There is no separate ticketing system, no external communication channel — everything happens in one place.

### Task State as a Coordination Primitive

NoteCove task states (`Doing`, `Attention`, `In Review`, `Done`) map directly onto the workflow's coordination protocol. Transitioning a task to a new state *is* the message — no extra status files, no JSON payloads, no side channels.

### Proactive Knowledge Capture

Workers file triage tasks for anything noteworthy they observe — bugs, doc gaps, security concerns — immediately into a shared Triage folder. These are visible to the user and to future agents without any extra tooling.

---

## How NoteCove Is Used

### Task States

| State | Who sets it | Meaning |
|---|---|---|
| `Ready` | User / Planner | Task is ready to be picked up |
| `Doing` | Orchestrator / Worker | Task is actively being worked |
| `Attention` | Worker / Planner | Worker needs user input or plan review |
| `In Review` | Worker / Planner | PR is open, awaiting approval |
| `Blocked` | Planner | Task is waiting on a dependency |
| `Done` | Orchestrator | Task is fully approved and complete |

### Priority

Standard P1–P4 scale. The orchestrator picks up the highest-priority `Ready` tasks first when deciding which to dispatch.

### Task Types

Tasks can optionally carry type labels (e.g. `bug`, `feature`, `chore`). Workers and the orchestrator use them for context but they do not affect dispatch order.

### Ready and Attention States

- **`Ready`** — the signal that a task is available for the orchestrator to pick up. Setting a task `Ready` is how the user queues work.
- **`Attention`** — the signal that a worker is blocked and needs human input. The orchestrator surfaces Attention events to the user and waits for them to respond before resuming the worker.

### Notes for Context Persistence

Each task gets a dedicated folder. Workers create notes there throughout their lifecycle:

| Note | Purpose |
|---|---|
| `QUESTIONS-N` | Questions for the user — round N |
| `ANSWER-N` | User's answers (written by user or orchestrator) |
| `PLAN` | Implementation plan proposed by the worker |
| `DECOMPOSITION` | Subtask breakdown proposed by the planner |
| `COMPLETION` | Summary of what was done + PR link |
| `DESCRIPTION` | Child task description (created by planner) |

Notes keep detailed context out of the task record itself. The task stays lightweight and easy to scan; only the worker needs to read the notes. If a worker crashes and is restarted, it reads existing notes to restore context from the prior session — no work is lost.
