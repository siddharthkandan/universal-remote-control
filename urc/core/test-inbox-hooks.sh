#!/usr/bin/env bash
# test-inbox-hooks.sh — tests for inbox-piggyback.sh and inbox-inject.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PIGGYBACK="$PROJECT_ROOT/.claude/hooks/inbox-piggyback.sh"
INJECT="$PROJECT_ROOT/.gemini/hooks/inbox-inject.sh"
DB="$PROJECT_ROOT/.urc/coordination.db"

PASS=0; FAIL=0
TEST_PANE="%99995"
TEST_SENDER="%99994"

_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL+1))
    fi
}

_clean() {
    rm -f "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
    sqlite3 "$DB" "DELETE FROM messages WHERE from_pane='$TEST_SENDER';" 2>/dev/null || true
    sqlite3 "$DB" "DELETE FROM message_reads WHERE pane_id='$TEST_PANE';" 2>/dev/null || true
}

mkdir -p "$PROJECT_ROOT/.urc/inbox"

# Ensure DB exists
if [ ! -f "$DB" ]; then
    echo "SKIP: coordination.db not found"
    exit 0
fi

echo "=== Test 1: inbox-piggyback.sh — additionalContext when signal exists ==="
_clean
# Insert a test direct message
sqlite3 "$DB" "INSERT INTO messages (from_pane, to_pane, body, read) VALUES ('$TEST_SENDER', '$TEST_PANE', 'piggyback test msg', 0);"
# Create signal file
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
# Run piggyback hook
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "$PIGGYBACK" 2>/dev/null || true)
HAS_CONTEXT=$(echo "$RESULT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "additionalContext present" test "$HAS_CONTEXT" = "yes"
CONTEXT_TEXT=$(echo "$RESULT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
HAS_INBOX=$(echo "$CONTEXT_TEXT" | grep -q "INBOX" && echo "yes" || echo "no")
_check "Context mentions INBOX" test "$HAS_INBOX" = "yes"
HAS_SENDER=$(echo "$CONTEXT_TEXT" | grep -q "$TEST_SENDER" && echo "yes" || echo "no")
_check "Context mentions sender pane" test "$HAS_SENDER" = "yes"
_clean

echo ""
echo "=== Test 2: inbox-piggyback.sh — no output when no signal ==="
_clean
# Insert a message but NO signal file
sqlite3 "$DB" "INSERT INTO messages (from_pane, to_pane, body, read) VALUES ('$TEST_SENDER', '$TEST_PANE', 'no-signal test', 0);"
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "$PIGGYBACK" 2>/dev/null || true)
_check "No output when no signal file" test -z "$RESULT"
_clean

echo ""
echo "=== Test 3: inbox-piggyback.sh — no output when no messages ==="
_clean
# Signal file exists but no messages
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "$PIGGYBACK" 2>/dev/null || true)
_check "No output when no unread messages" test -z "$RESULT"
_clean

echo ""
echo "=== Test 4: inbox-inject.sh — broadcast dedup ==="
_clean
# Insert a broadcast message (to_pane IS NULL)
sqlite3 "$DB" "INSERT INTO messages (from_pane, to_pane, body, read) VALUES ('$TEST_SENDER', NULL, 'broadcast test', 0);"
# Create signal file
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
# First call — should see the broadcast
RESULT1=$(echo '{}' | TMUX_PANE="$TEST_PANE" bash "$INJECT" 2>/dev/null || true)
HAS_CONTEXT1=$(echo "$RESULT1" | jq -e '.additionalContext' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Broadcast visible on first call" test "$HAS_CONTEXT1" = "yes"

# Mark broadcast as read for this pane
MSG_ID=$(sqlite3 "$DB" "SELECT id FROM messages WHERE from_pane='$TEST_SENDER' AND to_pane IS NULL LIMIT 1;" 2>/dev/null)
if [ -n "$MSG_ID" ]; then
    sqlite3 "$DB" "INSERT INTO message_reads (message_id, pane_id) VALUES ($MSG_ID, '$TEST_PANE');" 2>/dev/null
fi

# Second call — broadcast should be deduped (count=0)
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
RESULT2=$(echo '{}' | TMUX_PANE="$TEST_PANE" bash "$INJECT" 2>/dev/null || true)
HAS_CONTEXT2=$(echo "$RESULT2" | jq -e '.additionalContext' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Broadcast deduped after marking read" test "$HAS_CONTEXT2" = "no"
_clean

echo ""
echo "=== Test 5: inbox-inject.sh — continue:true always present ==="
_clean
# No messages, no signal — should still return continue:true
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" bash "$INJECT" 2>/dev/null || true)
CONTINUE=$(echo "$RESULT" | jq -r '.continue' 2>/dev/null)
_check "continue:true when no messages" test "$CONTINUE" = "true"
_clean

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
