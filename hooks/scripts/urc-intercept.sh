#!/bin/bash
# UserPromptSubmit hook -- intercepts /urc commands and pre-executes them
# Returns decision:"block" for instant commands (zero model invocation)
# Returns systemMessage for dispatch commands (model displays result)

URC_ROOT="${CLAUDE_PLUGIN_ROOT:-.}"

# Read the user's prompt from stdin
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -z "$PROMPT" ] && PROMPT="$INPUT"

# --- Instant commands (decision:block, zero model invocation) ---
case "$PROMPT" in
  /urc\ status|/urc\ fleet)
    OUTPUT=$(bash "$URC_ROOT/urc/core/urc-status.sh" 2>/dev/null)
    printf '{"decision":"block","reason":"%s"}' "$(printf '%s' "$OUTPUT" | jq -Rs . | sed 's/^"//;s/"$//')"
    exit 0
    ;;
esac

# --- Dispatch commands (/urc, /rc-any, /rc-bridge, /rc-relay) ---
if echo "$PROMPT" | grep -qiE '^\s*/urc\b|^\s*/rc-any\b|^\s*/rc-bridge\b|^\s*/rc-relay\b'; then
  ARG=$(echo "$PROMPT" | sed -E 's|^\s*/[a-zA-Z-]+\s*||')
  RESULT=$(bash "$URC_ROOT/urc/core/urc-dispatch.sh" "$ARG" "${TMUX_PANE:-}" 2>/dev/null)
  echo "{\"systemMessage\":\"URC dispatch result: $RESULT\"}"
  exit 0
fi

# Not a /urc command -- pass through silently
exit 0
