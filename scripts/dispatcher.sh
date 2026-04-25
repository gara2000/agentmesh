#!/usr/bin/env bash
# dispatcher.sh — fan-in relay: any worker event → orchestrator event
# Runs in a background tmux pane. Never exits.
set -euo pipefail

echo "[dispatcher] started"

while true; do
  tmux wait-for "worker-any-event"
  tmux wait-for -S "orchestrator-event"
done
