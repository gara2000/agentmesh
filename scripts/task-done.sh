#!/usr/bin/env bash
# task-done.sh <slug> <PROJECT>
#
# Terminal-state cleanup, called by the worker itself via finish_task() in
# agent-notecove.sh once it has set Done or Won't Do.
#
# Order matters. Unblocking dependents runs FIRST because it is the step that
# must not be skipped: everything after it is housekeeping that the watchdog
# would eventually do anyway, but nothing else unblocks dependents. Before this
# refactor the orchestrator's event handlers called this script; they are gone,
# so the worker is now the only caller.
#
# This deliberately does NOT kill the calling worker's own window
# (workers:<slug>). The worker is running this script, so killing its window
# here would terminate the script mid-run. The worker exits on its own
# afterwards and the watchdog reaps the registry entry on its next poll.

set -euo pipefail

SLUG="${1:?Usage: task-done.sh <slug> <PROJECT>}"
PROJECT="${2:?Usage: task-done.sh <slug> <PROJECT>}"
AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# 1. Unblock any tasks whose only remaining blocker was this slug.
#    Retry up to 3 times with a 2s delay to handle API propagation lag after
#    the task was marked terminal.
sleep 2
_attempt=0
while [ $_attempt -lt 3 ]; do
  _attempt=$((_attempt + 1))
  _blocked_json=$($NOTECOVE task list --project "$PROJECT" --state Blocked --limit 100 --json)
  _blocked_slugs=$(echo "$_blocked_json" | python3 -c "import sys,json; [print(t['slug']['short']) for t in json.load(sys.stdin)]")
  # On the final attempt, process even if empty (no blocked tasks is a valid result)
  if [ -n "$_blocked_slugs" ] || [ $_attempt -eq 3 ]; then
    echo "$_blocked_slugs" | while read -r dep_slug; do
      [ -z "$dep_slug" ] && continue
      dep_json=$($NOTECOVE task show "$dep_slug" --json)
      should_unblock=$(echo "$dep_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
blockers = d.get('blockers', [])
blocker_slugs = [b['slug']['short'] for b in blockers]
if '$SLUG' not in blocker_slugs:
    sys.exit()
remaining = [b for b in blockers
             if b['slug']['short'] != '$SLUG'
             and not b.get('state', {}).get('isTerminal', False)]
if not remaining:
    print('yes')
" 2>/dev/null)
      if [ "$should_unblock" = "yes" ]; then
        $NOTECOVE task change "$dep_slug" --state Ready
      fi
    done
    break
  fi
  sleep 2
done

# 2. Kill the task's side processes.
#    side-* and pr-mon-* are NOT in signals/workers (they are not workers), so
#    nothing else would reap them promptly — kill them explicitly here.
tmux kill-window -t "orchestrator:side-${SLUG}" 2>/dev/null || true
tmux kill-window -t "orchestrator:pr-mon-${SLUG}" 2>/dev/null || true

# 3. Unregister from the worker registry.
#    Frees the max-workers slot now rather than waiting for the watchdog's poll.
sed -i '' "/^${SLUG} /d" "$AGENTMESH/signals/workers" 2>/dev/null || true

# 4. Remove per-task signal files
rm -f "$AGENTMESH/signals/${SLUG}.seq" \
      "$AGENTMESH/signals/${SLUG}.inbox" \
      "$AGENTMESH/signals/${SLUG}.launching" \
      "$AGENTMESH/signals/${SLUG}.untyped" \
      "$AGENTMESH/signals/${SLUG}.seen-comments" \
      "$AGENTMESH/signals/${SLUG}.seen-state" \
      "$AGENTMESH/signals/${SLUG}.merged" \
      "$AGENTMESH/signals/${SLUG}.sidecar-handle" \
      "$AGENTMESH/signals/${SLUG}.backoff"

printf '%s\ttask-done    \tcleanup-complete\t%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SLUG" >> "$AGENTMESH/signals/events.log"
