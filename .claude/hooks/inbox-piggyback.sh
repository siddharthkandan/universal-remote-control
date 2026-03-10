#!/bin/bash
# inbox-piggyback.sh — PostToolUse hook: inject inbox notification into LLM context
# O(1) stat check on signal file. If present, queries SQLite for unread count.
# Signal file written by send_message MCP tool (with notify=true).

PANE="${TMUX_PANE:-%unknown}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SIGNAL_FILE="$PROJECT_DIR/.urc/inbox/${PANE}.signal"

# Fast path: no signal file = no unread messages. Drain stdin to avoid EPIPE.
[ -f "$SIGNAL_FILE" ] || { cat >/dev/null 2>&1; exit 0; }

# Signal exists — consume stdin (required by hook protocol)
cat >/dev/null

# Query SQLite for actual unread count
DB="$PROJECT_DIR/.urc/coordination.db"
[ -f "$DB" ] || exit 0

# Validate PANE format to prevent injection
if ! printf '%s' "$PANE" | grep -qE '^%[0-9]+$'; then
    exit 0
fi

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

[ -z "$COUNT" ] || [ "$COUNT" = "0" ] && exit 0

MSG="INBOX: You have $COUNT unread message(s) from $SENDER. Call receive_messages(\"$PANE\") to read them."

jq -n --arg msg "$MSG" '{
    hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $msg
    }
}'
exit 0
