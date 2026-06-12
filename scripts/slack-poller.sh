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
#   - At least one task in Attention state → fast tick (default 60s) for low-latency reply processing
#   - No tasks in Attention state          → slow tick (default 120s) for slash-command polling only
set -euo pipefail

# cd to agentmesh so notecove can find its .notecove config
AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$AGENTMESH"

LOG="$AGENTMESH/signals/events.log"
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# Parse arguments
FAST_INTERVAL=60
SLOW_INTERVAL=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast-interval) FAST_INTERVAL="$2"; shift 2 ;;
    --slow-interval) SLOW_INTERVAL="$2"; shift 2 ;;
    *) echo "[slack-poller] unknown argument: $1" >&2; exit 1 ;;
  esac
done

trap 'printf "%s\tslack-poller \tstopped\t-\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"; echo "[slack-poller] stopped"' EXIT

printf '%s\tslack-poller \tstarted\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
echo "[slack-poller] started — fast=${FAST_INTERVAL}s, slow=${SLOW_INTERVAL}s"

was_paused=0
last_tick_type=""

while true; do
  # Check for tasks in Attention state to choose the appropriate interval
  attention_count=$($NOTECOVE task list --state Attention --json 2>/dev/null \
    | python3 -c "import sys,json; tasks=json.load(sys.stdin); print(len(tasks))" 2>/dev/null || echo 0)

  if [[ "$attention_count" -gt 0 ]]; then
    interval="$FAST_INTERVAL"
    tick_type="fast"
  else
    interval="$SLOW_INTERVAL"
    tick_type="slow"
  fi

  # Log mode switch when tick_type changes (skip the very first iteration)
  if [[ -n "$last_tick_type" && "$tick_type" != "$last_tick_type" ]]; then
    printf '%s\tslack-poller \tmode-%s\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tick_type" >> "$LOG"
    echo "[slack-poller] mode changed to ${tick_type} (${attention_count} attention task(s), interval=${interval}s)"
  fi
  last_tick_type="$tick_type"

  sleep "$interval"

  # Check for pause flag or processing flag — skip waking SlackBridge if either is set
  # slack-poller-paused: manual or auto-pause (user-facing)
  # slack-poller-processing: set by SlackBridge while it is processing events (not listening)
  processing_paused=0
  user_paused=0
  [ -f "$AGENTMESH/signals/slack-poller-processing" ] && processing_paused=1
  [ -f "$AGENTMESH/signals/slack-poller-paused" ] && user_paused=1

  if [[ "$processing_paused" -eq 1 || "$user_paused" -eq 1 ]]; then
    if [[ "$was_paused" -eq 0 ]]; then
      if [[ "$processing_paused" -eq 1 && "$user_paused" -eq 1 ]]; then
        pause_reason="processing+user"
      elif [[ "$processing_paused" -eq 1 ]]; then
        pause_reason="processing"
      else
        pause_reason="user"
      fi
      printf '%s\tslack-poller \tpaused-%s\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pause_reason" >> "$LOG"
      echo "[slack-poller] paused (reason: ${pause_reason})"
      was_paused=1
    fi
    continue
  fi

  if [[ "$was_paused" -eq 1 ]]; then
    printf '%s\tslack-poller \tresumed\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
    echo "[slack-poller] resumed"
    was_paused=0
  fi

  printf '%s\tslack-poller \ttick-%s\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tick_type" >> "$LOG"
  tmux wait-for -S slackbridge-event
done
