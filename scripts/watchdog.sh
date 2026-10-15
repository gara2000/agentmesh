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
        "${SIGNALS}/${slug}.seen-state" \
        "${SIGNALS}/${slug}.sidecar-handle"
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
        # During this sleep the task still reads `doing` and its window is gone,
        # which is precisely the launcher's adoption trigger. Both run on a 30s
        # cadence and the first backoff is 30s, so the overlap is near-certain
        # rather than a narrow race. Without the sentinel the launcher adopts the
        # task mid-sleep and this branch then tears the new worker down:
        # cleanup_task kills its freshly-inherited sidecar, leaving it unable to
        # ever be nudged, and the re-queue to Ready makes pickup spawn a second
        # worker for the same task.
        touch "${SIGNALS}/${slug}.backoff"
        sleep "$backoff_secs"
        rm -f "${SIGNALS}/${slug}.backoff"

        # Belt and braces: if a worker reappeared anyway (sentinel missed, or the
        # launcher adopted before it was written), adoption has taken over — leave
        # it alone rather than killing a live worker.
        if tmux list-windows -t workers -F '#{window_name}' 2>/dev/null | grep -qxF "$window"; then
          echo "[watchdog] $slug was adopted during backoff — standing down"
          log_event "backoff-aborted-adopted" "$slug"
          continue
        fi

        # Back to Ready — the launcher spawns a fresh worker on its next scan.
        cleanup_task "$slug"
        $NOTECOVE task change "$slug" --state Ready 2>/dev/null || true
      fi
    elif [[ "$state" == "attention" ]]; then
      # Attention + dead window is NOT a clean exit: the task is mid-conversation
      # with the user and its worker is gone. Normally we deregister and leave the
      # sidecar, inbox, and seq intact for the launcher's adoption pass — a reply
      # waiting in the inbox must survive until the new worker reads it.
      #
      # But this path MUST still count crashes. Adoption respawns on a 30s
      # cadence, so a worker that reproducibly dies right after await_user would
      # otherwise be respawned forever, with no cap and nothing told to the user.
      # (Resetting the counter here, as this branch first did, guaranteed that.)
      crash_count_file="${SIGNALS}/${slug}.crash-count"
      crash_count=0
      [[ -f "$crash_count_file" ]] && crash_count=$(cat "$crash_count_file" 2>/dev/null || echo 0)
      new_count=$((crash_count + 1))

      if [[ $new_count -ge $MAX_CRASH_COUNT ]]; then
        echo "[watchdog] $slug died in Attention $new_count times — setting Blocked"
        log_event "crash-limit-reached-attention" "$slug"
        rm -f "$crash_count_file"
        $NOTECOVE task comments add "$slug" --user "Watchdog" \
          "Worker died ${new_count} times while waiting for your input, so the task has been set to Blocked and will not be retried automatically. Any reply you left may not have been read — needs investigation." 2>/dev/null || true
        $NOTECOVE task change "$slug" --state Blocked 2>/dev/null || true
        cleanup_task "$slug"
      else
        echo "[watchdog] $slug window gone while in Attention ($new_count) — leaving for launcher adoption"
        log_event "worker-stranded-attention" "$slug"
        echo "$new_count" > "$crash_count_file"
      fi
    else
      echo "[watchdog] $slug window gone but state=$state — no action needed"
      log_event "worker-exited-clean" "$slug"
      # Reset crash count on clean exit
      rm -f "${SIGNALS}/${slug}.crash-count"
      cleanup_task "$slug"
    fi

    # Remove this entry from the registry regardless of state.
    # Do NOT gate the mv on grep's exit status: grep -v exits 1 when it produces
    # no output, which is exactly the case where this was the only entry. Gating
    # on it leaves that last line in place forever, permanently burning one of
    # max-workers slots and re-processing the phantom worker every 30s.
    grep -vxF "$entry" "$REGISTRY" > "${REGISTRY}.tmp" 2>/dev/null || true
    mv "${REGISTRY}.tmp" "$REGISTRY" 2>/dev/null || true

  done <<< "$registry_snapshot"
done
