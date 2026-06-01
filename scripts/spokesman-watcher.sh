#!/usr/bin/env bash
# spokesman-watcher.sh — background signal watcher for the Spokesman
# Polls spokesman-queue every 2 seconds. When new entries arrive, fires spokesman-event
# to wake the Spokesman's event loop, and shows a tmux display-message so the user
# sees a visual alert if the Spokesman is currently blocked waiting for their input.
#
# Runs in orchestrator:spokesman-watcher. Started by the Spokesman skill (Phase 0).
# Never exits until killed by spokesman-exit.sh on shutdown.
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SPOKESMAN_QUEUE="$AGENTMESH/signals/spokesman-queue"
LOG="$AGENTMESH/signals/events.log"

log_event() {
  printf '%s\tspokesman-watcher\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" >> "$LOG"
}

echo "[spokesman-watcher] started"
log_event "started" "-"

last_size=0

while true; do
  sleep 2

  # Count lines in queue (0 if file missing or being drained)
  current_size=$(wc -l < "$SPOKESMAN_QUEUE" 2>/dev/null | tr -d ' ' || echo "0")

  if [ "$current_size" -gt "$last_size" ]; then
    new_count=$((current_size - last_size))
    log_event "queue-notification" "-"
    # Fire spokesman-event to wake the Spokesman's event loop (if it is currently blocking on it)
    tmux wait-for -S spokesman-event 2>/dev/null || true
    # Also show a visual overlay so the user sees the alert if the Spokesman is awaiting their input
    tmux display-message -t orchestrator:main -d 10000 \
      "⚡ ${new_count} new event(s) in queue — Spokesman will process when ready" 2>/dev/null || true
  fi

  last_size=$current_size
done
