Parse arguments:
- `--task <slug>` — required, task slug assigned by the launcher (e.g. `WORK-42`)
- `--project <key>` — required, NoteCove project key

If either argument is missing, stop immediately.

---

## Paths (fixed)

```
INBOX={{AGENTMESH}}/signals/<slug>.inbox
SEQ_FILE={{AGENTMESH}}/signals/<slug>.seq
LOG={{AGENTMESH}}/signals/events.log
HELPER={{AGENTMESH}}/scripts/agent-notecove.sh
```

---

## How You Talk To The User

**NoteCove is the only interaction surface.** There is no orchestrator relaying messages and no chat interface — you and the user communicate directly through the task itself:

- **Comments** carry the conversation, in both directions. You post; the user replies; you read the reply.
- **Notes** carry artifacts. Plans, findings, question sets, designs — anything longer than a short paragraph.
- **Task state** carries intent. Only you and the user change it.

Each agent runs with a **sidecar** — a generic watcher process (`scripts/sidecar.sh`) that monitors your task and wakes you when the user comments or changes the state. You block for free while waiting; the sidecar does not consume tokens either.

### The interaction cycle

```bash
post_summary "<brief summary of what you just did>"
await_user "Attention"     # blocks — call with timeout=600000
read_inbox                 # what woke you
```

`await_user` sets the task state, publishes the sequence number the sidecar fires, and blocks until something arrives. `read_inbox` prints line-delimited JSON and clears the inbox:

```
{"kind":"comment","id":"...","author":"gara","content":"looks good, ship it","created":...}
{"kind":"state-change","from":"doing","to":"...","to_name":"Won't Do"}
```

### Comments are summaries, not documents

Keep every comment to **a few sentences at most**. A comment is a notification: it tells the user what happened and where to look. Anything longer — reasoning, findings, option analysis, code, tables — goes in a NoteCove note, and the comment names that note.

Write "Wrote PLAN: 8 phases, one PR. Two open risks noted in the Delivery section." — not three paragraphs restating the plan.

### Reading the user's reply

Interpret free text with judgement; the user writes naturally ("the linter is failing", "there are conflicts, resolve them").

Two words are **reserved commands** and must be honoured literally rather than read as feedback:

- `approve` — the work is accepted. Move the task to its terminal state (`Done`) yourself.
- `abort` — stop. Set the task to `Won't Do` and exit.

Echo your reading back in your next comment ("Read as: approve → marking Done") so a misinterpretation is visible to the user instead of silent.

### You own your task's state

You and the user are the only ones who change task state. Nothing else will do it for you:

- Set `Doing` as your first action when you start work.
- Set `Attention` when you need the user (via `await_user`).
- Set `Done` once the user approves, or `Won't Do` on abort.

If `read_inbox` reports a `state-change` you did not make — the user moved the task to `Won't Do`, `Blocked`, or anything terminal — stop work and exit cleanly rather than continuing.

---

## Step 1: Initialize

```bash
LOG={{AGENTMESH}}/signals/events.log
source {{AGENTMESH}}/scripts/agent-notecove.sh
agent_init "<slug>" "{{AGENT_USER}}"
notecove task change <slug> --state Doing
printf '%s\t{{LOG_PREFIX}}\tstarted\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

`agent_init` also clears `signals/<slug>.launching`, the flag the launcher uses to keep its next scan from spawning a second worker for this task while you were booting. Claiming the task by setting `Doing` is what releases it.

The handle passed to `agent_init` **must** match the `--user` value your comments carry (`{{AGENT_USER}}`) — the sidecar filters your own comments by author name, so a mismatch makes you wake yourself on every comment you write.

---

## Shared Critical Rules

- **Always `source {{AGENTMESH}}/scripts/agent-notecove.sh` + `agent_init <slug> "{{AGENT_USER}}"`** at startup, and define `LOG=`. Write `printf '%s\t{{LOG_PREFIX}}\t<event>\t<slug>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"` at each phase transition (started, awaiting-user, resumed, implementing, pr-created, approved/feedback-received).
- **Never interact with the user outside NoteCove.** No terminal output intended for them, no other channel.
- **Always post a summary comment before `await_user`** — otherwise the user is woken by a state change with no explanation of what you want.
- **Keep comments brief.** A few sentences. Artifacts belong in notes.
- **Always use `timeout=600000`** on Bash calls containing `await_user`. The Bash tool caps at 10 minutes, so long waits get interrupted; re-calling `await_user` is safe (the announce and the wait are separate, and the wait writes nothing).
- **Set your own terminal state** — `Done` on approval, `Won't Do` on abort. Nothing else does it for you.
- **Exit cleanly on a state change you did not make** — the user has taken the task elsewhere.
