<!-- This file contains instructions for Codex CLI agents. For human documentation, see README.md -->
# URC — CLI-to-CLI Communication & RC Bridge

URC enables cross-CLI communication between Claude Code, Codex, and Gemini panes via MCP tools, and provides RC Bridge for phone-to-CLI remote control.

## RC Bridge System

The RC Bridge lets you control this Codex pane from the Claude Code phone app:
1. A Claude Code Haiku relay pane spawns alongside your pane
2. It's pre-configured with your pane ID and CLI type via tmux pane options (set by `urc-spawn.sh`)
3. Phone messages are dispatched to your pane via a `UserPromptSubmit` hook — no model turn consumed
4. Your output is captured by `hook.sh` and written to a push file, which the relay picks up on its next wake and displays on the phone

Launch with: `/rc-bridge`

## Available MCP Tools

### urc-coordination (pane communication — 11 tools)
| Tool | Purpose |
|------|---------|
| `register_agent` | Register a pane (auto-called on first tool use — no manual registration needed) |
| `heartbeat` | Send heartbeat update for a pane |
| `get_fleet_status` | List all registered agents and their status |
| `rename_agent` | Set display label for a pane |
| `dispatch_to_pane` | Send a message to a tmux pane via send.sh |
| `read_pane_output` | Capture recent output from a pane's tmux buffer |
| `send_message` | Send inter-agent message (use `notify=true` to include wake nudge) |
| `receive_messages` | Get unread messages |
| `kill_pane` | Kill a tmux pane (requires explicit confirmation) |
| `cancel_dispatch` | SIGINT target + clear signals + unblock waiting dispatcher |
| `bootstrap_validate` | Validate CWD/directories/hook/tmux setup |

### urc-teams (DORMANT — removed from .mcp.json)
Teams protocol is dormant. The code exists in `urc/core/teams_server.py` but the MCP server is not loaded. Use `send_message`/`receive_messages` from urc-coordination for cross-CLI messaging instead.

## Turn Completion

Your `notify` hook in `.codex/config.toml` fires `urc/core/hook.sh` after each turn. This:
- Writes response to `.urc/responses/{PANE}.json`
- Touches signal file `.urc/signals/done_{PANE}`
- Fires `tmux wait-for` to wake blocking dispatchers
- Appends to JSONL audit stream `.urc/streams/{PANE}.jsonl`

## Inbox & Bidirectional Messaging

For async conversations with other agents, use DB messaging (see Communication Strategy below).

Codex has automatic inbox detection via the Stop hook (requires `codex_hooks = true` in `.codex/config.toml` `[features]` and Codex v0.114.0+). The Stop hook fires after every turn and blocks turn completion if unread messages exist, injecting the inbox notification into model context via `block_message_for_model`. This is the STRONGEST inbox mechanism across all three CLIs — the model MUST process inbox messages before finishing its turn.

**How it works:** The Stop hook (`.codex/hooks.json`) runs `hooks/scripts/inbox-check.sh codex`. If unread messages exist, it returns `{"decision":"block","reason":"INBOX: N unread from %XXXX. Call receive_messages MCP tool."}`. The reason is injected as model context. If no messages, it returns `{"continue":true}`.

**Double-block guard:** Codex has a built-in safety: "Stop hook blocked twice in same turn; ignoring second block." This prevents infinite loops.

**Fallback (heartbeat polling):** If the Stop hook is unavailable (Codex <0.114.0 or `codex_hooks` not enabled), call `mcp__urc-coordination__heartbeat(pane_id="%YOUR_PANE", status="active")` at the start of each turn and check the return value for `inbox_hint`:
```json
{"status": "ok", "inbox_hint": "INBOX: 2 unread from %1316"}
```
If `inbox_hint` is present, immediately call `mcp__urc-coordination__receive_messages(pane_id="%YOUR_PANE")` to read your messages. Act on them before continuing other work.

**Sending messages to other agents:**
`mcp__urc-coordination__send_message(from_pane="%YOUR_PANE", to_pane="%TARGET", body="message", notify=true)`
The recipient will be notified automatically via their CLI's inbox hook.

**hooks.json format** (PascalCase event names, nested MatcherGroup, `type` tag required):
```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash script.sh", "timeout": 10, "statusMessage": "..."}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "bash script.sh", "timeout": 10, "statusMessage": "..."}]}]
  }
}
```
**Feature flag:** `codex_hooks = true` must be in `.codex/config.toml` under `[features]`.

**Idle notification (Layer 6):** Before going idle after dispatching background work, arm the inbox watcher: `bash urc/core/inbox-watcher.sh 120 &`. When it completes with `INBOX_READY`, call `receive_messages()` immediately. Re-arm after processing if expecting more messages.
- **Inbox notifications (6-layer stack)**: PostToolUse inbox-check (Claude), Codex Stop hook block (Codex, v0.114.0+), MCP middleware hints (heartbeat/fleet/dispatch/read), BeforeAgent hook (Gemini), tmux wake nudge (`notify=true`, rate-limited to 1 per 30s per recipient), background inbox watcher (Layer 6).

## Cross-Pane Communication

**Identity**: Auto-registered on SessionStart via `hooks/scripts/auto-register.sh codex`. Pane ID available via `$TMUX_PANE` — always starts with `%`, required in all tool calls. Never infer your identity from another pane's buffer — `read_pane_output` on other panes contains pane IDs that are NOT yours. Use your verified pane ID in all `from_pane` fields.

**Check pane alive:** `tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep '%NNN'` (~50 tokens).

**Discover all agents:** `mcp__urc-coordination__get_fleet_status()` (~15.9K tokens) — only for fleet-wide discovery, orphan scans, or when you need agent metadata (cli, role, status, context%).
```json
{"agents":[{"pane_id":"%1320","cli":"claude","status":"active","label":"spec-writer","alive":true}, ...],"count":N}
```
**Do NOT call `get_fleet_status` before launching Agent Teams** — those are new subprocesses that don't exist in the fleet yet.

**Send a message directly into another pane's TUI (fire-and-forget):**
`mcp__urc-coordination__dispatch_to_pane(pane_id="%NNN", message="your message")`
Returns `delivered` or `failed`.

**Synchronous dispatch (for cross-pane work, NOT used by relay):**
```bash
bash urc/core/dispatch-and-wait.sh "%42" "message" 120
```
Returns structured JSON with status `completed` or `timeout`.

**Send a DB-stored message:**
`mcp__urc-coordination__send_message(from_pane="%YOUR_PANE", to_pane="%TARGET", body="message")`
Use `notify=true` to include a wake nudge to the target pane.
Recipient retrieves with `mcp__urc-coordination__receive_messages(pane_id="%TARGET")`.

**Message size limits:**
- `dispatch_to_pane` / `dispatch-and-wait.sh`: text goes through tmux paste-buffer. Keep under **1000 chars**. 1000-3000 chars usually works but is not guaranteed; over 3000 risks silent truncation.
- `send_message` (DB): 100KB body limit. But the wake nudge text goes through tmux paste-buffer, so the nudge itself has the same limits.
- For long content: write to `.urc/handoff-{FROM}-to-{TO}.md` (strip `%` from pane IDs) and use `send_message(notify=true)` with a short reference like `"Report ready at .urc/handoff-896-to-906.md — read and delete"`. Always use `send_message` (not `dispatch_to_pane`) so the recipient gets a wake nudge. Sender creates; recipient deletes after reading. Handoff files are ephemeral.

**How to send results back to another agent:**
1. **Short results (<1000 chars):** `send_message(from_pane=YOUR_PANE, to_pane=TARGET, body="your results", notify=true)`
2. **Long results (>1000 chars):** Write handoff file, then `send_message` with short reference.
3. **If `wake_status` returns `"failed"`:** Message IS stored — recipient discovers it via inbox hooks on next turn. No retry needed.
4. **Never use `dispatch_to_pane` for "please read and respond"** — it's fire-and-forget with no inbox storage.

**Read what another pane is showing:**
`mcp__urc-coordination__read_pane_output(pane_id="%NNN", lines=30)`

**Teams protocol (DORMANT):**
`mcp__urc-teams__team_send`, `mcp__urc-teams__team_inbox`, `mcp__urc-teams__team_broadcast` — these tools are not available. The Teams MCP server has been removed from `.mcp.json`. Use `send_message`/`receive_messages` for cross-pane messaging.

### Communication Strategy

Pick the right approach based on what you need:

| Need | Approach | Tool / Command |
|------|----------|----------------|
| Send and get the response now | Synchronous dispatch | `bash urc/core/dispatch-and-wait.sh "%NNN" "message" 120` |
| Inject text, no response needed | Fire-and-forget | `dispatch_to_pane(pane_id="%NNN", message="...")` |
| Async message / question / task | DB messaging | `send_message(from, to, body, notify=true)` + recipient calls `receive_messages` |

**Synchronous dispatch** — blocks until the target completes or times out:
```bash
bash urc/core/dispatch-and-wait.sh "%NNN" "your message" 120
```
Atomically: clears signals, dispatches, waits, reads response. Returns JSON with `status` (`completed` or `timeout`) and `response`. Timeout is not fatal — always read output regardless.
Timeout guidance: 60s for simple questions, 120s (default) for most tasks, 180-300s for complex analysis or multi-file edits.

**Background dispatch** — non-blocking, useful for parallel orchestration:
```bash
bash urc/core/dispatch-and-wait.sh "%42" "task A" 120 > /tmp/result-42.json &
bash urc/core/dispatch-and-wait.sh "%43" "task B" 120 > /tmp/result-43.json &
wait  # then read /tmp/result-*.json
```
Redirect output to temp files — without redirection, JSON results are interleaved and lost.

**Fire-and-forget** — inject text into a pane's TUI, returns `delivered` or `failed`:
`mcp__urc-coordination__dispatch_to_pane(pane_id="%NNN", message="...")`
Sequential calls to the same pane are delivered in order. Concurrent calls to different panes run in parallel.

**DB messaging** — persistent, async, with inbox notifications:
- Send: `mcp__urc-coordination__send_message(from_pane="%YOU", to_pane="%TARGET", body="message", notify=true)`
- Receive: `mcp__urc-coordination__receive_messages(pane_id="%YOU")`
- Claude gets automatic inbox hints via PostToolUse inbox-check. Gemini gets inbox hints via BeforeAgent hook. **Codex gets inbox detection via Stop hook** (v0.114.0+, `codex_hooks` feature flag) — the strongest mechanism, blocking turn completion until messages are read. Fallback for older Codex: call `heartbeat()` to discover unread messages (see Inbox section above).

**Error handling:**
- `timeout` — read pane output anyway (`read_pane_output`). Retry once after 5s with same timeout. If second timeout, message the orchestrator or user.
- `failed` — pane is dead. Confirm: `tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q '%NNN'` (~50 tokens). Don't retry — spawn a replacement or reassign to a live agent.

**Return format (synchronous dispatch):**
```json
{"status":"completed","response":"...","pane":"%NNN","cli":"codex","latency_s":42}
{"status":"timeout","captured":"last 40 lines of pane output..."}
```

**`notify` default:** `notify=true` is recommended for all interactive messaging. `notify=false`: use when storing a message for later retrieval (logging, batch collection) without interrupting the recipient. If `send_message` returns `wake_status: "failed"`, no action needed — the message is stored and the recipient discovers it via inbox hooks on their next turn.

**`receive_messages` behavior:** Marks messages as read atomically — calling it twice returns nothing on the second call. Messages are ordered by DB insert time (FIFO).

**Pane lookup costs:**
- **Pane alive?** `tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q '%NNN'` (~50 tokens)
- **Full fleet?** `mcp__urc-coordination__get_fleet_status()` (~15.9K tokens) — only for fleet-wide discovery, orphan scans, health checks
- **Agent Teams?** Do NOT call `get_fleet_status` before launching Agent Teams — they're new subprocesses, not in the fleet yet.

## Key Files

| Component | File |
|-----------|------|
| Coordination server (11 MCP tools) | `urc/core/server.py` |
| Teams server (DORMANT, 17 tools) | `urc/core/teams_server.py` |
| Pane communication | `urc/core/send.sh` |
| Turn completion hook | `urc/core/hook.sh` |
| RC Bridge relay agent | `.claude/agents/rc-bridge.md` |
| Inbox watcher (Layer 6) | `urc/core/inbox-watcher.sh` |
| Codex config | `.codex/config.toml` |
| Codex hooks config | `.codex/hooks.json` |
| Unified inbox check (all CLIs) | `hooks/scripts/inbox-check.sh` |
| Auto-register hook | `hooks/scripts/auto-register.sh` |
| Auto-deregister hook | `hooks/scripts/auto-deregister.sh` |
| Non-interactive dispatch | `urc/core/dispatch-exec.sh` |

## Pane Dispatch Rules

- **Never use raw `tmux send-keys`** — always use `dispatch_to_pane` MCP tool or `send.sh`. Note: `send.sh` skips Escape for Codex panes (Escape breaks Codex TUI input submission).
- **Keep messages short** — under ~1000 chars for dispatched text (see Message size limits above). Use handoff files for longer content.
- **Check return status** — `delivered` = success, `failed` = pane dead
- **Verify after dispatch** — wait 5-10s, then `read_pane_output()` to confirm the target started processing
- Core edits (`urc/core/`) require planning first
- Commit frequently with descriptive messages
