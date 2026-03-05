#!/bin/bash
# urc-dispatch.sh — Thin CLI dispatcher for /urc skill
# Does preflight + arg parse + fires urc-spawn.sh in background
# Usage: bash urc/core/urc-dispatch.sh [codex|gemini|%NNNN|NNNN] [caller_pane]
#
# Returns immediately after launching background spawn.

URC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARG="${1:-}"
CALLER="${2:-${TMUX_PANE:-}}"

# --- Preflight ---
if ! command -v tmux &>/dev/null; then
  echo '{"status":"error","error":"tmux not installed"}'
  exit 1
fi
if ! tmux has-session 2>/dev/null; then
  echo '{"status":"error","error":"no tmux session"}'
  exit 1
fi

# --- Parse argument ---
ARG_LOWER=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')

case "$ARG_LOWER" in
  codex)
    DEDUP="/tmp/urc-dispatch-CODEX.ts"
    NOW=$(date +%s)
    if [ -f "$DEDUP" ]; then
      LAST=$(cat "$DEDUP" 2>/dev/null || echo 0)
      if [ $((NOW - LAST)) -lt 15 ]; then
        echo '{"status":"delegated","cli":"CODEX","note":"already_in_progress"}'
        exit 0
      fi
    fi
    echo "$NOW" > "$DEDUP"
    bash "$URC_ROOT/urc/core/urc-spawn.sh" spawn CODEX "" "$CALLER" &
    echo "{\"status\":\"delegated\",\"cli\":\"CODEX\",\"pid\":$!}"
    ;;
  gemini)
    DEDUP="/tmp/urc-dispatch-GEMINI.ts"
    NOW=$(date +%s)
    if [ -f "$DEDUP" ]; then
      LAST=$(cat "$DEDUP" 2>/dev/null || echo 0)
      if [ $((NOW - LAST)) -lt 15 ]; then
        echo '{"status":"delegated","cli":"GEMINI","note":"already_in_progress"}'
        exit 0
      fi
    fi
    echo "$NOW" > "$DEDUP"
    bash "$URC_ROOT/urc/core/urc-spawn.sh" spawn GEMINI "" "$CALLER" &
    echo "{\"status\":\"delegated\",\"cli\":\"GEMINI\",\"pid\":$!}"
    ;;
  %*|[0-9]*)
    # Pane ID — ensure % prefix
    PANE="$ARG"
    [[ "$PANE" != %* ]] && PANE="%$PANE"
    # Verify exists
    if ! tmux display-message -t "$PANE" -p '#{pane_id}' >/dev/null 2>&1; then
      echo "{\"status\":\"error\",\"error\":\"pane $PANE not found\"}"
      exit 1
    fi
    # Detect CLI type
    CMD=$(tmux display-message -t "$PANE" -p '#{pane_current_command}' 2>/dev/null)
    if echo "$CMD" | grep -qi codex; then
      CLI=CODEX
    elif echo "$CMD" | grep -qi gemini; then
      CLI=GEMINI
    else
      # Fallback: check DB
      CLI=$("$URC_ROOT/.venv/bin/python3" -c "
import sqlite3
db = sqlite3.connect('$URC_ROOT/.urc/coordination.db')
row = db.execute('SELECT cli FROM agents WHERE pane_id=?',('$PANE',)).fetchone()
db.close()
if row:
    c = row[0].lower()
    if 'codex' in c: print('CODEX')
    elif 'gemini' in c: print('GEMINI')
    else: print('UNKNOWN')
else: print('UNKNOWN')
" 2>/dev/null)
      if [ "$CLI" = "UNKNOWN" ]; then
        echo "{\"status\":\"error\",\"error\":\"can't detect CLI type for $PANE\"}"
        exit 1
      fi
    fi
    DEDUP="/tmp/urc-dispatch-bridge-${PANE}.ts"
    NOW=$(date +%s)
    if [ -f "$DEDUP" ]; then
      LAST=$(cat "$DEDUP" 2>/dev/null || echo 0)
      if [ $((NOW - LAST)) -lt 15 ]; then
        echo "{\"status\":\"delegated\",\"cli\":\"$CLI\",\"target\":\"$PANE\",\"note\":\"already_in_progress\"}"
        exit 0
      fi
    fi
    echo "$NOW" > "$DEDUP"
    bash "$URC_ROOT/urc/core/urc-spawn.sh" bridge "$CLI" "$PANE" "$CALLER" &
    echo "{\"status\":\"delegated\",\"cli\":\"$CLI\",\"target\":\"$PANE\",\"pid\":$!}"
    ;;
  "")
    # List un-bridged panes
    echo "=== Un-bridged CLI panes ==="
    tmux list-panes -a -F '#{pane_id} #{pane_current_command}' 2>/dev/null | grep -iE 'codex|gemini' || echo "(none found)"
    echo ""
    echo "Run /urc codex or /urc gemini to spawn new."
    ;;
  *)
    echo "{\"status\":\"error\",\"error\":\"unknown argument: $ARG\"}"
    exit 1
    ;;
esac
