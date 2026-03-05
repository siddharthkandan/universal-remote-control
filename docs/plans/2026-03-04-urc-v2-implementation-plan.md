# URC v2 Communication Architecture — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace URC's polling-based communication with push-based hook-driven notification, composite tools, and response-from-hook — achieving sub-second relay latency and 4-10x token savings.

**Architecture:** Enhanced turn-complete hooks capture response content and fire dual signals (file + tmux wait-for). A Bash composite script (`dispatch-and-wait.sh`) atomically dispatches, waits, and reads responses. The relay calls dispatch-and-wait.sh directly via Bash in Phase 1; MCP wrappers (`relay_cycle`, `send_with_notify`, `bootstrap_validate`) are added in Phase 2 after empirical MCP client timeout testing. A 4-layer notification stack ensures cross-CLI inbox awareness.

**Tech Stack:** Bash (hooks, composite scripts), Python 3.13 (MCP tools via FastMCP), SQLite WAL (data plane), tmux wait-for (notification primitive), jq (JSON parsing in hooks)

**Design Doc:** `docs/plans/2026-03-04-cli-communication-findings.md` (1,011 lines, fully reviewed by 3 cross-CLI reviewers)

**Evaluation Reports:** `.urc/eval-dispatch-and-wait.md`, `.urc/eval-tool-landscape.md`, `.urc/eval-hook-enhancement.md`

---

## Phase 0: Foundation (~160 LOC)

Milestone: Dispatch to any CLI, get structured response back, zero polling.

### Task 0: Create lib-cli.sh (CLI detection + field mapping)

**Files:**
- Create: `urc/core/lib-cli.sh`

**Why this is first:** Every subsequent task needs CLI detection and field mapping. A single ~20 LOC shell library with two functions covers Phase 0-1 needs. Full adapter configs (separate `.conf` files per CLI) can be added in Phase 2 when a 4th CLI arrives.

**Step 1: Create lib-cli.sh**

```bash
#!/bin/bash
# lib-cli.sh — CLI detection and field mapping (~20 LOC)
# Usage: source this file, then call detect_cli or get_cli_field

detect_cli() {
  # $1 = hook payload (JSON string) or empty
  local payload="${1:-}"
  if echo "$payload" | jq -e '.type == "agent-turn-complete"' >/dev/null 2>&1; then
    echo "codex"
  elif echo "$payload" | jq -e 'has("prompt_response")' >/dev/null 2>&1; then
    echo "gemini"
  elif echo "$payload" | jq -e 'has("last_assistant_message")' >/dev/null 2>&1; then
    echo "claude"
  else
    echo "unknown"
  fi
}

get_cli_field() {
  # $1 = cli name, $2 = field name
  local cli="$1" field="$2"
  case "$cli" in
    claude)
      case "$field" in
        response_field)  echo "last_assistant_message" ;;
        payload_source)  echo "stdin" ;;
        hook_output)     echo "" ;;
        turn_id_field)   echo "session_turn" ;;
      esac ;;
    codex)
      case "$field" in
        response_field)  echo "last-assistant-message" ;;
        payload_source)  echo "argv1" ;;
        hook_output)     echo "" ;;
        turn_id_field)   echo "turn-id" ;;
      esac ;;
    gemini)
      case "$field" in
        response_field)  echo "prompt_response" ;;
        payload_source)  echo "stdin" ;;
        hook_output)     echo '{"continue":true}' ;;
        turn_id_field)   echo "session_turn" ;;
      esac ;;
  esac
}
```

**Step 2: Commit**

```bash
git add urc/core/lib-cli.sh
git commit -m "feat: lib-cli.sh — CLI detection and field mapping for 3 CLIs"
```

---

### Task 1: Define response file schema and correlation protocol

**Files:**
- Create: `urc/schemas/response.md`

**Step 1: Write the schema specification**

```markdown
# URC Response File Schema v1

## Location
`.urc/responses/{PANE}.json` — one file per pane, overwritten each turn.

## Fields
| Field | Type | Required | Source |
|---|---|---|---|
| pane_id | string | yes | $TMUX_PANE |
| cli | string | yes | detected from payload structure |
| turn_id | string | yes | from hook payload (turn-id for Codex, session turn for Claude/Gemini) |
| timestamp | integer | yes | epoch seconds |
| response_text | string | yes | last_assistant_message / prompt_response |
| input_text | string | no | input_messages / prompt |
| checksum | string | yes | sha256 of response_text |
| schema_version | integer | yes | 1 |

## Atomic Write Protocol
1. Write to `.urc/responses/.tmp.{PANE}.$$`
2. `mv` temp to `.urc/responses/{PANE}.json`

## Correlation Protocol
Dispatcher records `dispatch_timestamp` (epoch seconds) BEFORE sending.
Response file includes `timestamp` from the hook (epoch seconds).
Dispatcher validates `response.timestamp > dispatch_timestamp` before accepting the response.
If stale (timestamp <= dispatch_timestamp), waits for the next signal.
No UUID injection into messages — timestamp comparison is sufficient.

## Signal Ordering (non-negotiable)
1. Write response file (data available)
2. Touch `signals/done_{PANE}` (durable signal for pre-check)
3. `tmux wait-for -S "urc_done_{PANE}"` (instant notification)
4. Append to JSONL stream (observability, best-effort)
```

**Step 2: Commit**

```bash
git add urc/schemas/response.md
git commit -m "feat: define response file schema and correlation protocol"
```

---

### Task 2: Enhance turn-complete-hook.sh with response capture + dual signal

**Files:**
- Modify: `urc/core/turn-complete-hook.sh`
- Reference: `.urc/eval-hook-enhancement.md` (140 LOC implementation sketch)

**Step 1: Read the current hook and the evaluation sketch**

Read `urc/core/turn-complete-hook.sh` (82 LOC current) and `.urc/eval-hook-enhancement.md` (Section 6: complete implementation).

**Step 2: Write test harness**

Create `urc/core/test-hook.sh` that invokes the hook with synthetic payloads for each CLI:

```bash
#!/bin/bash
# test-hook.sh — synthetic payload tests for turn-complete-hook.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/turn-complete-hook.sh"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export TMUX_PANE="%test99"

# Setup
mkdir -p "$PROJECT_ROOT/.urc/responses" "$PROJECT_ROOT/.urc/signals" "$PROJECT_ROOT/.urc/streams"
rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"

echo "=== Test 1: Claude Code Stop hook payload ==="
echo '{"stop_hook_active":true,"last_assistant_message":"Hello from Claude test"}' | bash "$HOOK"
# Verify response file
RESP=$(cat "$PROJECT_ROOT/.urc/responses/%test99.json" 2>/dev/null)
echo "$RESP" | jq -e '.response_text == "Hello from Claude test"' > /dev/null && echo "PASS: Claude response captured" || echo "FAIL: Claude response"
echo "$RESP" | jq -e '.cli == "claude"' > /dev/null && echo "PASS: CLI detected as claude" || echo "FAIL: CLI detection"
# Verify signal file
[ -f "$PROJECT_ROOT/.urc/signals/done_%test99" ] && echo "PASS: Signal file created" || echo "FAIL: Signal file"

# Cleanup
rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"

echo ""
echo "=== Test 2: Codex notify hook payload (via \$1) ==="
bash "$HOOK" '{"type":"agent-turn-complete","last-assistant-message":"Hello from Codex test","thread-id":"abc","turn-id":"t1","cwd":"/tmp","input-messages":["test"]}'
RESP=$(cat "$PROJECT_ROOT/.urc/responses/%test99.json" 2>/dev/null)
echo "$RESP" | jq -e '.response_text == "Hello from Codex test"' > /dev/null && echo "PASS: Codex response captured" || echo "FAIL: Codex response"
echo "$RESP" | jq -e '.cli == "codex"' > /dev/null && echo "PASS: CLI detected as codex" || echo "FAIL: CLI detection"

rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"

echo ""
echo "=== Test 3: Gemini AfterAgent hook payload ==="
echo '{"prompt":"test prompt","prompt_response":"Hello from Gemini test","stop_hook_active":false}' | bash "$HOOK" | jq -e '.continue == true' > /dev/null && echo "PASS: Gemini JSON contract" || echo "FAIL: Gemini JSON"
RESP=$(cat "$PROJECT_ROOT/.urc/responses/%test99.json" 2>/dev/null)
echo "$RESP" | jq -e '.response_text == "Hello from Gemini test"' > /dev/null && echo "PASS: Gemini response captured" || echo "FAIL: Gemini response"

# Final cleanup
rm -f "$PROJECT_ROOT/.urc/responses/%test99.json" "$PROJECT_ROOT/.urc/signals/done_%test99"
echo ""
echo "=== All tests complete ==="
```

**Step 3: Run test to verify it fails**

Run: `bash urc/core/test-hook.sh`
Expected: FAIL on response capture (current hook ignores all input)

**Step 4: Implement the enhanced hook**

Modify `urc/core/turn-complete-hook.sh` to add:
- CLI detection (stdin JSON with `last_assistant_message` = Claude, stdin JSON with `prompt_response` = Gemini, `$1` JSON with `"type":"agent-turn-complete"` = Codex)
- Response content extraction from the detected payload
- Atomic response file write (temp + mv) to `.urc/responses/{PANE}.json`
- Dual signal: touch signal file THEN `tmux wait-for -S`
- JSONL append (best-effort) to `.urc/streams/{PANE}.jsonl`
- Preserve ALL existing behavior (backward compatible)
- Gemini: output `{"continue": true}` on stdout (strict contract)
- Error handling: if payload parse fails, still create signal file (degrade gracefully)
- Trap handler: clean up temp file on unexpected exit

Follow the implementation sketch in `.urc/eval-hook-enhancement.md` Section 6.

**Step 5: Run test to verify it passes**

Run: `bash urc/core/test-hook.sh`
Expected: All PASS

**Step 6: Commit**

```bash
git add urc/core/turn-complete-hook.sh urc/core/test-hook.sh urc/schemas/response.md
git commit -m "feat: enhanced turn-complete hook with response capture and dual signal"
```

---

### Task 3: Build dispatch-and-wait.sh

**Files:**
- Create: `urc/core/dispatch-and-wait.sh`
- Reference: `.urc/eval-dispatch-and-wait.md` (68 LOC implementation sketch)

**Step 1: Write test harness**

Create `urc/core/test-dispatch-and-wait.sh`:

```bash
#!/bin/bash
# test-dispatch-and-wait.sh — tests for dispatch-and-wait.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAW="$SCRIPT_DIR/dispatch-and-wait.sh"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Test 1: Pre-existing response (instant return) ==="
# Simulate a pane that already completed
mkdir -p "$PROJECT_ROOT/.urc/responses" "$PROJECT_ROOT/.urc/signals"
echo '{"pane_id":"%test88","cli":"claude","turn_id":"t1","timestamp":9999999999,"response_text":"pre-existing","checksum":"abc","schema_version":1}' > "$PROJECT_ROOT/.urc/responses/%test88.json"
touch "$PROJECT_ROOT/.urc/signals/done_%test88"
RESULT=$(bash "$DAW" "%test88" "test message" 5 --skip-dispatch 2>/dev/null)
echo "$RESULT" | jq -e '.status == "completed"' > /dev/null && echo "PASS: Pre-existing response detected" || echo "FAIL: Pre-existing"
echo "$RESULT" | jq -e '.response_text == "pre-existing"' > /dev/null && echo "PASS: Response text correct" || echo "FAIL: Response text"

rm -f "$PROJECT_ROOT/.urc/responses/%test88.json" "$PROJECT_ROOT/.urc/signals/done_%test88"

echo ""
echo "=== Test 2: Timeout (no signal, short timeout) ==="
RESULT=$(bash "$DAW" "%test88" "test message" 3 --skip-dispatch 2>/dev/null)
echo "$RESULT" | jq -e '.status == "timeout"' > /dev/null && echo "PASS: Timeout detected" || echo "FAIL: Timeout"

echo ""
echo "=== Test 3: Signal file created mid-wait ==="
# Background: create signal + response after 1s
(sleep 1; echo '{"pane_id":"%test88","cli":"codex","turn_id":"t2","timestamp":9999999999,"response_text":"delayed response","checksum":"def","schema_version":1}' > "$PROJECT_ROOT/.urc/responses/%test88.json"; touch "$PROJECT_ROOT/.urc/signals/done_%test88"; tmux wait-for -S "urc_done_%test88" 2>/dev/null) &
RESULT=$(bash "$DAW" "%test88" "test message" 10 --skip-dispatch 2>/dev/null)
echo "$RESULT" | jq -e '.status == "completed"' > /dev/null && echo "PASS: Mid-wait signal detected" || echo "FAIL: Mid-wait"
echo "$RESULT" | jq -e '.response_text == "delayed response"' > /dev/null && echo "PASS: Delayed response correct" || echo "FAIL: Delayed response"

rm -f "$PROJECT_ROOT/.urc/responses/%test88.json" "$PROJECT_ROOT/.urc/signals/done_%test88"

echo ""
echo "=== Test 4: Interleaved manual turn (stale response then real response) ==="
# Simulate: dispatch starts, a "stale" response from a prior turn is written mid-wait
# with an old timestamp, then the "real" response with a newer timestamp arrives.
# dispatch-and-wait.sh should reject the stale response and return the real one.
DISPATCH_TS=$(date +%s)
(
  # After 1s: write stale response (timestamp BEFORE dispatch) + signal
  sleep 1
  echo "{\"pane_id\":\"%test88\",\"cli\":\"claude\",\"turn_id\":\"stale\",\"timestamp\":$((DISPATCH_TS - 10)),\"response_text\":\"STALE manual turn\",\"checksum\":\"aaa\",\"schema_version\":1}" > "$PROJECT_ROOT/.urc/responses/%test88.json"
  touch "$PROJECT_ROOT/.urc/signals/done_%test88"
  tmux wait-for -S "urc_done_%test88" 2>/dev/null
  # After 2s more: write real response (timestamp AFTER dispatch) + signal
  sleep 2
  echo "{\"pane_id\":\"%test88\",\"cli\":\"claude\",\"turn_id\":\"real\",\"timestamp\":$((DISPATCH_TS + 5)),\"response_text\":\"REAL dispatched response\",\"checksum\":\"bbb\",\"schema_version\":1}" > "$PROJECT_ROOT/.urc/responses/%test88.json"
  touch "$PROJECT_ROOT/.urc/signals/done_%test88"
  tmux wait-for -S "urc_done_%test88" 2>/dev/null
) &
RESULT=$(bash "$DAW" "%test88" "test message" 10 --skip-dispatch 2>/dev/null)
echo "$RESULT" | jq -e '.status == "completed"' > /dev/null && echo "PASS: Completed despite stale interleave" || echo "FAIL: Status"
echo "$RESULT" | jq -e '.response_text == "REAL dispatched response"' > /dev/null && echo "PASS: Returned real response (not stale)" || echo "FAIL: Got stale response"

rm -f "$PROJECT_ROOT/.urc/responses/%test88.json" "$PROJECT_ROOT/.urc/signals/done_%test88"
echo ""
echo "=== All tests complete ==="
```

**Step 2: Run test to verify it fails**

Run: `bash urc/core/test-dispatch-and-wait.sh`
Expected: FAIL (script doesn't exist yet)

**Step 3: Implement dispatch-and-wait.sh**

Create `urc/core/dispatch-and-wait.sh` (~50 LOC):

The script should:
1. Accept args: `$1` = target pane, `$2` = message, `$3` = timeout (default 120), `$4` = optional `--skip-dispatch` for testing
2. Ensure `.urc/responses/`, `.urc/signals/`, `.urc/locks/`, `.urc/timeout/` dirs exist
3. Acquire `flock` on `.urc/locks/{PANE}.lock` before proceeding (prevents concurrent dispatchers racing on the same pane; flock is auto-released on exit — ~3 lines of Bash)
4. Record `dispatch_timestamp=$(date +%s)` BEFORE clearing files
5. Unless `--skip-dispatch`: clear old signal file, response file, and timeout sentinel for target pane, then dispatch via `tmux-send-helper.sh --force --no-verify`. (When `--skip-dispatch` is set, files are NOT cleared — this allows testing pre-existing response scenarios.)
7. Pre-check: if signal file already exists, skip to read
8. Block: `tmux wait-for "urc_done_{PANE}"` with timeout. The timeout mechanism: background process does `sleep $TIMEOUT && touch .urc/timeout/{PANE} && tmux wait-for -S "urc_done_{PANE}"`. After wait-for returns, check: if `.urc/signals/done_{PANE}` exists → real completion. If `.urc/timeout/{PANE}` exists → timeout. This distinguishes genuine completion from synthetic timeout.
9. Read response from `.urc/responses/{PANE}.json`; validate `response.timestamp > dispatch_timestamp` before accepting (if stale, wait for next signal)
10. If response file missing: fallback to `tmux capture-pane -t $PANE -p -S -80`
11. Clean up signal file, timeout sentinel, release flock
12. Output structured JSON on stdout: `{"status":"completed|timeout|dispatch_failed","response_text":"...","pane_id":"...","cli":"...","latency_ms":NNN}`

Follow the approach in `.urc/eval-dispatch-and-wait.md` but as pure Bash (no Python, no kqueue).

**Step 4: Run test to verify it passes**

Run: `bash urc/core/test-dispatch-and-wait.sh`
Expected: All PASS

**Step 5: Commit**

```bash
git add urc/core/dispatch-and-wait.sh urc/core/test-dispatch-and-wait.sh
git commit -m "feat: dispatch-and-wait.sh — atomic dispatch + wait + read composite"
```

---

### Task 4: Build bootstrap_validate MCP tool

**Files:**
- Modify: `urc/core/coordination_server.py`

**Step 1: Read the current MCP server**

Read `urc/core/coordination_server.py` to understand tool registration pattern.

**Step 2: Implement bootstrap_validate**

Add a new MCP tool to `coordination_server.py`:

```python
@mcp.tool()
def bootstrap_validate() -> dict:
    """Validate URC setup: CWD, directories, hook configs, tmux, MCP servers.
    Call this before any cross-CLI operation to catch setup issues early.
    """
    issues = []
    # 1. Check CWD contains urc/core/
    if not os.path.isdir(os.path.join(_project_root, "urc", "core")):
        issues.append({"severity": "error", "check": "cwd", "message": f"URC project root not found. CWD: {_project_root}"})
    # 2. Check .urc/ directories exist
    for d in ["responses", "signals", "streams"]:
        path = os.path.join(_project_root, ".urc", d)
        if not os.path.isdir(path):
            os.makedirs(path, exist_ok=True)
            issues.append({"severity": "fixed", "check": f"dir_{d}", "message": f"Created missing directory: .urc/{d}"})
    # 3. Check tmux is accessible
    try:
        subprocess.run(["tmux", "list-sessions"], capture_output=True, timeout=3)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        issues.append({"severity": "error", "check": "tmux", "message": "tmux not accessible"})
    # 4. Check hook script exists and is executable
    hook_path = os.path.join(_project_root, "urc", "core", "turn-complete-hook.sh")
    if not os.path.isfile(hook_path):
        issues.append({"severity": "error", "check": "hook", "message": "turn-complete-hook.sh not found"})
    # 5. Check dispatch-and-wait.sh exists
    daw_path = os.path.join(_project_root, "urc", "core", "dispatch-and-wait.sh")
    if not os.path.isfile(daw_path):
        issues.append({"severity": "warning", "check": "dispatch_and_wait", "message": "dispatch-and-wait.sh not found"})
    errors = [i for i in issues if i["severity"] == "error"]
    return {"valid": len(errors) == 0, "issues": issues, "project_root": _project_root}
```

**Step 3: Test manually**

Run: `python3 urc/core/coordination_server.py --self-test` (existing self-test pattern)

**Step 4: Commit**

```bash
git add urc/core/coordination_server.py
git commit -m "feat: bootstrap_validate MCP tool for setup verification"
```

---

### Task 5: End-to-end Phase 0 validation

**Files:** None (validation only)

**Step 1: Validate the hook with a real CLI**

Launch Claude Code from the URC directory. Send a simple prompt. Check:
- `.urc/responses/{PANE}.json` was written with response content
- `.urc/signals/done_{PANE}` was created
- JSONL stream was appended

**Step 2: Validate dispatch-and-wait with a real CLI**

From one Claude pane, run:
```bash
bash urc/core/dispatch-and-wait.sh "%TARGET" "What is 2+2? Answer in one word." 30
```
Check: returns structured JSON with `status: "completed"` and `response_text` containing the answer.

**Step 3: Validate bootstrap_validate**

Call `bootstrap_validate()` MCP tool. Check: returns `valid: true` with no errors.

**Step 4: Commit validation results**

```bash
git commit --allow-empty -m "milestone: Phase 0 complete — dispatch-and-wait working end-to-end"
```

---

## Phase 1: Relay + Notifications (~160 LOC)

Milestone: Sub-second relay, inbox-aware Claude sessions.

### Task 6: Relay uses dispatch-and-wait.sh directly via Bash

**Note:** The `relay_cycle` MCP tool is deferred to Phase 2, conditional on empirical MCP client timeout testing. In Phase 1, the relay agent calls `bash urc/core/dispatch-and-wait.sh` directly via the Bash tool. This is simpler, has zero MCP timeout risk, and validates the foundation before wrapping it.

**Files:** None (relay prompt updated in Task 9 to call Bash directly)

**Validation:** During Phase 1 e2e testing (Task 10), empirically test MCP client timeout tolerance with a simple blocking MCP tool that sleeps for 60s, 90s, 120s. Record results. If 120s blocking works without client-side errors, `relay_cycle` MCP tool can be built in Phase 2.

---

### Task 7: Build send_with_notify MCP tool

**Files:**
- Modify: `urc/core/coordination_server.py`

**Step 1: Implement send_with_notify**

Add to `coordination_server.py`. This tool atomically: commits message to SQLite → touches inbox signal → fires wake pulse → fires tmux wait-for. Follow the spec in the findings doc Part 4, Layer 4.

**Step 2: Test by sending a message between two panes**

Verify: message in SQLite, signal file created, wake pulse sent, tmux wait-for channel signaled.

**Step 3: Commit**

```bash
git add urc/core/coordination_server.py
git commit -m "feat: send_with_notify MCP tool — atomic message send + notification"
```

---

### Task 8: Port inbox-piggyback.sh from ContextPilot v1

**Files:**
- Create: `.claude/hooks/inbox-piggyback.sh`
- Modify: `.claude/settings.json` (add PostToolUse hook)
- Reference: `Automating-CC/.claude/hooks/inbox-piggyback.sh`

**Step 1: Read the v1 implementation**

Read `Automating-CC/.claude/hooks/inbox-piggyback.sh` for the proven pattern.

**Step 2: Implement for URC**

Port the v1 hook, adapting paths from `.contextpilot/` to `.urc/`:
- O(1) stat check on `.urc/inbox/{PANE}.signal`
- If present: query SQLite for unread count + sender
- Output `additionalContextForAssistant` via `hookSpecificOutput`

**Step 3: Wire into .claude/settings.json**

Add PostToolUse hook entry for `inbox-piggyback.sh`.

**Step 4: Test by sending a message and verifying injection**

Send a message to the pane via `send_with_notify`. On the next tool call, verify the model receives the inbox notification.

**Step 5: Commit**

```bash
git add .claude/hooks/inbox-piggyback.sh .claude/settings.json
git commit -m "feat: inbox-piggyback PostToolUse hook for Claude inbox awareness"
```

---

### Task 9: Rewrite relay agent prompt

**Files:**
- Modify: `.claude/agents/rc-bridge.md`

**Step 1: Read the current 173-line prompt**

Read `.claude/agents/rc-bridge.md`.

**Step 2: Rewrite to use dispatch-and-wait.sh via Bash**

The new prompt should be ~50 lines maximum. The core loop:
1. On bootstrap: parse target pane from initial message, set tmux options
2. On each message: call `bash urc/core/dispatch-and-wait.sh "%TARGET" "message" 120` via the Bash tool, display `response_text` from the returned JSON verbatim
3. After 6 exchanges: `/clear`
4. On `__urc_refresh__`: call dispatch-and-wait.sh with empty message or just read `.urc/responses/{PANE}.json`
5. On `reconnect %NNN`: update bridge target

Remove all orchestration instructions (signal file management, polling loops, retry logic) — dispatch-and-wait.sh handles everything. The relay agent never calls MCP tools for the relay cycle; it uses a single Bash call.

**Step 3: Commit**

```bash
git add .claude/agents/rc-bridge.md
git commit -m "feat: simplified relay agent prompt using dispatch-and-wait.sh via Bash"
```

---

### Task 10: End-to-end Phase 1 validation

**Step 1: Full relay test**

Use `/urc codex` or `/urc gemini` to set up a relay. Send messages from the phone. Verify:
- Sub-second overhead (message → response displayed)
- Response content from hook (not terminal scraping)
- Relay prompt is short and deterministic

**Step 2: Inbox notification test**

Send a cross-CLI message to a Claude pane. Verify the inbox piggyback injects notification on the next tool call.

**Step 3: Commit milestone**

```bash
git commit --allow-empty -m "milestone: Phase 1 complete — sub-second relay, inbox-aware Claude"
```

---

## Phase 2: Hardening (~125 LOC)

Milestone: Full 4-layer notification, abort capability, relay_cycle MCP tool (conditional on MCP client timeout testing from Phase 1).

### Task 11: Build relay_cycle MCP tool (conditional)

**Files:**
- Modify: `urc/core/coordination_server.py`

**Gate:** Only build if Phase 1 MCP client timeout testing (Task 6) confirmed that Claude Code tolerates 120s blocking MCP tool calls. If not, the relay continues using `bash dispatch-and-wait.sh` directly.

Implement `relay_cycle(my_pane, message, timeout)` as an MCP tool on `coordination_server.py` that wraps `dispatch-and-wait.sh` via `subprocess.run()`. Reads `@bridge_target` from tmux pane options, calls dispatch-and-wait.sh, returns structured JSON.

---

### Task 12: Build cancel_dispatch MCP tool

**Files:**
- Modify: `urc/core/coordination_server.py`

Implement `cancel_dispatch(pane_id)`: sends SIGINT via tmux to target, clears signal/response files, signals the tmux wait-for channel to unblock any waiting dispatch-and-wait.sh.

---

### Task 13: Build Gemini BeforeAgent inbox hook

**Files:**
- Create: `.gemini/hooks/inbox-inject.sh`
- Modify: `.gemini/settings.json`

Implement inbox notification for Gemini using `BeforeAgent` hook with `additionalContext` in the JSON return value. Falls back to MCP middleware if `additionalContext` doesn't work.

---

### Task 14: Expand MCP middleware inbox hints

**Files:**
- Modify: `urc/core/coordination_server.py`
- Modify: `urc/core/coordination_db.py`

Extract `_peek_inbox_hint()` to `coordination_db.py`. Add it to `dispatch_to_pane`, `read_pane_output`, `get_fleet_status`, `heartbeat` responses.

---

### Task 15: Add inbox signal to team_send/send_message

**Files:**
- Modify: `urc/core/teams_protocol.py`
- Modify: `urc/core/coordination_server.py`

When `send_message` or `team_send` is called, automatically touch `.urc/inbox/{TO_PANE}.signal` and fire tmux wake pulse. Currently this is manual — make it automatic.

---

## Phase 3: Polish (~10 LOC)

> **Note:** Task 15 (JSONL event stream append) was consolidated into Task 2 (Phase 0 hook enhancement). The hook writes the JSONL append as part of its signal sequence — it's one line (`echo >> file`), not a standalone task.

### Task 16: CWD fix — document and automate

Update `setup.sh` and `/urc` skill to either launch CLIs from the URC directory or propagate hook configs to global config. Document the requirement in README.

---

## Summary

| Phase | Tasks | LOC | Milestone |
|---|---|---|---|
| P0 | 0-5 | ~160 | lib-cli.sh, dispatch to any CLI, structured response, zero polling |
| P1 | 6-10 | ~120 | Relay via Bash dispatch-and-wait, inbox-aware Claude |
| P2 | 11-15 | ~125 | relay_cycle MCP (conditional), full notification stack, abort capability |
| P3 | 16 | ~10 | CWD fix |
| **Total** | **17 tasks** | **~415** | **Complete URC v2 communication architecture** |

**Architectural principle:** CLI-specific behavior lives in `urc/core/lib-cli.sh` (Phase 0) with a simple case statement for 3 CLIs. Full adapter configs (separate `.conf` files) can be introduced in Phase 2 when a 4th CLI arrives. Core code is CLI-agnostic.
