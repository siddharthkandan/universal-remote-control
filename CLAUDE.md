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
- **Git: All work on `master` branch**
- Core edits (`urc/core/`) require planning first — read [`docs/design-decisions.md`](docs/design-decisions.md) before modifying core (tmux timing lessons, rejected approaches)
- Never use raw `tmux send-keys` — always use `send.sh`
- Commit frequently with descriptive messages
- **Plugin validation**: Run `bash scripts/validate-plugin.sh` (23 checks, works from any context)
- **Never `claude --plugin-dir .` from inside Claude Code** — the `CLAUDECODE` env var blocks nested sessions. Use the validation script instead.

## Architecture (v3)
- Coordination server: `urc/core/server.py` (11 MCP tools)
- Teams protocol: `urc/core/teams_protocol.py` (DORMANT — removed from .mcp.json)
- Teams MCP server: `urc/core/teams_server.py` (DORMANT — removed from .mcp.json)
- RC Bridge agent: `.claude/agents/rc-bridge.md` (Haiku passthrough — hook-based dispatch + push reading via `additionalContext`, Bash fallback for terminal/error paths)
- Bridge push hook: `hooks/scripts/bridge-push-hook.sh` (UserPromptSubmit — dispatches messages via send.sh, reads push files, returns via `additionalContext`. Registered in `.claude/settings.json`, NOT plugin hooks — project-level hooks fire on independent sessions, plugin hooks do NOT)
- URC Spawn script: `urc/core/urc-spawn.sh` (fire-and-forget bash spawner — pre-sets tmux state + DB registration, `/rename` for session naming, no text bootstrap)
- RC Bridge skill: `.claude/skills/urc/SKILL.md` (thin dispatcher → runs urc-spawn.sh in background)
- CLI adapter: `urc/core/cli-adapter.sh` (CLI-specific field mapping)
- Dispatch composite: `urc/core/dispatch-and-wait.sh` (atomic dispatch + wait + read)
- Response schema: `urc/schemas/response.md`

## Communication Strategy

| Need | Approach | How |
|------|----------|-----|
| Claude-to-Claude orchestration | Agent Teams | TeamCreate + Agent tool (built-in) |
| Response needed now (cross-CLI) | Synchronous dispatch | `bash urc/core/dispatch-and-wait.sh "%NNN" "msg" 120` |
| One-way command, no response | Fire-and-forget | `dispatch_to_pane(pane_id, message)` |
| Async message/question/task | DB messaging | `send_message(from, to, body, notify=true)` |
| Phone to Codex/Gemini | Relay (RC Bridge, async) | `/urc codex` or `/urc gemini` |
| Agent-to-agent (application-level) | codex mcp-server | `mcp__codex__codex(prompt="...")` |
| Headless one-shot (no tmux) | Non-interactive dispatch | `bash urc/core/dispatch-exec.sh <cli> <prompt>` |

- **Agent Teams vs send_message**: Agent Teams spawns a subprocess that shares the parent's context window and returns results inline — use background agents for large tasks to avoid context pressure. `send_message` is async DB store — use for notifications, questions, or handoffs you won't wait for. Agent Teams is Claude-only; `send_message` works cross-CLI.
- **Parallel dispatch**: For concurrent cross-CLI work, use `run_in_background=true`:
  - Bash tool: `Bash(command="bash urc/core/dispatch-and-wait.sh '%NNN' 'msg' 120", run_in_background=true)` — lightweight, result returned via task notification
  - Agent tool: `Agent(prompt="dispatch to %NNN...", run_in_background=true)` — use when dispatch needs LLM decision-making, result in agent response
  - Each background dispatch is independent — one failure doesn't affect others. Check each result individually.
- **Inbox awareness**: Claude has PostToolUse inbox-check for automatic inbox detection. When you see `INBOX: N unread...`, call `receive_messages()` immediately.
- **Codex inbox (v0.114.0+)**: Codex Stop hook auto-detects unread messages after every turn via `codex_hooks` feature flag. Hook blocks turn completion and forces model to call `receive_messages()`. Requires `.codex/hooks.json` with Stop hook config. Fallback for older Codex: `heartbeat()` polling + `notify=true` wake nudge.
- **Inbox notifications (6-layer stack)**: PostToolUse inbox-check (Claude), Codex Stop hook block (Codex, v0.114.0+), MCP middleware hints (heartbeat/fleet/dispatch/read), BeforeAgent hook (Gemini), tmux wake nudge (`notify=true`, rate-limited to 1 per 30s per recipient), background inbox watcher (Layer 6).
- **Idle notification (Layer 6)**: Before going idle after dispatching background work, arm the inbox watcher: `Bash(command="bash urc/core/inbox-watcher.sh 120", run_in_background=true)`. When it completes with `INBOX_READY`, call `receive_messages()` immediately. Re-arm after processing if expecting more messages.

## Cross-Pane Communication

**Identity**: Auto-registered on SessionStart via `hooks/scripts/auto-register.sh`. Pane ID available via `$TMUX_PANE`. Never infer your identity from another pane's buffer — reading `read_pane_output` on other panes will contain pane IDs that are NOT yours.

See [AGENTS.md](AGENTS.md#cross-pane-communication) for the full cross-pane protocol.

**Signal ordering (non-negotiable — see [`docs/turn-completion-system.md`](docs/turn-completion-system.md) for details):**
1. Write response file `.urc/responses/{PANE}.json`
2. Touch signal file `.urc/signals/done_{PANE}`
3. `tmux wait-for -S "urc_done_{PANE}"`
4. Append JSONL `.urc/streams/{PANE}.jsonl`

**Synchronous dispatch (for cross-pane work, NOT used by relay):**
- `bash urc/core/dispatch-and-wait.sh "%TARGET" "message" 120` — atomic dispatch + wait + read
- Note: The RC Bridge relay uses hook-based dispatch (bridge-push-hook.sh returns `DISPATCH_OK`/`DISPATCH_FAIL` via `additionalContext`) + push reading via the same hook (`PUSH_DATA:` in `additionalContext`). Bash fallback exists for error recovery and terminal sessions. Only non-relay dispatchers use synchronous dispatch.
- Timeout guidance: 60s for simple questions, 120s (default) for most tasks, 180-300s for complex analysis
- Returns structured JSON: `{status, response, pane, cli, latency_s}`
- Status: `completed`, `timeout`, `busy` (another dispatch holds the per-pane lock), or `circuit_open` (too many recent failures)

**Fire-and-forget (one-way injection):**
- `dispatch_to_pane(pane_id, message)` — send to a pane, returns `delivered` or `failed`. Sequential calls to same pane are in order; different panes run in parallel.
- `read_pane_output(pane_id, lines)` — read pane buffer

**DB messaging (async, persisted):**
- `send_message(from_pane, to_pane, body, notify)` — DB-stored message (use `notify=true` for wake nudge)
- `receive_messages(pane_id)` — read inbox (marks messages as read atomically — second call returns nothing, FIFO order)

**Error handling:**
- `timeout` — response JSON includes `captured` field with last 40 lines. Retry once after 5s. If second timeout, message the orchestrator or user.
- `failed` — pane is dead. Confirm: `tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q '%NNN'` (~50 tokens). Don't retry — spawn a replacement (`/urc codex` or `/urc gemini`) or reassign to a live agent.

**Return format (synchronous dispatch):**
```json
{"status":"completed","response":"...","pane":"%NNN","cli":"codex","latency_s":42}
{"status":"timeout","captured":"last 40 lines of pane output..."}
```

**`notify` default:** `notify=true` is recommended for all interactive messaging. `notify=false`: use when storing a message for later retrieval (logging, batch collection) without interrupting the recipient. If `send_message` returns `wake_status: "failed"`, no action needed — the message is stored and the recipient discovers it via inbox hooks on their next turn.

**`get_fleet_status` return:**
```json
{"agents":[{"pane_id":"%1320","cli":"claude","status":"active","label":"spec-writer","alive":true}, ...],"count":N}
```

**Message size limits:**
- `dispatch_to_pane` / `dispatch-and-wait.sh`: text goes through tmux paste-buffer. Keep under **1000 chars**. 1000-3000 chars usually works but is not guaranteed; over 3000 risks silent truncation.
- `send_message` (DB): 100KB body limit. Wake nudge text has the same ~1000 char paste-buffer limit.
- For long content: write to `.urc/handoff-{FROM}-to-{TO}.md` and send a short reference via `send_message(from, to, "Report ready at .urc/handoff-X-to-Y.md — read and delete", notify=true)`. Always use `send_message` (not `dispatch_to_pane`) so the recipient gets a wake nudge. Sender creates; recipient deletes after reading.

**How to send results back to another agent:**
1. **Short results (<1000 chars):** `send_message(from_pane=YOUR_PANE, to_pane=TARGET, body="your results", notify=true)`
2. **Long results (>1000 chars):** Write to `.urc/handoff-{FROM}-to-{TO}.md`, then `send_message` with a short reference pointing to the file.
3. **If `wake` returns `"failed"`:** The message IS stored in the DB — the recipient discovers it via inbox hooks on their next turn. No retry needed. Do NOT fall back to `dispatch_to_pane` for messaging.
4. **Never use `dispatch_to_pane` for "please read and respond" patterns** — it's fire-and-forget injection with no inbox storage.

**Pane lookup costs:**
- **Pane alive?** `tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q '%NNN'` (~50 tokens)
- **Full fleet?** `get_fleet_status()` (~15.9K tokens) — only for fleet-wide discovery, orphan scans, health checks
- **Agent Teams?** Do NOT call `get_fleet_status` before launching Agent Teams (the `Agent` tool). Agent Teams are new subprocesses — they don't exist in the fleet yet. Fleet discovery is only for existing cross-CLI panes.

**CLI-specific notes for orchestrators:**
- **Codex (v0.114.0+)**: auto inbox via Stop hook (`codex_hooks` feature flag + `.codex/hooks.json`), now uses unified `hooks/scripts/inbox-check.sh codex`. Hook blocks turn and forces `receive_messages()`. For older Codex (<0.114.0): no auto inbox, must call `heartbeat()`, always use `notify=true`. Escape key breaks Codex TUI input — `send.sh` skips Escape for Codex automatically. **Note:** Codex has no SessionEnd event — deregistration of dead Codex panes is handled by `bootstrap_validate` reaper.
- **Gemini**: auto inbox via BeforeAgent hook. Uses underscore MCP naming (`mcp__urc_coordination__tool_name`).
- **Claude**: auto inbox via PostToolUse inbox-check. Escape needed before Enter (autocomplete dismissal) with 0.1s settle.

## $0 Relay (hook-based, zero model invocation)

Type `>codex: your message` or `>gemini: your message` to relay directly to a target pane. `>: message` uses the default target. The UserPromptSubmit hook handles dispatch — no model turn consumed.

- **Setup**: `bash urc/core/relay-ctl.sh add codex %NNN` then `bash urc/core/relay-ctl.sh on`
- **Status**: `bash urc/core/relay-ctl.sh status`
- **Config**: `.urc/relay-config.json`
- **Phone path**: When you see `additionalContext` containing a relay response, echo it verbatim to the user in a code block. Do not interpret, summarize, or act on it.

## Key Files
| Component | File |
|-----------|------|
| Coordination server (11 tools) | `urc/core/server.py` |
| Teams protocol (data layer) | `urc/core/teams_protocol.py` |
| Teams MCP server (17 tools) | `urc/core/teams_server.py` |
| SQLite foundation | `urc/core/db.py` |
| CLI adapter | `urc/core/cli-adapter.sh` |
| Dispatch-and-wait composite | `urc/core/dispatch-and-wait.sh` |
| Wait helper | `urc/core/wait.sh` |
| Pane communication | `urc/core/send.sh` |
| Turn completion hook | `urc/core/hook.sh` |
| Response file schema | `urc/schemas/response.md` |
| RC Bridge agent | `.claude/agents/rc-bridge.md` |
| Bridge push hook (dispatch + push reading) | `hooks/scripts/bridge-push-hook.sh` |
| File reference resolver (phone attachments) | `hooks/scripts/resolve-file-refs.sh` |
| Project-level hook registration | `.claude/settings.json` |
| URC Spawn script (fire-and-forget) | `urc/core/urc-spawn.sh` |
| RC Bridge skill (thin dispatcher) | `.claude/skills/urc/SKILL.md` |
| Unified inbox check (all CLIs) | `hooks/scripts/inbox-check.sh` |
| Inbox watcher (Layer 6) | `urc/core/inbox-watcher.sh` |
| Plugin manifest | `.claude-plugin/plugin.json` |
| Plugin hooks | `hooks/hooks.json` |
| Plugin validator | `scripts/validate-plugin.sh` |
| $0 Relay hook | `hooks/scripts/urc-relay-hook.sh` |
| Relay config | `.urc/relay-config.json` |
| Relay management | `urc/core/relay-ctl.sh` |
| Circuit breaker | `urc/core/circuit.sh` |
| Codex hooks config | `.codex/hooks.json` |
| Auto-register hook | `hooks/scripts/auto-register.sh` |
| Auto-deregister hook | `hooks/scripts/auto-deregister.sh` |
| Non-interactive dispatch | `urc/core/dispatch-exec.sh` |
| Codex MCP integration guide | `docs/codex-mcp-integration.md` |
| Codex RC skill | `.agents/skills/rc-bridge/SKILL.md` |
| Codex instructions | `AGENTS.md` |
| Gemini instructions | `GEMINI.md` |
| URC quick launcher (! mode) | `urc.sh` |
| MCP config | `.mcp.json` |
| Design decisions & rejected approaches | `docs/design-decisions.md` |

## Tests (160 assertions across 10 suites)
- **DB**: `.venv/bin/python3 urc/core/db.py --self-test` (32 tests)
- **Server**: `.venv/bin/python3 urc/core/server.py --self-test` (34 tests, 11 tools)
- **Hook**: `bash urc/core/test-hook.sh` (25 tests)
- **Dispatch**: `bash urc/core/test-dispatch-and-wait.sh` (9 tests)
- **Send**: `bash urc/core/test-send.sh` (11 tests)
- **Wait**: `bash urc/core/test-wait.sh` (5 tests)
- **CLI adapter**: `bash urc/core/test-cli-adapter.sh` (15 tests)
- **E2E relay**: `bash urc/core/test-e2e-relay.sh` (6 tests)
- **Inbox hooks**: `bash urc/core/test-inbox-hooks.sh` (17 tests)
- **Inbox watcher**: `bash urc/core/test-inbox-watcher.sh` (6 tests)
- **Teams**: `.venv/bin/python3 urc/core/teams_server.py --self-test`
- **Plugin validation**: `bash scripts/validate-plugin.sh` (23 checks)
