#!/usr/bin/env bash
# crash-limit.sh <slug> <project>
# Handles event:crash-limit-reached: cleans up task state and escalates to Spokesman.
# The task is already set to Blocked by watchdog.sh before this event fires.
# Does NOT re-spawn the worker — manual user intervention is required.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
PROJECT="${2:?project required}"

log_event "crash-limit-reached" "$SLUG"
tmux kill-window -t "orchestrator:pr-mon-${SLUG}" 2>/dev/null || true
rm -f "${SIGNALS}/${SLUG}.merged" "${SIGNALS}/${SLUG}.reviewed" "${SIGNALS}/${SLUG}.review-start"
rm -f "${SIGNALS}/${SLUG}.plan-review-count" "${SIGNALS}/${SLUG}.pr-review-count"
rm -f "${SIGNALS}/${SLUG}.crash-count"
forward_to_spokesman "$SLUG" "event:crash-limit-reached"
