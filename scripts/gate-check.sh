#!/usr/bin/env bash
# gate-check.sh — shared gh:pr gate check loop; fires event:pr-merged when a PR gate resolves
# Usage: gate-check.sh [<interval-seconds>]
# Runs in orchestrator:gate-check tmux window. Replaces per-PR pr-monitor.sh daemon in the long run.
# Transition mode: runs in parallel with pr-monitor.sh — both write event:pr-merged to the queue;
# the orchestrator handles duplicate events idempotently.
set -uo pipefail

INTERVAL="${1:-30}"

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
QUEUE="$AGENTMESH/signals/queue"
LOG="$AGENTMESH/signals/events.log"

log_event() {
  printf '%s\tgate-check   \t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG"
}

echo "[gate-check] started, polling every ${INTERVAL}s"
log_event "started" "-"

while true; do
  # Snapshot open gh:pr gate IDs before running check
  BEFORE=$(bd gate list --json 2>/dev/null \
    | python3 -c "
import sys, json
gates = json.load(sys.stdin) or []
ids = [g['id'] for g in gates if g.get('await_type') == 'gh:pr' and g.get('status') == 'open']
print('\n'.join(ids))
" 2>/dev/null || true)

  if [ -z "$BEFORE" ]; then
    sleep "$INTERVAL"
    continue
  fi

  # Run the gate check — this closes any gates whose PRs are now merged
  bd gate check --type=gh:pr 2>/dev/null || true

  # Snapshot open gh:pr gate IDs after the check
  AFTER=$(bd gate list --json 2>/dev/null \
    | python3 -c "
import sys, json
gates = json.load(sys.stdin) or []
ids = [g['id'] for g in gates if g.get('await_type') == 'gh:pr' and g.get('status') == 'open']
print('\n'.join(ids))
" 2>/dev/null || true)

  # Find newly-resolved gate IDs (were open before, not open after)
  RESOLVED_IDS=$(comm -23 <(echo "$BEFORE" | sort) <(echo "$AFTER" | sort))

  if [ -n "$RESOLVED_IDS" ]; then
    # Look up each resolved gate in --all to get description and extract slug
    ALL_GATES=$(bd gate list --all --json 2>/dev/null || echo "[]")

    echo "$RESOLVED_IDS" | while IFS= read -r gate_id; do
      [ -z "$gate_id" ] && continue

      # Extract slug from gate description: "Reason: slug:WORK-xxx ..."
      SLUG=$(echo "$ALL_GATES" \
        | python3 -c "
import sys, json, re
gates = json.load(sys.stdin) or []
gate = next((g for g in gates if g.get('id') == '$gate_id'), None)
if gate:
    m = re.search(r'slug:(\S+)', gate.get('description', ''))
    if m:
        print(m.group(1))
" 2>/dev/null || true)

      if [ -z "$SLUG" ]; then
        echo "[gate-check] WARNING: resolved gate $gate_id has no slug in description — skipping"
        log_event "pr-merged-no-slug" "$gate_id"
        continue
      fi

      echo "[gate-check] PR merged for $SLUG (gate $gate_id) — firing auto-approval"
      log_event "pr-merged-detected" "$SLUG"

      # Write merge flag and queue entry (same as pr-monitor.sh)
      touch "$AGENTMESH/signals/${SLUG}.merged"
      echo "${SLUG}:event:pr-merged" >> "$QUEUE"
      tmux wait-for -S worker-any-event
    done
  fi

  sleep "$INTERVAL"
done
