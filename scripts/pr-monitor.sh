#!/usr/bin/env bash
# pr-monitor.sh — polls a PR and tells the worker when it has been merged
# Usage: pr-monitor.sh <slug> <pr-url> [<interval-seconds>]
# Runs in a background orchestrator window (orchestrator:pr-mon-<slug>).
# Exits automatically after reporting the merge.
#
# It does NOT change task state. Only the worker agent and the user do that, so
# this writes the merge into the worker's inbox and nudges it; the worker wakes,
# sees the merge, and sets Done itself.
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

    seq=$(cat "$SIGNALS/${SLUG}.seq" 2>/dev/null || echo "0")
    tmux wait-for -S "${SLUG}-nudge-${seq}" 2>/dev/null || true
    log_event "nudge-fired:seq=${seq}"
    exit 0
  fi

  sleep "$INTERVAL"
done
