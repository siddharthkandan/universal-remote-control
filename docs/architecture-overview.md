# Architecture Overview

URC provides two core capabilities: **RC Bridge** (phone-to-CLI passthrough)
and **Cross-CLI Communication** (structured messaging between Claude, Codex, and Gemini).

---

## Component Map

```
  Phone (Claude mobile app)
        |
        |  Remote Control
        v
  Haiku Relay (rc-bridge agent)
        |  send.sh (fire-and-forget) + __urc_push__ (response delivery)
        v
  +----------------------------------------------------------+
  |  Coordination Server (11 MCP tools, STDIO transport)     |
  |  SQLite WAL backend, auto-started via .mcp.json          |
  +----------+------------------+-----------------+----------+
             |                  |                 |
       send.sh  (state detection + retry + verify)
             |                  |                 |
        +----+----+        +---+-----+       +---+-----+
        | Claude  |        | Codex   |       | Gemini  |
        | %391    |        | %392    |       | %393    |
        +---------+        +---------+       +---------+
```

---

## Layer Details

### 1. Coordination Server (`urc/core/server.py`)

MCP server with 11 tools over STDIO transport. Auto-started from `.mcp.json`.

| Tool | Purpose |
|------|---------|
| `register_agent` | Register/re-register agent |
| `heartbeat` | Update agent status + context % |
| `send_message` | Send message between agents |
| `receive_messages` | Read unread messages |
| `get_fleet_status` | List all agents with heartbeat age |
| `rename_agent` | Set display label |
| `dispatch_to_pane` | Send message to tmux pane (reliable delivery) |
| `read_pane_output` | Capture pane's visible output |
| `kill_pane` | Kill tmux pane (requires confirmation) |
| `cancel_dispatch` | SIGINT target + clear signals + unblock waiting dispatcher |
| `bootstrap_validate` | Validate CWD/directories/hook/tmux setup |

State stored in `.urc/coordination.db` (SQLite WAL).

### 2. RC Bridge Agent (`.claude/agents/rc-bridge.md`)

A Haiku-powered passthrough relay that bridges your phone to a Codex or Gemini pane.

**Design:** Pure wire. No interpretation, routing, or summarization. Messages forwarded
verbatim, output displayed verbatim.

**State recovery:** State lives in tmux pane options (`@bridge_target`, `@bridge_cli`,
`@bridge_relays`, `@bridge_respawns`), not in context. `/clear` is safe.

**Message loop (async):**
1. `bash urc/core/send.sh "%TARGET" "message"` — fire-and-forget dispatch
2. Returns instantly with `{status: "delivered"}` or `{status: "failed"}`
3. Display "Sent to %TARGET (CLI_TYPE)"
4. Response arrives later via `__urc_push__` (pushed by hook.sh when target completes)

**Additional features:**
- Push attribution: shows who dispatched and what was asked
- Auto-reconnect: if target dies, spawns replacement (3 attempts max)
- Health dashboard: "status" command shows target alive/dead, relay count, respawn count

### 3. RC Bridge Skill (`.claude/skills/rc-any/SKILL.md`)

Universal launcher for bridge sessions. Invocable as `/rc-bridge`, `/rc-any`, `/rc-relay`.

| Usage | What happens |
|-------|-------------|
| `/rc-bridge %875` | Auto-detect CLI type, bridge that pane |
| `/rc-bridge codex` | Spawn new Codex pane + bridge it |
| `/rc-bridge gemini` | Spawn new Gemini pane + bridge it |
| `/rc-bridge` (empty) | List unbridged Codex/Gemini panes |

### 4. Teams Server (`urc/core/teams_server.py`) — DORMANT

MCP server with 17 tools for structured cross-CLI messaging. Currently
dormant (removed from `.mcp.json`). Preserved for future rebuild.

### 4b. Inbox Notification Architecture (active, 5-layer stack)

1. **PostToolUse piggyback** (Claude): `.claude/hooks/inbox-piggyback.sh` — O(1) stat, uses `additionalContext`
2. **MCP middleware hints**: `_peek_inbox_hint()` in heartbeat, get_fleet_status, dispatch_to_pane, read_pane_output
3. **BeforeAgent hook** (Gemini): `.gemini/hooks/inbox-inject.sh` — additionalContext injection with broadcast dedup
4. **tmux wake nudge**: `send_message(notify=True)` sends text to idle pane (rate-limited: 30s cooldown per recipient)
5. **Background inbox watcher**: `urc/core/inbox-watcher.sh` — agent arms via background task, blocks on `tmux wait-for`, completes when message arrives

### 5. Pane Dispatch Best Practices

`dispatch_to_pane()` is the MCP wrapper around `send.sh`. It handles
state detection, CLI-aware delays, Enter retries, and delivery verification. But
it has limitations that callers must understand.

**Message length matters:**
- All messages use `tmux load-buffer` + `paste-buffer` (bracketed paste) for reliability
- Keep messages under ~1000 chars. 1000-3000 chars usually works; over 3000 risks silent truncation
- A pre-Enter fingerprint check (2s timeout) verifies text appeared before pressing Enter

**Return statuses:**

| Path | Status | Meaning |
|------|--------|---------|
| Send (`send.sh` / `dispatch_to_pane`) | `delivered` | tmux commands succeeded (NOT confirmation that text was submitted — known limitation) |
| Send | `failed` | Pane doesn't exist, helper error, or send failure |
| Wait (`dispatch-and-wait.sh`) | `completed` | Response received within timeout |
| Wait | `timeout` | No response within timeout window |

**Rules for inter-agent messaging:**
1. **Keep messages short** — under ~100 chars for wake-up nudges, under ~200 chars for instructions
2. **Never use raw `tmux send-keys`** — always go through `dispatch_to_pane()` or `send.sh`
3. **Prefer `dispatch-and-wait.sh`** for synchronous relay — atomic dispatch + wait + read in one call
4. **Use `dispatch_to_pane` MCP tool** for fire-and-forget sends (no wait)

### 6. Shell Infrastructure

| Script | Purpose |
|--------|---------|
| `dispatch-and-wait.sh` | Atomic dispatch + wait + read (relay composite) |
| `send.sh` | Reliable pane dispatch (the ONLY approved send path) |
| `wait.sh` | tmux wait-for blocking, epoch correlation, watchdog |
| `hook.sh` | Turn completion signals + response capture for all CLIs |
| `cli-adapter.sh` | CLI-specific field mapping (source, don't execute) |
| `inbox-watcher.sh` | Layer 5 inbox watcher (blocks on tmux wait-for until message arrives) |

---

## Configuration

| File | Purpose |
|------|---------|
| `.mcp.json` | Claude MCP server definitions |
| `.codex/config.toml` | Codex MCP + turn-complete hook |
| `.gemini/settings.json` | Gemini MCP + AfterAgent hook |
