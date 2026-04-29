#!/usr/bin/env bash
# setup.sh — First-time machine setup for AgentMesh
#
# Registers the agentmesh plugin marketplace and installs the agentic-workflows
# plugin. Safe to run multiple times (idempotent).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGINS_PATH="${REPO_ROOT}/plugins"

# ── Marketplace registration ──────────────────────────────────────────────────

if claude plugin marketplace list 2>&1 | grep -qE '^\s+❯\s+agentmesh\b'; then
  echo "agentmesh marketplace already registered — skipping"
else
  echo "Registering agentmesh marketplace from ${PLUGINS_PATH} ..."
  claude plugin marketplace add "$PLUGINS_PATH"
  echo "agentmesh marketplace registered"
fi

# ── Plugin installation ───────────────────────────────────────────────────────

if claude plugin list 2>&1 | grep -qE '^\s+❯\s+agentic-workflows@agentmesh\b'; then
  echo "agentic-workflows@agentmesh already installed — skipping"
else
  echo "Installing agentic-workflows@agentmesh ..."
  claude plugin install agentic-workflows@agentmesh
  echo "agentic-workflows@agentmesh installed"
fi

echo ""
echo "Setup complete. You can now run the orchestrator:"
echo "  cd ${REPO_ROOT} && tmux new-session -s orchestrator && claude"
