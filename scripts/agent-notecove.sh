#!/usr/bin/env bash
# agent-notecove.sh — NoteCove interaction helper for agent skills
#
# Source this file at agent startup, then call:
#   agent_init "<slug>" "<agent-handle>"
#   resume_work                 # back to Doing — call this whenever you start working
#   post_summary "<brief summary of what just happened>"
#   request_attention "<state>" # hand the task back to the user, then END YOUR TURN
#   read_inbox                  # what the sidecar had to tell you
#
# NoteCove is the only interaction surface between the agent and the user:
#   - Comments carry the conversation, in both directions.
#   - Notes carry artifacts — plans, findings, questions, anything long.
#   - Task state carries intent; only the agent and the user change it.
#
# There is no orchestrator round-trip and no interface layer.
#
# The agent does NOT block waiting to be woken. It posts a comment, sets
# Attention, and ends its turn; the sidecar types a message into its Claude REPL
# when something changes. The predecessor to this blocked inside
# `tmux wait-for <slug>-nudge-<seq>`, which could only ever reach an agent that
# was already waiting — anything the user said while the agent was working went
# unseen until the agent next chose to wait.

SIGNALS=~/agentmesh/signals

# agent_init <slug> <agent-handle>
#
# <agent-handle> must match the --user value the agent passes to
# `notecove task comments add`. The sidecar compares comment authors against it
# to decide which comments are the agent's own, so a mismatch makes the agent
# wake itself on its own writes.
agent_init() {
    SLUG="$1"
    AGENT_HANDLE="$2"
    INBOX="${SIGNALS}/${SLUG}.inbox"
    # The launcher sets .launching so its next scan does not spawn a second
    # worker while Claude boots. Claiming the task clears it.
    rm -f "${SIGNALS}/${SLUG}.launching"
    # .ready is the sidecar's delivery gate. Until it exists the sidecar records
    # changes in the inbox but types nothing into the REPL, because spawn-agent.sh
    # may still be sending the skill invocation and a nudge would land in the
    # middle of that command line. Reaching this line means the skill is running.
    : > "${SIGNALS}/${SLUG}.ready"
}

# set_state <state>
#
# Every state change the agent makes goes through here. The state name is written
# to signals/<slug>.self-state BEFORE the CLI call, which is what lets the sidecar
# tell "I moved this" from "the user moved this": its diff compares the task's
# stateName against that marker and suppresses a match rather than reporting it
# back. Writing the marker first closes the race — there is no window in which
# the sidecar can observe the new state without also seeing the marker.
#
# On failure the marker is removed again, so a change that never happened cannot
# swallow a genuine user move to that same state.
#
# (The sidecar has always filtered the agent's own *comments* by author. State
# changes had no such filter, so the agent's own Doing/Attention writes came
# straight back into its own inbox — harmless while it blocked on a signal, but
# a self-inflicted mid-work interruption once the sidecar types into the REPL.)
set_state() {
    local state="${1:?set_state: state required}"
    printf '%s' "$state" > "${SIGNALS}/${SLUG}.self-state"
    if ! notecove task change "$SLUG" --state "$state"; then
        rm -f "${SIGNALS}/${SLUG}.self-state"
        return 1
    fi
}

# resume_work
#
# Put the task back in Doing. Call it as the first action of every working turn —
# on startup, and again each time a message from the sidecar puts you back to
# work. `Doing` means "an agent is working on this right now"; `Attention` means
# "the agent is finished for now and the user has the task". A task left in
# Attention while the agent works misreports both.
resume_work() {
    set_state "Doing"
}

# post_summary <text>
#
# One brief comment describing what the agent just did. Keep it to a few
# sentences: comments are a notification surface, not a document store. Anything
# longer than a short paragraph belongs in a NoteCove note, with the comment
# pointing at it.
post_summary() {
    local text="$1"
    notecove task comments add "$SLUG" --user "$AGENT_HANDLE" "$text"
}

# request_attention [<state>]
#
# Hand the task back to the user: set <state> (normally Attention) and return.
#
# It does NOT block, and nothing after it in the same turn will be reached by a
# reply — end your turn once it returns. The sidecar types a message into this
# worker's REPL when the user responds, which starts a fresh turn.
#
# Post the summary comment BEFORE calling this, or the user is handed a task with
# no explanation of what is wanted.
request_attention() {
    set_state "${1:-Attention}"
}

# await_user [<state>] — DEPRECATED. Kept only so a worker still running
# pre-3.5.0 skill text does not hang forever on a signal nobody fires any more.
# It is request_attention: it announces and returns, it does not wait.
await_user() {
    echo "[agent-notecove] await_user is deprecated: the sidecar now delivers" >&2
    echo "[agent-notecove] messages into your REPL. Use request_attention and" >&2
    echo "[agent-notecove] end your turn." >&2
    request_attention "${1:-Attention}"
}

# read_inbox
#
# Prints what the sidecar had to say as line-delimited JSON and clears the inbox.
# Each line is one of:
#   {"kind":"comment","id":...,"author":...,"content":...,"created":...}
#   {"kind":"state-change","from":...,"to":...,"to_name":...}
#   {"kind":"pr-merged","url":...,"note":...}
#
# Consume-and-clear: the agent is responsible for acting on what it reads, since
# a second call returns nothing.
#
# Printing nothing is normal, not an error. A nudge can arrive for a change the
# agent has already drained, so an empty result means "nothing new, carry on".
read_inbox() {
    [ -s "$INBOX" ] || return 0
    cat "$INBOX"
    : > "$INBOX"
}

# task_state
#
# Current state ID of the task, for agents that need to check whether the user
# moved it somewhere terminal.
task_state() {
    notecove task show "$SLUG" --json \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('stateId',''))"
}

# finish_task <state> <project>
#
# Set the task's terminal state and run the cleanup that has to happen with it.
# Use this instead of a bare `notecove task change --state Done`.
#
#   finish_task "Done" "$PROJECT"        # user approved
#   finish_task "Won't Do" "$PROJECT"    # user aborted
#
# Setting the state is not sufficient on its own: tasks blocked on this one have
# to be released, and this task's sidecar and pr-monitor have to be stopped.
# Nothing else does either — before the NoteCove refactor the orchestrator's
# event handlers ran this, and they no longer exist.
#
# Safe to call from inside the worker: task-done.sh unblocks dependents first and
# never kills the calling worker's own window, so the script cannot terminate
# itself partway through. Exit normally afterwards; the reaper collects whatever
# is left.
finish_task() {
    local state="${1:?finish_task: state required}"
    local project="${2:?finish_task: project required}"
    set_state "$state"
    bash ~/agentmesh/scripts/task-done.sh "$SLUG" "$project"
}

# finish_cleanup <project>
#
# The cleanup half of finish_task, without setting state. Call this when the
# *user* moved the task to a terminal state themselves — you must not overwrite
# their state, but dependents still need releasing and your sidecar still needs
# stopping, and nothing else does either.
#
#   finish_cleanup "$PROJECT"   # user set Done / Won't Do in NoteCove
finish_cleanup() {
    local project="${1:?finish_cleanup: project required}"
    bash ~/agentmesh/scripts/task-done.sh "$SLUG" "$project"
}

# watch_pr <pr-url>
#
# Start a pr-monitor for this task. It polls the PR and, when it is merged,
# writes a `pr-merged` entry to your inbox and delivers a message to your REPL —
# so a user who merges on GitHub instead of commenting `approve` still gets a
# response.
#
# Call this right after creating the PR, before request_attention. Idempotent: a
# second call while one is already running is a no-op.
watch_pr() {
    local pr_url="${1:?watch_pr: pr-url required}"
    local window="pr-mon-${SLUG}"
    if tmux list-windows -t orchestrator -F '#{window_name}' 2>/dev/null | grep -qxF "$window"; then
        return 0
    fi
    tmux new-window -d -t 'orchestrator:' -n "$window" \
        "bash ~/agentmesh/scripts/pr-monitor.sh '$SLUG' '$pr_url'" 2>/dev/null || true
}
