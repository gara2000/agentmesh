#!/usr/bin/env bash
# plan-review-complete.sh <slug> <resume_sig> <mode>
# Handles event:plan-review-complete.
#   auto-review: pass review back to worker, kill plan-reviewer window.
#   standard:    forward to Spokesman.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
RESUME_SIG="${2:?resume_sig required}"
MODE="${3:?mode required}"

if [[ "$MODE" == "auto-review" ]]; then
    log_event "attention-resumed" "$SLUG"
    $NOTECOVE task comments add "$SLUG" --user "Orchestrator" \
        "Plan review complete (auto-review mode). Review the reviewer's comment and the REVIEW note in your task folder before implementing."
    $NOTECOVE task change "$SLUG" --state Doing
    tmux wait-for -S "$RESUME_SIG"
    tmux kill-window -t "workers:plan-rev-${SLUG}" 2>/dev/null || true
    rm -f "${SIGNALS}/${SLUG}.review-start"
else
    forward_to_spokesman "$SLUG" "event:plan-review-complete"
fi
