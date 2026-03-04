#!/usr/bin/env bash
# turn-complete-hook.sh — Universal turn-completion notification.
#
# Called by:
#   - Codex: notify = ["bash", "urc/core/turn-complete-hook.sh"] in .codex/config.toml
#   - Gemini: AfterAgent hook in .gemini/settings.json (nested format: matcher.hooks[])
#   - Claude: Stop hook in .claude/settings.json (also calls report_event() MCP tool)
#
# Touches a signal file to wake the orchestrator's polling loop immediately.
# Outputs JSON for Gemini hook compliance (Codex ignores stdout).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGNAL_FILE="$PROJECT_ROOT/.urc/turn_signal"
PANE="${TMUX_PANE:-${URC_PANE_ID:-unknown}}"

mkdir -p "$(dirname "$SIGNAL_FILE")"
touch "$SIGNAL_FILE"

# Audit line for debugging missed wakeups
echo "$(date +%s) ${PANE} turn_complete" >> "$PROJECT_ROOT/.urc/events.log"

# Per-pane signal file for filesystem-based polling
mkdir -p "$PROJECT_ROOT/.urc/signals"
touch "$PROJECT_ROOT/.urc/signals/done_${PANE}"

# Gemini AfterAgent requires JSON response on stdout; Codex ignores it
echo '{"continue": true}'
