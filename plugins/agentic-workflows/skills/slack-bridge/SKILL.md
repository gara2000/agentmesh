---
name: slack-bridge
description: Full Spokesman peer for AgentMesh that communicates via Slack instead of a tmux terminal. Receives worker events via slackbridge-queue, posts to Slack threads via the Slack MCP, and translates Slack replies into orchestrator commands.
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, mkdir *, cat *, echo *, rm *, bash *, sleep *, sed *, python3 *), mcp__slack__*
hint: "Run the AgentMesh SlackBridge (Slack user-interaction layer). Required: --project <key>, --channel <slack-channel-id>. Optional: --verbosity low|medium|high (default: medium)"
---

# SlackBridge — AgentMesh Slack Interface Layer

**Arguments:** $ARGUMENTS

Parse arguments:
- `--project <key>` — required, NoteCove project key (e.g. `WORK`)
- `--channel <channel-id>` — required, Slack channel ID where agentmesh posts messages
- `--verbosity <level>` — optional, one of `low`, `medium`, `high`, defaults to `medium`

If `--project` or `--channel` is not provided, stop immediately.

---

## Paths (fixed)

```
AGENTMESH=~/agentmesh
SLACKBRIDGE_QUEUE=~/agentmesh/signals/slackbridge-queue
ORCHESTRATOR_CMDS=~/agentmesh/signals/orchestrator-cmds
LOG=~/agentmesh/signals/events.log
VERBOSITY_FILE=~/agentmesh/signals/slack-verbosity
CHANNEL_FILE=~/agentmesh/signals/slack-channel
```

### `send_cmd` helper

Define once at startup:

```bash
send_cmd() {
  local slug="$1" cmd="$2"
  if [ -n "${3:-}" ]; then
    echo "${slug}|${cmd}|$3" >> ~/agentmesh/signals/orchestrator-cmds
  else
    echo "${slug}|${cmd}" >> ~/agentmesh/signals/orchestrator-cmds
  fi
  tmux wait-for -S orchestrator-cmd-event
}
```

---

## Phase 0: Startup

### 0a. Register in active-interfaces

```bash
echo "slack-bridge" >> ~/agentmesh/signals/active-interfaces
```

### 0b. Write runtime state files

```bash
echo "<verbosity-level>" > ~/agentmesh/signals/slack-verbosity
echo "<channel-id>" > ~/agentmesh/signals/slack-channel
```

### 0c. Startup recovery

Query NoteCove for tasks in `Attention` state. For each, if `signals/<slug>.slack-thread` does NOT exist, post a new thread header and store the `thread_ts` in `signals/<slug>.slack-thread`:

```bash
_attention_slugs=$(notecove task list --project <PROJECT> --state Attention --json | \
  python3 -c "import sys,json; [print(t['slug']['short']) for t in json.load(sys.stdin)]" 2>/dev/null || echo "")

for _slug in $_attention_slugs; do
  if [ ! -f ~/agentmesh/signals/${_slug}.slack-thread ]; then
    # Post a recovery header thread
    _task_json=$(notecove task show "$_slug" --json)
    _title=$(echo "$_task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))")
    # Use Slack MCP to post to channel; store returned thread_ts
    # (post_message tool returns the ts of the posted message, used as thread_ts)
    _last_event=$(notecove task show "$_slug" --format markdown-with-comments | \
      grep "^- " | grep -oP 'event:\S+' | tail -1 2>/dev/null || echo "unknown")
    # post header message via Slack MCP (post_message to channel)
    # store thread_ts into signals/<slug>.slack-thread
  fi
done
```

### 0d. Post startup message

Post to the configured channel via Slack MCP:
```
agentmesh SlackBridge is running. Project: {PROJECT}. Verbosity: {VERBOSITY}.
```

---

## Phase 1: Event Loop

Each iteration:

### 1a. Block on slackbridge-event

```bash
SLACKBRIDGE_QUEUE=~/agentmesh/signals/slackbridge-queue
VERBOSITY=$(cat ~/agentmesh/signals/slack-verbosity 2>/dev/null || echo "medium")
LOG=~/agentmesh/signals/events.log

if [ ! -s "$SLACKBRIDGE_QUEUE" ]; then
  tmux wait-for slackbridge-event
fi
```

### 1b. Drain slackbridge-queue

```bash
while [ -s "$SLACKBRIDGE_QUEUE" ]; do
  TMP_QUEUE="${SLACKBRIDGE_QUEUE}.draining"
  mv "$SLACKBRIDGE_QUEUE" "$TMP_QUEUE" 2>/dev/null || break
  entries=$(cat "$TMP_QUEUE")
  rm -f "$TMP_QUEUE"

  for entry in $entries; do
    slug=$(echo "$entry" | cut -d: -f1)
    event_rest=$(echo "$entry" | cut -d: -f2-)
    # dispatch to handler
  done
done
```

### 1c. Dispatch events

Fetch task info for each slug:
```bash
task_json=$(notecove task show <slug> --json)
title=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))")
```

Dispatch on event type:

```
case "$event_rest" in
  event:task-ready)          → LLM triage, write spawn command to orchestrator-cmds (no Slack post)
  event:completion)          → post completion message (medium+), auto-ack
  event:questions)           → post questions thread (all verbosity levels)
  event:plan-ready)          → post plan-ready thread (all verbosity levels)
  event:plan-revised)        → same as plan-ready
  event:pr-submitted:*)      → post PR submitted thread (all verbosity levels)
  event:pr-ready:*)          → post PR ready (reviewed) thread (all verbosity levels)
  event:plan-review-complete) → post review summary (medium+)
  event:pr-review-complete)  → post review summary (medium+)
  event:review-limit-reached:plan) → post escalation (all verbosity levels)
  event:review-limit-reached:pr:*) → post escalation (all verbosity levels)
  event:ideas-ready)         → post ideas thread (all verbosity levels)
  event:selection-ready)     → post selection thread (all verbosity levels)
  event:design-ready)        → post design thread (all verbosity levels)
  event:design-revised)      → same as design-ready
  event:research-ready)      → post research thread (all verbosity levels)
  event:crash-limit-reached) → post crash alert (all verbosity levels)
  event:anomaly-detected:*)  → post anomaly warning (medium+)
  event:pr-merged-auto-approved) → post merge notification (medium+), no await
esac
```

### 1d. Check for new Slack replies

After draining the queue, check each active task's thread for new replies:

```bash
for _thread_file in ~/agentmesh/signals/*.slack-thread; do
  [ -f "$_thread_file" ] || continue
  _slug=$(basename "$_thread_file" .slack-thread)
  _thread_ts=$(cat "$_thread_file")
  _last_ts_file=~/agentmesh/signals/${_slug}.slack-last-ts
  _last_ts=$(cat "$_last_ts_file" 2>/dev/null || echo "0")

  # Use Slack MCP to fetch thread replies newer than _last_ts
  # For each new reply:
  #   - Parse the message text
  #   - Dispatch to reply_handler $_slug "$message_text"
  #   - Update _last_ts to newest seen reply ts
  echo "$_last_ts" > "$_last_ts_file"
done
```

#### Reply handler

```
reply_handler <slug> <message>:
  case (lowercased message) in
    approve|lgtm|looks good|yes|ok)
      send_cmd <slug> approve
    reviewer|spawn reviewer|spawn plan reviewer)
      send_cmd <slug> spawn-plan-reviewer
    spawn pr reviewer)
      send_cmd <slug> spawn-pr-reviewer
    feedback:*|fb:*)
      feedback_text=$(extract text after "feedback:" or "fb:")
      notecove task comments add <slug> --user "SlackBridge" "<feedback_text>"
      notecove task change <slug> --state Doing
      send_cmd <slug> resume
    abort|cancel)
      notecove task change <slug> --state "Won't Do"
      send_cmd <slug> abort
    respawn)
      notecove task change <slug> --state Doing
      send_cmd <slug> respawn
    select|continue)
      send_cmd <slug> approve
    *)
      Post to thread: "❓ Didn't understand that. Valid replies: approve, reviewer, feedback: <text>, abort"
  esac
```

### 1e. Check for slash commands

Fetch recent messages in the configured channel (not replies — top-level messages only) and check for messages newer than a stored channel-last-ts that start with `/agentmesh`:

```bash
CHANNEL_LAST_TS_FILE=~/agentmesh/signals/slack-channel-last-ts
CHANNEL_LAST_TS=$(cat "$CHANNEL_LAST_TS_FILE" 2>/dev/null || echo "0")
```

Use Slack MCP to fetch channel messages newer than CHANNEL_LAST_TS. For each new message starting with `/agentmesh`, parse and dispatch to the slash command handler. Update `CHANNEL_LAST_TS` to the newest seen message ts.

#### Slash command handler

```
/agentmesh create "<title>" [--priority P1] [--type implementer]
  → notecove task create with specified title and options
  → Post to channel: "✅ Task created: <slug> — <title>"

/agentmesh approve <slug>
  → send_cmd <slug> approve
  → Post to thread: "✅ Approved."

/agentmesh feedback <slug> "<text>"
  → notecove task comments add <slug> --user "SlackBridge" "<text>"
  → notecove task change <slug> --state Doing
  → send_cmd <slug> resume
  → Post to thread: "📝 Feedback sent."

/agentmesh abort <slug>
  → notecove task change <slug> --state "Won't Do"
  → send_cmd <slug> abort
  → Post to thread: "🛑 Task aborted."

/agentmesh status [<slug>]
  → If slug given: notecove task show <slug> --json → post single task status
  → Otherwise: notecove task list --project <PROJECT> --json → post summary list

/agentmesh show-questions <slug>
  → Find latest QUESTIONS-N note in task folder → post content to thread

/agentmesh show-plan <slug>
  → Find PLAN note in task folder → post content to thread

/agentmesh list-tasks [--state <state>]
  → notecove task list --project <PROJECT> [--state <state>] --json → post to channel

/agentmesh verbosity low|medium|high
  → echo "<level>" > signals/slack-verbosity
  → Post to channel: "Verbosity set to <level>."

/agentmesh mode standard|auto-review
  → echo "<mode>" > signals/mode
  → send_cmd - mode <mode>  (write "<mode>" to orchestrator-cmds as "orchestrator|mode|<mode>")
  → Post to channel: "Mode set to <mode>."

/agentmesh shutdown
  → send_cmd - shutdown
  → Proceed to Exit phase
```

### 1f. Loop back

Go to step 1a. Re-read `VERBOSITY` and `LOG` from files at the top of each iteration — zero in-memory state across cycles.

---

## Event Handlers (Slack Messages)

### Thread management

- **No thread exists** for a slug: call `mcp__slack__post_message` to channel, store the returned `ts` (message timestamp) in `signals/<slug>.slack-thread`. All subsequent posts for this slug use `thread_ts=<stored-ts>` to reply in the thread.
- **Thread exists**: call `mcp__slack__post_message` with `thread_ts=<stored-ts>` to reply.

Header format (channel-level post):
```
📋 *<slug>* — <task title>
State: Attention | Priority: <P> | Type: <agent-type>
```

### Verbosity filtering

Before posting, check `VERBOSITY`:
- `low`: only post if the event requires a user reply (questions, plan-ready, pr-submitted, pr-ready, research-ready, ideas-ready, selection-ready, design-ready, design-revised, crash alerts, review-limit escalations)
- `medium` (default): all low + state transition notifications, reviewer results, merge notifications, anomalies, completion notices
- `high`: all medium + full plan/research/design/QUESTIONS content inline in the Slack message

### Event-to-Slack message mapping

**`event:questions`** (all verbosity levels):
```
❓ *Worker has questions (Round N):*

<question content — if verbosity high, fetch and include full QUESTIONS note content; otherwise just the heading>

Reply here to answer, or `approve` to skip.
```
Read round number from existing QUESTIONS notes in the task folder.

**`event:plan-ready` / `event:plan-revised`** (all verbosity levels):
```
📝 *Plan ready for review:*

<if verbosity high: full PLAN note content; else: first 3 lines of plan>

Reply: `approve`, `reviewer`, `feedback: <text>`, or `abort`
```

**`event:pr-submitted:<url>`** (all verbosity levels):
```
🔀 *PR submitted:* <url>

Reply: `approve`, `reviewer`, `feedback: <text>`, or `abort`
```

**`event:pr-ready:<url>`** (all verbosity levels):
```
✅ *PR validated and ready:* <url>

Reply: `approve` or `feedback: <text>`
```

**`event:research-ready`** (all verbosity levels):
```
🔍 *Research complete.*

<if verbosity high: post Context notes content; else: brief summary>

Reply: `approve` or `feedback: <text>`
```

**`event:ideas-ready`** (all verbosity levels):
```
💡 *Ideas ready (Round N):*

<if verbosity high: full IDEAS note content; else: idea list headings>

Reply with feedback, or `select` when satisfied.
```

**`event:selection-ready`** (all verbosity levels):
```
☑️ *Select ideas to create as tasks:*

<checklist from SELECTION note>

When done: `continue`
```

**`event:design-ready` / `event:design-revised`** (all verbosity levels):
```
🎨 *Design ready for review:*

<if verbosity high: full DESIGN note; else: design summary>

Reply: `approve`, `feedback: <text>`, or `abort`
```

**`event:plan-review-complete`** (medium+):
```
🔎 *Plan review complete:*
<reviewer summary from last task comment>
```
Auto-ack — no reply needed (Spokesman handles next action).

**`event:pr-review-complete`** (medium+):
```
🔎 *PR review complete:*
<reviewer summary from last task comment>
```

**`event:review-limit-reached:plan`** (all verbosity levels):
```
⚠️ *Auto-review limit reached (plan).*
Reply: `approve`, `reviewer` (manual), or `abort`
```

**`event:review-limit-reached:pr:<url>`** (all verbosity levels):
```
⚠️ *Auto-review limit reached (PR).* <url>
Reply: `approve`, `reviewer` (manual), or `abort`
```

**`event:crash-limit-reached`** (all verbosity levels):
```
🚨 *Worker crashed 3 times.* Task blocked.
Reply: `respawn` or `abort`
```

**`event:anomaly-detected:<key>`** (medium+):
```
⚠️ *Anomaly detected:* <key description>
```
No reply needed.

**`event:completion`** (medium+):
```
✅ *Task complete.* <slug> — <title>
```
Auto-ack: `send_cmd <slug> acknowledge-completion` (no user input needed).

**`event:pr-merged-auto-approved`** (medium+):
```
🎉 *PR merged!* <slug> is done.
```
No reply needed.

**`event:task-ready`** — LLM triage (same TYPE_MAP as Spokesman, no Slack post):

```bash
task_json=$(notecove task show <slug> --json)
task_md=$(notecove task show <slug> --format markdown-with-comments)
title=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))")
```

Decide agent type using same heuristics as Spokesman TYPE_MAP:
- **brainstormer**: generate ideas, explore options, brainstorm approaches
- **planner**: multiple distinct deliverables, coordination of several concerns
- **designer**: UI, frontend, visual component, aesthetic design
- **investigator**: research, investigate, gather context, survey codebase
- **documenter**: write/update documentation, no logic changes
- **implementer**: any other concrete implementation task (default)

`send_cmd <slug> spawn <agent-type>`

---

## Exit

**Step 1 — Deregister from `active-interfaces`:**

```bash
grep -v "^slack-bridge$" ~/agentmesh/signals/active-interfaces > /tmp/sb_tmp && mv /tmp/sb_tmp ~/agentmesh/signals/active-interfaces
```

**Step 2 — Post to Slack channel:**
```
agentmesh SlackBridge stopped.
```

**Step 3 — Exit.** Do NOT kill other processes.

---

## Global Principles

- **Never interact with the user via the terminal** — all output goes to Slack.
- **Always re-read runtime state from files** at the top of each wakeup cycle (`VERBOSITY`, `LOG`) — zero in-memory state across cycles.
- **Always drain the full slackbridge-queue** before checking for replies or looping.
- **Always write NoteCove state changes BEFORE sending commands to orchestrator.py** — orchestrator.py fires the tmux signal immediately.
- **Check queue before blocking** — check `slackbridge-queue` before calling `tmux wait-for slackbridge-event` to avoid missing events that fired while processing the previous cycle.
- **thread_ts is the anchor** — the `signals/<slug>.slack-thread` file stores the top-level message ts. All replies use it as `thread_ts`. Never lose or overwrite it.
- **last-ts tracking prevents duplicate reply processing** — `signals/<slug>.slack-last-ts` stores the timestamp of the last processed reply; skip replies with `ts <= last_ts`.
- **Slash commands use channel-last-ts** — `signals/slack-channel-last-ts` stores the timestamp of the last processed channel message; skip messages with `ts <= channel_last_ts`.
