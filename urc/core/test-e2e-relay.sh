#!/usr/bin/env bash
# test-e2e-relay.sh — E2E test: send.sh → hook.sh → wait.sh
# Tests the critical path: dispatch message to pane, hook writes response, wait picks it up.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAW="$SCRIPT_DIR/dispatch-and-wait.sh"
HOOK="$SCRIPT_DIR/hook.sh"
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

# Skip if no tmux
if ! tmux info >/dev/null 2>&1; then
    echo "SKIP: No tmux session available"
    exit 0
fi

# Ensure directories
mkdir -p "$PROJECT_ROOT/.urc/responses" "$PROJECT_ROOT/.urc/signals" \
         "$PROJECT_ROOT/.urc/locks" "$PROJECT_ROOT/.urc/timeout" \
         "$PROJECT_ROOT/.urc/streams"

echo "=== E2E Test 1: dispatch → hook → wait (completed) ==="

# 1. Create a test pane
TEST_PANE=$(tmux split-window -d -P -F '#{pane_id}' -- sleep 60)
sleep 0.5

# Clean leftover state
rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" \
      "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}" \
      "$PROJECT_ROOT/.urc/timeout/${TEST_PANE}"
rmdir "$PROJECT_ROOT/.urc/locks/dispatch_${TEST_PANE}.d" 2>/dev/null || true

# 2. Start dispatch-and-wait in background (10s timeout)
bash "$DAW" "$TEST_PANE" "e2e test message" 10 > /tmp/e2e-result-$$.json 2>/dev/null &
DAW_PID=$!

# 3. Wait for send.sh to deliver and wait.sh to start blocking
sleep 2

# 4. Simulate hook.sh firing (as if the target pane completed processing)
HOOK_RESPONSE="E2E test response payload"
echo "{\"last_assistant_message\":\"$HOOK_RESPONSE\"}" | \
    TMUX_PANE="$TEST_PANE" bash "$HOOK" >/dev/null 2>&1

# 5. Wait for dispatch-and-wait.sh to finish
wait $DAW_PID 2>/dev/null || true

# 6. Verify results
RESULT=$(cat /tmp/e2e-result-$$.json 2>/dev/null || echo '{}')
STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
RESPONSE=$(echo "$RESULT" | jq -r '.response' 2>/dev/null)

_check "Status is completed" test "$STATUS" = "completed"
_check "Response matches hook payload" test "$RESPONSE" = "$HOOK_RESPONSE"
HAS_LATENCY=$(echo "$RESULT" | jq -e '.latency_s' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Has latency_s field" test "$HAS_LATENCY" = "yes"
_check "Lock released" test ! -d "$PROJECT_ROOT/.urc/locks/dispatch_${TEST_PANE}.d"

# Cleanup
tmux kill-pane -t "$TEST_PANE" 2>/dev/null || true
rm -f /tmp/e2e-result-$$.json \
      "$PROJECT_ROOT/.urc/responses/${TEST_PANE}.json" \
      "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE}" \
      "$PROJECT_ROOT/.urc/timeout/${TEST_PANE}" \
      "$PROJECT_ROOT/.urc/streams/${TEST_PANE}.jsonl"

echo ""
echo "=== E2E Test 2: dispatch → timeout (no hook fires) ==="

# 1. Create a test pane that won't respond
TEST_PANE2=$(tmux split-window -d -P -F '#{pane_id}' -- sleep 60)
sleep 0.5

rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE2}.json" \
      "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE2}" \
      "$PROJECT_ROOT/.urc/timeout/${TEST_PANE2}"
rmdir "$PROJECT_ROOT/.urc/locks/dispatch_${TEST_PANE2}.d" 2>/dev/null || true

# 2. Dispatch with 3s timeout — pane won't process, should timeout
RESULT=$(bash "$DAW" "$TEST_PANE2" "timeout test" 3 2>/dev/null || true)
STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)

_check "Timeout status returned" test "$STATUS" = "timeout"
HAS_CAPTURED=$(echo "$RESULT" | jq -e '.captured' >/dev/null 2>&1 && echo "yes" || echo "no")
_check "Has captured field" test "$HAS_CAPTURED" = "yes"

# Cleanup
tmux kill-pane -t "$TEST_PANE2" 2>/dev/null || true
rm -f "$PROJECT_ROOT/.urc/responses/${TEST_PANE2}.json" \
      "$PROJECT_ROOT/.urc/signals/done_${TEST_PANE2}" \
      "$PROJECT_ROOT/.urc/timeout/${TEST_PANE2}"
rmdir "$PROJECT_ROOT/.urc/locks/dispatch_${TEST_PANE2}.d" 2>/dev/null || true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
