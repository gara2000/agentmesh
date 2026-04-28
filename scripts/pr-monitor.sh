#!/usr/bin/env bash
# pr-monitor.sh — polls a PR and auto-approves when merged
# Usage: pr-monitor.sh <slug> <pr-url> [<interval-seconds>]
# Runs in a background orchestrator window (orchestrator:pr-mon-<slug>).
# Exits automatically after firing the merge event.
set -euo pipefail

SLUG="${1:?slug required}"
PR_URL="${2:?pr-url required}"
INTERVAL="${3:-60}"

QUEUE=/Users/firas.gara/agentmesh/signals/queue
LOG=/Users/firas.gara/agentmesh/signals/events.log
MERGED_FLAG="/Users/firas.gara/agentmesh/signals/${SLUG}.merged"

log_event() {
  printf '%s\tpr-monitor   \t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$SLUG" >> "$LOG"
}

echo "[pr-monitor] started for $SLUG ($PR_URL), polling every ${INTERVAL}s"
log_event "started"

while true; do
  state=$(gh pr view "$PR_URL" --json state --jq '.state' 2>/dev/null || echo "")

  if [ "$state" = "MERGED" ]; then
    echo "[pr-monitor] PR merged for $SLUG — firing auto-approval"
    log_event "pr-merged-detected"
    touch "$MERGED_FLAG"
    echo "$SLUG" >> "$QUEUE"
    tmux wait-for -S worker-any-event
    exit 0
  fi

  sleep "$INTERVAL"
done
