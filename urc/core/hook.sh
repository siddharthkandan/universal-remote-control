#!/usr/bin/env bash
# hook.sh — Turn-completion hook for Claude, Codex, and Gemini.
#
# Captures the assistant response, writes an atomic response file,
# signals the waiting dispatcher, appends JSONL audit stream.
#
# Called by:
#   Claude  — Stop hook (stdin JSON, .last_assistant_message)
#   Codex   — notify hook ($1 JSON, .["last-assistant-message"])
#   Gemini  — AfterAgent hook (stdin JSON, .prompt_response)
#
# stdout: {"continue": true}  (Gemini contract, harmless elsewhere)
# exit:   Always 0 — hook must never fail the CLI.

set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo '{"continue": true}'; exit 0; }

# Ensure clean exit and stdout contract no matter what.
_exit_ok() { echo '{"continue": true}'; exit 0; }
trap _exit_ok EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PANE="${TMUX_PANE:-unknown}"
[[ "$PANE" == "unknown" || "$PANE" =~ ^%[0-9]+$ ]] || PANE="unknown"
EPOCH=$(date +%s)

RESPONSE_DIR="$PROJECT_ROOT/.urc/responses"
SIGNAL_DIR="$PROJECT_ROOT/.urc/signals"
STREAM_DIR="$PROJECT_ROOT/.urc/streams"
mkdir -p "$RESPONSE_DIR" "$SIGNAL_DIR" "$STREAM_DIR"

# ── CLI Detection + Payload Parsing ──────────────────────────────
# CRITICAL: Check $1 first. Codex passes JSON as argument; reading
# stdin would block forever because Codex's stdin is /dev/null.
CLI="unknown"
RESPONSE=""

if [ -n "${1:-}" ]; then
    CLI="codex"
    RESPONSE=$(printf '%s' "$1" | jq -r '.["last-assistant-message"] // empty' 2>/dev/null)
else
    PAYLOAD=$(cat)
    if [ -n "$PAYLOAD" ]; then
        if [ "$(printf '%s' "$PAYLOAD" | jq -r 'has("prompt_response")' 2>/dev/null)" = "true" ]; then
            CLI="gemini"
            RESPONSE=$(printf '%s' "$PAYLOAD" | jq -r '.prompt_response // empty' 2>/dev/null)
        else
            CLI="claude"
            RESPONSE=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null)
        fi
    fi
fi

# ── Response File (atomic write) ─────────────────────────────────
if [ -n "$RESPONSE" ]; then
    TMP=$(mktemp "$RESPONSE_DIR/.tmp.XXXXXX")
    printf '%s' "$RESPONSE" | jq -Rs \
        --arg pane "$PANE" \
        --arg cli "$CLI" \
        --argjson epoch "$EPOCH" \
        --argjson len "${#RESPONSE}" \
        '{pane:$pane, cli:$cli, epoch:$epoch, response:., len:$len}' \
        > "$TMP" 2>/dev/null

    if [ -s "$TMP" ]; then
        mv -f "$TMP" "$RESPONSE_DIR/${PANE}.json"
    else
        rm -f "$TMP"
    fi
fi

# ── Respawn check (phone relay path accumulation) ─────────────────
# The additionalContext phone path accumulates ~300 tok/cycle.
# When relay counter hits 25, clear the session via respawn-pane -k.
# Counter only tracks outgoing sends (not push/status turns), so actual turns ~2x.
# At 25 sends (~50 total turns × ~500 tok = ~25K tok), well within Haiku's 200K context.
# Pane ID is preserved, tmux options survive, counter resets to 0.
if [ "$PANE" != "unknown" ]; then
    _relay_count=$(tmux show-options -pv -t "$PANE" @bridge_relays 2>/dev/null || echo "0")
    _needs_clear=$(tmux show-options -pv -t "$PANE" @bridge_needs_clear 2>/dev/null || echo "")
    if [ "${_relay_count:-0}" -ge 25 ]; then
        tmux set-option -p -t "$PANE" @bridge_needs_clear 1 2>/dev/null
    fi
    if [ "$_needs_clear" = "1" ]; then
        # Atomically clear flag BEFORE respawn to prevent double-fire race
        tmux set-option -p -t "$PANE" @bridge_needs_clear 0 2>/dev/null
        tmux set-option -p -t "$PANE" @bridge_relays 0 2>/dev/null
        # Respawn after signal ordering completes (background, 2s delay for signal flush)
        # After respawn, re-send /remote-control to restore phone connection (12s for Claude startup)
        (sleep 2 && tmux respawn-pane -k -t "$PANE" 2>/dev/null && sleep 12 && bash "$PROJECT_ROOT/urc/core/send.sh" "$PANE" "/remote-control" --cli claude >/dev/null 2>&1) &
    fi
fi

# ── Signal ordering (NON-NEGOTIABLE — changing this breaks wait.sh)
# 1. Response file written above
# 2. Touch signal file
touch "$SIGNAL_DIR/done_${PANE}"
# 3. tmux wait-for wakes dispatcher
tmux wait-for -S "urc_done_${PANE}" 2>/dev/null
# 4. Append JSONL (best-effort, with rotation at 1MB)
_STREAM="$STREAM_DIR/${PANE}.jsonl"
if [ -f "$_STREAM" ]; then
    _STREAM_SIZE=$(stat -f%z "$_STREAM" 2>/dev/null || stat -c%s "$_STREAM" 2>/dev/null || echo 0)
    if [ "${_STREAM_SIZE:-0}" -gt 1048576 ]; then
        tail -500 "$_STREAM" > "${_STREAM}.tmp" && mv "${_STREAM}.tmp" "$_STREAM"
    fi
fi
printf '%s' "${RESPONSE:-}" | jq -Rsc \
    --arg pane "$PANE" \
    --arg cli "$CLI" \
    --argjson epoch "$EPOCH" \
    --argjson len "${#RESPONSE}" \
    '{pane:$pane, cli:$cli, epoch:$epoch, response:., len:$len}' \
    >> "$STREAM_DIR/${PANE}.jsonl" 2>/dev/null

# ── Relay push (surface activity to phone) ────────────────────────
# If this pane has a @bridge_relay, push the response to the relay
# so the phone user sees what's happening on the target pane.
if [ "$PANE" != "unknown" ] && [ -n "${RESPONSE:-}" ]; then
    _relay=$(tmux show-options -pv -t "$PANE" @bridge_relay 2>/dev/null || true)
    if [ -n "$_relay" ]; then
        mkdir -p "$PROJECT_ROOT/.urc/pushes"
        # Read dispatch metadata for attribution (written by dispatcher before send)
        _meta_file="$PROJECT_ROOT/.urc/dispatches/${PANE}.json"
        _trig_type="autonomous"
        _trig_by=""
        _trig_msg=""
        if [ -f "$_meta_file" ]; then
            _trig_type=$(jq -r '.type // "dispatch"' "$_meta_file" 2>/dev/null)
            _trig_by=$(jq -r '.source // ""' "$_meta_file" 2>/dev/null)
            _trig_msg=$(jq -r '.message // ""' "$_meta_file" 2>/dev/null)
            rm -f "$_meta_file"
        fi
        printf '%s' "$RESPONSE" | jq -Rs \
            --arg pane "$PANE" --arg cli "$CLI" --argjson epoch "$EPOCH" \
            --arg triggered_type "$_trig_type" \
            --arg triggered_by "$_trig_by" \
            --arg triggered_msg "$_trig_msg" \
            '{pane:$pane, cli:$cli, epoch:$epoch, response:.,
              triggered_type:$triggered_type, triggered_by:$triggered_by, triggered_msg:$triggered_msg}' \
            > "$PROJECT_ROOT/.urc/pushes/${_relay}_${PANE}_${EPOCH}.json" 2>/dev/null
        (bash "$PROJECT_ROOT/urc/core/send.sh" "$_relay" "response from $PANE ($CLI) below:" --cli claude >/dev/null 2>&1) &
    fi
fi

# stdout contract handled by EXIT trap
