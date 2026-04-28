#!/usr/bin/env bash
# spawn-agent.sh — launch a Claude agent in a new tmux window
# Usage: spawn-agent.sh <session> <window-name> <skill> <task-slug> <project>
set -euo pipefail

SESSION=$1
WINDOW=$2
SKILL=$3
SLUG=$4
PROJECT=$5

tmux new-window -t "$SESSION" -n "$WINDOW"
tmux send-keys -t "$SESSION:$WINDOW" "cd /Users/firas.gara/agentmesh && claude --dangerously-skip-permissions" Enter
sleep 3
tmux send-keys -t "$SESSION:$WINDOW" "$SKILL --task $SLUG --project $PROJECT" Enter
