#!/bin/bash
# bridge-push-hook.sh — UserPromptSubmit hook for RC Bridge panes
# Reads push files on wake token, returns content via additionalContext.
# Model echoes the content as plain text — zero Bash blocks for push reading.
#
# Registration: .claude/settings.json (project-level, NOT hooks/hooks.json)
# Plugin hooks don't fire for independent sessions.

set -uo pipefail

PANE="${TMUX_PANE:-%unknown}"
URC_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# ── Read stdin (required protocol) ──────────────────────────────
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0

# ── Guard: only act in bridge panes (~10ms tmux query) ──────────
TARGET=$(tmux show-options -pv -t "$PANE" @bridge_target 2>/dev/null || true)
[ -z "$TARGET" ] && exit 0

# ── Shared paths ────────────────────────────────────────────────
PUSH_DIR="$URC_ROOT/.urc/pushes"

# ── Token match: route by message type ──────────────────────────
# Separate find patterns prevent race: fast responses can create both
# processing + response push files before "message delivered" hook runs.
PUSH_PATTERN="${PANE}_*.json"
case "$PROMPT" in
  "message delivered to %"*) PUSH_PATTERN="${PANE}_*_processing_*.json" ;;
  "response from %"*|__urc_push__*) ;;
  status|reconnect\ *|__urc_refresh__|/remote-control|/rename\ *)
    exit 0  # Commands/slash-cmds — let CLI handle
    ;;
  *)
    # Normal message — dispatch via hook (all bridge sessions)
    # No phone-only guard needed: model checks for DISPATCH_OK first (route 0),
    # so hook dispatch and model Bash dispatch never both run.

    CLI=$(tmux show-options -pv -t "$PANE" @bridge_cli 2>/dev/null || echo "unknown")

    # Resolve @"path" file references for non-Claude targets
    # Phone uploads → Claude Code creates @"/path/to/file" → other CLIs see literal text
    if [ "$CLI" != "claude" ] && [ "$CLI" != "claude-code" ]; then
      PROMPT=$(printf '%s' "$PROMPT" | bash "$URC_ROOT/hooks/scripts/resolve-file-refs.sh" "$URC_ROOT")
    fi

    # Clean stale push files before dispatch
    find "$PUSH_DIR" -name "${PANE}_*.json" -type f -delete 2>/dev/null || true

    # Write dispatch metadata
    mkdir -p "$URC_ROOT/.urc/dispatches"
    jq -n --arg source "$PANE" --arg message "$(printf '%.100s' "$PROMPT")" \
      --arg target "$TARGET" --argjson epoch "$(date +%s)" \
      '{source:$source,message:$message,target:$target,epoch:$epoch,type:"relay"}' \
      > "$URC_ROOT/.urc/dispatches/${TARGET}.json" 2>/dev/null

    # Dispatch (fire-and-forget)
    bash "$URC_ROOT/urc/core/send.sh" "$TARGET" "$PROMPT" >/dev/null 2>&1
    SEND_EXIT=$?

    # Increment relay counter
    RELAYS=$(tmux show-options -pv -t "$PANE" @bridge_relays 2>/dev/null || echo "0")
    RELAYS=$((RELAYS + 1))
    tmux set-option -p -t "$PANE" @bridge_relays "$RELAYS" 2>/dev/null

    if [ "$SEND_EXIT" -eq 0 ]; then
      MSG="DISPATCH_OK: Sent to $TARGET ($CLI)"
    else
      MSG="DISPATCH_FAIL: Failed to send to $TARGET ($CLI)"
    fi

    ESCAPED=$(printf '%s' "$MSG" | jq -Rs .)
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}' "$ESCAPED"
    exit 0
    ;;
esac

# ── Read push files (mtime order) ───────────────────────────────
_RAW=$(find "$PUSH_DIR" -name "$PUSH_PATTERN" -type f 2>/dev/null)
[ -z "$_RAW" ] && exit 0
FILES=$(echo "$_RAW" | xargs ls -1tr 2>/dev/null)
[ -z "$FILES" ] && exit 0

# ── Parse push files, build display content ─────────────────────
CONTENT=""
CLEANUP_FILES=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  DATA=$(cat "$f" 2>/dev/null) || continue

  STATUS=$(echo "$DATA" | jq -r '.status // empty' 2>/dev/null)
  P=$(echo "$DATA" | jq -r '.pane // empty' 2>/dev/null)
  CLI=$(echo "$DATA" | jq -r '.cli // empty' 2>/dev/null)

  if [ "$STATUS" = "processing" ]; then
    MSG=$(echo "$DATA" | jq -r '.message // empty' 2>/dev/null)
    DISP_BY=$(echo "$DATA" | jq -r '.dispatched_by // empty' 2>/dev/null)
    if [ -n "$DISP_BY" ] && [ "$DISP_BY" != "$PANE" ]; then
      CONTENT="${CONTENT}[PROCESSING on ${P} (${CLI}) -- dispatched by ${DISP_BY}: \"${MSG}\"]
(awaiting response...)
"
    else
      CONTENT="${CONTENT}[PROCESSING on ${P} (${CLI}) -- message received: \"${MSG}\"]
(awaiting response...)
"
    fi
  else
    RESPONSE=$(echo "$DATA" | jq -r '.response // empty' 2>/dev/null)
    TRIG_BY=$(echo "$DATA" | jq -r '.triggered_by // empty' 2>/dev/null)
    TRIG_MSG=$(echo "$DATA" | jq -r '.triggered_msg // empty' 2>/dev/null)
    TRIG_TYPE=$(echo "$DATA" | jq -r '.triggered_type // empty' 2>/dev/null)

    if [ "$TRIG_TYPE" = "db_message" ]; then
      HEADER="[MESSAGE from ${TRIG_BY} → ${P} (${CLI})]
[RESPONSE from ${P} (${CLI})]"
    elif [ "$TRIG_BY" = "$PANE" ] || [ "$TRIG_TYPE" = "relay" ]; then
      HEADER="[UPDATE from ${P} (${CLI}) -- you asked: \"${TRIG_MSG}\"]"
    elif [ -n "$TRIG_BY" ]; then
      HEADER="[UPDATE from ${P} (${CLI}) -- dispatched by ${TRIG_BY}: \"${TRIG_MSG}\"]"
    else
      HEADER="[UPDATE from ${P} (${CLI}) -- autonomous]"
    fi
    CONTENT="${CONTENT}${HEADER}
${RESPONSE}
"
  fi
  CLEANUP_FILES="${CLEANUP_FILES}${f}
"
done <<< "$FILES"

# ── Cleanup (always delete files we matched) ─────────────────────
# Each token type has its own PUSH_PATTERN — no cross-deletion race.
echo "$CLEANUP_FILES" | while IFS= read -r f; do
  [ -n "$f" ] && rm -f "$f"
done

# ── Return via additionalContext ────────────────────────────────
[ -z "$CONTENT" ] && exit 0

# ── Overflow guard (additionalContext 10K hard limit) ────────────
# "PUSH_DATA:\n" prefix = 11 chars. Leave 500 char margin for JSON envelope + hook metadata.
MAX_CONTENT=9000
CONTENT_LEN=${#CONTENT}
if [ "$CONTENT_LEN" -gt "$MAX_CONTENT" ]; then
    OVERFLOW_DIR="$PUSH_DIR/overflow"
    mkdir -p "$OVERFLOW_DIR"
    OVERFLOW_FILE="$OVERFLOW_DIR/${PANE}_$(date +%s).md"
    printf '%s' "$CONTENT" > "$OVERFLOW_FILE"
    # Truncate to fit, append overflow notice
    CONTENT="$(printf '%.8500s' "$CONTENT")

---
[TRUNCATED — full content (${CONTENT_LEN} chars) saved to: ${OVERFLOW_FILE}]
Read the file, echo all responses to the user, then delete the overflow file."
fi

ESCAPED=$(printf '%s' "PUSH_DATA:
$CONTENT" | jq -Rs .)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}' "$ESCAPED"
exit 0
