#!/usr/bin/env bash
# agent-context-init.sh — Per-session initialization for ALL session starts
# Runs on ALL session starts (including agent spawns via `claude --agent`).
# Responsibilities:
#   1. Agent-context marker for session role detection
#   2. Context-state file init to prevent stale % on fresh sessions
#   3. Pane-keyed peer registration in state.json

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
    PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
fi
[ -z "$PROJECT_DIR" ] && exit 0

# Resolve pane identity — $TMUX_PANE is canonical
_resolve_pane_id() {
    local _pane="${TMUX_PANE:-}"
    if [ -n "$_pane" ]; then
        printf '%s' "$_pane"
        return
    fi
    # Non-tmux fallback: synthetic ID with PID + entropy
    printf 'local-%s-%s' "$$" "$RANDOM"
}

# Resolve role from agent type
_resolve_role() {
    case "${AGENT_TYPE:-}" in
        architect*|researcher*|historian*|engineer*)
            printf '%s' "${AGENT_TYPE%%-*}"
            ;;
        *)
            printf 'claude'
            ;;
    esac
}

# Resolve CLI type from agent type
_resolve_cli() {
    case "${AGENT_TYPE:-}" in
        codex*)  printf 'codex-cli' ;;
        gemini*) printf 'gemini-cli' ;;
        *)       printf 'claude-code' ;;
    esac
}

# Pane-keyed registration in state.json
register_current_pane() {
    local _pane _state_file _state_dir _now _role _cli _epoch _boot_id

    _pane=$(_resolve_pane_id)
    [ -n "$_pane" ] || return 0

    _state_file="$PROJECT_DIR/.urc/bridge/state.json"
    _state_dir=$(dirname "$_state_file")
    mkdir -p "$_state_dir" 2>/dev/null || true

    # Initialize state.json with v5 schema if missing
    if [ ! -f "$_state_file" ]; then
        _boot_id=$(tmux display-message -p '#{start_time}' 2>/dev/null || echo "unknown")
        printf '{"schema_version":5,"server_boot_id":"%s","peers":{},"roles":{},"pane_layout":{},"reset_lock":{"held_by":null,"acquired_at":null,"expires_at":null},"teams":{}}' \
            "$_boot_id" > "$_state_file" 2>/dev/null || return 0
    fi

    # Source atomic write library (concurrent SessionStart writes need locking)
    local _sw_lib="$PROJECT_DIR/urc/lib/state-write.sh"
    if [ -f "$_sw_lib" ]; then
        # shellcheck source=/dev/null
        source "$_sw_lib"
    fi

    _role=$(_resolve_role)
    _cli=$(_resolve_cli)
    _now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _epoch=""
    [ -n "$SESSION_ID" ] && _epoch="${SESSION_ID:0:8}"

    # Register under pane key with v5 schema fields (atomic write)
    if declare -F sw_atomic_jq >/dev/null 2>&1; then
        sw_atomic_jq "$_state_file" \
            '
            .schema_version = (.schema_version // 5)
            | .peers = (.peers // {})
            | .peers[$p] = (
                (.peers[$p] // {})
                + {cli:$cli, role:$role, status:"active", last_seen:$ts,
                   session_epoch:(if $epoch == "" then null else $epoch end),
                   context_pct:null}
              )
            | .roles = (.roles // {})
            | .roles[$role] = ((.roles[$role] // []) + [$p] | unique)
            ' \
            --arg p "$_pane" \
            --arg cli "$_cli" \
            --arg role "$_role" \
            --arg epoch "$_epoch" \
            --arg ts "$_now" \
            2>/dev/null || return 0
    else
        # Fallback: raw jq (state-write.sh not available)
        local _tmp="${_state_file}.tmp.$$"
        jq \
            --arg p "$_pane" \
            --arg cli "$_cli" \
            --arg role "$_role" \
            --arg epoch "$_epoch" \
            --arg ts "$_now" \
            '
            .schema_version = (.schema_version // 5)
            | .peers = (.peers // {})
            | .peers[$p] = (
                (.peers[$p] // {})
                + {cli:$cli, role:$role, status:"active", last_seen:$ts,
                   session_epoch:(if $epoch == "" then null else $epoch end),
                   context_pct:null}
              )
            | .roles = (.roles // {})
            | .roles[$role] = ((.roles[$role] // []) + [$p] | unique)
            ' \
            "$_state_file" > "$_tmp" 2>/dev/null || {
                rm -f "$_tmp"
                return 0
            }
        mv "$_tmp" "$_state_file" 2>/dev/null || rm -f "$_tmp"
    fi
}

# Write agent-context marker for role detection
if [ -n "$AGENT_TYPE" ] && [ -n "$SESSION_ID" ]; then
    mkdir -p "$PROJECT_DIR/.claude" 2>/dev/null || true
    printf '%s' "$AGENT_TYPE" > "$PROJECT_DIR/.claude/.agent-context-${SESSION_ID:0:8}" 2>/dev/null || true
fi

# Initialize context-state files for pane scope
if [ -n "$SESSION_ID" ] || [ -n "${TMUX_PANE:-}" ]; then
    mkdir -p "$PROJECT_DIR/.claude" 2>/dev/null || true

    PREFIX="${SESSION_ID:0:8}"
    SESSION_TARGET=""
    SESSION_TARGET_PATH=""
    if [ -n "$SESSION_ID" ]; then
        SESSION_TARGET="context-state-${PREFIX}.json"
        SESSION_TARGET_PATH="$PROJECT_DIR/.claude/$SESSION_TARGET"
        if [ ! -f "$SESSION_TARGET_PATH" ]; then
            printf '{"pct":0,"session_id":"%s","cost":0,"model":"?"}' "$SESSION_ID" \
                > "$SESSION_TARGET_PATH" 2>/dev/null || true
        fi
    fi

    PANE_TARGET=""
    PANE_TARGET_PATH=""
    if [ -n "${TMUX_PANE:-}" ]; then
        PANE_TARGET="context-state-${TMUX_PANE}.json"
        PANE_TARGET_PATH="$PROJECT_DIR/.claude/$PANE_TARGET"
        if [ -n "$SESSION_TARGET" ]; then
            # Symlink pane file -> session file so hooks read real context %
            ln -sf "$SESSION_TARGET" "$PANE_TARGET_PATH" 2>/dev/null || true
        elif [ ! -f "$PANE_TARGET_PATH" ]; then
            printf '{"pct":0,"session_id":"%s","cost":0,"model":"?"}' "${SESSION_ID:-unknown}" \
                > "$PANE_TARGET_PATH" 2>/dev/null || true
        fi
    fi

    SYMLINK_PATH="$PROJECT_DIR/.claude/context-state.json"
    if [ -n "$PANE_TARGET" ]; then
        ln -sf "$PANE_TARGET" "$SYMLINK_PATH" 2>/dev/null || true
    elif [ -n "$SESSION_TARGET" ]; then
        ln -sf "$SESSION_TARGET" "$SYMLINK_PATH" 2>/dev/null || true
    fi
fi

# Register the current pane in state.json
register_current_pane

# Clean up stale agent-context markers (>24h old)
for f in "$PROJECT_DIR"/.claude/.agent-context-*; do
    [ -f "$f" ] || continue
    if [ "$(uname)" = "Darwin" ]; then
        FMTIME=$(stat -f %m "$f" 2>/dev/null || echo 0)
    else
        FMTIME=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    fi
    FAGE=$(($(date +%s) - ${FMTIME:-0}))
    if [ "$FAGE" -gt 86400 ]; then
        rm -f "$f"
    fi
done
