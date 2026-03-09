#!/usr/bin/env bash
# test-send.sh — tests for send.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0

_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL+1))
    fi
}

echo "=== Test 6: Invalid pane format returns error JSON ==="
RESULT=$(bash "$SCRIPT_DIR/send.sh" "bad_pane" "hello" 2>/dev/null || true)
JQ_VALID=$(echo "$RESULT" | jq -e '.' >/dev/null 2>&1 && echo "yes" || echo "no")
STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
ERROR=$(echo "$RESULT" | jq -r '.error' 2>/dev/null)
_check "Output is valid JSON" test "$JQ_VALID" = "yes"
_check "Status is failed" test "$STATUS" = "failed"
HAS_MSG=$(echo "$ERROR" | grep -q "invalid pane ID format" && echo "yes" || echo "no")
_check "Error mentions invalid pane ID format" test "$HAS_MSG" = "yes"

echo ""
echo "=== Test 7: Happy-path delivery to real pane ==="
if tmux info >/dev/null 2>&1; then
    TEMP_PANE=$(tmux split-window -d -P -F '#{pane_id}' -- sleep 30)
    sleep 0.3  # let pane initialize
    RESULT=$(bash "$SCRIPT_DIR/send.sh" "$TEMP_PANE" "hello from test" 2>/dev/null || true)
    STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
    PANE_FIELD=$(echo "$RESULT" | jq -r '.pane' 2>/dev/null)
    JQ_VALID=$(echo "$RESULT" | jq -e '.' >/dev/null 2>&1 && echo "yes" || echo "no")
    _check "Real pane returns delivered" test "$STATUS" = "delivered"
    _check "Pane field matches" test "$PANE_FIELD" = "$TEMP_PANE"
    _check "Output is valid JSON" test "$JQ_VALID" = "yes"
    tmux kill-pane -t "$TEMP_PANE" 2>/dev/null || true
else
    echo "  SKIP: No tmux session available"
fi

echo ""
echo "=== Test 8: Delivery to dead pane returns failed ==="
RESULT=$(bash "$SCRIPT_DIR/send.sh" "%99986" "should fail" 2>/dev/null || true)
STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
_check "Dead pane returns failed" test "$STATUS" = "failed"

echo ""
echo "=== Test 9: --cli shell flag delivers without Escape ==="
if tmux info >/dev/null 2>&1; then
    TEMP_PANE=$(tmux split-window -d -P -F '#{pane_id}' -- sleep 30)
    sleep 0.3
    RESULT=$(bash "$SCRIPT_DIR/send.sh" "$TEMP_PANE" "hello shell" --cli shell 2>/dev/null || true)
    STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
    CLI_FIELD=$(echo "$RESULT" | jq -r '.cli' 2>/dev/null)
    _check "--cli shell returns delivered" test "$STATUS" = "delivered"
    _check "--cli shell reports cli as shell" test "$CLI_FIELD" = "shell"
    tmux kill-pane -t "$TEMP_PANE" 2>/dev/null || true
else
    echo "  SKIP: No tmux session available"
fi

echo ""
echo "=== Test 10: --cli claude flag delivers with Escape ==="
if tmux info >/dev/null 2>&1; then
    TEMP_PANE=$(tmux split-window -d -P -F '#{pane_id}' -- sleep 30)
    sleep 0.3
    RESULT=$(bash "$SCRIPT_DIR/send.sh" "$TEMP_PANE" "hello claude" --cli claude 2>/dev/null || true)
    STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
    CLI_FIELD=$(echo "$RESULT" | jq -r '.cli' 2>/dev/null)
    _check "--cli claude returns delivered" test "$STATUS" = "delivered"
    _check "--cli claude reports cli as claude" test "$CLI_FIELD" = "claude"
    tmux kill-pane -t "$TEMP_PANE" 2>/dev/null || true
else
    echo "  SKIP: No tmux session available"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
