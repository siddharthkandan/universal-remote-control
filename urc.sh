#!/bin/bash
# urc — Quick launcher for ! bash mode in Claude Code
# Usage: ! ./urc.sh gemini    (instant, no LLM)
#        ! ./urc.sh codex     (instant, no LLM)
#        ! ./urc.sh %1234     (bridge existing pane)
#        ! ./urc.sh           (list available panes)
exec bash "$(dirname "$0")/urc/core/urc-dispatch.sh" "$@"
