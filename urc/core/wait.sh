#!/usr/bin/env bash
# wait.sh — Block until a pane completes its turn, then return the response.
#
# Usage: bash urc/core/wait.sh <pane_id> [timeout_seconds]
# Stdout: {"status":"completed","response":"...","cli":"...","latency_s":42}
#         {"status":"timeout","captured":"..."}
# Exit:   0 = completed, 1 = timeout
#
# All debug output goes to stderr. stdout is ONLY structured JSON.

set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

PANE="${1:?Usage: wait.sh <pane_id> [timeout_seconds] [dispatch_ts]}"
TIMEOUT="${2:-120}"
DISPATCH_TS_ARG="${3:-}"

# ── Pane ID validation ─────────────────────────────────────────
[[ "$PANE" =~ ^%[0-9]+$ ]] || { jq -n --arg pane "$PANE" '{status:"failed",pane:$pane,error:"invalid pane ID format"}'; exit 1; }

# ── Paths ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RESPONSE_FILE="$PROJECT_ROOT/.urc/responses/${PANE}.json"
SIGNAL_FILE="$PROJECT_ROOT/.urc/signals/done_${PANE}"
CANCEL_SENTINEL="$PROJECT_ROOT/.urc/signals/cancel_${PANE}"
TIMEOUT_SENTINEL="$PROJECT_ROOT/.urc/timeout/${PANE}"
WAIT_CHANNEL="urc_done_${PANE}"

mkdir -p "$PROJECT_ROOT/.urc/responses" "$PROJECT_ROOT/.urc/signals" "$PROJECT_ROOT/.urc/timeout"

# Clear any stale cancel sentinel from a prior cancelled dispatch
rm -f "$CANCEL_SENTINEL"

DISPATCH_TS="${DISPATCH_TS_ARG:-$(date +%s)}"
# Don't clear signal file — epoch check handles staleness.
# Clearing here races with fast responses (hook fires before wait.sh starts).

# ── Try to read a fresh response; emit JSON + exit 0 on success ──
_try_read_response() {
    [ -f "$RESPONSE_FILE" ] || return 1
    local raw
    raw=$(< "$RESPONSE_FILE")
    local epoch; epoch=$(printf '%s' "$raw" | jq -r '.epoch // 0' 2>/dev/null)
    [ "$epoch" -ge "$DISPATCH_TS" ] 2>/dev/null || {
        echo "stale response: epoch $epoch < dispatch $DISPATCH_TS" >&2
        rm -f "$SIGNAL_FILE"
        return 1
    }
    local text cli now latency
    text=$(printf '%s' "$raw" | jq -r '.response // empty' 2>/dev/null)
    cli=$(printf '%s' "$raw" | jq -r '.cli // "unknown"' 2>/dev/null)
    now=$(date +%s); latency=$((now - DISPATCH_TS))
    rm -f "$SIGNAL_FILE" "$TIMEOUT_SENTINEL"
    jq -n --arg status "completed" --arg response "$text" \
          --arg pane "$PANE" --arg cli "$cli" --argjson latency_s "$latency" \
          '{status:$status, response:$response, pane:$pane, cli:$cli, latency_s:$latency_s}'
    exit 0
}

# ── Watchdog: unblocks wait channel after timeout ────────────────
WATCHDOG_PID=""
SELFWAKE_PID=""
_cleanup() {
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null; wait "$WATCHDOG_PID" 2>/dev/null
    [ -n "$SELFWAKE_PID" ] && kill "$SELFWAKE_PID" 2>/dev/null; wait "$SELFWAKE_PID" 2>/dev/null
    rm -f "$TIMEOUT_SENTINEL" "$CANCEL_SENTINEL"
}
trap _cleanup EXIT

# NOTE: >/dev/null disconnects background subshells from stdout pipe.
# Without this, command substitution $(bash wait.sh ...) blocks until
# the sleep child exits — even after wait.sh itself returns.
( sleep "$TIMEOUT"; touch "$TIMEOUT_SENTINEL"; tmux wait-for -S "$WAIT_CHANNEL" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

# Self-wake: periodic re-signal closes hook-before-wait race (max 2s latency)
# Bounded by TIMEOUT+10s to prevent orphan processes if parent is SIGKILL'd
_SW_LIMIT=$((TIMEOUT + 10))
( _sw_end=$(($(date +%s) + _SW_LIMIT)); while [ "$(date +%s)" -lt "$_sw_end" ]; do sleep 2; tmux wait-for -S "$WAIT_CHANNEL" 2>/dev/null; done ) >/dev/null 2>&1 &
SELFWAKE_PID=$!

# ── Main loop ────────────────────────────────────────────────────
while true; do
    # (a) Fresh response ready?
    _try_read_response || true

    # Signal file persists on disk — hook already fired, re-check
    [ -f "$SIGNAL_FILE" ] && continue

    # (b) Cancelled by cancel_dispatch?
    if [ -f "$CANCEL_SENTINEL" ]; then
        rm -f "$CANCEL_SENTINEL"
        jq -n --arg status "cancelled" --arg pane "$PANE" \
              '{status:$status, pane:$pane}'
        exit 1
    fi

    # (c) Timeout?
    if [ -f "$TIMEOUT_SENTINEL" ]; then
        _try_read_response || true   # last-chance: hook may have fired between (a) and (b)
        captured=$(tmux capture-pane -t "$PANE" -p -S -40 2>/dev/null || true)
        jq -n --arg status "timeout" --arg captured "$captured" \
              '{status:$status, captured:$captured}'
        exit 1
    fi

    # (c) Block until signaled (by hook or watchdog), then loop back
    tmux wait-for "$WAIT_CHANNEL" 2>/dev/null || sleep 0.2
done
