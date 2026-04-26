#!/usr/bin/env bash
# watchdog.sh — detects crashed worker windows and re-queues their tasks
# Runs in a background tmux window alongside the dispatcher. Never exits.
set -euo pipefail

# cd to agentmesh so notecove can find its .notecove config
cd /Users/firas.gara/agentmesh

REGISTRY=/Users/firas.gara/agentmesh/signals/workers
QUEUE=/Users/firas.gara/agentmesh/signals/queue
LOG=/Users/firas.gara/agentmesh/signals/events.log

log_event() {
  printf '%s\twatchdog\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" >> "$LOG"
}

echo "[watchdog] started"

while true; do
  sleep 30

  # Nothing to watch if registry is absent or empty
  [[ ! -s "$REGISTRY" ]] && continue

  # Get live worker windows; if the workers session doesn't exist, treat as empty
  live_windows=$(tmux list-windows -t workers -F "#{window_name}" 2>/dev/null || true)

  # Snapshot registry to avoid read/write conflicts during loop
  registry_snapshot=$(cat "$REGISTRY")

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue

    slug=$(echo "$entry" | awk '{print $1}')
    window=$(echo "$entry" | awk '{print $2}')

    # Skip if the window is still live
    if echo "$live_windows" | grep -qxF "$window"; then
      continue
    fi

    # Window is gone — check task state
    # notecove is a shell function (not a binary), so call the CLI directly
    state=$(node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs task show "$slug" --json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stateId',''))" 2>/dev/null || true)

    if [[ "$state" == "doing" ]]; then
      echo "[watchdog] crash detected: $slug (window '$window' gone, state=doing)"
      log_event "crash-detected" "$slug"

      # Wake orchestrator
      echo "$slug" >> "$QUEUE"
      tmux wait-for -S worker-any-event
    else
      echo "[watchdog] $slug window gone but state=$state — no action needed"
      log_event "worker-exited-clean" "$slug"
    fi

    # Remove this entry from the registry regardless of state
    grep -vxF "$entry" "$REGISTRY" > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY" || true

  done <<< "$registry_snapshot"
done
