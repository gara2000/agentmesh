#!/usr/bin/env bash
# crash.sh <slug> <project>
# Handles event:crash-detected: re-queues the task and spawns a fresh worker.
# Does NOT call pick_up_ready_tasks — the worker slot is immediately refilled by spawn.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
PROJECT="${2:?project required}"

log_event "worker-crash-requeued" "$SLUG"
$NOTECOVE task comments add "$SLUG" --user "Orchestrator" "Worker crashed — restarting automatically."
tmux kill-window -t "orchestrator:pr-mon-${SLUG}" 2>/dev/null || true
rm -f "${SIGNALS}/${SLUG}.merged" "${SIGNALS}/${SLUG}.reviewed" "${SIGNALS}/${SLUG}.review-start"
rm -f "${SIGNALS}/${SLUG}.plan-review-count" "${SIGNALS}/${SLUG}.pr-review-count"
bash "${SCRIPTS}/task-done.sh" "$SLUG" "$PROJECT"
$NOTECOVE task change "$SLUG" --state Doing
bash "${SCRIPTS}/spawn-agent.sh" workers "$SLUG" /worker "$SLUG" "$PROJECT"
echo "${SLUG} ${SLUG}" >> "${SIGNALS}/workers"
