#!/usr/bin/env bash
# slack-poller.sh — fires slackbridge-event on a fixed interval
# Usage: slack-poller.sh [--interval <seconds>]
# Runs in orchestrator:slack-poller (started by bootstrap.sh when --interface includes slack)
#
# This is a pure timer/ticker — it does NOT call the Slack API.
# The actual message check is delegated to the SlackBridge skill, which has
# native access to the Slack MCP for reading and writing Slack messages.
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG="$AGENTMESH/signals/events.log"

# Parse arguments
INTERVAL=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

printf '%s\tslack-poller \tstarted\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
echo "[slack-poller] started — firing slackbridge-event every ${INTERVAL}s"

while true; do
  sleep "$INTERVAL"
  printf '%s\tslack-poller \ttick\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  tmux wait-for -S slackbridge-event
done
