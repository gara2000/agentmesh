#!/usr/bin/env bash
# notecove-ref.sh — the one safe way to call the NoteCove CLI with a task slug.
#
# Source this file, then use:
#   nc_run <args...>        run the CLI: stdin closed, bounded by a timeout
#   nc_ref <short-slug>     a slug that is safe to hand to the CLI
#   nc_task_id <short-slug> the task internal id, for matching event frames
#   nc_resolve_profile [<id>] the NoteCove profile id to use (see below)
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
#
# BASH_SOURCE is empty when an agent sources this from zsh (the Claude Code Bash
# tool's shell on macOS), and `dirname ""` is the caller's cwd. zsh sets $0 to
# the file being sourced, so that is the fallback.
_NC_DEFAULT_SIGNALS=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/signals

# The CLI reads its config (.notecove: profile id, token, project scope) from
# the current directory, else $HOME. Daemons happen to run from the repo root,
# but a worker runs in its task's Repo: directory, where the lookup fell through
# to ~/.notecove — a different profile and project scope — and every call failed
# with "No running Notecove instance found for profile …" (WORK-2cg). Pin it to
# the file bootstrap.sh's `notecove init` writes here. An explicit setting wins.
if [[ -z "${NOTECOVE_CONFIG_PATH:-}" && -f "${_NC_DEFAULT_SIGNALS%/signals}/.notecove" ]]; then
    export NOTECOVE_CONFIG_PATH="${_NC_DEFAULT_SIGNALS%/signals}/.notecove"
fi

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
#
# NOTECOVE_BIN is a command line ("node /path/cli.cjs"), deliberately left
# unquoted so it splits into words. zsh does not word-split parameters, so an
# agent that sources this into its zsh shell ran a program literally named
# "node /path/cli.cjs" — every helper call failed, and resume_work silently did
# not set Doing. sh_word_split restores bash's behaviour for this call only;
# local_options puts the caller's shell back as it was on return.
nc_run() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt local_options sh_word_split
    fi
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

# nc_resolve_profile [<explicit-id>]
#
# Print the NoteCove profile id to use. The id is machine-specific, so it must
# not be a hardcoded default that every other checkout silently inherits.
# First match wins:
#
#   a. the explicit id passed as $1 (the caller's --profile)
#   b. $AGENTMESH_PROFILE       a profile id, used verbatim
#   c. $AGENTMESH_PROFILE_NAME  a profile name, looked up via `notecove profiles`
#                               (case-insensitive). No default name. If it is set
#                               but matches zero or several profiles this FAILS
#                               rather than falling through to (d): the user
#                               asked for a specific profile, and quietly using a
#                               different one would act on the wrong data.
#   d. the historical id, so existing setups keep working unchanged
#
# Returns 1 (message on stderr) when (c) cannot be resolved.
_NC_FALLBACK_PROFILE="kmq9h71tepf95rac2b59xdbsq2"

nc_resolve_profile() {
    local explicit="${1:-}"

    if [[ -n "$explicit" ]]; then
        printf '%s' "$explicit"; return 0
    fi
    if [[ -n "${AGENTMESH_PROFILE:-}" ]]; then
        printf '%s' "$AGENTMESH_PROFILE"; return 0
    fi
    if [[ -n "${AGENTMESH_PROFILE_NAME:-}" ]]; then
        local listing id
        listing=$(nc_run profiles 2>/dev/null) || {
            echo "Error: 'notecove profiles' failed; cannot resolve AGENTMESH_PROFILE_NAME='$AGENTMESH_PROFILE_NAME'" >&2
            return 1
        }
        id=$(printf '%s' "$listing" | WANT="$AGENTMESH_PROFILE_NAME" python3 -c '
import os, re, sys

want = os.environ["WANT"].strip().casefold()
ids, cur = [], None
for line in sys.stdin:
    if re.match(r"^\s+[A-Za-z0-9]+\s*$", line) and ":" not in line:
        cur = line.strip()
    else:
        m = re.match(r"^\s+Name:\s*(.*?)\s*$", line)
        if m and cur and m.group(1).casefold() == want:
            ids.append(cur)
if len(ids) == 1:
    print(ids[0], end="")
else:
    sys.exit(2 if not ids else 3)
') && [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }
        echo "Error: AGENTMESH_PROFILE_NAME='$AGENTMESH_PROFILE_NAME' did not match exactly one NoteCove profile (see 'notecove profiles'); set AGENTMESH_PROFILE to an id instead" >&2
        return 1
    fi
    printf '%s' "$_NC_FALLBACK_PROFILE"
}

# launcher_model_args [<model>] — the launcher's model arguments, as one string
# ready to paste into its command line (each value %q-quoted).
#
#   --model <id>                 from <model> (`agentmesh start --model`), else
#                                $AGENTMESH_MODEL; omitted when neither is set
#   --type-model <handle>=<id>   one per non-empty $AGENTMESH_MODEL_<TYPE>, the
#                                handle lower-cased with `_` -> `-`, sorted
#
# The launcher reads no AGENTMESH_MODEL* variable itself: its tmux window
# inherits the tmux *server's* environment, not the shell that ran
# `agentmesh start`, so a variable set there would silently not arrive — and a
# stale one from whenever the server started would. Turning the caller's env
# into arguments here makes the command line the whole truth, which is also what
# lets bootstrap.sh notice that it changed. Shared by bootstrap.sh and
# `agentmesh switch`. No ${!var}: this file is also sourced from zsh.
launcher_model_args() {
    local model="${1:-${AGENTMESH_MODEL:-}}"
    if [ -n "$model" ]; then
        printf ' --model %q' "$model"
    fi
    env | LC_ALL=C sort | while IFS= read -r line; do
        case "$line" in
            AGENTMESH_MODEL_?*=?*) ;;
            *) continue ;;
        esac
        name=${line%%=*}
        handle=$(printf '%s' "${name#AGENTMESH_MODEL_}" | tr 'A-Z_' 'a-z-')
        printf ' --type-model %q' "$handle=${line#*=}"
    done
}

# launcher_command <agentmesh> <project> <profile> <max-workers> <poll-interval> [<model>]
#
# The launcher window's command: launcher.py inside its restart loop. One
# builder for bootstrap.sh and `agentmesh switch`, because bootstrap compares it
# with signals/launcher.cmd to decide whether a running launcher's configuration
# changed — two hand-written copies would differ by a byte and restart it on
# every start. \$(date) is escaped so it evaluates inside the loop.
launcher_command() {
    local am="$1" project="$2" profile="$3" max="$4" poll="$5" model="${6:-}"
    printf '%s' "cd $am && while true; do python3 $am/scripts/launcher.py --project $project --profile $profile --max-workers $max --poll-interval $poll$(launcher_model_args "$model"); printf '%s\tlauncher     \tprocess-exited-restarting\t-\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" >> '$am/signals/events.log'; echo '[launcher] exited — restarting in 5s'; sleep 5; done"
}

fi  # _NOTECOVE_REF_SOURCED
