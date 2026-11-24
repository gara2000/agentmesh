#!/usr/bin/env bash
# pr-monitor.sh — polls a task's PRs and tells the worker when they are reviewed or merged
# Usage: pr-monitor.sh <slug> [<pr-url>] [<interval-seconds>] [--once]
# Runs in a background orchestrator window (orchestrator:pr-mon-<slug>).
# Exits automatically after reporting the merge. --once runs a single poll and
# exits, for tests.
#
# One monitor watches every PR of its task. The list lives in signals/<slug>.prs,
# one URL per line: watch_pr appends to it and starts this monitor only if it is
# not already running, and the monitor re-reads it on every poll, so a PR the
# agent opens later is picked up without a restart. A <pr-url> argument is added
# to the list too. A task with several PRs used to be watched on the first one
# only: the others' review comments were never reported, and the first merge
# alone told the worker to set Done.
#
# The worker is told to set Done only once every watched PR has merged. An
# earlier merge is logged and otherwise silent — there is nothing for the worker
# to do yet. A PR closed without merging drops out of the set, so it cannot hold
# the task open forever; it does not count as merged.
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
# cannot tell its replies apart. Replies go through reply_pr_comment in
# agent-notecove.sh, which ends each with a visible AI-response footer and then
# REPLY_MARKER, a hidden HTML comment; any comment containing it is ignored.
#
# A failed CI check on an open PR travels the same way: one "PR Monitor" comment
# naming the failed checks and telling the worker to fix and push (or explain
# why the failure is not its own). Each failure is reported once per (PR, head
# commit, check), so a push that fails again is reported again.
set -uo pipefail

ONCE=0
_args=()
for _a in "$@"; do
  if [ "$_a" = "--once" ]; then ONCE=1; else _args+=("$_a"); fi
done
set -- "${_args[@]+"${_args[@]}"}"

SLUG="${1:?slug required}"
ARG_URL="${2:-}"
INTERVAL="${3:-60}"

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SIGNALS="$AGENTMESH/signals"
LOG="$SIGNALS/events.log"
INBOX="$SIGNALS/${SLUG}.inbox"
# The PRs to watch, one URL per line; appended to by watch_pr.
PRS="$SIGNALS/${SLUG}.prs"
# PRs seen merged / closed unmerged, one URL per line. Both survive a monitor
# restart, so an already-resolved PR is not polled again.
MERGED="$SIGNALS/${SLUG}.merged"
CLOSED="$SIGNALS/${SLUG}.pr-closed"
# Review comment ids already reported (or deliberately ignored), across all of
# the task's PRs — GitHub comment ids are global, so one file serves them all.
# A "baseline <pulls-api-path>" line records that the PR's first listing has
# been taken. Survives a monitor restart, so a respawned monitor does not
# replay old comments.
PR_SEEN="$SIGNALS/${SLUG}.pr-seen-comments"
# Failed CI checks already reported, one "<pr-url> <head-sha> <check>" per line.
# Keyed on the head commit: a fix pushed and failing again is a new failure.
PR_CI="$SIGNALS/${SLUG}.pr-ci-reported"

MONITOR_AUTHOR="PR Monitor"
# Must equal PR_REPLY_MARKER in agent-notecove.sh, which appends it.
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

# pr_api <pr-url>
#
# repos/<owner>/<repo>/pulls/<n>, or empty if the URL is not a GitHub PR URL.
pr_api() {
  printf '%s' "$1" \
    | sed -nE 's#^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+).*$#repos/\1/\2/pulls/\3#p'
}

# in_list <file> <line> — is <line> one of <file>'s lines?
in_list() {
  [ -f "$1" ] && grep -qxF -- "$2" "$1"
}

# watched_urls — the watch list, minus blank lines.
watched_urls() {
  [ -f "$PRS" ] && grep -v '^[[:space:]]*$' "$PRS"
  return 0
}

# check_pr_comments <pr-url>
#
# Lists the PR's inline review comments and, if any are new, posts one NoteCove
# comment describing them. Each PR is checked, and posted about, separately.
# The first successful listing of a PR seeds the baseline with
# only the comments the worker has already answered (a later marked reply in the
# same thread); every other comment on it is reported, so a monitor started fresh
# after a restart never hides an unanswered comment. A failed listing or a failed
# post leaves the baseline untouched, so the same comments are retried next poll
# rather than lost.
check_pr_comments() {
  local PR_URL="$1" PR_API
  PR_API=$(pr_api "$PR_URL")
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

seen, baselined = set(), False
if os.path.exists(seen_path):
    with open(seen_path) as f:
        for l in f:
            l = l.strip()
            if l == "baseline " + api:
                baselined = True
            elif l and " " not in l:
                seen.add(l)

if not baselined:
    # First listing of this PR. Only what the worker has demonstrably answered
    # is history: a comment followed, in its thread, by a reply carrying the
    # marker. Anything else may never have been seen by any worker, because
    # this file is lost whenever the monitor is started fresh (adoption, crash
    # cleanup, `agentmesh clean`). Baselining it all would silently swallow it;
    # reporting it costs at most one repeat of a comment already dealt with.
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
    answered = [str(c["id"]) for c in comments
                if marker in (c.get("body") or "")
                or order(c) < last_answer.get(root(c), -1)]
    seen.update(answered)
    with open(seen_path, "a") as f:
        f.write("baseline " + api + "\n")
        f.writelines(i + "\n" for i in answered)

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
    f"Either way, reply briefly in its thread with reply_pr_comment {url} <thread-id> \"<text>\" "
    "(thread-id is the thread # where shown, else the comment #) - never a raw gh api call: "
    f"it adds the AI-response footer and the {marker} marker that keeps your reply from being "
    "reported back to you. Then post_summary and request_attention."
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

# check_pr_ci <pr-url> <head-sha>
#
# Lists the PR's checks and, if any have failed on <head-sha> that were not
# reported yet, posts one NoteCove comment naming them. Only the "fail" bucket
# counts: pending, cancelled and skipped checks are not the worker's to fix.
# gh exits non-zero whenever a check is failing or pending, so its exit code
# says nothing; output that is not a JSON list (no checks, a gh error) means
# nothing to report this poll. As with review comments, a failed post leaves
# the record untouched and the failure is retried next poll.
check_pr_ci() {
  local PR_URL="$1" HEAD="$2" checks
  checks=$(gh pr checks "$PR_URL" --json name,workflow,bucket,link 2>/dev/null)
  [ -n "$checks" ] || return 0

  local pending="$PR_CI.pending" message
  message=$(printf '%s' "$checks" | PR_CI="$PR_CI" PENDING="$pending" \
    PR_URL="$PR_URL" HEAD="$HEAD" python3 -c '
import json, os, sys

reported_path, pending_path = os.environ["PR_CI"], os.environ["PENDING"]
url, head = os.environ["PR_URL"], os.environ["HEAD"]

try:
    checks = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
if not isinstance(checks, list):
    sys.exit(0)

reported = set()
if os.path.exists(reported_path):
    with open(reported_path) as f:
        reported = {l.rstrip("\n") for l in f}

new, keys = [], []
for c in checks:
    if not isinstance(c, dict) or c.get("bucket") != "fail":
        continue
    name = " ".join(str(c.get("name") or "?").split())
    workflow = " ".join(str(c.get("workflow") or "").split())
    label = f"{workflow} / {name}" if workflow else name
    key = f"{url} {head} {label}"
    if key in reported or key in keys:
        continue
    keys.append(key)
    new.append((label, c.get("link") or ""))

if not new:
    sys.exit(0)
with open(pending_path, "w") as f:
    f.writelines(k + "\n" for k in keys)

n = len(new)
plural = "s" if n != 1 else ""
header = f"CI failing on {url} (commit {head[:7]}): {n} failed check{plural}"
footer = (
    f"To the worker: inspect each failure (gh pr checks {url}; for GitHub Actions, "
    "gh run view <run-id> --log-failed). If this PR caused it, fix it: commit and push "
    "to the PR branch. If it is unrelated or flaky, leave the code alone and say so "
    "in your summary. Then post_summary and request_attention."
)

# NoteCove rejects a comment over 996 characters; keep well inside it.
budget = 980 - len(header) - len(footer) - 4
lines, used = [], 0
for i, (label, link) in enumerate(new):
    e = f"- {label}: {link}" if link else f"- {label}"
    more = f"- (+{n - i - 1} more: gh pr checks {url})" if i < n - 1 else ""
    if used + len(e) + 1 + len(more) > budget:
        lines.append(f"- (+{n - i} more: gh pr checks {url})")
        break
    lines.append(e)
    used += len(e) + 1

print(header + "\n" + "\n".join(lines) + "\n\n" + footer)
')

  if [ -z "$message" ]; then
    rm -f "$pending"
    return 0
  fi

  local ref
  ref=$(nc_ref "$SLUG")
  if nc_run task comments add "$ref" --user "$MONITOR_AUTHOR" "$message" >/dev/null 2>&1; then
    cat "$pending" >> "$PR_CI"
    log_event "pr-ci-failed-detected"
    echo "[pr-monitor] CI failing on $PR_URL — posted to the task"
  else
    log_event "pr-ci-post-failed"
  fi
  rm -f "$pending"
}

if [ -n "$ARG_URL" ] && ! in_list "$PRS" "$ARG_URL"; then
  printf '%s\n' "$ARG_URL" >> "$PRS"
fi

echo "[pr-monitor] started for $SLUG, polling every ${INTERVAL}s"
log_event "started"

# report_merged
#
# Every watched PR is resolved and at least one merged: write the pr-merged
# entry and deliver it. Unlike the sidecar this process exits after reporting,
# so there is no later poll to retry a failed delivery. Keep trying for a few
# minutes to cover a worker that is mid-boot or mid-respawn; .pending-delivery
# is left behind either way, so a sidecar that is still running picks up the
# retry.
report_merged() {
  echo "[pr-monitor] all PRs merged for $SLUG — notifying worker"
  log_event "pr-merged-detected"

  MERGED="$MERGED" python3 -c '
import json, os, sys
urls = [l.strip() for l in open(os.environ["MERGED"]) if l.strip()]
n = len(urls)
note = ("PR was merged." if n == 1 else f"All {n} PRs were merged.") + " Set the task to Done."
sys.stdout.write(json.dumps({
    "kind": "pr-merged",
    "url": urls[-1],
    "urls": urls,
    "note": note,
}) + "\n")
' >> "$INBOX"

  notify_worker "$SLUG"
  local tries=0
  while [ -f "$SIGNALS/${SLUG}.pending-delivery" ] && [ $tries -lt 10 ]; do
    tries=$((tries + 1))
    sleep "$MERGE_RETRY_SLEEP"
    retry_pending_nudge "$SLUG"
  done
  if [ -f "$SIGNALS/${SLUG}.pending-delivery" ]; then
    log_event "merge-nudge-undelivered"
  fi
}

# URLs already logged as unparsable, so the event is written once per PR rather
# than once per poll.
UNPARSED=" "

while true; do
  open=0
  while IFS= read -r url; do
    in_list "$MERGED" "$url" && continue
    in_list "$CLOSED" "$url" && continue

    if [ -z "$(pr_api "$url")" ] && [ "${UNPARSED#* "$url" }" = "$UNPARSED" ]; then
      UNPARSED="$UNPARSED$url "
      log_event "pr-url-unparsed"
    fi

    view=$(gh pr view "$url" --json state,headRefOid --jq '.state + " " + .headRefOid' \
      2>/dev/null </dev/null || echo "")
    state="" head=""
    read -r state head <<< "$view"
    case "$state" in
      MERGED)
        printf '%s\n' "$url" >> "$MERGED"
        log_event "pr-merged-seen"
        echo "[pr-monitor] $url merged"
        ;;
      CLOSED)
        printf '%s\n' "$url" >> "$CLOSED"
        log_event "pr-closed-unmerged"
        echo "[pr-monitor] $url closed without merging — no longer watched"
        ;;
      *)
        # OPEN, or unknown because gh failed: still outstanding either way.
        open=$((open + 1))
        check_pr_comments "$url" </dev/null
        # No head commit (gh failed): nothing to key a CI report on this poll.
        [ -n "$head" ] && check_pr_ci "$url" "$head" </dev/null
        ;;
    esac
  done < <(watched_urls)

  if [ "$open" -eq 0 ] && [ -s "$MERGED" ]; then
    # Re-read the list: a watch_pr racing with this poll may have just added a
    # PR this pass never saw, and exiting now would leave it unwatched.
    pending=0
    while IFS= read -r url; do
      in_list "$MERGED" "$url" || in_list "$CLOSED" "$url" || pending=1
    done < <(watched_urls)
    if [ "$pending" -eq 0 ]; then
      report_merged
      exit 0
    fi
  fi

  [ "$ONCE" = 1 ] && exit 0
  sleep "$INTERVAL"
done
