#!/usr/bin/env bash
# ready-poller.sh — polls for Ready tasks and triggers orchestrator scan
# Runs in a background tmux window. Never exits.
#
# Usage: ready-poller.sh --project <PROJECT> [--poll-interval <seconds>]
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$AGENTMESH"

SIGNALS="$AGENTMESH/signals"
LOG="$SIGNALS/events.log"
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# Parse arguments
PROJECT=""
POLL_INTERVAL="30"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "[ready-poller] Error: --project is required" >&2
  exit 1
fi

log_event() {
  printf '%s\tready-poller \t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" >> "$LOG"
}

echo "[ready-poller] started (project: $PROJECT, poll interval: ${POLL_INTERVAL}s)"
log_event "started" "-"

while true; do
  sleep "$POLL_INTERVAL"

  # Check if there are any Ready tasks in the project
  ready_count=$($NOTECOVE task list --state Ready --project "$PROJECT" --json 2>/dev/null \
    | python3 -c "import sys,json; tasks=json.load(sys.stdin); print(len(tasks))" 2>/dev/null || echo 0)

  if [[ "$ready_count" -gt 0 ]]; then
    echo "[ready-poller] found $ready_count Ready task(s) — signaling orchestrator scan"
    log_event "scan-triggered" "-"
    echo "-|scan" >> "$SIGNALS/orchestrator-cmds"
    tmux wait-for -S orchestrator-cmd-event
  fi
done
