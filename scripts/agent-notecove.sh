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

# nc_run / nc_ref. Every NoteCove call below goes through nc_run: it closes
# stdin and bounds the call, so an ambiguous slug fails fast instead of blocking
# the agent on an interactive prompt it cannot see.
# shellcheck source=notecove-ref.sh
source ~/agentmesh/scripts/notecove-ref.sh

# Longest comment body NoteCove will accept. Measured, not documented: 996
# characters post, 997 is rejected with rc=1 and no output at all. Comments are
# meant to be a few sentences anyway, so anything approaching this is already
# wrong — but it must fail loudly rather than silently, because a dropped
# summary hands the user a task in Attention with no explanation of why.
COMMENT_MAX_CHARS=900

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
    # The unambiguous form of this slug. A short slug is a uniquePrefix — unique
    # only when it was read — so an agent that has been running for a while can
    # be holding one that now resolves to several tasks. Everything below
    # addresses the task by TASK_REF; SLUG stays the local file identifier.
    # Exported so a skill making its own raw CLI calls can use it too.
    TASK_REF=$(nc_ref "$SLUG")
    export TASK_REF
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
    if ! nc_run task change "$(_task_ref)" --state "$state"; then
        rm -f "${SIGNALS}/${SLUG}.self-state"
        return 1
    fi
}

# _task_ref — the slug to address the task by.
#
# Normally TASK_REF, set by agent_init. Falls back to resolving on the spot so a
# helper called from a shell that lost its state (a new Bash invocation that
# sourced this file but skipped agent_init) still addresses the task correctly
# rather than re-introducing the ambiguous short slug.
_task_ref() {
    if [ -n "${TASK_REF:-}" ]; then
        printf '%s' "$TASK_REF"
    else
        nc_ref "$SLUG"
    fi
}

# _log_event <event-type>
_log_event() {
    printf '%s\tagent        \t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${SLUG:--}" \
        >> ~/agentmesh/signals/events.log 2>/dev/null || true
}

# resume_work
#
# Put the task back in Doing. Call it as the first action of every working turn —
# on startup, and again each time a message from the sidecar puts you back to
# work. `Doing` means "an agent is working on this right now"; `Attention` means
# "the agent is finished for now and the user has the task". A task left in
# Attention while the agent works misreports both.
resume_work() {
    # A new working turn owes the user a new summary. Clearing the marker here
    # is what makes "post a summary before handing the task back" enforceable:
    # request_attention checks it and writes a fallback comment if this turn
    # produced nothing.
    rm -f "${SIGNALS}/${SLUG}.summary-posted"
    set_state "Doing"
}

# post_summary <text>
#
# One brief comment describing what the agent just did. Keep it to a few
# sentences: comments are a notification surface, not a document store. Anything
# longer than a short paragraph belongs in a NoteCove note, with the comment
# pointing at it.
#
# The result is checked, which the first version of this did not do. NoteCove
# rejects a body over COMMENT_MAX_CHARS with rc=1 and no output whatsoever, so an
# over-long summary vanished silently while request_attention still set Attention
# — handing the user a task with nothing said about it. Over-length bodies are
# therefore truncated rather than dropped, and a genuine failure is retried once
# and then logged.
#
# Returns 0 only if a comment actually landed.
post_summary() {
    local text="$1"

    if [ -z "$text" ]; then
        return 1
    fi

    # Count characters, not bytes: the limit is on the stored string.
    if [ "${#text}" -gt "$COMMENT_MAX_CHARS" ]; then
        text="${text:0:$COMMENT_MAX_CHARS}… (truncated — see the task folder notes)"
        _log_event "summary-truncated"
    fi

    local attempt
    for attempt in 1 2; do
        if nc_run task comments add "$(_task_ref)" --user "$AGENT_HANDLE" "$text"; then
            : > "${SIGNALS}/${SLUG}.summary-posted"
            return 0
        fi
        sleep 2
    done

    _log_event "summary-post-failed"
    echo "[agent-notecove] WARNING: the summary comment did not post." >&2
    echo "[agent-notecove] The user will see no explanation on this task." >&2
    return 1
}

# _ensure_summary <fallback-text>
#
# Guarantee the user is told something before the task leaves the agent's hands.
# If this turn already posted a summary, do nothing; otherwise post the fallback.
#
# This exists because "always comment before handing back" was a rule in the
# skills and nothing enforced it. A skipped comment, or one silently rejected for
# being too long, leaves the user staring at a task in Attention with no idea
# what is wanted — which is indistinguishable from a wedged agent.
_ensure_summary() {
    local fallback="$1"
    [ -f "${SIGNALS}/${SLUG}.summary-posted" ] && return 0
    _log_event "summary-fallback"
    post_summary "$fallback" || true
}

# request_attention [<state>] [<summary>]
#
# Hand the task back to the user: post a summary if one has not been posted
# since the last resume_work, set <state> (normally Attention), and return.
#
# It does NOT block, and nothing after it in the same turn will be reached by a
# reply — end your turn once it returns. The sidecar types a message into this
# worker's REPL when the user responds, which starts a fresh turn.
#
# Prefer calling post_summary yourself with something specific; the <summary>
# argument and the generic fallback are safety nets, not the intended path.
request_attention() {
    local state="${1:-Attention}"
    local summary="${2:-}"

    if [ -n "$summary" ]; then
        post_summary "$summary" || true
    fi
    _ensure_summary "Handing this task back for your input. No summary was \
posted for this round of work — check the task folder notes for the latest \
state, and reply here with what you want done next."

    set_state "$state"
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
    nc_run task show "$(_task_ref)" --json \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('stateId',''))"
}

# finish_task <state> <project> [<summary>]
#
# Post a closing summary, set the task's terminal state, and run the cleanup that
# has to happen with it.
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
    local summary="${3:-}"

    if [ -n "$summary" ]; then
        post_summary "$summary" || true
    fi
    # Same guarantee as request_attention, and it matters more here: this is the
    # last thing that will ever be written to the task.
    _ensure_summary "Closing this task as ${state}."

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
    local summary="${2:-}"

    if [ -n "$summary" ]; then
        post_summary "$summary" || true
    fi
    _ensure_summary "Stopping work: you moved this task to a terminal state. \
Dependent tasks have been released and this task's sidecar stopped."

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
