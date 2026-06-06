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

# ── Git hooks ─────────────────────────────────────────────────────────────────

echo "Installing git hooks ..."
bash "${REPO_ROOT}/scripts/install-hooks.sh"

# ── agentmesh CLI symlink ─────────────────────────────────────────────────────

mkdir -p ~/bin
if [ -L ~/bin/agentmesh ] && [ "$(readlink ~/bin/agentmesh)" = "${REPO_ROOT}/scripts/agentmesh.sh" ]; then
  echo "agentmesh CLI symlink already up to date — skipping"
else
  ln -sf "${REPO_ROOT}/scripts/agentmesh.sh" ~/bin/agentmesh
  echo "agentmesh CLI symlinked to ~/bin/agentmesh"
fi

echo ""
echo "Setup complete. Start the system with:"
echo "  agentmesh start --project WORK"
