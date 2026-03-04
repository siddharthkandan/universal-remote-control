<!-- This file contains instructions for Gemini CLI agents. For human documentation, see README.md -->
# URC — CLI-to-CLI Communication & RC Bridge

## What This Is
URC enables cross-CLI communication between Claude Code, Codex, and Gemini panes via MCP tools backed by a shared SQLite coordination database.

## RC Bridge
The RC Bridge makes this Gemini pane controllable from the Claude Code phone app. A Haiku relay pane forwards messages between the phone app and this pane.

**How it works:**
1. A Claude Code relay pane runs the `rc-bridge` agent (Haiku model)
2. It's bootstrapped with `(NNN) GEMINI` where NNN is this pane's ID
3. State is stored in tmux pane options (`@bridge_target`, `@bridge_cli`, `@bridge_relays`)
4. Phone message -> relay dispatches to this pane -> waits for turn completion -> reads output -> displays verbatim

**Launch:** Use `/rc` command in this Gemini pane, or `/rc-bridge gemini` from Claude Code.

## Available MCP Tools (urc_coordination)

> **Note:** Gemini CLI uses underscores in MCP server names (`urc_coordination`) instead of hyphens (`urc-coordination`) — this is a Gemini CLI naming convention requirement.

| Tool | Purpose |
|------|---------|
| `dispatch_to_pane` | Send a message to a tmux pane via tmux-send-helper.sh |
| `read_pane_output` | Capture recent output from a pane's buffer |
| `register_agent` | Register this pane in the coordination DB |
| `heartbeat` | Send a heartbeat with context usage |
| `rename_agent` | Set a display label for a pane |
| `get_fleet_status` | List all registered agents |
| `send_message` | Send a message to another agent |
| `receive_messages` | Get unread messages |
| `report_event` | Record a structured event |
| `health_check` | Return server health metrics (uptime, DB size, agent/task/message counts) |
| `claim_task` | Claim the highest-priority pending task for this agent |
| `complete_task` | Mark a claimed task as completed (with optional commit SHA) |
| `kill_pane` | Kill a tmux pane (requires explicit confirmation) |
| `relay_forward` | Forward message to relay's bridge target (locked-down dispatch) |
| `relay_read` | Read output from relay's bridge target (locked-down read) |

## Turn Completion
The `AfterAgent` hook in `.gemini/settings.json` fires `turn-complete-hook.sh` after every turn. This writes a signal file at `.urc/signals/done_PANE`. Poll this file via Bash to detect turn completion.

## Verifying MCP Connectivity

To check that MCP servers are properly connected in a running Gemini session:

- **`/mcp list`** — The correct way to verify MCP connectivity. Shows configured servers, connection state, discovered tools/prompts/resources, and per-server errors. This is the canonical MCP health check.
- **`/mcp refresh`** — Restarts MCP servers and reloads tools without restarting Gemini. Use this after config changes.
- **`/mcp desc`** or **`/mcp schema`** — Deeper validation of tool descriptions and schemas.
- **Do NOT use `/tools`** to check MCP status. The `/tools` command intentionally filters out MCP tools (`serverName` tools are excluded), so it will show zero MCP tools even when servers are connected and working.
- **Out-of-session check:** `gemini mcp list` runs an active connection test (connect + ping with 5s timeout) and reports Connected/Disconnected per server.

## Pane Dispatch Rules
- **Never use raw `tmux send-keys`** — always use `dispatch_to_pane` MCP tool or `tmux-send-helper.sh`
- **Keep messages short** — under ~100 chars for wake-up nudges, under ~200 chars for instructions. Long messages with special characters can fail silently in the TUI input field.
- **Check return status** — `delivered` = success, `queued` = retry with `force=true`, `uncertain` = retry shorter, `failed` = pane dead
- **Verify after dispatch** — wait 5-10s, then `read_pane_output()` to confirm processing started
- Core edits (`urc/core/`) require planning first

## Cross-Pane Communication

**Find your pane ID:** Run `echo $TMUX_PANE` (returns e.g. `%904`).

**Discover other panes:** Call `mcp__urc_coordination__get_fleet_status()` to list all registered agents and their pane IDs.

**Send a message directly into another pane's TUI (most reliable):**
`mcp__urc_coordination__dispatch_to_pane(pane_id="%NNN", message="your message")`
Returns `delivered`, `uncertain`, `queued`, or `failed`. Use `force=true` to inject even if the target is mid-turn.

**Send a DB-stored message (includes wake nudge):**
`mcp__urc_coordination__send_message(from_pane="%YOUR_PANE", to_pane="%TARGET", body="message")`
Recipient retrieves with `mcp__urc_coordination__receive_messages(pane_id="%TARGET")`.

**Message size limit:** Keep dispatched messages under ~1000 characters. For longer content (handoffs, detailed tasks, multi-step instructions), write to a uniquely-named file and dispatch a short reference:
  - Naming: `.urc/handoff-{FROM_PANE}-to-{TO_PANE}.md` (e.g. `.urc/handoff-896-to-906.md`)
  - Strip the `%` from pane IDs in filenames
  - For broadcast handoffs (no specific target): `.urc/handoff-{FROM_PANE}-{TIMESTAMP}.md`
  - Then dispatch: `"Read .urc/handoff-896-to-906.md for full context"`
  Long messages (3000+ chars) may be silently truncated by tmux paste buffers, even when `dispatch_to_pane` reports "delivered".

**Read what another pane is showing (MCP preferred, shell fallback):**
`mcp__urc_coordination__read_pane_output(pane_id="%NNN", lines=30)`
MCP tools are the primary method for all pane communication. The shell fallback below is only for edge cases where MCP servers are unavailable (e.g., server crash, startup race):
```bash
tmux capture-pane -t %NNN -p -S -80
```

**Teams protocol (structured cross-CLI collaboration):**
`mcp__urc_teams__team_send`, `mcp__urc_teams__team_inbox`, `mcp__urc_teams__team_broadcast` — see `urc/core/teams_server.py`.

### Dispatch-and-Wait Pattern (REQUIRED for cross-pane work)

When you dispatch work to another pane, you MUST poll for their completion — do NOT fire-and-forget. Turn-completion hooks write signal files when any CLI finishes a turn.

**Full pattern:**
1. **Clear** signal files: `rm -f .urc/signals/done_%NNN`
2. **Dispatch** via `dispatch_to_pane(pane_id="%NNN", message="...")`
3. **Poll** for completion:
   ```bash
   ELAPSED=0; while [ ! -f .urc/signals/done_%NNN ] && [ $ELAPSED -lt 300 ]; do sleep 3; ELAPSED=$((ELAPSED + 3)); done
   [ -f .urc/signals/done_%NNN ] && echo "DONE" || echo "TIMEOUT"
   ```
4. **Read** output (MCP or shell — use whichever works):
   - MCP: `mcp__urc_coordination__read_pane_output(pane_id="%NNN", lines=80)`
   - Shell: `tmux capture-pane -t %NNN -p -S -80`
   Do this even on TIMEOUT.

**Why:** Without polling, you go silent after dispatch and the user must manually prompt you to check results. Timeout is not fatal — some CLIs may not have hooks configured. Always read output regardless.

## Key Files
| Component | File |
|-----------|------|
| Coordination server (15 MCP tools) | `urc/core/coordination_server.py` |
| Teams MCP server (17 MCP tools) | `urc/core/teams_server.py` |
| Pane communication | `urc/core/tmux-send-helper.sh` |
| Turn completion hook | `urc/core/turn-complete-hook.sh` |
| Gemini config (generated by setup.sh) | `.gemini/settings.json` |
