#!/usr/bin/env bash
# bootstrap.sh — initialize the AgentMesh runtime: notecove init, signals dir, daemons
# Usage: bootstrap.sh --project <PROJECT> [--profile <profile-id>]   # else $AGENTMESH_PROFILE / $AGENTMESH_PROFILE_NAME [--max-workers <n>]
#                     [--poll-interval <seconds>] [--model <id>]   # else $AGENTMESH_MODEL
#
# Per-agent-type models come from $AGENTMESH_MODEL_<TYPE> (e.g.
# AGENTMESH_MODEL_IMPLEMENTER=opus) and are passed to the launcher as arguments;
# see launcher_model_args in notecove-ref.sh.
#
# This is idempotent, additive and never destructive. Running it against a live
# system brings up whatever daemon is missing and touches nothing else: no worker
# is killed, no sidecar is restarted, no inbox is cleared. That is what lets a
# newly added daemon — or one that crashed — be started without an
# `agentmesh stop`, which would destroy every running worker.
#
# It never wipes runtime state, not even when nothing is running. It used to, on
# a "cold" start and on --clean, which made every start a judgement call about
# whether something was live enough to be worth keeping. Wiping is now only ever
# asked for explicitly: `agentmesh clean` (= `agentmesh stop --level 4`).
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS=$AGENTMESH/scripts
SIGNALS=$AGENTMESH/signals

# notecove is a shell function (not a binary), so call the CLI directly.
# Overridable so the tests can point it at a stub; nothing else sets it.
NOTECOVE="${AGENTMESH_NOTECOVE:-node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs}"

# shellcheck source=notecove-ref.sh
source "$SCRIPTS/notecove-ref.sh"

# Parse arguments
PROJECT=""
PROFILE=""
MAX_WORKERS="30"
POLL_INTERVAL="30"
MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)       PROJECT="$2";       shift 2 ;;
    --profile)       PROFILE="$2";       shift 2 ;;
    --max-workers)   MAX_WORKERS="$2";   shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --model)         MODEL="$2";         shift 2 ;;
    --clean)
      echo "Error: start never cleans. Run 'agentmesh clean' first, then start." >&2
      exit 1 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "Error: --project is required" >&2
  exit 1
fi

# --profile > $AGENTMESH_PROFILE > $AGENTMESH_PROFILE_NAME > historical default.
PROFILE=$(nc_resolve_profile "$PROFILE") || exit 1

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

# Window names in a session, one per line; fails if tmux cannot list them.
_windows() {
  tmux list-windows -t "$1" -F "#{window_name}" 2>/dev/null
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
echo "[bootstrap] this operation is idempotent and non destructive — if you expect to start fresh, run 'agentmesh clean' before start"

cd "$AGENTMESH"
$NOTECOVE init --profile "$PROFILE" --tasks-project "$PROJECT" --notes --events

mkdir -p "$SIGNALS"
touch "$LOG"

log_event "start-ensure"

# Resolve and persist Triage folder ID so agents can use it without re-querying
TRIAGE_FOLDER=$($NOTECOVE folder list --json | python3 -c "
import sys, json
folders = json.load(sys.stdin)
print(next(f['id'] for f in folders if f['name'] == 'Triage' and f['parentId'] is None))")
echo "$TRIAGE_FOLDER" > "$SIGNALS/triage_folder"

log_event "bootstrap-complete"

# 0e. Create orchestrator and workers tmux sessions (if not already running)
tmux new-session -d -s orchestrator 2>/dev/null || true

# ---------------------------------------------------------------------------
# 0e'. Clear what describes a process that cannot be running.
#
#      Not a wipe: inboxes, sidecar baselines and PR state are what let the
#      launcher's adoption pick a task up where it stopped, and all of them stay.
#      What goes is only the bookkeeping of processes that are provably gone:
#
#        - no `workers` session (machine reboot, tmux server killed): nothing in
#          the registry is alive, and the watchdog would read every entry as a
#          crash — bumping its count, deleting its inbox and re-queuing it to
#          Ready instead of letting adoption resume it. Each `.ready` gate is
#          stale too, and a stale one lets the sidecar type a nudge into the
#          respawned window while spawn-agent.sh is still typing the skill.
#        - no `watchdog` window: a `.backoff` sentinel belongs to a sleep that is
#          not happening, and adoption skips the task for as long as it exists.
#        - no `launcher` window: no spawn is in flight, so `.launching` is stale.
#
#      "Provably" needs tmux to answer: the orchestrator session was just
#      ensured above, so a failed list-sessions means tmux itself is not
#      answering, and nothing is touched.
# ---------------------------------------------------------------------------
if _sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null); then
  if ! grep -qx workers <<<"$_sessions"; then
    if [[ -s "$SIGNALS/workers" ]] || compgen -G "$SIGNALS/*.ready" >/dev/null; then
      echo "[bootstrap] no workers session — clearing the stale worker registry and delivery gates"
      log_event "stale-workers-cleared"
    fi
    grep '^#' "$SIGNALS/workers" > "$SIGNALS/workers.tmp" 2>/dev/null || true
    mv "$SIGNALS/workers.tmp" "$SIGNALS/workers"
    rm -f "$SIGNALS/"*.ready "$SIGNALS/"*.pending-delivery
  fi
  if _orch=$(_windows orchestrator); then
    grep -qx watchdog <<<"$_orch" || rm -f "$SIGNALS/"*.backoff
    grep -qx launcher <<<"$_orch" || rm -f "$SIGNALS/"*.launching
  fi
fi

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
#     It is also replaced when its configuration changed: the command line it
#     was started with is recorded in signals/launcher.cmd, and a start asking
#     for a different one (another --model, $AGENTMESH_MODEL_<TYPE>,
#     --max-workers, …) restarts it. Otherwise `AGENTMESH_MODEL_IMPLEMENTER=opus
#     agentmesh start` against a running system would silently do nothing.
#     Restarting the launcher touches no worker. With no record (a launcher from
#     before this existed) it is left alone and the record is written.
#
#     A healthy, unchanged launcher is otherwise left alone, even if its code on
#     disk has changed. To pick up new daemon code without a full reset, kill
#     the window and re-run this; it will come back on the new code.
# ---------------------------------------------------------------------------
LAUNCHER_CMD=$(launcher_command "$AGENTMESH" "$PROJECT" "$PROFILE" "$MAX_WORKERS" "$POLL_INTERVAL" "$MODEL")

LAUNCHER_CMD_FILE="$SIGNALS/launcher.cmd"

start_launcher() {
  tmux new-window -d -t 'orchestrator:' -n launcher "$LAUNCHER_CMD"
  printf '%s\n' "$LAUNCHER_CMD" > "$LAUNCHER_CMD_FILE"
  log_event "daemon-started:launcher"
}

restart_launcher() {
  # Loop: tmux kill-window removes only the first name match.
  while _window_exists launcher; do
    tmux kill-window -t orchestrator:launcher 2>/dev/null || break
  done
  start_launcher
}

if _window_exists launcher; then
  _age=$(_heartbeat_age)
  if [[ "$_age" -ge 90 ]]; then
    echo "[bootstrap] launcher window present but heartbeat is ${_age}s old — restarting it"
    log_event "launcher-wedged-restarting"
    restart_launcher
  elif [[ -f "$LAUNCHER_CMD_FILE" && "$(cat "$LAUNCHER_CMD_FILE")" != "$LAUNCHER_CMD" ]]; then
    echo "[bootstrap] launcher configuration changed — restarting it (workers are untouched)"
    log_event "launcher-config-changed-restarting"
    restart_launcher
  else
    echo "[bootstrap] launcher already running (heartbeat: ${_age}s ago)"
    [[ -f "$LAUNCHER_CMD_FILE" ]] || printf '%s\n' "$LAUNCHER_CMD" > "$LAUNCHER_CMD_FILE"
  fi
else
  start_launcher
  echo "[bootstrap] launcher started"
fi

# ---------------------------------------------------------------------------
# 0h. Report what each live worker is missing.
#
#     A worker needs a sidecar (or the user's replies never reach it) and, while
#     any of its PRs is unresolved, a pr-monitor (or a merge never does). The
#     launcher repairs both on every scan — the first one runs as soon as it
#     starts — so this only reports; spawning here as well could race the
#     launcher into two sidecars for one worker.
#
#     Worker windows are told apart from the session's default shell window by
#     what the launcher recorded for them: a registry line or a .full-slug.
# ---------------------------------------------------------------------------
_unresolved_prs() {
  local slug="$1" url
  [[ -f "$SIGNALS/${slug}.prs" ]] || return 1
  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    grep -qxF -- "$url" "$SIGNALS/${slug}.merged" "$SIGNALS/${slug}.pr-closed" 2>/dev/null \
      || return 0
  done < "$SIGNALS/${slug}.prs"
  return 1
}

if _orch=$(_windows orchestrator) && _live=$(_windows workers); then
  for _slug in $_live; do
    grep -q "^${_slug} " "$SIGNALS/workers" 2>/dev/null \
      || [[ -f "$SIGNALS/${_slug}.full-slug" ]] || continue
    if ! grep -qx "side-${_slug}" <<<"$_orch"; then
      echo "[bootstrap] $_slug has no sidecar — the launcher spawns one on its next scan"
    fi
    if ! grep -qx "pr-mon-${_slug}" <<<"$_orch" && _unresolved_prs "$_slug"; then
      echo "[bootstrap] $_slug has open PRs but no pr-monitor — the launcher spawns one on its next scan"
    fi
  done
fi

echo "[bootstrap] complete — watchdog, folder-cleanup, reaper, and launcher running"
echo "[bootstrap] interact with agents through NoteCove task comments"
