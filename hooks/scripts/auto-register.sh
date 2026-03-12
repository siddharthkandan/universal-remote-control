#!/bin/bash
# auto-register.sh — Register agent in URC coordination DB on session start
# Called by SessionStart hook (Claude, Gemini, Codex)
# CLI detection: explicit arg > env var > default
#   Codex passes "codex" as $1 from .codex/hooks.json
#   Gemini passes "gemini" as $1 from .gemini/settings.json

PANE_ID="$TMUX_PANE"
[ -z "$PANE_ID" ] && exit 0  # Not in tmux, skip silently

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
VENV_PYTHON="$PROJECT_DIR/.venv/bin/python3"

# Consume stdin (required by hook protocol)
cat >/dev/null

# CLI detection: explicit arg > env var > default
CLI_ARG="${1:-}"
CLI_TYPE="unknown"
if [ "$CLI_ARG" = "codex" ]; then
    CLI_TYPE="codex"
elif [ "$CLI_ARG" = "gemini" ]; then
    CLI_TYPE="gemini"
elif [ -n "$CLAUDE_PROJECT_DIR" ]; then
    CLI_TYPE="claude"
else
    CLI_TYPE="gemini"
fi

# Register via direct DB write (MCP may not be connected at SessionStart)
# Uses env vars instead of shell interpolation in Python (safer, consistent with resolve-file-refs.sh)
URC_PROJECT_DIR="$PROJECT_DIR" URC_PANE="$PANE_ID" URC_CLI="$CLI_TYPE" "$VENV_PYTHON" -c "
import os, sys
project_dir = os.environ['URC_PROJECT_DIR']
pane_id = os.environ['URC_PANE']
cli_type = os.environ['URC_CLI']
sys.path.insert(0, project_dir)
from urc.core.db import get_connection, init_schema, register_agent
conn = get_connection()
init_schema(conn)
register_agent(conn, pane_id, cli_type, 'worker', source='urc')
" 2>/dev/null || true

# Set @urc_cli tmux pane option (used by cli-adapter.sh Strategy 0 — fast path)
tmux set-option -p -t "$PANE_ID" @urc_cli "$CLI_TYPE" 2>/dev/null || true

# For Claude: persist pane ID in env file for downstream hooks
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "URC_PANE_ID=$PANE_ID" >> "$CLAUDE_ENV_FILE"
fi

exit 0
