#!/usr/bin/env bash
# watchdog.sh — detects crashed worker windows and re-queues their tasks
# Runs in a background tmux window in the orchestrator session. Never exits.
#
# Crash retry behavior:
#   - Tracks consecutive crashes in signals/<slug>.crash-count
#   - Applies exponential backoff before re-queuing: 30s, 60s (30 × 2^(n-1))
#   - Re-queues the task to Ready; the launcher picks it up on its next scan
#   - After 3 consecutive crashes, sets task to Blocked and comments on the task
#   - Resets crash count on clean worker exit
#
# Setting state here is the one exception to "only the worker and the user change
# state": a crashed worker cannot set its own state, and the alternative is a task
# stuck in Doing with nothing running. Blocked also doubles as the user-visible
# escalation, since no process relays notifications to the user any more.
set -euo pipefail

# cd to agentmesh so notecove can find its .notecove config
AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$AGENTMESH"

REGISTRY="${AGENTMESH}/signals/workers"
SIGNALS="${AGENTMESH}/signals"
LOG="${AGENTMESH}/signals/events.log"
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"
MAX_CRASH_COUNT=3

log_event() {
  printf '%s\twatchdog     \t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" >> "$LOG"
}

# Tear down the per-task side processes and flags left behind by a dead worker.
# The sidecar window is killed explicitly: it is not in signals/workers, so
# nothing else would ever reap it.
cleanup_task() {
  local slug="$1"
  tmux kill-window -t "orchestrator:side-${slug}" 2>/dev/null || true
  tmux kill-window -t "orchestrator:pr-mon-${slug}" 2>/dev/null || true
  rm -f "${SIGNALS}/${slug}.inbox" "${SIGNALS}/${slug}.seq" \
        "${SIGNALS}/${slug}.launching" "${SIGNALS}/${slug}.seen-comments" \
        "${SIGNALS}/${slug}.seen-state"
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
    state=$($NOTECOVE task show "$slug" --json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stateId',''))" 2>/dev/null || true)

    if [[ "$state" == "doing" ]]; then
      # Read crash count (default 0), increment
      crash_count_file="${SIGNALS}/${slug}.crash-count"
      crash_count=0
      [[ -f "$crash_count_file" ]] && crash_count=$(cat "$crash_count_file" 2>/dev/null || echo 0)
      new_count=$((crash_count + 1))

      if [[ $new_count -ge $MAX_CRASH_COUNT ]]; then
        echo "[watchdog] crash limit reached for $slug ($new_count crashes) — setting Blocked"
        log_event "crash-limit-reached" "$slug"
        rm -f "$crash_count_file"
        $NOTECOVE task comments add "$slug" --user "Watchdog" \
          "Worker crashed ${new_count} times in a row and has been set to Blocked. It will not be retried automatically — needs investigation." 2>/dev/null || true
        $NOTECOVE task change "$slug" --state Blocked 2>/dev/null || true
        cleanup_task "$slug"
      else
        echo "[watchdog] crash $new_count for $slug — backing off before retry"
        log_event "crash-detected" "$slug"
        echo "$new_count" > "$crash_count_file"
        # Backoff: 30s × 2^(new_count - 1) → 30s, 60s
        backoff_secs=$((30 * (2 ** (new_count - 1))))
        echo "[watchdog] sleeping ${backoff_secs}s before re-queuing $slug"
        sleep "$backoff_secs"
        # Back to Ready — the launcher spawns a fresh worker on its next scan.
        cleanup_task "$slug"
        $NOTECOVE task change "$slug" --state Ready 2>/dev/null || true
      fi
    else
      echo "[watchdog] $slug window gone but state=$state — no action needed"
      log_event "worker-exited-clean" "$slug"
      # Reset crash count on clean exit
      rm -f "${SIGNALS}/${slug}.crash-count"
      cleanup_task "$slug"
    fi

    # Remove this entry from the registry regardless of state
    grep -vxF "$entry" "$REGISTRY" > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY" || true

  done <<< "$registry_snapshot"
done
