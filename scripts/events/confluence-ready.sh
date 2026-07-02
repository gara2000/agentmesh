#!/usr/bin/env bash
# confluence-ready.sh <slug> <confluence_url>
# Handles event:confluence-ready:<url> — documenter signals Confluence docs are ready for user review.
# No PR monitor needed — Confluence pages are published directly (no GitHub PR).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLUG="${1:?slug required}"
CONFLUENCE_URL="${2:?confluence_url required}"

log_event "confluence-ready" "$SLUG"
forward_to_spokesman "$SLUG" "event:confluence-submitted:${CONFLUENCE_URL}"
