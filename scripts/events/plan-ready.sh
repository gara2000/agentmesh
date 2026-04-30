#!/usr/bin/env bash
# plan-ready.sh <slug> <mode> <review_limit> <project>
# Handles event:plan-ready — worker's FIRST plan submission.
#   auto-review: always spawn plan-reviewer (no limit check; first review always runs).
#                Counter is initialized to 1. Re-review cycles use event:plan-revised.
#   standard:    forward to Spokesman for manual review.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
MODE="${2:?mode required}"
REVIEW_LIMIT="${3:?review_limit required}"
PROJECT="${4:?project required}"

if [[ "$MODE" == "auto-review" ]]; then
    # Initialize counter to 1 (first review — no limit check needed).
    increment_review_count "$SLUG" "plan" > /dev/null
    log_event "plan-reviewer-spawned" "$SLUG"
    $NOTECOVE task change "$SLUG" --state 'In Review'
    bash "${SCRIPTS}/spawn-agent.sh" workers "plan-rev-${SLUG}" /plan-reviewer "$SLUG" "$PROJECT"
    touch "${SIGNALS}/${SLUG}.review-start"
else
    forward_to_spokesman "$SLUG" "event:plan-ready"
fi
