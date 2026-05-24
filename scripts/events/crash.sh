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
# Re-spawn using the original agent type recorded in the workers registry (3rd field).
# Fall back to implementer if the entry is missing or has no type field.
# Read BEFORE task-done.sh, which removes the entry from signals/workers.
_agent_type=$(grep "^${SLUG} " "${SIGNALS}/workers" 2>/dev/null | awk '{print $3}' | head -1)
_agent_type=${_agent_type:-implementer}
bash "${SCRIPTS}/task-done.sh" "$SLUG" "$PROJECT"
$NOTECOVE task change "$SLUG" --state Doing
bash "${SCRIPTS}/spawn-agent.sh" workers "$SLUG" "/${_agent_type}" "$SLUG" "$PROJECT"
echo "${SLUG} ${SLUG} ${_agent_type}" >> "${SIGNALS}/workers"
