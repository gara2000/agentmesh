# AgentMesh — Agentic Workflow

AgentMesh is a multi-agent orchestration system built on tmux and NoteCove. It picks up tasks from NoteCove and assigns them to autonomous worker agents.

**NoteCove is the only interaction surface between the user and the agents.** There is no chat interface, no relay process, and no interface layer. Each agent talks to the user directly through its task: comments carry the conversation, notes carry artifacts, task state carries intent.

---

## How It Works

### The interaction cycle

An agent that needs the user does three things:

1. **Posts a brief comment** summarising what it just did and what it needs.
2. **Sets the task to `Attention`** and blocks, consuming no tokens.
3. **Wakes when its sidecar nudges it**, reads what changed, and continues.

The user replies by commenting on the task in NoteCove — nothing else is required of them.

```
agent → comment + Attention → user reads and replies in NoteCove → sidecar → <slug>-nudge-<seq> → agent
```

### Coordination Primitives

- **`tmux wait-for -S <signal>`** — fires a named signal (non-blocking)
- **`tmux wait-for <signal>`** — blocks until the signal is fired
- **`signals/<slug>.inbox`** — append-only, line-delimited JSON; the sidecar (or pr-monitor) writes what changed, the agent reads and clears it
- **`signals/<slug>.seq`** — per-task nudge sequence counter; written by the agent before it blocks, read by the sidecar to know which signal to fire
- **`scripts/sidecar.sh`** — one per worker; watches the task in NoteCove and nudges its agent on any change

### Signal Protocol

| Signal | Direction | Trigger |
|---|---|---|
| `<task-slug>-nudge-<seq>` | Sidecar → Agent | A new comment (not the agent's own) or a task state change |
| `<task-slug>-nudge-<seq>` | PR Monitor → Agent | The agent's PR was merged |

Task slugs (e.g. `WORK-pm4`) are used as signal names — globally unique, safe for tmux (alphanumeric + hyphens).

The sequence number makes every nudge unique across rounds, so a stale signal from round N cannot unblock round N+1.

### Inbox Format

The sidecar appends one JSON object per line to `signals/<slug>.inbox`:

```json
{"kind":"comment","id":"CDpiRX…","author":"gara","content":"looks good, ship it","created":1792062799252}
{"kind":"state-change","from":"doing","to":"…","to_name":"Won't Do"}
{"kind":"pr-merged","url":"https://github.com/foo/bar/pull/1","note":"PR was merged. Set the task to Done."}
```

The agent reads the inbox rather than re-fetching and re-diffing the task itself.

### Why the inbox and not just the signal

`await_user` breaks on **the inbox being non-empty**, not on receiving the signal. This closes the race where the sidecar nudges while the agent is mid-turn: tmux drops the signal, but the inbox is already written, so the agent's next `await_user` returns immediately instead of blocking on a signal that will never fire again.

It also makes `await_user` safe to re-call. Claude Code's Bash tool caps at 10 minutes, so any real wait gets interrupted; because the announce (comment + state) and the wait (loop) are separate, and the loop writes nothing and fires nothing, re-invoking it simply re-enters the wait.

### Task State

Task state is owned by **the worker agent and the user — nothing else.**

| NoteCove Task State | Set by | Meaning |
|---|---|---|
| `Ready` | User | Available for pickup. The launcher reads it but never writes it. |
| `Doing` | Worker | The worker has claimed the task; its first action after booting. |
| `Attention` | Worker | The worker needs the user and is blocked. |
| `Done` | Worker via `finish_task` (after the user approves) or User | Work accepted. |
| `Won't Do` | Worker via `finish_task` (on `abort`) or User | Work abandoned. |
| `Blocked` | Watchdog (crash limit) or User | Needs investigation. |

The watchdog setting `Ready`/`Blocked` on a crash is the one exception: a crashed worker cannot set its own state, and the alternative is a task stuck in `Doing` with nothing running.

### Comment Conventions

- **Comments are summaries, not documents.** A few sentences at most — a comment tells the user what happened and where to look. Anything longer goes in a NoteCove note that the comment names.
- **Agents post under their role name** (`--user "Implementer"`, `--user "Investigator"`, …). The sidecar filters an agent's own comments by author name, so this value must match the skill's `agent-user` frontmatter and the `AGENT_AUTHOR` map in `launcher.py` — a mismatch makes an agent wake itself on every comment it writes.
- **The user writes free text**, interpreted with judgement. Two words are reserved commands honoured literally: `approve` (accept the work; the agent sets `Done`) and `abort` (stop; the agent sets `Won't Do`).
- **Agents echo their reading back** ("Read as: approve → marking Done") so a misinterpretation is visible rather than silent.

---

## Roles

### Launcher (launcher.py)

**One instance.** Runs in the `orchestrator` tmux session, window `launcher`. Pure Python.

Its entire job is picking up work and starting workers. It does not route events, does not talk to running agents, and does not change task state.

Responsibilities, in order, every `--poll-interval` seconds (default 30):
- **Reconcile sidecars** — spawn a sidecar for any live worker missing one, and re-register live workers absent from `signals/workers`
- **Adopt orphaned tasks** — spawn a worker for any `Doing`/`Attention` task with no live worker window (see below)
- **Pick up `Ready` tasks**, up to `max-workers` in parallel, triaged by `typeIds` then `typeNames` against `TYPE_MAP`
- Refuse tasks whose type does not resolve (see below)
- Write `signals/launcher.heartbeat` **after each completed scan** for `agentmesh status`

Adoption runs first: finishing work already in flight takes priority over starting more of it, and both draw from the same slot budget.

**Untyped tasks are refused, not guessed.** A task is only picked up when its type maps through `TYPE_MAP`. Anything else — no type at all, or a type like `chore` that maps to nothing — is left in `Ready` with no default agent. The refusal posts exactly one comment, deduped via `signals/<slug>.untyped`, and is logged on every scan. Setting a supported type makes the task eligible again on the next scan.

**Adoption: recovering orphaned work.** A task in `Doing` or `Attention` means a worker was working on it. If its tmux window is gone, that worker died — on an `agentmesh stop`/`start`, a machine reboot, or because the watchdog reaped it while the task sat in `Attention`. Nothing else would ever look at that task again: the pickup scan only queries `Ready`, and `bootstrap.sh` truncates `signals/workers`, so after a restart the watchdog has no record of it either.

Each scan, the launcher lists `Doing` and `Attention` tasks and spawns a worker + sidecar for any whose window is missing. It skips:

- tasks whose worker is alive — what makes the pass safe to run repeatedly and across launcher restarts
- tasks holding a live `.launching` flag — a worker mid-boot has no window yet
- tasks holding a `.backoff` sentinel — the watchdog is sleeping out a crash backoff and will re-queue the task itself; adopting here would have it tear down the worker we just made
- tasks whose type no longer maps to an agent — there is no way to know which agent owned the work

If `tmux list-windows` cannot be queried at all, the whole pass is skipped rather than treating an empty result as "every worker is dead".

**State is deliberately untouched** — the launcher only spawns. The respawned worker sets its own `Doing` and restores context by re-reading its task folder notes and the task's comments. Every skill is told at startup that it may be a restarted worker and must read existing notes before redoing work.

> Without this pass, `agentmesh stop && agentmesh start` silently abandons every in-flight task and the user has to re-queue each one by hand. The pre-refactor Spokesman did this in its "Phase 0.5: Startup Recovery"; this is that logic moved into the launcher and extended to cover `Doing` as well as `Attention`.

**The launcher does not set `Doing`.** The worker does, as its first action. That leaves the task in `Ready` while Claude boots (10–60s), so the launcher writes `signals/<slug>.launching` before spawning and skips any slug holding a live flag; the worker clears it on claiming the task. The flag expires after 5 minutes so a worker that dies during boot does not wedge the task permanently.

The launcher window runs inside a restart loop (`while true; do python3 launcher.py …; sleep 5; done`) — nothing supervises it, and it has no Claude dependency, so respawning in place is the simplest form of supervision. Each restart is logged as `process-exited-restarting`.

**The heartbeat is written only after a completed scan**, never at startup and never from a background thread. Both of those made a launcher crash-looping every 5s look perfectly healthy: each restart refreshed the file, so `agentmesh status` reported `✓ running` while nothing was ever picked up. Freshness now means "work is being picked up", which is what the check is for. `bootstrap.sh` deliberately does not pre-stamp it either.

### Sidecar reconciliation

A sidecar is the only thing that can wake a blocked agent, so a worker whose sidecar died waits on `await_user` forever — silently, because its own window is still alive. Adoption cannot cover this: it skips any slug with a live worker window, which is exactly this case.

The launcher therefore reconciles before adopting. For each live worker window it spawns a sidecar if `side-<slug>` is missing, and re-registers the worker if `signals/workers` has no entry for it (which happens whenever `bootstrap.sh` truncates the registry while workers survive — otherwise they stay invisible to the watchdog and uncounted against `max-workers`).

### Sidecar

**One instance per active worker.** Runs in the `orchestrator` session, window `side-<slug>`. Pure bash, no Claude.

The sidecar is **completely generic** — it carries no task-type knowledge. It never interprets comment content, never changes task state, and never decides what a change means. It reports "this changed" and wakes the agent; the agent, which already knows its own type because it is running a type-specific skill, decides what to do. Its only parameter beyond the slug is `--agent-handle`, the comment author name it treats as "mine".

Responsibilities:
- Establish a baseline of comment IDs and task state at startup (pre-existing comments are history, not replayed at the agent)
- Detect changes two ways, both funnelling into one diff step:
  - **SSE push** — subscribe to `notecove events --types "task.*"` and run the diff on any frame naming this slug
  - **Safety-net poll** — run the same diff every `--poll-interval` seconds (default 60)
- On a change, append to `signals/<slug>.inbox` and fire `<slug>-nudge-<seq>`

The poll runs **always**, not only when SSE is unavailable. The documented NoteCove event types (`task.created`, `task.modified`, `task.deleted`) include nothing comment-specific, so whether adding a comment emits a frame is an inference; the poll makes correctness independent of it. Duplicate triggers are harmless — the diff is against stored baseline state, so a change is reported exactly once however many times the check runs.

SSE requires the `events:subscribe` permission, requested by `bootstrap.sh` via `notecove init --events`. Until it is granted the sidecar logs `sse-unavailable:no-permission` and relies on the poll; `agentmesh status` reports which mode is in effect.

The `side-<slug>` window is **not** registered in `signals/workers` — it is not a worker, and registering it would make the watchdog treat its exit as a task crash. It is killed explicitly by the watchdog on crash cleanup and by `agentmesh stop`.

### PR Monitor

**One instance per active PR-ready task.** Runs in the `orchestrator` session, window `pr-mon-<slug>`. Pure bash, no Claude.

Responsibilities:
- Poll `gh pr view <pr-url>` every 60 seconds
- When the PR state is `MERGED`: write `signals/<slug>.merged`, append a `pr-merged` entry to the worker's inbox, fire the nudge, and exit

It does **not** set task state — the worker wakes, sees the merge, and sets `Done` itself. Merge detection lives here rather than in the sidecar so the sidecar stays generic, with no notion of PRs.

### Watchdog

**One instance.** Runs in the `orchestrator` session, window `watchdog`. Pure bash, no Claude.

Responsibilities:
- Poll the worker registry (`signals/workers`) every 30 seconds
- For each registered worker, check whether its tmux window still exists
- If a window is gone and the task state is still `doing` → crash detected:
  - Read `signals/<slug>.crash-count` (default 0); increment
  - If crash count < 3: write the count, sleep with exponential backoff (30s × 2^(n-1): 30s, 60s), clean up the task's side processes, and set the task back to `Ready` — the launcher spawns a fresh worker on its next scan
  - If crash count ≥ 3: delete the count file, set the task to `Blocked`, and comment on the task explaining why. `Blocked` plus the comment *is* the user-visible escalation; no process relays notifications any more.
- If the window is gone and the task is in `attention` → **stranded, not finished**: the task is mid-conversation with the user and its worker is gone. Deregister it (so it is not re-reported every poll) but leave its sidecar, inbox, and seq intact — the launcher's adoption pass will spawn a fresh worker, and a pending user reply sitting in the inbox has to survive until that worker reads it. **This path still counts crashes**: adoption respawns every 30s, so a worker that reproducibly dies right after `await_user` would otherwise loop forever with nothing said to the user. At the limit the task is set `Blocked` with a comment noting the reply may never have been read.
- Remove the entry from the registry regardless (window gone = worker dead)
- If the state is terminal (`done`, `won't do`) → the worker finished cleanly; reset the crash count and clean up

Crash cleanup kills `side-<slug>` and `pr-mon-<slug>` and removes the task's `.inbox`, `.seq`, `.launching`, `.seen-comments`, and `.seen-state` files.

The worker registry (`signals/workers`) is a line-oriented file maintained by the launcher:
```
# format: <task-slug> <tmux-window-name> <agent-type>
WORK-pm4 WORK-pm4 implementer
WORK-xyz WORK-xyz investigator
```

**Crash detection latency**: at most 60 seconds (two poll cycles).

### Folder Cleanup

**One instance.** Runs in the `orchestrator` session, window `folder-cleanup`. Pure bash, no Claude.

Responsibilities:
- Poll every 60 seconds for tasks in any terminal state (Done, Won't Do)
- For each, move its named subfolder from the task's parent folder into the adjacent `Done` folder
- Skip folders already under a `Done` folder (idempotent)

---

## tmux Layout

```
Session: orchestrator       ← daemons only; no user-interaction process
  window 0: watchdog        ← scripts/watchdog.sh (bash loop)
  window 1: folder-cleanup  ← scripts/folder-cleanup.sh (bash loop)
  window 2: launcher        ← scripts/launcher.py (Python daemon, restart loop)
  window N: side-WORK-xyz   ← scripts/sidecar.sh (bash loop, one per active worker)
  window N: pr-mon-WORK-xyz ← scripts/pr-monitor.sh (bash loop, one per PR-ready task)

Session: workers            ← Claude agents only
  window 0: WORK-pm4         ← /implementer skill (Claude Code, yolo mode)
  window N: WORK-abc         ← /designer skill — frontend/UI design tasks
  window N: WORK-def         ← /investigator skill — research/context-gathering tasks
  window N: WORK-ghi         ← /documenter skill — documentation tasks
  window N: WORK-jkl         ← /ticketer skill — Jira ticket creation tasks
  window N: WORK-mno         ← /skill-creator skill — creating/improving agentmesh skills
  window N: WORK-pqr         ← /rfc-creator skill — RFC/architecture proposal tasks
  ...
```

Keeping `workers` exclusively Claude agents is deliberate: the watchdog's window-liveness check and `agentmesh status` both read it that way.

`spawn-agent.sh` launches Claude **as the window's command** rather than typing it into a shell, so the window dies with the process. Window liveness is therefore a sound proxy for "the agent is running" — which both the watchdog and the launcher's adoption pass depend on. A shell-hosted window would outlive a dead Claude and make every task it held permanently unrecoverable.

---

## Skills

Skills live in `plugins/agentic-workflows/skills/` in this repo. Agents can read and improve them directly.

Skills inherit from a two-level base hierarchy:

```
shared/base-agent.md              ← NoteCove comment protocol (arg parsing, paths, post/await/read)
  └── shared/base-implementer.md  ← + folder management, exploration, questions, triage
        └── implementer, planner, brainstormer, designer, investigator,
            documenter, ticketer, skill-creator, rfc-creator
```

After editing a skill, bump the plugin version and reload it:

1. **Bump the version** in `plugins/agentic-workflows/.claude-plugin/plugin.json`.
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

**Adding a new agent type** requires three registrations, not one:
1. `TYPE_MAP` in `scripts/launcher.py` — NoteCove type → agent handle
2. `AGENT_AUTHOR` in `scripts/launcher.py` — agent handle → comment author name
3. `agent-user` in the skill's frontmatter — must equal the `AGENT_AUTHOR` value

A missing or mismatched `AGENT_AUTHOR` entry makes the agent wake itself on every comment it writes, which presents as a wakeup loop.

---

## Project Structure

```
agentmesh/
├── CLAUDE.md               # this file
├── scripts/
│   ├── bootstrap.sh        # runtime startup: notecove init, signals dir, watchdog + folder-cleanup + launcher
│   ├── launcher.py         # launcher daemon: Ready-task pickup, triage, worker + sidecar spawning
│   ├── sidecar.sh          # per-worker NoteCove watcher; nudges its agent on comments/state changes
│   ├── agent-notecove.sh   # sourced bash helper for agents: agent_init, post_summary, await_user, read_inbox
│   ├── watchdog.sh         # crash detector; re-queues tasks whose worker windows disappeared
│   ├── folder-cleanup.sh   # async folder housekeeping; moves Done/Won't-Do task subfolders to the Done folder
│   ├── pr-monitor.sh       # PR merge detector; writes the merge to the worker's inbox
│   ├── spawn-agent.sh      # launches a Claude agent in a new tmux window
│   ├── task-done.sh        # terminal-state cleanup, called by the worker via finish_task: unblocks dependents, stops sidecar/pr-monitor
│   ├── agentmesh.sh        # lifecycle CLI: start / stop / switch / status / attach / task
│   └── test_triage.py      # unit tests for launcher triage and the .launching guard
└── signals/                # runtime directory, created on bootstrap
    ├── workers             # worker registry; line per active worker: "<slug> <window-name> <agent-type>"
    ├── triage_folder       # Triage folder ID written by bootstrap.sh; read by agents
    ├── launcher.heartbeat  # UTC timestamp written by launcher.py after each completed scan; read by `agentmesh status`
    ├── events.log          # append-only TSV: timestamp, component, event_type, slug
    ├── <slug>.inbox            # line-delimited JSON; sidecar/pr-monitor write, agent reads and clears
    ├── <slug>.seq              # nudge sequence counter; written by the agent, read by the sidecar
    ├── <slug>.launching        # in-flight guard; written by launcher before spawn, cleared by the worker on claim
    ├── <slug>.untyped          # dedup flag so an untriageable task is commented on exactly once
    ├── <slug>.backoff          # sentinel while the watchdog sleeps out a crash backoff; adoption skips these
    ├── <slug>.sidecar-handle   # comment-author name the running sidecar filters on; checked before reusing it
    ├── <slug>.seen-comments    # sidecar baseline: comment IDs already reported
    ├── <slug>.seen-state       # sidecar baseline: last observed task state ID
    ├── <slug>.merged           # flag file written by pr-monitor when the PR is merged
    └── <slug>.crash-count      # consecutive crash counter; written by watchdog, reset on clean exit or bootstrap
```

The `signals/` directory and its contents are runtime artifacts — created fresh on each bootstrap.

### Event log format

`events.log` is a tab-separated file with four fields per line:

```
timestamp       component       event_type                      slug
2026-04-26T...  launcher        bootstrap-complete              -
2026-04-26T...  launcher        task-picked-up                  WORK-xyz
2026-04-26T...  launcher        implementer-spawned             WORK-xyz
2026-04-26T...  launcher        sidecar-spawned                 WORK-xyz
2026-04-26T...  launcher        task-refused-untyped            WORK-abc
2026-04-26T...  launcher        task-adopted:attention           WORK-xyz
2026-04-26T...  launcher        adoption-skipped-untyped         WORK-abc
2026-04-26T...  launcher        adoption-skipped-tmux-unavailable -
2026-04-26T...  launcher        sidecar-reconciled               WORK-xyz
2026-04-26T...  launcher        worker-reregistered              WORK-xyz
2026-04-26T...  launcher        implementer-spawn-failed         WORK-xyz
2026-04-26T...  launcher        launching-flag-expired          WORK-xyz
2026-04-26T...  sidecar         started                         WORK-xyz
2026-04-26T...  sidecar         sse-subscribed                  WORK-xyz
2026-04-26T...  sidecar         sse-unavailable:no-permission   WORK-xyz
2026-04-26T...  sidecar         change-detected:comments=1:state=0  WORK-xyz
2026-04-26T...  sidecar         nudge-fired:seq=3               WORK-xyz
2026-04-26T...  implementer     started                         WORK-xyz
2026-04-26T...  implementer     awaiting-user                   WORK-xyz
2026-04-26T...  implementer     resumed                         WORK-xyz
2026-04-26T...  watchdog        crash-detected                  WORK-xyz
2026-04-26T...  watchdog        worker-stranded-attention        WORK-xyz
2026-04-26T...  watchdog        backoff-aborted-adopted          WORK-xyz
2026-04-26T...  task-done       cleanup-complete                 WORK-xyz
2026-04-26T...  pr-monitor      pr-merged-detected              WORK-xyz
2026-04-26T...  folder-cleanup  folder-moved                    WORK-xyz
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

```bash
agentmesh start --project WORK
```

This bootstraps the daemons and returns. There is no user-interaction process to start — open NoteCove and comment on a task to talk to its agent.

**Full options:**

```
agentmesh start --project <key>
                [--profile <id>]
                [--max-workers <n>]        # default: 30
                [--poll-interval <secs>]   # default: 30 — Ready-task scan interval
```

**Other commands:**

```bash
agentmesh stop                    # graceful shutdown: kills all windows and the workers session
agentmesh status                  # health report: launcher heartbeat, daemons, workers, sidecars, SSE availability
agentmesh switch --project <key>  # switch projects, preserving running workers and their sidecars
agentmesh attach                  # attach to the orchestrator tmux session
agentmesh task create <title> \   # create a new task in NoteCove
  --project <key> \
  [--folder <name-or-id>] \
  [--priority <n>] \
  [--type <type>] \
  [--content <text>]
```

`agentmesh task create` wraps `notecove task create` with folder name resolution: pass a folder name (e.g. `Triage`) or folder ID directly to `--folder`.

> Set a **type** on every task. A task whose type does not map to an agent stays in `Ready` and the launcher comments once to say so — see the Launcher section above for the supported types.

### Verifying a healthy system

```bash
agentmesh status
```

```
launcher               ✓ running  (heartbeat: 4s ago)
watchdog               ✓ running
folder-cleanup         ✓ running
active workers         2  (WORK-abc,WORK-def)
sidecars               2
notecove events        ✓ available (push)
```

- **`sidecars` must equal `active workers`.** A worker whose sidecar has died is deaf to the user — it will block on `await_user` forever. `status` warns explicitly when they diverge.
- **`notecove events`** shows whether sidecars are waking on SSE push (sub-second) or on the 60-second safety-net poll. Both work; this tells you which.
- **`untyped tasks`** appears only when tasks have been refused for a missing or unmapped type.

---

## Recovery

Nothing needs doing by hand. `agentmesh stop` kills every worker, but the tasks they were on stay in `Doing` or `Attention`, and the launcher's **adoption pass** spawns a fresh worker + sidecar for each of them within one scan of the next `agentmesh start`.

```bash
agentmesh stop
agentmesh start --project WORK
grep task-adopted signals/events.log      # one line per recovered task
```

You do **not** need to set tasks back to `Ready`. Doing so would actually lose context: the respawned worker reads its task folder notes and the task's comments to pick up where the previous one left off, whereas re-queuing starts it over.

This covers every way a worker can disappear, not just a deliberate restart:

| Cause | Recovered by |
|---|---|
| `agentmesh stop` / `start`, machine reboot | Launcher adoption, next scan |
| Worker crash while `Doing` | Watchdog → back to `Ready` → normal pickup (with backoff, 3 attempts) |
| Worker reaped while `Attention` | Launcher adoption, next scan |
| Sidecar dies, worker still alive | Launcher sidecar reconciliation, next scan |
| Launcher restarts while workers survive | Reconciliation re-registers them |
| PR merged on GitHub instead of `approve` | `pr-monitor`, started by the agent via `watch_pr` |
| Launcher itself exits | Its `while true` restart loop in `bootstrap.sh`, after 5s |
| Three consecutive crashes | Not recovered — the task is set `Blocked` with an explanatory comment, deliberately |

The one thing adoption cannot recover is a task whose type no longer maps to an agent; it logs `adoption-skipped-untyped` and leaves the task alone, because there is no way to know which agent owned the work. Restore the type and the next scan picks it up.

---

## Migrating from the Spokesman architecture

The Spokesman-based architecture (plugin ≤ 2.x) is gone, not deprecated. The two cannot coexist — once a worker stops writing to `signals/queue`, the whole event layer is dead code.

```bash
agentmesh stop                      # kills every running agent
cd ~/agentmesh && git pull
claude plugin update agentic-workflows@agentmesh
agentmesh start --project WORK
```

On the first bootstrap, `notecove init --events` may raise an approval prompt in the NoteCove desktop app. Approving it enables push change detection; declining leaves sidecars on the 60-second poll, which is fully functional.

### What changed for the user

| Before | Now |
|---|---|
| Answer in the Spokesman terminal session | Comment on the task in NoteCove |
| `continue` / `spawn reviewer` / `approve` menu | Free text, plus reserved `approve` / `abort` |
| Orchestrator marked tasks `Done` | The agent sets `Done` itself after you `approve` |
| Untyped tasks were LLM-triaged by the Spokesman | Untyped tasks stay `Ready` and are commented on once |
| `--mode auto-review`, `--review-limit` | Removed — no reviewer agents |
| `--interface slack`, `--channel`, `--verbosity` | Removed — NoteCove only |
| `agentmesh pause-poller` / `resume-poller` | Removed with the Slack poller |

Nothing in `signals/` persists across a bootstrap, so there is no migration state to unwind — `bootstrap.sh` clears it on every start.

### Testing a branch before merging

The `agentmesh` plugin marketplace is a **local directory** pointing at `~/agentmesh/plugins`, and `~/bin/agentmesh` symlinks to `~/agentmesh/scripts/agentmesh.sh`. Both resolve to the **main worktree**.

Running daemons out of a feature worktree while the installed plugin still serves the old skills therefore gives you new daemons driving old agents, which block forever. Check the branch out in the main worktree instead:

```bash
agentmesh stop
cd ~/agentmesh
git fetch origin <branch>
git checkout --detach origin/<branch>    # detached: the branch is already checked out in its worktree
claude plugin update agentic-workflows@agentmesh
claude plugin list | grep -A1 'agentic-workflows@agentmesh'   # confirm the new version is live
agentmesh start --project WORK
```

Roll back with `git checkout main` and another `claude plugin update`.
