#!/usr/bin/env bash
# pr-ready.sh <slug> <pr_url> <resume_sig> <mode> <review_limit> <project>
# Handles event:pr-ready:<url> — three-way dispatch:
#   auto-review, first signal:  spawn pr-reviewer (with cycle limit check).
#   auto-review, post-review:   PR validated; forward as pr-ready for final user approval.
#   standard:                   forward as pr-submitted for user decision.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
PR_URL="${2:?pr_url required}"
RESUME_SIG="${3:?resume_sig required}"
MODE="${4:?mode required}"
REVIEW_LIMIT="${5:?review_limit required}"
PROJECT="${6:?project required}"

REVIEWED_FLAG="${SIGNALS}/${SLUG}.reviewed"

if [[ "$MODE" == "auto-review" && ! -f "$REVIEWED_FLAG" ]]; then
    # First PR signal in auto-review mode: spawn reviewer.
    COUNT=$(increment_review_count "$SLUG" "pr")
    if [[ "$COUNT" -gt "$REVIEW_LIMIT" ]]; then
        log_event "review-limit-reached:pr" "$SLUG"
        forward_to_spokesman "$SLUG" "event:review-limit-reached:pr:${PR_URL}"
        exit 0
    fi
    log_event "reviewer-spawning" "$SLUG"
    $NOTECOVE task change "$SLUG" --state 'In Review'
    bash "${SCRIPTS}/spawn-agent.sh" workers "pr-rev-${SLUG}" /pr-reviewer "$SLUG" "$PROJECT"
    log_event "reviewer-spawned" "$SLUG"
    touch "${SIGNALS}/${SLUG}.review-start"
    spawn_pr_monitor "$SLUG" "$PR_URL"
elif [[ -f "$REVIEWED_FLAG" ]]; then
    # Post-review signal: PR has been validated by reviewer; clear flag and forward for approval.
    rm -f "$REVIEWED_FLAG"
    spawn_pr_monitor "$SLUG" "$PR_URL"
    forward_to_spokesman "$SLUG" "event:pr-ready:${PR_URL}"
else
    # Standard mode: worker submitted PR; forward for user decision (review or approve).
    spawn_pr_monitor "$SLUG" "$PR_URL"
    forward_to_spokesman "$SLUG" "event:pr-submitted:${PR_URL}"
fi
