#!/usr/bin/env bash
# plan-ready.sh <slug> <mode> <review_limit> <project>
# Handles event:plan-ready.
#   auto-review: spawn plan-reviewer (with cycle limit check).
#   standard:    forward to Spokesman for manual review.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
MODE="${2:?mode required}"
REVIEW_LIMIT="${3:?review_limit required}"
PROJECT="${4:?project required}"

if [[ "$MODE" == "auto-review" ]]; then
    COUNT=$(increment_review_count "$SLUG" "plan")
    if [[ "$COUNT" -gt "$REVIEW_LIMIT" ]]; then
        log_event "review-limit-reached:plan" "$SLUG"
        forward_to_spokesman "$SLUG" "event:review-limit-reached:plan"
        exit 0
    fi
    log_event "plan-reviewer-spawned" "$SLUG"
    $NOTECOVE task change "$SLUG" --state 'In Review'
    bash "${SCRIPTS}/spawn-agent.sh" workers "plan-rev-${SLUG}" /plan-reviewer "$SLUG" "$PROJECT"
    touch "${SIGNALS}/${SLUG}.review-start"
else
    forward_to_spokesman "$SLUG" "event:plan-ready"
fi
