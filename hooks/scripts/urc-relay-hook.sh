#!/usr/bin/env bash
# urc-relay-hook.sh — UserPromptSubmit hook for $0 relay
#
# Detects >codex:, >gemini:, >: prefix in user prompt.
# No prefix → exit 0 immediately (NON-NEGOTIABLE — must not block prompts).
# Dispatches to target pane via dispatch-and-wait.sh, returns response
# via additionalContext (phone) or block decision (terminal).
#
# Config: .urc/relay-config.json
# Management: urc/core/relay-ctl.sh

set -uo pipefail

URC_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONFIG="$URC_ROOT/.urc/relay-config.json"

# ── Read prompt from stdin ────────────────────────────────────────
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0

# ── Match relay prefix ────────────────────────────────────────────
# >codex: message   → route to codex target
# >gemini: message  → route to gemini target
# >: message        → route to default target
# Anything else     → exit 0 (pass through to Claude)
if [[ "$PROMPT" =~ ^'>'([a-zA-Z]*):\ *(.*) ]]; then
    CLI_KEY="${BASH_REMATCH[1]}"
    MESSAGE="${BASH_REMATCH[2]}"
    [ -z "$CLI_KEY" ] && CLI_KEY="default"
    CLI_KEY=$(echo "$CLI_KEY" | tr '[:upper:]' '[:lower:]')
else
    exit 0
fi

# ── Validate message ──────────────────────────────────────────────
if [ -z "$MESSAGE" ]; then
    printf '{"decision":"block","reason":"Empty relay message. Usage: >codex: your message here"}'
    exit 0
fi

# ── Load config ───────────────────────────────────────────────────
if [ ! -f "$CONFIG" ]; then
    printf '{"decision":"block","reason":"Relay not configured. Run: bash urc/core/relay-ctl.sh add codex %%NNN"}'
    exit 0
fi

# ── Check enabled flag ────────────────────────────────────────────
ENABLED=$(jq -r 'if .enabled == false then "false" else "true" end' "$CONFIG" 2>/dev/null)
if [ "$ENABLED" = "false" ]; then
    exit 0  # Relay disabled — pass through to Claude
fi

# Look up target pane
if [ "$CLI_KEY" = "default" ]; then
    DEFAULT_KEY=$(jq -r '.default // empty' "$CONFIG" 2>/dev/null)
    if [ -z "$DEFAULT_KEY" ]; then
        printf '{"decision":"block","reason":"No default target configured. Run: bash urc/core/relay-ctl.sh add codex %%NNN"}'
        exit 0
    fi
    TARGET=$(jq -r --arg k "$DEFAULT_KEY" '.targets[$k] // empty' "$CONFIG" 2>/dev/null)
else
    TARGET=$(jq -r --arg k "$CLI_KEY" '.targets[$k] // empty' "$CONFIG" 2>/dev/null)
fi

if [ -z "$TARGET" ]; then
    printf '{"decision":"block","reason":"No target configured for '\''%s'\''. Run: bash urc/core/relay-ctl.sh add %s %%NNN"}' "$CLI_KEY" "$CLI_KEY"
    exit 0
fi

# ── Check pane alive ──────────────────────────────────────────────
if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q "^${TARGET}$"; then
    printf '{"decision":"block","reason":"Target pane %s is dead. Run: bash urc/core/relay-ctl.sh add %s %%NNN"}' "$TARGET" "$CLI_KEY"
    exit 0
fi

# ── Write dispatch metadata (attribution: type=relay, source=phone) ─
# Pre-writing metadata before dispatch-and-wait.sh ensures our attribution wins
# (dispatch-and-wait.sh skips metadata write if file is fresh ≤5s).
mkdir -p "$URC_ROOT/.urc/dispatches"
jq -n --arg type "relay" --arg source "phone" \
    --arg message "$(printf '%.100s' "$MESSAGE")" --argjson ts "$(date +%s)" \
    '{type:$type, source:$source, message:$message, ts:$ts}' \
    > "$URC_ROOT/.urc/dispatches/${TARGET}.json" 2>/dev/null

# ── Dispatch and wait ─────────────────────────────────────────────
RESULT=$(bash "$URC_ROOT/urc/core/dispatch-and-wait.sh" "$TARGET" "$MESSAGE" 120 2>/dev/null)

# ── Parse result ──────────────────────────────────────────────────
STATUS=$(echo "$RESULT" | jq -r '.status // "error"' 2>/dev/null)
RESPONSE=$(echo "$RESULT" | jq -r '.response // empty' 2>/dev/null)

case "$STATUS" in
    completed)
        DISPLAY="$RESPONSE"
        ;;
    timeout)
        CAPTURED=$(echo "$RESULT" | jq -r '.captured // empty' 2>/dev/null)
        DISPLAY="[TIMEOUT] Partial output from ${TARGET}:
${CAPTURED:-no output captured}"
        ;;
    busy)
        DISPLAY="[BUSY] Target ${TARGET} is processing another request. Try again in a moment."
        ;;
    failed)
        ERROR=$(echo "$RESULT" | jq -r '.error // "unknown error"' 2>/dev/null)
        DISPLAY="[FAILED] ${TARGET}: ${ERROR}"
        ;;
    *)
        DISPLAY="[ERROR] Unexpected dispatch result: ${RESULT:-no output}"
        ;;
esac

# ── Increment relay counter ───────────────────────────────────────
PANE="${TMUX_PANE:-}"
if [ -n "$PANE" ]; then
    COUNT=$(tmux show-options -pv -t "$PANE" @bridge_relays 2>/dev/null || echo "0")
    COUNT=$((COUNT + 1))
    tmux set-option -p -t "$PANE" @bridge_relays "$COUNT" 2>/dev/null
fi

# ── Dual-mode response ────────────────────────────────────────────
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    # Phone/remote: inject via additionalContext (Claude sees it, echoes it)
    ESCAPED=$(printf '%s' "$DISPLAY" | jq -Rs .)
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}' "$ESCAPED"
    exit 0
else
    # Local terminal: block the prompt, display response directly
    printf '{"decision":"block","reason":%s}' "$(printf '%s' "$DISPLAY" | jq -Rs .)"
    exit 0
fi
