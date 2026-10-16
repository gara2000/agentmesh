#!/usr/bin/env bash
# notify-worker.sh — deliver a message into a worker's Claude REPL
#
# Sourced by sidecar.sh and pr-monitor.sh; also runnable directly for testing:
#
#   bash scripts/notify-worker.sh <slug>          # deliver now, exit 0 if delivered
#
# This replaces the old `tmux wait-for -S <slug>-nudge-<seq>` signal. A signal can
# only ever reach a worker that is *blocked* inside `tmux wait-for`, which meant
# anything the user said while the agent was working went unseen until the agent
# next chose to wait. Typing the message into the agent's Claude REPL instead
# reaches it in both states: idle at the prompt it starts a new turn, and mid-turn
# Claude Code queues the input and picks it up when the current turn ends.
#
# The message itself is deliberately a bare one-line nudge. The payload stays in
# signals/<slug>.inbox, which is what keeps this generic — comment bodies are
# multi-line free text written by a human and must never be typed into a REPL.

# Tolerate being sourced by a caller that has already set these.
: "${AGENTMESH:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${SIGNALS:=$AGENTMESH/signals}"
: "${LOG:=$SIGNALS/events.log}"

# Pause between typing the text and pressing Enter. Sending both in one go can
# race the REPL's input handling, leaving the text sitting unsubmitted.
: "${NUDGE_SETTLE:=0.3}"

_nw_log() {
  printf '%s\tnotify-worker\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" >> "$LOG"
}

# nudge_message <slug>
#
# One line, no newlines. It has to stand on its own: the agent receiving it may
# have lost all shell state since it last ran, so the message names the helper to
# source rather than assuming the functions are still defined.
nudge_message() {
  printf '%s' "[agentmesh] New activity on $1 — source ~/agentmesh/scripts/agent-notecove.sh and run agent_init if your shell state is gone, then resume_work (back to Doing) and read_inbox, act on what you find, and request_attention only when you next need the user."
}

# mark_pending <slug>
#
# Record that this slug has something undelivered. Written whenever the inbox is
# appended to and cleared only by a successful delivery, so retry_pending_nudge
# can pick up a delivery that could not go through. Without it a failed nudge
# would never be retried: the sidecar's diff only fires on *new* changes, and the
# change it was reporting is already absorbed into the baseline by then.
mark_pending() {
  : > "${SIGNALS}/${1}.pending-delivery"
}

# worker_ready <slug>
#
# Both conditions are required:
#
#   - the worker window exists — there is nothing to type into otherwise;
#   - signals/<slug>.ready exists — spawn-agent.sh types the skill invocation
#     into the REPL once the prompt appears, and a nudge landing in that gap
#     would be typed into the middle of that command line. agent_init touches
#     .ready, so the gate opens only once the skill is actually running.
#
# A tmux that cannot be queried at all fails closed: "no answer" is not read as
# "the window is there".
worker_ready() {
  local slug="$1" windows
  [[ -f "${SIGNALS}/${slug}.ready" ]] || return 1
  windows=$(tmux list-windows -t workers -F '#{window_name}' 2>/dev/null) || return 1
  printf '%s\n' "$windows" | grep -qxF "$slug"
}

# deliver_nudge <slug>
#
# Returns 0 only when the message was actually submitted. Every failure path
# leaves .pending-delivery in place for the retry.
deliver_nudge() {
  local slug="$1"

  if ! worker_ready "$slug"; then
    _nw_log "delivery-deferred-not-ready" "$slug"
    return 1
  fi

  # -l sends the argument literally, so nothing in the text is interpreted as a
  # tmux key name.
  if ! tmux send-keys -t "workers:${slug}" -l "$(nudge_message "$slug")" 2>/dev/null; then
    _nw_log "delivery-failed-send" "$slug"
    return 1
  fi

  sleep "$NUDGE_SETTLE"

  if ! tmux send-keys -t "workers:${slug}" Enter 2>/dev/null; then
    _nw_log "delivery-failed-submit" "$slug"
    return 1
  fi

  rm -f "${SIGNALS}/${slug}.pending-delivery"
  _nw_log "nudge-delivered" "$slug"
  return 0
}

# notify_worker <slug>
#
# The normal entry point: mark pending, then try to deliver.
notify_worker() {
  mark_pending "$1"
  deliver_nudge "$1" || true
}

# retry_pending_nudge <slug>
#
# No-op unless a delivery is outstanding. Called from the sidecar's poll loop so
# a worker that was mid-boot when the change arrived still gets told about it.
retry_pending_nudge() {
  [[ -f "${SIGNALS}/${1}.pending-delivery" ]] || return 0
  deliver_nudge "$1" || true
}

# Direct invocation: notify-worker.sh <slug>
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  slug="${1:?Usage: notify-worker.sh <slug>}"
  deliver_nudge "$slug"
fi
