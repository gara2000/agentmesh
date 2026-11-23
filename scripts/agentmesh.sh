#!/usr/bin/env bash
# agentmesh — AgentMesh lifecycle CLI
# Usage: agentmesh <start|stop|clean|switch|status|attach|task> [options]
#
# There is no user-interaction process to start: agents talk to the user through
# NoteCove task comments, so `start` brings up daemons and returns.
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS="$AGENTMESH/scripts"
SIGNALS="$AGENTMESH/signals"

# shellcheck source=notecove-ref.sh
source "$SCRIPTS/notecove-ref.sh"

# ── Helpers ────────────────────────────────────────────────────────────────────

_window_exists() {
  tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null | grep -qx "$1"
}

_session_exists() {
  tmux has-session -t "$1" 2>/dev/null
}

# Spawn a daemon window only if it is not already there. Same contract as
# bootstrap.sh's ensure_daemon: launched as the window's command so the window
# dies with the process, and a no-op against a live one.
_ensure_daemon() {
  local name="$1" cmd="$2"
  if _window_exists "$name"; then
    echo "  · $name already running"
    return 0
  fi
  tmux new-window -d -t "orchestrator:" -n "$name" "$cmd"
  echo "  ✓ $name started"
}

_heartbeat_age() {
  local hb="$SIGNALS/launcher.heartbeat"
  [ -f "$hb" ] || { echo 9999; return; }
  local last_modified now
  last_modified=$(python3 -c "import os; print(int(os.path.getmtime('$hb')))")
  now=$(date +%s)
  echo $((now - last_modified))
}

# ── start ──────────────────────────────────────────────────────────────────────

cmd_start() {
  local PROJECT="" PROFILE=""
  local MAX_WORKERS="30" POLL_INTERVAL="30" MODEL=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)       PROJECT="$2";       shift 2 ;;
      --profile)       PROFILE="$2";       shift 2 ;;
      --max-workers)   MAX_WORKERS="$2";   shift 2 ;;
      --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
      --model)         MODEL="$2";         shift 2 ;;
      --clean)
        # start only ever adds what is missing. Wiping is its own, explicit,
        # confirmed command, so a routine start can never lose a pending reply.
        echo "Error: start never cleans. Run 'agentmesh clean' first, then start." >&2
        exit 1 ;;
      *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$PROJECT" ]]; then
    echo "Error: --project is required" >&2
    exit 1
  fi

  # Bootstrap creates the tmux sessions itself, and has to be the one to: it
  # reads a missing `workers` session as "no worker can be alive" (a reboot, a
  # killed tmux server) and clears the stale registry and delivery gates. Making
  # the session here first hid that from it.
  #
  # Always run it: it is idempotent and self-repairing, so this is
  #    also how a missing or crashed daemon is brought back without a stop.
  #
  #    This used to be skipped whenever the heartbeat was under 60s old, which
  #    made repair impossible — a live launcher meant `start` did nothing at all,
  #    so a newly added daemon (or a watchdog that had died) could only be
  #    started by stopping the system, which destroys every running worker.
  bash "$SCRIPTS/bootstrap.sh" \
    --project "$PROJECT" \
    ${PROFILE:+--profile "$PROFILE"} \
    --max-workers "$MAX_WORKERS" \
    --poll-interval "$POLL_INTERVAL" \
    ${MODEL:+--model "$MODEL"}

  echo ""
  echo "agentmesh started. Project: ${PROJECT}."
  echo "Agents interact through NoteCove task comments — open NoteCove to talk to them."
}

# ── stop ───────────────────────────────────────────────────────────────────────

# Four cumulative levels; each also does everything below it.
#
#   1  supervisory daemons — launcher, watchdog, reaper, folder-cleanup.
#      Workers keep their sidecars and pr-monitors, so the user's replies are
#      still delivered; nothing new is picked up, crashed or reaped.
#   2  + every sidecar and pr-monitor. Workers stay alive but deaf. Their
#      baselines are kept, so the replacements the launcher spawns on the next
#      start report everything that arrived in between.
#   3  + every worker. Also clears the registry and the per-process flags, so the
#      next start reads this as a stop rather than a crash of every worker (the
#      watchdog would otherwise bump each crash count, delete each inbox and
#      re-queue the task to Ready). Inboxes, baselines and PR state stay: the
#      launcher's adoption resumes each task with its unread replies.
#   4  + all runtime state in signals/ — a blank slate. Tasks stay in
#      Doing/Attention and are re-adopted from their notes and comments, but any
#      reply nobody has read yet is gone. *.description-backup is kept: it is the
#      only copy of a task description ensure_task_folder rewrote.

_STOP_LEVELS=(
  ""
  "daemons    — launcher, watchdog, reaper, folder-cleanup; workers keep talking to you"
  "+ sidecars and pr-monitors — workers stay alive but get no replies until start"
  "+ workers  — start re-adopts every task with its pending replies"
  "+ all signal files — blank slate; unread replies are lost"
)

# Window names in the workers session that are workers, as opposed to the
# session's default shell window: the launcher recorded a registry line or a
# full slug for each one it spawned.
_worker_windows() {
  local w
  tmux list-windows -t workers -F "#{window_name}" 2>/dev/null | while read -r w; do
    grep -q "^${w} " "$SIGNALS/workers" 2>/dev/null \
      || [[ -f "$SIGNALS/${w}.full-slug" ]] && echo "$w"
  done
  return 0
}

_orchestrator_windows() {
  tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null || true
}

_print_running() {
  local orch daemons=() d
  orch=$(_orchestrator_windows)
  for d in launcher watchdog reaper folder-cleanup; do
    grep -qx "$d" <<<"$orch" && daemons+=("$d")
  done
  echo "Currently running:"
  printf "  %-14s %s\n" "daemons" "${daemons[*]:-none}"
  printf "  %-14s %s\n" "workers" "$(_worker_windows | awk 'END {print NR}')"
  printf "  %-14s %s\n" "sidecars" "$(awk '/^side-/ {n++} END {print n+0}' <<<"$orch")"
  printf "  %-14s %s\n" "pr-monitors" "$(awk '/^pr-mon-/ {n++} END {print n+0}' <<<"$orch")"
}

_kill_windows_named() {
  # Loop: tmux kill-window removes only the first window matching a name.
  local name="$1"
  while _window_exists "$name"; do
    tmux kill-window -t "orchestrator:$name" 2>/dev/null || break
  done
}

_stop_daemons() {
  local d
  for d in launcher watchdog reaper folder-cleanup; do
    _kill_windows_named "$d"
  done
  # The heartbeat means "a scan completed recently"; with the launcher gone it
  # no longer does, and status must not report a dead launcher as running.
  rm -f "$SIGNALS/launcher.heartbeat"
  echo "  ✓ daemons stopped (launcher, watchdog, reaper, folder-cleanup)"
}

_stop_task_daemons() {
  # side-* and pr-mon-* are not in signals/workers, so nothing else would ever
  # collect them.
  local w n=0
  for w in $(_orchestrator_windows | grep -E '^(side-|pr-mon-)' || true); do
    tmux kill-window -t "orchestrator:$w" 2>/dev/null || true
    n=$((n + 1))
  done
  echo "  ✓ $n sidecar/pr-monitor window(s) stopped"
}

_stop_workers() {
  tmux kill-session -t workers 2>/dev/null || true
  # Keep the format comment, drop every entry: none of them is running now, and
  # an entry whose window is gone is what the watchdog reads as a crash.
  if [[ -f "$SIGNALS/workers" ]]; then
    grep '^#' "$SIGNALS/workers" > "$SIGNALS/workers.tmp" || true
    mv "$SIGNALS/workers.tmp" "$SIGNALS/workers"
  fi
  # Flags that describe a process, not a task. A stale .ready lets a sidecar
  # type into the respawned window while spawn-agent.sh is typing the skill; a
  # stale .backoff (watchdog gone mid-sleep) or .launching (launcher gone
  # mid-spawn) makes adoption skip the task.
  rm -f "$SIGNALS/"*.ready "$SIGNALS/"*.pending-delivery \
        "$SIGNALS/"*.launching "$SIGNALS/"*.backoff
  echo "  ✓ workers stopped (their tasks are re-adopted on the next start)"
}

_stop_signals() {
  [[ -d "$SIGNALS" ]] || return 0
  find "$SIGNALS" -maxdepth 1 -type f ! -name '*.description-backup' -delete
  echo "  ✓ runtime state cleared (signals/, keeping description backups)"
}

cmd_stop() {
  local LEVEL="" YES=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --level) LEVEL="${2:-}"; shift 2 ;;
      --yes|-y) YES=1; shift ;;
      *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
  done

  local tty=0 asked=0
  [[ -t 0 && -t 1 ]] && tty=1

  if [[ -z "$LEVEL" ]]; then
    if [[ $tty -eq 0 ]]; then
      # Never guess how much to destroy on someone's behalf.
      echo "Error: no terminal to ask on — pass --level <1-4>:" >&2
      local n
      for n in 1 2 3 4; do echo "  $n  ${_STOP_LEVELS[$n]}" >&2; done
      exit 1
    fi
    _print_running
    echo ""
    echo "How much should be stopped? Each level includes the ones above it."
    local n
    for n in 1 2 3 4; do echo "  $n  ${_STOP_LEVELS[$n]}"; done
    asked=1
    read -r -p "Level [1-4, anything else cancels]: " LEVEL || LEVEL=""
  fi

  case "$LEVEL" in
    1|2|3|4) ;;
    *)
      if [[ $asked -eq 0 ]]; then
        echo "Error: --level must be 1, 2, 3 or 4" >&2
        exit 1
      fi
      echo "Cancelled — nothing stopped."
      return 0
      ;;
  esac

  if [[ "$LEVEL" -eq 4 && $YES -eq 0 ]]; then
    if [[ $tty -eq 0 ]]; then
      echo "Error: level 4 deletes every pending reply and baseline — pass --yes to confirm" >&2
      exit 1
    fi
    local answer=""
    read -r -p "Level 4 deletes every unread reply and all runtime state. Type 'yes' to continue: " answer || true
    if [[ "$answer" != "yes" ]]; then
      echo "Cancelled — nothing stopped."
      return 0
    fi
  fi

  _stop_daemons
  [[ "$LEVEL" -ge 2 ]] && _stop_task_daemons
  [[ "$LEVEL" -ge 3 ]] && _stop_workers
  [[ "$LEVEL" -ge 4 ]] && _stop_signals

  echo "agentmesh stopped (level $LEVEL). 'agentmesh start' brings back whatever is missing."
}

# ── clean ──────────────────────────────────────────────────────────────────────

# Everything, signal files included: the one way to start fresh, since start
# itself never removes anything.
cmd_clean() {
  cmd_stop --level 4 "$@"
}

# ── status ─────────────────────────────────────────────────────────────────────

cmd_status() {
  local age
  age=$(_heartbeat_age)

  if [ "$age" -lt 90 ]; then
    printf "%-22s ✓ running  (heartbeat: %ss ago)\n" "launcher" "$age"
  else
    printf "%-22s ✗ not running\n" "launcher"
  fi

  # Daemons are launched as their window's command, so the window dies with the
  # process and its existence is a sound liveness check. (Under the old
  # send-keys form a crashed daemon left a live window running a shell, and this
  # reported it healthy.)
  for win in watchdog folder-cleanup reaper; do
    if _window_exists "$win"; then
      printf "%-22s ✓ running\n" "$win"
    else
      printf "%-22s ✗ not running  (agentmesh start brings it back)\n" "$win"
    fi
  done

  # active workers
  local workers=0 worker_names=""
  if [ -f "$SIGNALS/workers" ]; then
    worker_names=$(grep -v '^#' "$SIGNALS/workers" 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
    workers=$(awk '!/^#/ && NF {n++} END {print n+0}' "$SIGNALS/workers" 2>/dev/null)
  fi
  if [ -n "$worker_names" ]; then
    printf "%-22s %s  (%s)\n" "active workers" "$workers" "$worker_names"
  else
    printf "%-22s %s\n" "active workers" "$workers"
  fi
  # One line per worker: agent type and model. The model is the registry's
  # optional 5th field; absent means claude was started without --model.
  if [ "$workers" -gt 0 ] 2>/dev/null; then
    awk '!/^#/ && NF { printf "  %-20s %s · %s\n", $1, ($3 != "" ? $3 : "?"), (NF >= 5 ? $5 : "default") }' \
      "$SIGNALS/workers" 2>/dev/null || true
  fi

  # sidecars — one per live worker; a worker without one is deaf to the user
  local sidecars
  # Count with awk, not `grep -c`: grep prints 0 *and* exits 1 when nothing
  # matches, so `grep -c ... || echo 0` yields the two-line string "0\n0" and
  # every subsequent -lt test errors out — suppressing the warning in exactly
  # the case it exists for (zero sidecars, every worker deaf).
  sidecars=$(tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null | awk '/^side-/ {n++} END {print n+0}')
  printf "%-22s %s\n" "sidecars" "$sidecars"
  if [ "$sidecars" -lt "$workers" ]; then
    printf "%-22s ⚠ fewer sidecars than workers — those workers get no user replies\n" ""
  fi

  # SSE availability — sidecars fall back to polling without it
  local notecove="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"
  if $notecove events recent --types "task.*" --limit 1 --json >/dev/null 2>&1; then
    printf "%-22s ✓ available (push)\n" "notecove events"
  else
    printf "%-22s ✗ unavailable — sidecars polling only\n" "notecove events"
  fi

  # tasks refused for missing/unmapped type
  local untyped
  untyped=$(find "$SIGNALS" -maxdepth 1 -name '*.untyped' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$untyped" -gt 0 ]; then
    printf "%-22s %s  (set a supported type to unblock)\n" "untyped tasks" "$untyped"
  fi
}

# ── attach ─────────────────────────────────────────────────────────────────────

cmd_attach() {
  tmux attach-session -t orchestrator
}

# ── task ───────────────────────────────────────────────────────────────────────

cmd_task_create() {
  local TITLE="" PROJECT="" FOLDER="" PRIORITY="" TYPE="" CONTENT="" CONTENT_FILE=""

  # First positional arg is the title
  if [[ $# -gt 0 && "$1" != --* ]]; then
    TITLE="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)      PROJECT="$2";      shift 2 ;;
      --folder)       FOLDER="$2";       shift 2 ;;
      --priority)     PRIORITY="$2";     shift 2 ;;
      --type)         TYPE="$2";         shift 2 ;;
      --content)      CONTENT="$2";      shift 2 ;;
      --content-file) CONTENT_FILE="$2"; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$TITLE" ]]; then
    echo "Error: task title is required" >&2
    echo "Usage: agentmesh task create <title> --project <key> [--folder <name-or-id>] [options]" >&2
    exit 1
  fi

  if [[ -z "$PROJECT" ]]; then
    echo "Error: --project is required" >&2
    exit 1
  fi

  # Resolve --folder to a folder ID
  local FOLDER_ID=""
  if [[ -n "$FOLDER" ]]; then
    local FOLDER_LIST
    FOLDER_LIST=$(notecove folder list --json)
    FOLDER_ID=$(python3 -c "
import sys, json
folders = json.loads(sys.argv[1])
value = sys.argv[2]
match = next((f for f in folders if f['id'] == value), None)
if match is None:
    match = next((f for f in folders if f['name'].lower() == value.lower()), None)
if match is None:
    print('Error: folder not found: ' + value, file=sys.stderr)
    sys.exit(1)
print(match['id'])
" "$FOLDER_LIST" "$FOLDER")
    if [[ $? -ne 0 ]]; then
      exit 1
    fi
  fi

  # Build notecove args
  local NOTECOVE_ARGS=("$TITLE" --project "$PROJECT")
  [[ -n "$FOLDER_ID" ]]    && NOTECOVE_ARGS+=(--folder "$FOLDER_ID")
  [[ -n "$PRIORITY" ]]     && NOTECOVE_ARGS+=(--priority "$PRIORITY")
  [[ -n "$TYPE" ]]         && NOTECOVE_ARGS+=(--type "$TYPE")
  [[ -n "$CONTENT" ]]      && NOTECOVE_ARGS+=(--content "$CONTENT")
  [[ -n "$CONTENT_FILE" ]] && NOTECOVE_ARGS+=(--content-file "$CONTENT_FILE")
  NOTECOVE_ARGS+=(--json)

  notecove task create "${NOTECOVE_ARGS[@]}"
}

cmd_task() {
  local SUBCMD="${1:-}"
  shift || true

  case "$SUBCMD" in
    create) cmd_task_create "$@" ;;
    *)
      echo "Usage: agentmesh task <create> [options]" >&2
      echo "" >&2
      echo "Subcommands:" >&2
      echo "  create  Create a new task" >&2
      exit 1
      ;;
  esac
}

# ── switch ─────────────────────────────────────────────────────────────────

cmd_switch() {
  local PROJECT="" PROFILE=""
  local MAX_WORKERS="30" POLL_INTERVAL="30" MODEL=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)       PROJECT="$2";       shift 2 ;;
      --profile)       PROFILE="$2";       shift 2 ;;
      --max-workers)   MAX_WORKERS="$2";   shift 2 ;;
      --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
      --model)         MODEL="$2";         shift 2 ;;
      *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$PROJECT" ]]; then
    echo "Error: --project is required" >&2
    exit 1
  fi

  PROFILE=$(nc_resolve_profile "$PROFILE") || exit 1

  # 1. Verify orchestrator session exists (agentmesh must be running)
  if ! _session_exists orchestrator; then
    echo "Error: agentmesh is not running. Use 'agentmesh start' first." >&2
    exit 1
  fi

  # 2. Kill the launcher — the only project-scoped component. watchdog and
  #    folder-cleanup are project-agnostic; the workers session is untouched.
  #    Loop because tmux kill-window only removes the first name match.
  echo "  · stopping the launcher..."
  while tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null | grep -qx "launcher"; do
    tmux kill-window -t "orchestrator:launcher" 2>/dev/null || break
  done

  # Per-task windows are left running: sidecars keep serving workers from the
  # previous project (they are project-agnostic, keyed only on a task slug), and
  # pr-monitors keep watching for merges.

  # 3. Re-init NoteCove for the new project
  local NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"
  cd "$AGENTMESH"
  $NOTECOVE init --profile "$PROFILE" --tasks-project "$PROJECT" --notes --events

  # 4. Resolve and persist Triage folder ID for the new project
  #    (optional — not all projects have one)
  local TRIAGE_FOLDER
  TRIAGE_FOLDER=$($NOTECOVE folder list --json | python3 -c "
import sys, json
folders = json.load(sys.stdin)
match = next((f['id'] for f in folders if f['name'] == 'Triage' and f['parentId'] is None), '')
print(match)")
  echo "$TRIAGE_FOLDER" > "$SIGNALS/triage_folder"

  # 5. Start the launcher on the new project.
  #    As the window's command, not send-keys'd into a shell: the window must die
  #    with the restart loop, or a crashed launcher leaves a window that both
  #    `agentmesh status` and bootstrap's ensure pass read as healthy.
  #    Built by the same helper as bootstrap's and recorded the same way, so the
  #    next `agentmesh start` with the same settings leaves it alone.
  local LAUNCHER_CMD
  LAUNCHER_CMD=$(launcher_command "$AGENTMESH" "$PROJECT" "$PROFILE" "$MAX_WORKERS" "$POLL_INTERVAL" "$MODEL")
  tmux new-window -d -t "orchestrator:" -n launcher "$LAUNCHER_CMD"
  printf '%s\n' "$LAUNCHER_CMD" > "$SIGNALS/launcher.cmd"
  echo "  ✓ launcher started (project: $PROJECT)"

  # 6. Any daemon that died while the system was up comes back here too — switch
  #    is a restart of the project-scoped half, and there is no reason to leave a
  #    missing reaper or watchdog missing.
  _ensure_daemon watchdog       "bash $SCRIPTS/watchdog.sh"
  _ensure_daemon folder-cleanup "bash $SCRIPTS/folder-cleanup.sh"
  _ensure_daemon reaper         "bash $SCRIPTS/reaper.sh"

  # Deliberately no heartbeat stamp here. The heartbeat means "a scan
  # completed"; writing it on spawn makes a launcher that dies on startup — a
  # bad --project, say — report healthy for a full minute.

  echo ""
  echo "agentmesh switched to project: ${PROJECT}."
  echo "  · existing workers and their sidecars are still running"
  echo "  · watchdog and folder-cleanup remain active"
}

# ── dispatch ───────────────────────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  start)         cmd_start         "$@" ;;
  stop)          cmd_stop          "$@" ;;
  clean)         cmd_clean         "$@" ;;
  switch)        cmd_switch        "$@" ;;
  status)        cmd_status        "$@" ;;
  attach)        cmd_attach        "$@" ;;
  task)          cmd_task          "$@" ;;
  *)
    echo "Usage: agentmesh <start|stop|clean|switch|status|attach|task> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  start          Start the agentmesh system, or repair a running one" >&2
    echo "                 (idempotent: creates what is missing, never removes anything)" >&2
    echo "  stop           Stop the system, choosing how much from a menu" >&2
    echo "                 (--level 1-4 to skip it; 4 needs --yes without a terminal)" >&2
    echo "  clean          stop --level 4: everything, runtime state included" >&2
    echo "  switch         Switch to a different project (preserves running workers)" >&2
    echo "  status         Show component health" >&2
    echo "  attach         Attach to the orchestrator tmux session" >&2
    echo "  task create    Create a new task in NoteCove" >&2
    exit 1
    ;;
esac
