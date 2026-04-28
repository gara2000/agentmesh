#!/usr/bin/env bash
# detect-agent-type.sh — print the agent type for a NoteCove task
#
# Usage:
#   detect-agent-type.sh --title "<title>" <<< "$DESCRIPTION"
#   printf '%s' "$description" | detect-agent-type.sh --title "<title>"
#
# Outputs one of: brainstormer | planner | worker
#
# Only keyword heuristics are checked. Non-keyword signals (e.g. "no clear
# acceptance criteria") are intentionally left for human/orchestrator judgement
# and are not encoded here.

set -euo pipefail

TITLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Read description from stdin (handles markdown, newlines, embedded quotes safely)
DESCRIPTION=$(cat)

# Combine title + description for matching (case-insensitive)
COMBINED=$(printf '%s\n%s' "$TITLE" "$DESCRIPTION" | tr '[:upper:]' '[:lower:]')

# 1. Brainstormer: open-ended ideation keywords
if printf '%s' "$COMBINED" | grep -qE 'brainstorm|ideate|come up with ideas|explore options|think through|ideas for|options for|what should we'; then
  echo "brainstormer"
  exit 0
fi

# 2. Planner: multi-component / decomposition keywords
if printf '%s' "$COMBINED" | grep -qE '\bmultiple\b|\bseveral\b|and also|as well as|in addition|\bvarious\b'; then
  echo "planner"
  exit 0
fi

# 3. Default: single-PR worker
echo "worker"
