#!/usr/bin/env bash
# cli-adapter.sh — CLI detection and CLI-specific parameters
# Usage: source urc/core/cli-adapter.sh, then call detect_cli or paste_delay
# ~35 LOC (excluding comments/blanks)

set -uo pipefail

# Project root: up two levels from urc/core/
_CLI_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CLI_ADAPTER_DB="${_CLI_ADAPTER_DIR}/../../.urc/coordination.db"

validate_pane_id() {
    [[ "$1" =~ ^%[0-9]+$ ]]
}

detect_cli() {
  # $1 = pane_id (e.g. "%42")
  local pane="${1:?detect_cli requires pane_id}"

  # Validate pane ID format before using in SQL
  [[ "$pane" =~ ^%[0-9]+$ ]] || { echo "shell"; return; }

  # Strategy 0: tmux pane option (set by auto-register.sh / urc-spawn.sh, ~5ms)
  local opt_cli
  opt_cli=$(tmux show-options -t "$pane" -pqv @urc_cli 2>/dev/null)
  if [ -n "$opt_cli" ]; then echo "$opt_cli"; return 0; fi

  # Strategy 1: DB lookup (~50ms)
  if [ -f "$_CLI_ADAPTER_DB" ]; then
    local db_cli
    db_cli=$(sqlite3 "$_CLI_ADAPTER_DB" \
      "PRAGMA busy_timeout=3000; SELECT cli FROM agents WHERE pane_id='${pane}' LIMIT 1;" 2>/dev/null | tail -1 || true)
    if [ -n "$db_cli" ]; then
      case "$db_cli" in
        *claude*) echo "claude"; return 0 ;;
        *codex*)  echo "codex";  return 0 ;;
        *gemini*) echo "gemini"; return 0 ;;
      esac
    fi
  fi

  # Strategy 2: Content-based fallback (last 5 lines of pane)
  local buf
  buf=$(tmux capture-pane -t "$pane" -p -S -5 2>/dev/null || true)
  if [ -n "$buf" ]; then
    case "$buf" in
      *[Gg]emini*|*[Gg]oogle*) echo "gemini"; return 0 ;;
      *[Cc]odex*)              echo "codex";  return 0 ;;
      *[Cc]laude*)             echo "claude"; return 0 ;;
    esac
  fi

  # Safe default: shell (just Enter, no Escape) — unknown targets are safer without Escape
  echo "shell"
}

paste_delay() {
  # $1 = cli type ("claude", "codex", "gemini", "shell")
  local cli="${1:?paste_delay requires cli_type}"
  case "$cli" in
    shell) echo "0" ;;
    *)     echo "0.15" ;;
  esac
}
