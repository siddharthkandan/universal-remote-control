# Getting Started

## What You'll Build

By the end of this guide, you'll have a bridge between your phone and a Codex or Gemini agent running on your machine. You'll send instructions from the Claude app on your phone, have them forwarded to Codex or Gemini for execution, and see the results — all without touching your laptop. The bridge is a stateless Haiku relay that acts as a pure passthrough, so you stay in full control.

## tmux — What It Is and Why You Need It

URC uses **tmux** (terminal multiplexer) to manage multiple CLI sessions in separate panes within one terminal window. Think of it like browser tabs, but for terminals.

**If you've never used tmux:**

1. Install it:
   - macOS: `brew install tmux`
   - Linux: `sudo apt install tmux`

2. Start a tmux session:
   ```bash
   tmux new -s urc
   ```

3. That's it — you're now inside tmux. Everything else works the same as your normal terminal.

**Don't worry about tmux commands.** URC handles all the pane management for you. The `/urc` command will detect if tmux is missing or not running and guide you through setup.

## Prerequisites

- Python 3.10+
- tmux (see above)
- jq
- Claude Code CLI (`curl -fsSL https://claude.ai/install.sh | bash`)
- Claude Max plan (for phone control)
- Codex CLI and/or Gemini CLI (optional)

## Install

```bash
git clone https://github.com/siddharthkandan/universal-remote-control universal-remote-control
cd universal-remote-control
./setup.sh
```

`setup.sh` runs preflight checks (Python 3.10+, tmux, jq, claude CLI, codex/gemini optional), creates `.urc/signals/` for turn-completion hooks, sets up a venv, installs dependencies (`mcp`, `pyyaml`, `anyio`), generates MCP configs for all detected CLIs (`.mcp.json`, `.codex/config.toml`, `.gemini/settings.json`), and runs self-tests.

Verify:

```bash
.venv/bin/python3 urc/core/server.py --self-test
# Expected: PASS: server.py self-test (11 tools)
```

## Bridge a Codex Pane to Your Phone

> **Note:** The `/urc` command only works inside a Claude Code session. Start Claude Code first (`claude` in your terminal), then use `/urc`.

From Claude Code (not from inside Codex/Gemini):

```
/urc codex
```

This spawns a Codex pane, launches a Haiku relay pane, configures the bridge,
and activates Remote Control. Your phone now controls Codex.

## Bridge a Gemini Pane

```
/urc gemini
```

## Bridge an Existing Pane

If you already have a Codex or Gemini pane running:

```
/urc 875
```

The `%` prefix is optional — both `875` and `%875` work. The skill auto-detects the CLI type from the coordination DB.

You can also initiate bridges from inside the target CLI:
- **From Codex:** activate the `rc-bridge` skill
- **From Gemini:** type `/rc`

## How It Works

1. `/urc` spawns a Haiku relay pane running the `rc-bridge` agent
2. The relay connects to your phone via Remote Control (`/remote-control`)
3. You type a message on your phone
4. A `UserPromptSubmit` hook (`bridge-push-hook.sh`) dispatches your message via `send.sh` — no model turn consumed
5. The hook also reads any pending push files and returns responses via `additionalContext`
6. When the target completes its turn, `hook.sh` captures the response and writes a push file
7. The relay picks up the response on its next wake and displays it verbatim on your phone

The bridge is stateless — `/clear` is safe. State lives in tmux pane options.

Additional features: push attribution (shows who asked what), auto-reconnect (spawns replacement if target dies, up to 3 attempts), and health dashboard (`status` command).

## MCP Configuration

The coordination server provides 11 MCP tools for pane management, dispatch, and messaging.
The `.mcp.json` configures it:

```json
{
  "mcpServers": {
    "urc-coordination": {
      "command": ".venv/bin/python3",
      "args": ["urc/core/server.py"],
      "env": { "PYTHONPATH": "." }
    }
  }
}
```

Claude Code auto-starts the server from `.mcp.json`. Codex and Gemini configs are in
`.codex/config.toml` and `.gemini/settings.json`.

> **Note:** The Teams protocol (`urc/core/teams_server.py`) is dormant and not loaded by default. It can be re-enabled by adding a `urc-teams` entry to `.mcp.json` if needed.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `/urc` not found | Run from project root where `.claude/skills/` exists |
| Bridge can't detect CLI type | Ensure target pane called `register_agent()` via MCP |
| Turn completion not detected | Check hook config: `.codex/config.toml` (notify) or `.gemini/settings.json` (AfterAgent) |
| RC disconnects | Re-run `/remote-control` in the relay pane for a new session |
| MCP server won't start | Run `./setup.sh` again, verify `.venv/bin/python3` works |
| Gemini MCP tools missing | Run `gemini mcp list` to check server connection. If connected but tools hidden: check `~/.gemini/policies/urc-mcp.toml` exists (re-run `./setup.sh`). Remove any `tools.allowed` whitelist from `~/.gemini/settings.json`. Note: `/tools` hides MCP tools by design — use `/mcp list` instead. |
