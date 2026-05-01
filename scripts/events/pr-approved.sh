#!/usr/bin/env bash
# pr-approved.sh <slug> <resume_sig> <project>
# Shared PR approval cleanup: mark Done, run task-done, kill pr-mon, remove signal flags.
# Called by pr-merged.sh (auto-approve) and by orchestrator.py (done/pr-approved command).
# Caller is responsible for calling pick_up_ready_tasks() after this script returns.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
RESUME_SIG="${2:?resume_sig required}"
PROJECT="${3:?project required}"

$NOTECOVE task change "$SLUG" --state Done
bash "${SCRIPTS}/task-done.sh" "$SLUG" "$PROJECT" "$RESUME_SIG"
tmux kill-window -t "orchestrator:pr-mon-${SLUG}" 2>/dev/null || true
rm -f "${SIGNALS}/${SLUG}.merged" "${SIGNALS}/${SLUG}.review-start"
rm -f "${SIGNALS}/${SLUG}.plan-review-count" "${SIGNALS}/${SLUG}.pr-review-count"
