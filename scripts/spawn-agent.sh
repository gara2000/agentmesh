#!/usr/bin/env bash
# spawn-agent.sh — launch a Claude agent in a new tmux window
# Usage: spawn-agent.sh <session> <window-name> <skill> <task-slug> <project> [<workdir> [<model>]]
#   <workdir> — the worker's working directory: the task's `Repo:` line, resolved
#               by the launcher. Defaults to the agentmesh repo.
#   <model>   — passed to claude as --model, unvalidated; empty or absent means
#               no --model at all (Claude Code's own default).
#
# Exit codes: 0 running, 1 failed to start, 3 Claude rejected <model>.
set -euo pipefail

if [[ $# -lt 5 || $# -gt 7 ]]; then
  echo "Usage: spawn-agent.sh <session> <window-name> <skill> <task-slug> <project> [<workdir> [<model>]]" >&2
  exit 1
fi

SESSION=$1
WINDOW=$2
SKILL=$3
SLUG=$4
PROJECT=$5

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKDIR="${6:-$AGENTMESH}"
MODEL="${7:-}"

# Checked before any window exists: a `cd` that fails inside the window kills it
# straight away, which would surface only as "died before the REPL appeared".
if [[ ! -d "$WORKDIR" ]]; then
  echo "spawn-agent.sh: working directory '$WORKDIR' does not exist" >&2
  exit 1
fi

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
# %q, not hand-written single quotes: the directory comes from a task
# description and may hold spaces or quotes of its own.
CLAUDE_CMD="exec claude --dangerously-skip-permissions"
if [[ -n "$MODEL" ]]; then
  # %q for the same reason as the directory: the value is unvalidated and may
  # come straight from a task description.
  CLAUDE_CMD="$CLAUDE_CMD --model $(printf '%q' "$MODEL")"
fi
# The NoteCove CLI reads .notecove from its working directory, else $HOME. A
# worker started in its task's Repo: directory has none there, so every raw
# `notecove` call it made used ~/.notecove — whatever profile and project scope
# that happens to hold — instead of the one bootstrap.sh wrote here, and failed
# with "No running Notecove instance found for profile …". Pin it for the whole
# Claude process so it holds in every Bash call, sourced helper or not.
ENV_CMD=""
if [[ -f "$AGENTMESH/.notecove" ]]; then
  ENV_CMD="export NOTECOVE_CONFIG_PATH=$(printf '%q' "$AGENTMESH/.notecove") && "
fi
tmux new-window -t "${SESSION}:" -n "$WINDOW" \
  "cd $(printf '%q' "$WORKDIR") && ${ENV_CMD}$CLAUDE_CMD"

# Pacing knobs, overridable so tests need not wait them out.
#   SPAWN_SETTLE         — pause after the prompt first appears, before typing
#   SPAWN_SUBMIT_SETTLE  — pause between typing the command and pressing Enter
#   SPAWN_VERIFY_DELAY   — pause after Enter before checking it took
#   SPAWN_SUBMIT_TRIES   — Enter presses allowed before giving up
#   SPAWN_MODEL_TRIES    — pane checks for a model rejection after submitting
#   SPAWN_MODEL_POLL     — pause between those checks (30 × 0.5s = 15s)
: "${SPAWN_SETTLE:=1}"
: "${SPAWN_MODEL_TRIES:=30}"
: "${SPAWN_MODEL_POLL:=0.5}"
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

# accept_trust_dialog <pane-text>
#
# Claude asks "Is this a project you … trust?" the first time it starts in a
# directory — which, with a task's `Repo:` line, is the first worker in any new
# repository. The highlighted default is "No, exit", so the blind Enter that
# follows a prompt timeout would quit Claude, kill the window, and have the
# launcher retry that every scan forever.
#
# The user named this directory in the task, which is the trust decision; the
# worker runs with --dangerously-skip-permissions regardless. So: move to
# "Yes, I trust this folder" and press Enter ONLY once the cursor is verified on
# it — never an Enter that could land on "No, exit".
_trust_tries=0
accept_trust_dialog() {
  printf '%s' "$1" | grep -qF "Yes, I trust this folder" || return 0
  [ "$_trust_tries" -lt 5 ] || return 0
  _trust_tries=$((_trust_tries + 1))
  if ! printf '%s' "$1" | grep -qE '❯.{0,3}Yes, I trust this folder'; then
    tmux send-keys -t "$SESSION:$WINDOW" Down 2>/dev/null || true
    sleep "$SPAWN_SUBMIT_SETTLE"
  fi
  if tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null \
      | grep -qE '❯.{0,3}Yes, I trust this folder'; then
    tmux send-keys -t "$SESSION:$WINDOW" Enter 2>/dev/null || true
    _log "spawn-trust-accepted"
  fi
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
  _pane=$(tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null || true)
  if printf '%s' "$_pane" | grep -qF "$PROMPT"; then
    _prompt_seen=true
    break
  fi
  accept_trust_dialog "$_pane"
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

# model_check — only when a model was passed. Claude does NOT refuse an unknown
# model at startup: it prints a warning banner (which also appears for valid ids
# newer than this Claude Code, so it proves nothing) and draws its prompt as
# usual. The rejection only comes as the reply to the first message — the skill
# command just submitted — after which the REPL idles at its prompt. Left alone
# that window would hide the task from pickup and adoption forever, so watch for
# the first reply: the rejection text means exit 3; any other reply, or none
# within the window, counts as accepted. Never kill on absence of evidence.
MODEL_REJECTED_TEXT="issue with the selected model"
model_check() {
  [[ -n "$MODEL" ]] || return 0
  local i=0 pane
  while [ $i -lt "$SPAWN_MODEL_TRIES" ]; do
    if ! window_alive; then
      echo "spawn-agent.sh: window '$SESSION:$WINDOW' died after the skill command was sent" >&2
      exit 1
    fi
    pane=$(tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null || true)
    if printf '%s' "$pane" | grep -qF "$MODEL_REJECTED_TEXT"; then
      return 1
    fi
    # ⏺ marks Claude's first reply (or tool call): it answered on this model.
    if printf '%s' "$pane" | grep -qF '⏺'; then
      return 0
    fi
    sleep "$SPAWN_MODEL_POLL"
    i=$((i + 1))
  done
  return 0
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
    if ! model_check; then
      # The value goes into a tab-separated log field: no tabs or newlines.
      _log "spawn-model-rejected:$(printf '%s' "$MODEL" | tr -d '\t\n')"
      tmux kill-window -t "$SESSION:$WINDOW" 2>/dev/null || true
      echo "spawn-agent.sh: Claude rejected model '$MODEL'" >&2
      exit 3
    fi
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
