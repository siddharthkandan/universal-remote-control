#!/usr/bin/env bash
# test-dispatch-and-wait.sh — tests for dispatch-and-wait.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAW="$SCRIPT_DIR/dispatch-and-wait.sh"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
TEST_PANE="%99988"

_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL+1))
    fi
}

_lock_path() { echo "$PROJECT_ROOT/.urc/locks/dispatch_${TEST_PANE}.d"; }
_clean_lock() { rmdir "$(_lock_path)" 2>/dev/null || true; }
_clean_all() {
    rm -f "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}" "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json"
    rm -f "$PROJECT_ROOT/.urc/circuits/${TEST_PANE}"
    _clean_lock
}

mkdir -p "$PROJECT_ROOT/.urc/responses" "$PROJECT_ROOT/.urc/signals" "$PROJECT_ROOT/.urc/locks" "$PROJECT_ROOT/.urc/timeout" "$PROJECT_ROOT/.urc/circuits"

echo "=== Test 1: Dispatch to non-existent pane ==="
_clean_all
RESULT=$(bash "$DAW" "$TEST_PANE" "hello" 5 2>/dev/null || true)
_check "Non-existent pane returns failed" test "$(echo "$RESULT" | jq -r '.status' 2>/dev/null)" = "failed"
JQ_VALID=$(echo "$RESULT" | jq -e '.' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Output is valid JSON" test "$JQ_VALID" = "yes"
_clean_lock

echo ""
echo "=== Test 2: Concurrent lock returns busy ==="
_clean_lock
mkdir -p "$(_lock_path)"
# Touch the lock dir to make it fresh (not stale)
touch "$(_lock_path)"
RESULT=$(bash "$DAW" "$TEST_PANE" "hello" 5 2>/dev/null || true)
_check "Locked pane returns busy" test "$(echo "$RESULT" | jq -r '.status' 2>/dev/null)" = "busy"
_clean_lock

echo ""
echo "=== Test 3: Stale lock recovery ==="
_clean_lock
mkdir -p "$(_lock_path)"
# Backdate the lock dir to >300s ago
touch -t 202501010000 "$(_lock_path)"
RESULT=$(bash "$DAW" "$TEST_PANE" "hello" 5 2>/dev/null || true)
STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
# Stale lock should be recovered (not busy). The dispatch itself may fail
# (non-existent pane), but it should NOT be "busy".
_check "Stale lock not busy" test "$STATUS" != "busy"
_clean_lock

echo ""
echo "=== Test 4: JSON output format ==="
_clean_lock
RESULT=$(bash "$DAW" "$TEST_PANE" "test" 5 2>/dev/null || true)
JQ_VALID=$(echo "$RESULT" | jq -e '.' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Valid JSON output" test "$JQ_VALID" = "yes"
HAS_STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
_check "Has status field" test -n "$HAS_STATUS"
_clean_lock

echo ""
echo "=== Test 5: Timeout parameter accepted ==="
_clean_lock
# Just verify the script accepts a third argument without error
RESULT=$(bash "$DAW" "$TEST_PANE" "test" 3 2>/dev/null || true)
_check "Timeout arg accepted" test -n "$RESULT"
_clean_lock

echo ""
echo "=== Test 6: Lock released after completion ==="
_clean_lock
bash "$DAW" "$TEST_PANE" "test" 3 >/dev/null 2>&1 || true
_check "Lock dir removed after exit" test ! -d "$(_lock_path)"

# Cleanup
_clean_all
rm -f "$PROJECT_ROOT/.urc/timeout/${TEST_PANE}"
rm -f "$PROJECT_ROOT/.urc/circuits/${TEST_PANE}"

echo ""
echo "=== Test 7: Concurrent lock contention ==="
_clean_all
# Start a dispatch in background (will fail since pane doesn't exist, but lock is held briefly)
bash "$DAW" "$TEST_PANE" "first" 3 >/dev/null 2>&1 &
BG_PID=$!
sleep 0.1  # Let first dispatch acquire lock
RESULT2=$(bash "$DAW" "$TEST_PANE" "second" 3 2>/dev/null || true)
STATUS2=$(echo "$RESULT2" | jq -r '.status' 2>/dev/null)
# Either "busy" (lock contention) or "failed" (pane doesn't exist, lock already released)
_check "Concurrent dispatch handled" test "$STATUS2" = "busy" -o "$STATUS2" = "failed"
wait $BG_PID 2>/dev/null || true
_clean_lock

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
