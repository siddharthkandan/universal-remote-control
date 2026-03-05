#!/bin/bash
# UserPromptSubmit hook — intercepts /urc commands and pre-executes them
# Runs BEFORE the model processes the prompt, so the heavy work is already done
# by the time the LLM sees it. Model just needs to display the result.

URC_ROOT="${CLAUDE_PLUGIN_ROOT:-.}"

# Read the user's prompt from stdin
PROMPT=$(cat)

# Match /urc, /rc-any, /rc-bridge, /rc-relay patterns
if echo "$PROMPT" | grep -qiE '^\s*/urc\b|^\s*/rc-any\b|^\s*/rc-bridge\b|^\s*/rc-relay\b'; then
  # Extract the argument (everything after the command)
  ARG=$(echo "$PROMPT" | sed -E 's|^\s*/[a-zA-Z-]+\s*||')

  # Pre-execute the dispatch script
  RESULT=$(bash "$URC_ROOT/urc/core/urc-dispatch.sh" "$ARG" "${TMUX_PANE:-}" 2>/dev/null)

  # Return result as additional context so the model just displays it
  echo "$RESULT"
  exit 0
fi

# Not a /urc command — pass through silently
exit 0
