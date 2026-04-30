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

# Wait for Claude REPL prompt to appear before sending the skill command.
# Claude Code uses ❯ (U+276F) as its prompt character, not ASCII >.
# _timeout=300 with sleep 0.2 preserves the 60-second real-time fallback.
_elapsed=0
_timeout=300
while [ $_elapsed -lt $_timeout ]; do
  if tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null | grep -q '❯'; then
    break
  fi
  sleep 0.2
  _elapsed=$((_elapsed + 1))
done

tmux send-keys -t "$SESSION:$WINDOW" "$SKILL --task $SLUG --project $PROJECT" Enter
