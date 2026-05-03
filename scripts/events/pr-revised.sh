#!/usr/bin/env bash
# pr-revised.sh <slug> <pr_url> <resume_sig> <mode> <review_limit> <project>
# Handles event:pr-revised:<url> — worker re-signals after addressing pr-reviewer feedback
# and wants another automated review cycle.
#   auto-review: spawn pr-reviewer again (increment counter, check limit).
#                pr-monitor was spawned at pr-ready and keeps running — no spawn needed here.
#   standard:    forward as pr-submitted for user decision.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
PR_URL="${2:?pr_url required}"
RESUME_SIG="${3:?resume_sig required}"
MODE="${4:?mode required}"
REVIEW_LIMIT="${5:?review_limit required}"
PROJECT="${6:?project required}"

if [[ "$MODE" == "auto-review" ]]; then
    COUNT=$(increment_review_count "$SLUG" "pr")
    if [[ "$COUNT" -gt "$REVIEW_LIMIT" ]]; then
        log_event "review-limit-reached:pr" "$SLUG"
        # pr-monitor was spawned at pr-ready and is still running — no spawn needed here.
        forward_to_spokesman "$SLUG" "event:review-limit-reached:pr:${PR_URL}"
        exit 0
    fi
    log_event "reviewer-spawning" "$SLUG"
    $NOTECOVE task change "$SLUG" --state 'In Review'
    bash "${SCRIPTS}/spawn-agent.sh" workers "pr-rev-${SLUG}" /pr-reviewer "$SLUG" "$PROJECT"
    log_event "reviewer-spawned" "$SLUG"
    touch "${SIGNALS}/${SLUG}.review-start"
else
    forward_to_spokesman "$SLUG" "event:pr-submitted:${PR_URL}"
fi
