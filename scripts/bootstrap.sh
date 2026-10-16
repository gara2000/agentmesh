#!/usr/bin/env bash
# bootstrap.sh — initialize the AgentMesh runtime: notecove init, signals dir, daemons
# Usage: bootstrap.sh --project <PROJECT> [--profile <profile-id>] [--max-workers <n>]
#                     [--poll-interval <seconds>] [--clean]
#
# This is idempotent and self-repairing. Running it against a live system brings
# up whatever daemon is missing and touches nothing else: no worker is killed, no
# sidecar is restarted, no inbox is cleared. That is what lets a newly added
# daemon — or one that crashed — be started without an `agentmesh stop`, which
# would destroy every running worker.
#
# The destructive init — truncating the registry, wiping the signal files,
# killing stray sidecars — runs only on a COLD start, i.e. when there is nothing
# running for it to destroy. `--clean` forces it.
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS=$AGENTMESH/scripts
SIGNALS=$AGENTMESH/signals

# notecove is a shell function (not a binary), so call the CLI directly.
# Overridable so the tests can point it at a stub; nothing else sets it.
NOTECOVE="${AGENTMESH_NOTECOVE:-node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs}"

# Parse arguments
PROJECT=""
PROFILE="kmq9h71tepf95rac2b59xdbsq2"
MAX_WORKERS="30"
POLL_INTERVAL="30"
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)       PROJECT="$2";       shift 2 ;;
    --profile)       PROFILE="$2";       shift 2 ;;
    --max-workers)   MAX_WORKERS="$2";   shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --clean)         CLEAN=1;            shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "Error: --project is required" >&2
  exit 1
fi

LOG="$SIGNALS/events.log"

log_event() {
  printf '%s\tlauncher     \t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" >> "$LOG"
}

_window_exists() {
  tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null | grep -qx "$1"
}

_heartbeat_age() {
  local hb="$SIGNALS/launcher.heartbeat"
  [ -f "$hb" ] || { echo 9999; return; }
  python3 -c "import os,time; print(int(time.time() - os.path.getmtime('$hb')))"
}

# Is there live runtime state that the cold-start wipe would destroy?
#
# Any one of these is enough, and the test deliberately errs towards "yes":
# wrongly skipping the wipe costs a few stale files, while wrongly running it
# deletes an inbox holding the reply a worker is blocked on.
_runtime_is_live() {
  [[ -s "$SIGNALS/workers" ]] && return 0
  tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null \
    | grep -qE '^(side-|pr-mon-)' && return 0
  tmux list-panes -s -t workers -F "#{pane_current_command}" 2>/dev/null \
    | grep -qx claude && return 0
  return 1
}

# ---------------------------------------------------------------------------
# 0a. Init NoteCove.
#     --events requests the events:subscribe permission the sidecars use for push
#     change detection. The first run after adding it may need approval in the
#     NoteCove desktop app; until granted, sidecars fall back to their poll
#     interval and log sse-unavailable:no-permission.
#     Idempotent, and safe against live workers — `agentmesh switch` does exactly
#     this while they run.
# ---------------------------------------------------------------------------
cd "$AGENTMESH"
$NOTECOVE init --profile "$PROFILE" --tasks-project "$PROJECT" --notes --events

mkdir -p "$SIGNALS"
touch "$LOG"

# ---------------------------------------------------------------------------
# 0b. Cold-start reset — only when nothing is running.
#
#     On a warm start every one of these steps is actively harmful:
#       - killing sidecars strands the workers they serve
#       - truncating signals/workers hides live workers from the watchdog
#       - deleting *.inbox throws away replies workers have yet to read
#       - truncating events.log loses the running system's history
#
#     A sidecar that outlives the wipe is worse still: with its baseline files
#     gone its next diff computes first_run=true, so it absorbs everything new —
#     including a reply the user is waiting on — into history and never writes it
#     to the inbox. Hence killing them first, inside the same branch.
# ---------------------------------------------------------------------------
if [[ $CLEAN -eq 1 ]] || ! _runtime_is_live; then
  echo "[bootstrap] cold start — resetting runtime state"
  log_event "cold-start-reset"

  for _w in $(tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null | grep -E '^(side-|pr-mon-)' || true); do
    tmux kill-window -t "orchestrator:${_w}" 2>/dev/null || true
  done

  : > "$SIGNALS/workers"
  : > "$LOG"
  rm -f "$SIGNALS/"*.merged
  rm -f "$SIGNALS/"*.crash-count
  rm -f "$SIGNALS/"*.launching
  rm -f "$SIGNALS/"*.untyped
  rm -f "$SIGNALS/"*.inbox
  rm -f "$SIGNALS/"*.ready
  rm -f "$SIGNALS/"*.pending-delivery
  rm -f "$SIGNALS/"*.self-state
  rm -f "$SIGNALS/"*.seen-comments
  rm -f "$SIGNALS/"*.seen-state
  rm -f "$SIGNALS/"*.backoff
  rm -f "$SIGNALS/"*.sidecar-handle
  rm -f "$SIGNALS/"*.terminal-since
  # Deliberately NOT stamping launcher.heartbeat here. The heartbeat means "a scan
  # completed", not "a process was started" — pre-stamping makes a launcher that
  # dies on startup report healthy. launcher.py writes it after each scan.
  rm -f "$SIGNALS/launcher.heartbeat"
else
  echo "[bootstrap] warm start — preserving running workers and their state"
  log_event "warm-start-ensure"
fi

# Resolve and persist Triage folder ID so agents can use it without re-querying
TRIAGE_FOLDER=$($NOTECOVE folder list --json | python3 -c "
import sys, json
folders = json.load(sys.stdin)
print(next(f['id'] for f in folders if f['name'] == 'Triage' and f['parentId'] is None))")
echo "$TRIAGE_FOLDER" > "$SIGNALS/triage_folder"

log_event "bootstrap-complete"

# 0e. Create orchestrator and workers tmux sessions (if not already running)
tmux new-session -d -s orchestrator 2>/dev/null || true
tmux new-session -d -s workers 2>/dev/null || true

# ---------------------------------------------------------------------------
# 0f. Ensure the daemons.
#
#     Each is launched AS THE WINDOW'S COMMAND rather than send-keys'd into a
#     shell. That is what makes window-existence a sound liveness check: the
#     window dies with the process. Under the old send-keys form a crashed
#     watchdog left a live `watchdog` window running zsh, so `agentmesh status`
#     reported it healthy and nothing — not even a re-run of this script — could
#     ever notice it was gone.
#
#     Spawning only what is missing is what makes a re-run safe against a live
#     system.
# ---------------------------------------------------------------------------
ensure_daemon() {
  local name="$1" cmd="$2"
  if _window_exists "$name"; then
    echo "[bootstrap] $name already running"
    return 0
  fi
  tmux new-window -d -t 'orchestrator:' -n "$name" "$cmd"
  log_event "daemon-started:${name}"
  echo "[bootstrap] $name started"
}

ensure_daemon watchdog       "bash $SCRIPTS/watchdog.sh"
ensure_daemon folder-cleanup "bash $SCRIPTS/folder-cleanup.sh"
ensure_daemon reaper         "bash $SCRIPTS/reaper.sh"

# ---------------------------------------------------------------------------
# 0g. Ensure the launcher.
#
#     Wrapped in a restart loop: nothing supervises it, and it is pure Python
#     with no Claude dependency, so respawning in place is the simplest form of
#     supervision. \$(date) is escaped so it evaluates inside the loop rather
#     than once, here.
#
#     The launcher is the one daemon whose window existing is not quite proof of
#     life: it can be up and wedged. The heartbeat already measures exactly that
#     — it is stamped after each completed scan — so a window with a stale
#     heartbeat is replaced rather than left.
#
#     A healthy launcher is otherwise left alone, even if its code on disk has
#     changed. To pick up new daemon code without a full reset, kill the window
#     and re-run this; it will come back on the new code.
# ---------------------------------------------------------------------------
LAUNCHER_CMD="cd $AGENTMESH && while true; do python3 $SCRIPTS/launcher.py --project $PROJECT --profile $PROFILE --max-workers $MAX_WORKERS --poll-interval $POLL_INTERVAL; printf '%s\tlauncher     \tprocess-exited-restarting\t-\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" >> '$LOG'; echo '[launcher] exited — restarting in 5s'; sleep 5; done"

if _window_exists launcher; then
  _age=$(_heartbeat_age)
  if [[ "$_age" -lt 90 ]]; then
    echo "[bootstrap] launcher already running (heartbeat: ${_age}s ago)"
  else
    echo "[bootstrap] launcher window present but heartbeat is ${_age}s old — restarting it"
    log_event "launcher-wedged-restarting"
    # Loop: tmux kill-window removes only the first name match.
    while _window_exists launcher; do
      tmux kill-window -t orchestrator:launcher 2>/dev/null || break
    done
    tmux new-window -d -t 'orchestrator:' -n launcher "$LAUNCHER_CMD"
    log_event "daemon-started:launcher"
  fi
else
  tmux new-window -d -t 'orchestrator:' -n launcher "$LAUNCHER_CMD"
  log_event "daemon-started:launcher"
  echo "[bootstrap] launcher started"
fi

echo "[bootstrap] complete — watchdog, folder-cleanup, reaper, and launcher running"
echo "[bootstrap] interact with agents through NoteCove task comments"
