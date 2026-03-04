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
        |  dispatch_to_pane / read_pane_output / signal file polling
        v
  +----------------------------------------------------------+
  |  Coordination Server (13 MCP tools, STDIO transport)     |
  |  SQLite WAL backend, auto-started via .mcp.json          |
  +----------+------------------+-----------------+----------+
             |                  |                 |
       tmux-send-helper.sh  (state detection + retry + verify)
             |                  |                 |
        +----+----+        +---+-----+       +---+-----+
        | Claude  |        | Codex   |       | Gemini  |
        | %391    |        | %392    |       | %393    |
        +---------+        +---------+       +---------+
             |                  |                 |
             |  MCP tools (team_send,             |
             |   team_inbox, ...)                 |
             +----------+------------------------+
                        v
         +--------------------------+
         |  Teams Server            |  17 MCP tools, STDIO
         |  (auto-started)          |  Cross-CLI messaging
         +--------------------------+
```

---

## Layer Details

### 1. Coordination Server (`urc/core/coordination_server.py`)

MCP server with 13 tools over STDIO transport. Auto-started from `.mcp.json`.

| Tool | Purpose |
|------|---------|
| `register_agent` | Register/re-register agent |
| `heartbeat` | Update agent status + context % |
| `health_check` | Server uptime + DB stats |
| `claim_task` | Claim highest-priority pending task |
| `complete_task` | Mark task as completed |
| `send_message` | Send message between agents |
| `receive_messages` | Read unread messages |
| `get_fleet_status` | List all agents with heartbeat age |
| `report_event` | Record structured event |
| `rename_agent` | Set display label |
| `dispatch_to_pane` | Send message to tmux pane (reliable delivery) |
| `read_pane_output` | Capture pane's visible output |
| `kill_pane` | Kill tmux pane (requires confirmation) |

State stored in `.urc/coordination.db` (SQLite WAL).

### 2. RC Bridge Agent (`.claude/agents/rc-bridge.md`)

A Haiku-powered passthrough relay that bridges your phone to a Codex or Gemini pane.

**Design:** Pure wire. No interpretation, routing, or summarization. Messages forwarded
verbatim, output displayed verbatim.

**State recovery:** State lives in tmux pane options (`@bridge_target`, `@bridge_cli`,
`@bridge_relays`), not in context. `/clear` is safe.

**Message loop:**
1. `dispatch_to_pane()` — send user message
2. Poll `signals/done_PANE` via Bash (2s interval, 120s timeout)
3. `read_pane_output()` — capture response
4. Display output in code block

### 3. RC Bridge Skill (`.claude/skills/rc-bridge/SKILL.md`)

Universal launcher for bridge sessions. Invocable as `/rc-bridge`.

| Usage | What happens |
|-------|-------------|
| `/rc-bridge %875` | Auto-detect CLI type, bridge that pane |
| `/rc-bridge codex` | Spawn new Codex pane + bridge it |
| `/rc-bridge gemini` | Spawn new Gemini pane + bridge it |
| `/rc-bridge` (empty) | List unbridged Codex/Gemini panes |

### 4. Teams Server (`urc/core/teams_server.py`)

MCP server with 17 tools for structured cross-CLI messaging. Works with
Claude, Codex, and Gemini.

**Message types:** `message`, `task_assignment`, `status_update`, `completion`,
`idle_notification`, `shutdown_request`, `shutdown_response`,
`plan_approval_request`, `plan_approval_response`.

**Notification architecture:** 4-layer stack:
1. Spawn-time instructions (agents check inbox after tasks)
2. MCP middleware hints (unread counts appended to tool responses)
3. PostToolUse hook piggyback (Claude only, via signal files)
4. tmux wake signals (for idle agents)

### 5. Pane Dispatch Best Practices

`dispatch_to_pane()` is the MCP wrapper around `tmux-send-helper.sh`. It handles
state detection, CLI-aware delays, Enter retries, and delivery verification. But
it has limitations that callers must understand.

**Message length matters:**
- Messages under ~200 chars are most reliable (sent character-by-character via `tmux send-keys -l`)
- Messages over 1000 chars use `tmux load-buffer` + `paste-buffer` (atomic but slower to settle)
- Long messages with special characters (quotes, backticks, braces) can partially render
  in the TUI input field, causing the Enter key to be swallowed silently

**Return statuses and what to do:**

| Status | Meaning | Action |
|--------|---------|--------|
| `delivered` | Helper confirmed content changed in target pane | Success — proceed |
| `uncertain` | Text appeared but Enter wasn't confirmed after 4 retries, OR force-sent to a PROCESSING pane | Message may be stuck in input field — retry with a shorter message |
| `queued` | Target is PROCESSING and `force=false` | Re-dispatch with `force=true` |
| `failed` | Pane doesn't exist, helper error, or cross-group block | Check error message — pane may be dead |

**Rules for inter-agent messaging:**
1. **Keep messages short** — under ~100 chars for wake-up nudges, under ~200 chars for instructions
2. **Never use raw `tmux send-keys`** — always go through `dispatch_to_pane()` or `tmux-send-helper.sh`
3. **Use `force=false` first** — gets clean `failed` for dead panes and `queued` for busy ones
4. **Verify after dispatch** — wait 5-10s, then `read_pane_output()` to confirm the target started processing
5. **If `uncertain`, retry shorter** — the original text likely landed in the input field but wasn't submitted

### 6. Shell Infrastructure

| Script | Purpose |
|--------|---------|
| `tmux-send-helper.sh` | Reliable pane dispatch (the ONLY approved send path) |
| `observer.sh` | State detection + pane resolution |
| `turn-complete-hook.sh` | Turn completion signals for all CLIs |

---

## Configuration

| File | Purpose |
|------|---------|
| `.mcp.json` | Claude MCP server definitions |
| `.codex/config.toml` | Codex MCP + turn-complete hook |
| `.gemini/settings.json` | Gemini MCP + AfterAgent hook |
