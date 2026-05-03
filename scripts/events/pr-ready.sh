#!/usr/bin/env bash
# pr-ready.sh <slug> <pr_url> <resume_sig> <mode> <review_limit> <project>
# Handles event:pr-ready:<url> — worker's FIRST PR submission.
#   auto-review: always spawn pr-reviewer (no limit check; first review always runs).
#                Counter is initialized to 1. Re-review cycles use event:pr-revised.
#                Final user approval uses event:pr-ready-final.
#   standard:    forward as pr-submitted for user decision.
# pr-monitor is spawned by orchestrator.py before this script runs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
PR_URL="${2:?pr_url required}"
RESUME_SIG="${3:?resume_sig required}"
MODE="${4:?mode required}"
REVIEW_LIMIT="${5:?review_limit required}"
PROJECT="${6:?project required}"

if [[ "$MODE" == "auto-review" ]]; then
    # Initialize counter to 1 (first review — no limit check needed).
    increment_review_count "$SLUG" "pr" > /dev/null
    log_event "reviewer-spawning" "$SLUG"
    $NOTECOVE task change "$SLUG" --state 'In Review'
    bash "${SCRIPTS}/spawn-agent.sh" workers "pr-rev-${SLUG}" /pr-reviewer "$SLUG" "$PROJECT"
    log_event "reviewer-spawned" "$SLUG"
    touch "${SIGNALS}/${SLUG}.review-start"
else
    # Standard mode: worker submitted PR; forward for user decision (review or approve).
    forward_to_spokesman "$SLUG" "event:pr-submitted:${PR_URL}"
fi
