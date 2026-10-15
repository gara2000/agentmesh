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

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# A window with this name must not already exist. tmux happily creates a second
# window with a duplicate name, after which every name-addressed operation
# ("$SESSION:$WINDOW") fails with "can't find window" — send-keys below included,
# so the agent would never start, yet the caller would register it as running.
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qxF "$WINDOW"; then
  echo "spawn-agent.sh: window '$SESSION:$WINDOW' already exists — refusing to create a duplicate" >&2
  exit 1
fi

# Launch claude AS THE WINDOW'S COMMAND rather than send-keys'ing it into a
# shell. This is what makes window liveness a sound proxy for "the agent is
# running": the window dies with the process. Created as a shell wrapper so the
# working directory is set and so `exec` replaces the shell, leaving no parent
# to outlive claude.
#
# Use "${SESSION}:" (trailing colon) to always append at the end of the window
# list, avoiding index collisions when several windows are created at once.
tmux new-window -t "${SESSION}:" -n "$WINDOW" \
  "cd '$AGENTMESH' && exec claude --dangerously-skip-permissions"

# Wait for Claude REPL prompt to appear before sending the skill command.
# Claude Code uses ❯ (U+276F) followed by NBSP (U+00A0) as its prompt.
# Match that specific byte sequence to avoid false-positive on banner text.
# _timeout=300 × sleep 0.2 s = 60 s real-time fallback.
_elapsed=0
_timeout=300
while [ $_elapsed -lt $_timeout ]; do
  # The window now dies with claude, so a vanished window means it failed to
  # start — stop waiting for a prompt that will never appear.
  if ! tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qxF "$WINDOW"; then
    echo "spawn-agent.sh: window '$SESSION:$WINDOW' died before the REPL appeared" >&2
    exit 1
  fi
  if tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null | grep -q $'❯\xc2\xa0'; then
    break
  fi
  sleep 0.2
  _elapsed=$((_elapsed + 1))
done

tmux send-keys -t "$SESSION:$WINDOW" "$SKILL --task $SLUG --project $PROJECT" Enter
