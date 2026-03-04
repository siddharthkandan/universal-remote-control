#!/usr/bin/env bash
# session-start.sh — Session initialization hook
# Called by Claude Code's SessionStart hook. Receives JSON on stdin.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# CLAUDE_PROJECT_DIR is set by Claude Code to the project directory
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
    PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
fi
if [ -z "$PROJECT_DIR" ]; then
    PROJECT_DIR="."
fi

# Write PID file for process monitoring
mkdir -p "$PROJECT_DIR/.urc/pids" 2>/dev/null || true
_SAFE_PANE="${TMUX_PANE:-unknown}"
echo "$$" > "$PROJECT_DIR/.urc/pids/${_SAFE_PANE#%}.pid" 2>/dev/null || true

# Register agent via SQLite
URC_PROJECT_DIR="$PROJECT_DIR" URC_HOOK_PID="$$" python3 - <<'PY' 2>/dev/null || true
import sys, os
project_dir = os.environ.get('URC_PROJECT_DIR', '.')
hook_pid = int(os.environ.get('URC_HOOK_PID', '0'))
sys.path.insert(0, project_dir)
from urc.core.coordination_db import get_connection, init_schema, register_agent
from urc.core.jsonl_recovery import append_log
conn = get_connection(os.path.join(project_dir, '.urc', 'coordination.db'))
init_schema(conn)
pane = os.environ.get('TMUX_PANE', 'unknown')
register_agent(conn, pane, 'claude-code', 'claude', hook_pid)
append_log('register', pane, {'cli': 'claude-code', 'role': 'claude', 'pid': hook_pid})
conn.close()
PY

# Keep per-peer context-state symlink in sync with this session
if [ -n "$SESSION_ID" ]; then
    _prefix="${SESSION_ID:0:8}"
    if [ -n "$_prefix" ]; then
        _target="context-state-${_prefix}.json"
        ln -sf "$_target" "$PROJECT_DIR/.claude/context-state-claude.json" 2>/dev/null || true
        ln -sf "$_target" "$PROJECT_DIR/.claude/context-state.json" 2>/dev/null || true
    fi
fi

# Single tmux server assertion — pane IDs require single server
if command -v tmux >/dev/null 2>&1; then
    _SOCKET_COUNT=$(tmux list-sessions -F '#{socket_path}' 2>/dev/null | sort -u | wc -l | tr -d ' ')
    if [ "${_SOCKET_COUNT:-0}" -gt 1 ]; then
        echo "[FATAL] Multiple tmux sockets detected ($_SOCKET_COUNT). Pane-based identity requires single server." >&2
    fi
fi

# Check for pane-scoped handoff to consume on session start
OWN_PANE="${TMUX_PANE:-}"
if [ -n "$OWN_PANE" ] && [ -f "$PROJECT_DIR/.urc/bridge/handoffs/${OWN_PANE}.md" ]; then
    echo "## Handoff Context"
    cat "$PROJECT_DIR/.urc/bridge/handoffs/${OWN_PANE}.md"
    echo "---"
fi
