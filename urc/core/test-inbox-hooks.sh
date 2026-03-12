#!/usr/bin/env bash
# test-inbox-hooks.sh — tests for unified hooks/scripts/inbox-check.sh
# Replaces separate tests for inbox-piggyback.sh, inbox-inject.sh, codex-inbox-test.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

INBOX_CHECK="$PROJECT_ROOT/hooks/scripts/inbox-check.sh"
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

# ============================================================
# Claude format tests (CLAUDE_PROJECT_DIR set, no CLI arg)
# ============================================================

echo "=== Test 1: Claude — additionalContext when signal exists ==="
_clean
sqlite3 "$DB" "INSERT INTO messages (from_pane, to_pane, body, read) VALUES ('$TEST_SENDER', '$TEST_PANE', 'piggyback test msg', 0);"
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "$INBOX_CHECK" 2>/dev/null || true)
HAS_CONTEXT=$(echo "$RESULT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "additionalContext present" test "$HAS_CONTEXT" = "yes"
CONTEXT_TEXT=$(echo "$RESULT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
HAS_INBOX=$(echo "$CONTEXT_TEXT" | grep -q "INBOX" && echo "yes" || echo "no")
_check "Context mentions INBOX" test "$HAS_INBOX" = "yes"
HAS_SENDER=$(echo "$CONTEXT_TEXT" | grep -q "$TEST_SENDER" && echo "yes" || echo "no")
_check "Context mentions sender pane" test "$HAS_SENDER" = "yes"
_clean

echo ""
echo "=== Test 2: Claude — no output when no signal ==="
_clean
sqlite3 "$DB" "INSERT INTO messages (from_pane, to_pane, body, read) VALUES ('$TEST_SENDER', '$TEST_PANE', 'no-signal test', 0);"
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "$INBOX_CHECK" 2>/dev/null || true)
_check "No output when no signal file" test -z "$RESULT"
_clean

echo ""
echo "=== Test 3: Claude — no output when no messages ==="
_clean
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "$INBOX_CHECK" 2>/dev/null || true)
_check "No output when no unread messages" test -z "$RESULT"
_clean

# ============================================================
# Gemini format tests (no CLAUDE_PROJECT_DIR, no CLI arg)
# ============================================================

echo ""
echo "=== Test 4: Gemini — broadcast dedup ==="
_clean
sqlite3 "$DB" "INSERT INTO messages (from_pane, to_pane, body, read) VALUES ('$TEST_SENDER', NULL, 'broadcast test', 0);"
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
# Gemini: pass "gemini" as explicit arg (matches .gemini/settings.json config)
RESULT1=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="" bash "$INBOX_CHECK" gemini 2>/dev/null || true)
HAS_CONTEXT1=$(echo "$RESULT1" | jq -e '.additionalContext' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Broadcast visible on first call" test "$HAS_CONTEXT1" = "yes"

# Mark broadcast as read for this pane
MSG_ID=$(sqlite3 "$DB" "SELECT id FROM messages WHERE from_pane='$TEST_SENDER' AND to_pane IS NULL LIMIT 1;" 2>/dev/null)
if [ -n "$MSG_ID" ]; then
    sqlite3 "$DB" "INSERT INTO message_reads (message_id, pane_id) VALUES ($MSG_ID, '$TEST_PANE');" 2>/dev/null
fi

# Second call — broadcast should be deduped (count=0)
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
RESULT2=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="" bash "$INBOX_CHECK" gemini 2>/dev/null || true)
HAS_CONTEXT2=$(echo "$RESULT2" | jq -e '.additionalContext' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Broadcast deduped after marking read" test "$HAS_CONTEXT2" = "no"
_clean

echo ""
echo "=== Test 5: Gemini — continue:true always present ==="
_clean
# No messages, no signal — should still return continue:true
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="" bash "$INBOX_CHECK" gemini 2>/dev/null || true)
CONTINUE=$(echo "$RESULT" | jq -r '.continue' 2>/dev/null)
_check "continue:true when no messages" test "$CONTINUE" = "true"
_clean

# ============================================================
# Codex format tests (pass 'codex' as $1)
# ============================================================

echo ""
echo "=== Test 6: Codex — decision:block when inbox has messages ==="
_clean
sqlite3 "$DB" "INSERT INTO messages (from_pane, to_pane, body, read) VALUES ('$TEST_SENDER', '$TEST_PANE', 'codex inbox test', 0);"
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="" bash "$INBOX_CHECK" codex 2>/dev/null || true)
DECISION=$(echo "$RESULT" | jq -r '.decision' 2>/dev/null)
_check "decision is block" test "$DECISION" = "block"
REASON=$(echo "$RESULT" | jq -r '.reason' 2>/dev/null)
HAS_INBOX=$(echo "$REASON" | grep -q "INBOX" && echo "yes" || echo "no")
_check "reason mentions INBOX" test "$HAS_INBOX" = "yes"
HAS_SENDER=$(echo "$REASON" | grep -q "$TEST_SENDER" && echo "yes" || echo "no")
_check "reason mentions sender pane" test "$HAS_SENDER" = "yes"
_clean

echo ""
echo "=== Test 7: Codex — continue:true when no messages ==="
_clean
# No signal, no messages — should return continue:true
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="" bash "$INBOX_CHECK" codex 2>/dev/null || true)
CONTINUE=$(echo "$RESULT" | jq -r '.continue' 2>/dev/null)
_check "continue:true when no messages" test "$CONTINUE" = "true"
_clean

echo ""
echo "=== Test 8: Codex — broadcast message detection ==="
_clean
# Broadcast (to_pane IS NULL) should be picked up via UNION ALL query
sqlite3 "$DB" "INSERT INTO messages (from_pane, to_pane, body, read) VALUES ('$TEST_SENDER', NULL, 'codex broadcast test', 0);"
touch "$PROJECT_ROOT/.urc/inbox/${TEST_PANE}.signal"
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="" bash "$INBOX_CHECK" codex 2>/dev/null || true)
DECISION=$(echo "$RESULT" | jq -r '.decision' 2>/dev/null)
_check "Broadcast triggers block" test "$DECISION" = "block"
REASON=$(echo "$RESULT" | jq -r '.reason' 2>/dev/null)
HAS_SENDER=$(echo "$REASON" | grep -q "$TEST_SENDER" && echo "yes" || echo "no")
_check "Broadcast reason mentions sender" test "$HAS_SENDER" = "yes"
_clean

echo ""
echo "=== Test 9: Codex — MCP health check does NOT fire ==="
_clean
# Create a fake PID file pointing to a dead process
mkdir -p "$PROJECT_ROOT/.urc/pids"
echo "99999" > "$PROJECT_ROOT/.urc/pids/server_${TEST_PANE}.pid"
# No messages, no signal — Codex should NOT get MCP warning (Gemini-only feature)
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="" bash "$INBOX_CHECK" codex 2>/dev/null || true)
CONTINUE=$(echo "$RESULT" | jq -r '.continue' 2>/dev/null)
_check "Codex ignores dead MCP PID" test "$CONTINUE" = "true"
# Verify no MCP warning text leaked through
HAS_MCP=$(echo "$RESULT" | grep -q "MCP" && echo "yes" || echo "no")
_check "No MCP warning in Codex output" test "$HAS_MCP" = "no"
rm -f "$PROJECT_ROOT/.urc/pids/server_${TEST_PANE}.pid"
_clean

echo ""
echo "=== Test 10: Gemini — MCP health check fires for dead PID ==="
_clean
# Create a fake PID file pointing to a dead process
mkdir -p "$PROJECT_ROOT/.urc/pids"
echo "99999" > "$PROJECT_ROOT/.urc/pids/server_${TEST_PANE}.pid"
# No messages, no signal — Gemini SHOULD get MCP warning
RESULT=$(echo '{}' | TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="" bash "$INBOX_CHECK" gemini 2>/dev/null || true)
HAS_MCP=$(echo "$RESULT" | jq -r '.additionalContext' 2>/dev/null | grep -q "MCP" && echo "yes" || echo "no")
_check "Gemini gets MCP dead-process warning" test "$HAS_MCP" = "yes"
rm -f "$PROJECT_ROOT/.urc/pids/server_${TEST_PANE}.pid"
_clean

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
