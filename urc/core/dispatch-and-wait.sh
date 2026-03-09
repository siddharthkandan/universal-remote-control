#!/usr/bin/env bash
# dispatch-and-wait.sh — Atomic dispatch + wait composite (thin wrapper)
#
# Usage: dispatch-and-wait.sh <pane_id> <message> [timeout]
#
# Acquires per-pane lock → calls send.sh → calls wait.sh → outputs JSON.
# All debug output goes to stderr. stdout is ONLY structured JSON.

set -uo pipefail

PANE="${1:?Usage: dispatch-and-wait.sh <pane_id> <message> [timeout]}"
MESSAGE="${2:?Usage: dispatch-and-wait.sh <pane_id> <message> [timeout]}"
TIMEOUT="${3:-120}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LOCK_DIR="$PROJECT_ROOT/.urc/locks"
LOCK_DIR_PATH="$LOCK_DIR/dispatch_${PANE}.d"
mkdir -p "$LOCK_DIR"

# ── Circuit breaker check (fast fail before lock) ─────────────────
# shellcheck source=circuit.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/circuit.sh"

if ! circuit_check "$PANE"; then
    # circuit_check already output JSON to stdout
    exit 1
fi

# ── Acquire per-pane lock (mkdir-based, POSIX compatible) ────────
if ! mkdir "$LOCK_DIR_PATH" 2>/dev/null; then
  if [ -d "$LOCK_DIR_PATH" ]; then
    # Check for stale lock (older than 5 minutes)
    _lock_mtime=$(stat -f%m "$LOCK_DIR_PATH" 2>/dev/null || stat -c%Y "$LOCK_DIR_PATH" 2>/dev/null || echo 0)
    _lock_age=$(( $(date +%s) - _lock_mtime ))
    if [ "$_lock_age" -gt 300 ]; then
      echo "stale lock (${_lock_age}s), reclaiming" >&2
      rmdir "$LOCK_DIR_PATH" 2>/dev/null
      if ! mkdir "$LOCK_DIR_PATH" 2>/dev/null; then
        jq -n --arg pane "$PANE" '{status:"busy",pane:$pane}'
        exit 1
      fi
    else
      jq -n --arg pane "$PANE" '{status:"busy",pane:$pane}'
      exit 1
    fi
  else
    jq -n --arg pane "$PANE" '{status:"busy",pane:$pane}'
    exit 1
  fi
fi

# ── Cleanup on exit ─────────────────────────────────────────────
trap 'rmdir "$LOCK_DIR_PATH" 2>/dev/null' EXIT

# ── Write dispatch metadata (attribution for relay push) ─────────
_DISPATCH_META_DIR="$PROJECT_ROOT/.urc/dispatches"
mkdir -p "$_DISPATCH_META_DIR"
_DISPATCH_META="$_DISPATCH_META_DIR/${PANE}.json"
_meta_stale=1
if [ -f "$_DISPATCH_META" ]; then
    _meta_ts=$(stat -f%m "$_DISPATCH_META" 2>/dev/null || stat -c%Y "$_DISPATCH_META" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - _meta_ts )) -le 5 ] && _meta_stale=0
fi
if [ "$_meta_stale" -eq 1 ]; then
    jq -n --arg type "dispatch" --arg source "${TMUX_PANE:-unknown}" \
        --arg message "$(printf '%.100s' "$MESSAGE")" --argjson ts "$(date +%s)" \
        '{type:$type, source:$source, message:$message, ts:$ts}' \
        > "$_DISPATCH_META" 2>/dev/null
fi

# ── Send ─────────────────────────────────────────────────────────
DISPATCH_TS=$(date +%s)  # capture BEFORE send to maximize epoch gap
SEND_RESULT=$(bash "$SCRIPT_DIR/send.sh" "$PANE" "$MESSAGE")
SEND_EXIT=$?

if [ "$SEND_EXIT" -ne 0 ]; then
  SEND_STATUS=$(echo "$SEND_RESULT" | jq -r '.status // "failed"' 2>/dev/null)
  circuit_record "$PANE" "$SEND_STATUS"
  echo "$SEND_RESULT"
  exit 1
fi

# ── Wait ─────────────────────────────────────────────────────────
WAIT_RESULT=$(bash "$SCRIPT_DIR/wait.sh" "$PANE" "$TIMEOUT" "$DISPATCH_TS")
WAIT_EXIT=$?

# ── Record circuit state ──────────────────────────────────────────
WAIT_STATUS=$(echo "$WAIT_RESULT" | jq -r '.status // "failed"' 2>/dev/null)
circuit_record "$PANE" "$WAIT_STATUS"

echo "$WAIT_RESULT"
exit "$WAIT_EXIT"
