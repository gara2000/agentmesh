#!/usr/bin/env bash
# pr-monitor.sh — polls a PR and tells the worker when it is reviewed or merged
# Usage: pr-monitor.sh <slug> <pr-url> [<interval-seconds>] [--once]
# Runs in a background orchestrator window (orchestrator:pr-mon-<slug>).
# Exits automatically after reporting the merge. --once runs a single poll and
# exits, for tests.
#
# It does NOT change task state. Only the worker agent and the user do that, so
# this writes the merge into the worker's inbox and delivers a message to the
# worker's Claude REPL; the worker wakes, sees the merge, and sets Done itself.
#
# Merge detection lives here rather than in the sidecar so the sidecar stays
# generic — it watches NoteCove and nothing else, with no notion of PRs.
#
# New inline review comments (the ones pinned to a diff line, with a reply
# thread) are reported differently: as a NoteCove comment on the task, authored
# "PR Monitor". The sidecar already reports every comment the agent did not
# write, so that comment reaches the worker through the normal inbox + nudge
# path, and the user sees it in NoteCove too. The comment carries the complete
# instructions — review, address or ignore, reply in the thread — so no skill
# needs to know about PR comments.
#
# The worker replies under the same GitHub account as the user, so the author
# cannot tell its replies apart. Replies end with REPLY_MARKER, a hidden HTML
# comment, and any comment containing it is ignored.
set -uo pipefail

ONCE=0
_args=()
for _a in "$@"; do
  if [ "$_a" = "--once" ]; then ONCE=1; else _args+=("$_a"); fi
done
set -- "${_args[@]+"${_args[@]}"}"

SLUG="${1:?slug required}"
PR_URL="${2:?pr-url required}"
INTERVAL="${3:-60}"

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SIGNALS="$AGENTMESH/signals"
LOG="$SIGNALS/events.log"
INBOX="$SIGNALS/${SLUG}.inbox"
MERGED_FLAG="$SIGNALS/${SLUG}.merged"
# Review comment ids already reported (or deliberately ignored). Survives a
# monitor restart, so a respawned monitor does not replay old comments.
PR_SEEN="$SIGNALS/${SLUG}.pr-seen-comments"

MONITOR_AUTHOR="PR Monitor"
REPLY_MARKER="<!-- agentmesh -->"
# Pause between merge-nudge retries; overridable so tests do not wait.
: "${MERGE_RETRY_SLEEP:=30}"

# shellcheck source=notecove-ref.sh
source "$AGENTMESH/scripts/notecove-ref.sh"
# shellcheck source=notify-worker.sh
source "$AGENTMESH/scripts/notify-worker.sh"

log_event() {
  printf '%s\tpr-monitor   \t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$SLUG" >> "$LOG"
}

# repos/<owner>/<repo>/pulls/<n>, or empty if the URL is not a GitHub PR URL.
PR_API=$(printf '%s' "$PR_URL" \
  | sed -nE 's#^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+).*$#repos/\1/\2/pulls/\3#p')

# check_pr_comments
#
# Lists the PR's inline review comments and, if any are new, posts one NoteCove
# comment describing them. The first successful listing seeds the baseline with
# only the comments the worker has already answered (a later marked reply in the
# same thread); every other comment on it is reported, so a monitor started fresh
# after a restart never hides an unanswered comment. A failed listing or a failed
# post leaves the baseline untouched, so the same comments are retried next poll
# rather than lost.
check_pr_comments() {
  [ -n "$PR_API" ] || return 0

  local comments
  if ! comments=$(gh api --paginate "$PR_API/comments" --jq '.[]' 2>/dev/null); then
    log_event "pr-comments-fetch-failed"
    return 0
  fi

  local pending="$PR_SEEN.pending" message
  message=$(printf '%s\n' "$comments" | PR_SEEN="$PR_SEEN" PENDING="$pending" \
    PR_URL="$PR_URL" PR_API="$PR_API" REPLY_MARKER="$REPLY_MARKER" python3 -c '
import json, os, sys

seen_path, pending_path = os.environ["PR_SEEN"], os.environ["PENDING"]
url, api, marker = os.environ["PR_URL"], os.environ["PR_API"], os.environ["REPLY_MARKER"]
repo = api.rsplit("/pulls/", 1)[0]

comments = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        c = json.loads(line)
    except ValueError:
        continue
    if c.get("id") is not None:
        comments.append(c)

all_ids = [str(c["id"]) for c in comments]

if not os.path.exists(seen_path):
    # First run. Only what the worker has demonstrably answered is history: a
    # comment followed, in its thread, by a reply carrying the marker. Anything
    # else may never have been seen by any worker, because this file is lost
    # whenever the monitor is started fresh (adoption, crash cleanup, a cold
    # bootstrap). Baselining it all would silently swallow it; reporting it
    # costs at most one repeat of a comment already dealt with.
    def root(c):
        return str(c.get("in_reply_to_id") or c["id"])
    def order(c):
        try:
            return int(c["id"])
        except (TypeError, ValueError):
            return 0
    last_answer = {}
    for c in comments:
        if marker in (c.get("body") or ""):
            r = root(c)
            last_answer[r] = max(last_answer.get(r, order(c)), order(c))
    seen = {str(c["id"]) for c in comments
            if marker in (c.get("body") or "")
            or order(c) < last_answer.get(root(c), -1)}
    with open(seen_path, "w") as f:
        f.writelines(i + "\n" for i in all_ids if i in seen)
else:
    with open(seen_path) as f:
        seen = {l.strip() for l in f if l.strip()}

new = [c for c in comments if str(c["id"]) not in seen]
with open(pending_path, "w") as f:
    f.writelines(str(c["id"]) + "\n" for c in new)

# The workers own replies, not work for it.
new = [c for c in new if marker not in (c.get("body") or "")]
if not new:
    sys.exit(0)

def entry(c):
    cid = str(c["id"])
    root = str(c.get("in_reply_to_id") or cid)
    where = c.get("path") or "?"
    line = c.get("line") or c.get("original_line")
    if line:
        where += f":{line}"
    excerpt = " ".join((c.get("body") or "").split())
    if len(excerpt) > 60:
        excerpt = excerpt[:57] + "..."
    thread = "" if root == cid else f" (thread #{root})"
    login = (c.get("user") or {}).get("login") or "?"
    return f"- #{cid}{thread} @{login} {where}: \"{excerpt}\""

n = len(new)
plural = "s" if n != 1 else ""
header = f"{n} new inline review comment{plural} on {url}"
footer = (
    f"To the worker: for each one, read it in full (gh api {repo}/pulls/comments/<id>). "
    "If it is relevant, address it: commit and push to the PR branch. If not, leave the code alone. "
    f"Either way, reply briefly in its thread: gh api {api}/comments/<thread-id>/replies -f body=... "
    "(thread-id is the thread # where shown, else the comment #), and end every reply with "
    f"{marker} or it will be reported back to you. Then post_summary and request_attention."
)

# NoteCove rejects a comment over 996 characters; keep well inside it.
budget = 980 - len(header) - len(footer) - 4
lines, used = [], 0
for i, c in enumerate(new):
    e = entry(c)
    more = f"- (+{n - i - 1} more: gh api {api}/comments)" if i < n - 1 else ""
    if used + len(e) + 1 + len(more) > budget:
        lines.append(f"- (+{n - i} more: gh api {api}/comments)")
        break
    lines.append(e)
    used += len(e) + 1

print(header + "\n" + "\n".join(lines) + "\n\n" + footer)
')

  if [ -z "$message" ]; then
    # Baseline, nothing new, or only the worker's own replies.
    [ -f "$pending" ] && cat "$pending" >> "$PR_SEEN"
    rm -f "$pending"
    return 0
  fi

  local ref
  ref=$(nc_ref "$SLUG")
  if nc_run task comments add "$ref" --user "$MONITOR_AUTHOR" "$message" >/dev/null 2>&1; then
    cat "$pending" >> "$PR_SEEN"
    log_event "pr-comments-detected"
    echo "[pr-monitor] new review comments on $SLUG — posted to the task"
  else
    log_event "pr-comments-post-failed"
  fi
  rm -f "$pending"
}

echo "[pr-monitor] started for $SLUG ($PR_URL), polling every ${INTERVAL}s"
log_event "started"
[ -n "$PR_API" ] || log_event "pr-url-unparsed"

while true; do
  state=$(gh pr view "$PR_URL" --json state --jq '.state' 2>/dev/null || echo "")

  if [ "$state" = "MERGED" ]; then
    echo "[pr-monitor] PR merged for $SLUG — notifying worker"
    log_event "pr-merged-detected"
    touch "$MERGED_FLAG"

    PR_URL="$PR_URL" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "kind": "pr-merged",
    "url": os.environ["PR_URL"],
    "note": "PR was merged. Set the task to Done.",
}) + "\n")
' >> "$INBOX"

    # Unlike the sidecar this process exits after reporting, so there is no
    # later poll to retry a failed delivery. Keep trying for a few minutes to
    # cover a worker that is mid-boot or mid-respawn; .pending-delivery is left
    # behind either way, so a sidecar that is still running picks up the retry.
    notify_worker "$SLUG"
    _tries=0
    while [ -f "$SIGNALS/${SLUG}.pending-delivery" ] && [ $_tries -lt 10 ]; do
      _tries=$((_tries + 1))
      sleep "$MERGE_RETRY_SLEEP"
      retry_pending_nudge "$SLUG"
    done
    if [ -f "$SIGNALS/${SLUG}.pending-delivery" ]; then
      log_event "merge-nudge-undelivered"
    fi
    exit 0
  fi

  check_pr_comments

  [ "$ONCE" = 1 ] && exit 0
  sleep "$INTERVAL"
done
