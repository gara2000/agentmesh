Parse arguments:
- `--task <slug>` — required, task slug assigned by the orchestrator (e.g. `WORK-42`)
- `--project <key>` — required, NoteCove project key

If either argument is missing, stop immediately.

---

## Paths (fixed)

```
QUEUE={{AGENTMESH}}/signals/queue
SEQ_FILE={{AGENTMESH}}/signals/<slug>.seq
LOG={{AGENTMESH}}/signals/events.log
SIGNAL_HELPER={{AGENTMESH}}/scripts/signal-agent.sh
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
LOG={{AGENTMESH}}/signals/events.log
source {{AGENTMESH}}/scripts/signal-agent.sh
signal_init "<slug>"
printf '%s\t{{LOG_PREFIX}}\tstarted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

---

## Shared Critical Rules

- **Always define `LOG=` and `source {{AGENTMESH}}/scripts/signal-agent.sh` + `signal_init <slug>`** at startup. Write `printf '%s\t{{LOG_PREFIX}}\t<event>\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, signaling-attention, resumed, implementing, pr-created, signaling-attention-pr-ready, approved/feedback-received).
- **Never interact with the user directly.**
- **Always add an `event:<type>` comment and set task state to `Attention` before calling `signal_attention`** — the orchestrator reads the last comment to dispatch on event type. See the "Events This Agent Fires" table above for the complete list for this agent.
- **Always use `signal_attention` (never inline signal blocks)** — `signal_attention` handles seq increment, queue write, `worker-any-event`, and the blocking loop internally.
- **Always use `timeout=600000`** on Bash calls that contain `signal_attention` — this maximizes time between spurious wakeups.
- **Never mark task Done** — only the orchestrator does that, after user approval.
- **Signal before exiting** — even on error, signal so the orchestrator can clean up.
