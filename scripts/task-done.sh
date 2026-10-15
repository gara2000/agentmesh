#!/usr/bin/env bash
# task-done.sh <slug> <PROJECT> [<nudge-sig>]
#
# Unblock dependents, kill the task's worker/sidecar/pr-monitor windows,
# unregister from the worker registry, and remove per-task signal files.
# Run whenever a task reaches a terminal state (Done, Won't Do, etc.).
#
# If <nudge-sig> is provided, fires that tmux signal first so a blocked worker
# unblocks before its windows are killed. Omit it when the worker is already
# gone (crash path, abort after an external state change).

set -euo pipefail

SLUG="${1:?Usage: task-done.sh <slug> <PROJECT> [<nudge-sig>]}"
PROJECT="${2:?Usage: task-done.sh <slug> <PROJECT> [<nudge-sig>]}"
RESUME_SIG="${3:-}"
AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

# 1. Fire the nudge signal if the worker is blocked waiting
if [ -n "$RESUME_SIG" ]; then
  tmux wait-for -S "$RESUME_SIG"
fi

# 2. Kill the task's windows.
#    side-* and pr-mon-* are NOT in signals/workers (they are not workers), so
#    nothing else would ever reap them — they must be killed explicitly here.
tmux kill-window -t "workers:${SLUG}" 2>/dev/null || true
tmux kill-window -t "orchestrator:side-${SLUG}" 2>/dev/null || true
tmux kill-window -t "orchestrator:pr-mon-${SLUG}" 2>/dev/null || true

# 3. Unregister from the worker registry
sed -i '' "/^${SLUG} /d" "$AGENTMESH/signals/workers" 2>/dev/null || true

# 4. Remove per-task signal files
rm -f "$AGENTMESH/signals/${SLUG}.seq" \
      "$AGENTMESH/signals/${SLUG}.inbox" \
      "$AGENTMESH/signals/${SLUG}.launching" \
      "$AGENTMESH/signals/${SLUG}.untyped" \
      "$AGENTMESH/signals/${SLUG}.seen-comments" \
      "$AGENTMESH/signals/${SLUG}.seen-state" \
      "$AGENTMESH/signals/${SLUG}.merged"

# 5. Unblock any tasks whose only remaining blocker was this slug.
#    Retry up to 3 times with a 2s delay to handle API propagation lag after
#    the task was marked Done.
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
