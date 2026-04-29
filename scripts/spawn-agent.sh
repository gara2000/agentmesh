#!/usr/bin/env bash
# spawn-agent.sh — launch a Claude agent in a new tmux window
# Usage: spawn-agent.sh <session> <window-name> <skill> <task-slug> <project>
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: spawn-agent.sh <session> <window-name> <skill> <task-slug> <project>" >&2
  exit 1
fi

SESSION=$1
WINDOW=$2
SKILL=$3
SLUG=$4
PROJECT=$5

tmux new-window -t "$SESSION" -n "$WINDOW"
tmux send-keys -t "$SESSION:$WINDOW" "cd /Users/firas.gara/agentmesh && claude --dangerously-skip-permissions" Enter

# Wait for Claude REPL prompt to appear before sending the skill command
_elapsed=0
_timeout=60
while [ $_elapsed -lt $_timeout ]; do
  if tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null | grep -qE '^\s*>\s*$'; then
    break
  fi
  sleep 1
  _elapsed=$((_elapsed + 1))
done

tmux send-keys -t "$SESSION:$WINDOW" "$SKILL --task $SLUG --project $PROJECT" Enter
