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
