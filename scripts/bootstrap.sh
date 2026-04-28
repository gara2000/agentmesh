#!/usr/bin/env bash
# bootstrap.sh — initialize orchestrator runtime: notecove init, signals dir, dispatcher, watchdog
# Usage: bootstrap.sh --project <PROJECT> [--profile <profile-id>]
set -euo pipefail

AGENTMESH=/Users/firas.gara/agentmesh
SCRIPTS=$AGENTMESH/scripts
SIGNALS=$AGENTMESH/signals

# notecove is a shell function (not a binary), so call the CLI directly
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# Parse arguments
PROJECT=""
PROFILE="kmq9h71tepf95rac2b59xdbsq2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "Error: --project is required" >&2
  exit 1
fi

# 0a. Init NoteCove
cd "$AGENTMESH"
$NOTECOVE init --profile "$PROFILE" --tasks-project "$PROJECT" --notes

# 0b. Create signals directory, empty queue, registry, and log; clear stale runtime flags
mkdir -p "$SIGNALS"
: > "$SIGNALS/queue"
: > "$SIGNALS/workers"
: > "$SIGNALS/events.log"
rm -f "$SIGNALS/"*.merged
rm -f "$SIGNALS/"*.reviewed

LOG="$SIGNALS/events.log"

# Resolve and persist Triage folder ID so agents can use it without re-querying
TRIAGE_FOLDER=$($NOTECOVE folder list --json | python3 -c "
import sys, json
folders = json.load(sys.stdin)
print(next(f['id'] for f in folders if f['name'] == 'Triage' and f['parentId'] is None))")
echo "$TRIAGE_FOLDER" > "$SIGNALS/triage_folder"

printf '%s\torchestrator \tbootstrap-complete\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

# 0c. Create workers tmux session (if not already running)
tmux new-session -d -s workers 2>/dev/null || true

# 0d. Launch dispatcher in a background window
tmux list-windows -t orchestrator | grep -q dispatcher || {
  tmux new-window -t orchestrator -n dispatcher
  tmux send-keys -t orchestrator:dispatcher "bash $SCRIPTS/dispatcher.sh" Enter
}

# 0e. Launch watchdog in a background window
tmux list-windows -t orchestrator | grep -q watchdog || {
  tmux new-window -t orchestrator -n watchdog
  tmux send-keys -t orchestrator:watchdog "bash $SCRIPTS/watchdog.sh" Enter
}

echo "[bootstrap] complete — dispatcher and watchdog running"
