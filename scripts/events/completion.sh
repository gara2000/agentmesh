#!/usr/bin/env bash
# completion.sh <slug> <resume_sig> <project>
# Handles event:completion (planner/brainstormer): marks Done, unblocks worker, notifies Spokesman.
# Caller is responsible for calling pick_up_ready_tasks() after this script returns.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
RESUME_SIG="${2:?resume_sig required}"
PROJECT="${3:?project required}"

log_event "agent-completion-ack" "$SLUG"
$NOTECOVE task change "$SLUG" --state Done
bash "${SCRIPTS}/task-done.sh" "$SLUG" "$PROJECT" "$RESUME_SIG"
rm -f "${SIGNALS}/${SLUG}.plan-review-count" "${SIGNALS}/${SLUG}.pr-review-count"
forward_to_spokesman "$SLUG" "event:completion"
