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
- **`signals/slackbridge-queue`** — append-only file; orchestrator.py writes forwarded user-attention events for SlackBridge; SlackBridge drains it after unblocking
- **`signals/active-interfaces`** — one line per active interface name (`spokesman`, `slack-bridge`); read by orchestrator.py to fan out events; empty or missing = falls back to `spokesman` only
- **`signals/orchestrator-cmds`** — append-only file; Spokesman writes commands (`<slug>|<cmd>[|<args>]`); orchestrator.py drains it after unblocking
- **`scripts/dispatcher.sh`** — relay process running in a background tmux pane; listens on `worker-any-event` and forwards to `orchestrator-event`, enabling fan-in from multiple workers

### Signal Protocol

| Signal | Direction | Trigger |
|---|---|---|
| `worker-any-event` | Worker → Dispatcher | Worker needs to notify orchestrator.py |
| `orchestrator-event` | Dispatcher → orchestrator.py | Relayed fan-in signal |
| `spokesman-event` | orchestrator.py → Spokesman | User-attention event forwarded to Spokesman |
| `slackbridge-event` | orchestrator.py → SlackBridge | User-attention event forwarded to SlackBridge (when registered in `active-interfaces`) |
| `slackbridge-event` | slack-poller.sh → SlackBridge | Tick signal fired every N seconds; wakes SlackBridge to check for new inbound messages via MCP |
| `orchestrator-cmd-event` | Spokesman → orchestrator.py | Command from Spokesman (resume, spawn, etc.) |
| `<task-slug>-resume-<seq>` | orchestrator.py → Worker | Resume blocked worker (sequenced) |

Task slugs (e.g. `WORK-pm4`) are used as signal names — globally unique, safe for tmux (alphanumeric + hyphens).

### Queue Format

Workers write `<slug>:<event-type>` to `signals/queue`. The event type is the same tag as the `event:*` comment written to NoteCove — the queue is the source of truth so orchestrator.py never needs to parse task comments for routing.

Examples:
- `WORK-abc:event:plan-ready`
- `WORK-abc:event:pr-ready:https://github.com/foo/bar/pull/1`
- `WORK-abc:event:questions`
- `WORK-abc:event:crash-detected` (written by watchdog.sh — with exponential backoff)
- `WORK-abc:event:crash-limit-reached` (written by watchdog.sh after 3 consecutive crashes)
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

<!-- Source of truth: plugins/agentic-workflows/shared/protocol.yaml — update there first, then sync here -->
| Event Tag | Fired by | Meaning |
|---|---|---|
| `event:questions` | Implementer / Planner / Brainstormer / Investigator | Agent has questions for the user |
| `event:plan-ready` | Implementer | Plan note written (first submission), awaiting review |
| `event:plan-revised` | Implementer | Plan revised after reviewer feedback; re-review requested |
| `event:pr-ready:<url>` | Implementer | PR created at `<url>` (first submission), signaling readiness to orchestrator |
| `event:pr-revised:<url>` | Implementer | PR revised after reviewer feedback; re-review requested |
| `event:pr-ready-final:<url>` | Implementer | PR is ready for user approval — no further automated review needed |
| `event:ideas-ready` | Brainstormer | New IDEAS note ready for user feedback |
| `event:selection-ready` | Brainstormer | SELECTION note ready for user to check ideas |
| `event:design-ready` | Designer | DESIGN note written (first submission), awaiting user review |
| `event:design-revised` | Designer | Design revised after user feedback; re-review requested |
| `event:research-ready` | Investigator | Context notes written — awaiting user review and approval |
| `event:completion` | Brainstormer / Planner / Designer | Subtasks created (or skipped), parent marked Done |
| `event:plan-review-complete` | Plan Reviewer | Plan review note written, summary in comment |
| `event:pr-review-complete` | PR Reviewer | PR review posted to GitHub, summary in comment |
| `event:anomaly-detected:<key>` | Orchestrator | Invariant violation detected (forwarded to Spokesman for user notification) |
| `event:review-limit-reached:plan` | orchestrator.py | Auto-review cycle limit reached for plan reviews — escalated to Spokesman |
| `event:review-limit-reached:pr:<url>` | orchestrator.py | Auto-review cycle limit reached for PR reviews — escalated to Spokesman |
| `event:crash-limit-reached` | watchdog.sh | Worker crashed 3 consecutive times — task set to Blocked, escalated to Spokesman |

The orchestrator translates worker events into Spokesman events:

<!-- Source of truth: plugins/agentic-workflows/shared/protocol.yaml — update there first, then sync here -->
| Worker Event | Spokesman Event | When | Meaning |
|---|---|---|---|
| `event:pr-ready:<url>` | `event:pr-submitted:<url>` | Standard mode | PR needs user decision (approve / review / feedback / abort) |
| `event:pr-revised:<url>` | `event:pr-submitted:<url>` | Standard mode | Revised PR needs user decision |
| `event:pr-ready-final:<url>` | `event:pr-ready:<url>` | Auto-review mode, post-review | PR validated; ready for final user approval |

---

## Roles

### Spokesman

**One instance.** Runs in the `orchestrator` tmux session, window `main`. This is the only session the user attaches to. The Spokesman is a thin user-interaction layer — it never spawns workers directly.

Responsibilities:
- Bootstrap the system (calls `bootstrap.sh` which starts orchestrator.py and all daemons)
- Block on `spokesman-event` and drain `spokesman-queue` after each unblock
- Triage new tasks (`event:task-ready`): orchestrator.py already attempted type-map triage (by typeId then typeName); the Spokesman handles only the LLM fallback (tasks with no matching typeId or typeName); decide agent type using judgment and send `spawn` command back to orchestrator.py
- Present user-attention events to the user (questions, plan ready, PR ready, review results)
- Write decisions to NoteCove (state changes, feedback comments) and relay commands to orchestrator.py via `orchestrator-cmds`
- When all tasks complete: tell orchestrator.py to shut down and exit

### Orchestrator Daemon (orchestrator.py)

**One instance.** Runs in the `orchestrator` tmux session, window `orchestrator`. Pure Python, always running — never blocked by user interaction.

Responsibilities:
- Pick up `Ready` tasks from NoteCove (up to `max-workers` in parallel), mark as `Doing`, and triage by typeId then typeName against TYPE_MAP: matched types → spawn worker directly; unmatched types → forward to Spokesman for LLM triage via `spokesman-queue`
- Block on `orchestrator-event` (from dispatcher); drain `signals/queue` on each unblock
- Block on `orchestrator-cmd-event` (from Spokesman); drain `signals/orchestrator-cmds` on each unblock
- Auto-handle events that don't require user input:
  - `auto-review` mode: spawn reviewers automatically, pass results back to workers
  - Planner/brainstormer completion: auto-ack, set Done, clean up
  - PR merged: auto-approve, clean up
  - Worker crash: re-queue task, spawn new worker
- Forward user-attention events to all registered interfaces (reads `signals/active-interfaces`; falls back to `spokesman` only when empty)
- Execute commands from Spokesman: fire resume signals, spawn agents, clean up

### SlackBridge

**One instance (optional).** Runs in the `orchestrator` tmux session, window `slack-bridge` (or any user-chosen window). A full Spokesman peer that communicates via Slack instead of a tmux terminal. Registered in `signals/active-interfaces` as `slack-bridge`; the orchestrator fans events to both Spokesman and SlackBridge simultaneously.

Responsibilities:
- Register in `signals/active-interfaces` and write `signals/slack-channel` and `signals/slack-verbosity` at startup
- Block on `slackbridge-event` (fired by both orchestrator.py and slack-poller.sh on a timer)
- Drain `signals/slackbridge-queue` and dispatch each event to a Slack thread for the relevant task
- Poll Slack thread replies (via Slack MCP) for user commands (`approve`, `feedback: <text>`, `abort`, etc.)
- Parse top-level channel messages starting with `/agentmesh` as slash commands
- Write commands to `signals/orchestrator-cmds` and fire `orchestrator-cmd-event` (same as Spokesman)
- Deregister from `signals/active-interfaces` and post a shutdown message on exit
- Never bootstrap or shut down the orchestrator — those responsibilities remain with the Spokesman

### Legacy Orchestrator

**Kept for compatibility.** The original `/orchestrator` Claude Code skill (`plugins/agentic-workflows/skills/orchestrator/SKILL.md`) remains unchanged. Use `/spokesman` as the new entry point for the Spokesman + orchestrator.py architecture.

### Implementer

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

### Designer

**N instances (up to `max-workers`).** Each runs in the `workers` tmux session in a window named after its task slug (e.g. `workers:WORK-pm4`), spawned with `claude --dangerously-skip-permissions`.

Responsibilities:
- Pick up the assigned frontend/UI design task from NoteCove
- Explore task context and the codebase to understand what's being built
- Ask questions via `QUESTIONS-<N>` notes if requirements are ambiguous
- Create a DESIGN note with aesthetic direction, component breakdown, and proposed subtasks; signal `event:design-ready` for user review
- After design approval, create child tasks with rich DESCRIPTION notes (aesthetic guidance, acceptance criteria, specific files to create/modify)
- Signal `event:completion` — orchestrator auto-acks and marks Done
- Never implement code — designs and decomposes only
- Never mark its own task `Done`

### Investigator

**N instances (up to `max-workers`).** Each runs in the `workers` tmux session in a window named after its task slug (e.g. `workers:WORK-pm4`), spawned with `claude --dangerously-skip-permissions`.

Responsibilities:
- Pick up the assigned research task from NoteCove
- Explore task context, the codebase, and external resources (WebSearch/WebFetch)
- Ask questions via `QUESTIONS-<N>` notes if scope is ambiguous
- Write structured Context notes under a `Context/` subfolder in the task folder
- Signal `event:research-ready` — Spokesman presents research to user for approval; block until approved or feedback received
- Never write code or create PRs — research and documentation only
- Never create subtasks — it is a leaf agent
- Never mark its own task `Done`

### Documenter

**N instances (up to `max-workers`).** Each runs in the `workers` tmux session in a window named after its task slug (e.g. `workers:WORK-pm4`), spawned with `claude --dangerously-skip-permissions`.

Responsibilities:
- Pick up the assigned documentation task from NoteCove
- Read code to understand it; write or update README files, API docs, inline comments, and architecture notes
- Ask questions via `QUESTIONS-<N>` notes if documentation scope is ambiguous
- Skip the plan phase — proceed directly from exploration to writing (low risk, docs-only)
- Create a docs-only PR (no logic changes, no test-breaking changes)
- Signal `Attention` when PR is ready — standard approval/feedback loop
- Exit only after receiving the orchestrator's resume signal (user approved)
- Never change logic, fix bugs, add features, or rename variables
- Never mark its own task `Done`

### Dispatcher

**One instance.** Runs in the `orchestrator` session, window `dispatcher`. Pure bash, no Claude.

Responsibilities:
- Loop on `tmux wait-for worker-any-event`
- Forward each event to the orchestrator via `tmux wait-for -S orchestrator-event`
- Enables fan-in: multiple workers can signal concurrently without the orchestrator missing events

### PR Monitor

**One instance per active PR-ready task.** Runs in the `orchestrator` session, window `pr-mon-<slug>`. Pure bash, no Claude. Spawned automatically by `orchestrator.py` (in `_handle_queue_entry`) whenever it receives `event:pr-ready`, `event:pr-revised`, or `event:pr-ready-final` — before calling the corresponding event handler script. The spawn is idempotent. The Spokesman has no knowledge of the pr-monitor.

Responsibilities:
- Poll `gh pr view <pr-url>` every 60 seconds
- When the PR state is `MERGED`: write a `signals/<slug>.merged` flag file, append `<slug>:event:pr-merged` to the queue, fire `worker-any-event`, and exit
- orchestrator.py detects the merge event and auto-approves (sets Done, fires resume, cleans up)

The pr-monitor window is killed by orchestrator.py when the task closes (approve or abort). It is NOT killed during review cycles (reviewer feedback, re-review requests).

### Watchdog

**One instance.** Runs in the `orchestrator` session, window `watchdog`. Pure bash, no Claude.

Responsibilities:
- Poll the worker registry (`signals/workers`) every 30 seconds
- For each registered worker, check if its tmux window still exists
- If a window is gone and the task state is still `doing` → crash detected:
  - Read `signals/<slug>.crash-count` (default 0); increment
  - If crash count < 3: write count to file, sleep with exponential backoff (30s × 2^(n-1): 30s, 60s), append `<slug>:event:crash-detected` to queue, fire `worker-any-event`
  - If crash count ≥ 3: delete count file, set task to Blocked in NoteCove, append `<slug>:event:crash-limit-reached` to queue, fire `worker-any-event`
- Remove the entry from the registry regardless (window gone = worker dead)
- If the task state is anything other than `doing` (e.g. `done`, `attention`) → worker finished cleanly; reset crash count (`rm signals/<slug>.crash-count`)

orchestrator.py handles the crash case: when it drains a `crash-detected` event, it re-queues the task to `Ready` and spawns a new worker. When it drains `crash-limit-reached`, it cleans up and escalates to the Spokesman for user notification.

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
  window N: slack-poller    ← scripts/slack-poller.sh (bash loop, when --interface includes slack)
  window N: slack-bridge    ← /slack-bridge skill (Claude Code, when using Slack interface)

Session: workers
  window 0: WORK-pm4         ← /implementer skill (Claude Code, yolo mode)
  window 1: WORK-xyz         ← /implementer skill (Claude Code, yolo mode)
  window N: WORK-abc         ← /designer skill (Claude Code, yolo mode) — for frontend/UI design tasks
  window N: WORK-def         ← /investigator skill (Claude Code, yolo mode) — for research/context-gathering tasks
  window N: WORK-ghi         ← /documenter skill (Claude Code, yolo mode) — for documentation tasks
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
| `/slack-bridge` | User (manually) | `plugins/agentic-workflows/skills/slack-bridge/SKILL.md` |
| `/orchestrator` | User (manually, legacy) | `plugins/agentic-workflows/skills/orchestrator/SKILL.md` |
| `/implementer` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/implementer/SKILL.md` |
| `/planner` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/planner/SKILL.md` |
| `/brainstormer` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/brainstormer/SKILL.md` |
| `/designer` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/designer/SKILL.md` |
| `/investigator` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/investigator/SKILL.md` |
| `/documenter` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/documenter/SKILL.md` |
| `/plan-reviewer` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/plan-reviewer/SKILL.md` |
| `/pr-reviewer` | orchestrator.py (via `spawn-agent.sh`) | `plugins/agentic-workflows/skills/pr-reviewer/SKILL.md` |

Skills inherit from a two-level base hierarchy:

```
shared/base-agent.md          ← pure signal protocol (arg parsing, paths, signaling)
  ├── shared/base-implementer.md  ← + folder management, exploration, questions, triage
  │     └── implementer, planner, brainstormer, investigator, documenter
  └── shared/base-reviewer.md    ← + fire-and-done role, folder lookup, review conventions
        └── plan-reviewer, pr-reviewer
```

After editing a skill, bump the plugin version and reload it:

1. **Bump the version** in `plugins/agentic-workflows/.claude-plugin/plugin.json` (increment the patch version, e.g. `2.11.0` → `2.11.1`).
2. **Rebuild** (only if the skill extends a shared base file):
   ```bash
   ./plugins/agentic-workflows/build.sh
   ```
3. **Reload the plugin:**
   ```bash
   claude plugin update agentic-workflows@agentmesh
   ```

If you edit `shared/base-agent.md`, first propagate the changes into the family base files, then rebuild:

```bash
./plugins/agentic-workflows/build.sh --update-family-bases   # stamps base-agent.md into family files
./plugins/agentic-workflows/build.sh                          # rebuilds all skills
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
│   ├── signal-agent.sh     # sourced bash helper for agents: signal_init, signal_attention, signal_fire
│   ├── dispatcher.sh       # fan-in relay (worker-any-event → orchestrator-event)
│   ├── watchdog.sh         # crash detector; re-queues tasks whose worker windows disappeared
│   ├── folder-cleanup.sh   # async folder housekeeping; moves Done/Won't-Do task subfolders to the Done folder
│   ├── pr-monitor.sh       # PR merge detector; auto-approves merged PRs
│   ├── slack-poller.sh     # timer/ticker daemon: fires slackbridge-event every N seconds to wake SlackBridge for inbound message checks (no Slack API calls)
│   ├── agentmesh.sh        # lifecycle CLI: start / stop / status / attach
│   ├── spokesman-heartbeat-check.sh  # verifies orchestrator.py heartbeat; auto-restarts if stale (called by spokesman skill)
│   └── spokesman-exit.sh   # shutdown cleanup: kills tmux windows, removes signal files (called by spokesman skill)
└── signals/                # runtime directory, created on orchestrator bootstrap
    ├── queue               # append-only; workers write <slug>:<event-type> entries before signaling
    ├── spokesman-queue     # append-only; orchestrator.py writes <slug>:<event-type> for Spokesman to drain
    ├── slackbridge-queue   # append-only; orchestrator.py writes <slug>:<event-type> for SlackBridge to drain
    ├── active-interfaces   # one line per active interface name (e.g. spokesman, slack-bridge); empty = spokesman-only fallback
    ├── orchestrator-cmds   # append-only; Spokesman writes <slug>|<cmd>[|<args>] commands for orchestrator.py
    ├── workers             # worker registry; line per active worker: "<slug> <window-name>"
    ├── triage_folder       # Triage folder ID written by bootstrap.sh; read by orchestrator
    ├── slack-channel       # Slack channel ID written by bootstrap.sh (empty string when interface is spokesman-only); read by SlackBridge
    ├── mode                # running mode written by Spokesman on bootstrap (standard|auto-review); re-read on each wakeup cycle
    ├── <slug>.seq                  # per-task signal sequence counter; written by worker, read by orchestrator to compute resume signal name
    ├── <slug>.merged               # flag file written by pr-monitor when PR is merged
    ├── <slug>.review-start         # flag file touched by orchestrator when a reviewer is spawned; cleared when review completes or is killed; used by anomaly check 1
    ├── <slug>.plan-review-count    # auto-review cycle counter for plan reviews; incremented before each plan-reviewer spawn; cleared at terminal state
    ├── <slug>.pr-review-count      # auto-review cycle counter for PR reviews; incremented before each pr-reviewer spawn; cleared at terminal state
    ├── <slug>.crash-count          # consecutive crash counter; written by watchdog on each crash, reset on clean exit or at bootstrap
    ├── slack-verbosity             # verbosity level written by SlackBridge at startup (low|medium|high); re-read each wakeup cycle
    ├── slack-channel-last-ts       # timestamp of last processed top-level channel message; used by SlackBridge to avoid reprocessing
    ├── <slug>.slack-thread         # Slack thread timestamp written by SlackBridge when it starts a thread for the task
    ├── <slug>.slack-last-ts        # timestamp of last processed reply in the task's Slack thread; used by SlackBridge to avoid reprocessing
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
2026-04-26T...  watchdog        crash-limit-reached         WORK-xyz
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
2026-04-26T...  orchestrator    crash-limit-reached         WORK-xyz
2026-04-26T...  orchestrator    pr-monitor-spawned          WORK-xyz
2026-04-26T...  orchestrator    pr-auto-approved            WORK-xyz
2026-04-26T...  orchestrator    pr-review-passed-to-worker  WORK-xyz
2026-04-26T...  orchestrator    anomaly-detected:<key>      WORK-xyz
2026-04-26T...  orchestrator    anomaly-resolved:<key>      WORK-xyz
2026-04-26T...  orchestrator    review-limit-reached:plan   WORK-xyz
2026-04-26T...  orchestrator    review-limit-reached:pr     WORK-xyz
2026-04-26T...  orchestrator    shutdown                    -
2026-04-26T...  orchestrator    research-ready-forwarded    WORK-xyz
2026-04-26T...  spokesman       research-approved           WORK-xyz
2026-04-26T...  spokesman       agent-completion-ack        WORK-xyz
2026-04-26T...  spokesman       attention-resumed           WORK-xyz
2026-04-26T...  spokesman       attention-feedback          WORK-xyz
2026-04-26T...  spokesman       plan-reviewer-requested     WORK-xyz
2026-04-26T...  spokesman       reviewer-requested          WORK-xyz
2026-04-26T...  spokesman       review-approved             WORK-xyz
2026-04-26T...  spokesman       review-feedback             WORK-xyz
2026-04-26T...  spokesman       anomaly-detected            WORK-xyz
2026-04-26T...  spokesman       crash-limit-reached         WORK-xyz
2026-04-26T...  spokesman       review-rejected             WORK-xyz
2026-04-26T...  spokesman       review-aborted              WORK-xyz
2026-04-26T...  spokesman       worker-respawned            WORK-xyz
2026-04-26T...  spokesman       orchestrator-restarted      -
2026-04-26T...  spokesman       shutdown                    -
2026-04-26T...  folder-cleanup  folder-moved                WORK-xyz
2026-04-26T...  pr-monitor      started                     WORK-xyz
2026-04-26T...  pr-monitor      pr-merged-detected          WORK-xyz
2026-04-26T...  slack-poller    started                     -
2026-04-26T...  slack-poller    tick                        -
2026-04-26T...  slack-bridge    started                     -
2026-04-26T...  slack-bridge    task-triaged                WORK-xyz
2026-04-26T...  slack-bridge    thread-created              WORK-xyz
2026-04-26T...  slack-bridge    reply-received              WORK-xyz
2026-04-26T...  slack-bridge    slash-command               -
2026-04-26T...  slack-bridge    shutdown                    -
2026-04-26T...  plan-reviewer   plan-review-started         WORK-xyz
2026-04-26T...  plan-reviewer   error-no-plan               WORK-xyz
2026-04-26T...  plan-reviewer   plan-review-complete        WORK-xyz
2026-04-26T...  pr-reviewer     pr-review-started           WORK-xyz
2026-04-26T...  pr-reviewer     pr-review-complete          WORK-xyz
2026-04-26T...  implementer     started                     WORK-xyz
2026-04-26T...  implementer     signaling-attention         WORK-xyz
2026-04-26T...  implementer     resumed                     WORK-xyz
2026-04-26T...  implementer     signaling-plan              WORK-xyz
2026-04-26T...  implementer     resumed-from-plan           WORK-xyz
2026-04-26T...  implementer     implementing                WORK-xyz
2026-04-26T...  implementer     pr-created                  WORK-xyz
2026-04-26T...  implementer     signaling-attention-pr-ready WORK-xyz
2026-04-26T...  implementer     approved                    WORK-xyz
2026-04-26T...  implementer     feedback-received           WORK-xyz
2026-04-26T...  designer        started                     WORK-xyz
2026-04-26T...  designer        signaling-attention         WORK-xyz
2026-04-26T...  designer        resumed                     WORK-xyz
2026-04-26T...  designer        signaling-design            WORK-xyz
2026-04-26T...  designer        resumed-from-design         WORK-xyz
2026-04-26T...  designer        signaling-design-revised    WORK-xyz
2026-04-26T...  designer        resumed-from-design-revised WORK-xyz
2026-04-26T...  designer        signaling-completion        WORK-xyz
2026-04-26T...  designer        approved                    WORK-xyz
2026-04-26T...  investigator    started                     WORK-xyz
2026-04-26T...  investigator    signaling-attention         WORK-xyz
2026-04-26T...  investigator    resumed                     WORK-xyz
2026-04-26T...  investigator    researching                 WORK-xyz
2026-04-26T...  investigator    signaling-research-ready    WORK-xyz
2026-04-26T...  investigator    resumed                     WORK-xyz
2026-04-26T...  investigator    approved                    WORK-xyz
2026-04-26T...  investigator    feedback-received           WORK-xyz
2026-04-26T...  documenter      started                     WORK-xyz
2026-04-26T...  documenter      signaling-attention         WORK-xyz
2026-04-26T...  documenter      resumed                     WORK-xyz
2026-04-26T...  documenter      implementing                WORK-xyz
2026-04-26T...  documenter      pr-created                  WORK-xyz
2026-04-26T...  documenter      signaling-attention-pr-ready WORK-xyz
2026-04-26T...  documenter      approved                    WORK-xyz
2026-04-26T...  documenter      feedback-received           WORK-xyz
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

### Recommended: `agentmesh start`

```bash
agentmesh start --project WORK
```

This bootstraps all daemons, then launches the Spokesman with `--no-bootstrap`. The Spokesman skips its own bootstrap phase, registers in `signals/active-interfaces`, and starts the event loop.

**Full options:**

```
agentmesh start --project <key>
                [--mode standard|auto-review]          # default: standard
                [--review-limit <n>]                   # default: 3
                [--interface spokesman|slack|both]      # default: spokesman
                [--channel <slack-channel-id>]          # required if --interface includes slack
                [--verbosity low|medium|high]           # default: medium (SlackBridge only)
                [--slack-poller-interval <seconds>]    # default: 5
```

**Other commands:**

```bash
agentmesh stop      # graceful shutdown: kills all windows and the workers session
agentmesh status    # health report: components, heartbeat, active workers, mode
agentmesh attach    # attach to the orchestrator tmux session (terminal fallback)
```

### Manual / Legacy

```bash
cd ~/agentmesh
tmux new-session -s orchestrator
claude
/spokesman --project WORK
```

The Spokesman bootstraps the entire system (orchestrator.py daemon + dispatcher + watchdog + folder-cleanup) and handles all user interaction from there.

> **Note:** `--no-bootstrap` is for use by `agentmesh start` only. Manual invocations use the standard flow above.

### Running Modes

Pass `--mode <mode>` to choose how the orchestrator handles plan and PR reviews:

| Mode | Behavior |
|---|---|
| `standard` (default) | User manually reviews plans and PRs; reviewers spawn only on explicit user request |
| `auto-review` | Plan-reviewers and PR-reviewers spawn automatically; review is passed back to implementers automatically; user only approves the final PR |

**`auto-review` mode flow:**
1. When a plan is ready → plan-reviewer spawns automatically, review passed back to implementer (no user prompt)
2. When a PR is ready → pr-reviewer spawns automatically, review passed back to implementer (no user prompt); implementer applies fixes and re-signals when ready
3. After implementer re-signals PR-ready (post-review) → user sees the final PR and approves or gives feedback
4. Implementer questions → user is always asked (no automation for Q&A)

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

### Interface (`--interface`)

Pass `--interface <mode>` to choose which user-facing interfaces are active:

| Interface | Behavior |
|---|---|
| `spokesman` (default) | Only the Spokesman Claude Code process handles user interaction |
| `slack` | Slack integration only: starts `slack-poller.sh` to wake SlackBridge on a timer |
| `both` | Both Spokesman and Slack interfaces active simultaneously |

When `--interface` includes `slack`, `--slack-channel <channel-id>` is required. The channel ID is written to `signals/slack-channel` for the SlackBridge skill to read. An optional `--slack-poller-interval <seconds>` arg controls the tick frequency (default: 5).

Example — start with both interfaces, polling every 10 seconds:
```bash
/spokesman --project WORK --interface both --slack-channel C01234567 --slack-poller-interval 10
```

The SlackBridge skill registers itself in `signals/active-interfaces` when it starts, enabling the orchestrator to forward worker events to both Spokesman and SlackBridge simultaneously.

### Legacy Entry Point

The original `/orchestrator` skill is kept for compatibility but is no longer the recommended entry point. Use `/spokesman` for the new Spokesman + orchestrator.py architecture.
