# AgentMesh — Agentic Workflow

AgentMesh is a multi-agent orchestration system built on tmux and NoteCove. It picks up tasks from NoteCove and assigns them to autonomous worker agents.

**NoteCove is the only interaction surface between the user and the agents.** There is no chat interface, no relay process, and no interface layer. Each agent talks to the user directly through its task: comments carry the conversation, notes carry artifacts, task state carries intent.

---

## How It Works

### The interaction cycle

An agent that needs the user does three things:

1. **Posts a brief comment** summarising what it just did and what it needs.
2. **Sets the task to `Attention`** via `request_attention`.
3. **Ends its turn**, consuming no tokens until something arrives.

The user replies by commenting on the task in NoteCove — nothing else is required of them.

```
agent → comment + Attention → end of turn → user replies in NoteCove → sidecar → send-keys into the agent's REPL → agent
```

When the message lands the agent calls `resume_work` (back to `Doing`), reads its inbox, and carries on.

### Coordination Primitives

- **`tmux send-keys -t workers:<slug>`** — types a one-line nudge into the worker's Claude REPL and submits it
- **`signals/<slug>.inbox`** — append-only, line-delimited JSON; the sidecar (or pr-monitor) writes what changed, the agent reads and clears it
- **`signals/<slug>.ready`** — delivery gate; written by the agent's `agent_init`, so nothing is typed before the skill is running
- **`signals/<slug>.pending-delivery`** — retry sentinel; cleared only by a delivered nudge
- **`signals/<slug>.self-state`** — the state name the agent is about to set, so the sidecar can tell its own writes from the user's
- **`signals/<slug>.full-slug`** — the task's unambiguous full slug, written by the launcher at spawn time; every CLI call addressing the task reads it first
- **`signals/<slug>.task-id`** — the task's internal id, which is the only thing an SSE frame names
- **`scripts/notecove-ref.sh`** — the one safe way to call the NoteCove CLI with a slug; sourced by every daemon and by the agent helper
- **`scripts/notify-worker.sh`** — the one place that knows how to deliver; sourced by the sidecar and the pr-monitor
- **`scripts/sidecar.sh`** — one per worker; watches the task in NoteCove and nudges its agent on any change

### Slug identity

A task has two slugs. **`slug.short`** (`WORK-7jp`) is a *uniquePrefix* — unique only at the moment it is read. Creating another task sharing that prefix lengthens it, and every copy stored earlier silently becomes ambiguous. **`slug.full`** (`WORK-7jp:hatbqq77qtm4g4x76zz6de5`) never changes.

**Short slugs are local identifiers only** — tmux window names and `signals/` filenames. Renaming those would invalidate every running worker's state, so they stay. **Everything passed to the NoteCove CLI uses the full slug**, via `nc_ref` in `scripts/notecove-ref.sh`.

This matters because the CLI does not *fail* on an ambiguous slug. With stdin on a TTY it asks which task you meant:

```
Ambiguous slug. Multiple tasks match:
  1. work-7w25:…   2. work-7w2p:…
Pick one (1-2):
```

Every daemon runs in a tmux window, so every daemon has a TTY, so the call blocks until its timeout — every poll, forever. WORK-7w2's sidecar logged 43 consecutive `notecove-call-timed-out` events that way and never saw a comment in between.

Two defences, both in `notecove-ref.sh`:

- **`nc_run` closes stdin** on every call. The same ambiguous call then returns `rc=1` and "Please use a more specific slug." immediately. This converts a silent permanent hang into a loud fast failure, and it holds even when resolution has nothing to work with.
- **`nc_ref` resolves the short slug to the full one**, from `signals/<slug>.full-slug` (written by the launcher, which had the task JSON in hand anyway), or by listing tasks and caching the result. Two matches resolve to *nothing* rather than a guess — the distinguishing part was never recorded, and acting on the wrong task is worse than failing.

Agents get `$TASK_REF` from `agent_init` and must use it for any raw `notecove` call. In Python, `launcher.py` passes `stdin=subprocess.DEVNULL` on every CLI invocation for the same reason.

### Delivery Protocol

| Mechanism | Direction | Trigger |
|---|---|---|
| `tmux send-keys` into `workers:<slug>` | Sidecar → Agent | A new comment (not the agent's own) or a state change the agent did not make |
| `tmux send-keys` into `workers:<slug>` | PR Monitor → Agent | The agent's PR was merged |

**Why messages and not `tmux wait-for`.** The old protocol fired `<slug>-nudge-<seq>` at an agent blocked inside `tmux wait-for`. That could only ever reach an agent *already waiting*: anything the user said while the agent was working went unseen until the agent next chose to wait — which, mid-implementation, could be many minutes or never. Typing into the REPL reaches the agent in both states. Idle at its prompt it starts a new turn; mid-turn, Claude Code queues the input and picks it up when the current turn ends.

The agent therefore **does not block at all**. `request_attention` announces and returns; the turn ends there. The reply arrives as a fresh turn, which also removes the 10-minute Bash-tool cap that used to interrupt every real wait.

**What is delivered is a bare one-line nudge**, not the user's text. The payload stays in the inbox — comment bodies are multi-line human free text and must never be typed into a REPL. The nudge names the helper to source, because an agent woken after a long gap may have lost all shell state.

Delivery can fail in ways a fire-and-forget signal could not, so `notify-worker.sh` writes `.pending-delivery` before every attempt and clears it only on success. The sidecar retries any outstanding delivery once per poll. It never types blind: both the worker window and `.ready` must be present, and a `tmux` that cannot be queried at all is read as "not ready" rather than "the window is there".

### Inbox Format

The sidecar appends one JSON object per line to `signals/<slug>.inbox`:

```json
{"kind":"comment","id":"CDpiRX…","author":"gara","content":"looks good, ship it","created":1792062799252}
{"kind":"state-change","from":"doing","to":"…","to_name":"Won't Do"}
{"kind":"pr-merged","url":"https://github.com/foo/bar/pull/1","note":"PR was merged. Set the task to Done."}
```

The agent reads the inbox rather than re-fetching and re-diffing the task itself.

### Why the inbox and not just the message

The nudge carries no payload, so the inbox is the whole message. Separating them is what keeps the sidecar generic and the REPL safe: the sidecar writes arbitrary user text to a file and types a fixed line, rather than typing user text into a shell.

It also makes the nudge **idempotent and safe to duplicate**. A second nudge for a change the agent has already drained finds an empty inbox, and an empty `read_inbox` is defined as "nothing new, carry on" rather than an error. That is what lets the retry loop and the SSE/poll overlap both fire freely without coordination.

### Task State

Task state is owned by **the worker agent and the user — nothing else.**

| NoteCove Task State | Set by | Meaning |
|---|---|---|
| `Ready` | User | Available for pickup. The launcher reads it but never writes it. |
| `Doing` | Worker | A worker is working on this right now. Set on booting, and again at the top of every turn that resumes work. |
| `Attention` | Worker | The worker is finished for now and the user has the task. |
| `Done` | Worker via `finish_task` (after the user approves) or User | Work accepted. |
| `Won't Do` | Worker via `finish_task` (on `abort`) or User | Work abandoned. |
| `Blocked` | Watchdog (crash limit) or User | Needs investigation. |

The watchdog setting `Ready`/`Blocked` on a crash is the one exception: a crashed worker cannot set its own state, and the alternative is a task stuck in `Doing` with nothing running.

**`Doing` and `Attention` alternate for the life of the task.** The agent is not in `Attention` while it works — a task left there misreports both what the agent is doing and whether the user is expected to act. Every working turn opens with `resume_work` and every hand-back closes with `request_attention`, however many rounds that takes.

**Agents change state only through `resume_work` / `request_attention` / `finish_task`, never a bare `notecove task change --state`.** All three go through `set_state`, which writes the state name to `signals/<slug>.self-state` *before* calling the CLI. That marker is how the sidecar tells "I moved this" from "the user moved this" — it compares the task's `stateName` against the marker and suppresses a match. Writing it first closes the race: there is no window in which the sidecar can observe the new state without also seeing the marker. Without it, an agent's own `Doing`/`Attention` writes come straight back as a message and interrupt it mid-work — harmless under the old blocking protocol, a self-inflicted interruption under this one. The marker is consumed once the sidecar's baseline has absorbed the state it names, so it cannot later swallow a genuine user move to that same state.

### The task folder link

Every task gets a folder named after it, holding that task's notes, and the folder is linked from the task description as `[[F:<folder-id>|<folder-path>]]`. Agents create both through one helper, **`ensure_task_folder`** in `agent-notecove.sh`. It takes no arguments: the parent folder and the folder name come from the task itself.

This was previously a ~20-line recipe pasted into all nine implementer-family skills, which each agent retyped by hand with `<slug>`, `<folder-id>` and `<folder-path>` substituted in. **It destroyed task descriptions.** The shape was:

```bash
EXISTING_DESC=$(notecove task show <slug> --format markdown | …split on "Description:"…)
if [ -n "$EXISTING_DESC" ]; then  …prepend the link…
else  notecove task change <slug> --content "[[F:…]]"   # replaces the whole description
fi
```

`EXISTING_DESC` is empty for two unrelated reasons — *the description really is empty* and *the read failed* — and both took the destructive branch. The read fails on an ambiguous short slug (the recipe used `<slug>`, not `$TASK_REF`, so the CLI prompted on the worker's TTY and hung to timeout), on any CLI error, and whenever NoteCove is not running. A description holding a table and two paragraphs came back as nothing but the link. Nothing verified the write either, so a failed one left the agent believing the folder was linked — the other half of the same report.

The helper's rules, in order of importance:

- **Never write on a failed read.** Any CLI failure aborts; it does not fall through to "the description must have been empty".
- **Decide emptiness from the stored content**, read via `task show --json` → `contentJson.content`, not from a text parse. An empty NoteCove description is `<paragraph></paragraph>`, not `""`.
- **Refuse a write the parse cannot justify.** Stored content present but the markdown parse empty means the parse is wrong, not the task.
- **Back up first**, to `signals/<slug>.description-backup`.
- **Verify afterwards** — the link must be present and the content must not have shrunk.
- **Be idempotent.** A description already carrying a `[[F:…]]` link is left untouched and its id exported, so a restarted worker simply calls it again.

One trap it encodes: `--content-file -` must never be used through `nc_run`, which closes stdin — the CLI then reads nothing and writes an **empty** description. The helper writes to a temp file and passes a real path.

### Comment Conventions

- **Comments are summaries, not documents.** A few sentences at most — a comment tells the user what happened and where to look. Anything longer goes in a NoteCove note that the comment names.
- **NoteCove rejects a comment body over 996 characters** with `rc=1` and no output at all. `post_summary` truncates at 900 and appends a marker rather than letting one vanish — a dropped summary leaves the user staring at a task in `Attention` with no idea what is wanted, which is indistinguishable from a wedged agent.
- **Every round of work owes the user a comment.** `resume_work` clears `signals/<slug>.summary-posted`; `request_attention`, `finish_task` and `finish_cleanup` check it and post a generic placeholder if the agent wrote nothing. The placeholder is the visible symptom of a skipped summary, not a substitute for one.
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

A sidecar is the only thing that delivers the user's replies into a worker's REPL, so a worker whose sidecar died sits in `Attention` forever — silently, because its own window is still alive and its last turn ended normally. Adoption cannot cover this: it skips any slug with a live worker window, which is exactly this case.

The launcher therefore reconciles before adopting. For each live worker window it spawns a sidecar if `side-<slug>` is missing, and re-registers the worker if `signals/workers` has no entry for it (which happens whenever `bootstrap.sh` truncates the registry while workers survive — otherwise they stay invisible to the watchdog and uncounted against `max-workers`).

### Sidecar

**One instance per active worker.** Runs in the `orchestrator` session, window `side-<slug>`. Pure bash, no Claude.

The sidecar is **completely generic** — it carries no task-type knowledge. It never interprets comment content, never changes task state, and never decides what a change means. It reports "this changed" and wakes the agent; the agent, which already knows its own type because it is running a type-specific skill, decides what to do. Its only parameter beyond the slug is `--agent-handle`, the comment author name it treats as "mine".

Responsibilities:
- Establish a baseline of comment IDs and task state at startup (pre-existing comments are history, not replayed at the agent)
- Detect changes two ways, both funnelling into one diff step:
  - **SSE push** — subscribe to `notecove events --types "task.*"` and run the diff on any frame whose `item.id` is this task's id
  - **Safety-net poll** — run the same diff every `--poll-interval` seconds (default 60)
- On a change, append to `signals/<slug>.inbox` and deliver a nudge via `notify-worker.sh`
- Retry any outstanding `.pending-delivery` on every poll

**Two filters keep an agent from waking itself.** New comments authored by `--agent-handle` are ignored, and a state change matching `signals/<slug>.self-state` is suppressed — see the Task State section above. Both are the same rule: the sidecar reports what *others* did to the task.

**Frames are matched on `item.id`, not on the slug.** A frame carries no slug at all:

```json
{"id":"…","type":"task.modified","item":{"type":"task","id":"7jphatbqq77qtm4g4x76zz6de5"},"payload":{"projectId":"…"},"seq":41}
```

The original check was `grep -qF "$SLUG"` on the raw frame, on the belief that an id-only frame would still match as a substring. It cannot: the short slug carries a project prefix and a hyphen the id does not (`WORK-7jp` vs `7jphatbqq77qtm4g4x76zz6de5`). That grep never matched once, so SSE triggered no diff from the day the sidecar was written and the poll was silently the only detection path. The sidecar now resolves its task id via `nc_task_id` at subscribe time and parses each frame; if the id cannot be resolved it logs `task-id-unresolved` and stays poll-only rather than subscribing to a stream it could not match.

The poll runs **always**, not only when SSE is unavailable. The documented NoteCove event types (`task.created`, `task.modified`, `task.deleted`) include nothing comment-specific, so whether adding a comment emits a frame is an inference; the poll makes correctness independent of it. Duplicate triggers are harmless — the diff is against stored baseline state, so a change is reported exactly once however many times the check runs.

SSE requires the `events:subscribe` permission, requested by `bootstrap.sh` via `notecove init --events`. Until it is granted the sidecar logs `sse-unavailable:no-permission` and relies on the poll; `agentmesh status` reports which mode is in effect.

The `side-<slug>` window is **not** registered in `signals/workers` — it is not a worker, and registering it would make the watchdog treat its exit as a task crash. It is killed explicitly by the watchdog on crash cleanup and by `agentmesh stop`.

### PR Monitor

**One instance per active PR-ready task.** Runs in the `orchestrator` session, window `pr-mon-<slug>`. Pure bash, no Claude.

Responsibilities:
- Poll `gh pr view <pr-url>` every 60 seconds
- When the PR state is `MERGED`: write `signals/<slug>.merged`, append a `pr-merged` entry to the worker's inbox, deliver the nudge, and exit

It will not exit on an undelivered nudge: unlike the sidecar it has no further poll to retry from, so it retries for up to ten cycles itself and logs `merge-nudge-undelivered` if the worker never became reachable.

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
- If the window is gone and the task is in `attention` → **stranded, not finished**: the task is mid-conversation with the user and its worker is gone. Deregister it (so it is not re-reported every poll) but leave its sidecar and inbox intact — the launcher's adoption pass will spawn a fresh worker, and a pending user reply sitting in the inbox has to survive until that worker reads it. **This path still counts crashes**: adoption respawns every 30s, so a worker that reproducibly dies right after `request_attention` would otherwise loop forever with nothing said to the user. At the limit the task is set `Blocked` with a comment noting the reply may never have been read.
- Remove the entry from the registry regardless (window gone = worker dead)
- If the state is terminal (`done`, `won't do`) → the worker finished cleanly; reset the crash count and clean up

Crash cleanup kills `side-<slug>` and `pr-mon-<slug>` and removes the task's `.inbox`, `.ready`, `.pending-delivery`, `.self-state`, `.launching`, `.seen-comments`, `.seen-state`, `.full-slug`, `.task-id`, and `.summary-posted` files.

The worker registry (`signals/workers`) is a line-oriented file maintained by the launcher:
```
# format: <task-slug> <tmux-window-name> <agent-type> [<full-slug>]
WORK-pm4 WORK-pm4 implementer WORK-pm4:fg9k2m4x76zz6de5hatbq
WORK-xyz WORK-xyz investigator
```

The 4th field is optional and the launcher omits it when the full slug is not
known; every reader already tolerates the 3-field form.

**Crash detection latency**: at most 60 seconds (two poll cycles).

### Folder Cleanup

**One instance.** Runs in the `orchestrator` session, window `folder-cleanup`. Pure bash, no Claude.

Responsibilities:
- Poll every 60 seconds for tasks in any terminal state (Done, Won't Do)
- For each, move its named subfolder from the task's parent folder into the adjacent `Done` folder
- Skip folders already under a `Done` folder (idempotent)

### Reaper

**One instance.** Runs in the `orchestrator` session, window `reaper`. Pure bash, no Claude.

Its job is the one thing nothing else in the system does: **kill a worker whose task has finished.**

A worker does not exit on its own. `spawn-agent.sh` launches the interactive Claude REPL, so when the skill's final turn ends Claude returns to its prompt and idles there indefinitely. `task-done.sh` deliberately leaves the worker window alone — the worker is the process running that script, so killing it there would abort the cleanup mid-run — and the watchdog only ever looks at windows that are *already* gone. Until the reaper existed, the only thing that collected a finished worker was `agentmesh stop`.

That had two costs. Every completed task leaked a Claude process against `max-workers`, and a task reopened from `Done` could never be picked up again: its window name was still taken, so `spawn-agent.sh` refused the respawn and the launcher skipped the slug as "already live".

Responsibilities, every `--poll-interval` seconds (default 30):
- Build the **candidate set**: live `workers` windows, the slugs behind any `side-*`/`pr-mon-*` window, and every slug still in `signals/workers`
- Ask NoteCove for each candidate's state and branch on **`isTerminal`**
- On the first terminal sighting, write `signals/<slug>.terminal-since` and defer
- Once that file is `--grace` seconds old (default 60), kill `workers:<slug>`, `side-<slug>` and `pr-mon-<slug>`, drop the registry line, and remove the task's signal files

It never changes task state and never comments. It only tears down.

**Why a grace period.** A worker sets `Done` and *then* runs `task-done.sh`, which retries dependent-unblocking up to three times with sleeps in between. Reaping on sight would kill it mid-cleanup and leave the dependents blocked forever. The delay also covers the user who closes a task and immediately reopens it: a candidate that is no longer terminal has its `.terminal-since` deleted and is logged as `reap-cancelled-reopened`.

**Why candidate-driven rather than task-driven.** Listing every terminal task in the project would hit the NoteCove CLI's default page size and silently miss anything past it. The only slugs that can possibly need reaping are those with something still running or registered — at most `max-workers` of them.

**It never reaps on absence of evidence.** A NoteCove call that fails or times out is skipped, not read as terminal. If `tmux` cannot be queried at all the entire pass is abandoned and logged as `reap-skipped-tmux-unavailable` — treating an unanswerable tmux as "no windows exist" would reap every tracked task at once. Telling "that session does not exist" apart from "tmux is not answering" needs `tmux list-sessions` to succeed; `has-session` alone fails in both cases.

Being a separate process is the whole point: the reaper is not the thing being killed, so it works whether or not the worker cooperated, noticed its own state change, or is wedged.

```bash
bash scripts/reaper.sh --once --dry-run   # report what would be reaped, kill nothing
```

---

## tmux Layout

```
Session: orchestrator       ← daemons only; no user-interaction process
  window 0: watchdog        ← scripts/watchdog.sh (bash loop)
  window 1: folder-cleanup  ← scripts/folder-cleanup.sh (bash loop)
  window 2: reaper          ← scripts/reaper.sh (bash loop)
  window 3: launcher        ← scripts/launcher.py (Python daemon, restart loop)
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

**The same rule applies to the daemons.** `bootstrap.sh` and `agentmesh switch` pass each daemon's command to `tmux new-window` instead of `send-keys`-ing it into a shell, for exactly the reason above: the window must die with the process. Under the old `send-keys` form a crashed watchdog left a live `watchdog` window running zsh, so `agentmesh status` reported it healthy and no re-run of `bootstrap.sh` could ever notice it was gone.

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
│   ├── bootstrap.sh        # idempotent runtime startup: notecove init, signals dir, watchdog + folder-cleanup + reaper + launcher
│   ├── launcher.py         # launcher daemon: Ready-task pickup, triage, worker + sidecar spawning
│   ├── notecove-ref.sh     # the one safe way to call the NoteCove CLI with a slug: stdin closed, short slug resolved to full
│   ├── sidecar.sh          # per-worker NoteCove watcher; nudges its agent on comments/state changes
│   ├── notify-worker.sh    # delivery: types a one-line nudge into a worker's Claude REPL; sourced by sidecar + pr-monitor
│   ├── agent-notecove.sh   # sourced bash helper for agents: agent_init, resume_work, post_summary, request_attention, read_inbox, ensure_task_folder
│   ├── watchdog.sh         # crash detector; re-queues tasks whose worker windows disappeared
│   ├── folder-cleanup.sh   # async folder housekeeping; moves Done/Won't-Do task subfolders to the Done folder
│   ├── reaper.sh           # kills the worker, sidecar and pr-monitor of any task that has reached a terminal state
│   ├── pr-monitor.sh       # PR merge detector; writes the merge to the worker's inbox
│   ├── spawn-agent.sh      # launches a Claude agent in a new tmux window
│   ├── task-done.sh        # terminal-state cleanup, called by the worker via finish_task: unblocks dependents, stops sidecar/pr-monitor
│   ├── agentmesh.sh        # lifecycle CLI: start / stop / switch / status / attach / task
│   ├── test_triage.py      # unit tests for launcher triage and the .launching guard
│   ├── test_reaper.py      # unit tests for reaper.sh, driven with --once against stub tmux/notecove
│   ├── test_bootstrap.py   # unit tests for idempotent start: cold vs warm, daemon revival, wedged launcher
│   ├── test_notify_worker.py # unit tests for nudge delivery: the .ready gate, retry sentinel, what gets typed
│   ├── test_sidecar_diff.py  # unit tests for the sidecar's diff step: comment-author/self-state filtering, SSE frame matching
│   ├── test_slug_resolution.py # unit tests for notecove-ref.sh: stdin closure, full-slug resolution, refusal to guess
│   ├── test_agent_notecove.py  # unit tests for the agent helper: TASK_REF addressing, the summary guarantee
│   ├── test_task_folder_link.py # unit tests for ensure_task_folder: never writing on a failed read, idempotence, verification
│   └── test_task_done.py       # unit tests for task-done.sh: dependent unblocking by full slug, cleanup
└── signals/                # runtime directory, created on bootstrap
    ├── workers             # worker registry; line per active worker: "<slug> <window-name> <agent-type>"
    ├── triage_folder       # Triage folder ID written by bootstrap.sh; read by agents
    ├── launcher.heartbeat  # UTC timestamp written by launcher.py after each completed scan; read by `agentmesh status`
    ├── events.log          # append-only TSV: timestamp, component, event_type, slug
    ├── <slug>.inbox            # line-delimited JSON; sidecar/pr-monitor write, agent reads and clears
    ├── <slug>.ready            # delivery gate; touched by the worker's agent_init once its skill is running
    ├── <slug>.pending-delivery # retry sentinel; written before every nudge, cleared only by a delivered one
    ├── <slug>.self-state       # state name the agent is about to set, so the sidecar suppresses its own write
    ├── <slug>.launching        # in-flight guard; written by launcher before spawn, cleared by the worker on claim
    ├── <slug>.untyped          # dedup flag so an untriageable task is commented on exactly once
    ├── <slug>.backoff          # sentinel while the watchdog sleeps out a crash backoff; adoption skips these
    ├── <slug>.sidecar-handle   # comment-author name the running sidecar filters on; checked before reusing it
    ├── <slug>.seen-comments    # sidecar baseline: comment IDs already reported
    ├── <slug>.seen-state       # sidecar baseline: last observed task state ID
    ├── <slug>.merged           # flag file written by pr-monitor when the PR is merged
    ├── <slug>.crash-count      # consecutive crash counter; written by watchdog, reset on clean exit or bootstrap
    ├── <slug>.terminal-since   # reaper: first time the task was seen terminal; deleted if it is reopened
    ├── <slug>.full-slug        # the task's unambiguous full slug; written by the launcher at spawn, read by every CLI call
    ├── <slug>.task-id          # the task's internal id; what an SSE frame names, so what the sidecar matches on
    ├── <slug>.summary-posted   # set by a successful post_summary, cleared by resume_work; the per-turn summary guarantee
    └── <slug>.description-backup # the task description as it was before ensure_task_folder prepended the folder link
```

The `signals/` directory and its contents are runtime artifacts. They are wiped on a **cold** bootstrap — one where nothing is running — and deliberately left alone on a warm one, so `agentmesh start` can repair a live system without discarding the reply a waiting worker has yet to read. `agentmesh start --clean` forces the wipe.

### Event log format

`events.log` is a tab-separated file with four fields per line:

```
timestamp       component       event_type                      slug
2026-04-26T...  launcher        bootstrap-complete              -
2026-04-26T...  launcher        cold-start-reset                 -
2026-04-26T...  launcher        warm-start-ensure                -
2026-04-26T...  launcher        daemon-started:reaper            -
2026-04-26T...  launcher        launcher-wedged-restarting       -
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
2026-04-26T...  sidecar         sse-frame-matched                WORK-xyz
2026-04-26T...  sidecar         sse-reconnecting                 WORK-xyz
2026-04-26T...  sidecar         task-id-unresolved               WORK-xyz
2026-04-26T...  sidecar         slug-unresolved                  WORK-xyz
2026-04-26T...  sidecar         sse-unavailable:no-permission   WORK-xyz
2026-04-26T...  sidecar         change-detected:comments=1:state=0  WORK-xyz
2026-04-26T...  sidecar         notecove-call-timed-out          WORK-xyz
2026-04-26T...  notify-worker   nudge-delivered                 WORK-xyz
2026-04-26T...  notify-worker   delivery-deferred-not-ready      WORK-xyz
2026-04-26T...  notify-worker   delivery-failed-send             WORK-xyz
2026-04-26T...  notify-worker   delivery-failed-submit           WORK-xyz
2026-04-26T...  implementer     started                         WORK-xyz
2026-04-26T...  implementer     awaiting-user                   WORK-xyz
2026-04-26T...  implementer     resumed                         WORK-xyz
2026-04-26T...  agent           summary-truncated                WORK-xyz
2026-04-26T...  agent           summary-post-failed              WORK-xyz
2026-04-26T...  agent           summary-fallback                 WORK-xyz
2026-04-26T...  agent           task-folder-linked               WORK-xyz
2026-04-26T...  agent           task-folder-aborted-read         WORK-xyz
2026-04-26T...  agent           task-folder-aborted-parse        WORK-xyz
2026-04-26T...  agent           task-folder-create-failed        WORK-xyz
2026-04-26T...  agent           task-folder-link-failed          WORK-xyz
2026-04-26T...  agent           task-folder-verify-failed        WORK-xyz
2026-04-26T...  watchdog        crash-detected                  WORK-xyz
2026-04-26T...  watchdog        worker-stranded-attention        WORK-xyz
2026-04-26T...  watchdog        backoff-aborted-adopted          WORK-xyz
2026-04-26T...  task-done       cleanup-complete                 WORK-xyz
2026-04-26T...  pr-monitor      pr-merged-detected              WORK-xyz
2026-04-26T...  pr-monitor      merge-nudge-undelivered          WORK-xyz
2026-04-26T...  folder-cleanup  folder-moved                    WORK-xyz
2026-04-26T...  reaper          started                          -
2026-04-26T...  reaper          reap-deferred-grace              WORK-xyz
2026-04-26T...  reaper          reap-cancelled-reopened          WORK-xyz
2026-04-26T...  reaper          worker-reaped                    WORK-xyz
2026-04-26T...  reaper          reap-dry-run                     WORK-xyz
2026-04-26T...  reaper          reap-skipped-tmux-unavailable    -
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
                [--clean]                  # force the full runtime reset
```

### `start` is also `repair`

**`agentmesh start` is idempotent and safe to run against a live system.** It creates whatever is missing and touches nothing that is already there — no worker is killed, no sidecar restarted, no inbox cleared. Run it to bring back a daemon that died, or to pick up a newly added one:

```bash
agentmesh start --project WORK      # reaper window gone? it comes back. Workers keep running.
```

This is the only way to do that. `agentmesh stop && agentmesh start` would work too, but it destroys every running worker — and while adoption respawns them, each one starts over from its notes and comments.

What "idempotent" means concretely:

- **The destructive init runs only on a cold start** — one where nothing is running. On a warm start, truncating `signals/workers` would hide live workers from the watchdog, and deleting `*.inbox` would throw away the reply a worker in `Attention` has yet to read — and deleting `*.ready` would shut the delivery gate on a worker whose skill is already running, so the next reply is recorded but never typed to it. A sidecar that outlived such a wipe is worse still: with its baseline files gone, its next diff computes `first_run=true`, absorbs the pending reply into history, and never writes it to the inbox.
- **The liveness test errs towards "live".** A non-empty registry, *or* a surviving `side-*`/`pr-mon-*` window, *or* a `claude` pane in the `workers` session is enough. Wrongly skipping the wipe costs a few stale files; wrongly running it loses work.
- **Daemons are spawned only if their window is absent**, and as the window's command — see the tmux Layout note above for why that makes the check trustworthy.
- **The launcher is the exception**, because its window can be up while it is wedged. Its heartbeat measures exactly that (it is stamped after each *completed scan*), so a launcher window with a heartbeat older than 90s is replaced; a healthy one is left strictly alone.
- **The heartbeat is never pre-stamped**, not by `bootstrap.sh` and not by `switch`. Stamping on spawn makes a launcher that dies on startup — a bad `--project`, say — report healthy for a full minute.

`--clean` forces the reset on a live system. Use it when you actually want a blank slate.

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
reaper                 ✓ running
active workers         2  (WORK-abc,WORK-def)
sidecars               2
notecove events        ✓ available (push)
```

- **Any `✗ not running` daemon is fixed by `agentmesh start`** — no stop required.

- **`sidecars` must equal `active workers`.** A worker whose sidecar has died is deaf to the user — nothing will ever type the user's reply into its REPL, so it sits in `Attention` indefinitely. `status` warns explicitly when they diverge.
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
| Worker killed while `Attention` | Launcher adoption, next scan |
| Sidecar dies, worker still alive | Launcher sidecar reconciliation, next scan |
| A nudge could not be delivered (worker mid-boot, tmux unreachable) | `.pending-delivery`, retried from the sidecar's poll loop |
| Launcher restarts while workers survive | Reconciliation re-registers them |
| PR merged on GitHub instead of `approve` | `pr-monitor`, started by the agent via `watch_pr` |
| Launcher itself exits | Its `while true` restart loop in `bootstrap.sh`, after 5s |
| Launcher up but wedged (stale heartbeat) | `agentmesh start` replaces it; no stop needed |
| A daemon window killed or never started | `agentmesh start` respawns it, workers untouched |
| Worker idling after its task finished | Reaper, within `--grace` + one poll |
| Task reopened from `Done`, old window still holding the name | Reaper frees the name, then normal pickup |
| Three consecutive crashes | Not recovered — the task is set `Blocked` with an explanatory comment, deliberately |

The one thing adoption cannot recover is a task whose type no longer maps to an agent; it logs `adoption-skipped-untyped` and leaves the task alone, because there is no way to know which agent owned the work. Restore the type and the next scan picks it up.

---

## Upgrading across the signal → message change (plugin 3.5.0)

Daemons and skills have to cross this change together. A pre-3.5.0 worker blocks inside `tmux wait-for` for a signal no sidecar fires any more; a 3.5.0 worker ends its turn expecting a message an old sidecar never types. Either mismatch leaves the task silently stalled in `Attention`.

So this one is a full restart, not a repair:

```bash
agentmesh stop                      # every worker; adoption brings their tasks back
cd ~/agentmesh && git pull
claude plugin update agentic-workflows@agentmesh
agentmesh start --project WORK
```

Adoption respawns every in-flight task on the new skills within one scan. `await_user` survives as a deprecated alias of `request_attention` — it announces and returns rather than blocking — so a worker that somehow boots on old skill text degrades to "ends its turn early" instead of hanging forever.

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
