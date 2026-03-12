#!/bin/bash
# inbox-check.sh — Unified inbox notification for ALL CLIs (Claude + Gemini + Codex)
# Called by hook configs in .claude/settings.json, .gemini/settings.json, .codex/hooks.json
#
# CLI detection: explicit arg > env var > default
#   Claude:  bash inbox-check.sh          ($CLAUDE_PROJECT_DIR auto-detected)
#   Gemini:  bash inbox-check.sh gemini  (explicit arg from .gemini/settings.json)
#   Codex:   bash inbox-check.sh codex   (explicit arg from .codex/hooks.json)

CLI_ARG="${1:-}"
PANE="${TMUX_PANE:-%unknown}"

# Detect project root (Claude provides $CLAUDE_PROJECT_DIR, Gemini/Codex use dirname)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Consume stdin (required by hook protocol, NOT used for CLI detection)
cat >/dev/null

# CLI detection: explicit arg > env var > default
if [ "$CLI_ARG" = "codex" ]; then
    HOOK_FORMAT="codex"
elif [ "$CLI_ARG" = "gemini" ]; then
    HOOK_FORMAT="gemini"
elif [ -n "$CLAUDE_PROJECT_DIR" ]; then
    HOOK_FORMAT="claude"
else
    HOOK_FORMAT="gemini"
fi

# --- MCP health check (Gemini only — no auto-reconnect) ---
MCP_WARNING=""
if [ "$HOOK_FORMAT" = "gemini" ]; then
    MCP_PID_FILE="$PROJECT_DIR/.urc/pids/server_${PANE}.pid"
    if [ -f "$MCP_PID_FILE" ]; then
        EXPECTED_PID=$(cat "$MCP_PID_FILE" 2>/dev/null)
        if [ -n "$EXPECTED_PID" ] && ! kill -0 "$EXPECTED_PID" 2>/dev/null; then
            MCP_WARNING="WARNING: URC MCP server (PID $EXPECTED_PID) is no longer running. Run /mcp refresh."
        fi
    fi
fi

# --- Inbox signal check ---
SIGNAL_FILE="$PROJECT_DIR/.urc/inbox/${PANE}.signal"
if [ ! -f "$SIGNAL_FILE" ] && [ -z "$MCP_WARNING" ]; then
    # Nothing to report — exit with CLI-appropriate empty response
    case "$HOOK_FORMAT" in
        gemini|codex) echo '{"continue":true}' ;;
    esac
    exit 0
fi

# Validate PANE format
printf '%s' "$PANE" | grep -qE '^%[0-9]+$' || {
    case "$HOOK_FORMAT" in
        gemini|codex) echo '{"continue":true}' ;;
    esac
    exit 0
}

# Query SQLite for unread count
MSG=""
DB="$PROJECT_DIR/.urc/coordination.db"
if [ -f "$DB" ] && [ -f "$SIGNAL_FILE" ]; then
    COUNT=$(sqlite3 "$DB" "
        PRAGMA busy_timeout=3000;
        SELECT COUNT(*) FROM (
            SELECT id FROM messages WHERE to_pane = '$PANE' AND read = 0
            UNION ALL
            SELECT m.id FROM messages m
            WHERE m.to_pane IS NULL
            AND NOT EXISTS (
                SELECT 1 FROM message_reads r
                WHERE r.message_id = m.id AND r.pane_id = '$PANE'
            )
        );
    " 2>/dev/null | tail -1)

    SENDER=$(sqlite3 "$DB" "
        PRAGMA busy_timeout=3000;
        SELECT from_pane FROM (
            SELECT id, from_pane FROM messages WHERE to_pane = '$PANE' AND read = 0
            UNION ALL
            SELECT m.id, m.from_pane FROM messages m
            WHERE m.to_pane IS NULL
            AND NOT EXISTS (
                SELECT 1 FROM message_reads r
                WHERE r.message_id = m.id AND r.pane_id = '$PANE'
            )
        ) ORDER BY id DESC LIMIT 1;
    " 2>/dev/null | tail -1)

    if [ -n "$COUNT" ] && [ "$COUNT" != "0" ]; then
        case "$HOOK_FORMAT" in
            claude)  MSG="INBOX: You have $COUNT unread message(s) from $SENDER. Call receive_messages(\"$PANE\") to read them." ;;
            gemini)  MSG="INBOX: You have $COUNT unread message(s) from $SENDER. Use receive_messages MCP tool to read them." ;;
            codex)   MSG="INBOX: $COUNT unread message(s) from $SENDER. Call receive_messages() MCP tool to read them before finishing." ;;
        esac
    fi
fi

# Combine MCP warning + inbox notification
COMBINED=""
[ -n "$MCP_WARNING" ] && COMBINED="$MCP_WARNING"
if [ -n "$MSG" ]; then
    [ -n "$COMBINED" ] && COMBINED="$COMBINED\n$MSG" || COMBINED="$MSG"
fi

[ -z "$COMBINED" ] && {
    case "$HOOK_FORMAT" in
        gemini|codex) echo '{"continue":true}' ;;
    esac
    exit 0
}

# Output in CLI-appropriate format
case "$HOOK_FORMAT" in
    claude)
        jq -n --arg msg "$COMBINED" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$msg}}'
        ;;
    gemini)
        jq -n --arg msg "$COMBINED" '{"continue":true,"additionalContext":$msg}' 2>/dev/null || echo '{"continue":true}'
        ;;
    codex)
        # Codex Stop hook: "block" prevents turn finalization — model MUST address inbox
        # Built-in guard: "Stop hook blocked twice in same turn; ignoring second block"
        jq -n --arg msg "$COMBINED" '{"decision":"block","reason":$msg}' 2>/dev/null || echo '{"continue":true}'
        ;;
esac
exit 0
