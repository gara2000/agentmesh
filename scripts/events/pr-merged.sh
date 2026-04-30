#!/usr/bin/env bash
# pr-merged.sh <slug> <resume_sig> <project>
# Handles event:pr-merged: auto-approves the PR if the task is in attention or in-review state.
# Exits 0 (no action) if the task is already in a terminal state (idempotent guard).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
RESUME_SIG="${2:?resume_sig required}"
PROJECT="${3:?project required}"

# Guard: only act if the task is awaiting user action or under review.
# Without this check, a stale pr-merged event could double-approve an already-done task.
STATE=$($NOTECOVE task show "$SLUG" --json | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d.get('state', {})
print((s.get('name', '') if isinstance(s, dict) else '').lower() or d.get('stateName', '').lower())
")
if [[ "$STATE" != "attention" && "$STATE" != "in review" ]]; then
    exit 0
fi

log_event "pr-auto-approved" "$SLUG"
# pr-approved.sh does not call pick_up_ready_tasks; the Python caller does after we return.
bash "${SCRIPTS}/events/pr-approved.sh" "$SLUG" "$RESUME_SIG" "$PROJECT"
forward_to_spokesman "$SLUG" "event:pr-merged-auto-approved"
