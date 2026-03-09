#!/usr/bin/env bash
# inbox-watcher.sh — Block until inbox message arrives (Layer 5)
# Usage: bash urc/core/inbox-watcher.sh [timeout_seconds]
# Designed for Bash(run_in_background=true) — completes when message arrives,
# triggering a new agent turn automatically.
#
# Stdout: "INBOX_READY" (message waiting) or "TIMEOUT" (no message within timeout)
# Exit:   0 always (background task completion should always notify agent)
#
# Signal file lifecycle: created by send_message(notify=true) in server.py,
# cleared by receive_messages() in server.py. This script only reads it.

set -uo pipefail

PANE="${TMUX_PANE:-%unknown}"
TIMEOUT="${1:-120}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SIGNAL_FILE="$PROJECT_DIR/.urc/inbox/${PANE}.signal"

# Pane ID validation (matches send.sh/wait.sh pattern)
[[ "$PANE" =~ ^%[0-9]+$ ]] || { echo "TIMEOUT"; exit 0; }

# Ensure inbox directory exists
mkdir -p "$(dirname "$SIGNAL_FILE")"

# Fast path: signal file already exists — messages waiting
if [ -f "$SIGNAL_FILE" ]; then
  echo "INBOX_READY"
  exit 0
fi

# Watchdog: fire the tmux signal after timeout to unblock wait-for
(sleep "$TIMEOUT" && tmux wait-for -S "urc_inbox_${PANE}" 2>/dev/null) &
WDPID=$!

# EXIT trap: clean up watchdog on any exit (SIGTERM, SIGINT, etc.)
trap 'kill $WDPID 2>/dev/null; wait $WDPID 2>/dev/null' EXIT

# Block until signaled (zero CPU — tmux wait-for is kernel-level)
# send_message(notify=true) fires: tmux wait-for -S "urc_inbox_{pane}"
tmux wait-for "urc_inbox_${PANE}" 2>/dev/null

# Report result
if [ -f "$SIGNAL_FILE" ]; then
  echo "INBOX_READY"
else
  echo "TIMEOUT"
fi
