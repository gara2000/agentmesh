#!/usr/bin/env bash
# tickets-draft.sh <slug>
# Handles event:tickets-draft (ticketer): forwards to Spokesman for user confirmation.
# The ticketer blocks until the user confirms (doing) or provides feedback (doing).
# Caller is responsible for calling pick_up_ready_tasks() after this script returns.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"

log_event "tickets-draft-forwarded" "$SLUG"
forward_to_spokesman "$SLUG" "event:tickets-draft"
