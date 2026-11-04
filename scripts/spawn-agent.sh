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

# Clear any .ready left behind by a dead worker. It is the sidecar's gate for
# typing messages into this window's REPL, and the skill invocation below is
# send-keys'd in too — a nudge arriving while that command line is being typed
# would land in the middle of it. agent_init re-creates .ready once the skill is
# actually running.
rm -f "$AGENTMESH/signals/${SLUG}.ready"

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

# Pacing knobs, overridable so tests need not wait them out.
#   SPAWN_SETTLE         — pause after the prompt first appears, before typing
#   SPAWN_SUBMIT_SETTLE  — pause between typing the command and pressing Enter
#   SPAWN_VERIFY_DELAY   — pause after Enter before checking it took
#   SPAWN_SUBMIT_TRIES   — Enter presses allowed before giving up
: "${SPAWN_SETTLE:=1}"
: "${SPAWN_SUBMIT_SETTLE:=0.3}"
: "${SPAWN_VERIFY_DELAY:=0.5}"
: "${SPAWN_SUBMIT_TRIES:=5}"

LOG="$AGENTMESH/signals/events.log"
_log() {
  printf '%s\tspawn-agent  \t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$SLUG" >> "$LOG" 2>/dev/null || true
}

# Claude Code's input prompt is ❯ (U+276F) followed by NBSP (U+00A0). A message
# already submitted is echoed into the history with ❯ and a *plain* space, so the
# NBSP form identifies the live input line specifically.
PROMPT=$'❯\xc2\xa0'
COMMAND="$SKILL --task $SLUG --project $PROJECT"

window_alive() {
  tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qxF "$WINDOW"
}

# Wait for Claude REPL prompt to appear before sending the skill command.
# Match that specific byte sequence to avoid false-positive on banner text.
# _timeout=300 × sleep 0.2 s = 60 s real-time fallback.
_elapsed=0
_timeout=300
_prompt_seen=false
while [ $_elapsed -lt $_timeout ]; do
  # The window now dies with claude, so a vanished window means it failed to
  # start — stop waiting for a prompt that will never appear.
  if ! window_alive; then
    echo "spawn-agent.sh: window '$SESSION:$WINDOW' died before the REPL appeared" >&2
    exit 1
  fi
  if tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null | grep -qF "$PROMPT"; then
    _prompt_seen=true
    break
  fi
  sleep 0.2
  _elapsed=$((_elapsed + 1))
done
$_prompt_seen || _log "spawn-prompt-timeout"

# The prompt is drawn on the REPL's first render, while startup notices (update
# check, MCP servers connecting, auth warnings) are still re-rendering the
# screen. Keys typed into that window were occasionally lost, so give it a beat.
sleep "$SPAWN_SETTLE"

# Type the command and submit it as two separate sends — the same fix
# notify-worker.sh carries. One send-keys writes text and Enter to the pty as a
# single burst, which Claude Code can read as a paste: the Enter is inserted into
# the draft instead of submitting it, and the prompt sits there unsent. Whether
# the burst is split across reads is timing-dependent, which is why this only
# happened some of the time. -l keeps tmux from interpreting the text as key names.
if ! tmux send-keys -t "$SESSION:$WINDOW" -l "$COMMAND" 2>/dev/null; then
  echo "spawn-agent.sh: could not type the skill command into '$SESSION:$WINDOW'" >&2
  exit 1
fi
sleep "$SPAWN_SUBMIT_SETTLE"

# draft_pending — true while the input line still holds the command, i.e. it was
# typed but not submitted. Matched on "--task <slug>" rather than the skill name:
# an Enter that lands while the slash-command menu is open can accept a
# completion, rewriting "/implementer" to its plugin-qualified form, and that is
# still an unsent draft. A pane that cannot be captured is not a draft; the
# liveness check below handles a window that has gone.
draft_pending() {
  tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null \
    | grep -F "$PROMPT" | grep -qF -- "--task $SLUG"
}

# Press Enter, then confirm it took. Nothing used to check, so a swallowed Enter
# left the task in Ready behind a .launching flag for its full 5-minute expiry —
# and since the window was alive, adoption would never have repaired it anyway.
_tries=0
while [ $_tries -lt "$SPAWN_SUBMIT_TRIES" ]; do
  tmux send-keys -t "$SESSION:$WINDOW" Enter 2>/dev/null || true
  _tries=$((_tries + 1))
  sleep "$SPAWN_VERIFY_DELAY"
  if ! window_alive; then
    echo "spawn-agent.sh: window '$SESSION:$WINDOW' died after the skill command was sent" >&2
    exit 1
  fi
  if ! draft_pending; then
    [ $_tries -gt 1 ] && _log "spawn-submit-retried:$_tries"
    _log "spawn-submitted"
    exit 0
  fi
done

# Still a draft. Kill the window rather than leave it holding an unsent prompt:
# a live window hides the task from adoption and blocks its name, whereas a
# non-zero exit makes the launcher clear .launching and retry on its next scan.
_log "spawn-submit-unconfirmed"
tmux kill-window -t "$SESSION:$WINDOW" 2>/dev/null || true
echo "spawn-agent.sh: skill command was typed into '$SESSION:$WINDOW' but never submitted" >&2
exit 1
