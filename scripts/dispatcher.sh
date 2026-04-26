#!/usr/bin/env bash
# dispatcher.sh — fan-in relay: any worker event → orchestrator event
# Runs in a background tmux pane. Never exits.
set -euo pipefail

LOG=/Users/firas.gara/agentmesh/signals/events.log

log_event() {
  printf '%s\tdispatcher\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" >> "$LOG"
}

echo "[dispatcher] started"

while true; do
  tmux wait-for "worker-any-event"
  log_event "worker-any-event-received" "-"
  tmux wait-for -S "orchestrator-event"
  log_event "orchestrator-event-fired" "-"
done
