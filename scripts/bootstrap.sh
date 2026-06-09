#!/usr/bin/env bash
# bootstrap.sh — initialize orchestrator runtime: notecove init, signals dir, dispatcher, watchdog, orchestrator.py
# Usage: bootstrap.sh --project <PROJECT> [--profile <profile-id>] [--mode standard|auto-review] [--max-workers <n>] [--review-limit <n>]
#                     [--interface spokesman|slack|both] [--slack-channel <channel-id>] [--slack-poller-interval <seconds>]
set -euo pipefail

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS=$AGENTMESH/scripts
SIGNALS=$AGENTMESH/signals

# notecove is a shell function (not a binary), so call the CLI directly
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# Parse arguments
PROJECT=""
PROFILE="kmq9h71tepf95rac2b59xdbsq2"
MODE="standard"
MAX_WORKERS="10"
REVIEW_LIMIT="3"
INTERFACE="spokesman"
SLACK_CHANNEL=""
SLACK_POLLER_INTERVAL="5"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --max-workers) MAX_WORKERS="$2"; shift 2 ;;
    --review-limit) REVIEW_LIMIT="$2"; shift 2 ;;
    --interface) INTERFACE="$2"; shift 2 ;;
    --slack-channel) SLACK_CHANNEL="$2"; shift 2 ;;
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

# 0a. Init NoteCove
cd "$AGENTMESH"
$NOTECOVE init --profile "$PROFILE" --tasks-project "$PROJECT" --notes

# 0b. Create signals directory, empty queue, registry, and log; clear stale runtime flags
mkdir -p "$SIGNALS"
: > "$SIGNALS/queue"
: > "$SIGNALS/workers"
: > "$SIGNALS/events.log"
: > "$SIGNALS/spokesman-queue"
: > "$SIGNALS/slackbridge-queue"
: > "$SIGNALS/active-interfaces"
: > "$SIGNALS/orchestrator-cmds"
# Write slack-channel file (empty when slack interface is not in use)
echo "${SLACK_CHANNEL}" > "$SIGNALS/slack-channel"
rm -f "$SIGNALS/"*.merged
date -u +%Y-%m-%dT%H:%M:%SZ > "$SIGNALS/orchestrator.heartbeat"
rm -f "$SIGNALS/"*.review-start
rm -f "$SIGNALS/"*.plan-review-count
rm -f "$SIGNALS/"*.pr-review-count
rm -f "$SIGNALS/"*.crash-count

# Persist orchestrator launch command so Spokesman can restart it on stale heartbeat
echo "python3 $SCRIPTS/orchestrator.py --project $PROJECT --profile $PROFILE --mode $MODE --max-workers $MAX_WORKERS --review-limit $REVIEW_LIMIT" > "$SIGNALS/orchestrator-restart-cmd"

LOG="$SIGNALS/events.log"

# Resolve and persist Triage folder ID so agents can use it without re-querying
TRIAGE_FOLDER=$($NOTECOVE folder list --json | python3 -c "
import sys, json
folders = json.load(sys.stdin)
print(next(f['id'] for f in folders if f['name'] == 'Triage' and f['parentId'] is None))")
echo "$TRIAGE_FOLDER" > "$SIGNALS/triage_folder"

printf '%s\torchestrator \tbootstrap-complete\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

# 0c. Create orchestrator and workers tmux sessions (if not already running)
tmux new-session -d -s orchestrator 2>/dev/null || true
tmux new-session -d -s workers 2>/dev/null || true

# 0d. Launch dispatcher in a background window
tmux list-windows -t orchestrator -F "#{window_name}" | grep -qx "dispatcher" || {
  tmux new-window -t orchestrator -n dispatcher
  tmux send-keys -t orchestrator:dispatcher "bash $SCRIPTS/dispatcher.sh" Enter
}

# 0e. Launch watchdog in a background window
tmux list-windows -t orchestrator -F "#{window_name}" | grep -qx "watchdog" || {
  tmux new-window -t orchestrator -n watchdog
  tmux send-keys -t orchestrator:watchdog "bash $SCRIPTS/watchdog.sh" Enter
}

# 0f. Launch folder-cleanup daemon in a background window
tmux list-windows -t orchestrator -F "#{window_name}" | grep -qx "folder-cleanup" || {
  tmux new-window -t orchestrator -n folder-cleanup
  tmux send-keys -t orchestrator:folder-cleanup "bash $SCRIPTS/folder-cleanup.sh" Enter
}

# 0g. Launch orchestrator.py daemon (handles all event routing and worker spawning)
# Always kill and restart — ensures stale/old-version orchestrators are replaced on every bootstrap.
tmux list-windows -t orchestrator -F "#{window_name}" | grep -qx "orchestrator" && \
  tmux kill-window -t orchestrator:orchestrator 2>/dev/null || true
tmux new-window -t orchestrator -n orchestrator
tmux send-keys -t orchestrator:orchestrator \
  "cd $AGENTMESH && python3 $SCRIPTS/orchestrator.py --project $PROJECT --profile $PROFILE --mode $MODE --max-workers $MAX_WORKERS --review-limit $REVIEW_LIMIT" \
  Enter

# 0h. Launch slack-poller when interface includes slack
if [[ "$INTERFACE" == "slack" || "$INTERFACE" == "both" ]]; then
  tmux list-windows -t orchestrator -F "#{window_name}" | grep -qx "slack-poller" && \
    tmux kill-window -t orchestrator:slack-poller 2>/dev/null || true
  tmux new-window -t orchestrator -n slack-poller
  tmux send-keys -t orchestrator:slack-poller \
    "bash $SCRIPTS/slack-poller.sh --interval $SLACK_POLLER_INTERVAL" \
    Enter
fi

if [[ "$INTERFACE" == "slack" || "$INTERFACE" == "both" ]]; then
  echo "[bootstrap] complete — dispatcher, watchdog, folder-cleanup, orchestrator.py, and slack-poller running"
else
  echo "[bootstrap] complete — dispatcher, watchdog, folder-cleanup, and orchestrator.py running"
fi
