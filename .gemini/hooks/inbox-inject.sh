#!/bin/bash
# inbox-inject.sh — Gemini BeforeAgent hook: inject inbox notification
# Checks .urc/inbox/{PANE}.signal (O(1) stat). If present, queries SQLite
# for unread count and outputs additionalContext in the hook JSON response.
# stdout MUST be clean JSON — no debug output.

PANE="${TMUX_PANE:-%unknown}"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SIGNAL_FILE="$PROJECT_DIR/.urc/inbox/${PANE}.signal"

# Consume stdin (required by hook protocol)
cat >/dev/null

# Fast path: no signal = no messages
if [ ! -f "$SIGNAL_FILE" ]; then
    echo '{"continue":true}'
    exit 0
fi

DB="$PROJECT_DIR/.urc/coordination.db"
if [ ! -f "$DB" ]; then
    echo '{"continue":true}'
    exit 0
fi

# Validate PANE format
if ! printf '%s' "$PANE" | grep -qE '^%[0-9]+$'; then
    echo '{"continue":true}'
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

if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then
    echo '{"continue":true}'
    exit 0
fi

MSG="INBOX: You have $COUNT unread message(s) from $SENDER. Use receive_messages MCP tool to read them."

jq -n --arg msg "$MSG" '{
    continue: true,
    additionalContext: $msg
}' 2>/dev/null || echo '{"continue":true}'
exit 0
