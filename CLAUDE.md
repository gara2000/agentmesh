# AgentMesh — Agentic Workflow

AgentMesh is a synchronous multi-agent orchestration system built on tmux and NoteCove. It picks up tasks from NoteCove, assigns them to autonomous worker agents, and routes any user interaction through a single orchestrator — the user never interacts with workers directly.

---

## How It Works

### Coordination Primitives

All coordination is synchronous — no polling, no idle token consumption.

- **`tmux wait-for -S <signal>`** — fires a named signal (non-blocking)
- **`tmux wait-for <signal>`** — blocks until the signal is fired
- **`signals/queue`** — append-only file; workers write `<slug>:<event-type>` entries before signaling; orchestrator.py drains it after unblocking
- **`signals/spokesman-queue`** — append-only file; orchestrator.py writes forwarded user-attention events (`<slug>:<event-type>`); Spokesman drains it after unblocking
- **`signals/orchestrator-cmds`** — append-only file; Spokesman writes typed commands (`<cmd-seq>|<slug>|<cmd>[|<args>]`); orchestrator.py drains and executes, then writes an ACK to `spokesman-acks`
- **`signals/spokesman-acks`** — append-only file; orchestrator.py writes ACKs (`<cmd-seq>|<slug>|confirm|<cmd>`) after each command execution; Spokesman waits on the sequenced ACK signal before proceeding
- **`scripts/dispatcher.sh`** — relay process running in a background tmux pane; listens on `worker-any-event` and forwards to `orchestrator-event`, enabling fan-in from multiple workers

### Signal Protocol

| Signal | Direction | Trigger |
|---|---|---|
| `worker-any-event` | Worker → Dispatcher | Worker needs to notify orchestrator.py |
| `orchestrator-event` | Dispatcher → orchestrator.py | Relayed fan-in signal |
| `spokesman-event` | orchestrator.py → Spokesman | User-attention event forwarded to Spokesman |
| `orchestrator-cmd-event` | Spokesman → orchestrator.py | New command written to `orchestrator-cmds` |
| `spokesman-ack-<cmd-seq>` | orchestrator.py → Spokesman | ACK for command `<cmd-seq>` (sequenced) |
| `<task-slug>-resume-<seq>` | orchestrator.py → Worker | Resume blocked worker (sequenced) |

Task slugs (e.g. `WORK-pm4`) are used as signal names — globally unique, safe for tmux (alphanumeric + hyphens).

### Queue Format

Workers write `<slug>:<event-type>` to `signals/queue`. The event type is the same tag as the `event:*` comment written to NoteCove — the queue is the source of truth so orchestrator.py never needs to parse task comments for routing.

Examples:
- `WORK-abc:event:plan-ready`
- `WORK-abc:event:pr-ready:https://github.com/foo/bar/pull/1`
- `WORK-abc:event:questions`
- `WORK-abc:event:crash-detected` (written by watchdog.sh)
- `WORK-abc:event:pr-merged` (written by pr-monitor.sh)

### Task State as Event Type

The orchestrator does not use separate status files. After unblocking, it reads the NoteCove task state directly to determine what happened:

| NoteCove Task State | Meaning |
|---|---|
| `Attention` | Worker/planner needs user input — questions, plan ready, or PR ready |
| `In Review` | A reviewer agent is currently running (set by orchestrator only) |
| `Done` | Set by orchestrator after user approves — triggers worker exit |

### Event Tag Dispatch

When a task reaches `Attention`, the orchestrator reads the **last comment** to determine the precise event type. Every agent adds a machine-readable `event:<type>` comment as the final comment before signaling `Attention`. The orchestrator extracts the tag and dispatches via a clean `case` statement — no string-content heuristics.

| Event Tag | Fired by | Meaning |
|---|---|---|
| `event:questions` | Worker / Planner / Brainstormer | Agent has questions for the user |
| `event:plan-ready` | Worker | Plan note written, awaiting review |
| `event:pr-ready:<url>` | Worker | PR created at `<url>`, signaling readiness to orchestrator |
| `event:ideas-ready` | Brainstormer | New IDEAS note ready for user feedback |
| `event:selection-ready` | Brainstormer | SELECTION note ready for user to check ideas |
| `event:completion` | Brainstormer / Planner | Subtasks created (or skipped), parent marked Done |
| `event:plan-review-complete` | Plan Reviewer | Plan review note written, summary in comment |
| `event:pr-review-complete` | PR Reviewer | PR review posted to GitHub, summary in comment |
| `event:anomaly-detected:<key>` | Orchestrator | Invariant violation detected (forwarded to Spokesman for user notification) |
| `event:review-limit-reached:plan` | orchestrator.py | Auto-review cycle limit reached for plan reviews — escalated to Spokesman |
| `event:review-limit-reached:pr:<url>` | orchestrator.py | Auto-review cycle limit reached for PR reviews — escalated to Spokesman |

The orchestrator translates `event:pr-ready:<url>` from the worker into one of two Spokesman events depending on mode and context:

| Spokesman Event | When | Meaning |
|---|---|---|
| `event:pr-submitted:<url>` | Standard mode, first signal | PR needs user decision (approve / review / feedback / abort) |
| `event:pr-ready:<url>` | Auto-review mode, post-review | PR has been reviewed and validated; ready for final user approval |

---

## Roles

### Spokesman

**One instance.** Runs in the `orchestrator` tmux session, window `main`. This is the only session the user attaches to. The Spokesman is a thin user-interaction layer — it never spawns workers directly.

Responsibilities:
- Bootstrap the system (calls `bootstrap.sh` which starts orchestrator.py and all daemons)
- Block on `spokesman-event` and drain `spokesman-queue` after each unblock
- Triage new tasks (`event:task-ready`): decide agent type (worker/planner/brainstormer) using LLM judgment and send `spawn` command back to orchestrator.py
- Present user-attention events to the user (questions, plan ready, PR ready, review results)
- Write decisions to NoteCove (state changes, feedback comments) and relay commands to orchestrator.py via `orchestrator-cmds`
- When all tasks complete: tell orchestrator.py to shut down and exit

### Orchestrator Daemon (orchestrator.py)

**One instance.** Runs in the `orchestrator` tmux session, window `orchestrator`. Pure Python, always running — never blocked by user interaction.

Responsibilities:
- Pick up `Ready` tasks from NoteCove (up to `max-workers` in parallel), mark as `Doing`, and forward to Spokesman for agent-type triage via `spokesman-queue`
- Block on `orchestrator-event` (from dispatcher); drain `signals/queue` on each unblock
- Block on `orchestrator-cmd-event` (from Spokesman); drain `signals/orchestrator-cmds` on each unblock
- Auto-handle events that don't require user input:
  - `auto-review` mode: spawn reviewers automatically, pass results back to workers
  - Planner/brainstormer completion: auto-ack, set Done, clean up
  - PR merged: auto-approve, clean up
  - Worker crash: re-queue task, spawn new worker
- Forward user-attention events to `spokesman-queue` + fire `spokesman-event`
- Execute commands from Spokesman: fire resume signals, spawn agents, clean up

### Legacy Orchestrator

**Kept for compatibility.** The original `/orchestrator` Claude Code skill (`plugins/agentic-workflows/skills/orchestrator/SKILL.md`) remains unchanged. Use `/spokesman` as the new entry point for the Spokesman + orchestrator.py architecture.

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

**One instance per active PR-ready task.** Runs in the `orchestrator` session, window `pr-mon-<slug>`. Pure bash, no Claude. Always spawned by orchestrator.py as soon as the worker's `event:pr-ready` signal is received — in all modes (standard and auto-review).

Responsibilities:
- Poll `gh pr view <pr-url>` every 60 seconds
- When the PR state is `MERGED`: write a `signals/<slug>.merged` flag file, append `<slug>:event:pr-merged` to the queue, fire `worker-any-event`, and exit
- orchestrator.py detects the merge event and auto-approves (sets Done, fires resume, cleans up)

The pr-monitor window is killed by orchestrator.py in all PR resolution paths (approve, feedback, abort) and at shutdown.

### Watchdog

**One instance.** Runs in the `orchestrator` session, window `watchdog`. Pure bash, no Claude.

Responsibilities:
- Poll the worker registry (`signals/workers`) every 30 seconds
- For each registered worker, check if its tmux window still exists
- If a window is gone and the task state is still `doing` → crash detected: append `<slug>:event:crash-detected` to queue and fire `worker-any-event` to wake orchestrator.py
- Remove the entry from the registry regardless (window gone = worker dead)
- If the task state is anything other than `doing` (e.g. `done`, `attention`) → worker finished cleanly before being unregistered; no action

orchestrator.py handles the crash case: when it drains a `crash-detected` event, it re-queues the task to `Ready` and spawns a new worker.

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
  window 0: main            ← /spokesman skill (Claude Code) — user-interaction layer
  window 1: dispatcher      ← scripts/dispatcher.sh (bash loop)
  window 2: watchdog        ← scripts/watchdog.sh (bash loop)
  window 3: folder-cleanup  ← scripts/folder-cleanup.sh (bash loop)
  window 4: orchestrator    ← scripts/orchestrator.py (Python daemon)
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

Skills live in `plugins/agentic-workflows/skills/` in this repo. Agents can read and improve them directly.

| Skill | Invoked by | Source |
|---|---|---|
| `/spokesman` | User (manually) | `plugins/agentic-workflows/skills/spokesman/SKILL.md` |
| `/orchestrator` | User (manually, legacy) | `plugins/agentic-workflows/skills/orchestrator/SKILL.md` |
| `/worker` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/worker/SKILL.md` |
| `/planner` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/planner/SKILL.md` |
| `/brainstormer` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/brainstormer/SKILL.md` |
| `/plan-reviewer` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/plan-reviewer/SKILL.md` |
| `/pr-reviewer` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/pr-reviewer/SKILL.md` |

After editing a skill, bump the plugin version and reload it:

1. **Bump the version** in `plugins/agentic-workflows/.claude-plugin/plugin.json` (increment the patch version, e.g. `2.11.0` → `2.11.1`).
2. **Rebuild** (only if the skill extends `shared/base-agent.md`):
   ```bash
   ./plugins/agentic-workflows/build.sh
   ```
3. **Reload the plugin:**
   ```bash
   claude plugin update agentic-workflows@agentmesh
   ```

> Every plugin change — skill edits, new skills, script updates — must include a version bump so the installed plugin stays in sync with the repo.

---

## Project Structure

```
agentmesh/
├── CLAUDE.md               # this file
├── scripts/
│   ├── bootstrap.sh        # orchestrator startup: notecove init, signals dir, dispatcher + watchdog + folder-cleanup + orchestrator.py
│   ├── orchestrator.py     # orchestrator daemon: event routing, worker spawning, lifecycle management
│   ├── anomaly_checks.py   # AnomalyChecker: 4 structural invariant checks, dedup, Spokesman escalation
│   ├── dispatcher.sh       # fan-in relay (worker-any-event → orchestrator-event)
│   ├── watchdog.sh         # crash detector; re-queues tasks whose worker windows disappeared
│   ├── folder-cleanup.sh   # async folder housekeeping; moves Done/Won't-Do task subfolders to the Done folder
│   ├── pr-monitor.sh       # PR merge detector; auto-approves merged PRs
│   ├── spokesman-heartbeat-check.sh  # verifies orchestrator.py heartbeat; auto-restarts if stale (called by spokesman skill)
│   └── spokesman-exit.sh   # shutdown cleanup: kills tmux windows, removes signal files (called by spokesman skill)
└── signals/                # runtime directory, created on orchestrator bootstrap
    ├── queue               # append-only; workers write <slug>:<event-type> entries before signaling
    ├── spokesman-queue     # append-only; orchestrator.py writes <slug>:<event-type> for Spokesman to drain
    ├── orchestrator-cmds   # append-only; Spokesman writes <cmd-seq>|<slug>|<cmd>[|<args>] typed commands for orchestrator.py
    ├── spokesman-acks      # append-only; orchestrator.py writes <cmd-seq>|<slug>|confirm|<cmd> ACKs after each command (cleared on bootstrap)
    ├── workers             # worker registry; line per active worker: "<slug> <window-name>"
    ├── triage_folder       # Triage folder ID written by bootstrap.sh; read by orchestrator
    ├── mode                # running mode written by Spokesman on bootstrap (standard|auto-review); re-read on each wakeup cycle
    ├── <slug>.seq                  # per-task signal sequence counter; written by worker, read by orchestrator to compute resume signal name
    ├── <slug>.merged               # flag file written by pr-monitor when PR is merged
    ├── <slug>.reviewed             # flag file written by orchestrator after passing pr-review to worker (auto-review mode); cleared on PR resolution
    ├── <slug>.review-start         # flag file touched by orchestrator when a reviewer is spawned; cleared when review completes or is killed; used by anomaly check 1
    ├── <slug>.plan-review-count    # auto-review cycle counter for plan reviews; incremented before each plan-reviewer spawn; cleared at terminal state
    ├── <slug>.pr-review-count      # auto-review cycle counter for PR reviews; incremented before each pr-reviewer spawn; cleared at terminal state
    ├── orchestrator.heartbeat      # UTC timestamp written by orchestrator.py every 30s; Spokesman checks mtime on each wakeup
    ├── orchestrator-restart-cmd    # orchestrator.py launch command written by bootstrap.sh; used by Spokesman to restart on stale heartbeat
    └── events.log                  # append-only TSV: timestamp, component, event_type, slug
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
2026-04-26T...  orchestrator    task-triage-forwarded       WORK-xyz
2026-04-26T...  spokesman       task-triaged                WORK-xyz
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
2026-04-26T...  orchestrator    anomaly-detected:<key>      WORK-xyz
2026-04-26T...  orchestrator    anomaly-resolved:<key>      WORK-xyz
2026-04-26T...  orchestrator    review-limit-reached:plan   WORK-xyz
2026-04-26T...  orchestrator    review-limit-reached:pr     WORK-xyz
2026-04-26T...  orchestrator    shutdown                    -
2026-04-26T...  spokesman       agent-completion-ack        WORK-xyz
2026-04-26T...  spokesman       attention-resumed           WORK-xyz
2026-04-26T...  spokesman       attention-feedback          WORK-xyz
2026-04-26T...  spokesman       plan-reviewer-requested     WORK-xyz
2026-04-26T...  spokesman       reviewer-requested          WORK-xyz
2026-04-26T...  spokesman       review-approved             WORK-xyz
2026-04-26T...  spokesman       review-feedback             WORK-xyz
2026-04-26T...  spokesman       anomaly-detected            WORK-xyz
2026-04-26T...  spokesman       review-rejected             WORK-xyz
2026-04-26T...  spokesman       review-aborted              WORK-xyz
2026-04-26T...  spokesman       orchestrator-restarted      -
2026-04-26T...  spokesman       shutdown                    -
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
2026-04-26T...  worker          ci-wait-start               WORK-xyz
2026-04-26T...  worker          ci-wait-complete            WORK-xyz
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

## Path Conventions

All documentation, scripts, and skill files refer to the repo root as `~/agentmesh` (not as an absolute path like `/Users/<username>/agentmesh`).

- In bash scripts, use `~/agentmesh/...` or derive dynamically: `AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)`
- In Python scripts, use `Path(__file__).parent.parent` to locate the repo root at runtime
- In skill source files, use the `{{AGENTMESH}}` build variable — `build.sh` expands it to `~/agentmesh`

Do not add hardcoded absolute paths anywhere.

---

## First-time Setup (new machine)

After cloning the repo, register the marketplace and install the plugin:

```bash
cd ~/agentmesh
bash scripts/setup.sh
```

This is idempotent — safe to run again if anything changes.

## Starting the System

```bash
cd ~/agentmesh
tmux new-session -s orchestrator
claude
/spokesman --project WORK
```

The Spokesman bootstraps the entire system (orchestrator.py daemon + dispatcher + watchdog + folder-cleanup) and handles all user interaction from there.

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
/spokesman --project WORK --mode auto-review
```

### Review Limit (`--review-limit`)

In `auto-review` mode, the orchestrator tracks how many times each task has gone through an automatic review cycle (separately for plan reviews and PR reviews). If the cycle count exceeds the limit, the orchestrator escalates to the Spokesman instead of spawning another reviewer — the user must intervene manually.

| Option | Default | Description |
|---|---|---|
| `--review-limit <n>` | `3` | Max auto-review cycles per task per review type before escalating to user |

Counter files (`signals/<slug>.plan-review-count` and `signals/<slug>.pr-review-count`) are cleared at task terminal state (done, abort, crash) and on bootstrap.

Example:
```bash
/spokesman --project WORK --mode auto-review --review-limit 5
```

### Legacy Entry Point

The original `/orchestrator` skill is kept for compatibility but is no longer the recommended entry point. Use `/spokesman` for the new Spokesman + orchestrator.py architecture.
