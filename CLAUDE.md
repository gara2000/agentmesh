# AgentMesh — Agentic Workflow

AgentMesh is a synchronous multi-agent orchestration system built on tmux and NoteCove. It picks up tasks from NoteCove, assigns them to autonomous worker agents, and routes any user interaction through a single orchestrator — the user never interacts with workers directly.

---

## How It Works

### Coordination Primitives

All coordination is synchronous — no polling, no idle token consumption.

- **`tmux wait-for -S <signal>`** — fires a named signal (non-blocking)
- **`tmux wait-for <signal>`** — blocks until the signal is fired
- **`signals/queue`** — append-only file; workers write their task slug before signaling, orchestrator drains it after unblocking
- **`scripts/dispatcher.sh`** — relay process running in a background tmux pane; listens on `worker-any-event` and forwards to `orchestrator-event`, enabling fan-in from multiple workers

### Signal Protocol

| Signal | Direction | Trigger |
|---|---|---|
| `worker-any-event` | Worker → Dispatcher | Worker needs to notify orchestrator |
| `orchestrator-event` | Dispatcher → Orchestrator | Relayed fan-in signal |
| `<task-slug>-event` | Worker → Orchestrator | (reserved, direct path if needed) |
| `<task-slug>-resume` | Orchestrator → Worker | Resume blocked worker |

Task slugs (e.g. `WORK-pm4`) are used as signal names — globally unique, safe for tmux (alphanumeric + hyphens).

### Task State as Event Type

The orchestrator does not use separate status files. After unblocking, it reads the NoteCove task state directly to determine what happened:

| NoteCove Task State | Meaning |
|---|---|
| `Attention` | Worker has questions — needs user input |
| `In Review` | Worker believes work is complete — needs user approval |
| `Done` | Set by orchestrator after user approves — triggers worker exit |

---

## Roles

### Orchestrator

**One instance.** Runs in the `orchestrator` tmux session, window `main`. This is the only session the user attaches to.

Responsibilities:
- Initialize NoteCove for the project
- Bootstrap the `workers` tmux session and launch `dispatcher.sh`
- Pick up `Ready` tasks from NoteCove (up to `max-workers` in parallel)
- Spawn a worker per task
- Block on `orchestrator-event` and drain the queue after each unblock
- Handle `Attention` events: surface worker questions to the user, write answers to NoteCove, resume the worker
- Handle `In Review` events: surface completion summary to the user, wait for approval or feedback
  - Approved → mark task `Done`, resume worker (which exits), kill its window
  - Feedback → write feedback as an ANSWER note, set task back to `Doing`, resume worker to continue
- When all workers are done and no more Ready tasks exist: shut down dispatcher and exit

### Worker

**N instances (up to `max-workers`).** Each runs in the `workers` tmux session in a window named after its task slug (e.g. `workers:WORK-pm4`), spawned with `claude --dangerously-skip-permissions`.

Responsibilities:
- Pick up the assigned task from NoteCove (no `notecove init` — inherited from orchestrator)
- Explore task context, linked notes, and the codebase
- Ask questions via `QUESTIONS-<N>` notes, signal `Attention`, block on resume
- Create an implementation plan via `PLAN` note, signal `Attention` for review, block on resume
- Implement the plan (TDD where applicable), create a PR
- Signal `In Review` when complete — block on resume
- Exit only after receiving the orchestrator's resume signal (which means the user approved)
- Never interact with the user directly
- Never mark its own task `Done`

### Dispatcher

**One instance.** Runs in the `orchestrator` session, window `dispatcher`. Pure bash, no Claude.

Responsibilities:
- Loop on `tmux wait-for worker-any-event`
- Forward each event to the orchestrator via `tmux wait-for -S orchestrator-event`
- Enables fan-in: multiple workers can signal concurrently without the orchestrator missing events

### Watchdog

**One instance.** Runs in the `orchestrator` session, window `watchdog`. Pure bash, no Claude.

Responsibilities:
- Poll the worker registry (`signals/workers`) every 30 seconds
- For each registered worker, check if its tmux window still exists
- If a window is gone and the task state is still `doing` → crash detected: append slug to queue and fire `worker-any-event` to wake the orchestrator
- Remove the entry from the registry regardless (window gone = worker dead)
- If the task state is anything other than `doing` (e.g. `done`, `in-review`) → worker finished cleanly before being unregistered; no action

The orchestrator handles the crash case in its event loop: when it drains a slug whose task state is `doing`, it re-queues the task to `Ready` and spawns a new worker.

The worker registry (`signals/workers`) is a line-oriented file maintained by the orchestrator:
```
# format: <task-slug> <tmux-window-name>
WORK-pm4 WORK-pm4
WORK-xyz WORK-xyz
```

**Crash detection latency**: at most 60 seconds (two poll cycles).

---

## tmux Layout

```
Session: orchestrator       ← user attaches here only
  window 0: main            ← /orchestrator skill (Claude Code)
  window 1: dispatcher      ← scripts/dispatcher.sh (bash loop)
  window 2: watchdog        ← scripts/watchdog.sh (bash loop)

Session: workers
  window 0: WORK-pm4        ← /worker skill (Claude Code, yolo mode)
  window 1: WORK-xyz        ← /worker skill (Claude Code, yolo mode)
  ...
```

---

## Skills

Skills live in the `agentic-workflows` plugin in the personal Claude marketplace. Agents can read and improve them directly.

| Skill | Invoked by | Source |
|---|---|---|
| `/orchestrator` | User (manually) | `~/personal/claude-marketplace/plugins/agentic-workflows/skills/orchestrator/SKILL.md` |
| `/worker` | Orchestrator (via `tmux send-keys`) | `~/personal/claude-marketplace/plugins/agentic-workflows/skills/worker/SKILL.md` |

After editing a skill, bump the version in `.claude-plugin/plugin.json`, commit, push, then run:

```bash
cd ~/.claude/plugins/marketplaces/personal-claude-marketplace && git pull
claude plugin update agentic-workflows@personal-claude-marketplace
```

---

## Project Structure

```
agentmesh/
├── CLAUDE.md               # this file
├── scripts/
│   ├── dispatcher.sh       # fan-in relay (worker-any-event → orchestrator-event)
│   └── watchdog.sh         # crash detector; re-queues tasks whose worker windows disappeared
└── signals/                # runtime directory, created on orchestrator bootstrap
    ├── queue               # append-only; worker slugs written here before signaling
    └── workers             # worker registry; line per active worker: "<slug> <window-name>"
```

The `signals/` directory and its contents are runtime artifacts — created fresh each time the orchestrator bootstraps.

---

## Starting the Orchestrator

```bash
cd ~/agentmesh
tmux new-session -s orchestrator
claude
/orchestrator --project WORK
```

The orchestrator handles everything from there.
