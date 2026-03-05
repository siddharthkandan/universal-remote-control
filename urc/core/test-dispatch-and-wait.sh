#!/usr/bin/env bash
# test-dispatch-and-wait.sh — tests for dispatch-and-wait.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAW="$SCRIPT_DIR/dispatch-and-wait.sh"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0

_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL+1))
    fi
}

mkdir -p "$PROJECT_ROOT/.urc/responses" "$PROJECT_ROOT/.urc/signals" "$PROJECT_ROOT/.urc/locks" "$PROJECT_ROOT/.urc/timeout"

echo "=== Test 1: Pre-existing response (instant return) ==="
echo '{"v":1,"pane":"%test88","cli":"claude","turn_id":"t1","epoch":9999999999,"response":"pre-existing","len":12,"sha256":"abc","ts":"2026-01-01T00:00:00Z"}' > "$PROJECT_ROOT/.urc/responses/%test88.json"
touch "$PROJECT_ROOT/.urc/signals/done_%test88"
RESULT=$(bash "$DAW" "%test88" "test message" 5 --skip-dispatch 2>/dev/null)
_check "Pre-existing response detected" test "$(echo "$RESULT" | jq -r '.status')" = "completed"
_check "Response text correct" test "$(echo "$RESULT" | jq -r '.response_text')" = "pre-existing"
rm -f "$PROJECT_ROOT/.urc/responses/%test88.json" "$PROJECT_ROOT/.urc/signals/done_%test88"

echo ""
echo "=== Test 2: Timeout (no signal, short timeout) ==="
rm -f "$PROJECT_ROOT/.urc/signals/done_%test88" "$PROJECT_ROOT/.urc/responses/%test88.json"
RESULT=$(bash "$DAW" "%test88" "test message" 3 --skip-dispatch 2>/dev/null)
_check "Timeout detected" test "$(echo "$RESULT" | jq -r '.status')" = "timeout"
rm -f "$PROJECT_ROOT/.urc/timeout/%test88"

echo ""
echo "=== Test 3: Signal file created mid-wait ==="
rm -f "$PROJECT_ROOT/.urc/signals/done_%test88" "$PROJECT_ROOT/.urc/responses/%test88.json"
(
    sleep 1
    echo '{"v":1,"pane":"%test88","cli":"codex","turn_id":"t2","epoch":9999999999,"response":"delayed response","len":16,"sha256":"def","ts":"2026-01-01T00:00:00Z"}' > "$PROJECT_ROOT/.urc/responses/%test88.json"
    touch "$PROJECT_ROOT/.urc/signals/done_%test88"
    tmux wait-for -S "urc_done_%test88" 2>/dev/null
) &
RESULT=$(bash "$DAW" "%test88" "test message" 10 --skip-dispatch 2>/dev/null)
_check "Mid-wait signal detected" test "$(echo "$RESULT" | jq -r '.status')" = "completed"
_check "Delayed response correct" test "$(echo "$RESULT" | jq -r '.response_text')" = "delayed response"
rm -f "$PROJECT_ROOT/.urc/responses/%test88.json" "$PROJECT_ROOT/.urc/signals/done_%test88"

echo ""
echo "=== Test 4: Stale response rejected, real response accepted ==="
rm -f "$PROJECT_ROOT/.urc/signals/done_%test88" "$PROJECT_ROOT/.urc/responses/%test88.json"
DISPATCH_TS=$(date +%s)
(
    # After 1s: write stale response (timestamp BEFORE dispatch) + signal
    sleep 1
    echo "{\"v\":1,\"pane\":\"%test88\",\"cli\":\"claude\",\"turn_id\":\"stale\",\"epoch\":$((DISPATCH_TS - 10)),\"response\":\"STALE\",\"len\":5,\"sha256\":\"aaa\",\"ts\":\"2026-01-01\"}" > "$PROJECT_ROOT/.urc/responses/%test88.json"
    touch "$PROJECT_ROOT/.urc/signals/done_%test88"
    tmux wait-for -S "urc_done_%test88" 2>/dev/null
    # After 2s more: write real response (timestamp AFTER dispatch) + signal
    sleep 2
    echo "{\"v\":1,\"pane\":\"%test88\",\"cli\":\"claude\",\"turn_id\":\"real\",\"epoch\":$((DISPATCH_TS + 5)),\"response\":\"REAL dispatched response\",\"len\":23,\"sha256\":\"bbb\",\"ts\":\"2026-01-01\"}" > "$PROJECT_ROOT/.urc/responses/%test88.json"
    touch "$PROJECT_ROOT/.urc/signals/done_%test88"
    tmux wait-for -S "urc_done_%test88" 2>/dev/null
) &
# Use the stale-aware dispatch timestamp via env var
RESULT=$(URC_DISPATCH_TS="$DISPATCH_TS" bash "$DAW" "%test88" "test message" 15 --skip-dispatch 2>/dev/null)
_check "Completed despite stale interleave" test "$(echo "$RESULT" | jq -r '.status')" = "completed"
_check "Returned real response" test "$(echo "$RESULT" | jq -r '.response_text')" = "REAL dispatched response"
rm -f "$PROJECT_ROOT/.urc/responses/%test88.json" "$PROJECT_ROOT/.urc/signals/done_%test88"

echo ""
echo "=== Test 5: JSON output is valid ==="
echo '{"v":1,"pane":"%test88","cli":"claude","turn_id":"t1","epoch":9999999999,"response":"json test","len":9,"sha256":"abc","ts":"2026-01-01"}' > "$PROJECT_ROOT/.urc/responses/%test88.json"
touch "$PROJECT_ROOT/.urc/signals/done_%test88"
RESULT=$(bash "$DAW" "%test88" "test" 5 --skip-dispatch 2>/dev/null)
JQ_VALID=$(echo "$RESULT" | jq -e '.' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Valid JSON output" test "$JQ_VALID" = "yes"
_check "Has pane_id field" test "$(echo "$RESULT" | jq -r '.pane_id')" = "%test88"
HAS_LATENCY=$(echo "$RESULT" | jq -e '.latency_ms' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Has latency_ms field" test "$HAS_LATENCY" = "yes"
rm -f "$PROJECT_ROOT/.urc/responses/%test88.json" "$PROJECT_ROOT/.urc/signals/done_%test88"

# Cleanup
rm -f "$PROJECT_ROOT/.urc/locks/%test88.lock" "$PROJECT_ROOT/.urc/timeout/%test88"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
