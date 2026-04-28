#!/bin/bash
# task-done.sh <slug> <PROJECT> [<resume-sig>]
#
# Unblock dependents, clean up worker windows, unregister from the worker
# registry, and remove the seq file. Called by the orchestrator whenever a
# task reaches a terminal state (Done, Won't Do, etc.).
#
# If <resume-sig> is provided, fires that tmux signal first so the blocked
# worker unblocks before its windows are killed. Omit it when the worker is
# already gone (crash path, abort after external state change).

set -euo pipefail

SLUG="${1:?Usage: task-done.sh <slug> <PROJECT> [<resume-sig>]}"
PROJECT="${2:?Usage: task-done.sh <slug> <PROJECT> [<resume-sig>]}"
RESUME_SIG="${3:-}"
AGENTMESH=/Users/firas.gara/agentmesh

# 1. Fire resume signal if the worker is blocked waiting
if [ -n "$RESUME_SIG" ]; then
  tmux wait-for -S "$RESUME_SIG"
fi

# 2. Kill worker tmux windows
tmux kill-window -t "workers:${SLUG}" 2>/dev/null || true
tmux kill-window -t "workers:plan-rev-${SLUG}" 2>/dev/null || true
tmux kill-window -t "workers:pr-rev-${SLUG}" 2>/dev/null || true

# 3. Unregister from the worker registry and remove seq file
sed -i '' "/^${SLUG} /d" "$AGENTMESH/signals/workers"
rm -f "$AGENTMESH/signals/${SLUG}.seq"

# 4. Unblock any tasks whose only remaining blocker was this slug.
#    Retry up to 3 times with a 2s delay to handle API propagation lag after
#    the task was marked Done.
sleep 2
_attempt=0
while [ $_attempt -lt 3 ]; do
  _attempt=$((_attempt + 1))
  _blocked_json=$(notecove task list --project "$PROJECT" --state Blocked --limit 100 --json)
  _blocked_slugs=$(echo "$_blocked_json" | python3 -c "import sys,json; [print(t['slug']['short']) for t in json.load(sys.stdin)]")
  if [ -n "$_blocked_slugs" ] || [ $_attempt -eq 3 ]; then
    echo "$_blocked_slugs" | while read -r dep_slug; do
      [ -z "$dep_slug" ] && continue
      dep_json=$(notecove task show "$dep_slug" --json)
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
        notecove task change "$dep_slug" --state Ready
      fi
    done
    break
  fi
  sleep 2
done
