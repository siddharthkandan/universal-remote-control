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

## Architecture
- Coordination server: `urc/core/coordination_server.py` (13 MCP tools)
- Teams protocol: `urc/core/teams_protocol.py` (cross-CLI messaging)
- Teams MCP server: `urc/core/teams_server.py` (17 MCP tools)
- RC Bridge agent: `.claude/agents/rc-bridge.md` (Haiku passthrough)
- RC Bridge skill: `.claude/skills/rc-bridge/SKILL.md` (universal launcher)

## Communication
- Claude-to-Claude: Native Agent Teams (TeamCreate + Agent tool)
- Cross-CLI (Claude/Codex/Gemini): Teams protocol via MCP tools
- Phone to Codex/Gemini: `/urc` relay bridges

## Cross-Pane Communication

See [AGENTS.md](AGENTS.md#cross-pane-communication) for the full cross-pane protocol (dispatch, messaging, handoff naming, size limits) and the required dispatch-and-wait pattern.

**Quick reference:**
- `dispatch_to_pane(pane_id, message)` — send to a pane
- `read_pane_output(pane_id, lines)` — read pane buffer
- `send_message(from_pane, to_pane, body)` — DB-stored message with wake nudge
- Always poll `signals/done_%NNN` after dispatching — never fire-and-forget

## Key Files
| Component | File |
|-----------|------|
| Coordination server (13 tools) | `urc/core/coordination_server.py` |
| Teams protocol (data layer) | `urc/core/teams_protocol.py` |
| Teams MCP server (17 tools) | `urc/core/teams_server.py` |
| SQLite foundation | `urc/core/coordination_db.py` |
| JSONL audit log | `urc/core/jsonl_recovery.py` |
| Pane communication | `urc/core/tmux-send-helper.sh` |
| State detection | `urc/core/observer.sh` |
| Turn completion hook | `urc/core/turn-complete-hook.sh` |
| RC Bridge agent | `.claude/agents/rc-bridge.md` |
| RC Bridge skill (universal) | `.claude/skills/rc-bridge/SKILL.md` |
| Plugin manifest | `.claude-plugin/plugin.json` |
| Plugin hooks | `hooks/hooks.json` |
| Plugin validator | `scripts/validate-plugin.sh` |
| Codex RC skill | `.agents/skills/rc-bridge/SKILL.md` |
| Codex instructions | `AGENTS.md` |
| Gemini instructions | `GEMINI.md` |
| MCP config | `.mcp.json` |
