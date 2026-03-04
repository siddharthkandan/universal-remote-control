<!-- This file contains instructions for Codex CLI agents. For human documentation, see README.md -->
# URC — CLI-to-CLI Communication & RC Bridge

URC enables cross-CLI communication between Claude Code, Codex, and Gemini panes via MCP tools, and provides RC Bridge for phone-to-CLI remote control.

## RC Bridge System

The RC Bridge lets you control this Codex pane from the Claude Code phone app:
1. A Claude Code Haiku relay pane spawns alongside your pane
2. It receives a bootstrap message like `(856) CODEX` to pair with your pane
3. Phone messages go to the relay, which forwards them to your pane via MCP tools
4. Your output is read back and displayed on the phone

Launch with: `/rc-bridge`

## Available MCP Tools

### urc-coordination (pane communication)
| Tool | Purpose |
|------|---------|
| `dispatch_to_pane` | Send a message to a tmux pane via tmux-send-helper.sh |
| `read_pane_output` | Capture recent output from a pane's tmux buffer |
| `register_agent` | Register a pane in the coordination database |
| `heartbeat` | Send heartbeat update for a pane |
| `rename_agent` | Set display label for a pane |
| `get_fleet_status` | List all registered agents and their status |
| `send_message` | Send inter-agent message |
| `receive_messages` | Get unread messages |
| `report_event` | Record a structured event |
| `health_check` | Return server health metrics (uptime, DB size, agent/task/message counts) |
| `claim_task` | Claim the highest-priority pending task for this agent |
| `complete_task` | Mark a claimed task as completed (with optional commit SHA) |
| `kill_pane` | Kill a tmux pane (requires explicit confirmation) |

### urc-teams (cross-CLI messaging)
Team creation, membership, task management, and typed messaging between CLI agents. See `urc/core/teams_server.py` for full tool list.

## Turn Completion

Your `notify` hook in `.codex/config.toml` fires `urc/core/turn-complete-hook.sh` after each turn. This:
- Touches a turn signal file
- Appends to `events.log`
- Writes `signals/done_PANE` for filesystem polling

Other agents poll `signals/done_PANE` via Bash to detect when you finish.

## Cross-Pane Communication

**Find your pane ID:** Run `echo $TMUX_PANE` (returns e.g. `%856`).

**Discover other panes:** Call `mcp__urc-coordination__get_fleet_status()` to list all registered agents and their pane IDs.

**Send a message directly into another pane's TUI (most reliable):**
`mcp__urc-coordination__dispatch_to_pane(pane_id="%NNN", message="your message")`
Returns `delivered`, `uncertain`, `queued`, or `failed`. Use `force=true` to inject even if the target is mid-turn.

**Send a DB-stored message (includes wake nudge):**
`mcp__urc-coordination__send_message(from_pane="%YOUR_PANE", to_pane="%TARGET", body="message")`
Recipient retrieves with `mcp__urc-coordination__receive_messages(pane_id="%TARGET")`.

**Message size limit:** Keep dispatched messages under ~1000 characters. For longer content (handoffs, detailed tasks, multi-step instructions), write to a uniquely-named file and dispatch a short reference:
  - Naming: `.urc/handoff-{FROM_PANE}-to-{TO_PANE}.md` (e.g. `.urc/handoff-896-to-906.md`)
  - Strip the `%` from pane IDs in filenames
  - For broadcast handoffs (no specific target): `.urc/handoff-{FROM_PANE}-{TIMESTAMP}.md`
  - Then dispatch: `"Read .urc/handoff-896-to-906.md for full context"`
  Long messages (3000+ chars) may be silently truncated by tmux paste buffers, even when `dispatch_to_pane` reports "delivered".

**Read what another pane is showing:**
`mcp__urc-coordination__read_pane_output(pane_id="%NNN", lines=30)`

**Teams protocol (structured cross-CLI collaboration):**
`mcp__urc-teams__team_send`, `mcp__urc-teams__team_inbox`, `mcp__urc-teams__team_broadcast` — see `urc/core/teams_server.py`.

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
4. **Read** output: `read_pane_output(pane_id="%NNN", lines=80)` — do this even on TIMEOUT

**Why:** Without polling, you go silent after dispatch and the user must manually prompt you to check results. Timeout is not fatal — some CLIs may not have hooks configured. Always read output regardless.

## Key Files

| Component | File |
|-----------|------|
| Coordination server (13 MCP tools) | `urc/core/coordination_server.py` |
| Teams server (17 MCP tools) | `urc/core/teams_server.py` |
| Pane communication | `urc/core/tmux-send-helper.sh` |
| Turn completion hook | `urc/core/turn-complete-hook.sh` |
| RC Bridge relay agent | `.claude/agents/rc-bridge.md` |
| Codex config | `.codex/config.toml` |

## Pane Dispatch Rules

- **Never use raw `tmux send-keys`** — always use `dispatch_to_pane` MCP tool or `tmux-send-helper.sh`
- **Keep messages short** — under ~100 chars for wake-up nudges, under ~200 chars for instructions. Long messages with special characters can fail silently in the TUI input field.
- **Check return status** — `delivered` = success, `queued` = retry with `force=true`, `uncertain` = text may be stuck in input field (retry shorter), `failed` = pane dead
- **Verify after dispatch** — wait 5-10s, then `read_pane_output()` to confirm the target started processing
- Core edits (`urc/core/`) require planning first
- Commit frequently with descriptive messages
