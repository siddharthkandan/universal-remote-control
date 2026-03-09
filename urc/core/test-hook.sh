#!/usr/bin/env bash
# test-hook.sh — synthetic payload tests for hook.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
TEST_PANE="%99999"

_check() {
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $*"; PASS=$((PASS+1))
    else
        echo "  FAIL: $*"; FAIL=$((FAIL+1))
    fi
}

# Setup
mkdir -p "$PROJECT_ROOT/.urc/responses" "$PROJECT_ROOT/.urc/signals" "$PROJECT_ROOT/.urc/streams"

echo "=== Test 1: Claude Code Stop hook payload ==="
rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
echo '{"stop_hook_active":true,"last_assistant_message":"Hello from Claude test"}' | \
    TMUX_PANE="$TEST_PANE" bash "$HOOK" >/dev/null 2>&1
RESP=$(cat "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "Hello from Claude test"
_check test "$(echo "$RESP" | jq -r '.cli' 2>/dev/null)" = "claude"
_check test -f "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

echo ""
echo "=== Test 2: Codex notify hook payload (via \$1) ==="
TMUX_PANE="$TEST_PANE" bash "$HOOK" '{"type":"agent-turn-complete","last-assistant-message":"Hello from Codex test","thread-id":"abc","turn-id":"t1","cwd":"/tmp","input-messages":["test"]}' >/dev/null 2>&1
RESP=$(cat "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "Hello from Codex test"
_check test "$(echo "$RESP" | jq -r '.cli' 2>/dev/null)" = "codex"

rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

echo ""
echo "=== Test 3: Gemini AfterAgent hook payload ==="
STDOUT=$(echo '{"prompt":"test prompt","prompt_response":"Hello from Gemini test","stop_hook_active":false}' | \
    TMUX_PANE="$TEST_PANE" bash "$HOOK" 2>/dev/null)
echo "$STDOUT" | jq -e '.continue == true' >/dev/null 2>&1
_check test $? -eq 0
RESP=$(cat "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "Hello from Gemini test"
_check test "$(echo "$RESP" | jq -r '.cli' 2>/dev/null)" = "gemini"

rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

echo ""
echo "=== Test 3b: Claude payload WITH hook_event_name (regression) ==="
echo '{"hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"Claude with hook_event_name"}' | \
    TMUX_PANE="$TEST_PANE" bash "$HOOK" >/dev/null 2>&1
RESP=$(cat "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.cli' 2>/dev/null)" = "claude"
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "Claude with hook_event_name"

rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

echo ""
echo "=== Test 4: Response file has expected fields ==="
echo '{"last_assistant_message":"fields test"}' | \
    TMUX_PANE="$TEST_PANE" bash "$HOOK" >/dev/null 2>&1
RESP=$(cat "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.pane' 2>/dev/null)" = "$TEST_PANE"
_check test "$(echo "$RESP" | jq -r '.cli' 2>/dev/null)" = "claude"
EPOCH=$(echo "$RESP" | jq -r '.epoch' 2>/dev/null)
_check test "$EPOCH" -gt 0
LEN=$(echo "$RESP" | jq -r '.len' 2>/dev/null)
_check test "$LEN" -gt 0

rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

echo ""
echo "=== Test 5: JSONL stream written ==="
rm -f "$PROJECT_ROOT/.urc/streams/${TEST_PANE}.jsonl"
echo '{"last_assistant_message":"stream test"}' | \
    TMUX_PANE="$TEST_PANE" bash "$HOOK" >/dev/null 2>&1
_check test -f "$PROJECT_ROOT/.urc/streams/${TEST_PANE}.jsonl"
JSONL_LINE=$(tail -1 "$PROJECT_ROOT/.urc/streams/${TEST_PANE}.jsonl" 2>/dev/null)
_check test "$(echo "$JSONL_LINE" | jq -r '.response' 2>/dev/null)" = "stream test"
_check test "$(echo "$JSONL_LINE" | jq -r '.pane' 2>/dev/null)" = "$TEST_PANE"

rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}" "$PROJECT_ROOT/.urc/streams/${TEST_PANE}.jsonl"

echo ""
echo "=== Test 6: Empty input (no crash, signals still created) ==="
rm -f "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
TMUX_PANE="$TEST_PANE" bash "$HOOK" < /dev/null >/dev/null 2>&1
_check test -f "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

# Final cleanup
rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}" "$PROJECT_ROOT/.urc/streams/${TEST_PANE}.jsonl"

echo ""
echo "=== Test 7: Signal ordering invariant ==="
rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
echo '{"last_assistant_message":"signal ordering test"}' | \
    TMUX_PANE="$TEST_PANE" bash "$HOOK" >/dev/null 2>&1
_check test -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json"
_check test -f "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
RESP=$(cat "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "signal ordering test"
rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

echo ""
echo "=== Test 8: Empty response preserves signal ==="
rm -f "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
# Pre-seed a response file
echo '{"pane":"%99999","cli":"claude","epoch":1,"response":"pre-seeded","len":9}' > "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json"
# Send empty last_assistant_message
echo '{"last_assistant_message":""}' | \
    TMUX_PANE="$TEST_PANE" bash "$HOOK" >/dev/null 2>&1
# Signal should still fire
_check test -f "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
# Original response file should be preserved (empty response doesn't overwrite)
RESP=$(cat "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "pre-seeded"
rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

echo ""
echo "=== Test 9: Special characters survive pipeline ==="
rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
SPECIAL='He said "hello" & used a backslash \\ and single quote '"'"'s'
echo "{\"last_assistant_message\":$(printf '%s' "$SPECIAL" | jq -Rs .)}" | \
    TMUX_PANE="$TEST_PANE" bash "$HOOK" >/dev/null 2>&1
RESP=$(cat "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" 2>/dev/null || echo "{}")
# Verify it's valid JSON and non-empty
RESP_VAL=$(echo "$RESP" | jq -e '.response' >/dev/null 2>&1 && echo "valid" || echo "invalid")
_check test "$RESP_VAL" = "valid"
RESP_LEN=$(echo "$RESP" | jq -r '.len' 2>/dev/null)
_check test "$RESP_LEN" -gt 0
rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
