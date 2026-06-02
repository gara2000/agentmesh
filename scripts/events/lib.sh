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

forward_to_interfaces() {
    local slug="${1:?slug required}" event_type="${2:?event_type required}"
    local ifaces_file="${SIGNALS}/active-interfaces"
    local interfaces=()
    if [[ -f "$ifaces_file" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && interfaces+=("$line")
        done < "$ifaces_file"
    fi
    [[ ${#interfaces[@]} -eq 0 ]] && interfaces=("spokesman")
    log_event "forwarding-to-interfaces:$(IFS=,; echo "${interfaces[*]}"):${event_type}" "$slug"
    for iface in "${interfaces[@]}"; do
        printf '%s:%s\n' "$slug" "$event_type" >> "${SIGNALS}/${iface}-queue"
        tmux wait-for -S "${iface}-event"
    done
}

forward_to_spokesman() {
    local slug="${1:?slug required}" event_type="${2:?event_type required}"
    forward_to_interfaces "$slug" "$event_type"
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
