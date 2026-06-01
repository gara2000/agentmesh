#!/usr/bin/env bash
# spokesman-watcher.sh — background queue monitor for the Spokesman
# Polls spokesman-queue every 2 seconds and notifies the user via tmux display-message
# when new events arrive. This ensures the user always sees pending events even while
# the Spokesman is blocked waiting for their input on a previous event.
#
# Runs in orchestrator:spokesman-watcher. Started by bootstrap.sh. Never exits until killed.
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
    # Notify the user via tmux status bar overlay (10 second display)
    tmux display-message -t orchestrator:main -d 10000 \
      "⚡ ${new_count} new event(s) in queue — Spokesman will process when ready" 2>/dev/null || true
  fi

  last_size=$current_size
done
