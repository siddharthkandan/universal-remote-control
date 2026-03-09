#!/usr/bin/env bash
# test-wait.sh — tests for wait.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAIT="$SCRIPT_DIR/wait.sh"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
TEST_PANE="%99997"

_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL+1))
    fi
}

mkdir -p "$PROJECT_ROOT/.urc/responses" "$PROJECT_ROOT/.urc/signals" "$PROJECT_ROOT/.urc/timeout"

_clean() {
    rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json"
    rm -f "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
    rm -f "$PROJECT_ROOT/.urc/timeout/${TEST_PANE}"
}

echo "=== Test 1: Epoch equality accepted ==="
_clean
EPOCH=$(date +%s)
# Pre-create response file with matching epoch
echo "{\"pane\":\"$TEST_PANE\",\"cli\":\"claude\",\"epoch\":$EPOCH,\"response\":\"epoch-equal-test\",\"len\":16}" \
    > "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json"
# Pre-create signal file
touch "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
# Run wait.sh — should find the response immediately (epoch matches)
RESULT=$(bash "$WAIT" "$TEST_PANE" 3 "$EPOCH" 2>/dev/null || true)
STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
RESP_TEXT=$(echo "$RESULT" | jq -r '.response' 2>/dev/null)
_check "Epoch equality returns completed" test "$STATUS" = "completed"
_check "Epoch equality response text" test "$RESP_TEXT" = "epoch-equal-test"
_clean

echo ""
echo "=== Test 2: Epoch stale rejected ==="
_clean
# Pre-create response file with epoch=999 (stale)
echo "{\"pane\":\"$TEST_PANE\",\"cli\":\"claude\",\"epoch\":999,\"response\":\"stale-response\",\"len\":14}" \
    > "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json"
# Pre-create signal file
touch "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}"
# Run wait.sh with dispatch_ts=1000 — stale response should be rejected, then timeout
RESULT=$(bash "$WAIT" "$TEST_PANE" 2 1000 2>/dev/null || true)
STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
_check "Stale epoch returns timeout" test "$STATUS" = "timeout"
_clean

echo ""
echo "=== Test 3: Timeout captures pane buffer ==="
_clean
# No response file, no signal — wait.sh should timeout
RESULT=$(bash "$WAIT" "$TEST_PANE" 2 2>/dev/null || true)
STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
HAS_CAPTURED=$(echo "$RESULT" | jq -e 'has("captured")' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Timeout returns timeout status" test "$STATUS" = "timeout"
_check "Timeout output has captured field" test "$HAS_CAPTURED" = "yes"
_clean

# Final cleanup
_clean

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
