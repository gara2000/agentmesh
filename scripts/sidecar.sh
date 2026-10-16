#!/usr/bin/env bash
# sidecar.sh — per-agent NoteCove task watcher
#
# Usage: sidecar.sh --task <slug> --agent-handle <handle> [--poll-interval <seconds>]
#
# Watches one NoteCove task and delivers a message to its agent whenever
# something changes that the agent needs to see: a new comment written by anyone
# other than the agent itself, or a task state change the agent did not make.
#
# Delivery is `tmux send-keys` into the worker's Claude REPL (see
# notify-worker.sh), not `tmux wait-for -S`. A signal could only ever reach an
# agent already blocked in `tmux wait-for`, so anything the user said while the
# agent was working went unseen until the agent next chose to wait.
#
# The sidecar is deliberately GENERIC — it carries no task-type knowledge at all.
# It never interprets comment content, never changes task state, and never decides
# what a change means. It reports "this changed" and wakes the agent; the agent,
# which already knows its own type because it is running a type-specific skill,
# decides what to do.
#
# Change detection runs two mechanisms against one shared diff step:
#
#   1. SSE push — subscribes to the NoteCove event stream and runs the diff step
#      whenever a task.* frame arrives for this slug. Near-zero latency.
#   2. Safety-net poll — runs the same diff step every --poll-interval seconds.
#      This runs ALWAYS, not only when SSE is unavailable: the documented event
#      type list (task.created/modified/deleted) has no comment-specific type, so
#      whether adding a comment emits a frame at all is an inference. The poll
#      makes correctness independent of that inference.
#
# Both mechanisms funnel into check_for_changes(), which is the only place that
# decides whether to nudge. Duplicate triggers are harmless — the diff is against
# stored baseline state, so a change is reported exactly once regardless of how
# many times the check runs.
set -uo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$AGENTMESH"

SIGNALS="$AGENTMESH/signals"
LOG="$SIGNALS/events.log"
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# shellcheck source=notify-worker.sh
source "$AGENTMESH/scripts/notify-worker.sh"

SLUG=""
AGENT_HANDLE=""
POLL_INTERVAL="60"
# Upper bound on any single NoteCove call. Comfortably above a normal local-socket
# response, low enough that a hang costs one poll cycle rather than the session.
CALL_TIMEOUT="30"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)          SLUG="$2";          shift 2 ;;
    --agent-handle)  AGENT_HANDLE="$2";  shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    *) echo "[sidecar] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SLUG" || -z "$AGENT_HANDLE" ]]; then
  echo "[sidecar] Error: --task and --agent-handle are required" >&2
  exit 1
fi

INBOX="$SIGNALS/${SLUG}.inbox"
SEEN_COMMENTS="$SIGNALS/${SLUG}.seen-comments"
SEEN_STATE="$SIGNALS/${SLUG}.seen-state"
SELF_STATE="$SIGNALS/${SLUG}.self-state"

log_event() {
  printf '%s\tsidecar      \t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-$SLUG}" >> "$LOG"
}

# ---------------------------------------------------------------------------
# The diff step — the single place that decides whether to nudge.
#
# Fetches the task once and compares against baseline files:
#   - comment IDs  (signals/<slug>.seen-comments)
#   - state ID     (signals/<slug>.seen-state)
#
# Appends any new comments not authored by this agent, plus any state change the
# agent did not make itself, to signals/<slug>.inbox as line-delimited JSON, then
# delivers a nudge to the agent's REPL.
#
# Baselines are updated only after the inbox write succeeds, so a crash mid-write
# re-reports rather than silently swallowing a change.
# ---------------------------------------------------------------------------
check_for_changes() {
  local task_json rc
  # Bound the call. Without a timeout a hung NoteCove wedges this loop forever,
  # and the failure is invisible: the sidecar's window stays alive, so both the
  # watchdog and `agentmesh status` keep counting it as healthy while the agent
  # it is supposed to wake blocks indefinitely.
  task_json=$(timeout "$CALL_TIMEOUT" $NOTECOVE task show "$SLUG" --json 2>/dev/null)
  rc=$?
  if [[ $rc -eq 124 ]]; then
    log_event "notecove-call-timed-out"
    echo "[sidecar] $SLUG: notecove task show timed out after ${CALL_TIMEOUT}s — will retry"
    return 0
  fi
  [[ $rc -ne 0 ]] && return 0
  [[ -z "$task_json" ]] && return 0

  # Pass baselines by path so python does the whole diff in one pass.
  local result
  result=$(printf '%s' "$task_json" | AGENT_HANDLE="$AGENT_HANDLE" \
    SEEN_COMMENTS="$SEEN_COMMENTS" SEEN_STATE="$SEEN_STATE" INBOX="$INBOX" \
    SELF_STATE="$SELF_STATE" \
    python3 -c '
import json, os, sys

try:
    task = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

handle = os.environ["AGENT_HANDLE"].strip().lower()
seen_comments_path = os.environ["SEEN_COMMENTS"]
seen_state_path = os.environ["SEEN_STATE"]
self_state_path = os.environ["SELF_STATE"]
inbox_path = os.environ["INBOX"]


def read_lines(path):
    try:
        with open(path) as f:
            return {l.strip() for l in f if l.strip()}
    except FileNotFoundError:
        return set()


def read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


seen_ids = read_lines(seen_comments_path)
prev_state = read_text(seen_state_path)
cur_state = (task.get("stateId") or "").strip()

entries = []
all_ids = set()

# Flatten comments and their replies — a reply is as much a message as a
# top-level comment, and the user may answer either way.
def walk(comments):
    for c in comments or []:
        yield c
        yield from walk(c.get("replies"))

for c in walk(task.get("comments")):
    cid = (c.get("id") or "").strip()
    if not cid:
        continue
    all_ids.add(cid)
    if cid in seen_ids:
        continue
    author = (c.get("authorName") or "").strip()
    # Ignore the agents own comments so its summary writes do not wake it.
    if author.lower() == handle:
        continue
    entries.append({
        "kind": "comment",
        "id": cid,
        "author": author,
        "content": c.get("content") or "",
        "created": c.get("created"),
    })

# The agent writes the state name it is about to set to .self-state before
# calling the CLI (set_state in agent-notecove.sh). A match against the task
# current state name means the agent moved the task itself, so reporting it back
# would interrupt the agent with its own write - the state-change equivalent of
# the author filter applied to comments above.
#
# Matched against the current state rather than only against an observed
# transition: the transition may never be observed at all (a fresh sidecar
# baselines straight onto it, or the agent moves twice between two polls), and a
# marker left behind could otherwise swallow a genuine user move to that same
# state much later.
cur_name = (task.get("stateName") or "").strip()
expected = read_text(self_state_path)
self_induced = bool(expected) and bool(cur_name) and expected.lower() == cur_name.lower()

if prev_state and cur_state and prev_state != cur_state and not self_induced:
    entries.append({
        "kind": "state-change",
        "from": prev_state,
        "to": cur_state,
        "to_name": cur_name,
    })

# First run establishes the baseline without nudging: everything that exists
# before the sidecar starts is history the agent already has.
first_run = not seen_ids and not prev_state

if entries and not first_run:
    with open(inbox_path, "a") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")

with open(seen_comments_path, "w") as f:
    for cid in sorted(all_ids):
        f.write(cid + "\n")
with open(seen_state_path, "w") as f:
    f.write(cur_state)

# Consume the marker only after the baseline has absorbed the state it covered,
# so a crash in between re-suppresses rather than reporting a self-inflicted move.
if self_induced:
    try:
        os.unlink(self_state_path)
    except OSError:
        pass

if entries and not first_run:
    n_comments = sum(1 for e in entries if e["kind"] == "comment")
    n_state = sum(1 for e in entries if e["kind"] == "state-change")
    print(f"{n_comments} {n_state}")
' 2>/dev/null)

  [[ -z "$result" ]] && return 0

  local n_comments n_state
  n_comments=$(echo "$result" | awk '{print $1}')
  n_state=$(echo "$result" | awk '{print $2}')

  log_event "change-detected:comments=${n_comments}:state=${n_state}"
  echo "[sidecar] $SLUG: ${n_comments} new comment(s), ${n_state} state change(s) — delivering"
  notify_worker "$SLUG"
}

# ---------------------------------------------------------------------------
# Delivery lives in notify-worker.sh, shared with pr-monitor.sh:
#
#   notify_worker <slug>       mark pending, then try to deliver
#   retry_pending_nudge <slug> re-try an outstanding delivery, no-op otherwise
#
# A delivery can legitimately fail — the worker window may be mid-boot, or
# .ready may not be set yet — so notify_worker leaves a .pending-delivery
# sentinel and the poll loop below retries while it exists. Nothing else would:
# the diff only fires on *new* changes, and by the time a delivery fails the
# change it was reporting is already absorbed into the baseline.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# SSE subscription loop.
#
# Streams task.* frames and runs the diff step for any frame naming this slug.
# Frames carry {type, source, item:{type,slug,id}, timestamp, payload}; we match
# on item.slug, falling back to a substring check so an id-only frame for this
# task still triggers a diff.
#
# Runs in a background subshell. If the stream is unavailable — notably when the
# CLI token lacks events:subscribe — it logs once and exits, leaving the
# safety-net poll as the sole mechanism.
# ---------------------------------------------------------------------------
sse_loop() {
  local probe
  probe=$(timeout "$CALL_TIMEOUT" $NOTECOVE events recent --types "task.*" --limit 1 --json 2>&1 | head -1)
  if [[ "$probe" == *"does not have events:subscribe"* ]]; then
    log_event "sse-unavailable:no-permission"
    echo "[sidecar] $SLUG: SSE unavailable (token lacks events:subscribe) — relying on ${POLL_INTERVAL}s poll"
    return 0
  fi

  log_event "sse-subscribed"
  echo "[sidecar] $SLUG: subscribed to NoteCove event stream"

  while true; do
    # --json prints one JSON object per line as frames arrive.
    $NOTECOVE events --types "task.*" --json 2>/dev/null | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if printf '%s' "$line" | grep -qF "$SLUG"; then
        check_for_changes
      fi
    done
    # Stream ended (app restart, socket drop) — reconnect after a short pause.
    log_event "sse-reconnecting"
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "[sidecar] started for $SLUG (agent: $AGENT_HANDLE, poll: ${POLL_INTERVAL}s)"
log_event "started"

# Establish the baseline before anything can nudge, so pre-existing comments are
# recorded as history rather than replayed at the agent.
check_for_changes

sse_loop &
SSE_PID=$!
trap 'kill $SSE_PID 2>/dev/null || true' EXIT

while true; do
  sleep "$POLL_INTERVAL"
  check_for_changes
  retry_pending_nudge "$SLUG"
done
