#!/usr/bin/env bash
# lib.sh — shared utilities for orchestrator event handler scripts
# Source this file at the top of each handler:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTMESH=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SIGNALS="${AGENTMESH}/signals"
SCRIPTS="${AGENTMESH}/scripts"
LOG="${SIGNALS}/events.log"
NOTECOVE="node /Applications/NoteCove.app/Contents/Resources/cli/cli.cjs"

log_event() {
    local event_type="${1:?event_type required}" slug="${2:--}"
    printf '%s\torchestrator \t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event_type" "$slug" >> "$LOG"
}

forward_to_spokesman() {
    local slug="${1:?slug required}" event_type="${2:?event_type required}"
    log_event "forwarding-to-spokesman:${event_type}" "$slug"
    printf '%s:%s\n' "$slug" "$event_type" >> "${SIGNALS}/spokesman-queue"
    tmux wait-for -S spokesman-event
}

get_review_count() {
    local slug="${1:?slug required}" type="${2:?type required}"
    local f="${SIGNALS}/${slug}.${type}-review-count"
    [ -f "$f" ] && cat "$f" || echo 0
}

increment_review_count() {
    local slug="${1:?slug required}" type="${2:?type required}"
    local f="${SIGNALS}/${slug}.${type}-review-count"
    local count
    count=$(( $(get_review_count "$slug" "$type") + 1 ))
    echo "$count" > "$f"
    echo "$count"
}

spawn_pr_monitor() {
    local slug="${1:?slug required}" pr_url="${2:?pr_url required}"
    tmux new-window -t orchestrator -n "pr-mon-${slug}" 2>/dev/null || true
    tmux send-keys -t "orchestrator:pr-mon-${slug}" "bash ${SCRIPTS}/pr-monitor.sh ${slug} ${pr_url}" Enter
    log_event "pr-monitor-spawned" "$slug"
}
