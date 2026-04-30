#!/usr/bin/env bash
# spokesman-heartbeat-check.sh — Verify orchestrator.py heartbeat; auto-restart if stale.
# Called by the Spokesman skill after each wakeup in Phase 1a.5.
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG="$AGENTMESH/signals/events.log"
HEARTBEAT="$AGENTMESH/signals/orchestrator.heartbeat"
RESTART_CMD=$(cat "$AGENTMESH/signals/orchestrator-restart-cmd" 2>/dev/null || echo "")

if [ -n "$RESTART_CMD" ] && [ -f "$HEARTBEAT" ]; then
  last_modified=$(stat -f %m "$HEARTBEAT" 2>/dev/null || stat -c %Y "$HEARTBEAT" 2>/dev/null)
  now=$(date +%s)
  age=$((now - last_modified))
  if [ "$age" -gt 90 ]; then
    printf '%s\tspokesman    \torchestrator-restarted\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
    echo "⚠  Orchestrator heartbeat stale (${age}s). Restarting orchestrator.py..."
    tmux kill-window -t orchestrator:orchestrator 2>/dev/null || true
    sleep 1
    tmux new-window -t orchestrator -n orchestrator
    tmux send-keys -t orchestrator:orchestrator "$RESTART_CMD" Enter
    echo "Orchestrator restarted. Continuing..."
  fi
fi
