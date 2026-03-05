#!/bin/bash
# inbox-piggyback.sh — PostToolUse hook: inject inbox notification into LLM context
# O(1) stat check on signal file. If present, queries SQLite for unread count.
# Signal file written by send_with_notify MCP tool.

PANE="${TMUX_PANE:-%unknown}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SIGNAL_FILE="$PROJECT_DIR/.urc/inbox/${PANE}.signal"

# Fast path: no signal file = no unread messages. Exit before reading stdin.
[ -f "$SIGNAL_FILE" ] || exit 0

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
    SELECT COUNT(*) FROM messages
    WHERE (to_pane = '$PANE' OR to_pane IS NULL) AND read = 0;
" 2>/dev/null)

SENDER=$(sqlite3 "$DB" "
    SELECT from_pane FROM messages
    WHERE (to_pane = '$PANE' OR to_pane IS NULL) AND read = 0
    ORDER BY id DESC LIMIT 1;
" 2>/dev/null)

[ -z "$COUNT" ] || [ "$COUNT" = "0" ] && exit 0

MSG="INBOX: You have $COUNT unread message(s) from $SENDER. Call receive_messages(\"$PANE\") to read them."

jq -n --arg msg "$MSG" '{
    hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContextForAssistant: $msg
    }
}'
exit 0
