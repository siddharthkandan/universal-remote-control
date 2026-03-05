#!/usr/bin/env bash
# turn-complete-hook.sh — Universal turn-completion with response capture + dual signal.
#
# Called by:
#   - Claude: Stop hook in .claude/settings.json (stdin JSON with last_assistant_message)
#   - Codex:  notify in .codex/config.toml (JSON as $1 arg, stdin is /dev/null)
#   - Gemini: AfterAgent hook in .gemini/settings.json (stdin JSON with prompt_response)
#
# Signal ordering (non-negotiable):
#   1. Write response file (.urc/responses/{PANE}.json)
#   2. Touch signal file (.urc/signals/done_{PANE})
#   3. tmux wait-for -S "urc_done_{PANE}" (instant notification)
#   4. Append JSONL event stream (.urc/streams/{PANE}.jsonl)
#   5. Output JSON for Gemini ({"continue": true})
#
# ALL debug/error output goes to stderr. stdout is ONLY for Gemini JSON contract.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PANE="${TMUX_PANE:-${URC_PANE_ID:-unknown}}"
NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

SIGNAL_DIR="$PROJECT_ROOT/.urc/signals"
RESPONSE_DIR="$PROJECT_ROOT/.urc/responses"
STREAM_DIR="$PROJECT_ROOT/.urc/streams"
LOG_FILE="$PROJECT_ROOT/.urc/events.log"
mkdir -p "$SIGNAL_DIR" "$RESPONSE_DIR" "$STREAM_DIR"

# Cleanup trap for temp files
_TMP_FILE=""
_cleanup() { [ -n "$_TMP_FILE" ] && rm -f "$_TMP_FILE"; }
trap _cleanup EXIT

# ── CLI Detection + Payload Parsing ──────────────────────────────
# Strategy: Check $1 first (Codex passes JSON as argument).
# If empty, read stdin (Claude/Gemini). Differentiate by field names.
CLI_TYPE="unknown"
RESPONSE=""
TURN_ID=""
INPUT_PROMPT=""
RAW_PAYLOAD=""

if [ -n "${1:-}" ]; then
    # ── CODEX PATH ───────────────────────────────────────────────
    # Codex notify: JSON is $1. stdin/stdout/stderr are /dev/null.
    CLI_TYPE="codex"
    RAW_PAYLOAD="$1"
    RESPONSE=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.["last-assistant-message"] // empty' 2>/dev/null)
    TURN_ID=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.["turn-id"] // empty' 2>/dev/null)
    INPUT_PROMPT=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.["input-messages"][0] // empty' 2>/dev/null)
else
    # ── STDIN PATH (Claude or Gemini) ────────────────────────────
    RAW_PAYLOAD=$(cat)

    if [ -n "$RAW_PAYLOAD" ]; then
        HAS_PROMPT_RESPONSE=$(printf '%s' "$RAW_PAYLOAD" | jq -r 'has("prompt_response")' 2>/dev/null)
        HAS_HOOK_EVENT=$(printf '%s' "$RAW_PAYLOAD" | jq -r 'has("hook_event_name")' 2>/dev/null)

        if [ "$HAS_PROMPT_RESPONSE" = "true" ] || [ "$HAS_HOOK_EVENT" = "true" ]; then
            # ── GEMINI PATH ──────────────────────────────────────
            CLI_TYPE="gemini"
            RESPONSE=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.prompt_response // empty' 2>/dev/null)
            INPUT_PROMPT=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null)
            TURN_ID=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)
        else
            # ── CLAUDE PATH ──────────────────────────────────────
            CLI_TYPE="claude"
            RESPONSE=$(printf '%s' "$RAW_PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null)
            TURN_ID=""
            INPUT_PROMPT=""
        fi
    fi
fi

# ── Response File (atomic write) ─────────────────────────────────
RESPONSE_LEN=0
RESPONSE_SHA=""
if [ -n "$RESPONSE" ]; then
    RESPONSE_LEN=${#RESPONSE}
    if command -v shasum >/dev/null 2>&1; then
        RESPONSE_SHA=$(printf '%s' "$RESPONSE" | shasum -a 256 | awk '{print $1}')
    elif command -v sha256sum >/dev/null 2>&1; then
        RESPONSE_SHA=$(printf '%s' "$RESPONSE" | sha256sum | awk '{print $1}')
    fi

    _TMP_FILE=$(mktemp "$RESPONSE_DIR/.tmp.XXXXXX")
    jq -n \
        --argjson v 1 \
        --arg pane "$PANE" \
        --arg cli "$CLI_TYPE" \
        --arg ts "$NOW_ISO" \
        --argjson epoch "$NOW_EPOCH" \
        --arg response "$RESPONSE" \
        --arg turn_id "$TURN_ID" \
        --arg input "$INPUT_PROMPT" \
        --argjson len "$RESPONSE_LEN" \
        --arg sha256 "$RESPONSE_SHA" \
        '{v:$v, pane:$pane, cli:$cli, ts:$ts, epoch:$epoch, response:$response,
          turn_id:$turn_id, input:$input, len:$len, sha256:$sha256}' \
        > "$_TMP_FILE" 2>/dev/null

    if [ -s "$_TMP_FILE" ]; then
        mv -f "$_TMP_FILE" "$RESPONSE_DIR/${PANE}.json"
        _TMP_FILE=""  # moved successfully, don't cleanup
    else
        # jq failed — write minimal fallback
        rm -f "$_TMP_FILE"
        _TMP_FILE=""
        printf '{"v":1,"pane":"%s","cli":"%s","epoch":%s,"len":%s,"error":"jq_failed"}\n' \
            "$PANE" "$CLI_TYPE" "$NOW_EPOCH" "$RESPONSE_LEN" \
            > "$RESPONSE_DIR/${PANE}.json" 2>/dev/null
    fi
fi

# ── Audit log (backward compat) ──────────────────────────────────
echo "$NOW_EPOCH ${PANE} turn_complete" >> "$LOG_FILE"

# ── Shared signal file (legacy) ──────────────────────────────────
touch "$PROJECT_ROOT/.urc/turn_signal"

# ── Per-pane signal file ─────────────────────────────────────────
touch "$SIGNAL_DIR/done_${PANE}"

# ── tmux instant notification ────────────────────────────────────
tmux wait-for -S "urc_done_${PANE}" 2>/dev/null

# ── JSONL event stream ───────────────────────────────────────────
printf '{"ts":"%s","epoch":%s,"pane":"%s","type":"turn_end","cli":"%s","len":%d}\n' \
    "$NOW_ISO" "$NOW_EPOCH" "$PANE" "$CLI_TYPE" "$RESPONSE_LEN" \
    >> "$STREAM_DIR/${PANE}.jsonl"

# ── Gemini/Claude stdout (MUST be last synchronous output) ───────
# Gemini AfterAgent requires JSON on stdout. Claude Stop accepts it.
# Codex ignores stdout (it is /dev/null).
echo '{"continue": true}'
