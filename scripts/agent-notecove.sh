#!/usr/bin/env bash
# agent-notecove.sh — NoteCove interaction helper for agent skills
#
# Source this file at agent startup, then call:
#   agent_init "<slug>" "<agent-handle>"
#   post_summary "<brief summary of what just happened>"
#   await_user "<state>"        # blocks until the user (or a daemon) changes something
#   read_inbox                  # prints and clears what woke us
#
# NoteCove is the only interaction surface between the agent and the user:
#   - Comments carry the conversation, in both directions.
#   - Notes carry artifacts — plans, findings, questions, anything long.
#   - Task state carries intent; only the agent and the user change it.
#
# There is no orchestrator round-trip and no interface layer. The agent posts a
# comment, sets a state, and blocks; the sidecar wakes it when the user replies.

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
    NUDGE_SEQ=0
    INBOX="${SIGNALS}/${SLUG}.inbox"
    # The launcher sets .launching so its next scan does not spawn a second
    # worker while Claude boots. Claiming the task clears it.
    rm -f "${SIGNALS}/${SLUG}.launching"
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

# await_user <state>
#
# Announce-then-wait. Sets the task to <state> (normally Attention), publishes
# the sequence number the sidecar should fire, then blocks until the inbox has
# something in it.
#
# Two properties worth preserving if this is ever rewritten:
#
#   1. Re-calling it is safe. The announce and the wait are separate, and the
#      wait loop is pure — it writes nothing and fires nothing. Claude Code's
#      Bash tool caps out at 10 minutes, so a long wait WILL be interrupted;
#      re-invoking simply re-enters the loop. (The predecessor wrote to a queue
#      and fired a signal before blocking, so every re-invocation re-signalled.)
#
#   2. The nudge-before-block race is closed by construction. If the sidecar
#      fires while the agent is mid-turn, tmux drops the signal — but the inbox
#      is already non-empty, so this returns immediately instead of blocking on
#      a signal that will never come again.
await_user() {
    local state="${1:-Attention}"

    NUDGE_SEQ=$((NUDGE_SEQ + 1))
    echo "$NUDGE_SEQ" > "${SIGNALS}/${SLUG}.seq"
    notecove task change "$SLUG" --state "$state"

    while [ ! -s "$INBOX" ]; do
        tmux wait-for "${SLUG}-nudge-${NUDGE_SEQ}" 2>/dev/null || true
    done
}

# read_inbox
#
# Prints what woke the agent as line-delimited JSON and clears the inbox.
# Each line is one of:
#   {"kind":"comment","id":...,"author":...,"content":...,"created":...}
#   {"kind":"state-change","from":...,"to":...,"to_name":...}
#
# Consume-and-clear: the agent is responsible for acting on what it reads, since
# a second call returns nothing.
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
# itself partway through. Exit normally afterwards; the watchdog reaps whatever
# is left.
finish_task() {
    local state="${1:?finish_task: state required}"
    local project="${2:?finish_task: project required}"
    notecove task change "$SLUG" --state "$state"
    bash ~/agentmesh/scripts/task-done.sh "$SLUG" "$project"
}
