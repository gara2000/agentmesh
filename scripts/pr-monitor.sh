#!/usr/bin/env bash
# pr-monitor.sh — polls a PR and tells the worker when it has been merged
# Usage: pr-monitor.sh <slug> <pr-url> [<interval-seconds>]
# Runs in a background orchestrator window (orchestrator:pr-mon-<slug>).
# Exits automatically after reporting the merge.
#
# It does NOT change task state. Only the worker agent and the user do that, so
# this writes the merge into the worker's inbox and delivers a message to the
# worker's Claude REPL; the worker wakes, sees the merge, and sets Done itself.
#
# Merge detection lives here rather than in the sidecar so the sidecar stays
# generic — it watches NoteCove and nothing else, with no notion of PRs.
set -uo pipefail

SLUG="${1:?slug required}"
PR_URL="${2:?pr-url required}"
INTERVAL="${3:-60}"

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SIGNALS="$AGENTMESH/signals"
LOG="$SIGNALS/events.log"
INBOX="$SIGNALS/${SLUG}.inbox"
MERGED_FLAG="$SIGNALS/${SLUG}.merged"

# shellcheck source=notify-worker.sh
source "$AGENTMESH/scripts/notify-worker.sh"

log_event() {
  printf '%s\tpr-monitor   \t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$SLUG" >> "$LOG"
}

echo "[pr-monitor] started for $SLUG ($PR_URL), polling every ${INTERVAL}s"
log_event "started"

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
      sleep 30
      retry_pending_nudge "$SLUG"
    done
    if [ -f "$SIGNALS/${SLUG}.pending-delivery" ]; then
      log_event "merge-nudge-undelivered"
    fi
    exit 0
  fi

  sleep "$INTERVAL"
done
