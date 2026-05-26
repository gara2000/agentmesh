#!/usr/bin/env bash
# research-ready.sh <slug>
# Handles event:research-ready (investigator): forwards to Spokesman for user approval.
# The investigator blocks until the user approves (done) or provides feedback (doing).
# Caller is responsible for calling pick_up_ready_tasks() after this script returns.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"

log_event "research-ready-forwarded" "$SLUG"
forward_to_spokesman "$SLUG" "event:research-ready"
