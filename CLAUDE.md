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
| `Attention` | Worker/planner needs user input — questions, plan ready, or PR ready |
| `In Review` | A reviewer agent is currently running (set by orchestrator only) |
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
- Handle `Attention` events: determine the event type (questions, plan ready, PR ready, or post-review), surface to the user, resume the worker
  - Questions → write user answers to NoteCove, resume worker
  - Plan ready → user approves/rejects or requests plan reviewer (sets `In Review`, spawns plan-reviewer)
  - PR ready → user approves/rejects/provides feedback or requests PR reviewer (sets `In Review`, spawns pr-reviewer)
  - Post-review (standard mode) → present review findings, await user decision; (auto-review mode) → pass review to worker automatically, resume worker
  - Planner completion → auto-ack, set Done, clean up
- When all workers are done and no more Ready tasks exist: shut down dispatcher and exit

### Worker

**N instances (up to `max-workers`).** Each runs in the `workers` tmux session in a window named after its task slug (e.g. `workers:WORK-pm4`), spawned with `claude --dangerously-skip-permissions`.

Responsibilities:
- Pick up the assigned task from NoteCove (no `notecove init` — inherited from orchestrator)
- Explore task context, linked notes, and the codebase
- Ask questions via `QUESTIONS-<N>` notes, signal `Attention`, block on resume
- Create an implementation plan via `PLAN` note, signal `Attention` for review, block on resume
- Implement the plan (TDD where applicable), create a PR
- Signal `Attention` when PR is ready — block on resume (approved → exit, feedback → continue)
- Exit only after receiving the orchestrator's resume signal (which means the user approved)
- Never interact with the user directly
- Never mark its own task `Done`

### Dispatcher

**One instance.** Runs in the `orchestrator` session, window `dispatcher`. Pure bash, no Claude.

Responsibilities:
- Loop on `tmux wait-for worker-any-event`
- Forward each event to the orchestrator via `tmux wait-for -S orchestrator-event`
- Enables fan-in: multiple workers can signal concurrently without the orchestrator missing events

### PR Monitor

**One instance per active PR-ready task.** Runs in the `orchestrator` session, window `pr-mon-<slug>`. Pure bash, no Claude. Spawned by the orchestrator when a worker signals PR-ready.

Responsibilities:
- Poll `gh pr view <pr-url>` every 60 seconds
- When the PR state is `MERGED`: write a `signals/<slug>.merged` flag file, append slug to the queue, fire `worker-any-event`, and exit
- The orchestrator checks the merged flag at the start of each PR-ready Attention event and auto-approves if set

The pr-monitor window is killed by the orchestrator in all PR resolution paths (approve, feedback, abort) and at shutdown.

**Known limitation**: if the PR merges while the orchestrator is actively presenting the PR-ready prompt to the user, the auto-approval does not interrupt that interaction. The merged flag will be picked up on the next event loop cycle.

### Watchdog

**One instance.** Runs in the `orchestrator` session, window `watchdog`. Pure bash, no Claude.

Responsibilities:
- Poll the worker registry (`signals/workers`) every 30 seconds
- For each registered worker, check if its tmux window still exists
- If a window is gone and the task state is still `doing` → crash detected: append slug to queue and fire `worker-any-event` to wake the orchestrator
- Remove the entry from the registry regardless (window gone = worker dead)
- If the task state is anything other than `doing` (e.g. `done`, `attention`) → worker finished cleanly before being unregistered; no action

The orchestrator handles the crash case in its event loop: when it drains a slug whose task state is `doing`, it re-queues the task to `Ready` and spawns a new worker.

The worker registry (`signals/workers`) is a line-oriented file maintained by the orchestrator:
```
# format: <task-slug> <tmux-window-name>
WORK-pm4 WORK-pm4
WORK-xyz WORK-xyz
```

**Crash detection latency**: at most 60 seconds (two poll cycles).

### Folder Cleanup

**One instance.** Runs in the `orchestrator` session, window `folder-cleanup`. Pure bash, no Claude.

Responsibilities:
- Poll every 60 seconds for tasks in any terminal state (Done, Won't Do)
- For each such task, move its named subfolder from the task's parent folder into the adjacent `Done` folder
- Skip folders already under a `Done` folder (idempotent)
- Handles all terminal states automatically — the orchestrator no longer needs to call a `move_task_folder_to_done` helper inline

The folder-cleanup window is killed by the orchestrator at shutdown.

---

## tmux Layout

```
Session: orchestrator       ← user attaches here only
  window 0: main            ← /orchestrator skill (Claude Code)
  window 1: dispatcher      ← scripts/dispatcher.sh (bash loop)
  window 2: watchdog        ← scripts/watchdog.sh (bash loop)
  window 3: folder-cleanup  ← scripts/folder-cleanup.sh (bash loop)
  window N: pr-mon-WORK-xyz ← scripts/pr-monitor.sh (bash loop, one per PR-ready task)

Session: workers
  window 0: WORK-pm4         ← /worker skill (Claude Code, yolo mode)
  window 1: WORK-xyz         ← /worker skill (Claude Code, yolo mode)
  window N: plan-rev-WORK-xyz ← /plan-reviewer skill (Claude Code, one per plan under review)
  window N: pr-rev-WORK-xyz   ← /pr-reviewer skill (Claude Code, one per PR under review)
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
│   ├── bootstrap.sh        # orchestrator startup: notecove init, signals dir, dispatcher + watchdog + folder-cleanup
│   ├── dispatcher.sh       # fan-in relay (worker-any-event → orchestrator-event)
│   ├── watchdog.sh         # crash detector; re-queues tasks whose worker windows disappeared
│   ├── folder-cleanup.sh   # async folder housekeeping; moves Done/Won't-Do task subfolders to the Done folder
│   └── pr-monitor.sh       # PR merge detector; auto-approves merged PRs
└── signals/                # runtime directory, created on orchestrator bootstrap
    ├── queue               # append-only; worker slugs written here before signaling
    ├── workers             # worker registry; line per active worker: "<slug> <window-name>"
    ├── triage_folder       # Triage folder ID written by bootstrap.sh; read by orchestrator
    ├── <slug>.merged       # flag file written by pr-monitor when PR is merged
    ├── <slug>.reviewed     # flag file written by orchestrator after passing pr-review to worker (auto-review mode); cleared on PR resolution
    └── events.log          # append-only TSV: timestamp, component, event_type, slug
```

The `signals/` directory and its contents are runtime artifacts — created fresh each time the orchestrator bootstraps.

### Event log format

`events.log` is a tab-separated file with four fields per line:

```
timestamp       component       event_type                  slug
2026-04-26T...  dispatcher      worker-any-event-received   -
2026-04-26T...  dispatcher      orchestrator-event-fired    -
2026-04-26T...  watchdog        crash-detected              WORK-xyz
2026-04-26T...  watchdog        worker-exited-clean         WORK-xyz
2026-04-26T...  orchestrator    bootstrap-complete          -
2026-04-26T...  orchestrator    task-picked-up              WORK-xyz
2026-04-26T...  orchestrator    worker-spawned              WORK-xyz
2026-04-26T...  orchestrator    event-received:attention    WORK-xyz
2026-04-26T...  orchestrator    attention-resumed           WORK-xyz
2026-04-26T...  orchestrator    review-approved             WORK-xyz
2026-04-26T...  orchestrator    review-feedback             WORK-xyz
2026-04-26T...  orchestrator    plan-reviewer-spawned       WORK-xyz
2026-04-26T...  orchestrator    reviewer-spawning           WORK-xyz
2026-04-26T...  orchestrator    reviewer-spawned            WORK-xyz
2026-04-26T...  orchestrator    worker-crash-requeued       WORK-xyz
2026-04-26T...  orchestrator    pr-monitor-spawned          WORK-xyz
2026-04-26T...  orchestrator    pr-auto-approved            WORK-xyz
2026-04-26T...  orchestrator    pr-review-passed-to-worker  WORK-xyz
2026-04-26T...  orchestrator    shutdown                    -
2026-04-26T...  folder-cleanup  folder-moved                WORK-xyz
2026-04-26T...  pr-monitor      started                     WORK-xyz
2026-04-26T...  pr-monitor      pr-merged-detected          WORK-xyz
2026-04-26T...  plan-reviewer   plan-review-started         WORK-xyz
2026-04-26T...  plan-reviewer   error-no-plan               WORK-xyz
2026-04-26T...  plan-reviewer   plan-review-complete        WORK-xyz
2026-04-26T...  pr-reviewer     pr-review-started           WORK-xyz
2026-04-26T...  pr-reviewer     pr-review-complete          WORK-xyz
2026-04-26T...  worker          started                     WORK-xyz
2026-04-26T...  worker          signaling-attention         WORK-xyz
2026-04-26T...  worker          resumed                     WORK-xyz
2026-04-26T...  worker          signaling-plan              WORK-xyz
2026-04-26T...  worker          resumed-from-plan           WORK-xyz
2026-04-26T...  worker          implementing                WORK-xyz
2026-04-26T...  worker          pr-created                  WORK-xyz
2026-04-26T...  worker          signaling-attention-pr-ready WORK-xyz
2026-04-26T...  worker          approved                    WORK-xyz
2026-04-26T...  worker          feedback-received           WORK-xyz
```

---

## Proactive Issue Reporting

Workers are expected to file triage tasks for anything noteworthy they observe during their work — bugs, inconsistencies, missing tests, documentation gaps, security concerns — **even if unrelated to their assigned task**.

All triage tasks go into the **Triage** folder at the root of the NoteCove storage directory. Workers resolve the folder ID dynamically at startup:

```bash
TRIAGE_FOLDER=$(notecove folder list --json | python3 -c "import sys,json; folders=json.load(sys.stdin); print(next(f['id'] for f in folders if f['name']=='Triage' and f['parentId'] is None))")
```

Then create triage tasks using `${TRIAGE_FOLDER}`:

```bash
notecove task create "<title>" \
  --folder ${TRIAGE_FOLDER} \
  --project WORK \
  --content-file - --content-format markdown --json
```

An automated triage process will eventually process these tasks. Workers should file them immediately rather than batching.

---

## Starting the Orchestrator

```bash
cd ~/agentmesh
tmux new-session -s orchestrator
claude
/orchestrator --project WORK
```

The orchestrator handles everything from there.

### Running Modes

Pass `--mode <mode>` to choose how the orchestrator handles plan and PR reviews:

| Mode | Behavior |
|---|---|
| `standard` (default) | User manually reviews plans and PRs; reviewers spawn only on explicit user request |
| `auto-review` | Plan-reviewers and PR-reviewers spawn automatically; review is passed back to workers automatically; user only approves the final PR |

**`auto-review` mode flow:**
1. When a plan is ready → plan-reviewer spawns automatically, review passed back to worker (no user prompt)
2. When a PR is ready → pr-reviewer spawns automatically, review passed back to worker (no user prompt); worker applies fixes and re-signals when ready
3. After worker re-signals PR-ready (post-review) → user sees the final PR and approves or gives feedback
4. Worker questions → user is always asked (no automation for Q&A)

Example:
```bash
/orchestrator --project WORK --mode auto-review
```
