# AgentMesh — Agentic Workflow

AgentMesh is a synchronous multi-agent orchestration system. It picks up tasks from NoteCove, assigns them to autonomous worker agents, and routes all user interaction through a single orchestrator. Workers are never talked to directly by the user.

---

## System Layout

```
Session: orchestrator          ← user attaches here only
  window 0: main               ← /orchestrator skill (Claude Code)
  window 1: dispatcher         ← scripts/dispatcher.sh (bash loop)
  window 2: watchdog           ← scripts/watchdog.sh (bash loop)
  window 3: folder-cleanup     ← scripts/folder-cleanup.sh (bash loop)
  window N: pr-mon-WORK-42     ← scripts/pr-monitor.sh (bash loop, one per PR-ready task)

Session: workers
  window 0: WORK-42            ← /worker skill (Claude Code, yolo mode)
  window 1: WORK-57            ← /worker skill (Claude Code, yolo mode)
  ...
```

---

## How the User Interacts

The user only ever interacts with the **orchestrator** — the single Claude Code session in the `orchestrator` tmux session.

```mermaid
flowchart LR
    User -->|talks to| Orchestrator
    Orchestrator -->|spawns & manages| Workers
    Workers -->|signal events| Orchestrator
    Orchestrator -->|surfaces questions & PRs| User
    User -->|answers & approvals| Orchestrator
    Workers -. never talk to .-> User
```

Workflow from the user's perspective:

1. Run `/orchestrator --project WORK` to start (add `--mode auto-review` to enable automatic reviewing).
2. The orchestrator picks up `Ready` tasks and dispatches agents automatically.
3. When a worker needs input or has a completed PR (both signaled as `Attention`), the orchestrator surfaces it.
4. The user responds in the orchestrator session — answering questions, approving or giving feedback.
5. The orchestrator relays everything to the worker and resumes it.

### Running Modes

The orchestrator supports two modes set via `--mode`:

| Mode | Plan reviews | PR reviews | User interrupted for |
|---|---|---|---|
| `standard` (default) | User decides: approve, spawn reviewer, or give feedback | User decides: approve, spawn reviewer, feedback, or abort | All Attention events |
| `auto-review` | Plan-reviewer spawns automatically; review passed to worker | PR-reviewer spawns automatically; review passed to worker; user approves final PR | Questions + final PR approval only |

In `auto-review` mode the reviewer verdict is not read by the orchestrator — the worker is always resumed regardless of verdict. For plan reviews, the worker reads the REVIEW note and decides how to proceed before implementing. For PR reviews, the reviewer posts its findings to the GitHub PR; the orchestrator passes the review back to the worker (sets task `Doing`), and the worker reads the PR comments, applies any fixes, and re-signals when ready. On the worker's next PR-ready signal, the orchestrator presents the PR to the user for final approval (no second auto-review). This keeps the orchestrator simple and avoids infinite review cycles.

---

## Orchestrator — Worker Relationship

### Task Pickup

```mermaid
flowchart TD
    A([NoteCove: Ready tasks]) --> B{Orchestrator picks up\nup to max-workers tasks}
    B --> C[Mark task Doing]
    C --> D{Worker type?}
    D -->|simple task| E[Spawn /worker]
    D -->|complex / multi-PR task| F[Spawn /planner]
    E & F --> G[Register in signals/workers]
    G --> H([Enter event loop])
```

### Signal Protocol

All coordination is synchronous — no polling or idle token consumption.

```mermaid
sequenceDiagram
    participant W as Worker
    participant D as Dispatcher
    participant O as Orchestrator
    participant NC as NoteCove

    W->>NC: Set task state (always Attention)
    W->>W: Increment SIGNAL_SEQ, write to signals/<slug>.seq
    W->>W: Append slug to signals/queue
    W->>D: tmux wait-for -S worker-any-event
    D->>O: tmux wait-for -S orchestrator-event
    O->>O: Drain queue, read slug
    O->>NC: Read task state
    Note over O: Handle event (see below)
    O->>NC: Update task state
    O->>W: tmux wait-for -S <slug>-resume-<seq>
    W->>W: Unblock, verify state, continue
```

**Fan-in via dispatcher**: multiple workers can fire `worker-any-event` concurrently without losing events. The dispatcher serialises them into `orchestrator-event` one at a time.

**Sequenced resume signals** (`<slug>-resume-<N>`): each round uses a unique name, so a stale signal from round N-1 can never accidentally unblock round N.

### Task State as the Only Message

The orchestrator never reads worker notes — **task state is the only coordination channel**.

```mermaid
stateDiagram-v2
    [*] --> Ready : User queues task
    Ready --> Doing : Orchestrator picks up
    Doing --> Attention : Worker needs input,\nplan ready, or PR ready
    Attention --> InReview : Orchestrator dispatches\nreviewer agent
    InReview --> Attention : Reviewer finishes
    Attention --> Doing : Orchestrator resumes\n(after user responds)
    Attention --> Done : User approves PR
    Done --> [*]
    Ready --> WontDo : User cancels task
    Doing --> WontDo : User cancels in-progress task
    WontDo --> [*]
```

---

## Worker Types

### Normal Worker

```mermaid
flowchart TD
    A([Start]) --> B[Read task & explore codebase]
    B --> C{Ambiguous?}
    C -->|Yes| D[Create QUESTIONS-N note\nSignal Attention\nBlock]
    D --> E[Read ANSWER-N note]
    E --> C
    C -->|No| F[Create PLAN note\nSignal Attention\nBlock]
    F --> G{Plan approved?}
    G -->|Feedback| F
    G -->|Approved| H[Create git worktree\nbranched from origin/main]
    H --> I[Implement + tests]
    I --> I2{Workflow files\nchanged?}
    I2 -->|Yes| I3[Update docs/agentic-workflow.md\n& NoteCove note]
    I3 --> J[Open PR]
    I2 -->|No| J
    J --> K["Create COMPLETION note<br/>Signal Attention PR ready<br/>Block"]
    K --> L{Outcome}
    L -->|Approved| M([Exit])
    L -->|Feedback| I
```

### Planner

Spawned when a task is too large for a single PR (multiple independent components, distinct areas, explicit decomposition language).

Like a normal worker, a planner can also ask the user questions before proposing a decomposition — it signals `Attention` with a `QUESTIONS-N` note and blocks until the orchestrator resumes it with answers.

```mermaid
flowchart TD
    A([Start]) --> B[Read task & explore codebase]
    B --> C{Ambiguous?}
    C -->|Yes| Q[Create QUESTIONS-N note\nSignal Attention\nBlock]
    Q --> R[Read ANSWER-N note]
    R --> C
    C -->|No| D[Create DECOMPOSITION note\nwith subtask breakdown\nSignal Attention\nBlock]
    D --> E{Decomposition approved?}
    E -->|Feedback| D
    E -->|Approved| F[Create child tasks in NoteCove\nIndependent → Ready\nBlocked → Blocked]
    F --> G[Establish blocking links between tasks]
    G --> H[Mark parent task Done]
    H --> I["Signal Attention completion<br/>Block"]
    I --> J([Exit after orchestrator ack])
```

---

## Bootstrap

`scripts/bootstrap.sh` is called once by the orchestrator at startup. It encapsulates all Phase 0 setup:

1. **NoteCove init** — connects to the project and notes database.
2. **Signals directory** — creates `signals/`, clears the queue, worker registry, and event log, and removes stale `.merged` and `.reviewed` flags.
3. **Triage folder** — resolves the Triage folder ID from NoteCove and writes it to `signals/triage_folder` so the orchestrator can reference it without a repeated lookup.
4. **Workers session** — creates the `workers` tmux session if it doesn't already exist.
5. **Dispatcher** — launches `scripts/dispatcher.sh` in `orchestrator:dispatcher`.
6. **Watchdog** — launches `scripts/watchdog.sh` in `orchestrator:watchdog`.
7. **Folder cleanup** — launches `scripts/folder-cleanup.sh` in `orchestrator:folder-cleanup`.

Usage:
```bash
bash /Users/firas.gara/agentmesh/scripts/bootstrap.sh --project WORK [--profile <id>]
```

---

## Dispatcher

The dispatcher is a minimal bash loop (`scripts/dispatcher.sh`) that provides **fan-in from many workers to the single orchestrator**:

```mermaid
flowchart LR
    W1[Worker 1] -- worker-any-event --> D
    W2[Worker 2] -- worker-any-event --> D
    W3[Worker N] -- worker-any-event --> D
    D[Dispatcher] -- orchestrator-event --> O[Orchestrator]
```

```bash
while true; do
  tmux wait-for "worker-any-event"
  tmux wait-for -S "orchestrator-event"
done
```

Without the dispatcher the orchestrator would need to know which signal to wait on. With it, the orchestrator always blocks on a single signal name, and the dispatcher serialises concurrent worker events.

---

## Watchdog

The watchdog (`scripts/watchdog.sh`) detects crashed workers and automatically recovers them.

```mermaid
sequenceDiagram
    participant WD as Watchdog (every 30s)
    participant NC as NoteCove
    participant Q as signals/queue
    participant O as Orchestrator

    loop every 30 seconds
        WD->>WD: Read signals/workers registry
        loop for each registered worker
            WD->>WD: Check if tmux window still exists
            alt window gone AND state = doing
                WD->>Q: Append slug
                WD->>O: tmux wait-for -S worker-any-event
                Note over O: Orchestrator re-queues task\nand spawns fresh worker
            else window gone AND state ≠ doing
                Note over WD: Worker finished cleanly — no action
            end
            WD->>WD: Remove entry from registry
        end
    end
```

**Crash detection latency**: at most 60 seconds (two poll cycles).

---

## Folder Cleanup

The folder cleanup daemon (`scripts/folder-cleanup.sh`) moves task subfolders for terminal tasks into the adjacent `Done` folder — asynchronously, without requiring the orchestrator to call a folder-move helper inline.

```mermaid
sequenceDiagram
    participant FC as Folder Cleanup (every 60s)
    participant NC as NoteCove

    loop every 60 seconds
        FC->>NC: task list --json (all tasks)
        FC->>NC: folder list --json (all folders)
        loop for each terminal task (Done / Won't Do)
            FC->>FC: Find task's named subfolder in parent folder
            alt subfolder exists AND not already in Done folder
                FC->>NC: folder move <subfolder-id> <done-folder-id>
            end
        end
    end
```

This replaces the inline `move_task_folder_to_done` helper that was previously called in each terminal path of the orchestrator skill, removing ~25 lines of repeated shell/Python from the skill.

**Idempotent**: the daemon checks whether the subfolder is already under a `Done` folder before attempting a move, so repeated poll cycles are safe.

---

## PR Monitor

The pr-monitor (`scripts/pr-monitor.sh`) polls a PR's state and triggers auto-approval when it is merged — removing the need for the user to manually approve.

```mermaid
sequenceDiagram
    participant W as Worker
    participant O as Orchestrator
    participant PM as PR Monitor
    participant GH as GitHub

    W->>O: Signal Attention (PR ready)
    O->>PM: Spawn pr-mon-WORK-42 window
    O->>O: Present PR options to user

    loop every 60 seconds
        PM->>GH: gh pr view --json state
        alt state = MERGED
            PM->>PM: Write signals/WORK-42.merged
            PM->>O: Append slug to queue, fire worker-any-event
            PM->>PM: Exit
        end
    end

    O->>O: Process event for WORK-42
    O->>O: Detect .merged flag
    O->>O: Auto-approve (set Done, clean up)
```

**Auto-approval latency**: up to 60 seconds after the PR is merged (one poll cycle).

**Known limitation**: if the PR merges while the user is actively reviewing the PR-ready prompt, the auto-approval is deferred to the next event loop iteration. In practice this is harmless — whichever action completes first wins.

---

## Agent Spawner

`scripts/spawn-agent.sh` is a helper that encapsulates the repeated four-line pattern for launching a Claude agent in a new tmux window:

```bash
bash /Users/firas.gara/agentmesh/scripts/spawn-agent.sh <session> <window-name> <skill> <task-slug> <project>
```

It runs `new-window`, starts Claude in yolo mode, waits 3 seconds for the shell to initialize, then sends the skill invocation. Used by the orchestrator to spawn workers, planners, brainstormers, plan-reviewers, and pr-reviewers.

---

## End-to-End Example Workflow

```mermaid
sequenceDiagram
    participant U as User
    participant O as Orchestrator
    participant NC as NoteCove
    participant W as Worker (WORK-42)

    U->>O: /orchestrator --project WORK
    O->>NC: Fetch Ready tasks
    NC-->>O: WORK-42 "Add rate limiting"
    O->>NC: Set WORK-42 → Doing
    O->>W: Spawn /worker --task WORK-42

    W->>W: Read task, explore codebase
    W->>NC: Create QUESTIONS-1 note
    W->>NC: Set WORK-42 → Attention
    W->>O: Signal (via dispatcher)
    W->>W: Block on WORK-42-resume-1

    O->>U: "WORK-42 needs input — open NoteCove"
    U->>NC: Read QUESTIONS-1, write ANSWER-1
    U->>O: "continue"
    O->>NC: Set WORK-42 → Doing
    O->>W: Fire WORK-42-resume-1

    W->>NC: Create PLAN note
    W->>NC: Set WORK-42 → Attention
    W->>O: Signal
    W->>W: Block on WORK-42-resume-2

    O->>U: "WORK-42 has a plan — review in NoteCove"
    U->>NC: Read PLAN, approve
    U->>O: "continue"
    O->>NC: Set WORK-42 → Doing
    O->>W: Fire WORK-42-resume-2

    W->>W: Create worktree, implement, write tests
    W->>W: Push branch, open PR #17
    W->>NC: Create COMPLETION note
    W->>NC: Set WORK-42 → Attention
    W->>O: Signal
    W->>W: Block on WORK-42-resume-3

    O->>O: Spawn pr-mon-WORK-42 window
    O->>U: "WORK-42 has a PR — review and approve"
    Note over O,U: PR #17 is merged on GitHub
    O->>O: pr-monitor detects merge, writes .merged flag
    O->>O: Detects .merged flag on next event, auto-approves
    O->>NC: Set WORK-42 → Done
    O->>W: Fire WORK-42-resume-3
    O->>O: Kill workers:WORK-42, pr-mon-WORK-42 windows

    Note over O: Check for newly unblocked tasks
    O->>NC: Fetch Blocked tasks in project
    loop for each blocked task
        O->>NC: Check if all remaining blockers are Done
        alt only blocker was WORK-42
            O->>NC: Set dependent task → Ready
        end
    end

    W->>W: Confirm state=done, exit
```

---

## Why NoteCove?

| Benefit | Detail |
|---|---|
| **Lightweight tasks** | Tasks hold only title, state, priority, and a brief description. Implementation details live in notes — tasks stay scannable. |
| **Context belongs to the worker** | The orchestrator reads task state only, never notes. Workers own their scratchpad. Orchestrator stays simple regardless of task complexity. |
| **Shared workspace** | User and agents operate in the same space. Questions, plans, and completion summaries are notes the user reads naturally — no external ticketing system. |
| **State as coordination primitive** | Task state transitions *are* the messages. No extra status files, no JSON payloads, no side channels. |
| **Crash resilience** | Workers restore context from existing notes on restart. No work is lost if a worker crashes. |
| **Proactive knowledge capture** | Workers file triage tasks for bugs, doc gaps, or concerns into a shared Triage folder — visible to user and future agents immediately. |

---

## How NoteCove Is Used

### Task States

```mermaid
flowchart LR
    Ready -->|Orchestrator picks up| Doing
    Doing -->|Worker blocks: question, plan ready, or PR ready| Attention
    Attention -->|Orchestrator dispatches reviewer| InReview[In Review]
    InReview -->|Reviewer finishes| Attention
    Attention -->|Orchestrator resumes worker| Doing
    Attention -->|User approves PR| Done
    Ready -->|Planner creates blocked child| Blocked
    Blocked -->|All blockers resolved| Ready
    Ready -->|User cancels| WontDo[Won't Do]
    Doing -->|User cancels| WontDo
```

| State | Who sets it | Meaning |
|---|---|---|
| `Ready` | User / Planner | Task is queued for pickup |
| `Doing` | Orchestrator / Worker | Task is actively being worked |
| `Attention` | Worker / Planner | Needs user attention — questions, plan ready, PR ready, or post-review |
| `In Review` | Orchestrator only | A reviewer agent is currently running |
| `Blocked` | Planner | Task is waiting on a dependency |
| `Done` | Orchestrator | Fully approved and complete |
| `Won't Do` | User | Task was cancelled — no work will be done |

### Priority

Standard **P1–P4** scale. The orchestrator dispatches the highest-priority `Ready` tasks first.

### Notes for Context Persistence

Each task gets a dedicated folder. Workers create notes there throughout their lifecycle:

```mermaid
flowchart TD
    TaskFolder["Task folder\n(e.g. WORK-42/)"]
    TaskFolder --> Q["QUESTIONS-N\nWorker's questions for the user"]
    TaskFolder --> A["ANSWER-N\nUser's answers"]
    TaskFolder --> P["PLAN\nImplementation plan"]
    TaskFolder --> D["DECOMPOSITION\nSubtask breakdown (planner only)"]
    TaskFolder --> C["COMPLETION\nSummary + PR link"]
    TaskFolder --> Desc["DESCRIPTION\nChild task context (planner only)"]
```

Notes keep detailed context out of the task record. If a worker crashes and is restarted, it reads existing notes to restore context — no work is lost.

### Answering Worker Questions

When a worker signals `Attention` with a `QUESTIONS-N` note, the user has two ways to answer:

- **Via the orchestrator session** — type the answer in-session; the orchestrator writes it to NoteCove and resumes the worker.
- **Inline in the QUESTIONS note** — edit the note directly in NoteCove, writing answers beneath each question. The worker reads the updated note after being resumed.

The inline approach keeps questions and answers together in one place, making the conversation easy to review later.
