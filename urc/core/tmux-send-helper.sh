#!/usr/bin/env bash
# tmux-send-helper.sh — Reliable tmux send-keys with guaranteed Enter
#
# Called by the dispatch_to_pane MCP tool. Resolves peer → pane, checks idle state,
# sends text with CLI-aware delays, presses Enter, and optionally verifies
# the target began processing.
#
# Usage:
#   tmux-send-helper.sh <target> <text> [--verify|--no-verify] [--force]
#
# <target> is a peer name ("codex", "claude-ipc") or direct pane ID ("%256").
#
# Outputs JSON to stdout. Exit codes:
#   0 = delivered   1 = failed   2 = timeout   3 = peer offline/not idle
#
# Bash 3.2 compatible. macOS + Linux.

set -uo pipefail

TARGET="${1:?Usage: tmux-send-helper.sh <target> <text> [--verify|--no-verify] [--force]}"
TEXT="${2:?Usage: tmux-send-helper.sh <target> <text> [--verify|--no-verify] [--force]}"
shift 2

# Backward-compatible flag parsing:
# - default behavior remains "verify=yes"
# - --force without explicit verify keeps prior behavior: verify=no
VERIFY="yes"
FORCE="no"
EXPLICIT_VERIFY="no"
while [ $# -gt 0 ]; do
    case "$1" in
        --verify|yes)
            VERIFY="yes"
            EXPLICIT_VERIFY="yes"
            ;;
        --no-verify|no)
            VERIFY="no"
            EXPLICIT_VERIFY="yes"
            ;;
        --force|force)
            FORCE="yes"
            ;;
        *)
            printf '{"status":"failed","pane":"","error":"unknown flag: %s"}\n' "$1"
            exit 1
            ;;
    esac
    shift
done

if [ "$FORCE" = "yes" ] && [ "$EXPLICIT_VERIFY" != "yes" ]; then
    VERIFY="no"
fi

LONG_MSG_THRESHOLD=1000
CLAUDE_BASE_DELAY=0.3
OTHER_BASE_DELAY=0.1
# Conservative fallback for unknown CLI targets to avoid premature Enter.
UNKNOWN_BASE_DELAY=0.2

# Source observer.sh for resolve_pane(), detect_state(), resolve_cli_type()
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=observer.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/observer.sh"

# ── Audit Logging ────────────────────────────────────────────────
# JSONL audit trail for every send attempt. Auto-rotates at 1MB.
_AUDIT_LOG="${SCRIPT_DIR}/../../.urc/logs/tmux-send.log"
_AUDIT_MAX_BYTES=1048576  # 1MB

_audit_log() {
    local status="$1" target_pane="${2:-}" peer="${3:-}" error="${4:-}"
    local sender_pane="${TMUX_PANE:-unknown}"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    # preview_80: first 80 chars of message, newlines collapsed
    local preview_80
    preview_80=$(printf '%.80s' "$(printf '%s' "${TEXT:-}" | tr '\n' ' ')")
    # delivered: boolean derived from status
    local delivered="false"
    [ "$status" = "delivered" ] && delivered="true"
    local dir
    dir=$(dirname "$_AUDIT_LOG")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
    # Auto-rotate at 1MB
    if [ -f "$_AUDIT_LOG" ]; then
        local sz
        sz=$(stat -f%z "$_AUDIT_LOG" 2>/dev/null || stat -c%s "$_AUDIT_LOG" 2>/dev/null || echo 0)
        if [ "$sz" -gt "$_AUDIT_MAX_BYTES" ]; then
            mv "$_AUDIT_LOG" "${_AUDIT_LOG}.1" 2>/dev/null
        fi
    fi
    printf '{"timestamp":"%s","sender_pane":"%s","target_pane":"%s","preview_80":"%s","delivered":%s,"status":"%s","error":"%s"}\n' \
        "$timestamp" "$sender_pane" "$target_pane" "$preview_80" "$delivered" "$status" "$error" >> "$_AUDIT_LOG" 2>/dev/null
}

# ── Output helper ──────────────────────────────────────────────────
# _FORCE_WARNING is set when --force bypasses a non-IDLE state.
# Include warning in delivered results so callers can
# detect potential silent text swallow on PROCESSING panes.
_FORCE_WARNING=""

json_result() {
    local status="$1" pane="${2:-}" error="${3:-}"
    # Audit every outcome
    _audit_log "$status" "$pane" "${PEER_NAME:-$TARGET}" "$error"
    if [ -n "$error" ]; then
        printf '{"status":"%s","pane":"%s","error":"%s"}\n' "$status" "$pane" "$error"
    elif [ -n "$_FORCE_WARNING" ] && [ "$status" = "delivered" ]; then
        printf '{"status":"%s","pane":"%s","warning":"%s"}\n' "$status" "$pane" "$_FORCE_WARNING"
    else
        printf '{"status":"%s","pane":"%s"}\n' "$status" "$pane"
    fi
}

# ── Step 1: Resolve pane ──────────────────────────────────────────
# --force skips pane_exists check. Required for Codex sandbox
# where tmux list-panes returns empty inside script subprocesses.
PANE=""
if [[ "$TARGET" == %* ]]; then
    PANE="$TARGET"
    if [ "$FORCE" != "yes" ] && ! pane_exists "$PANE"; then
        json_result "failed" "$PANE" "pane $PANE does not exist"
        exit 1
    fi
else
    PANE=$(resolve_pane "$TARGET" 2>/dev/null)
    if [ -z "$PANE" ]; then
        json_result "failed" "" "cannot resolve peer '$TARGET' to a pane"
        exit 1
    fi
fi

# ── Step 1.5: Instruction pane-target validation ────────────────
# If sending a "READ and execute:" instruction with pane-specific targeting,
# validate the instruction file matches the resolved target pane.
_read_exec_pat='READ and execute: (.+)'
if [[ "$TEXT" =~ $_read_exec_pat ]]; then
    _instruction_path="${BASH_REMATCH[1]}"
    if ! validate_instruction_pane_target "$_instruction_path" "$PANE"; then
        _file_pane=$(extract_instruction_pane_id "$_instruction_path")
        _target_num="${PANE#%}"
        json_result "failed" "$PANE" "instruction targets pane${_file_pane} but target is pane${_target_num}"
        exit 1
    fi
fi

# ── Step 1.9: Session group boundary guard ──────────────────────
# Block cross-group sends unless --force or URC_ALLOW_CROSS_GROUP=1
if [ "$FORCE" != "yes" ]; then
    _SENDER_PANE="${TMUX_PANE:-}"
    if [ -n "$_SENDER_PANE" ] && ! check_session_group "$_SENDER_PANE" "$PANE"; then
        json_result "blocked" "$PANE" "cross-group send: sender $_SENDER_PANE -> target $PANE"
        exit 4
    fi
fi

# ── Step 2: Check idle state ─────────────────────────────────────
PEER_NAME="$TARGET"
# When targeting by direct pane ID (%NNN), infer the peer name from
# state.json or pane content. Previously defaulted to "claude", which caused
# Codex/Gemini panes to always appear PROCESSING (wrong idle detection pattern).
if [[ "$PEER_NAME" == %* ]]; then
    PEER_NAME=$(resolve_peer_from_pane "$PANE")
fi

# --force skips idle check (Codex sandbox can't run tmux capture-pane in scripts).
# Even with --force, detect state and warn if PROCESSING.
# Claude Code's TUI silently swallows text sent during mid-turn rendering.
# send-helper still delivers (force = bypass block), but warns the caller.
if [ "$FORCE" = "yes" ]; then
    _DETECTED_STATE=$(detect_state "$PEER_NAME" "$PANE" 2>/dev/null || echo "UNKNOWN")
    if [ "$_DETECTED_STATE" = "PROCESSING" ]; then
        _FORCE_WARNING="target_processing: text may be silently swallowed by TUI"
        echo "WARN: target $PANE is PROCESSING — text may be silently swallowed" >&2
    elif [ "$_DETECTED_STATE" = "WAITING_PERMISSION" ]; then
        _FORCE_WARNING="target_waiting_permission: text may interfere with approval prompt"
        echo "WARN: target $PANE is WAITING_PERMISSION — text may interfere" >&2
    fi
    STATE="FORCED"
else
    STATE=$(detect_state "$PEER_NAME" "$PANE")
    if [ "$STATE" != "IDLE" ] && [ "$STATE" != "STUCK_INPUT" ]; then
        json_result "failed" "$PANE" "peer is $STATE, not IDLE"
        exit 3
    fi
fi

# ── Step 3: Determine CLI type for delay ──────────────────────────
CLI_TYPE=$(resolve_cli_type "$PEER_NAME" 2>/dev/null || echo "unknown")
if [ "$CLI_TYPE" = "unknown" ]; then
    # Fallback: resolve by pane ID directly (uses DB cli field lookup)
    CLI_TYPE=$(resolve_cli_type "$PANE" 2>/dev/null || echo "unknown")
fi

# ── Step 4: Capture before-state for verification ─────────────────
BEFORE=""
if [ "$VERIFY" != "no" ]; then
    BEFORE=$(tmux capture-pane -t "$PANE" -p -S -10 2>/dev/null || true)
fi

# ── Step 5: Send text ─────────────────────────────────────────────
TEXT_LEN=${#TEXT}
USED_BUFFER_PASTE=0
if [ "$TEXT_LEN" -gt "$LONG_MSG_THRESHOLD" ] || [ "$CLI_TYPE" = "gemini" ]; then
    # Buffer paste for long messages AND always for Gemini.
    # Gemini CLI 0.32.x has a React state staleness bug where '!' in
    # send-keys -l input triggers shell mode toggle. paste-buffer goes
    # through Ink's paste handler, bypassing the '!' check entirely.
    USED_BUFFER_PASTE=1
    local_tmp=$(mktemp "${TMPDIR:-/tmp}/tmux-send-XXXXXX")
    printf '%s' "$TEXT" > "$local_tmp"
    tmux load-buffer -b urc-send "$local_tmp" 2>/dev/null
    tmux paste-buffer -b urc-send -d -p -t "$PANE" 2>/dev/null
    rm -f "$local_tmp"
else
    tmux send-keys -t "$PANE" -l "$TEXT" 2>/dev/null
fi

# ── Step 6: CLI-aware delay before Enter ──────────────────────────
# Buffer paste delivers text atomically but the TUI needs
# time to receive, parse, and render multi-line content. Without a
# "paste settled" check, Enter arrives before the TUI is ready and is
# either dropped or absorbed as a newline.
if [ "$USED_BUFFER_PASTE" -eq 1 ]; then
    # Buffer paste path: wait for the pasted text to appear in the pane
    # before sending Enter. Poll up to 5s in 0.5s increments.
    _paste_settled=0
    # Use first 40 chars of text as a fingerprint (enough to confirm paste landed)
    _paste_fingerprint="${TEXT:0:40}"
    for _pw in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        _paste_check=$(tmux capture-pane -t "$PANE" -p -S -30 2>/dev/null || true)
        if printf '%s' "$_paste_check" | grep -Fq "$_paste_fingerprint"; then
            _paste_settled=1
            break
        fi
    done
    if [ "$_paste_settled" -eq 0 ]; then
        # Paste didn't appear after 5s — fall back to generous fixed delay
        sleep 2
    fi
    # Extra settling time for Claude TUI to finish rendering
    case "$CLI_TYPE" in
        claude) sleep 0.5 ;;
    esac
else
    # send-keys -l path: character-by-character delivery, normal adaptive delay
    case "$CLI_TYPE" in
        claude)
            # Adaptive: base 0.3s + 0.1s per 500 chars, cap 2.0s
            extra=$(( TEXT_LEN / 500 ))
            delay=$(awk "BEGIN { d = $CLAUDE_BASE_DELAY + $extra * 0.1; if (d > 2.0) d = 2.0; print d }")
            sleep "$delay"
            ;;
        codex)
            sleep "$OTHER_BASE_DELAY"
            ;;
        gemini)
            sleep 0.3
            ;;
        *)
            # Unknown CLI: use conservative delay to avoid Enter racing input.
            sleep "$UNKNOWN_BASE_DELAY"
            ;;
    esac
fi

# ── Step 6b: Text-settled check (send-keys path) ─────────────────
# For Claude TUI: verify text appeared in the pane before sending
# Enter. Claude Code renders input asynchronously; if Enter arrives
# before the TUI finishes receiving characters, it is silently
# swallowed. Poll up to 3s for the first 30 chars to appear.
if [ "$USED_BUFFER_PASTE" -eq 0 ] && { [ "$CLI_TYPE" = "claude" ] || [ "$CLI_TYPE" = "gemini" ]; } && [ "$VERIFY" = "yes" ]; then
    _text_fingerprint="${TEXT:0:30}"
    _text_settled=0
    for _ts in 1 2 3 4 5 6; do
        _ts_check=$(tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || true)
        if printf '%s' "$_ts_check" | grep -Fq "$_text_fingerprint"; then
            _text_settled=1
            break
        fi
        sleep 0.5
    done
    if [ "$_text_settled" -eq 0 ]; then
        # Text didn't appear after 3s — add generous extra delay
        sleep 2
    fi
fi

# ── Step 7: Send Enter ────────────────────────────────────────────
tmux send-keys -t "$PANE" Enter 2>/dev/null

# ── Step 8: Verify delivery (optional) ────────────────────────────
if [ "$VERIFY" = "no" ]; then
    json_result "delivered" "$PANE"
    exit 0
fi

# Processing markers that confirm the agent started working
_PROCESSING_RE='tool use|running|processing|executing|thinking|working|generating|esc to interrupt|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|searching|calling|Interactive shell'

# Wait 2s then check if content changed
sleep 2
AFTER=$(tmux capture-pane -t "$PANE" -p -S -10 2>/dev/null || true)

if [ "$BEFORE" != "$AFTER" ]; then
    # Content changed — check for processing markers
    AFTER_LC=$(printf '%s' "$AFTER" | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$AFTER_LC" | grep -Eq "$_PROCESSING_RE"; then
        json_result "delivered" "$PANE"
        exit 0
    fi
    # Only retry aggressively for Claude — extra Enters interfere with Gemini/Codex tool execution
    if [ "$CLI_TYPE" != "claude" ]; then
        # Non-Claude: accept uncertain delivery after first check
        json_result "uncertain" "$PANE" "content changed but no processing markers (non-Claude, skipping retries)"
        exit 2
    fi
    # No markers — retry Enter up to 3 times (2s apart)
    for _ in 1 2 3; do
        tmux send-keys -t "$PANE" Enter 2>/dev/null
        sleep 2
        RETRY=$(tmux capture-pane -t "$PANE" -p -S -10 2>/dev/null || true)
        RETRY_LC=$(printf '%s' "$RETRY" | tr '[:upper:]' '[:lower:]')
        if printf '%s' "$RETRY_LC" | grep -Eq "$_PROCESSING_RE"; then
            json_result "delivered" "$PANE"
            exit 0
        fi
    done
    # Final aggressive retry: longer settle time before last Enter
    sleep 3
    tmux send-keys -t "$PANE" Enter 2>/dev/null
    sleep 3
    FINAL=$(tmux capture-pane -t "$PANE" -p -S -10 2>/dev/null || true)
    FINAL_LC=$(printf '%s' "$FINAL" | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$FINAL_LC" | grep -Eq "$_PROCESSING_RE"; then
        json_result "delivered" "$PANE"
        exit 0
    fi
    # Text appeared but Enter never confirmed — NEVER false-positive.
    # Return uncertain so callers know the message may be stuck in
    # the TUI input field.
    _FORCE_WARNING="${_FORCE_WARNING:+$_FORCE_WARNING; }enter_not_confirmed: text appeared but not submitted after 4 Enter attempts"
    json_result "uncertain" "$PANE"
    exit 2
fi

# Content didn't change — poll for 10s
for _ in 1 2 3 4 5; do
    sleep 2
    POLL=$(tmux capture-pane -t "$PANE" -p -S -10 2>/dev/null || true)
    if [ "$BEFORE" != "$POLL" ]; then
        json_result "delivered" "$PANE"
        exit 0
    fi
done

json_result "timeout" "$PANE" "pane content did not change after send"
exit 2
