#!/usr/bin/env bash
# plugin-setup.sh — Auto-setup for URC plugin installs.
# Runs on SessionStart to ensure venv and dependencies exist.
# Idempotent — safe to run every session.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Prevent concurrent pip installs (multiple SessionStart hooks)
mkdir -p "$PLUGIN_ROOT/.urc/locks" 2>/dev/null || true
LOCK_DIR="$PLUGIN_ROOT/.urc/locks/pip-install"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another pip install in progress, skipping" >&2
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

VENV_DIR="$PLUGIN_ROOT/.venv"

# Skip if venv already exists and has dependencies
if [[ -x "$VENV_DIR/bin/python3" ]] && "$VENV_DIR/bin/python3" -c "import mcp, yaml" 2>/dev/null; then
  exit 0
fi

# Create venv if missing
if [[ ! -d "$VENV_DIR" ]]; then
  if ! python3 -m venv "$VENV_DIR" 2>/dev/null; then
    echo "URC: Failed to create venv — MCP servers will not start" >&2
    exit 0
  fi
fi

# Install dependencies from requirements.txt
if [[ -f "$PLUGIN_ROOT/requirements.txt" ]]; then
  "$VENV_DIR/bin/pip" install --quiet -r "$PLUGIN_ROOT/requirements.txt"
else
  "$VENV_DIR/bin/pip" install --quiet mcp==1.26.0 PyYAML==6.0.3 anyio==4.12.1
fi

# Create signal directories
mkdir -p "$PLUGIN_ROOT/.urc/signals"

exit 0
