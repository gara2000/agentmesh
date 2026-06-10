#!/usr/bin/env bash
# slack-poller.sh — fires slackbridge-event on a state-aware interval
# Usage: slack-poller.sh [--fast-interval <seconds>] [--slow-interval <seconds>]
# Runs in orchestrator:slack-poller (started by bootstrap.sh when --interface includes slack)
#
# This is a pure timer/ticker — it does NOT call the Slack API.
# The actual message check is delegated to the SlackBridge skill, which has
# native access to the Slack MCP for reading and writing Slack messages.
#
# State-aware behavior:
#   - At least one task in Attention state → fast tick (default 30s) for low-latency reply processing
#   - No tasks in Attention state, adaptive interval set → use adaptive back-off interval
#   - No tasks in Attention state, no adaptive interval  → slow tick (default 60s)
set -euo pipefail

# cd to agentmesh so notecove can find its .notecove config
AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$AGENTMESH"

LOG="$AGENTMESH/signals/events.log"
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# Parse arguments
FAST_INTERVAL=30
SLOW_INTERVAL=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast-interval) FAST_INTERVAL="$2"; shift 2 ;;
    --slow-interval) SLOW_INTERVAL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

printf '%s\tslack-poller \tstarted\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
echo "[slack-poller] started — fast=${FAST_INTERVAL}s, slow=${SLOW_INTERVAL}s"

was_paused=0
prev_interval=0

while true; do
  # Check for tasks in Attention state to choose the appropriate interval
  attention_count=$($NOTECOVE task list --state Attention --json 2>/dev/null \
    | python3 -c "import sys,json; tasks=json.load(sys.stdin); print(len(tasks))" 2>/dev/null || echo 0)

  if [[ "$attention_count" -gt 0 ]]; then
    interval="$FAST_INTERVAL"
    tick_type="fast"
  else
    # Check for adaptive back-off interval written by SlackBridge
    adaptive_interval=$(cat "$AGENTMESH/signals/slack-poller-current-interval" 2>/dev/null || echo "")
    if [[ -n "$adaptive_interval" ]] && [[ "$adaptive_interval" =~ ^[0-9]+$ ]] && [[ "$adaptive_interval" -gt 0 ]]; then
      interval="$adaptive_interval"
      tick_type="adaptive"
    else
      interval="$SLOW_INTERVAL"
      tick_type="slow"
    fi
  fi

  # Log when the interval changes
  if [[ "$interval" != "$prev_interval" ]]; then
    printf '%s\tslack-poller \tinterval-changed\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
    prev_interval="$interval"
  fi

  sleep "$interval"

  # Check for pause flag — skip waking SlackBridge if paused
  if [ -f "$AGENTMESH/signals/slack-poller-paused" ]; then
    if [[ "$was_paused" -eq 0 ]]; then
      printf '%s\tslack-poller \tpaused\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
      was_paused=1
    fi
    continue
  fi

  if [[ "$was_paused" -eq 1 ]]; then
    printf '%s\tslack-poller \tresumed\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
    was_paused=0
  fi

  printf '%s\tslack-poller \ttick-%s\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tick_type" >> "$LOG"
  tmux wait-for -S slackbridge-event
done
