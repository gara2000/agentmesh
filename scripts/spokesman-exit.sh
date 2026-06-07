#!/usr/bin/env bash
# spokesman-exit.sh — Shutdown cleanup for the Spokesman skill.
# Called by the Spokesman skill in the Exit phase after all tasks complete.
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG="$AGENTMESH/signals/events.log"

printf '%s\tspokesman    \tshutdown\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

# Clean up signal files first (before sessions are killed)
rm -f "$AGENTMESH/signals/queue" "$AGENTMESH/signals/workers"
rm -f "$AGENTMESH/signals/spokesman-queue" "$AGENTMESH/signals/orchestrator-cmds"
rm -f "$AGENTMESH/signals/"*.merged
rm -f "$AGENTMESH/signals/"*.reviewed
rm -f "$AGENTMESH/signals/"*.review-start
rm -f "$AGENTMESH/signals/triage_folder"
rm -f "$AGENTMESH/signals/mode"

# Kill any remaining daemon windows before ending sessions
tmux kill-window -t "orchestrator:slack-socket" 2>/dev/null || true
tmux kill-window -t "orchestrator:slack-poller" 2>/dev/null || true

# Kill the workers session entirely (all worker and reviewer windows)
tmux kill-session -t workers 2>/dev/null || true

# Kill the orchestrator session entirely — this also terminates the current process
# (the Spokesman runs in orchestrator:main), which is the expected shutdown behavior.
tmux kill-session -t orchestrator 2>/dev/null || true
