#!/usr/bin/env bash
# observer.sh — Peer state detection library
#
# Provides: pane_exists(), detect_state(), resolve_pane()
# Source this file — do NOT execute directly.
#
# Dependencies: tmux, jq (for resolve_pane fallback)
# Optional: python3 (for SQLite coordination DB queries)
# Bash 3.2 compatible.
#
# Standalone mode: When .urc/coordination.db or
# .urc/bridge/state.json don't exist, all functions
# return sensible defaults (UNKNOWN state, pane_id as name,
# "unknown" CLI type). No errors are raised.

pane_exists() {
  # Capture pane list first, then grep. Avoids SIGPIPE when
  # grep -q exits early and tmux gets killed — which returns 141 under
  # pipefail (set in tmux-send-helper.sh), causing false "not exists".
  local _pe_list
  _pe_list="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"
  printf '%s\n' "$_pe_list" | grep -qx "$1"
}

detect_state() {
  local peer="$1" pane="$2"

  # Resolve peer name from pane ID for logging
  if [[ "$peer" == %* ]]; then
    local _ds_resolved
    _ds_resolved=$(resolve_peer_from_pane "$peer" 2>/dev/null)
    [ -n "$_ds_resolved" ] && peer="$_ds_resolved"
  fi

  if ! pane_exists "$pane"; then
    echo "OFFLINE"
    return
  fi

  # PRIMARY — read agent state from SQLite coordination DB.
  local _ds_project_dir="${PROJECT_DIR:-.}"
  local _ds_db="$_ds_project_dir/.urc/coordination.db"
  if [ -f "$_ds_db" ] && command -v python3 >/dev/null 2>&1; then
    local _ds_status
    _ds_status=$(python3 -c "
import sqlite3, sys
try:
    conn = sqlite3.connect(sys.argv[1], timeout=1)
    conn.row_factory = sqlite3.Row
    row = conn.execute('SELECT status FROM agents WHERE pane_id = ?', (sys.argv[2],)).fetchone()
    conn.close()
    if row: print(row['status'])
    else: print('')
except: print('')
" "$_ds_db" "$pane" 2>/dev/null)
    if [ -n "$_ds_status" ]; then
      # Map SQLite status → observer.sh state names
      case "$_ds_status" in
        active|processing) echo "PROCESSING" ; return ;;
        idle)              echo "IDLE"        ; return ;;
        thinking)          echo "PROCESSING"  ; return ;;
        stuck)             echo "STUCK_INPUT" ; return ;;
        crashed|offline)   echo "OFFLINE"     ; return ;;
        shutdown)          echo "OFFLINE"     ; return ;;
      esac
    fi
  fi

  # FALLBACK — tmux silence-based detection (no buffer scraping).
  # If SQLite unavailable, check tmux silence hook state.
  local _ds_events="$_ds_project_dir/.urc/events.log"
  if [ -f "$_ds_events" ]; then
    local _ds_last_event
    _ds_last_event=$(grep "$pane" "$_ds_events" 2>/dev/null | tail -1 | awk '{print $3}')
    case "$_ds_last_event" in
      silence)  echo "IDLE"       ; return ;;
      activity) echo "PROCESSING" ; return ;;
    esac
  fi

  # Ultimate fallback: pane exists but no state info
  echo "UNKNOWN"
}

# Dynamic pane resolution instead of hardcoded pane IDs
# Requires PROJECT_DIR to be set by the sourcing script.
resolve_pane() {
    local peer="$1"
    local _resolve_project_dir="${PROJECT_DIR:-.}"

    # If peer is already a pane ID (%NNN), return it directly
    if [[ "$peer" == %* ]]; then
        printf '%s' "$peer"
        return 0
    fi

    local state="$_resolve_project_dir/.urc/bridge/state.json"
    if [ -f "$state" ]; then
        local _schema_ver
        _schema_ver=$(jq -r '.schema_version // .version // 0' "$state" 2>/dev/null)
        if [ "$_schema_ver" = "5" ]; then
            # v5: resolve via roles index first, then logical_peer_id
            # Phase 3 fix: filter by active/alive status to avoid returning
            # stale/offline panes. Default "active" for entries missing status.
            local _pane
            _pane=$(jq -r --arg r "$peer" '
                . as $root |
                [$root.roles[$r] // [] | .[] |
                 select(. as $p |
                   ($root.peers[$p].status // "active") |
                   test("^(active|idle|online)$")
                 )] | .[0] // empty
            ' "$state" 2>/dev/null)
            if [ -n "$_pane" ]; then
                printf '%s' "$_pane"
                return 0
            fi
            _pane=$(jq -r --arg lp "$peer" '
                . as $root |
                [$root.peers | to_entries[] |
                 select(.value.logical_peer_id == $lp) |
                 select((.value.status // "active") | test("^(active|idle|online)$")) |
                 .key] | .[0] // empty
            ' "$state" 2>/dev/null)
            if [ -n "$_pane" ]; then
                printf '%s' "$_pane"
                return 0
            fi
        fi
    fi

    # Fallback: direct pane_id lookup from state.json
    if [ -f "$state" ]; then
        jq -r --arg p "$peer" '.peers[$p].pane_id // empty' "$state" 2>/dev/null
    fi
}

# Derive CLI type from peer name. Used for injection strategy selection.
# Maps peer keys (including operator-qualified keys like claude-a1, em-alpha)
# to the CLI binary type they run on.
resolve_cli_type() {
    local peer="$1"

    # If peer is a pane ID (%NNN), look up CLI type
    if [[ "$peer" == %* ]]; then
        local _resolve_project_dir="${PROJECT_DIR:-.}"
        # Try SQLite first (requires python3)
        local _rct_db="$_resolve_project_dir/.urc/coordination.db"
        if [ -f "$_rct_db" ] && command -v python3 >/dev/null 2>&1; then
            local _rct_cli
            _rct_cli=$(python3 -c "
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1], timeout=1)
    c.row_factory = sqlite3.Row
    r = c.execute('SELECT cli FROM agents WHERE pane_id = ?', (sys.argv[2],)).fetchone()
    c.close()
    print(r['cli'] if r and r['cli'] else '')
except: print('')
" "$_rct_db" "$peer" 2>/dev/null)
            case "$_rct_cli" in
                claude-code|claude) echo "claude"; return ;;
                codex-cli|codex)    echo "codex"; return ;;
                gemini-cli|gemini)  echo "gemini"; return ;;
            esac
        fi
        # Fallback: state.json
        local state="$_resolve_project_dir/.urc/bridge/state.json"
        if [ -f "$state" ]; then
            local _cli _role
            _cli=$(jq -r --arg p "$peer" '.peers[$p].cli // empty' "$state" 2>/dev/null)
            case "$_cli" in
                claude-code|claude) echo "claude"; return ;;
                codex-cli|codex)    echo "codex"; return ;;
                gemini-cli|gemini)  echo "gemini"; return ;;
            esac
            # Fallback: infer from role
            _role=$(jq -r --arg p "$peer" '.peers[$p].role // empty' "$state" 2>/dev/null)
            case "$_role" in
                claude*|operator|researcher*|architect*)
                    echo "claude"; return ;;
                codex*)
                    echo "codex"; return ;;
                gemini*)
                    echo "gemini"; return ;;
            esac
        fi
        echo "unknown"
        return
    fi

    case "$peer" in
        claude|claude-code|claude-*|em|em-*|researcher|researcher-*|architect|architect-*)
                                                           echo "claude" ;;
        codex|codex-cli|codex-*)                           echo "codex" ;;
        gemini|gemini-cli|gemini-*)                        echo "gemini" ;;
        *)                                                 echo "unknown" ;;
    esac
}

# Reverse-lookup peer name from pane ID.
# When tmux-send-helper targets a direct pane ID (%NNN), we need the peer name
# to select the correct idle detection heuristic. Without this, direct pane IDs
# default to "claude" detection, which silently fails for Codex/Gemini panes
# (always returns PROCESSING because it looks for >, ❯, ✦ prompt chars).
#
# Strategy: SQLite DB → state.json reverse lookup → content-based inference → pane_id fallback.
resolve_peer_from_pane() {
    local pane_id="$1"
    local _rpp_project_dir="${PROJECT_DIR:-.}"

    # Strategy 0 — SQLite coordination DB (fastest, requires python3)
    local _rpp_db="$_rpp_project_dir/.urc/coordination.db"
    if [ -f "$_rpp_db" ] && command -v python3 >/dev/null 2>&1; then
        local _rpp_role
        _rpp_role=$(python3 -c "
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1], timeout=1)
    c.row_factory = sqlite3.Row
    r = c.execute('SELECT role FROM agents WHERE pane_id = ?', (sys.argv[2],)).fetchone()
    c.close()
    print(r['role'] if r and r['role'] else '')
except: print('')
" "$_rpp_db" "$pane_id" 2>/dev/null)
        if [ -n "$_rpp_role" ]; then
            printf '%s' "$_rpp_role"
            return
        fi
    fi

    local state_file="$_rpp_project_dir/.urc/bridge/state.json"

    # Strategy 1: Reverse lookup in state.json (v5 + v4)
    if [ -f "$state_file" ] && command -v jq >/dev/null 2>&1; then
        local _schema_ver found
        _schema_ver=$(jq -r '.schema_version // .version // 0' "$state_file" 2>/dev/null)
        if [ "$_schema_ver" = "5" ]; then
            # v5: pane IS the key — return logical_peer_id or role
            found=$(jq -r --arg p "$pane_id" '
                .peers[$p] | .logical_peer_id // .role // empty
            ' "$state_file" 2>/dev/null)
        else
            # v4: reverse lookup by pane_id field value
            found=$(jq -r --arg p "$pane_id" '
                .peers | to_entries[]
                | select(.value.pane_id == $p)
                | .key' "$state_file" 2>/dev/null | head -1)
        fi
        if [ -n "$found" ]; then
            printf '%s' "$found"
            return
        fi
    fi

    # Strategy 2: Content-based inference from pane buffer
    # Use -S -20 (not -S -5) because CLI markers like '? for shortcuts'
    # can scroll above the prompt zone when output is long.
    if pane_exists "$pane_id"; then
        local _rpp_buf
        _rpp_buf="$(tmux capture-pane -t "$pane_id" -p -S -20 2>/dev/null || true)"
        if printf '%s' "$_rpp_buf" | grep -Fq '? for shortcuts'; then
            printf 'codex'
            return
        fi
        # Codex status bar: "gpt-*-codex" model string or "› " prompt char (U+203A)
        if printf '%s' "$_rpp_buf" | grep -Eq 'gpt-[^ ]*codex'; then
            printf 'codex'
            return
        fi
        if printf '%s' "$_rpp_buf" | grep -Eq '^[[:space:]]*›[[:space:]]'; then
            printf 'codex'
            return
        fi
        if printf '%s' "$_rpp_buf" | grep -Eq 'Gemini [0-9]|no sandbox.*Auto|YOLO mode'; then
            printf 'gemini'
            return
        fi
        if printf '%s' "$_rpp_buf" | grep -Eq '^[[:space:]]*[>❯✦]'; then
            printf 'claude'
            return
        fi
    fi

    # Fallback: return pane_id as-is when no DB or state.json available
    printf '%s' "$pane_id"
}

# ── Instruction pane-target validation ────────────────────────────
# Extract pane ID from a bridge instruction filename.
# Pattern: {peer}-pane{NNN}-{timestamp}... or {peer}-pane{NNN}.md
# Returns the pane number (e.g., "250") or empty if no pane specifier.
extract_instruction_pane_id() {
    local _eip_filename
    _eip_filename=$(basename "$1")
    local _eip_pat='-pane([0-9]+)[-.]'
    if [[ "$_eip_filename" =~ $_eip_pat ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Validate that an instruction file is targeted at the given pane.
# Returns 0 if valid (or no pane specifier in name), 1 if pane mismatch.
# Usage: validate_instruction_pane_target "path/claude-pane250-ts.md" "%256"
validate_instruction_pane_target() {
    local _vit_file="$1" _vit_target="$2"
    local _vit_file_pane _vit_target_num
    _vit_file_pane=$(extract_instruction_pane_id "$_vit_file")
    [ -z "$_vit_file_pane" ] && return 0
    _vit_target_num="${_vit_target#%}"
    [ "$_vit_file_pane" = "$_vit_target_num" ]
}

# ── Session group boundary guard ──────────────────────────────────
# Check whether sender and target panes belong to the same session group.
# Returns 0 if same group, no groups defined, or either pane is ungrouped.
# Returns 1 if cross-group (different named groups).
# Usage: check_session_group <sender_pane> <target_pane>
check_session_group() {
    local sender="$1" target="$2"

    # Environment override — allows cross-group sends explicitly
    [ "${URC_ALLOW_CROSS_GROUP:-0}" = "1" ] && return 0

    local state_file="${URC_PROJECT_DIR:-.}/.urc/bridge/state.json"
    [ -f "$state_file" ] || return 0

    # Find sender's group
    local sender_group target_group
    sender_group=$(jq -r --arg p "$sender" '
        .session_groups // {} | to_entries[]
        | select(.value.members | index($p))
        | .key' "$state_file" 2>/dev/null | head -1)

    # Ungrouped sender = allow
    [ -z "$sender_group" ] && return 0

    # Find target's group
    target_group=$(jq -r --arg p "$target" '
        .session_groups // {} | to_entries[]
        | select(.value.members | index($p))
        | .key' "$state_file" 2>/dev/null | head -1)

    # Ungrouped target = allow
    [ -z "$target_group" ] && return 0

    # Same group = allow
    [ "$sender_group" = "$target_group" ] && return 0

    # Cross-group detected
    return 1
}

# Enforce atomic send pattern — NEVER separate text and Enter in tmux send-keys
# Usage: send_to_peer <peer> "prompt text"
# This wrapper resolves the pane dynamically and sends text+Enter atomically.
# Returns 0 on success, 1 if pane not found, 2 if peer not idle.
send_to_peer() {
    local peer="$1" text="$2"
    local pane
    pane=$(resolve_pane "$peer")
    if [ -z "$pane" ]; then
        echo "ERROR: Cannot resolve pane for $peer" >&2
        return 1
    fi
    local state
    state=$(detect_state "$peer" "$pane")
    if [ "$state" != "IDLE" ]; then
        echo "WARN: $peer is $state, not IDLE. Aborting send." >&2
        return 2
    fi
    # ATOMIC: text and Enter in a single tmux send-keys invocation (never separate)
    tmux send-keys -t "$pane" "$text" Enter
}

