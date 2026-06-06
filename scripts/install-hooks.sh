#!/usr/bin/env bash
# install-hooks.sh — Install git hooks for AgentMesh
#
# Installs scripts/pre-commit into .git/hooks/pre-commit as a symlink.
# Safe to run multiple times (idempotent).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SOURCE="${REPO_ROOT}/scripts/pre-commit"
HOOK_DEST="${REPO_ROOT}/.git/hooks/pre-commit"

chmod +x "$HOOK_SOURCE"

if [ -L "$HOOK_DEST" ] && [ "$(readlink "$HOOK_DEST")" = "$HOOK_SOURCE" ]; then
    echo "pre-commit hook already installed — skipping"
else
    ln -sf "$HOOK_SOURCE" "$HOOK_DEST"
    echo "pre-commit hook installed: .git/hooks/pre-commit → scripts/pre-commit"
fi
