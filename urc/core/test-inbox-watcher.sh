#!/usr/bin/env bash
# test-inbox-watcher.sh — Tests for inbox-watcher.sh (Layer 5)
# Usage: bash urc/core/test-inbox-watcher.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WATCHER="$SCRIPT_DIR/inbox-watcher.sh"

PASS=0
FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "true" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== inbox-watcher.sh tests ==="

# --- Setup ---
TEST_PANE="%99997"
INBOX_DIR="$PROJECT_DIR/.urc/inbox"
SIGNAL_FILE="$INBOX_DIR/${TEST_PANE}.signal"
mkdir -p "$INBOX_DIR"
rm -f "$SIGNAL_FILE"

# --- Test 1: Fast path — signal file already exists ---
echo ""
echo "Test 1: Fast path (signal file exists)"
echo "test" > "$SIGNAL_FILE"
OUT=$(TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$WATCHER" 5 2>/dev/null)
check "returns INBOX_READY" "$([ "$OUT" = "INBOX_READY" ] && echo true || echo false)"
rm -f "$SIGNAL_FILE"

# --- Test 2: Timeout — no signal, no file ---
echo ""
echo "Test 2: Timeout (no signal within timeout)"
OUT=$(TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$WATCHER" 3 2>/dev/null)
check "returns TIMEOUT" "$([ "$OUT" = "TIMEOUT" ] && echo true || echo false)"

# --- Test 3: Signal fires — tmux wait-for unblocks ---
echo ""
echo "Test 3: Signal fires (tmux wait-for unblocks)"
rm -f "$SIGNAL_FILE"
# Start watcher in background
TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$WATCHER" 10 > /tmp/urc-watcher-test-out.txt 2>/dev/null &
WPID=$!
sleep 1
# Create signal file + fire tmux signal (simulates send_message notify=true)
echo "sender" > "$SIGNAL_FILE"
tmux wait-for -S "urc_inbox_${TEST_PANE}" 2>/dev/null
wait $WPID 2>/dev/null
OUT=$(cat /tmp/urc-watcher-test-out.txt)
check "returns INBOX_READY on signal" "$([ "$OUT" = "INBOX_READY" ] && echo true || echo false)"
rm -f "$SIGNAL_FILE" /tmp/urc-watcher-test-out.txt

# --- Test 4: Signal without file — returns TIMEOUT ---
echo ""
echo "Test 4: Signal without file (edge case)"
rm -f "$SIGNAL_FILE"
TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$WATCHER" 10 > /tmp/urc-watcher-test-out.txt 2>/dev/null &
WPID=$!
sleep 1
# Fire signal but don't create file (bare signal, shouldn't happen in practice)
tmux wait-for -S "urc_inbox_${TEST_PANE}" 2>/dev/null
wait $WPID 2>/dev/null
OUT=$(cat /tmp/urc-watcher-test-out.txt)
check "returns TIMEOUT (signal but no file)" "$([ "$OUT" = "TIMEOUT" ] && echo true || echo false)"
rm -f /tmp/urc-watcher-test-out.txt

# --- Test 5: Exit code is always 0 ---
echo ""
echo "Test 5: Exit code always 0"
TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$WATCHER" 2 2>/dev/null
EC=$?
check "exit code 0 on timeout" "$([ "$EC" -eq 0 ] && echo true || echo false)"
echo "test" > "$SIGNAL_FILE"
TMUX_PANE="$TEST_PANE" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$WATCHER" 2 2>/dev/null
EC=$?
check "exit code 0 on ready" "$([ "$EC" -eq 0 ] && echo true || echo false)"
rm -f "$SIGNAL_FILE"

# --- Summary ---
echo ""
TOTAL=$((PASS + FAIL))
echo "=== $PASS/$TOTAL passed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
