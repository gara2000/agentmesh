#!/usr/bin/env bash
# bootstrap.sh — initialize the AgentMesh runtime: notecove init, signals dir, daemons
# Usage: bootstrap.sh --project <PROJECT> [--profile <profile-id>] [--max-workers <n>]
#                     [--poll-interval <seconds>]
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS=$AGENTMESH/scripts
SIGNALS=$AGENTMESH/signals

# notecove is a shell function (not a binary), so call the CLI directly
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# Parse arguments
PROJECT=""
PROFILE="kmq9h71tepf95rac2b59xdbsq2"
MAX_WORKERS="30"
POLL_INTERVAL="30"

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

# 0a. Init NoteCove.
#     --events requests the events:subscribe permission the sidecars use for push
#     change detection. The first run after adding it may need approval in the
#     NoteCove desktop app; until granted, sidecars fall back to their poll
#     interval and log sse-unavailable:no-permission.
cd "$AGENTMESH"
$NOTECOVE init --profile "$PROFILE" --tasks-project "$PROJECT" --notes --events

# 0b. Kill any surviving per-task processes BEFORE clearing their state.
#     A sidecar that outlives the wipe below is actively harmful: with its
#     baseline files gone its next diff computes first_run=true, so it absorbs
#     everything new — including a reply the user is waiting on — into history
#     and never writes it to the inbox. The agent then blocks forever on a
#     message that was silently discarded.
#     The launcher's reconcile pass re-spawns a sidecar for every live worker on
#     its first scan, so killing them here costs nothing.
for _w in $(tmux list-windows -t orchestrator -F "#{window_name}" 2>/dev/null | grep -E '^(side-|pr-mon-)' || true); do
  tmux kill-window -t "orchestrator:${_w}" 2>/dev/null || true
done

# 0c. Create signals directory and log; clear stale runtime flags
mkdir -p "$SIGNALS"
: > "$SIGNALS/workers"
: > "$SIGNALS/events.log"
rm -f "$SIGNALS/"*.merged
rm -f "$SIGNALS/"*.crash-count
rm -f "$SIGNALS/"*.launching
rm -f "$SIGNALS/"*.untyped
rm -f "$SIGNALS/"*.inbox
rm -f "$SIGNALS/"*.seq
rm -f "$SIGNALS/"*.seen-comments
rm -f "$SIGNALS/"*.seen-state
rm -f "$SIGNALS/"*.backoff
rm -f "$SIGNALS/"*.sidecar-handle
# Deliberately NOT stamping launcher.heartbeat here. The heartbeat means "a scan
# completed", not "a process was started" — pre-stamping makes a launcher that
# dies on startup report healthy. launcher.py writes it after each scan.
rm -f "$SIGNALS/launcher.heartbeat"

LOG="$SIGNALS/events.log"

# Resolve and persist Triage folder ID so agents can use it without re-querying
TRIAGE_FOLDER=$($NOTECOVE folder list --json | python3 -c "
import sys, json
folders = json.load(sys.stdin)
print(next(f['id'] for f in folders if f['name'] == 'Triage' and f['parentId'] is None))")
echo "$TRIAGE_FOLDER" > "$SIGNALS/triage_folder"

printf '%s\tlauncher     \tbootstrap-complete\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

# 0e. Create orchestrator and workers tmux sessions (if not already running)
tmux new-session -d -s orchestrator 2>/dev/null || true
tmux new-session -d -s workers 2>/dev/null || true

# 0f. Launch watchdog in a background window
tmux list-windows -t orchestrator -F "#{window_name}" | grep -qx "watchdog" || {
  tmux new-window -t orchestrator -n watchdog
  tmux send-keys -t orchestrator:watchdog "bash $SCRIPTS/watchdog.sh" Enter
}

# 0g. Launch folder-cleanup daemon in a background window
tmux list-windows -t orchestrator -F "#{window_name}" | grep -qx "folder-cleanup" || {
  tmux new-window -t orchestrator -n folder-cleanup
  tmux send-keys -t orchestrator:folder-cleanup "bash $SCRIPTS/folder-cleanup.sh" Enter
}

# 0h. Launch the launcher daemon.
#     Always kill and restart so a stale/old-version launcher is replaced on every
#     bootstrap. Wrapped in a restart loop: nothing supervises the launcher, and
#     it is pure Python with no Claude dependency, so respawning in place is the
#     simplest form of supervision.
tmux list-windows -t orchestrator -F "#{window_name}" | grep -qx "launcher" && \
  tmux kill-window -t orchestrator:launcher 2>/dev/null || true
tmux new-window -t orchestrator -n launcher
tmux send-keys -t orchestrator:launcher \
  "cd $AGENTMESH && while true; do python3 $SCRIPTS/launcher.py --project $PROJECT --profile $PROFILE --max-workers $MAX_WORKERS --poll-interval $POLL_INTERVAL; printf '%s\tlauncher     \tprocess-exited-restarting\t-\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" >> '$LOG'; echo '[launcher] exited — restarting in 5s'; sleep 5; done" \
  Enter

echo "[bootstrap] complete — watchdog, folder-cleanup, and launcher running"
echo "[bootstrap] interact with agents through NoteCove task comments"
