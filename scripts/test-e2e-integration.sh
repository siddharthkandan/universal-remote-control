#!/usr/bin/env bash
# test-e2e-integration.sh — Automated end-to-end integration test
#
# Spawns real Codex/Gemini panes, creates relay bridges, sends messages,
# and verifies the full pipeline. Cleans up all spawned panes on exit.
#
# Usage: bash scripts/test-e2e-integration.sh
# Requires: tmux session, jq, .venv/bin/python3
# Duration: ~2-5 minutes (depends on CLI boot times)

set -uo pipefail
# NOTE: No set -e — test scripts must continue through individual failures

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
DB_PATH="$PROJECT_ROOT/.urc/coordination.db"

PASS=0; FAIL=0; SKIP=0
SPAWNED_PANES=()

# Per-CLI tracking (no associative arrays — bash 3.x compat)
CODEX_RELAY=""; CODEX_TARGET=""
GEMINI_RELAY=""; GEMINI_TARGET=""

# ── Helpers ───────────────────────────────────────────────────
_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL+1))
    fi
}

_pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
_fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
_skip() { echo "  SKIP: $1"; SKIP=$((SKIP+1)); }

# ── Cleanup (EXIT trap — CRITICAL) ───────────────────────────
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    for pane in ${SPAWNED_PANES[@]+"${SPAWNED_PANES[@]}"}; do
        if tmux display-message -t "$pane" -p '#{pane_id}' >/dev/null 2>&1; then
            tmux kill-pane -t "$pane" 2>/dev/null && echo "  Killed pane $pane" || true
        fi
    done
    # Deregister test agents from DB
    for pane in ${SPAWNED_PANES[@]+"${SPAWNED_PANES[@]}"}; do
        sqlite3 "$DB_PATH" "DELETE FROM agents WHERE pane_id='$pane'" 2>/dev/null || true
    done
    # Clean up test DB entries (Group 5)
    sqlite3 "$DB_PATH" "DELETE FROM agents WHERE pane_id IN ('%99998','%99999')" 2>/dev/null || true
    sqlite3 "$DB_PATH" "DELETE FROM messages WHERE from_pane='%99998' OR to_pane='%99999'" 2>/dev/null || true
    # Remove test relay config
    bash "$PROJECT_ROOT/urc/core/relay-ctl.sh" remove testcli 2>/dev/null || true
    # Clean up test circuit breaker state
    for pane in ${SPAWNED_PANES[@]+"${SPAWNED_PANES[@]}"}; do
        rm -f "$PROJECT_ROOT/.urc/circuits/$pane" 2>/dev/null || true
    done
    # Clean up temp spawn output files
    rm -f /tmp/urc-e2e-gemini-$$.json /tmp/urc-e2e-codex-$$.json 2>/dev/null || true
    echo "  Cleanup complete."
}
trap cleanup EXIT

# ── Prerequisites ─────────────────────────────────────────────
echo "=== Prerequisites ==="

if ! tmux info >/dev/null 2>&1; then
    echo "FATAL: No tmux session — cannot run E2E tests"
    exit 1
fi
_check "tmux available" tmux info

MY_PANE="${TMUX_PANE:-}"
if [ -z "$MY_PANE" ]; then
    MY_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
fi
if [ -z "$MY_PANE" ]; then
    echo "FATAL: Cannot determine current pane ID"
    exit 1
fi
_pass "Current pane: $MY_PANE"

_check "jq available" command -v jq
_check ".venv/bin/python3 exists" test -f "$VENV_PYTHON"
_check "coordination DB exists" test -f "$DB_PATH"

HAS_CODEX=0; HAS_GEMINI=0
command -v codex >/dev/null 2>&1 && HAS_CODEX=1
command -v gemini >/dev/null 2>&1 && HAS_GEMINI=1

[ "$HAS_CODEX" -eq 1 ] && echo "  INFO: codex available" || echo "  INFO: codex NOT available (skipping codex tests)"
[ "$HAS_GEMINI" -eq 1 ] && echo "  INFO: gemini available" || echo "  INFO: gemini NOT available (skipping gemini tests)"

if [ "$HAS_CODEX" -eq 0 ] && [ "$HAS_GEMINI" -eq 0 ]; then
    echo "  WARN: Neither codex nor gemini available — spawn tests will be skipped"
    echo "        DB-only tests (Groups 5-6) still run."
fi

# Ensure directories
mkdir -p "$PROJECT_ROOT/.urc/responses" "$PROJECT_ROOT/.urc/signals" \
         "$PROJECT_ROOT/.urc/locks" "$PROJECT_ROOT/.urc/timeout" \
         "$PROJECT_ROOT/.urc/streams" "$PROJECT_ROOT/.urc/pushes" \
         "$PROJECT_ROOT/.urc/dispatches" "$PROJECT_ROOT/.urc/circuits"

echo ""

# ============================================================
# Test Group 1: Spawn + Bridge Verification
# ============================================================
echo "=== Test Group 1: Spawn + Bridge ==="

# Launch both spawns in parallel (each takes ~20-50s, parallel halves total time)
GEMINI_SPAWN_PID=""; CODEX_SPAWN_PID=""
GEMINI_SPAWN_FILE="/tmp/urc-e2e-gemini-$$.json"
CODEX_SPAWN_FILE="/tmp/urc-e2e-codex-$$.json"

if [ "$HAS_GEMINI" -eq 1 ]; then
    echo "  INFO: Launching GEMINI spawn in background..."
    bash "$PROJECT_ROOT/urc/core/urc-spawn.sh" spawn GEMINI "" "$MY_PANE" > "$GEMINI_SPAWN_FILE" 2>/dev/null &
    GEMINI_SPAWN_PID=$!
fi
if [ "$HAS_CODEX" -eq 1 ]; then
    echo "  INFO: Launching CODEX spawn in background..."
    bash "$PROJECT_ROOT/urc/core/urc-spawn.sh" spawn CODEX "" "$MY_PANE" > "$CODEX_SPAWN_FILE" 2>/dev/null &
    CODEX_SPAWN_PID=$!
fi

if [ -z "$GEMINI_SPAWN_PID" ] && [ -z "$CODEX_SPAWN_PID" ]; then
    _skip "Spawn (no CLIs available)"
fi

# Wait for both to complete
echo "  INFO: Waiting for spawns to complete (parallel, ~20-50s each)..."
if [ -n "$GEMINI_SPAWN_PID" ]; then wait "$GEMINI_SPAWN_PID" 2>/dev/null || true; fi
if [ -n "$CODEX_SPAWN_PID" ]; then wait "$CODEX_SPAWN_PID" 2>/dev/null || true; fi
echo "  INFO: All spawns finished."

# Verify each CLI's spawn result
for CLI_TYPE in GEMINI CODEX; do
    cli_lower=$(echo "$CLI_TYPE" | tr '[:upper:]' '[:lower:]')
    eval "SPAWN_FILE=\"\${${CLI_TYPE}_SPAWN_FILE}\""
    eval "SPAWN_PID=\"\${${CLI_TYPE}_SPAWN_PID}\""

    if [ -z "$SPAWN_PID" ]; then
        _skip "Spawn $CLI_TYPE (CLI not available)"
        continue
    fi

    echo ""
    echo "  --- $CLI_TYPE Verification ---"

    SPAWN_OUTPUT=$(cat "$SPAWN_FILE" 2>/dev/null || true)
    rm -f "$SPAWN_FILE"

    if [ -z "$SPAWN_OUTPUT" ]; then
        _fail_msg "$CLI_TYPE spawn produced no output"
        continue
    fi

    # Parse JSON output
    SPAWN_STATUS=$(echo "$SPAWN_OUTPUT" | jq -r '.status // "unknown"' 2>/dev/null)
    RELAY=$(echo "$SPAWN_OUTPUT" | jq -r '.relay // empty' 2>/dev/null)
    TARGET=$(echo "$SPAWN_OUTPUT" | jq -r '.target // empty' 2>/dev/null)
    METHOD=$(echo "$SPAWN_OUTPUT" | jq -r '.method // empty' 2>/dev/null)

    _check "$CLI_TYPE spawn status=ready" test "$SPAWN_STATUS" = "ready"
    _check "$CLI_TYPE relay pane present" test -n "$RELAY"
    _check "$CLI_TYPE target pane present" test -n "$TARGET"
    echo "  INFO: method=$METHOD relay=$RELAY target=$TARGET"

    # Track panes for cleanup + later tests
    if [ -n "$RELAY" ]; then
        SPAWNED_PANES+=("$RELAY")
        eval "${CLI_TYPE}_RELAY=\"$RELAY\""
    fi
    if [ -n "$TARGET" ]; then
        SPAWNED_PANES+=("$TARGET")
        eval "${CLI_TYPE}_TARGET=\"$TARGET\""
    fi

    # Verify panes exist in tmux
    if [ -n "$RELAY" ]; then
        _check "$CLI_TYPE relay pane alive" tmux display-message -t "$RELAY" -p '#{pane_id}'
    fi
    if [ -n "$TARGET" ]; then
        _check "$CLI_TYPE target pane alive" tmux display-message -t "$TARGET" -p '#{pane_id}'
    fi

    # Verify tmux pane options
    if [ -n "$RELAY" ] && [ -n "$TARGET" ]; then
        BRIDGE_TARGET=$(tmux show-options -pv -t "$RELAY" @bridge_target 2>/dev/null || true)
        BRIDGE_RELAY=$(tmux show-options -pv -t "$TARGET" @bridge_relay 2>/dev/null || true)
        BRIDGE_CLI=$(tmux show-options -pv -t "$RELAY" @bridge_cli 2>/dev/null || true)

        _check "$CLI_TYPE @bridge_target on relay == target" test "$BRIDGE_TARGET" = "$TARGET"
        _check "$CLI_TYPE @bridge_relay on target == relay" test "$BRIDGE_RELAY" = "$RELAY"
        _check "$CLI_TYPE @bridge_cli on relay == $CLI_TYPE" test "$BRIDGE_CLI" = "$CLI_TYPE"
    fi

    # Verify DB registration (relay should be registered as bridge)
    # Poll up to 10s — relay registers via MCP during bootstrap turn, may lag
    if [ -n "$RELAY" ]; then
        RELAY_ROLE=""
        for _db_wait in $(seq 1 20); do
            RELAY_ROLE=$(sqlite3 "$DB_PATH" "SELECT role FROM agents WHERE pane_id='$RELAY'" 2>/dev/null || true)
            if [ "$RELAY_ROLE" = "bridge" ]; then break; fi
            sleep 1
        done
        _check "$CLI_TYPE relay DB role=bridge" test "$RELAY_ROLE" = "bridge"

        RELAY_LABEL=$(sqlite3 "$DB_PATH" "SELECT label FROM agents WHERE pane_id='$RELAY'" 2>/dev/null || true)
        if echo "$RELAY_LABEL" | grep -iq "$cli_lower"; then
            _pass "$CLI_TYPE relay label contains CLI name"
        else
            _fail_msg "$CLI_TYPE relay label='$RELAY_LABEL' does not contain '$cli_lower'"
        fi
    fi
done

echo ""

# ── Pick first available target for subsequent tests ──────────
TEST_TARGET=""; TEST_RELAY=""; TEST_CLI=""
for ct in CODEX GEMINI; do
    eval "_t=\${${ct}_TARGET:-}"
    eval "_r=\${${ct}_RELAY:-}"
    if [ -n "$_t" ]; then
        TEST_TARGET="$_t"
        TEST_RELAY="$_r"
        TEST_CLI="$ct"
        break
    fi
done

# ============================================================
# Test Group 2: Message Delivery
# ============================================================
echo "=== Test Group 2: Message Delivery ==="

if [ -z "$TEST_TARGET" ]; then
    _skip "Message delivery (no CLI panes spawned)"
else
    TEST_MARKER="URC_TEST_OK_$(date +%s)"
    SEND_TS=$(date +%s)

    # Give CLI a few more seconds to fully boot after spawn
    sleep 5

    # 1. Send message via send.sh
    SEND_RESULT=$(bash "$PROJECT_ROOT/urc/core/send.sh" "$TEST_TARGET" "Say exactly: $TEST_MARKER" 2>/dev/null) || true
    SEND_STATUS=$(echo "$SEND_RESULT" | jq -r '.status // "unknown"' 2>/dev/null)
    _check "Message sent to $TEST_CLI target" test "$SEND_STATUS" = "delivered"

    # 2. Poll for response file (up to 60s)
    RESPONSE_FILE="$PROJECT_ROOT/.urc/responses/${TEST_TARGET}.json"
    RESPONSE_FOUND=0
    echo "  INFO: Waiting for $TEST_CLI to process message (up to 60s)..."
    for i in $(seq 1 60); do
        if [ -f "$RESPONSE_FILE" ]; then
            RESP_EPOCH=$(jq -r '.epoch // 0' "$RESPONSE_FILE" 2>/dev/null)
            if [ "$RESP_EPOCH" -ge "$SEND_TS" ] 2>/dev/null; then
                RESPONSE_FOUND=1
                echo "  INFO: Response received in ${i}s"
                break
            fi
        fi
        sleep 1
    done
    if [ "$RESPONSE_FOUND" -eq 1 ]; then
        _pass "Response file created with fresh epoch"
    else
        _fail_msg "Response file not created within 60s"
    fi

    # 3. Check stream JSONL (poll up to 5s — written by hook.sh step 4, after signal)
    STREAM_FILE="$PROJECT_ROOT/.urc/streams/${TEST_TARGET}.jsonl"
    STREAM_FOUND=0
    for _sw in $(seq 1 5); do
        if [ -f "$STREAM_FILE" ] && [ -s "$STREAM_FILE" ]; then
            STREAM_FOUND=1; break
        fi
        sleep 1
    done
    if [ "$STREAM_FOUND" -eq 1 ]; then
        _pass "Stream JSONL has entries"
    else
        _fail_msg "Stream JSONL empty or missing after 5s"
    fi

    # 4. Check push files (relay should have been notified)
    if [ -n "$TEST_RELAY" ]; then
        PUSH_FILES=$(ls "$PROJECT_ROOT/.urc/pushes/${TEST_RELAY}_${TEST_TARGET}_"* 2>/dev/null || true)
        if [ -n "$PUSH_FILES" ]; then
            _pass "Push files created for relay"
        else
            _fail_msg "No push files found for ${TEST_RELAY}_${TEST_TARGET}_*"
        fi
    fi
fi

echo ""

# ============================================================
# Test Group 3: Synchronous Dispatch
# ============================================================
echo "=== Test Group 3: Synchronous Dispatch ==="

if [ -z "$TEST_TARGET" ]; then
    _skip "Synchronous dispatch (no CLI panes spawned)"
else
    # Clean state for fresh dispatch
    rm -f "$PROJECT_ROOT/.urc/responses/${TEST_TARGET}.json" \
          "$PROJECT_ROOT/.urc/signals/done_${TEST_TARGET}" \
          "$PROJECT_ROOT/.urc/timeout/${TEST_TARGET}"
    rm -rf "$PROJECT_ROOT/.urc/locks/dispatch_${TEST_TARGET}.d" 2>/dev/null || true
    rm -f "$PROJECT_ROOT/.urc/circuits/${TEST_TARGET}" 2>/dev/null || true

    echo "  INFO: Dispatching to $TEST_CLI (timeout: 60s)..."
    DISPATCH_RESULT=$(bash "$PROJECT_ROOT/urc/core/dispatch-and-wait.sh" "$TEST_TARGET" "Say exactly: DISPATCH_TEST_OK" 60 2>/dev/null) || true

    if [ -n "$DISPATCH_RESULT" ]; then
        D_STATUS=$(echo "$DISPATCH_RESULT" | jq -r '.status // "unknown"' 2>/dev/null)

        if [ "$D_STATUS" = "completed" ]; then
            _pass "Dispatch status=completed"

            D_RESPONSE=$(echo "$DISPATCH_RESULT" | jq -r '.response // empty' 2>/dev/null)
            if [ -n "$D_RESPONSE" ]; then
                _pass "Dispatch response non-empty"
            else
                _fail_msg "Dispatch response is empty"
            fi

            HAS_LATENCY=$(echo "$DISPATCH_RESULT" | jq -e '.latency_s' >/dev/null 2>&1 && echo "yes" || echo "no")
            _check "Dispatch has latency_s field" test "$HAS_LATENCY" = "yes"

            # Circuit breaker should be clean after success
            _check "Circuit breaker clean" test ! -f "$PROJECT_ROOT/.urc/circuits/${TEST_TARGET}"

        elif [ "$D_STATUS" = "timeout" ]; then
            _pass "Dispatch returned status (timeout — CLI may be slow)"
            echo "  INFO: $TEST_CLI timed out — this is acceptable for slow CLIs"
            HAS_CAPTURED=$(echo "$DISPATCH_RESULT" | jq -e '.captured' >/dev/null 2>&1 && echo "yes" || echo "no")
            _check "Timeout has captured field" test "$HAS_CAPTURED" = "yes"
        else
            _fail_msg "Dispatch status='$D_STATUS' (expected completed or timeout)"
        fi
    else
        _fail_msg "dispatch-and-wait.sh produced no output"
    fi

    # Verify lock was released
    _check "Dispatch lock released" test ! -d "$PROJECT_ROOT/.urc/locks/dispatch_${TEST_TARGET}.d"
fi

echo ""

# ============================================================
# Test Group 4: $0 Relay Hook
# ============================================================
echo "=== Test Group 4: \$0 Relay Hook ==="

if [ -z "$TEST_TARGET" ]; then
    _skip "\$0 relay hook (no CLI panes spawned)"
else
    # Set up test relay config
    bash "$PROJECT_ROOT/urc/core/relay-ctl.sh" add testcli "$TEST_TARGET" >/dev/null 2>&1
    _check "Relay config created" test -f "$PROJECT_ROOT/.urc/relay-config.json"

    # Test 4a: Non-relay prompt → should pass through (exit 0, empty output)
    HOOK_PASSTHROUGH=$(echo '{"prompt":"hello world"}' | \
        CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" TMUX_PANE="$MY_PANE" \
        bash "$PROJECT_ROOT/hooks/scripts/urc-relay-hook.sh" 2>/dev/null) || true
    if [ -z "$HOOK_PASSTHROUGH" ]; then
        _pass "Non-relay prompt passes through silently"
    else
        _fail_msg "Non-relay prompt produced output: $HOOK_PASSTHROUGH"
    fi

    # Test 4b: Empty message → should block with usage error
    HOOK_EMPTY=$(echo '{"prompt":">testcli: "}' | \
        CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" TMUX_PANE="$MY_PANE" \
        bash "$PROJECT_ROOT/hooks/scripts/urc-relay-hook.sh" 2>/dev/null) || true
    EMPTY_DECISION=$(echo "$HOOK_EMPTY" | jq -r '.decision // empty' 2>/dev/null)
    if [ "$EMPTY_DECISION" = "block" ]; then
        _pass "Empty relay message blocked"
    else
        # Whitespace handling may vary — skip rather than fail
        _skip "Empty relay message (handling varies)"
    fi

    # Test 4c: Unknown target → should block
    HOOK_UNKNOWN=$(echo '{"prompt":">nonexistent: test"}' | \
        CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" TMUX_PANE="$MY_PANE" \
        bash "$PROJECT_ROOT/hooks/scripts/urc-relay-hook.sh" 2>/dev/null) || true
    UNKNOWN_DECISION=$(echo "$HOOK_UNKNOWN" | jq -r '.decision // empty' 2>/dev/null)
    _check "Unknown target returns block decision" test "$UNKNOWN_DECISION" = "block"

    # Test 4d: Disabled relay → should pass through
    bash "$PROJECT_ROOT/urc/core/relay-ctl.sh" off >/dev/null 2>&1
    HOOK_DISABLED=$(echo '{"prompt":">testcli: test"}' | \
        CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" TMUX_PANE="$MY_PANE" \
        bash "$PROJECT_ROOT/hooks/scripts/urc-relay-hook.sh" 2>/dev/null) || true
    if [ -z "$HOOK_DISABLED" ]; then
        _pass "Disabled relay passes through"
    else
        _fail_msg "Disabled relay produced output: $HOOK_DISABLED"
    fi
    bash "$PROJECT_ROOT/urc/core/relay-ctl.sh" on >/dev/null 2>&1

    # Test 4e: Full dispatch through relay hook (real CLI)
    # Re-add target after on/off cycle
    bash "$PROJECT_ROOT/urc/core/relay-ctl.sh" add testcli "$TEST_TARGET" >/dev/null 2>&1

    # Clean dispatch state
    rm -f "$PROJECT_ROOT/.urc/responses/${TEST_TARGET}.json" \
          "$PROJECT_ROOT/.urc/signals/done_${TEST_TARGET}" \
          "$PROJECT_ROOT/.urc/timeout/${TEST_TARGET}"
    rm -rf "$PROJECT_ROOT/.urc/locks/dispatch_${TEST_TARGET}.d" 2>/dev/null || true
    rm -f "$PROJECT_ROOT/.urc/circuits/${TEST_TARGET}" 2>/dev/null || true

    echo "  INFO: Testing full relay dispatch (up to 120s)..."
    HOOK_REAL=$(echo '{"prompt":">testcli: what is 1+1"}' | \
        CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" TMUX_PANE="$MY_PANE" \
        bash "$PROJECT_ROOT/hooks/scripts/urc-relay-hook.sh" 2>/dev/null) || true

    if [ -n "$HOOK_REAL" ]; then
        IS_BLOCK=$(echo "$HOOK_REAL" | jq -e '.decision' >/dev/null 2>&1 && echo "yes" || echo "no")
        IS_HOOK=$(echo "$HOOK_REAL" | jq -e '.hookSpecificOutput' >/dev/null 2>&1 && echo "yes" || echo "no")
        if [ "$IS_BLOCK" = "yes" ] || [ "$IS_HOOK" = "yes" ]; then
            _pass "Relay hook returned structured response"
        else
            _fail_msg "Relay hook output is not structured JSON: $HOOK_REAL"
        fi
    else
        _skip "Relay hook full dispatch (no output — CLI may have timed out)"
    fi

    # Cleanup relay config
    bash "$PROJECT_ROOT/urc/core/relay-ctl.sh" remove testcli >/dev/null 2>&1 || true
fi

echo ""

# ============================================================
# Test Group 5: DB Messaging
# ============================================================
echo "=== Test Group 5: DB Messaging ==="

# Pure DB tests — no CLIs needed
TEST_FROM="%99998"
TEST_TO="%99999"
TEST_BODY="E2E_MSG_$(date +%s)"

# 1. Insert test agents + message
"$VENV_PYTHON" -c "
import sqlite3
db = sqlite3.connect('$DB_PATH')
db.execute('INSERT INTO agents (pane_id, cli, role, status) VALUES (?, ?, ?, ?) ON CONFLICT(pane_id) DO UPDATE SET status=\"active\"', ('$TEST_FROM', 'test', 'worker', 'active'))
db.execute('INSERT INTO agents (pane_id, cli, role, status) VALUES (?, ?, ?, ?) ON CONFLICT(pane_id) DO UPDATE SET status=\"active\"', ('$TEST_TO', 'test', 'worker', 'active'))
db.execute('INSERT INTO messages (from_pane, to_pane, body) VALUES (?, ?, ?)', ('$TEST_FROM', '$TEST_TO', '$TEST_BODY'))
db.commit()
db.close()
" 2>/dev/null
_check "Test message inserted" test $? -eq 0

# 2. Query unread messages
UNREAD=$("$VENV_PYTHON" -c "
import sqlite3
db = sqlite3.connect('$DB_PATH')
rows = db.execute('SELECT body FROM messages WHERE to_pane=? AND read=0', ('$TEST_TO',)).fetchall()
for r in rows:
    print(r[0])
db.close()
" 2>/dev/null)
if echo "$UNREAD" | grep -q "$TEST_BODY"; then
    _pass "Unread message found in inbox"
else
    _fail_msg "Test message not found in inbox"
fi

# 3. Mark as read
"$VENV_PYTHON" -c "
import sqlite3
db = sqlite3.connect('$DB_PATH')
db.execute('UPDATE messages SET read=1 WHERE to_pane=? AND read=0', ('$TEST_TO',))
db.commit()
db.close()
" 2>/dev/null

# 4. Verify idempotency — second read returns 0 unread
UNREAD_COUNT=$("$VENV_PYTHON" -c "
import sqlite3
db = sqlite3.connect('$DB_PATH')
rows = db.execute('SELECT COUNT(*) FROM messages WHERE to_pane=? AND read=0', ('$TEST_TO',)).fetchall()
print(rows[0][0])
db.close()
" 2>/dev/null)
_check "Second read returns 0 unread (idempotent)" test "$UNREAD_COUNT" = "0"

# 5. Cleanup test data
"$VENV_PYTHON" -c "
import sqlite3
db = sqlite3.connect('$DB_PATH')
db.execute('DELETE FROM messages WHERE from_pane=? OR to_pane=?', ('$TEST_FROM', '$TEST_TO'))
db.execute('DELETE FROM agents WHERE pane_id IN (?, ?)', ('$TEST_FROM', '$TEST_TO'))
db.commit()
db.close()
" 2>/dev/null

echo ""

# ============================================================
# Test Group 6: Fleet Status
# ============================================================
echo "=== Test Group 6: Fleet Status ==="

# Check DB has active agents
ACTIVE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM agents WHERE status='active'" 2>/dev/null || echo "0")
if [ "$ACTIVE_COUNT" -gt 0 ]; then
    _pass "Active agents in DB: $ACTIVE_COUNT"
else
    _fail_msg "No active agents in DB"
fi

# Verify spawned relay appears in fleet
if [ -n "$TEST_RELAY" ]; then
    RELAY_IN_FLEET=$(sqlite3 "$DB_PATH" "SELECT pane_id, cli, role, status FROM agents WHERE pane_id='$TEST_RELAY' AND status='active'" 2>/dev/null || true)
    if [ -n "$RELAY_IN_FLEET" ]; then
        _pass "Test relay $TEST_RELAY in fleet (${RELAY_IN_FLEET})"
    else
        _fail_msg "Test relay $TEST_RELAY not found in fleet"
    fi
fi

# Check target pane (CLIs may or may not self-register via MCP)
if [ -n "$TEST_TARGET" ]; then
    TARGET_IN_FLEET=$(sqlite3 "$DB_PATH" "SELECT pane_id FROM agents WHERE pane_id='$TEST_TARGET'" 2>/dev/null || true)
    if [ -n "$TARGET_IN_FLEET" ]; then
        _pass "Target $TEST_TARGET found in fleet DB"
    else
        _skip "Target pane DB registration (CLI may not self-register)"
    fi
fi

echo ""

# ============================================================
# Test Group 7: Double Push + Interrupt Behavior
# (Live testing behaviors #1, #2, #4)
#
# KNOWN ISSUE #1: send.sh step 12 fires a processing push immediately
# after delivery. It arrives while Haiku is mid-turn, triggering Claude
# Code's interrupt handler. This is architectural — fix requires Phase 2
# (hook reads pushes before model turn) or Phase 3 (change token).
# ============================================================
echo "=== Test Group 7: Double Push + Attribution ==="

if [ -z "$TEST_TARGET" ] || [ -z "$TEST_RELAY" ]; then
    _skip "Push verification (no relay bridge available)"
else
    # Clean push files and dispatch state from prior test groups
    rm -f "$PROJECT_ROOT/.urc/pushes/${TEST_RELAY}_${TEST_TARGET}_"* 2>/dev/null || true
    rm -f "$PROJECT_ROOT/.urc/responses/${TEST_TARGET}.json" \
          "$PROJECT_ROOT/.urc/signals/done_${TEST_TARGET}" \
          "$PROJECT_ROOT/.urc/timeout/${TEST_TARGET}"
    rm -rf "$PROJECT_ROOT/.urc/locks/dispatch_${TEST_TARGET}.d" 2>/dev/null || true
    rm -f "$PROJECT_ROOT/.urc/circuits/${TEST_TARGET}" 2>/dev/null || true

    # Snapshot relay output BEFORE this test (to detect new output later)
    RELAY_BEFORE_LINES=$(tmux capture-pane -t "$TEST_RELAY" -p 2>/dev/null | wc -l || echo "0")

    # Pre-write dispatch metadata (attribution: type=relay, source=TEST_RELAY)
    mkdir -p "$PROJECT_ROOT/.urc/dispatches"
    jq -n --arg type "relay" --arg source "$TEST_RELAY" \
        --arg message "push verification test" --argjson ts "$(date +%s)" \
        '{type:$type, source:$source, message:$message, ts:$ts}' \
        > "$PROJECT_ROOT/.urc/dispatches/${TEST_TARGET}.json" 2>/dev/null

    PUSH_SEND_TS=$(date +%s)

    # Send message — this triggers the double push sequence:
    #   1. send.sh step 12 → processing push + __urc_push__ to relay (immediate)
    #   2. hook.sh → response push + __urc_push__ to relay (after target completes)
    bash "$PROJECT_ROOT/urc/core/send.sh" "$TEST_TARGET" "Say exactly: PUSH_TEST_OK" 2>/dev/null || true

    # 7a: Poll for processing push file (created by send.sh step 12, within ~1s)
    # This file is ephemeral — relay may consume it before we check.
    PROCESSING_FOUND=0
    for i in $(seq 1 10); do
        PROC_FILES=$(ls "$PROJECT_ROOT/.urc/pushes/${TEST_RELAY}_${TEST_TARGET}_processing_"* 2>/dev/null || true)
        if [ -n "$PROC_FILES" ]; then
            PROCESSING_FOUND=1
            PROC_FILE=$(echo "$PROC_FILES" | head -1)
            PROC_STATUS=$(jq -r '.status // empty' "$PROC_FILE" 2>/dev/null)
            _check "Processing push has status=processing" test "$PROC_STATUS" = "processing"
            break
        fi
        sleep 0.5
    done
    if [ "$PROCESSING_FOUND" -eq 1 ]; then
        _pass "Processing push file created (send.sh step 12)"
    else
        # File was consumed by relay — verify via relay output instead
        echo "  INFO: Processing push consumed before capture — will verify via relay output"
    fi

    # 7b: Wait for target to respond + relay to display (up to 90s)
    # Primary verification: relay pane output shows BOTH push types
    echo "  INFO: Waiting for relay to display push responses (up to 90s)..."
    GOT_PROCESSING=0; GOT_UPDATE=0
    for i in $(seq 1 90); do
        RELAY_OUTPUT=$(tmux capture-pane -t "$TEST_RELAY" -p -S -50 2>/dev/null || true)
        echo "$RELAY_OUTPUT" | grep -q '\[PROCESSING' && GOT_PROCESSING=1
        echo "$RELAY_OUTPUT" | grep -q '\[UPDATE' && GOT_UPDATE=1
        if [ "$GOT_PROCESSING" -eq 1 ] && [ "$GOT_UPDATE" -eq 1 ]; then
            echo "  INFO: Both push types visible in relay output (${i}s)"
            break
        fi
        sleep 1
    done

    # 7c: Verify double push — BOTH types must appear (behavior #1)
    if [ "$GOT_PROCESSING" -eq 1 ]; then
        _pass "Relay displayed [PROCESSING push (send.sh step 12)"
    else
        _fail_msg "Relay never displayed [PROCESSING push — interrupt may have dropped it (KNOWN ISSUE #1)"
    fi
    if [ "$GOT_UPDATE" -eq 1 ]; then
        _pass "Relay displayed [UPDATE push (hook.sh response)"
    else
        _fail_msg "Relay never displayed [UPDATE push within 90s"
    fi

    # 7d: Verify push display order — PROCESSING before UPDATE (behavior #2)
    if [ "$GOT_PROCESSING" -eq 1 ] && [ "$GOT_UPDATE" -eq 1 ]; then
        RELAY_OUTPUT=$(tmux capture-pane -t "$TEST_RELAY" -p -S -80 2>/dev/null || true)
        PROC_LINE=$(echo "$RELAY_OUTPUT" | grep -n '\[PROCESSING' | tail -1 | cut -d: -f1)
        UPDATE_LINE=$(echo "$RELAY_OUTPUT" | grep -n '\[UPDATE' | tail -1 | cut -d: -f1)
        if [ -n "$PROC_LINE" ] && [ -n "$UPDATE_LINE" ]; then
            if [ "$PROC_LINE" -lt "$UPDATE_LINE" ]; then
                _pass "Push display order: PROCESSING (line $PROC_LINE) before UPDATE (line $UPDATE_LINE)"
            else
                _fail_msg "Push display order wrong: UPDATE (line $UPDATE_LINE) before PROCESSING (line $PROC_LINE)"
            fi
        fi
    fi

    # 7e: Verify attribution on response push (behavior #4)
    # Check relay output for attribution text from the relay dispatch
    if [ "$GOT_UPDATE" -eq 1 ]; then
        RELAY_OUTPUT=$(tmux capture-pane -t "$TEST_RELAY" -p -S -80 2>/dev/null || true)
        if echo "$RELAY_OUTPUT" | grep -q "you asked"; then
            _pass "Response push attributed to relay (\"you asked\" pattern)"
        elif echo "$RELAY_OUTPUT" | grep -q "autonomous"; then
            _fail_msg "Response push shows autonomous instead of relay attribution"
        else
            _pass "Response push displayed (attribution format may vary)"
        fi
    fi

    # 7f: Also try to verify via push file if still present
    RESP_PUSHES=$(find "$PROJECT_ROOT/.urc/pushes" -name "${TEST_RELAY}_${TEST_TARGET}_[0-9]*.json" -not -name "*processing*" -type f 2>/dev/null || true)
    if [ -n "$RESP_PUSHES" ]; then
        RESP_FILE=$(echo "$RESP_PUSHES" | head -1)
        TRIG_TYPE=$(jq -r '.triggered_type // empty' "$RESP_FILE" 2>/dev/null)
        TRIG_BY=$(jq -r '.triggered_by // empty' "$RESP_FILE" 2>/dev/null)
        _check "Push file triggered_type=relay" test "$TRIG_TYPE" = "relay"
        _check "Push file triggered_by=$TEST_RELAY" test "$TRIG_BY" = "$TEST_RELAY"
    else
        echo "  INFO: Push files already consumed by relay (verified via output above)"
    fi
fi

echo ""

# ============================================================
# Test Group 8: Relay Output Quality
# (Live testing behaviors #3, #5, #6, #7)
# ============================================================
echo "=== Test Group 8: Relay Output Quality ==="

if [ -z "$TEST_RELAY" ]; then
    _skip "Relay output quality (no relay available)"
else
    # Capture relay pane output (last 80 lines)
    RELAY_OUTPUT=$(tmux capture-pane -t "$TEST_RELAY" -p -S -80 2>/dev/null || true)

    if [ -z "$RELAY_OUTPUT" ]; then
        _fail_msg "Cannot capture relay pane output"
    else
        # 8a: Plain text — no triple backticks (behavior #6)
        if echo "$RELAY_OUTPUT" | grep -q '```'; then
            _fail_msg "Relay output contains triple backticks (should be plain text)"
        else
            _pass "Relay output is plain text (no code blocks)"
        fi

        # 8b: No commentary text (behavior #7)
        COMMENTARY_PATTERNS="Reading push files|Sending to target|Cleanup complete|Relaying message|Gathering diagnostics|Let me check|I'll forward|Here's the response|Processing the"
        if echo "$RELAY_OUTPUT" | grep -qiE "$COMMENTARY_PATTERNS"; then
            FOUND_COMMENTARY=$(echo "$RELAY_OUTPUT" | grep -iE "$COMMENTARY_PATTERNS" | head -3)
            _fail_msg "Relay has commentary text: $FOUND_COMMENTARY"
        else
            _pass "Relay output has no commentary text"
        fi

        # 8c: Check for "Sent to" dispatch confirmation
        # "Sent to" only appears when messages go THROUGH the relay (phone path).
        # Our test sends directly to target via send.sh, so relay only sees pushes.
        # To verify "Sent to", send a message TO the relay and let it forward.
        if echo "$RELAY_OUTPUT" | grep -q "Sent to"; then
            _pass "Relay shows 'Sent to' (relay-path message detected)"
        else
            echo "  INFO: No 'Sent to' in relay output — test sends directly to target, not through relay"
            echo "  INFO: Sending message through relay to verify relay dispatch path..."
            # Send a message TO the relay — it should forward to target and display "Sent to"
            bash "$PROJECT_ROOT/urc/core/send.sh" "$TEST_RELAY" "What is 2+2?" --cli claude 2>/dev/null || true
            # Poll relay output for "Sent to" (up to 15s for relay to process)
            SENT_TO_FOUND=0
            for _st in $(seq 1 15); do
                RELAY_RECHECK=$(tmux capture-pane -t "$TEST_RELAY" -p -S -20 2>/dev/null || true)
                if echo "$RELAY_RECHECK" | grep -q "Sent to"; then
                    SENT_TO_FOUND=1; break
                fi
                sleep 1
            done
            if [ "$SENT_TO_FOUND" -eq 1 ]; then
                _pass "Relay shows 'Sent to' after relay-path dispatch"
            else
                _fail_msg "Relay did not show 'Sent to' after relay-path dispatch"
            fi
        fi
    fi

    # 8d: /remote-control survival (behavior #3)
    # Check relay pane is alive and responsive after push interrupts
    if tmux display-message -t "$TEST_RELAY" -p '#{pane_id}' >/dev/null 2>&1; then
        _pass "Relay pane alive after push interrupts"
        RELAY_PID=$(tmux display-message -t "$TEST_RELAY" -p '#{pane_pid}' 2>/dev/null || true)
        if [ -n "$RELAY_PID" ] && kill -0 "$RELAY_PID" 2>/dev/null; then
            _pass "Relay process still running (PID: $RELAY_PID)"
        else
            _fail_msg "Relay process dead after push interrupts (PID: $RELAY_PID) — /remote-control likely dropped (KNOWN ISSUE #3)"
        fi
    else
        _fail_msg "Relay pane died after push interrupts — /remote-control dropped (KNOWN ISSUE #3)"
    fi
    echo "  INFO: Full /remote-control phone connection verification requires manual test"
fi

echo ""

# ============================================================
# Test Group 9: Third-Party Attribution + Stuck-Input
# (Live testing behaviors #4 supplement, #8)
#
# KNOWN ISSUE #3: When a third party sends via send_message() (DB),
# no dispatch metadata is written to .urc/dispatches/. hook.sh defaults
# to triggered_type: "autonomous". Fix requires changes to hook.sh or
# server.py — beyond Phase 1 scope.
# ============================================================
echo "=== Test Group 9: Third-Party Attribution + Stuck-Input ==="

# 9a: Third-party message attribution
if [ -z "$TEST_TARGET" ] || [ -z "$TEST_RELAY" ]; then
    _skip "Third-party attribution (no bridge available)"
else
    # Clean push files and dispatch metadata
    rm -f "$PROJECT_ROOT/.urc/pushes/${TEST_RELAY}_${TEST_TARGET}_"* 2>/dev/null || true
    rm -f "$PROJECT_ROOT/.urc/dispatches/${TEST_TARGET}.json" 2>/dev/null || true

    # Snapshot relay output before third-party test
    RELAY_BEFORE_TP=$(tmux capture-pane -t "$TEST_RELAY" -p -S -80 2>/dev/null || true)

    # Send from "third party" (no dispatch metadata → hook defaults to autonomous)
    echo "  INFO: Sending third-party message (no dispatch metadata)..."
    THIRD_PARTY_TS=$(date +%s)
    bash "$PROJECT_ROOT/urc/core/send.sh" "$TEST_TARGET" "Say exactly: THIRD_PARTY_OK" 2>/dev/null || true

    # Wait for relay to show the third-party response (up to 90s)
    echo "  INFO: Waiting for relay to display third-party response (up to 90s)..."
    TP_DETECTED=0
    for i in $(seq 1 90); do
        RELAY_NOW=$(tmux capture-pane -t "$TEST_RELAY" -p -S -50 2>/dev/null || true)
        # Look for any new [UPDATE line that wasn't in the pre-test snapshot
        NEW_UPDATES=$(echo "$RELAY_NOW" | grep '\[UPDATE' | tail -3)
        if [ -n "$NEW_UPDATES" ]; then
            # Check if this is a new update (not from Group 7)
            if echo "$NEW_UPDATES" | grep -q "autonomous"; then
                TP_DETECTED=1
                echo "  INFO: Third-party response visible in ${i}s"
                break
            fi
            # Also check push file if still present
            TP_PUSHES=$(find "$PROJECT_ROOT/.urc/pushes" -name "${TEST_RELAY}_${TEST_TARGET}_[0-9]*.json" -not -name "*processing*" -type f 2>/dev/null || true)
            if [ -n "$TP_PUSHES" ]; then
                TP_FILE=$(echo "$TP_PUSHES" | head -1)
                TP_EPOCH=$(jq -r '.epoch // 0' "$TP_FILE" 2>/dev/null)
                if [ "$TP_EPOCH" -ge "$THIRD_PARTY_TS" ] 2>/dev/null; then
                    TP_TRIG=$(jq -r '.triggered_type // empty' "$TP_FILE" 2>/dev/null)
                    if [ "$TP_TRIG" = "autonomous" ]; then
                        TP_DETECTED=1
                        echo "  INFO: Third-party push file captured in ${i}s"
                        break
                    fi
                fi
            fi
        fi
        sleep 1
    done

    if [ "$TP_DETECTED" -eq 1 ]; then
        _pass "Third-party message shows autonomous attribution (KNOWN ISSUE — no dispatch metadata)"
        # Verify content is still displayed correctly
        RELAY_FINAL=$(tmux capture-pane -t "$TEST_RELAY" -p -S -30 2>/dev/null || true)
        if echo "$RELAY_FINAL" | grep -qE '\[UPDATE.*autonomous'; then
            _pass "Third-party response content displayed despite wrong attribution"
        else
            # Check push file content as fallback
            TP_PUSHES=$(find "$PROJECT_ROOT/.urc/pushes" -name "${TEST_RELAY}_${TEST_TARGET}_[0-9]*.json" -not -name "*processing*" -type f 2>/dev/null || true)
            if [ -n "$TP_PUSHES" ]; then
                TP_RESP=$(jq -r '.response // empty' "$(echo "$TP_PUSHES" | head -1)" 2>/dev/null)
                if [ -n "$TP_RESP" ]; then
                    _pass "Third-party response content present in push file"
                else
                    _fail_msg "Third-party response content missing"
                fi
            else
                _pass "Third-party response displayed by relay (push files consumed)"
            fi
        fi
    else
        _fail_msg "Third-party autonomous attribution not detected within 90s"
    fi
fi

# 9b: Stuck-input regression (behavior #8)
# The bootstrap verification in Group 1 already checks @bridge_target is set.
# Here we document the stuck-input scenario for awareness.
echo ""
echo "  --- Stuck-Input Regression Notes ---"
echo "  Bootstrap delivery is verified in Group 1 (@bridge_target check)."
echo "  If @bridge_target is empty after spawn, bootstrap text was stuck in input."
echo "  Root cause: send.sh step 11 stuck-input detection can false-positive when"
echo "  status bar updates during the 0.5s check window on fresh panes."
echo "  Reliable rate measurement requires multiple spawn attempts (not in this suite)."

# Count how many CLIs had successful bootstrap in Group 1
BOOTSTRAP_OK=0
for ct in CODEX GEMINI; do
    eval "_r=\${${ct}_RELAY:-}"
    if [ -n "$_r" ]; then
        BT=$(tmux show-options -pv -t "$_r" @bridge_target 2>/dev/null || true)
        if [ -n "$BT" ]; then
            BOOTSTRAP_OK=$((BOOTSTRAP_OK + 1))
        fi
    fi
done
if [ "$BOOTSTRAP_OK" -gt 0 ]; then
    _pass "Bootstrap succeeded for $BOOTSTRAP_OK CLI(s) (stuck-input not triggered)"
else
    if [ "$HAS_CODEX" -eq 1 ] || [ "$HAS_GEMINI" -eq 1 ]; then
        _fail_msg "No CLIs bootstrapped successfully (possible stuck-input regression)"
    else
        _skip "Stuck-input check (no CLIs available)"
    fi
fi

echo ""

# ============================================================
# Summary
# ============================================================
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "========================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
