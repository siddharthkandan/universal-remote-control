#!/bin/bash
# auto-deregister.sh — Deregister agent from URC coordination DB on session end
# Cleans up signal/response/inbox files for this pane.

PANE_ID="$TMUX_PANE"
[ -z "$PANE_ID" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
VENV_PYTHON="$PROJECT_DIR/.venv/bin/python3"

# Consume stdin
cat >/dev/null

# Deregister via direct DB write
# Uses env vars instead of shell interpolation in Python (safer, consistent with resolve-file-refs.sh)
URC_PROJECT_DIR="$PROJECT_DIR" URC_PANE="$PANE_ID" "$VENV_PYTHON" -c "
import os, sys
project_dir = os.environ['URC_PROJECT_DIR']
pane_id = os.environ['URC_PANE']
sys.path.insert(0, project_dir)
from urc.core.db import get_connection, deregister_agent
conn = get_connection()
deregister_agent(conn, pane_id)
" 2>/dev/null || true

# Clean up ALL ephemeral files for this pane
rm -f "$PROJECT_DIR/.urc/signals/done_${PANE_ID}" 2>/dev/null
rm -f "$PROJECT_DIR/.urc/signals/cancel_${PANE_ID}" 2>/dev/null
rm -f "$PROJECT_DIR/.urc/responses/${PANE_ID}.json" 2>/dev/null
rm -f "$PROJECT_DIR/.urc/streams/${PANE_ID}.jsonl" 2>/dev/null
rm -f "$PROJECT_DIR/.urc/inbox/${PANE_ID}.signal" 2>/dev/null
rm -f "$PROJECT_DIR/.urc/seq/${PANE_ID}" 2>/dev/null
rm -f "$PROJECT_DIR/.urc/dispatches/${PANE_ID}.json" 2>/dev/null
rm -f "$PROJECT_DIR/.urc/circuits/${PANE_ID}" 2>/dev/null
rm -f "$PROJECT_DIR/.urc/pids/server_${PANE_ID}.pid" 2>/dev/null
rm -f "$PROJECT_DIR/.urc/pids/${PANE_ID}" 2>/dev/null
# Clean dispatch lock dirs containing this pane ID
find "$PROJECT_DIR/.urc" -maxdepth 1 -name "dispatch_*.d" -type d 2>/dev/null | while read lockdir; do
    [ -f "$lockdir/pane" ] && grep -q "${PANE_ID}" "$lockdir/pane" 2>/dev/null && rm -rf "$lockdir"
done

exit 0
