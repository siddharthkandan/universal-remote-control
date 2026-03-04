#!/usr/bin/env bash
# dispatch-watch.sh — PostToolUse hook: track dispatch_to_pane calls and
# nag agents who forget to poll for completion.
#
# After a successful dispatch, creates a tracking file and injects a reminder
# with exact poll + read commands. On subsequent tool calls, nags if the agent
# hasn't called read_pane_output for the dispatched pane. Self-cleans when
# read_pane_output is called or after 10 minutes.
#
# Tracking files: .urc/dispatch-pending/{PANE_ID_NO_PERCENT}
#   Line 1: {TIMESTAMP} {FROM_PANE} {MESSAGE_PREVIEW}
#   Line 2 (after nag): nag {LAST_NAG_TS} {NAG_COUNT}

# ─── Self-test mode ─────────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
    TEST_DIR=$(mktemp -d)
    PASS=0; FAIL=0

    # Test 1: tracking file created on successful dispatch
    mkdir -p "$TEST_DIR/.urc/dispatch-pending"
    echo '{"tool_name":"mcp__urc-coordination__dispatch_to_pane","tool_input":{"pane_id":"%856","message":"test message"},"tool_response":{"status":"delivered"}}' | \
        CLAUDE_PROJECT_DIR="$TEST_DIR" TMUX_PANE="%907" bash "$0"
    if [ -f "$TEST_DIR/.urc/dispatch-pending/856" ]; then
        echo "PASS: tracking file created"; PASS=$((PASS+1))
    else
        echo "FAIL: no tracking file"; FAIL=$((FAIL+1))
    fi

    # Test 2: read_pane_output clears tracking
    echo '{"tool_name":"mcp__urc-coordination__read_pane_output","tool_input":{"pane_id":"%856","lines":30}}' | \
        CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$0"
    if [ ! -f "$TEST_DIR/.urc/dispatch-pending/856" ]; then
        echo "PASS: tracking file cleared"; PASS=$((PASS+1))
    else
        echo "FAIL: tracking file not cleared"; FAIL=$((FAIL+1))
    fi

    # Test 3: failed dispatch not tracked
    echo '{"tool_name":"mcp__urc-coordination__dispatch_to_pane","tool_input":{"pane_id":"%999","message":"test"},"tool_response":{"status":"failed"}}' | \
        CLAUDE_PROJECT_DIR="$TEST_DIR" TMUX_PANE="%907" bash "$0"
    if [ ! -f "$TEST_DIR/.urc/dispatch-pending/999" ]; then
        echo "PASS: failed dispatch not tracked"; PASS=$((PASS+1))
    else
        echo "FAIL: failed dispatch tracked"; FAIL=$((FAIL+1))
    fi

    # Test 4: stale tracking file auto-expires
    echo "0 %907 ancient message" > "$TEST_DIR/.urc/dispatch-pending/100"
    echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | \
        CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$0" >/dev/null 2>&1
    if [ ! -f "$TEST_DIR/.urc/dispatch-pending/100" ]; then
        echo "PASS: stale file expired"; PASS=$((PASS+1))
    else
        echo "FAIL: stale file not expired"; FAIL=$((FAIL+1))
    fi

    rm -rf "$TEST_DIR"
    echo "Self-test: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ─── Configuration ──────────────────────────────────────────────────────
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PENDING_DIR="$PROJECT_DIR/.urc/dispatch-pending"
NOW=$(date +%s)
MAX_AGE=600         # 10 minutes — auto-expire stale tracking files
NAG_COOLDOWN=30     # seconds between nags per pane
GRACE_PERIOD=5      # seconds after dispatch before nagging starts

# ─── Fast path: no pending dir + check tool name before full parse ──────
HAS_PENDING=false
if [ -d "$PENDING_DIR" ]; then
    for f in "$PENDING_DIR"/*; do
        [ -f "$f" ] && HAS_PENDING=true && break
    done
fi

# Read stdin (required by hook protocol)
INPUT=$(cat)

# Extract tool name
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Classify tool type by suffix match
case "$TOOL_NAME" in
    *dispatch_to_pane) TOOL_TYPE="dispatch" ;;
    *read_pane_output) TOOL_TYPE="read" ;;
    *)                 TOOL_TYPE="other" ;;
esac

# Fast exit: not dispatch, not read, no pending dispatches
if [ "$TOOL_TYPE" = "other" ] && [ "$HAS_PENDING" = "false" ]; then
    exit 0
fi

# ─── DISPATCH: create tracking file + inject reminder ───────────────────
if [ "$TOOL_TYPE" = "dispatch" ]; then
    PANE_ID=$(echo "$INPUT" | jq -r '.tool_input.pane_id // empty' 2>/dev/null)
    [ -z "$PANE_ID" ] && exit 0

    # Check delivery status — only track successful dispatches
    STATUS=$(echo "$INPUT" | jq -r '.tool_response.status // empty' 2>/dev/null)
    case "$STATUS" in
        delivered|uncertain) ;;
        "") ;;   # tool_response unavailable — still track (conservative)
        *) exit 0 ;;  # failed/queued — nothing to follow up on
    esac

    # Strip % for tracking filename
    PANE_BARE="${PANE_ID#%}"

    # Validate pane ID format
    if ! echo "$PANE_BARE" | grep -qE '^[0-9]+$'; then
        exit 0  # silently skip malformed pane IDs
    fi

    mkdir -p "$PENDING_DIR" 2>/dev/null

    MY_PANE="${TMUX_PANE:-unknown}"
    MSG_PREVIEW=$(echo "$INPUT" | jq -r '.tool_input.message // ""' 2>/dev/null | head -c 80)

    # Write tracking file
    echo "$NOW $MY_PANE $MSG_PREVIEW" > "$PENDING_DIR/$PANE_BARE"

    # Inject follow-up reminder with exact commands
    STATUS_DISPLAY="${STATUS:-delivered}"
    jq -n --arg pane "$PANE_ID" --arg status "$STATUS_DISPLAY" '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: (
                "DISPATCH SENT to " + $pane + " (status: " + $status + "). REQUIRED NEXT STEPS:\n" +
                "1. Clear signal file: rm -f .urc/signals/done_" + $pane + "\n" +
                "2. Poll for completion (Bash with run_in_background=true):\n" +
                "   ELAPSED=0; while [ ! -f .urc/signals/done_" + $pane + " ] && [ $ELAPSED -lt 120 ]; do sleep 2; ELAPSED=$((ELAPSED+2)); done; [ -f .urc/signals/done_" + $pane + " ] && echo DONE || echo TIMEOUT\n" +
                "3. When poll completes (or on timeout): read_pane_output(pane_id=\"" + $pane + "\", lines=100)\n" +
                "Do NOT move on to other work without reading the target pane response. Timeout is NOT fatal — always read output."
            )
        }
    }'
    exit 0
fi

# ─── READ: clear tracking file (dispatch fulfilled) ─────────────────────
if [ "$TOOL_TYPE" = "read" ]; then
    PANE_ID=$(echo "$INPUT" | jq -r '.tool_input.pane_id // empty' 2>/dev/null)
    if [ -n "$PANE_ID" ]; then
        PANE_BARE="${PANE_ID#%}"
        # Validate pane ID format
        if ! echo "$PANE_BARE" | grep -qE '^[0-9]+$'; then
            exit 0
        fi
        rm -f "$PENDING_DIR/$PANE_BARE" 2>/dev/null
    fi
    exit 0
fi

# ─── OTHER TOOL: check for unfulfilled dispatches and nag ───────────────
NAGS=""
NAG_PANES=""

for f in "$PENDING_DIR"/*; do
    [ -f "$f" ] || continue

    PANE_BARE=$(basename "$f")

    # Read first line: timestamp sender preview
    read -r TRACK_TS TRACK_FROM TRACK_MSG < "$f" 2>/dev/null
    [ -z "$TRACK_TS" ] && { rm -f "$f"; continue; }

    # Age check
    AGE=$((NOW - TRACK_TS))

    # Auto-expire stale tracking files (10 min)
    if [ "$AGE" -gt "$MAX_AGE" ]; then
        rm -f "$f"
        continue
    fi

    # Grace period — don't nag within first few seconds
    [ "$AGE" -lt "$GRACE_PERIOD" ] && continue

    # Read nag state from second line (if exists)
    LAST_NAG_TS=0
    NAG_TALLY=0
    LINE_COUNT=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    if [ "$LINE_COUNT" -gt 1 ]; then
        NAG_LINE=$(sed -n '2p' "$f" 2>/dev/null)
        LAST_NAG_TS=$(echo "$NAG_LINE" | awk '{print $2}')
        NAG_TALLY=$(echo "$NAG_LINE" | awk '{print $3}')
        LAST_NAG_TS="${LAST_NAG_TS:-0}"
        NAG_TALLY="${NAG_TALLY:-0}"
    fi

    # Throttle: don't re-nag within cooldown
    NAG_ELAPSED=$((NOW - LAST_NAG_TS))
    [ "$NAG_ELAPSED" -lt "$NAG_COOLDOWN" ] && continue

    # Build nag for this pane
    PANE_WITH_PCT="%${PANE_BARE}"
    NAGS="${NAGS}Pane ${PANE_WITH_PCT} (dispatched ${AGE}s ago). "
    NAG_PANES="${NAG_PANES}${PANE_WITH_PCT} "

    # Update nag state
    NEW_TALLY=$((NAG_TALLY + 1))
    FIRST_LINE=$(head -1 "$f")
    printf '%s\nnag %s %s\n' "$FIRST_LINE" "$NOW" "$NEW_TALLY" > "$f"
done

# No nags needed
[ -z "$NAGS" ] && exit 0

# Build the full nag message
NAG_MSG="PENDING DISPATCH REMINDER: You dispatched work but never read the result. ${NAGS}Call read_pane_output for each pending pane NOW to see their responses."

jq -n --arg msg "$NAG_MSG" '{
    hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $msg
    }
}'
exit 0
