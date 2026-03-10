<!-- This file contains instructions for Gemini CLI agents. For human documentation, see README.md -->
# URC — CLI-to-CLI Communication & RC Bridge

## What This Is
URC enables cross-CLI communication between Claude Code, Codex, and Gemini panes via MCP tools backed by a shared SQLite coordination database.

## RC Bridge
The RC Bridge makes this Gemini pane controllable from the Claude Code phone app. A Haiku relay pane forwards messages between the phone app and this pane.

**How it works:**
1. A Claude Code relay pane runs the `rc-bridge` agent (Haiku model)
2. It's pre-configured with target pane ID and CLI type via tmux pane options (set by `urc-spawn.sh`)
3. State is stored in tmux pane options (`@bridge_target`, `@bridge_cli`, `@bridge_relays`)
4. Phone message -> relay hook dispatches to this pane via `send.sh` -> your response is captured by `hook.sh` and written to a push file -> relay picks it up on next wake and displays it verbatim on phone

**Launch:** Use `/rc` command in this Gemini pane, or `/rc-bridge gemini` from Claude Code.

## Available MCP Tools (urc_coordination — 11 tools)

> **Note:** Gemini CLI uses underscores in MCP server names (`urc_coordination`) instead of hyphens (`urc-coordination`) — this is a Gemini CLI naming convention requirement. The naming is transparent: just use `mcp__urc_coordination__tool_name()` syntax. The MCP server is `urc/core/server.py`.

**NEVER run `python3 urc/core/server.py` as a shell command** — it is an MCP server, not a CLI tool.

| Tool | Purpose |
|------|---------|
| `register_agent` | Register this pane in the coordination DB |
| `heartbeat` | Send a heartbeat with context usage |
| `get_fleet_status` | List all registered agents |
| `rename_agent` | Set a display label for a pane |
| `dispatch_to_pane` | Send a message to a tmux pane via send.sh |
| `read_pane_output` | Capture recent output from a pane's buffer |
| `send_message` | Send a message to another agent (use `notify=true` to include wake nudge) |
| `receive_messages` | Get unread messages |
| `kill_pane` | Kill a tmux pane (requires explicit confirmation) |
| `cancel_dispatch` | SIGINT target + clear signals + unblock waiting dispatcher |
| `bootstrap_validate` | Validate CWD/directories/hook/tmux setup |

## Turn Completion
The `AfterAgent` hook in `.gemini/settings.json` fires `hook.sh` after every turn. This performs the full 4-step signal ordering:
1. Write response file `.urc/responses/{PANE}.json`
2. Touch signal file `.urc/signals/done_{PANE}`
3. `tmux wait-for -S "urc_done_{PANE}"` (wakes blocking dispatchers)
4. Append JSONL `.urc/streams/{PANE}.jsonl`

## Verifying MCP Connectivity

To check that MCP servers are properly connected in a running Gemini session:

- **`/mcp list`** — The correct way to verify MCP connectivity. Shows configured servers, connection state, discovered tools/prompts/resources, and per-server errors. This is the canonical MCP health check.
- **`/mcp refresh`** — Restarts MCP servers and reloads tools without restarting Gemini. Use this after config changes.
- **`/mcp desc`** or **`/mcp schema`** — Deeper validation of tool descriptions and schemas.
- **Do NOT use `/tools`** to check MCP status. The `/tools` command intentionally filters out MCP tools (`serverName` tools are excluded), so it will show zero MCP tools even when servers are connected and working.
- **Out-of-session check:** `gemini mcp list` runs an active connection test (connect + ping with 5s timeout) and reports Connected/Disconnected per server.

## Pane Dispatch Rules
- **Never use raw `tmux send-keys`** — always use `dispatch_to_pane` MCP tool or `send.sh`
- **NEVER run `python3 urc/core/server.py` as a shell command** — it is an MCP server, not a CLI tool. Running it starts an infinite STDIO loop that hangs your shell. Use MCP tools or `tmux capture-pane -t %NNN -p -S -80` instead.
- **Keep messages short** — under ~1000 chars for dispatched text (see Message size limits in Cross-Pane Communication). Use handoff files for longer content.
- **Check return status** — `delivered` = success, `failed` = pane dead
- **Verify after dispatch** — wait 5-10s, then `read_pane_output()` to confirm processing started
- **Cold-start delay** — freshly spawned Gemini panes need ~10s to initialize. The relay flow handles this automatically, but direct dispatch to a new Gemini pane may fail if sent within 10s of pane creation.
- Core edits (`urc/core/`) require planning first

## Inbox & Bidirectional Messaging

Gemini has automatic inbox notification via the `BeforeAgent` hook (`.gemini/hooks/inbox-inject.sh`). This fires before every turn — no polling needed. When messages are waiting, you'll see:
```
INBOX: You have 2 unread message(s) from %1316. Call receive_messages("%YOUR_PANE") to read them.
```

**INBOX notifications are high priority — act immediately:**
1. Call `mcp__urc_coordination__receive_messages(pane_id="%YOUR_PANE")` before doing anything else
2. Read the messages and act on them before continuing other work
3. Reply using DB messaging (see [Communication Strategy](#communication-strategy) for when to use each approach)

**Sending messages to other agents:**
`mcp__urc_coordination__send_message(from_pane="%YOUR_PANE", to_pane="%TARGET", body="message", notify=true)`
The recipient will be notified automatically via their CLI's inbox hook. With `notify=false`, the message is stored but no wake nudge is sent — Gemini recipients still see it on their next turn via the BeforeAgent hook. This is DB messaging — see the Communication Strategy section for alternatives.

**Idle notification (Layer 5):** Before going idle after dispatching background work, arm the inbox watcher: `bash urc/core/inbox-watcher.sh 120 &`. When it completes with `INBOX_READY`, call `receive_messages()` immediately. Re-arm after processing if expecting more messages.
- **Inbox notifications (5-layer stack)**: PostToolUse piggyback (Claude), MCP middleware hints (heartbeat/fleet/dispatch/read), BeforeAgent hook (Gemini), tmux wake nudge (`notify=true`, rate-limited to 1 per 30s per recipient), background inbox watcher (Layer 5).

## Cross-Pane Communication

**Identity verification (before ANY cross-pane messaging):** Run `echo $TMUX_PANE` to confirm your own pane ID (returns e.g. `%904`). Never infer your identity from another pane's buffer — `read_pane_output` on other panes contains pane IDs that are NOT yours. Use your verified pane ID in all `from_pane` fields.

**Check pane alive:** `tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep '%NNN'` (~50 tokens).

**Discover all agents:** `mcp__urc_coordination__get_fleet_status()` (~15.9K tokens) — only for fleet-wide discovery, orphan scans, or when you need agent metadata (cli, role, status, context%).
```json
{"agents":[{"pane_id":"%1320","cli":"claude","status":"active","label":"spec-writer","alive":true}, ...],"count":N}
```
**Do NOT call `get_fleet_status` before launching Agent Teams** — those are new subprocesses that don't exist in the fleet yet.

**Send to another pane:** See [Communication Strategy](#communication-strategy) for which approach to use (synchronous dispatch, fire-and-forget, or DB messaging).

**Message size limits:**
- `dispatch_to_pane` / `dispatch-and-wait.sh`: text goes through tmux paste-buffer. Keep under **1000 chars**. 1000-3000 chars usually works but is not guaranteed; over 3000 risks silent truncation.
- `send_message` (DB): 100KB body limit. But the wake nudge text goes through tmux paste-buffer, so the nudge itself has the same limits.
- For long content: write to `.urc/handoff-{FROM}-to-{TO}.md` (strip `%` from pane IDs) and dispatch a short reference like `"Read .urc/handoff-896-to-906.md"`. Sender creates; recipient deletes after reading.

**Read what another pane is showing (MCP preferred, shell fallback):**
`mcp__urc_coordination__read_pane_output(pane_id="%NNN", lines=30)`
MCP tools are the primary method for all pane communication. The shell fallback below is only for edge cases where MCP servers are unavailable (e.g., server crash, startup race):
```bash
tmux capture-pane -t %NNN -p -S -80
```

**Teams protocol (DORMANT):**
`mcp__urc_teams__team_send`, `mcp__urc_teams__team_inbox`, `mcp__urc_teams__team_broadcast` — these tools are not available. The Teams MCP server has been removed from `.mcp.json`. Use `send_message`/`receive_messages` for cross-pane messaging.

### Communication Strategy

Choose the right approach based on what you need:

| Need | Approach | Tool/Command |
|------|----------|-------------|
| Send and wait for response | Synchronous dispatch | `bash urc/core/dispatch-and-wait.sh "%NNN" "message" 120` |
| Inject text, no response needed | Fire-and-forget | `mcp__urc_coordination__dispatch_to_pane(pane_id, message)` |
| Send a question/task to another agent | DB messaging | `mcp__urc_coordination__send_message(from_pane, to_pane, body, notify=true)` |

**Synchronous dispatch** — blocks until the target completes its turn:
```bash
bash urc/core/dispatch-and-wait.sh "%NNN" "your message" 120
```
Atomically: clears signals, dispatches, waits for completion, reads response. Returns structured JSON with `status` (`completed` or `timeout`) and `response`.
Timeout guidance: 60s for simple questions, 120s (default) for most tasks, 180-300s for complex analysis or multi-file edits.

**Fire-and-forget** — inject text into a pane's TUI, returns immediately:
`mcp__urc_coordination__dispatch_to_pane(pane_id="%NNN", message="...")`
Returns `delivered` or `failed`. Use for commands, wake nudges, or when you'll check results separately.
Sequential calls to the same pane are delivered in order. Concurrent calls to different panes run in parallel.

**DB messaging** — async, persisted, triggers inbox notification:
`mcp__urc_coordination__send_message(from_pane="%YOUR_PANE", to_pane="%TARGET", body="message", notify=true)`
Recipient reads via `mcp__urc_coordination__receive_messages(pane_id="%TARGET")`. Use for questions, task assignments, or anything the recipient should see on their next turn.

**Background dispatch** — non-blocking synchronous pattern:
```bash
bash urc/core/dispatch-and-wait.sh "%NNN" "message" 120 > /tmp/result-NNN.json &
bash urc/core/dispatch-and-wait.sh "%MMM" "message" 120 > /tmp/result-MMM.json &
wait  # then read /tmp/result-*.json
```
Redirect output to temp files — without redirection, JSON results are interleaved and lost.

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
- **Full fleet?** `mcp__urc_coordination__get_fleet_status()` (~15.9K tokens) — only for fleet-wide discovery, orphan scans, health checks
- **Agent Teams?** Do NOT call `get_fleet_status` before launching Agent Teams — they're new subprocesses, not in the fleet yet.

## Key Files
| Component | File |
|-----------|------|
| Coordination server (11 MCP tools) | `urc/core/server.py` |
| Teams MCP server (DORMANT, 17 tools) | `urc/core/teams_server.py` |
| Pane communication | `urc/core/send.sh` |
| Turn completion hook | `urc/core/hook.sh` |
| Inbox watcher (Layer 5) | `urc/core/inbox-watcher.sh` |
| Gemini config (generated by setup.sh) | `.gemini/settings.json` |
