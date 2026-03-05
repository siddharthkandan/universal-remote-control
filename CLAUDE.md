<!-- This file contains instructions for Claude Code AI agents working on this project. For human documentation, see README.md -->
# URC — RC Bridge + CLI-to-CLI Communication

## Quick Start
- `/urc codex` — spawn Codex pane + bridge it to your phone
- `/urc gemini` — spawn Gemini pane + bridge it to your phone
- `/urc %NNN` — bridge an existing pane by ID
- Aliases: `/rc-bridge`, `/rc-any`, `/rc-relay` all work
- From Codex: activate `rc-bridge` skill — spawns relay, bridges back to Codex pane
- From Gemini: `/rc` command — spawns relay, bridges back to Gemini pane

## Development Rules
- Core edits (`urc/core/`) require planning first
- Never use raw `tmux send-keys` — always use `tmux-send-helper.sh`
- Commit frequently with descriptive messages
- **Plugin validation**: Run `bash scripts/validate-plugin.sh` (22 checks, works from any context)
- **Never `claude --plugin-dir .` from inside Claude Code** — the `CLAUDECODE` env var blocks nested sessions. Use the validation script instead.

## Architecture (v2)
- Coordination server: `urc/core/coordination_server.py` (18 MCP tools)
- Teams protocol: `urc/core/teams_protocol.py` (cross-CLI messaging)
- Teams MCP server: `urc/core/teams_server.py` (17 MCP tools)
- RC Bridge agent: `.claude/agents/rc-bridge.md` (Haiku passthrough via dispatch-and-wait.sh)
- URC Spawn script: `urc/core/urc-spawn.sh` (fire-and-forget bash spawner, ~20s)
- RC Bridge skill: `.claude/skills/rc-any/SKILL.md` (thin dispatcher → runs urc-spawn.sh in background)
- CLI detection: `urc/core/lib-cli.sh` (3-CLI field mapping)
- Dispatch composite: `urc/core/dispatch-and-wait.sh` (atomic dispatch + wait + read)
- Response schema: `urc/schemas/response.md`

## Communication
- Claude-to-Claude: Native Agent Teams (TeamCreate + Agent tool)
- Cross-CLI (Claude/Codex/Gemini): Teams protocol via MCP tools
- Phone to Codex/Gemini: `/urc` relay bridges using `dispatch-and-wait.sh`
- Inbox notifications: 4-layer stack (PostToolUse piggyback, MCP middleware hints, Gemini BeforeAgent, tmux wake)

## Cross-Pane Communication

See [AGENTS.md](AGENTS.md#cross-pane-communication) for the full cross-pane protocol.

**v2 pattern (preferred):**
- `bash urc/core/dispatch-and-wait.sh "%TARGET" "message" 120` — atomic dispatch + wait + read
- Returns structured JSON: `{status, response_text, pane_id, cli, latency_ms}`
- Used by relay agent, available from any CLI via Bash

**Legacy pattern:**
- `dispatch_to_pane(pane_id, message)` — send to a pane
- `read_pane_output(pane_id, lines)` — read pane buffer
- `send_message(from_pane, to_pane, body)` — DB-stored message with inbox signal

## Key Files
| Component | File |
|-----------|------|
| Coordination server (18 tools) | `urc/core/coordination_server.py` |
| Teams protocol (data layer) | `urc/core/teams_protocol.py` |
| Teams MCP server (17 tools) | `urc/core/teams_server.py` |
| SQLite foundation | `urc/core/coordination_db.py` |
| JSONL audit log | `urc/core/jsonl_recovery.py` |
| CLI detection library | `urc/core/lib-cli.sh` |
| Dispatch-and-wait composite | `urc/core/dispatch-and-wait.sh` |
| Pane communication | `urc/core/tmux-send-helper.sh` |
| State detection | `urc/core/observer.sh` |
| Turn completion hook | `urc/core/turn-complete-hook.sh` |
| Response file schema | `urc/schemas/response.md` |
| RC Bridge agent | `.claude/agents/rc-bridge.md` |
| URC Spawn script (fire-and-forget) | `urc/core/urc-spawn.sh` |
| RC Bridge skill (thin dispatcher) | `.claude/skills/rc-any/SKILL.md` |
| Inbox piggyback (Claude) | `.claude/hooks/inbox-piggyback.sh` |
| Inbox inject (Gemini) | `.gemini/hooks/inbox-inject.sh` |
| Plugin manifest | `.claude-plugin/plugin.json` |
| Plugin hooks | `hooks/hooks.json` |
| Plugin validator | `scripts/validate-plugin.sh` |
| Codex RC skill | `.agents/skills/rc-bridge/SKILL.md` |
| Codex instructions | `AGENTS.md` |
| Gemini instructions | `GEMINI.md` |
| URC quick launcher (! mode) | `urc.sh` |
| MCP config | `.mcp.json` |
