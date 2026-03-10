#!/usr/bin/env bash
# send.sh — Inject text into a tmux pane via bracketed paste
# Usage: bash urc/core/send.sh <pane_id> <text>
# Stdout: JSON — {"status":"delivered","pane":"%42","cli":"codex"}
#                 {"status":"failed","pane":"%42","error":"pane does not exist"}
# Exit:   0 = delivered, 1 = failed
# ~95 LOC (excluding comments/blanks)

set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

PANE="${1:?Usage: send.sh <pane_id> <text>}"
TEXT="${2:?Usage: send.sh <pane_id> <text>}"

# Optional: --cli <type> overrides auto-detection
_CLI_OVERRIDE=""
if [ "${3:-}" = "--cli" ] && [ -n "${4:-}" ]; then
  _CLI_OVERRIDE="$4"
fi

# ── Pane ID validation ─────────────────────────────────────────
[[ "$PANE" =~ ^%[0-9]+$ ]] || { jq -n --arg pane "$PANE" '{status:"failed",pane:$pane,error:"invalid pane ID format"}'; exit 1; }

# Source cli-adapter.sh from same directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cli-adapter.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/cli-adapter.sh"

# ── Temp file cleanup ────────────────────────────────────────────
_SEND_TMP=""
trap '[ -n "$_SEND_TMP" ] && rm -f "$_SEND_TMP"' EXIT

# ── JSON output helpers ──────────────────────────────────────────
_fail() { jq -n --arg pane "$PANE" --arg error "$1" '{status:"failed",pane:$pane,error:$error}'; exit 1; }
_ok() { jq -n --arg pane "$PANE" --arg cli "$1" '{status:"delivered",pane:$pane,cli:$cli}'; exit 0; }

# ── Step 1: Validate pane exists ─────────────────────────────────
_pane_check=$(tmux display-message -t "$PANE" -p '#{pane_id}' 2>/dev/null) || _pane_check=""
if [ -z "$_pane_check" ]; then
  _fail "pane does not exist"
fi

# ── Step 2: Detect CLI type ─────────────────────────────────────
if [ -n "$_CLI_OVERRIDE" ]; then
  CLI="$_CLI_OVERRIDE"
else
  CLI=$(detect_cli "$PANE")
fi

# ── Step 3: Write text to temp file ──────────────────────────────
_SEND_TMP=$(mktemp "${TMPDIR:-/tmp}/urc-send-XXXXXX")
printf '%s' "$TEXT" > "$_SEND_TMP"

# ── Step 4: Load buffer (PID-unique name) ────────────────────────
# ── Step 4b: Snapshot window_activity BEFORE paste (for Step 6b fast-path) ──
_ACTIVITY_BEFORE=$(tmux display-message -t "$PANE" -p '#{window_activity}' 2>/dev/null || echo "0")

BUF_NAME="urc-send-$$"
if ! tmux load-buffer -b "$BUF_NAME" "$_SEND_TMP" 2>/dev/null; then
  _fail "tmux load-buffer failed"
fi

# ── Step 5: Paste buffer (bracketed paste, auto-delete) ──────────
if ! tmux paste-buffer -b "$BUF_NAME" -d -p -t "$PANE" 2>/dev/null; then
  _fail "tmux paste-buffer failed"
fi

# ── Step 6: CLI-aware paste delay ────────────────────────────────
sleep "$(paste_delay "$CLI")"

# ── Step 6b: Verify text appeared in pane ────────────────────────
# Fast-path: check window_activity epoch change (~30ms vs ~500ms).
# If same-second collision, fall back to fingerprint polling.
# NOTE: _ACTIVITY_BEFORE is captured in Step 4b (before paste) for accurate comparison.
_FAST_DONE=0

# Quick check: did window_activity change? (10ms poll, up to 200ms)
for _wa in 1 2 3 4 5 6 7 8 9 10; do
  _ACTIVITY_NOW=$(tmux display-message -t "$PANE" -p '#{window_activity}' 2>/dev/null || echo "0")
  if [ "$_ACTIVITY_NOW" != "$_ACTIVITY_BEFORE" ] && [ "$_ACTIVITY_NOW" != "0" ]; then
    _FAST_DONE=1
    break
  fi
  sleep 0.02
done

# Fallback: fingerprint polling if window_activity didn't change
if [ "$_FAST_DONE" -eq 0 ]; then
  _FP="${TEXT:0:30}"
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    tmux capture-pane -t "$PANE" -p -S -10 2>/dev/null | grep -Fq -- "$_FP" && break
    sleep 0.2
  done
fi

# ── Step 7: Dismiss autocomplete (TUI CLIs only) ─────────────────
case "$CLI" in
  claude|gemini)
    tmux send-keys -t "$PANE" Escape 2>/dev/null
    # ── Step 8: Settle after Escape (Ink needs one React render cycle) ──
    sleep 0.1
    ;;
  # codex: Escape breaks input field
  # shell/*: no autocomplete to dismiss
esac

# ── Step 9: Capture pre-Enter snapshot ────────────────────────────
# NOTE: In TUI alternate screen mode, -S -3 captures the ENTIRE pane
# (no scrollback history to offset into). This snapshot is used by the
# fallback detection path for non-Claude CLIs only.
_PRE_ENTER=$(tmux capture-pane -t "$PANE" -p -S -3 2>/dev/null || true)

# ── Step 10: Press Enter ─────────────────────────────────────────
if ! tmux send-keys -t "$PANE" Enter 2>/dev/null; then
  _fail "tmux send-keys failed"
fi

# ── Step 11: Post-Enter stuck-input detection ─────────────────────
# TUI state transition race: Enter can be dropped during Ink render cycle.
# Skip for relay control messages (low risk, adds latency to relay path).
case "$TEXT" in
  __urc_push__|__urc_refresh__|/remote-control|"message delivered to %"*|"response from %"*) ;;
  *)
    case "$CLI" in
      shell) ;;  # No TUI — Enter always processed
      claude)
        # Fingerprint-based: check if text is still in the input field.
        # Claude Code's input prompt starts with "❯" — if a line starting
        # with ❯ still contains the input text, Enter was dropped.
        # NOTE: Claude Code uses a non-breaking space (U+00A0) after ❯,
        # so we match "starts with ❯" and "contains text" separately.
        # This avoids false positives from status bar settling on fresh
        # panes (the old full-pane comparison captured the entire screen
        # in TUI alternate mode, and status bar changes fooled the
        # detection into thinking Enter was accepted).
        _FP_INPUT="${TEXT:0:30}"
        for _enter_retry in 1 2; do
          sleep 0.5
          if tmux capture-pane -t "$PANE" -p 2>/dev/null | grep -F -- "$_FP_INPUT" | grep -q "^❯"; then
            tmux send-keys -t "$PANE" Enter 2>/dev/null || true
          else
            break
          fi
        done
        ;;
      *)
        # Other TUI CLIs: full-pane comparison fallback.
        # Known limitation: -S -3 captures entire screen in alternate mode,
        # so status bar changes can cause false positives on fresh panes.
        for _enter_retry in 1 2; do
          sleep 0.5
          _POST_ENTER=$(tmux capture-pane -t "$PANE" -p -S -3 2>/dev/null || true)
          if [ "$_PRE_ENTER" = "$_POST_ENTER" ]; then
            tmux send-keys -t "$PANE" Enter 2>/dev/null || true
          else
            break
          fi
        done
        ;;
    esac
    ;;
esac

# ── Step 12: Dispatch-acknowledged push (relay visibility) ────────
# If target pane has a relay, notify it that a message was delivered.
# Skip for control messages (relay protocol, prevents recursion).
case "$TEXT" in
  __urc_push__|__urc_refresh__|/remote-control|"You have an unread message from %"*|"message delivered to %"*|"response from %"*) ;;  # control/nudge/push tokens
  *)
    _relay=$(tmux show-options -pv -t "$PANE" @bridge_relay 2>/dev/null || true)
    if [ -n "$_relay" ]; then
      _push_dir="$(cd "${SCRIPT_DIR}/../.." && pwd)/.urc/pushes"
      _urc_dir="$(cd "${SCRIPT_DIR}/../.." && pwd)/.urc"
      mkdir -p "$_push_dir"
      # Read dispatch metadata for attribution (who dispatched this?)
      _dispatched_by=""
      _meta_file="$_urc_dir/dispatches/${PANE}.json"
      [ -f "$_meta_file" ] && _dispatched_by=$(jq -r '.source // ""' "$_meta_file" 2>/dev/null)
      jq -n --arg pane "$PANE" --arg cli "$CLI" --arg status "processing" \
        --arg message "${TEXT:0:100}" --arg dispatched_by "$_dispatched_by" \
        --argjson epoch "$(date +%s)" \
        '{pane:$pane,cli:$cli,epoch:$epoch,status:$status,message:$message,dispatched_by:$dispatched_by}' \
        > "$_push_dir/${_relay}_${PANE}_processing_$(date +%s).json" 2>/dev/null
      # Wake relay with informative token (replaces opaque __urc_push__)
      (bash "${SCRIPT_DIR}/send.sh" "$_relay" "message delivered to $PANE ($CLI)" --cli claude >/dev/null 2>&1) &
    fi
    ;;
esac

# ── Step 13: Report success ──────────────────────────────────────
_ok "$CLI"
