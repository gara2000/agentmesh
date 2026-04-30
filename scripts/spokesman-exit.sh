#!/usr/bin/env bash
# spokesman-exit.sh — Shutdown cleanup for the Spokesman skill.
# Called by the Spokesman skill in the Exit phase after all tasks complete.
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG="$AGENTMESH/signals/events.log"
SPOKESMAN_ACKS="$AGENTMESH/signals/spokesman-acks"

printf '%s\tspokesman    \tshutdown\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

# Kill any remaining reviewer windows (not tracked in signals/workers)
tmux list-windows -t workers -F "#{window_name}" 2>/dev/null | { grep -E '^(plan-rev-|pr-rev-)' || true; } | while read -r win; do
  tmux kill-window -t "workers:$win" 2>/dev/null || true
done

# Kill the orchestrator.py window and daemons
tmux kill-window -t orchestrator:orchestrator 2>/dev/null || true
tmux kill-window -t orchestrator:dispatcher 2>/dev/null || true
tmux kill-window -t orchestrator:watchdog 2>/dev/null || true
tmux kill-window -t orchestrator:folder-cleanup 2>/dev/null || true

# Kill any remaining pr-monitor windows
tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null | { grep "^pr-mon-" || true; } | while read -r _win; do
  tmux kill-window -t "orchestrator:${_win}" 2>/dev/null || true
done

# Clean up signal files
rm -f "$AGENTMESH/signals/queue" "$AGENTMESH/signals/workers"
rm -f "$AGENTMESH/signals/spokesman-queue" "$AGENTMESH/signals/orchestrator-cmds"
rm -f "$SPOKESMAN_ACKS"
rm -f "$AGENTMESH/signals/"*.merged
rm -f "$AGENTMESH/signals/"*.reviewed
rm -f "$AGENTMESH/signals/"*.review-start
rm -f "$AGENTMESH/signals/triage_folder"
rm -f "$AGENTMESH/signals/mode"
