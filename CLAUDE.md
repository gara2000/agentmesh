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
- **`signals/slackbridge-queue`** — append-only file; orchestrator.py writes forwarded user-attention events (`<slug>:<event-type>`) and `slack-socket-relay.py` writes relay-pushed inbound Slack messages (`slack-message:<channel_id>:<thread_ts>:<user_id>:<text_escaped>`); SlackBridge drains it after unblocking
- **`signals/active-interfaces`** — one line per active interface name (`spokesman`, `slackbridge`); read by orchestrator.py to fan out events; empty or missing = falls back to `spokesman` only
- **`signals/orchestrator-cmds`** — append-only file; Spokesman writes commands (`<slug>|<cmd>[|<args>]`); orchestrator.py drains it after unblocking
- **`scripts/dispatcher.sh`** — relay process running in a background tmux pane; listens on `worker-any-event` and forwards to `orchestrator-event`, enabling fan-in from multiple workers

### Signal Protocol

| Signal | Direction | Trigger |
|---|---|---|
| `worker-any-event` | Worker → Dispatcher | Worker needs to notify orchestrator.py |
| `orchestrator-event` | Dispatcher → orchestrator.py | Relayed fan-in signal |
| `spokesman-event` | orchestrator.py → Spokesman | User-attention event forwarded to Spokesman |
| `slackbridge-event` | orchestrator.py → SlackBridge | User-attention event forwarded to SlackBridge (when registered in `active-interfaces`) |
| `slackbridge-event` | slack-socket-relay.py → SlackBridge | Push signal fired when Slack delivers a message over the WebSocket connection |
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
| `event:questions` | Implementer / Planner / Brainstormer / Investigator / Ticketer | Agent has questions for the user |
| `event:plan-ready` | Implementer | Plan note written (first submission), awaiting review |
| `event:plan-revised` | Implementer | Plan revised after reviewer feedback; re-review requested |
| `event:pr-ready:<url>` | Implementer | PR created at `<url>` (first submission), signaling readiness to orchestrator |
| `event:pr-revised:<url>` | Implementer | PR revised after reviewer feedback; re-review requested |
| `event:pr-ready-final:<url>` | Implementer | PR is ready for user approval — no further automated review needed |
| `event:confluence-ready:<url>` | Documenter | Confluence page created/updated at `<url>` in personal space, awaiting user review — no PR created |
| `event:ideas-ready` | Brainstormer | New IDEAS note ready for user feedback |
| `event:selection-ready` | Brainstormer | SELECTION note ready for user to check ideas |
| `event:design-ready` | Designer | DESIGN note written (first submission), awaiting user review |
| `event:design-revised` | Designer | Design revised after user feedback; re-review requested |
| `event:research-ready` | Investigator | Context notes written — awaiting user review and approval |
| `event:tickets-draft` | Ticketer | Ticket draft written — awaiting user confirmation before creating in Atlassian |
| `event:tickets-created` | Ticketer | Tickets created in Jira — task auto-completed by orchestrator |
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
| `event:confluence-ready:<url>` | `event:confluence-submitted:<url>` | Always | Confluence docs ready; needs user decision (approve / feedback / abort) |

---

## Roles

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

### Legacy Orchestrator

**Kept for compatibility.** The original `/orchestrator` Claude Code skill (`plugins/agentic-workflows/skills/orchestrator/SKILL.md`) remains unchanged. Use `/spokesman` as the new entry point for the Spokesman + orchestrator.py architecture.

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

### Ready Poller

**One instance.** Runs in the `orchestrator` session, window `ready-poller`. Pure bash, no Claude.

Responsibilities:
- Poll NoteCove every 30 seconds for tasks in `Ready` state
- When any `Ready` tasks are found, write `-|scan` to `signals/orchestrator-cmds` and fire `orchestrator-cmd-event`
- The orchestrator wakes up and calls `pick_up_ready_tasks()` to pick up and spawn workers for the ready tasks
- Ensures tasks that become `Ready` while the orchestrator is idle (no worker events) are picked up promptly

The ready-poller window is killed by `agentmesh stop` at shutdown.

---

## tmux Layout

```
Session: orchestrator       ← user attaches here only
  window 0: main            ← /spokesman skill (Claude Code) — user-interaction layer
  window 1: dispatcher      ← scripts/dispatcher.sh (bash loop)
  window 2: watchdog        ← scripts/watchdog.sh (bash loop)
  window 3: folder-cleanup  ← scripts/folder-cleanup.sh (bash loop)
  window 4: ready-poller    ← scripts/ready-poller.sh (bash loop)
  window 5: orchestrator    ← scripts/orchestrator.py (Python daemon)
  window N: pr-mon-WORK-xyz ← scripts/pr-monitor.sh (bash loop, one per PR-ready task)
  window N: slack-socket    ← scripts/slack-socket-relay.py (Python daemon, when --interface includes slack)
  window N: slack-bridge    ← /slack-bridge skill (Claude Code, when using Slack interface)

Session: workers
  window 0: WORK-pm4         ← /implementer skill (Claude Code, yolo mode)
  window 1: WORK-xyz         ← /implementer skill (Claude Code, yolo mode)
  window N: WORK-abc         ← /designer skill (Claude Code, yolo mode) — for frontend/UI design tasks
  window N: WORK-def         ← /investigator skill (Claude Code, yolo mode) — for research/context-gathering tasks
  window N: WORK-ghi         ← /documenter skill (Claude Code, yolo mode) — for documentation tasks
  window N: WORK-jkl         ← /ticketer skill (Claude Code, yolo mode) — for Jira ticket creation tasks
  window N: plan-rev-WORK-xyz ← /plan-reviewer skill (Claude Code, one per plan under review)
  window N: pr-rev-WORK-xyz   ← /pr-reviewer skill (Claude Code, one per PR under review)
  ...
```

---

## Skills

Skills live in `plugins/agentic-workflows/skills/` in this repo. Agents can read and improve them directly.

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
│   ├── ready-poller.sh     # Ready task poller; fires scan command when Ready tasks are found
│   ├── slack-socket-relay.py # Socket Mode WebSocket relay: forwards inbound Slack messages to slackbridge-queue and fires slackbridge-event
│   ├── agentmesh.sh        # lifecycle CLI: start / stop / status / attach
│   ├── spokesman-heartbeat-check.sh  # verifies orchestrator.py heartbeat; auto-restarts if stale (called by spokesman skill)
│   └── spokesman-exit.sh   # shutdown cleanup: kills tmux windows, removes signal files (called by spokesman skill)
└── signals/                # runtime directory, created on orchestrator bootstrap
    ├── queue               # append-only; workers write <slug>:<event-type> entries before signaling
    ├── spokesman-queue     # append-only; orchestrator.py writes <slug>:<event-type> for Spokesman to drain
    ├── slackbridge-queue   # append-only; orchestrator.py writes <slug>:<event-type> for SlackBridge to drain
    ├── active-interfaces   # one line per active interface name (e.g. spokesman, slackbridge); empty = spokesman-only fallback
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
    ├── slack-idle-pause-minutes    # idle-pause threshold in minutes written by bootstrap.sh; absent = feature disabled
    ├── slack-bridge-last-user-msg-ts # unix timestamp of last user message; written by SlackBridge on each user interaction; used for idle-pause
    ├── slack-poller-auto-paused    # sentinel flag written by SlackBridge alongside slack-poller-paused when auto-pause triggers; absent = manual pause
    ├── slack-poller-processing     # flag set by SlackBridge while it is processing events (not listening); poller skips firing when this flag is present
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
2026-04-26T...  orchestrator    task-picked-up              WORK-xyz
2026-04-26T...  orchestrator    worker-spawned              WORK-xyz
2026-04-26T...  orchestrator    event-received:attention    WORK-xyz
2026-04-26T...  spokesman       attention-resumed           WORK-xyz
2026-04-26T...  watchdog        crash-detected              WORK-xyz
2026-04-26T...  pr-monitor      pr-merged-detected          WORK-xyz
2026-04-26T...  ready-poller    scan-triggered              -
2026-04-26T...  slack-bridge    thread-created              WORK-xyz
2026-04-26T...  implementer     started                     WORK-xyz
2026-04-26T...  plan-reviewer   plan-review-complete        WORK-xyz
2026-04-26T...  pr-reviewer     pr-review-complete          WORK-xyz
2026-04-26T...  folder-cleanup  folder-moved                WORK-xyz
```

For the full list of event types per component, see each component's skill or script source.

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
                [--slack-idle-pause <minutes>]          # default: 0 (disabled); auto-pause polling after N min of Slack inactivity
```

**Other commands:**

```bash
agentmesh stop                    # graceful shutdown: kills all windows and the workers session
agentmesh status                  # health report: components, heartbeat, active workers, mode
agentmesh attach                  # attach to the orchestrator tmux session (terminal fallback)
agentmesh task create <title> \   # create a new task in NoteCove
  --project <key> \
  [--folder <name-or-id>] \
  [--priority <n>] \
  [--type <type>] \
  [--content <text>]
```

`agentmesh task create` wraps `notecove task create` with folder name resolution: pass a folder name (e.g. `Triage`) or folder ID directly to `--folder`.

### Manual / Legacy

**Spokesman** (terminal interface): `tmux new-session -s orchestrator && claude && /spokesman --project WORK`

**SlackBridge** (Slack interface): `tmux new-session -s orchestrator && claude && /slack-bridge --project WORK --channel C01234567`

> `--no-bootstrap` is for use by `agentmesh start` only. Manual invocations use the standard flow above.

### Legacy Entry Point

The original `/orchestrator` skill is kept for compatibility but is no longer the recommended entry point. Use `/spokesman` for the new Spokesman + orchestrator.py architecture.
