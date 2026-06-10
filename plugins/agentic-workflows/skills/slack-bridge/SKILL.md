---
name: slack-bridge
description: Full Spokesman peer for AgentMesh that communicates via Slack instead of a tmux terminal. Receives worker events via slackbridge-queue, posts to Slack threads via the Slack MCP, and translates Slack replies into orchestrator commands.
disable-model-invocation: true
allowed-tools: Bash(notecove *, tmux *, mkdir *, cat *, echo *, rm *, bash *, sleep *, sed *, python3 *), mcp__slack__*
hint: "Run the AgentMesh SlackBridge (Slack user-interaction layer). Required: --project <key>, --channel <slack-channel-id>. Optional: --verbosity low|medium|high (default: medium)"
---

# SlackBridge — AgentMesh Slack Interface Layer

**Arguments:** $ARGUMENTS

## Phase 0: Verify Slack MCP is configured

Before doing anything else, verify that the Slack MCP is available by attempting a lightweight call:

- Call `mcp__slack__slack_search_channels` with query `test` and limit `1`.
- If the call succeeds (even with zero results) → Slack MCP is configured; proceed normally.
- If the call fails for any reason (tool unavailable, MCP server not running, connection error, auth error) → print the following message to the terminal and stop immediately:

```
ERROR: Slack MCP is not configured or not reachable.

Please add the Slack MCP server to your Claude Code MCP settings and restart.
See: https://github.com/modelcontextprotocol/servers for setup instructions.

Once the Slack MCP is configured, re-run /slack-bridge to start the SlackBridge.
```

Do not proceed to argument parsing or any further steps if this check fails.

---

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
echo "slackbridge" >> ~/agentmesh/signals/active-interfaces
```

### 0b. Write runtime state files

```bash
echo "<verbosity-level>" > ~/agentmesh/signals/slack-verbosity
echo "<channel-id>" > ~/agentmesh/signals/slack-channel
# Initialize idle timer to now so the idle-pause clock starts fresh on startup
date +%s > ~/agentmesh/signals/slack-bridge-last-user-msg-ts
# Set processing flag — poller must not fire until SlackBridge is ready to listen
touch ~/agentmesh/signals/slack-poller-processing
```

### 0c. Startup recovery

Query NoteCove for tasks in `Attention` state. For each, check whether the worker window is still alive:

- **Worker window exists** → if no `signals/<slug>.slack-thread` exists, post a recovery header thread to Slack so the user can see the pending event; store the `thread_ts`.
- **Worker window is gone** → the worker crashed and must be respawned. Infer the agent type from the task's typeIds/typeNames using the same TYPE_MAP as the Spokesman, set task to `Doing`, and send a `spawn` command to orchestrator.py.

```bash
_attention_slugs=$(notecove task list --project <PROJECT> --state Attention --json | \
  python3 -c "import sys,json; [print(t['slug']['short']) for t in json.load(sys.stdin)]" 2>/dev/null || echo "")

_respawned_count=0
for _slug in $_attention_slugs; do
  # Check if the worker window still exists
  _worker_alive=false
  if tmux list-windows -t workers -F '#{window_name}' 2>/dev/null | grep -qxF "$_slug"; then
    _worker_alive=true
  fi

  if [ "$_worker_alive" = "true" ]; then
    # Worker is alive: ensure a Slack thread exists so the user can see the event
    if [ ! -f ~/agentmesh/signals/${_slug}.slack-thread ]; then
      _task_json=$(notecove task show "$_slug" --json)
      _title=$(echo "$_task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))")
      _priority=$(echo "$_task_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print('P' + str(d.get('priority','?')))")
      _last_event=$(notecove task show "$_slug" --format markdown-with-comments | \
        grep "^- " | grep -oP 'event:\S+' | tail -1 2>/dev/null || echo "unknown")
      # Post recovery header using standard format, store thread_ts in signals/<slug>.slack-thread:
      #   📋 *<slug>* — <title>
      #   State: Attention (<last-event>) | Priority: <P>
      # Then update the header to the current event state.
      # Log: slack-bridge  thread-created  <slug>
    fi
  else
    # Worker is gone: respawn it
    _agent_type=$(notecove task show "$_slug" --json | python3 -c "
import sys, json
TYPE_MAP = {
    'feature': 'implementer', 'bug': 'implementer',
    'plan': 'planner', 'brainstorming': 'brainstormer',
    'documentation': 'documenter', 'design': 'designer',
    'investigation': 'investigator',
}
task = json.load(sys.stdin)
type_ids = task.get('typeIds') or []
type_names = task.get('typeNames') or []
result = next((TYPE_MAP[t.lower()] for t in type_ids if t.lower() in TYPE_MAP), None)
if result is None:
    result = next((TYPE_MAP[n.lower()] for n in type_names if n.lower() in TYPE_MAP), None)
print(result or 'implementer')
" 2>/dev/null || echo "implementer")
    notecove task change "$_slug" --state Doing
    send_cmd "$_slug" "spawn" "$_agent_type"
    _respawned_count=$((_respawned_count + 1))
  fi
done

if [ "$_respawned_count" -gt 0 ]; then
  # Post to Slack channel: "Recovery: respawned workers for N task(s) whose worker windows were gone."
  :
fi
```

After the recovery loop, check whether the queue is already non-empty (orchestrator.py may have written events before SlackBridge started listening):

```bash
if [ -s "$SLACKBRIDGE_QUEUE" ]; then
  # Jump directly to step 1b to drain it
  :
fi
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

Re-read runtime state at the top of each wakeup cycle — zero in-memory state across iterations:

```bash
SLACKBRIDGE_QUEUE=~/agentmesh/signals/slackbridge-queue
VERBOSITY=$(cat ~/agentmesh/signals/slack-verbosity 2>/dev/null || echo "medium")
LOG=~/agentmesh/signals/events.log
```

Check whether the queue already has pending events before blocking (the orchestrator writes to `slackbridge-queue` **before** firing `slackbridge-event`; if the signal fired while SlackBridge was processing, tmux drops it silently):

```bash
if [ ! -s "$SLACKBRIDGE_QUEUE" ]; then
  # Clear the processing flag — SlackBridge is now ready to receive signals
  rm -f ~/agentmesh/signals/slack-poller-processing
  tmux wait-for slackbridge-event
  # Set the processing flag — SlackBridge is now processing; poller must not fire
  touch ~/agentmesh/signals/slack-poller-processing
fi
```

### 1a.5. Check orchestrator heartbeat

After each wakeup, verify that orchestrator.py is still alive. If the heartbeat file is stale (not updated in >90 seconds), auto-restart orchestrator.py:

```bash
bash ~/agentmesh/scripts/spokesman-heartbeat-check.sh
```

If the restart happens, post to the Slack channel: "⚠️ orchestrator.py was stale — restarted automatically."

If `signals/orchestrator.heartbeat` does not exist (e.g., shortly after bootstrap before orchestrator.py writes its first heartbeat), the check is silently skipped.

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

After draining the queue, check threads only for tasks currently in `Attention` state — tasks in `Doing` have no pending user replies and reading their threads is pure waste:

```bash
_attention_slugs_for_replies=$(notecove task list --project <PROJECT> --state Attention --json | \
  python3 -c "import sys,json; [print(t['slug']['short']) for t in json.load(sys.stdin)]" 2>/dev/null || echo "")

for _slug in $_attention_slugs_for_replies; do
  _thread_file=~/agentmesh/signals/${_slug}.slack-thread
  [ -f "$_thread_file" ] || continue
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
  # Reset idle timer — any user reply counts as activity
  date +%s > ~/agentmesh/signals/slack-bridge-last-user-msg-ts
  case (lowercased message) in
    approve|lgtm|looks good|yes|ok|✅)
      # Determine the right command from the task's last event comment
      _last_event=$(notecove task show <slug> --format markdown-with-comments | \
        grep "^- " | grep -oP 'event:\S+' | tail -1 2>/dev/null || echo "")
      if echo "$_last_event" | grep -qE '^event:pr-(submitted|ready|revised|ready-final|review-complete)'; then
        # PR context: approve the PR
        send_cmd <slug> pr-approved
        Update thread header: State: Done
        Post final thread reply: "> 🤖 *AgentMesh*\n✅ *<slug>* complete."
        Log slack-bridge  thread-closed  <slug>
      elif echo "$_last_event" | grep -q '^event:review-limit-reached:pr:'; then
        # PR review-limit escalation: approve the PR
        send_cmd <slug> pr-approved
        Update thread header: State: Done
        Post final thread reply: "> 🤖 *AgentMesh*\n✅ *<slug>* complete."
        Log slack-bridge  thread-closed  <slug>
      elif [ "$_last_event" = "event:research-ready" ]; then
        # Research context: set Done then send done command (matches Spokesman behaviour)
        notecove task change <slug> --state Done
        send_cmd <slug> done
        Update thread header: State: Done
        Post final thread reply: "> 🤖 *AgentMesh*\n✅ *<slug>* complete."
        Log slack-bridge  thread-closed  <slug>
      else
        # Plan / questions / design / brainstormer context: resume the worker
        notecove task change <slug> --state Doing
        send_cmd <slug> resume
        Update thread header: State: Doing
      fi
    reviewer|spawn reviewer|spawn plan reviewer)
      send_cmd <slug> spawn-plan-reviewer
    spawn pr reviewer|pr reviewer)
      send_cmd <slug> spawn-pr-reviewer
    feedback:*|fb:*)
      feedback_text=$(extract text after "feedback:" or "fb:")
      notecove task comments add <slug> --user "SlackBridge" "<feedback_text>"
      notecove task change <slug> --state Doing
      send_cmd <slug> resume
      Update thread header: State: Doing
    abort|cancel|stop)
      notecove task change <slug> --state "Won't Do"
      send_cmd <slug> abort
      Update thread header: State: Won't Do
      Post final thread reply: "> 🤖 *AgentMesh*\n🚫 *<slug>* cancelled."
      Log slack-bridge  thread-closed  <slug>
    respawn|retry)
      # Look up agent type from task typeIds/typeNames (same TYPE_MAP as Spokesman)
      _agent_type=$(notecove task show <slug> --json | python3 -c "
import sys, json
TYPE_MAP = {'feature': 'implementer', 'bug': 'implementer', 'plan': 'planner',
            'brainstorming': 'brainstormer', 'documentation': 'documenter',
            'design': 'designer', 'investigation': 'investigator'}
task = json.load(sys.stdin)
type_ids = task.get('typeIds') or []
type_names = task.get('typeNames') or []
result = next((TYPE_MAP[t.lower()] for t in type_ids if t.lower() in TYPE_MAP), None)
if result is None:
    result = next((TYPE_MAP[n.lower()] for n in type_names if n.lower() in TYPE_MAP), None)
print(result or 'implementer')
" 2>/dev/null || echo "implementer")
      notecove task change <slug> --state Doing
      send_cmd <slug> spawn $_agent_type
      Update thread header: State: Doing
    select|selection done|continue|proceed|done)
      # "Accept and continue" reply for plans, questions, brainstormer selection, etc.
      notecove task change <slug> --state Doing
      send_cmd <slug> resume
    *)
      Post to thread: "> 🤖 *AgentMesh*\n❓ Didn't understand that. Valid replies: approve, reviewer, feedback: <text>, abort"
  esac
```

### 1e. Check for slash commands

Fetch recent messages in the configured channel (not replies — top-level messages only) and check for messages newer than a stored channel-last-ts that start with `/agentmesh`:

```bash
CHANNEL_LAST_TS_FILE=~/agentmesh/signals/slack-channel-last-ts
CHANNEL_LAST_TS=$(cat "$CHANNEL_LAST_TS_FILE" 2>/dev/null || echo "0")
```

Use Slack MCP to fetch channel messages newer than CHANNEL_LAST_TS. For each new message starting with `/agentmesh`, reset the idle timer and parse and dispatch to the slash command handler. Update `CHANNEL_LAST_TS` to the newest seen message ts.

For each new `/agentmesh` message found:
```bash
# Reset idle timer — any slash command counts as user activity
date +%s > ~/agentmesh/signals/slack-bridge-last-user-msg-ts
```

#### Slash command handler

```
/agentmesh create "<title>" [--priority P1|P2|P3] [--type implementer|planner|brainstormer|investigator|documenter|designer] [--description "<text>"]
  → Convert agent type to notecove task type ID using this mapping:
    implementer → feature, planner → plan, brainstormer → brainstorming,
    investigator → investigation, documenter → documentation, designer → design
    (if --type is omitted, omit --type from the notecove command)
  → notecove task create "<title>" --project <PROJECT> --state ready [--priority <P>] [--type <task-type-id>] [--content "<text>" --content-format markdown]
  → Post to channel: "✅ Task created: <slug> — <title>"

/agentmesh approve <slug>
  → Determine command from last event comment (same context-aware logic as reply_handler):
    PR context (event:pr-submitted/pr-ready/pr-revised/pr-ready-final/pr-review-complete or review-limit-reached:pr:*):
      send_cmd <slug> pr-approved
    Research context (event:research-ready):
      notecove task change <slug> --state Done
      send_cmd <slug> done
    Plan / questions / design / brainstormer context:
      notecove task change <slug> --state Doing
      send_cmd <slug> resume
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

/agentmesh spawn-reviewer <slug> plan|pr
  → if plan: send_cmd <slug> spawn-plan-reviewer
  → if pr:   send_cmd <slug> spawn-pr-reviewer
  → Post to thread: "🔎 Reviewer spawned."

/agentmesh respawn <slug>
  → Look up agent type from task typeIds/typeNames (same TYPE_MAP as Spokesman):
    implementer → feature/bug, planner → plan, brainstormer → brainstorming,
    designer → design, investigator → investigation, documenter → documentation
    (default: implementer)
  → notecove task change <slug> --state Doing
  → send_cmd <slug> spawn <agent_type>
  → Post to thread: "♻️ Worker respawned."

/agentmesh status [<slug>]
  → If slug given: notecove task show <slug> --json → post single task status
  → Otherwise: notecove task list --project <PROJECT> --json → post summary list

/agentmesh show-questions <slug>
  → Find latest QUESTIONS-N note in task folder → post content to thread

/agentmesh show-plan <slug>
  → Find PLAN note in task folder → post content to thread

/agentmesh list-tasks [--state ready|doing|attention|blocked]
  → notecove task list --project <PROJECT> [--state <state>] --json → post to channel

/agentmesh verbosity low|medium|high
  → echo "<level>" > signals/slack-verbosity
  → Post to channel: "Verbosity set to <level>."

/agentmesh mode standard|auto-review
  → echo "<mode>" > signals/mode
  → send_cmd - mode <mode>  (write "<mode>" to orchestrator-cmds as "orchestrator|mode|<mode>")
  → Post to channel: "Mode set to <mode>."

/agentmesh pause
  → touch ~/agentmesh/signals/slack-poller-paused
  → Post to channel: "⏸ Slack polling paused. Send /agentmesh resume to restart."
  → Log: slack-bridge  poller-paused  -

/agentmesh resume
  → rm -f ~/agentmesh/signals/slack-poller-paused
  → rm -f ~/agentmesh/signals/slack-poller-auto-paused
  → date +%s > ~/agentmesh/signals/slack-bridge-last-user-msg-ts  (reset idle timer to prevent immediate re-pause)
  → Post to channel: "▶️ Slack polling resumed."
  → Log: slack-bridge  poller-resumed  -

/agentmesh scan
  → send_cmd - scan
  → Post to channel: "🔍 Scan triggered — orchestrator will pick up any new ready tasks."
  → Log: slack-bridge  slash-command  -

/agentmesh shutdown
  → send_cmd - shutdown
  → Proceed to Exit phase

/agentmesh release patch|minor|major
  → bash ~/agentmesh/scripts/release.sh <bump-type>
  → Post output to channel: "✅ Release cut: v<new-version>" (or error message if it fails)

/agentmesh help
  → Post the full command table to the channel:
     /agentmesh create "<title>" [--priority P1|P2|P3] [--type implementer|...] [--description "<text>"] — Create a task
     /agentmesh approve <slug>                — Approve a worker's PR/plan/research
     /agentmesh feedback <slug> "<text>"      — Send feedback to a worker
     /agentmesh abort <slug>                  — Abort a task (sets to Won't Do)
     /agentmesh spawn-reviewer <slug> plan|pr — Spawn a plan or PR reviewer
     /agentmesh respawn <slug>                — Respawn a crashed worker
     /agentmesh status [<slug>]               — Show all tasks or a single task
     /agentmesh show-questions <slug>         — Show latest questions from a worker
     /agentmesh show-plan <slug>              — Show the implementation plan for a task
     /agentmesh list-tasks [--state <state>]  — List tasks filtered by state
     /agentmesh verbosity low|medium|high     — Set Slack message verbosity
     /agentmesh mode standard|auto-review     — Set orchestrator review mode
     /agentmesh pause                         — Pause Slack polling
     /agentmesh resume                        — Resume Slack polling
     /agentmesh scan                          — Trigger orchestrator to pick up new ready tasks
     /agentmesh release patch|minor|major     — Cut a plugin release
     /agentmesh shutdown                      — Shut down the SlackBridge
     /agentmesh help                          — Show this help message
```

**Freeform release commands** — also recognize these as top-level channel messages (not just slash commands), matching the Spokesman's behavior:

- `release patch` / `release minor` / `release major` (as a plain channel message)
  → `bash ~/agentmesh/scripts/release.sh <bump-type>`
  → Post result to channel

### 1f. Auto-pause check

After processing all events, replies, and slash commands for this cycle, check whether the Slack poller should be auto-paused due to idle timeout:

```bash
IDLE_PAUSE_MINUTES=$(cat ~/agentmesh/signals/slack-idle-pause-minutes 2>/dev/null || echo "0")
if [[ "$IDLE_PAUSE_MINUTES" -gt 0 ]] 2>/dev/null; then
  IDLE_PAUSE_SECONDS=$((IDLE_PAUSE_MINUTES * 60))
  LAST_MSG_TS=$(cat ~/agentmesh/signals/slack-bridge-last-user-msg-ts 2>/dev/null || date +%s)
  NOW=$(date +%s)
  IDLE_SECONDS=$((NOW - LAST_MSG_TS))

  if [[ "$IDLE_SECONDS" -gt "$IDLE_PAUSE_SECONDS" ]] && [ ! -f ~/agentmesh/signals/slack-poller-paused ]; then
    # Idle timeout exceeded and not yet paused — auto-pause
    touch ~/agentmesh/signals/slack-poller-paused
    touch ~/agentmesh/signals/slack-poller-auto-paused
    IDLE_MINS=$((IDLE_SECONDS / 60))
    # Post to Slack channel: "⏸ Polling paused (idle for ${IDLE_MINS}m). Send any message or /agentmesh resume to restart."
    printf '%s\tslack-bridge  \tauto-paused-idle\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  elif [[ "$IDLE_SECONDS" -le "$IDLE_PAUSE_SECONDS" ]] && [ -f ~/agentmesh/signals/slack-poller-auto-paused ]; then
    # Activity resumed and the pause was auto-triggered — auto-resume
    rm -f ~/agentmesh/signals/slack-poller-paused
    rm -f ~/agentmesh/signals/slack-poller-auto-paused
    printf '%s\tslack-bridge  \tauto-resumed\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  fi
fi
```

Note: Only auto-remove `slack-poller-paused` when `slack-poller-auto-paused` also exists. This distinguishes auto-pause from a manual `/agentmesh pause` — manual pauses are only cleared by `/agentmesh resume`.

### 1g. Loop back

Go to step 1a. Re-read `VERBOSITY` and `LOG` from files at the top of each iteration — zero in-memory state across cycles.

---

## Event Handlers (Slack Messages)

### Thread management

- **No thread exists** for a slug: call `mcp__slack__post_message` to channel, store the returned `ts` (message timestamp) in `signals/<slug>.slack-thread`. All subsequent posts for this slug use `thread_ts=<stored-ts>` to reply in the thread. Log `slack-bridge  thread-created  <slug>` to `events.log`.
- **Thread exists**: call `mcp__slack__post_message` with `thread_ts=<stored-ts>` to reply.

### Message prefix convention

Every SlackBridge thread reply (not the top-level header) MUST begin with the following prefix on its own line, before the message body:

```
> 🤖 *AgentMesh*
```

This uses Slack's blockquote formatting (renders a vertical bar on the left side), making AgentMesh replies immediately distinguishable from user messages in the thread. Apply this prefix to **all** thread replies: event notifications, reply handler confirmations, error messages, and any other non-header posts.

Do **not** apply the prefix to:
- Channel-level header posts (📋 *slug* — title format)
- `mcp__slack__update_message` calls (header updates)

Header format (channel-level post, initial creation and updates):
```
📋 *<slug>* — <task title>
State: <state> | Priority: <P>
```
- `PR: <url>` is appended (` | PR: <url>`) when a PR URL is known for the task.

### Thread header updates

After each event that changes the task's visible state, update the thread header using `mcp__slack__update_message`. Read the current thread ts, build the new header text, and call the tool:

```bash
_thread_ts=$(cat ~/agentmesh/signals/<slug>.slack-thread 2>/dev/null || echo "")
if [ -n "$_thread_ts" ]; then
  _pr_suffix=""
  [ -n "${_pr_url:-}" ] && _pr_suffix=" | PR: ${_pr_url}"
  mcp__slack__update_message channel="<CHANNEL_ID>" ts="$_thread_ts" \
    text="📋 *${slug}* — ${title}
State: <new-state> | Priority: <P>${_pr_suffix}"
  printf '%s\tslack-bridge  \tthread-header-updated\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" >> "$LOG"
fi
```

**When to update the header:**

| Event / action | New header state |
|---|---|
| `event:questions` | `Attention (questions)` |
| `event:plan-ready` / `event:plan-revised` | `Attention (plan review)` |
| `event:pr-submitted:<url>` | `Attention (PR ready)` — include PR URL |
| `event:pr-ready:<url>` | `Attention (PR validated)` — include PR URL |
| `event:plan-review-complete` | `In Review` |
| `event:pr-review-complete` | `In Review` |
| `event:review-limit-reached:plan` | `Attention (review limit)` |
| `event:review-limit-reached:pr:<url>` | `Attention (review limit)` — include PR URL |
| `event:crash-limit-reached` | `Blocked` |
| `event:completion` | `Done` |
| `event:pr-merged-auto-approved` | `Done` |
| `approve` (reply handler) | `Done` |
| `feedback:*` / `respawn` (reply handler) | `Doing` |
| `abort` (reply handler) | `Won't Do` |

### Thread cleanup

When a task reaches a terminal state, post a final reply to the thread **after** updating the header:

- **Done** (via `event:completion`, `event:pr-merged-auto-approved`, or `approve`): post `> 🤖 *AgentMesh*` followed by `✅ *<slug>* complete.` as a thread reply. Log `slack-bridge  thread-closed  <slug>`.
- **Won't Do** (via `abort`): post `> 🤖 *AgentMesh*` followed by `🚫 *<slug>* cancelled.` as a thread reply. Log `slack-bridge  thread-closed  <slug>`.

Do NOT delete or remove `signals/<slug>.slack-thread` — the file persists until `agentmesh stop` on shutdown.

### Verbosity filtering

Before posting, check `VERBOSITY`:
- `low`: only post if the event requires a user reply (questions, plan-ready, pr-submitted, pr-ready, research-ready, ideas-ready, selection-ready, design-ready, design-revised, crash alerts, review-limit escalations)
- `medium` (default): all low + state transition notifications, reviewer results, merge notifications, anomalies, completion notices
- `high`: all medium + full plan/research/design/QUESTIONS content inline in the Slack message

### Event-to-Slack message mapping

**`event:questions`** (all verbosity levels):
```
> 🤖 *AgentMesh*
❓ *Worker has questions (Round N):*

<question content — if verbosity high, fetch and include full QUESTIONS note content; otherwise first 500 chars of the QUESTIONS note content>

Reply here to answer, or `approve` to skip.
```
Read round number from existing QUESTIONS notes in the task folder.
Update thread header: `State: Attention (questions)`.

**`event:plan-ready` / `event:plan-revised`** (all verbosity levels):
```
> 🤖 *AgentMesh*
📝 *Plan ready for review:*

<if verbosity high: full PLAN note content; else: first 500 chars of PLAN note>

Reply: `approve`, `reviewer`, `feedback: <text>`, or `abort`
```
Update thread header: `State: Attention (plan review)`.

**`event:pr-submitted:<url>`** (all verbosity levels):
```
> 🤖 *AgentMesh*
🔀 *PR submitted:* <url>

Reply: `approve`, `reviewer`, `feedback: <text>`, or `abort`
```
Update thread header: `State: Attention (PR ready) | PR: <url>`.

**`event:pr-ready:<url>`** (all verbosity levels):
```
> 🤖 *AgentMesh*
✅ *PR validated and ready:* <url>

Reply: `approve` or `feedback: <text>`
```
Update thread header: `State: Attention (PR validated) | PR: <url>`.

**`event:research-ready`** (all verbosity levels):
```
> 🤖 *AgentMesh*
🔍 *Research complete.*

<if verbosity high: post Context notes content; else: first 300 chars of research summary>

Reply: `approve` or `feedback: <text>`
```
Update thread header: `State: Attention (research ready)`.

**`event:ideas-ready`** (all verbosity levels):
```
> 🤖 *AgentMesh*
💡 *Ideas ready (Round N):*

<if verbosity high: full IDEAS note content; else: idea list headings>

Reply with feedback, or `select` when satisfied.
```
Update thread header: `State: Attention (ideas ready)`.

**`event:selection-ready`** (all verbosity levels):
```
> 🤖 *AgentMesh*
☑️ *Select ideas to create as tasks:*

<checklist from SELECTION note>

When done: `continue`
```
Update thread header: `State: Attention (select ideas)`.

**`event:design-ready` / `event:design-revised`** (all verbosity levels):
```
> 🤖 *AgentMesh*
🎨 *Design ready for review:*

<if verbosity high: full DESIGN note; else: design summary>

Reply: `approve`, `feedback: <text>`, or `abort`
```
Update thread header: `State: Attention (design review)`.

**`event:plan-review-complete`** (medium+):
```
> 🤖 *AgentMesh*
🔎 *Plan review complete:*
<reviewer summary from last task comment>
```
Auto-ack — no reply needed (Spokesman handles next action).
Update thread header: `State: In Review`.

**`event:pr-review-complete`** (medium+):
```
> 🤖 *AgentMesh*
🔎 *PR review complete:*
<reviewer summary from last task comment>
```
Update thread header: `State: In Review`.

**`event:review-limit-reached:plan`** (all verbosity levels):
```
> 🤖 *AgentMesh*
⚠️ *Auto-review limit reached (plan).*
Reply: `approve`, `reviewer` (manual), or `abort`
```
Update thread header: `State: Attention (review limit)`.

**`event:review-limit-reached:pr:<url>`** (all verbosity levels):
```
> 🤖 *AgentMesh*
⚠️ *Auto-review limit reached (PR).* <url>
Reply: `approve`, `reviewer` (manual), or `abort`
```
Update thread header: `State: Attention (review limit) | PR: <url>`.

**`event:crash-limit-reached`** (all verbosity levels):
```
> 🤖 *AgentMesh*
🚨 *Worker crashed 3 times.* Task blocked.
Reply: `respawn` or `abort`
```
Update thread header: `State: Blocked`.

**`event:anomaly-detected:<key>`** (medium+):
```
> 🤖 *AgentMesh*
⚠️ *Anomaly detected:* <key description>
```
No reply needed. No header update (not a state transition).

**`event:completion`** (medium+):
```
> 🤖 *AgentMesh*
✅ *Task complete.* <slug> — <title>
```
Auto-ack — the orchestrator handles completion automatically via `completion.sh`; no command needed from SlackBridge.
Update thread header: `State: Done`. Then post final thread reply: `> 🤖 *AgentMesh*` followed by `✅ *<slug>* complete.`
Log `slack-bridge  thread-closed  <slug>`.

**`event:pr-merged-auto-approved`** (medium+):
```
> 🤖 *AgentMesh*
🎉 *PR merged!* <slug> is done.
```
No await needed.
Update thread header: `State: Done`. Then post final thread reply: `> 🤖 *AgentMesh*` followed by `✅ *<slug>* complete.`
Log `slack-bridge  thread-closed  <slug>`.

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
grep -v "^slackbridge$" ~/agentmesh/signals/active-interfaces > /tmp/sb_tmp && mv /tmp/sb_tmp ~/agentmesh/signals/active-interfaces
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
- **Check orchestrator heartbeat after every wakeup** — call `spokesman-heartbeat-check.sh` immediately after waking; if orchestrator.py is stale, restart it and notify via Slack before processing any events.
- **Respawn dead workers on startup** — tasks in `Attention` state with no live worker window must be respawned (not just threaded) to prevent them from being permanently stuck.
- **thread_ts is the anchor** — the `signals/<slug>.slack-thread` file stores the top-level message ts. All replies use it as `thread_ts`. Never lose or overwrite it.
- **last-ts tracking prevents duplicate reply processing** — `signals/<slug>.slack-last-ts` stores the timestamp of the last processed reply; skip replies with `ts <= last_ts`.
- **Slash commands use channel-last-ts** — `signals/slack-channel-last-ts` stores the timestamp of the last processed channel message; skip messages with `ts <= channel_last_ts`.
- **Always update the thread header on state transitions** — after each event that changes task state, call `mcp__slack__update_message` on the stored `thread_ts`. See "Thread header updates" table. Skip the update silently if `signals/<slug>.slack-thread` does not exist.
- **Always post a final thread reply on terminal states** — when a task reaches Done or Won't Do, post `✅ *<slug>* complete.` or `🚫 *<slug>* cancelled.` as a thread reply after updating the header. This closes the thread visually without deleting it.
