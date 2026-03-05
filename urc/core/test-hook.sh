#!/usr/bin/env bash
# test-hook.sh — synthetic payload tests for turn-complete-hook.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/turn-complete-hook.sh"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0

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
rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"
echo '{"stop_hook_active":true,"last_assistant_message":"Hello from Claude test"}' | \
    TMUX_PANE="%test99" bash "$HOOK" >/dev/null 2>&1
RESP=$(cat "$PROJECT_ROOT/.urc/responses/%test99.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "Hello from Claude test"
_check test "$(echo "$RESP" | jq -r '.cli' 2>/dev/null)" = "claude"
_check test -f "$PROJECT_ROOT/.urc/signals/done_%test99"

rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"

echo ""
echo "=== Test 2: Codex notify hook payload (via \$1) ==="
TMUX_PANE="%test99" bash "$HOOK" '{"type":"agent-turn-complete","last-assistant-message":"Hello from Codex test","thread-id":"abc","turn-id":"t1","cwd":"/tmp","input-messages":["test"]}' >/dev/null 2>&1
RESP=$(cat "$PROJECT_ROOT/.urc/responses/%test99.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "Hello from Codex test"
_check test "$(echo "$RESP" | jq -r '.cli' 2>/dev/null)" = "codex"
_check test "$(echo "$RESP" | jq -r '.turn_id' 2>/dev/null)" = "t1"

rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"

echo ""
echo "=== Test 3: Gemini AfterAgent hook payload ==="
STDOUT=$(echo '{"prompt":"test prompt","prompt_response":"Hello from Gemini test","stop_hook_active":false}' | \
    TMUX_PANE="%test99" bash "$HOOK" 2>/dev/null)
echo "$STDOUT" | jq -e '.continue == true' >/dev/null 2>&1
_check test $? -eq 0
RESP=$(cat "$PROJECT_ROOT/.urc/responses/%test99.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "Hello from Gemini test"
_check test "$(echo "$RESP" | jq -r '.cli' 2>/dev/null)" = "gemini"

rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"

rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"

echo ""
echo "=== Test 3b: Claude payload WITH hook_event_name (regression) ==="
echo '{"hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"Claude with hook_event_name"}' | \
    TMUX_PANE="%test99" bash "$HOOK" >/dev/null 2>&1
RESP=$(cat "$PROJECT_ROOT/.urc/responses/%test99.json" 2>/dev/null || echo "{}")
_check test "$(echo "$RESP" | jq -r '.cli' 2>/dev/null)" = "claude"
_check test "$(echo "$RESP" | jq -r '.response' 2>/dev/null)" = "Claude with hook_event_name"

rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"

echo ""
echo "=== Test 4: SHA-256 checksum present ==="
echo '{"last_assistant_message":"checksum test"}' | \
    TMUX_PANE="%test99" bash "$HOOK" >/dev/null 2>&1
RESP=$(cat "$PROJECT_ROOT/.urc/responses/%test99.json" 2>/dev/null || echo "{}")
SHA=$(echo "$RESP" | jq -r '.sha256' 2>/dev/null)
_check test -n "$SHA"
_check test "$SHA" != "null"

rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"

echo ""
echo "=== Test 5: JSONL stream written ==="
rm -f "$PROJECT_ROOT/.urc/streams/%test99.jsonl"
echo '{"last_assistant_message":"stream test"}' | \
    TMUX_PANE="%test99" bash "$HOOK" >/dev/null 2>&1
_check test -f "$PROJECT_ROOT/.urc/streams/%test99.jsonl"
_check test "$(jq -r '.type' "$PROJECT_ROOT/.urc/streams/%test99.jsonl" 2>/dev/null)" = "turn_end"

rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99" "$PROJECT_ROOT/.urc/streams/%test99.jsonl"

echo ""
echo "=== Test 6: Empty input (no crash, signals still created) ==="
rm -f "$PROJECT_ROOT/.urc/signals/done_%test99"
TMUX_PANE="%test99" bash "$HOOK" < /dev/null >/dev/null 2>&1
_check test -f "$PROJECT_ROOT/.urc/signals/done_%test99"

# Final cleanup
rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99" "$PROJECT_ROOT/.urc/streams/%test99.jsonl"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
