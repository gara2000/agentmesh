#!/usr/bin/env bash
# pr-review-complete.sh <slug> <resume_sig> <mode>
# Handles event:pr-review-complete.
#   auto-review: pass review back to worker, kill pr-reviewer window.
#                pr-monitor keeps running until the task is closed.
#   standard:    forward to Spokesman.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
RESUME_SIG="${2:?resume_sig required}"
MODE="${3:?mode required}"

if [[ "$MODE" == "auto-review" ]]; then
    log_event "pr-review-passed-to-worker" "$SLUG"
    $NOTECOVE task comments add "$SLUG" --user "Orchestrator" \
        "PR review complete (auto-review mode). Read the reviewer's comment and the GitHub PR comments. Apply any needed fixes and re-signal when ready."
    $NOTECOVE task change "$SLUG" --state Doing
    tmux wait-for -S "$RESUME_SIG"
    tmux kill-window -t "workers:pr-rev-${SLUG}" 2>/dev/null || true
    rm -f "${SIGNALS}/${SLUG}.review-start"
else
    forward_to_spokesman "$SLUG" "event:pr-review-complete"
fi
