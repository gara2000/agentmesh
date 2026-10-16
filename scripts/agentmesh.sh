#!/usr/bin/env bash
# agentmesh — AgentMesh lifecycle CLI
# Usage: agentmesh <start|stop|switch|status|attach|task> [options]
#
# There is no user-interaction process to start: agents talk to the user through
# NoteCove task comments, so `start` brings up daemons and returns.
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS="$AGENTMESH/scripts"
SIGNALS="$AGENTMESH/signals"

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
  local PROJECT="" PROFILE="kmq9h71tepf95rac2b59xdbsq2"
  local MAX_WORKERS="30" POLL_INTERVAL="30" CLEAN=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)       PROJECT="$2";       shift 2 ;;
      --profile)       PROFILE="$2";       shift 2 ;;
      --max-workers)   MAX_WORKERS="$2";   shift 2 ;;
      --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
      --clean)         CLEAN="--clean";    shift ;;
      *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$PROJECT" ]]; then
    echo "Error: --project is required" >&2
    exit 1
  fi

  # 1. Create tmux sessions
  if ! _session_exists orchestrator; then
    tmux new-session -d -s orchestrator
    echo "  ✓ orchestrator session created"
  else
    echo "  · orchestrator session already running"
  fi

  if ! _session_exists workers; then
    tmux new-session -d -s workers
    echo "  ✓ workers session created"
  else
    echo "  · workers session already running"
  fi

  # 2. Bootstrap. Always run it: it is idempotent and self-repairing, so this is
  #    also how a missing or crashed daemon is brought back without a stop.
  #
  #    This used to be skipped whenever the heartbeat was under 60s old, which
  #    made repair impossible — a live launcher meant `start` did nothing at all,
  #    so a newly added daemon (or a watchdog that had died) could only be
  #    started by stopping the system, which destroys every running worker.
  bash "$SCRIPTS/bootstrap.sh" \
    --project "$PROJECT" \
    --profile "$PROFILE" \
    --max-workers "$MAX_WORKERS" \
    --poll-interval "$POLL_INTERVAL" \
    ${CLEAN:+$CLEAN}

  echo ""
  echo "agentmesh started. Project: ${PROJECT}."
  echo "Agents interact through NoteCove task comments — open NoteCove to talk to them."
}

# ── stop ───────────────────────────────────────────────────────────────────────

cmd_stop() {
  # 1. Kill known windows in the orchestrator session
  for win in folder-cleanup watchdog reaper launcher; do
    tmux kill-window -t "orchestrator:$win" 2>/dev/null || true
  done

  # 2. Kill per-task windows. side-* and pr-mon-* are not tracked in
  #    signals/workers, so nothing else would ever reap them — kill explicitly.
  tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null \
    | grep -E "^(pr-mon-|side-)" \
    | while read -r w; do
        tmux kill-window -t "orchestrator:$w" 2>/dev/null || true
      done || true

  # 3. Kill workers session
  tmux kill-session -t workers 2>/dev/null || true

  # 4. Invalidate the heartbeat.
  #    cmd_start skips bootstrap entirely when the heartbeat is under 60s old,
  #    and launcher.py refreshes it every 30s — so without this, a stop followed
  #    by a start inside a minute brings up nothing at all and reports
  #    "launcher already running". Nothing would then adopt the stopped tasks.
  rm -f "$SIGNALS/launcher.heartbeat"

  echo "agentmesh stopped."
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
  local PROJECT="" PROFILE="kmq9h71tepf95rac2b59xdbsq2"
  local MAX_WORKERS="30" POLL_INTERVAL="30"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)       PROJECT="$2";       shift 2 ;;
      --profile)       PROFILE="$2";       shift 2 ;;
      --max-workers)   MAX_WORKERS="$2";   shift 2 ;;
      --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$PROJECT" ]]; then
    echo "Error: --project is required" >&2
    exit 1
  fi

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
  tmux new-window -d -t "orchestrator:" -n launcher \
    "cd $AGENTMESH && while true; do python3 $SCRIPTS/launcher.py --project $PROJECT --profile $PROFILE --max-workers $MAX_WORKERS --poll-interval $POLL_INTERVAL; printf '%s\tlauncher     \tprocess-exited-restarting\t-\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" >> '$SIGNALS/events.log'; echo '[launcher] exited — restarting in 5s'; sleep 5; done"
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
  switch)        cmd_switch        "$@" ;;
  status)        cmd_status        "$@" ;;
  attach)        cmd_attach        "$@" ;;
  task)          cmd_task          "$@" ;;
  *)
    echo "Usage: agentmesh <start|stop|switch|status|attach|task> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  start          Start the agentmesh system, or repair a running one" >&2
    echo "                 (idempotent: creates what is missing, touches nothing else;" >&2
    echo "                  --clean forces a full runtime reset)" >&2
    echo "  stop           Stop the agentmesh system" >&2
    echo "  switch         Switch to a different project (preserves running workers)" >&2
    echo "  status         Show component health" >&2
    echo "  attach         Attach to the orchestrator tmux session" >&2
    echo "  task create    Create a new task in NoteCove" >&2
    exit 1
    ;;
esac
