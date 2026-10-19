#!/usr/bin/env bash
# notecove-ref.sh — the one safe way to call the NoteCove CLI with a task slug.
#
# Source this file, then use:
#   nc_run <args...>        run the CLI: stdin closed, bounded by a timeout
#   nc_ref <short-slug>     a slug that is safe to hand to the CLI
#   nc_task_id <short-slug> the task internal id, for matching event frames
#
# ---------------------------------------------------------------------------
# Why stdin must be closed
#
# A short slug is a *uniquePrefix*: unique only at the moment it is read.
# Creating new tasks can lengthen the prefix and make a slug stored earlier
# ambiguous. WORK-7w2 reached that state with work-7w25 and work-7w2p both
# matching.
#
# The CLI does not fail on an ambiguous slug. With stdin on a TTY it PROMPTS:
#
#   Ambiguous slug. Multiple tasks match:
#     1. work-7w25:...   2. work-7w2p:...
#   Pick one (1-2):
#
# Every agentmesh daemon runs in a tmux window, so every daemon has a TTY. The
# call blocks until the timeout fires, every poll, forever — the sidecar for
# WORK-7w2 logged 43 consecutive notecove-call-timed-out events that way, and
# never saw a single comment in between.
#
# With stdin closed the same call returns rc=1 and "Please use a more specific
# slug." immediately. That is the whole point of nc_run: it converts a silent
# permanent hang into a loud fast failure. It is the backstop that holds even
# when slug resolution below has nothing to work with.
#
# ---------------------------------------------------------------------------
# Why resolution is needed on top of that
#
# Failing fast is not the same as working. The full slug (short prefix + unique
# id) cannot become ambiguous, so it is what should reach the CLI. The launcher
# records it in signals/<slug>.full-slug when it spawns the worker, because that
# is the one moment the full slug is known for certain — it came straight out of
# the task list the launcher was already reading.
#
# Short slugs stay in use for tmux window names and signals/ filenames. Those
# are local identifiers and renaming them would invalidate every running
# worker's state. Only what is passed to the NoteCove CLI changes.

# Guard against double-sourcing: these are plain function definitions, but the
# readonly-ish defaults below should not be recomputed.
if [[ -z "${_NOTECOVE_REF_SOURCED:-}" ]]; then
_NOTECOVE_REF_SOURCED=1

: "${NOTECOVE_BIN:=${AGENTMESH_NOTECOVE:-node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs}}"

# Upper bound on any single NoteCove call. Comfortably above a normal
# local-socket response, low enough that a hang costs one poll cycle rather
# than the session. With stdin closed a hang should no longer be reachable,
# but a timeout that is never hit costs nothing.
: "${NC_CALL_TIMEOUT:=30}"

# The signals directory of the repo this file belongs to, resolved once at
# source time. Derived from BASH_SOURCE rather than $HOME/agentmesh so a checkout
# in a git worktree reads and writes its own caches — most callers do not export
# SIGNALS, and silently resolving to a different tree's cache would have the
# daemons of one checkout addressing tasks through another's slug mappings.
_NC_DEFAULT_SIGNALS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/signals

_nc_signals() {
    if [[ -n "${SIGNALS:-}" && -d "${SIGNALS}" ]]; then
        printf '%s' "$SIGNALS"
    else
        printf '%s' "$_NC_DEFAULT_SIGNALS"
    fi
}

# nc_run <args...>
#
# Run the NoteCove CLI. stdin is closed so no prompt can ever block, and the
# call is bounded by NC_CALL_TIMEOUT. Returns the CLI exit code, or 124 on
# timeout.
nc_run() {
    timeout "$NC_CALL_TIMEOUT" $NOTECOVE_BIN "$@" </dev/null
}

# nc_resolve_ref <short-slug>
#
# Resolve a short slug to the full slug by asking NoteCove, and cache it.
# Separated from nc_ref so the cache read stays free of a CLI call.
#
# Matching is deliberately broad: the stored short slug may be shorter than the
# task current slug.short (that is exactly how it became ambiguous), so a
# "<short>:" prefix match on slug.full is the reliable test. A match is only
# accepted when it is unique — two matches means the information needed to tell
# them apart was lost before we got here, and guessing would act on the wrong
# task.
nc_resolve_ref() {
    local short="${1:?nc_resolve_ref: slug required}"
    local signals listing full
    signals=$(_nc_signals)

    listing=$(nc_run task list --limit 200 --json 2>/dev/null) || return 1
    [[ -z "$listing" ]] && return 1

    full=$(printf '%s' "$listing" | SHORT="$short" python3 -c '
import json, os, sys

want = os.environ["SHORT"].strip().lower()
try:
    tasks = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(1)
if not isinstance(tasks, list):
    sys.exit(1)

matches = set()
for t in tasks:
    slug = t.get("slug") or {}
    if not isinstance(slug, dict):
        continue
    full = (slug.get("full") or "").strip()
    short = (slug.get("short") or "").strip()
    if not full:
        continue
    if short.lower() == want or full.lower().startswith(want + ":"):
        matches.add(full)

# Exactly one or nothing. An ambiguous short slug cannot be resolved from the
# short slug alone - the distinguishing part was never recorded - and picking
# one would act on the wrong task.
if len(matches) == 1:
    print(matches.pop())
' 2>/dev/null) || return 1

    [[ -z "$full" ]] && return 1
    printf '%s' "$full" > "${signals}/${short}.full-slug" 2>/dev/null || true
    printf '%s' "$full"
}

# nc_ref <short-slug>
#
# A slug safe to pass to the CLI. Always prints something, so callers can use it
# inline without a null check:
#
#   1. signals/<slug>.full-slug, written by the launcher at spawn time
#   2. resolved from the task list and cached
#   3. the short slug unchanged — with stdin closed this fails fast and loudly
#      rather than hanging, which is the correct behaviour when the full slug is
#      genuinely unrecoverable
nc_ref() {
    local short="${1:?nc_ref: slug required}"
    local signals cached resolved
    signals=$(_nc_signals)

    cached="${signals}/${short}.full-slug"
    if [[ -s "$cached" ]]; then
        tr -d '[:space:]' < "$cached"
        return 0
    fi

    if resolved=$(nc_resolve_ref "$short") && [[ -n "$resolved" ]]; then
        printf '%s' "$resolved"
        return 0
    fi

    printf '%s' "$short"
}

# nc_task_id <short-slug>
#
# The task internal id, cached in signals/<slug>.task-id.
#
# Needed because NoteCove event frames identify their subject by id and nothing
# else:
#
#   {"type":"task.modified","item":{"type":"task","id":"7jphatbqq77qtm4g4x76zz6de5"},...}
#
# There is no slug in the frame at all. The sidecar used to test frames with
# `grep -qF "$SLUG"` on the belief that an id-only frame would still match as a
# substring — it cannot, because the short slug carries a project prefix and a
# hyphen that the id does not (WORK-7jp vs 7jphatbqq77qtm4g4x76zz6de5). That
# grep never matched once, so SSE never triggered a single diff and the sidecar
# was silently poll-only from the day it was written.
#
# Prints nothing and returns 1 if the id cannot be determined; the caller should
# fall back to its poll rather than guessing.
nc_task_id() {
    local short="${1:?nc_task_id: slug required}"
    local signals cached ref task_id
    signals=$(_nc_signals)

    cached="${signals}/${short}.task-id"
    if [[ -s "$cached" ]]; then
        tr -d '[:space:]' < "$cached"
        return 0
    fi

    ref=$(nc_ref "$short")
    task_id=$(nc_run task show "$ref" --json 2>/dev/null | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin).get("id") or "").strip())
except (json.JSONDecodeError, ValueError):
    pass
' 2>/dev/null)

    [[ -z "$task_id" ]] && return 1
    printf '%s' "$task_id" > "$cached" 2>/dev/null || true
    printf '%s' "$task_id"
}

fi  # _NOTECOVE_REF_SOURCED
