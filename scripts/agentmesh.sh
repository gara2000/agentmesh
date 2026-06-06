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
  last_modified=$(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null)
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
  local VERBOSITY="medium" SLACK_CHANNEL="" SLACK_POLLER_INTERVAL="5"

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
      --slack-poller-interval) SLACK_POLLER_INTERVAL="$2"; shift 2 ;;
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
      ${SLACK_CHANNEL:+--slack-channel "$SLACK_CHANNEL"} \
      --slack-poller-interval "$SLACK_POLLER_INTERVAL"
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

  # 10. Start SlackBridge (orchestrator:slack-bridge) + slack-poller
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

    if _window_exists "slack-poller"; then
      echo "  · slack-poller already running (orchestrator:slack-poller)"
    else
      tmux new-window -t "orchestrator:" -n slack-poller
      tmux send-keys -t "orchestrator:slack-poller" \
        "bash $SCRIPTS/slack-poller.sh --interval $SLACK_POLLER_INTERVAL" \
        Enter
      echo "  ✓ slack-poller started (orchestrator:slack-poller)"
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
  for win in slack-bridge slack-poller main folder-cleanup watchdog dispatcher orchestrator; do
    tmux kill-window -t "orchestrator:$win" 2>/dev/null || true
  done

  # Kill any pr-mon-* windows
  tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null \
    | grep "^pr-mon-" \
    | while read -r w; do
        tmux kill-window -t "orchestrator:$w" 2>/dev/null || true
      done

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

  # slack-poller
  if _window_exists "slack-poller"; then
    printf "%-22s ✓ running\n" "slack-poller"
  else
    printf "%-22s ✗ not running\n" "slack-poller"
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

# ── dispatch ───────────────────────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  start)  cmd_start  "$@" ;;
  stop)   cmd_stop   "$@" ;;
  status) cmd_status "$@" ;;
  attach) cmd_attach "$@" ;;
  *)
    echo "Usage: agentmesh <start|stop|status|attach> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  start   Start the agentmesh system" >&2
    echo "  stop    Stop the agentmesh system" >&2
    echo "  status  Show component health" >&2
    echo "  attach  Attach to the orchestrator tmux session" >&2
    exit 1
    ;;
esac
