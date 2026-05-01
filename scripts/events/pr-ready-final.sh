#!/usr/bin/env bash
# pr-ready-final.sh <slug> <pr_url>
# Handles event:pr-ready-final:<url> — worker signals the PR is ready for user approval.
# Used after addressing auto-reviewer feedback (no further review cycle wanted) or
# after addressing user feedback (show to user again, no re-review needed).
#
# pr-monitor was killed by pr-review-complete.sh before the worker re-signaled, so
# a fresh monitor is spawned here.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
PR_URL="${2:?pr_url required}"

# Spawn pr-monitor (previous one was killed by pr-review-complete.sh).
spawn_pr_monitor "$SLUG" "$PR_URL"
# Forward to Spokesman for final user approval using the standard pr-ready event.
forward_to_spokesman "$SLUG" "event:pr-ready:${PR_URL}"
