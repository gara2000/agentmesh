#!/usr/bin/env bash
# agentmesh — AgentMesh lifecycle CLI
# Usage: agentmesh <start|stop|status|attach> [options]
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

_heartbeat_age() {
  local hb="$SIGNALS/orchestrator.heartbeat"
  [ -f "$hb" ] || { echo 9999; return; }
  local last_modified now
  last_modified=$(python3 -c "import os; print(int(os.path.getmtime('$hb')))")
  now=$(date +%s)
  echo $((now - last_modified))
}

# Wait for Claude REPL prompt (❯\u00a0) to appear in a tmux window.
# _timeout iterations × 0.2 s = 60 s real-time fallback.
_wait_for_repl() {
  local session_window="$1"
  local elapsed=0 timeout=300
  while [ $elapsed -lt $timeout ]; do
    if tmux capture-pane -t "$session_window" -p 2>/dev/null | grep -q $'❯\xc2\xa0'; then
      return 0
    fi
    sleep 0.2
    elapsed=$((elapsed + 1))
  done
  echo "Warning: timed out waiting for Claude REPL in $session_window" >&2
  return 1
}

# ── start ──────────────────────────────────────────────────────────────────────

cmd_start() {
  local PROJECT="" PROFILE="kmq9h71tepf95rac2b59xdbsq2" MODE="standard"
  local MAX_WORKERS="10" REVIEW_LIMIT="3" INTERFACE="spokesman"
  local VERBOSITY="medium" SLACK_CHANNEL=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)              PROJECT="$2";              shift 2 ;;
      --profile)              PROFILE="$2";              shift 2 ;;
      --mode)                 MODE="$2";                 shift 2 ;;
      --max-workers)          MAX_WORKERS="$2";          shift 2 ;;
      --review-limit)         REVIEW_LIMIT="$2";         shift 2 ;;
      --interface)            INTERFACE="$2";            shift 2 ;;
      --verbosity)            VERBOSITY="$2";            shift 2 ;;
      --channel|--slack-channel) SLACK_CHANNEL="$2";    shift 2 ;;
      *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$PROJECT" ]]; then
    echo "Error: --project is required" >&2
    exit 1
  fi

  if [[ "$INTERFACE" == "slack" || "$INTERFACE" == "both" ]] && [[ -z "$SLACK_CHANNEL" ]]; then
    echo "Error: --slack-channel is required when --interface includes slack" >&2
    exit 1
  fi

  if [[ "$INTERFACE" == "slack" || "$INTERFACE" == "both" ]] && [[ -z "${SLACK_APP_TOKEN:-}" ]]; then
    echo "Error: SLACK_APP_TOKEN environment variable is required when --interface includes slack" >&2
    exit 1
  fi

  if [[ "$INTERFACE" == "slack" || "$INTERFACE" == "both" ]] && [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
    echo "Warning: SLACK_BOT_TOKEN is not set. The relay cannot join the Slack channel automatically." >&2
    echo "  If messages are not received, set SLACK_BOT_TOKEN or invite the bot to the channel manually." >&2
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

  # 2–7. Bootstrap (initializes signals/, starts dispatcher/watchdog/folder-cleanup/orchestrator.py)
  local orch_age
  orch_age=$(_heartbeat_age)
  if [ "$orch_age" -lt 60 ]; then
    echo "  · orchestrator.py already running (heartbeat: ${orch_age}s ago)"
  else
    bash "$SCRIPTS/bootstrap.sh" \
      --project "$PROJECT" \
      --profile "$PROFILE" \
      --mode "$MODE" \
      --max-workers "$MAX_WORKERS" \
      --review-limit "$REVIEW_LIMIT" \
      --interface "$INTERFACE" \
      ${SLACK_CHANNEL:+--slack-channel "$SLACK_CHANNEL"}
    # Persist mode for Spokesman to read on recovery
    echo "$MODE" > "$SIGNALS/mode"
  fi

  # 8. Write slack-channel file if interface includes slack
  if [[ "$INTERFACE" == "slack" || "$INTERFACE" == "both" ]]; then
    echo "$SLACK_CHANNEL" > "$SIGNALS/slack-channel"
  fi

  # 9. Start Spokesman (orchestrator:main)
  if [[ "$INTERFACE" == "spokesman" || "$INTERFACE" == "both" ]]; then
    if _window_exists "main"; then
      echo "  · Spokesman already running (orchestrator:main)"
    else
      tmux new-window -t "orchestrator:" -n main
      tmux send-keys -t "orchestrator:main" "cd $AGENTMESH && claude --dangerously-skip-permissions" Enter
      _wait_for_repl "orchestrator:main"
      tmux send-keys -t "orchestrator:main" \
        "/spokesman --project $PROJECT --profile $PROFILE --mode $MODE --max-workers $MAX_WORKERS --review-limit $REVIEW_LIMIT --no-bootstrap" \
        Enter
      echo "  ✓ Spokesman started (orchestrator:main)"
    fi
  fi

  # 10. Start SlackBridge (orchestrator:slack-bridge) + slack-socket-relay
  if [[ "$INTERFACE" == "slack" || "$INTERFACE" == "both" ]]; then
    if _window_exists "slack-bridge"; then
      echo "  · SlackBridge already running (orchestrator:slack-bridge)"
    else
      tmux new-window -t "orchestrator:" -n slack-bridge
      tmux send-keys -t "orchestrator:slack-bridge" "cd $AGENTMESH && claude --dangerously-skip-permissions" Enter
      _wait_for_repl "orchestrator:slack-bridge"
      tmux send-keys -t "orchestrator:slack-bridge" \
        "/slack-bridge --project $PROJECT --profile $PROFILE --mode $MODE --verbosity $VERBOSITY --no-bootstrap" \
        Enter
      echo "  ✓ SlackBridge started (orchestrator:slack-bridge)"
    fi

    if _window_exists "slack-socket"; then
      echo "  · slack-socket-relay already running (orchestrator:slack-socket)"
    else
      tmux new-window -t "orchestrator:" -n slack-socket
      tmux send-keys -t "orchestrator:slack-socket" \
        "SLACK_APP_TOKEN=$SLACK_APP_TOKEN SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN:-} python3 $SCRIPTS/slack-socket-relay.py" \
        Enter
      echo "  ✓ slack-socket-relay started (orchestrator:slack-socket)"
    fi
  fi

  echo ""
  echo "agentmesh started. Project: ${PROJECT}. Interface: ${INTERFACE}. Mode: ${MODE}."
}

# ── stop ───────────────────────────────────────────────────────────────────────

cmd_stop() {
  # 1. Send shutdown command to orchestrator.py (best-effort — it may not be running)
  if [ -f "$SIGNALS/orchestrator-cmds" ]; then
    echo "-|shutdown" >> "$SIGNALS/orchestrator-cmds"
    tmux wait-for -S orchestrator-cmd-event 2>/dev/null || true
    sleep 2
  fi

  # 2. Kill known windows in the orchestrator session
  for win in slack-bridge slack-socket slack-poller main folder-cleanup watchdog dispatcher orchestrator; do
    tmux kill-window -t "orchestrator:$win" 2>/dev/null || true
  done

  # Kill any pr-mon-* windows
  tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null \
    | grep "^pr-mon-" \
    | while read -r w; do
        tmux kill-window -t "orchestrator:$w" 2>/dev/null || true
      done || true

  # 3. Kill workers session
  tmux kill-session -t workers 2>/dev/null || true

  # 4. Clear active-interfaces
  : > "$SIGNALS/active-interfaces" 2>/dev/null || true

  echo "agentmesh stopped."
}

# ── status ─────────────────────────────────────────────────────────────────────

cmd_status() {
  local age
  age=$(_heartbeat_age)

  # orchestrator.py
  if [ "$age" -lt 90 ]; then
    printf "%-22s ✓ running  (heartbeat: %ss ago)\n" "orchestrator.py" "$age"
  else
    printf "%-22s ✗ not running\n" "orchestrator.py"
  fi

  # tmux windows
  for win in dispatcher watchdog folder-cleanup; do
    if _window_exists "$win"; then
      printf "%-22s ✓ running\n" "$win"
    else
      printf "%-22s ✗ not running\n" "$win"
    fi
  done

  # spokesman
  if _window_exists "main"; then
    printf "%-22s ✓ running  (tmux: orchestrator:main)\n" "spokesman"
  else
    printf "%-22s ✗ not running\n" "spokesman"
  fi

  # slack-bridge
  if _window_exists "slack-bridge"; then
    printf "%-22s ✓ running\n" "slack-bridge"
  else
    printf "%-22s ✗ not running\n" "slack-bridge"
  fi

  # slack-socket-relay
  if _window_exists "slack-socket"; then
    printf "%-22s ✓ running\n" "slack-socket-relay"
  else
    printf "%-22s ✗ not running\n" "slack-socket-relay"
  fi

  # active workers
  local workers=0 worker_names=""
  if [ -f "$SIGNALS/workers" ]; then
    worker_names=$(grep -v '^#' "$SIGNALS/workers" 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
    workers=$(grep -v '^#' "$SIGNALS/workers" 2>/dev/null | grep -c . || echo 0)
  fi
  if [ -n "$worker_names" ]; then
    printf "%-22s %s  (%s)\n" "active workers" "$workers" "$worker_names"
  else
    printf "%-22s %s\n" "active workers" "$workers"
  fi

  # mode
  local mode="unknown"
  [ -f "$SIGNALS/mode" ] && mode=$(cat "$SIGNALS/mode")
  printf "%-22s %s\n" "mode" "$mode"

  # active interfaces
  local interfaces="(none)"
  if [ -f "$SIGNALS/active-interfaces" ] && [ -s "$SIGNALS/active-interfaces" ]; then
    interfaces=$(tr '\n' ',' < "$SIGNALS/active-interfaces" | sed 's/,$//')
  fi
  printf "%-22s %s\n" "active interfaces" "$interfaces"
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

# ── dispatch ───────────────────────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  start)  cmd_start  "$@" ;;
  stop)   cmd_stop   "$@" ;;
  status) cmd_status "$@" ;;
  attach) cmd_attach "$@" ;;
  task)   cmd_task   "$@" ;;
  *)
    echo "Usage: agentmesh <start|stop|status|attach|task> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  start         Start the agentmesh system" >&2
    echo "  stop          Stop the agentmesh system" >&2
    echo "  status        Show component health" >&2
    echo "  attach        Attach to the orchestrator tmux session" >&2
    echo "  task create   Create a new task in NoteCove" >&2
    exit 1
    ;;
esac
