#!/bin/bash
# dispatch-exec.sh — One-shot headless CLI execution
# Usage: bash urc/core/dispatch-exec.sh <cli> <prompt> [timeout]
# Returns: stdout from CLI (text or JSON depending on CLI flags)
#
# LIMITATIONS:
# - gemini -p: MCP tools are DISABLED by default in non-interactive mode.
#   Only works for self-contained tasks that don't need URC coordination tools.
# - codex exec --ephemeral: No session persistence — cannot resume.
# - All: No tmux pane — no live visibility into execution progress.

set -uo pipefail

CLI="${1:?Usage: dispatch-exec.sh <claude|codex|gemini> <prompt> [timeout]}"
PROMPT="${2:?Missing prompt}"
TIMEOUT="${3:-120}"

case "$CLI" in
    claude)
        timeout "$TIMEOUT" claude -p "$PROMPT" 2>/dev/null
        ;;
    codex)
        timeout "$TIMEOUT" codex exec --json --full-auto --ephemeral "$PROMPT" 2>/dev/null
        ;;
    gemini)
        # NOTE: MCP disabled in non-interactive mode — self-contained tasks only
        timeout "$TIMEOUT" gemini -p "$PROMPT" -o json --yolo 2>/dev/null
        ;;
    *)
        echo "{\"error\":\"Unknown CLI: $CLI\"}" >&2
        exit 1
        ;;
esac
EXIT=$?
[ "$EXIT" -eq 124 ] && echo "{\"error\":\"timeout after ${TIMEOUT}s\",\"cli\":\"$CLI\"}" >&2
exit $EXIT
