#!/usr/bin/env bash
# dispatch-and-wait.sh — Atomic dispatch + wait + read composite
#
# Usage: dispatch-and-wait.sh <pane_id> <message> [timeout] [--skip-dispatch]
#
# Atomically: acquires lock -> dispatches via tmux-send-helper.sh ->
# blocks on tmux wait-for until target completes -> reads response file ->
# outputs structured JSON on stdout.
#
# All debug output goes to stderr. stdout is ONLY structured JSON.

set -uo pipefail

PANE="${1:?Usage: dispatch-and-wait.sh <pane_id> <message> [timeout] [--skip-dispatch]}"
MESSAGE="${2:?Usage: dispatch-and-wait.sh <pane_id> <message> [timeout] [--skip-dispatch]}"
TIMEOUT="${3:-120}"
SKIP_DISPATCH=0
[ "${4:-}" = "--skip-dispatch" ] && SKIP_DISPATCH=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/tmux-send-helper.sh"

RESPONSE_DIR="$PROJECT_ROOT/.urc/responses"
SIGNAL_DIR="$PROJECT_ROOT/.urc/signals"
LOCK_DIR="$PROJECT_ROOT/.urc/locks"
TIMEOUT_DIR="$PROJECT_ROOT/.urc/timeout"
mkdir -p "$RESPONSE_DIR" "$SIGNAL_DIR" "$LOCK_DIR" "$TIMEOUT_DIR"

SIGNAL_FILE="$SIGNAL_DIR/done_${PANE}"
RESPONSE_FILE="$RESPONSE_DIR/${PANE}.json"
TIMEOUT_SENTINEL="$TIMEOUT_DIR/${PANE}"
LOCK_DIR_PATH="$LOCK_DIR/${PANE}.d"
WAIT_CHANNEL="urc_done_${PANE}"

START_MS=$(($(date +%s) * 1000))
DISPATCH_TS="${URC_DISPATCH_TS:-$(date +%s)}"

# ── Output helper ────────────────────────────────────────────────
_result() {
    local status="$1" response_text="${2:-}" cli="${3:-}" source="${4:-}"
    local now_ms=$(($(date +%s) * 1000))
    local latency_ms=$((now_ms - START_MS))
    jq -n \
        --arg status "$status" \
        --arg response_text "$response_text" \
        --arg pane_id "$PANE" \
        --arg cli "$cli" \
        --arg source "$source" \
        --argjson latency_ms "$latency_ms" \
        '{status:$status, response_text:$response_text, pane_id:$pane_id, cli:$cli, source:$source, latency_ms:$latency_ms}'
}

# ── Read response file ───────────────────────────────────────────
_read_response() {
    if [ -f "$RESPONSE_FILE" ]; then
        local resp_epoch resp_text resp_cli
        resp_epoch=$(jq -r '.epoch // 0' "$RESPONSE_FILE" 2>/dev/null)
        resp_text=$(jq -r '.response // empty' "$RESPONSE_FILE" 2>/dev/null)
        resp_cli=$(jq -r '.cli // "unknown"' "$RESPONSE_FILE" 2>/dev/null)

        # Timestamp correlation: reject stale responses
        if [ "$resp_epoch" -gt "$DISPATCH_TS" ] 2>/dev/null; then
            _result "completed" "$resp_text" "$resp_cli" "response_file"
            return 0
        else
            echo "stale:$resp_epoch <= $DISPATCH_TS" >&2
            return 1
        fi
    fi
    return 1
}

# ── Fallback: tmux capture-pane ──────────────────────────────────
_capture_fallback() {
    local captured
    captured=$(tmux capture-pane -t "$PANE" -p -S -80 2>/dev/null || true)
    if [ -n "$captured" ]; then
        _result "timeout" "$captured" "" "pane_capture"
    else
        _result "timeout" "" "" "none"
    fi
}

# ── Acquire lock (mkdir-based, POSIX compatible) ─────────────────
if ! mkdir "$LOCK_DIR_PATH" 2>/dev/null; then
    # Check for stale lock (older than 5 minutes)
    if [ -d "$LOCK_DIR_PATH" ]; then
        _LOCK_AGE=$(( $(date +%s) - $(stat -f%m "$LOCK_DIR_PATH" 2>/dev/null || stat -c%Y "$LOCK_DIR_PATH" 2>/dev/null || echo 0) ))
        if [ "$_LOCK_AGE" -gt 300 ]; then
            rmdir "$LOCK_DIR_PATH" 2>/dev/null && mkdir "$LOCK_DIR_PATH" 2>/dev/null
            if [ $? -ne 0 ]; then
                _result "busy" "" "" ""
                exit 0
            fi
        else
            _result "busy" "" "" ""
            exit 0
        fi
    fi
fi

# ── Cleanup on exit ──────────────────────────────────────────────
WATCHDOG_PID=""
_cleanup() {
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null; wait "$WATCHDOG_PID" 2>/dev/null
    rm -f "$TIMEOUT_SENTINEL"
    rmdir "$LOCK_DIR_PATH" 2>/dev/null
}
trap _cleanup EXIT

# ── Dispatch (unless --skip-dispatch) ────────────────────────────
if [ "$SKIP_DISPATCH" -eq 0 ]; then
    rm -f "$SIGNAL_FILE" "$RESPONSE_FILE" "$TIMEOUT_SENTINEL"
    DISPATCH_TS=$(date +%s)

    DISPATCH_OUT=$(bash "$HELPER" "$PANE" "$MESSAGE" --force --no-verify 2>/dev/null)
    DISPATCH_STATUS=$(echo "$DISPATCH_OUT" | jq -r '.status // "unknown"' 2>/dev/null)

    if [ "$DISPATCH_STATUS" = "failed" ]; then
        _result "dispatch_failed" "" "" ""
        exit 0
    fi
fi

# ── Pre-check: signal may already exist ──────────────────────────
if [ -f "$SIGNAL_FILE" ]; then
    if _read_response; then
        rm -f "$SIGNAL_FILE" "$TIMEOUT_SENTINEL"
        exit 0
    fi
fi

# ── Wait: tmux wait-for with timeout via background watchdog ─────
# Background watchdog: after $TIMEOUT seconds, creates sentinel + signals channel
(
    sleep "$TIMEOUT"
    touch "$TIMEOUT_SENTINEL"
    tmux wait-for -S "$WAIT_CHANNEL" 2>/dev/null
) &
WATCHDOG_PID=$!

# Block until the channel is signaled (by hook or watchdog)
while true; do
    tmux wait-for "$WAIT_CHANNEL" 2>/dev/null || true

    # Check: real completion or timeout?
    if [ -f "$SIGNAL_FILE" ]; then
        if _read_response; then
            rm -f "$SIGNAL_FILE" "$TIMEOUT_SENTINEL"
            exit 0
        fi
        # Stale response — clear signal and wait again
        rm -f "$SIGNAL_FILE"
    fi

    # Timeout sentinel?
    if [ -f "$TIMEOUT_SENTINEL" ]; then
        # Check response file one last time (hook may have fired between checks)
        if [ -f "$SIGNAL_FILE" ] && _read_response; then
            rm -f "$SIGNAL_FILE" "$TIMEOUT_SENTINEL"
            exit 0
        fi
        _capture_fallback
        exit 0
    fi

    # Spurious wake — loop back to wait
done
