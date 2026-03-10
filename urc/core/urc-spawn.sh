#!/bin/bash
# urc-spawn.sh — Spawn CLI + relay bridge, fire-and-forget
# Usage: bash urc/core/urc-spawn.sh <MODE> <CLI_TYPE> [TARGET_PANE] [CALLER_PANE]
#   MODE: "spawn" or "bridge"
#   CLI_TYPE: "CODEX" or "GEMINI"
#   TARGET_PANE: required for bridge mode (e.g. %1234)
#   CALLER_PANE: optional, used for tmux split positioning
#
# Examples:
#   bash urc/core/urc-spawn.sh spawn GEMINI "" %1020 &
#   bash urc/core/urc-spawn.sh bridge CODEX %1234 %1020 &

set -euo pipefail

MODE="${1:?Usage: urc-spawn.sh <spawn|bridge> <CODEX|GEMINI> [target_pane] [caller_pane]}"
CLI_TYPE="${2:?Missing CLI_TYPE (CODEX or GEMINI)}"
TARGET_PANE="${3:-}"
CALLER_PANE="${4:-}"

URC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DB_PATH="$URC_ROOT/.urc/coordination.db"
VENV_PYTHON="$URC_ROOT/.venv/bin/python3"

# --- CLI config map ---
case "$CLI_TYPE" in
  CODEX)  LAUNCH_CMD="codex --full-auto"; REGISTER_AS="codex-cli" ;;  # auto-approve: --full-auto
  GEMINI) LAUNCH_CMD="gemini --yolo";     REGISTER_AS="gemini-cli" ;;  # auto-approve: --yolo
  *) echo "ERROR: CLI_TYPE must be CODEX or GEMINI, got: $CLI_TYPE" >&2; exit 1 ;;
esac

# --- Helper: get bridge candidates via direct DB ---
db_get_bridges() {
  "$VENV_PYTHON" -c "
import sqlite3
db = sqlite3.connect('$DB_PATH')
rows = db.execute('SELECT pane_id, label FROM agents WHERE role=\"bridge\" AND label LIKE ?', ('%$CLI_TYPE%',)).fetchall()
for r in rows:
    print(f'{r[0]} {r[1]}')
db.close()
"
}

log() { echo "[urc-spawn] $*" >&2; }

# ============================================================
# Step 1: Spawn CLI pane (spawn mode only)
# ============================================================
if [ "$MODE" = "spawn" ]; then
  log "Spawning $CLI_TYPE pane..."
  SPLIT_TARGET="${CALLER_PANE:-${TMUX_PANE:-urc}}"
  TARGET_PANE=$(tmux split-window -h -d -P -F '#{pane_id}' -t "$SPLIT_TARGET" \
    "cd '$URC_ROOT' && $LAUNCH_CMD; EC=\$?; [ \$EC -ne 0 ] && echo \"\$(date '+%H:%M:%S') $CLI_TYPE crashed (exit \$EC)\" >> '$URC_ROOT/.urc/crashes.log' && tmux display-message \"$CLI_TYPE crashed (exit \$EC)\" && sleep 10")
  log "CLI pane: $TARGET_PANE"
  sleep 5
  log "Spawned $TARGET_PANE as $REGISTER_AS (auto-registers via MCP)"
elif [ "$MODE" = "bridge" ]; then
  if [ -z "$TARGET_PANE" ]; then
    log "ERROR: bridge mode requires TARGET_PANE"
    exit 1
  fi
  # Verify target exists
  if ! tmux display-message -t "$TARGET_PANE" -p '#{pane_id}' >/dev/null 2>&1; then
    log "ERROR: Target pane $TARGET_PANE does not exist"
    exit 1
  fi
else
  log "ERROR: MODE must be 'spawn' or 'bridge', got: $MODE"
  exit 1
fi

# ============================================================
# Step 2: Check for orphaned relay
# ============================================================
log "Checking for orphaned relays..."
ORPHAN_RELAY=""
while IFS=' ' read -r candidate_pane _; do
  [ -z "$candidate_pane" ] && continue
  # Is the candidate bridge pane alive in tmux?
  if ! tmux display-message -t "$candidate_pane" -p '#{pane_id}' >/dev/null 2>&1; then
    continue  # Bridge pane itself is dead, skip
  fi
  # Read its current target
  old_target=$(tmux show-options -pv -t "$candidate_pane" @bridge_target 2>/dev/null || true)
  [ -z "$old_target" ] && continue
  # Is the old target dead?
  if ! tmux display-message -t "$old_target" -p '#{pane_id}' >/dev/null 2>&1; then
    ORPHAN_RELAY="$candidate_pane"
    log "Found orphaned relay: $ORPHAN_RELAY (old target $old_target is dead)"
    break
  fi
done < <(db_get_bridges || true)

if [ -n "$ORPHAN_RELAY" ]; then
  log "Re-pairing orphan $ORPHAN_RELAY → $TARGET_PANE"
  tmux set-option -p -t "$ORPHAN_RELAY" @bridge_target "$TARGET_PANE"
  tmux set-option -p -t "$TARGET_PANE" @bridge_relay "$ORPHAN_RELAY"
  bash "$URC_ROOT/urc/core/send.sh" "$ORPHAN_RELAY" "__urc_refresh__" --cli claude >/dev/null 2>&1
  RELAY_PANE="$ORPHAN_RELAY"
  log "Re-paired. Relay: $RELAY_PANE, Target: $TARGET_PANE ($CLI_TYPE)"
  echo "{\"status\":\"ready\",\"relay\":\"$RELAY_PANE\",\"target\":\"$TARGET_PANE\",\"cli\":\"$CLI_TYPE\",\"method\":\"re-paired\"}"
  exit 0
fi

# ============================================================
# Step 3: Spawn relay pane
# ============================================================
log "Spawning relay pane..."
# auto-approve: relay uses --dangerously-skip-permissions
RELAY_PANE=$(tmux split-window -v -d -P -F '#{pane_id}' -t "$TARGET_PANE" \
  "cd '$URC_ROOT' && source .venv/bin/activate && unset CLAUDECODE && export CLAUDE_CODE_REMOTE_SEND_KEEPALIVES=true && claude --agent rc-bridge --model haiku --dangerously-skip-permissions; EC=\$?; [ \$EC -ne 0 ] && echo \"\$(date '+%H:%M:%S') Relay crashed (exit \$EC)\" >> '$URC_ROOT/.urc/crashes.log' && tmux display-message \"RC Bridge relay crashed (exit \$EC)\" && sleep 10")
log "Relay pane: $RELAY_PANE"

# ============================================================
# Step 4: Pre-set tmux state + wait for boot + activate
# ============================================================
# Pre-set bridge state on the relay pane BEFORE Claude boots.
# The agent reads these on its first turn (lazy bootstrap) — no text
# bootstrap message needed, so no user bubble appears on the phone.
log "Pre-setting bridge state on relay pane..."
tmux set-option -p -t "$RELAY_PANE" @bridge_target "$TARGET_PANE"
tmux set-option -p -t "$RELAY_PANE" @bridge_cli "$CLI_TYPE"
tmux set-option -p -t "$RELAY_PANE" @bridge_relays 0
tmux set-option -p -t "$TARGET_PANE" @bridge_relay "$RELAY_PANE"

# Pre-register relay in coordination DB (so fleet sees it immediately)
TARGET_NUM="${TARGET_PANE#%}"
RELAY_LABEL="(${TARGET_NUM}) ${CLI_TYPE}"
"$VENV_PYTHON" -c "
import sqlite3, time
db = sqlite3.connect('$DB_PATH')
db.execute('INSERT OR REPLACE INTO agents (pane_id, cli, role, status, label, registered_at) VALUES (?, ?, ?, ?, ?, ?)',
           ('$RELAY_PANE', 'claude-code', 'bridge', 'active', '$RELAY_LABEL', int(time.time())))
db.commit()
db.close()
" 2>/dev/null && log "Registered relay as '$RELAY_LABEL'" || log "WARN: DB registration failed (non-fatal)"

log "Waiting for relay boot..."
sleep 10

if ! tmux display-message -t "$RELAY_PANE" -p '#{pane_id}' >/dev/null 2>&1; then
  log "ERROR: Relay pane $RELAY_PANE died during startup"
  echo "{\"status\":\"failed\",\"error\":\"relay_died\",\"relay\":\"$RELAY_PANE\",\"target\":\"$TARGET_PANE\"}"
  exit 1
fi

# ============================================================
# Step 5: Name session + activate /remote-control
# ============================================================
# /rename sets the conversation title — no user bubble, no model turn.
log "Naming session: (${TARGET_NUM}) ${CLI_TYPE}"
bash "$URC_ROOT/urc/core/send.sh" "$RELAY_PANE" "/rename (${TARGET_NUM}) ${CLI_TYPE}" --cli claude >/dev/null 2>&1
sleep 2

log "Activating /remote-control..."
bash "$URC_ROOT/urc/core/send.sh" "$RELAY_PANE" "/remote-control" --cli claude >/dev/null 2>&1

# ============================================================
# Step 6: Report result via stdout (consumed by run_in_background)
# ============================================================
log "Bridge ready! Relay: $RELAY_PANE, Target: $TARGET_PANE ($CLI_TYPE)"
echo "{\"status\":\"ready\",\"relay\":\"$RELAY_PANE\",\"target\":\"$TARGET_PANE\",\"cli\":\"$CLI_TYPE\",\"method\":\"new\"}"
