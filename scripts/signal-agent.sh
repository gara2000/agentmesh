#!/usr/bin/env bash
# signal-agent.sh — orchestrator signal helper for agent skills
#
# Source this file at agent startup, then call:
#   signal_init "<slug>"
#   signal_attention "<event-type>" "<break-state>" ["<alt-break-state>"]
#   signal_fire "<event-type>"   # fire-and-done (reviewers only; no blocking)
#
# Caller responsibilities (must be done BEFORE calling signal_attention):
#   1. Set LOG= (path to events.log)
#   2. Add the event:* comment to NoteCove (user differs per agent type)
#   3. Set task state to Attention: notecove task change $SLUG --state Attention
#
# The SIGNAL_SEQ variable is kept in the calling shell's scope so it persists
# across multiple signal_attention calls in the same session.

SIGNAL_SEQ=0

# signal_init <slug>
# Sets the global SLUG used by all subsequent signal_* calls.
signal_init() {
    SLUG="$1"
}

# signal_attention <event-type> <break-state> [<alt-break-state>]
#
# Increments SIGNAL_SEQ, writes it to signals/<slug>.seq, appends
# "<slug>:<event-type>" to the queue, fires worker-any-event, then blocks
# in a loop until the task state equals <break-state> (or <alt-break-state>).
#
# The blocking loop re-calls tmux wait-for internally so Claude Code only
# wakes up when the expected state is confirmed (or after the 10-minute
# Bash tool max timeout, at which point the outer block is re-called).
signal_attention() {
    local event_type="$1"
    local break_state="$2"
    local alt_break_state="${3:-}"

    SIGNAL_SEQ=$((SIGNAL_SEQ + 1))
    echo "$SIGNAL_SEQ" > ~/agentmesh/signals/${SLUG}.seq
    echo "${SLUG}:${event_type}" >> ~/agentmesh/signals/queue
    tmux wait-for -S worker-any-event
    while true; do
        tmux wait-for "${SLUG}-resume-${SIGNAL_SEQ}" 2>/dev/null || true
        local state
        state=$(notecove task show "$SLUG" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['stateId'])")
        if [ "$state" = "$break_state" ]; then break; fi
        if [ -n "$alt_break_state" ] && [ "$state" = "$alt_break_state" ]; then break; fi
    done
}

# signal_fire <event-type>
#
# Appends "<slug>:<event-type>" to the queue and fires worker-any-event.
# Does NOT block — for fire-and-done agents (plan-reviewer, pr-reviewer)
# that set Attention and exit immediately without waiting for a resume.
#
# NOTE: Do NOT call this if the agent needs to know the outcome.
# NOTE: Do NOT update signals/<slug>.seq — reviewer must not overwrite the
#       worker's seq file (the orchestrator uses it to resume the worker).
signal_fire() {
    local event_type="$1"
    echo "${SLUG}:${event_type}" >> ~/agentmesh/signals/queue
    tmux wait-for -S worker-any-event
}
