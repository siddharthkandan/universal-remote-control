# URC — Universal Remote Control

Control Codex and Gemini from the Claude App on your phone.

![URC Demo — orchestrating Codex and Gemini from the Claude App](docs/demo.gif)

You know `/remote-control` — the Claude Code feature that lets you control a session from the Claude App on your phone. URC makes it **universal**. One command, and your phone controls Codex. Another command, and it controls Gemini. Same app, same conversation, same interface. No extra API keys. No extra apps.

```bash
/urc codex    # Your phone now controls Codex
/urc gemini   # Your phone now controls Gemini
```

Behind the scenes, URC spawns a lightweight Haiku relay that acts as a pure passthrough — your messages go through unchanged, output comes back verbatim. The relay is self-managing: it auto-clears, auto-reconnects on target death, and runs indefinitely without intervention.

## Features

**Phone control for every CLI**
- Bridge any Codex or Gemini pane from your phone in one command
- Spawn new panes or bridge existing ones (`/urc 875`)
- Initiate bridges from the other side too (Codex skill or Gemini `/rc` command)

**Self-managing relay**
- Auto-clears at 25 sends — respawns itself, restores phone connection, resets counter
- Auto-reconnects on target death — spawns replacement, retries your message (3 attempts)
- Type **"status"** to check capacity, target health, and respawn count
- No manual maintenance, no `/clear`, no restarts

**Real-time visibility**
- Push attribution shows who dispatched each message and what was asked
- Instant "message received" confirmation when target gets your message
- Responses stream back to your phone as turns complete

**$0 relay mode**
- Type `>codex: message` or `>gemini: message` for hook-based passthrough
- Zero model invocation, zero cost — a `UserPromptSubmit` hook handles dispatch
- Setup: `bash urc/core/relay-ctl.sh add codex %NNN && bash urc/core/relay-ctl.sh on`

**Cross-CLI coordination**
- 11-tool MCP server for pane-level communication (dispatch, read, register, heartbeat, messaging)
- Agents across Claude Code, Codex, and Gemini can send messages, share work, and coordinate
- 5-layer inbox notification stack ensures no message is missed

**Tested and validated**
- 147 assertions across 10 test suites
- 23-check plugin validation
- Post-Enter stuck-input detection for TUI reliability

## Quick Start

### Prerequisites

- **tmux**: `brew install tmux` (macOS) or `sudo apt install tmux` (Linux)
- **Python 3.10+**, **jq**
- **Claude Code CLI**: `curl -fsSL https://claude.ai/install.sh | bash`
- **Claude Max plan** (for phone control — see [claude.com/pricing](https://claude.com/pricing))
- **Codex CLI** and/or **Gemini CLI** (optional — install whichever you want to bridge)
  - Codex: `npm install -g @openai/codex`
  - Gemini: see [github.com/google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli)

### Install

```bash
tmux new -s urc                # Start a tmux session (required)
git clone https://github.com/siddharthkandan/universal-remote-control
cd universal-remote-control
./setup.sh                     # Detects your CLIs, generates configs
```

Or install as a Claude Code plugin:

```
/plugin marketplace add siddharthkandan/universal-remote-control
/plugin install urc
```

### Use It

From Claude Code (inside tmux):

```bash
/urc codex                    # Spawn Codex pane + bridge it to your phone
/urc gemini                   # Spawn Gemini pane + bridge it to your phone
/urc 875                      # Bridge an existing pane by ID
/urc                          # List unbridged panes
```

Open the **Claude App on your phone** — the relay automatically activates Remote Control. Type a message and it goes straight to Codex or Gemini. Responses stream back as they complete.

Aliases: `/rc-bridge`, `/rc-any`, `/rc-relay` all work.

You can also bridge from the other side:
- **From Codex:** activate the `rc-bridge` skill
- **From Gemini:** type `/rc`

Your Claude plan covers the Haiku relay — no separate API key needed.

### Gemini Setup Note

Gemini CLI requires additional configuration beyond what `setup.sh` generates:

- `setup.sh` creates the project config and policy rules automatically
- If `~/.gemini/settings.json` has a `tools.allowed` whitelist, remove the `"tools"` block
- Verify: `gemini mcp list` (outside session) or `/mcp list` (in session)
- Note: Gemini's `/tools` command intentionally hides MCP tools — don't use it to check

## How It Works

```
Phone (Claude App)
    |  Remote Control
    v
Haiku Relay (rc-bridge agent)        ← self-managing, auto-clears at 25 sends
    |  send.sh         __urc_push__
    |  (dispatch) ←——— (response)
    v                      |
Target pane (tmux)         |
    |  hook.sh fires ——————┘         ← captures response, pushes back to relay
```

**The relay is a stateless passthrough.** State lives in tmux pane options (`@bridge_target`, `@bridge_cli`, `@bridge_relays`). The relay reads your phone message, calls `send.sh` to inject it into the target pane, and waits. When the target completes its turn, `hook.sh` captures the response and pushes it back via `__urc_push__`. The relay displays it on your phone.

**The MCP server** (`urc-coordination`, 11 tools) provides the cross-pane infrastructure: dispatch messages, read pane output, register agents, track heartbeats, and send/receive async messages via SQLite. Any agent in any CLI can use these tools to coordinate with others.

> A second MCP server (`urc-teams`, 17 tools) provides structured team creation, typed messages, and task dependencies. Currently dormant — the coordination server handles all active messaging.

## Project Structure

> The root directory includes CLI-specific files (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, symlinks) because each AI CLI has its own conventions for discovering instructions. All actual code lives in `urc/`.

### Core (`urc/`)

```
urc/
├── core/
│   ├── server.py                 Coordination MCP server (11 tools)
│   ├── db.py                     SQLite foundation
│   ├── teams_protocol.py         Teams data layer (dormant)
│   ├── teams_server.py           Teams MCP server (dormant)
│   ├── send.sh                   Pane dispatch (bracketed paste + post-Enter verify)
│   ├── hook.sh                   Turn completion + push attribution + respawn
│   ├── wait.sh                   Blocking wait with self-wake
│   ├── dispatch-and-wait.sh      Atomic dispatch + wait + read
│   ├── cli-adapter.sh            CLI detection + paste behavior
│   ├── urc-spawn.sh              Fire-and-forget relay+target spawner
│   ├── urc-dispatch.sh           ! mode CLI dispatcher
│   ├── urc-status.sh             Fleet status display
│   ├── inbox-watcher.sh          Background inbox notification
│   ├── circuit.sh                Circuit breaker for dispatch failures
│   ├── relay-ctl.sh              $0 relay configuration
│   └── test-*.sh                 8 test suites (71 assertions)
├── lib/
│   └── state-write.sh            Atomic JSON write helper
└── schemas/
    └── response.md               Response file schema
```

### CLI Integration

| File/Dir | Required by | Purpose |
|----------|-------------|---------|
| `CLAUDE.md` | Claude Code | Agent instructions |
| `AGENTS.md` | Codex | Agent instructions |
| `GEMINI.md` | Gemini | Agent instructions |
| `.claude/agents/` | Claude Code | RC Bridge agent definition |
| `.claude/skills/` | Claude Code | `/urc` command |
| `.claude/hooks/` | Claude Code | Session init + inbox hooks |
| `.agents/skills/` | Codex | Codex bridge skill |

### Plugin System

```
.claude-plugin/plugin.json    Plugin manifest
hooks/hooks.json              Plugin hooks (Stop + SessionStart)
hooks/scripts/plugin-setup.sh Auto-setup on first session
```

## Documentation

- [Getting Started](docs/getting-started.md) — Install, first bridge, tmux basics
- [Architecture Overview](docs/architecture-overview.md) — System design and message flows
- [Turn Completion System](docs/turn-completion-system.md) — Hook signal ordering and response capture
- [Design Decisions](docs/design-decisions.md) — Why things are built this way
- [Teams Protocol](docs/teams-protocol.md) — Structured cross-CLI messaging (dormant)

## Glossary

| Term | What it means |
|------|---------------|
| **Remote Control** | A Claude Code feature that lets you control a session from the Claude App on your phone |
| **MCP** | Model Context Protocol — how AI agents talk to external tools and services |
| **Haiku** | Claude's fastest model — used for the relay since it just passes messages through |
| **tmux** | Terminal multiplexer — runs multiple sessions in panes within one window |
| **Pane** | A terminal session inside tmux, identified by an ID like `%875` |
| **Push** | Response delivery from the target pane back to the relay when a turn completes |

## Troubleshooting

**MCP tools not showing in Gemini?**
Run `gemini mcp list`. If empty, verify `~/.gemini/policies/urc-mcp.toml` exists (created by `setup.sh`). Remove any `tools.allowed` whitelist from `~/.gemini/settings.json`.

**Relay shows "pane does not exist"?**
The target died. Type "status" to confirm, then "reconnect %NNN" with a new pane ID, or let auto-reconnect handle it.

**Text stuck in a pane's input field?**
A TUI timing edge case. `send.sh` retries automatically in most cases. If still stuck, press Enter manually.

**`setup.sh` fails on venv creation?**
Needs Python 3.10+. On some systems: `sudo apt install python3.12-venv`.

**Plugin validation fails?**
Run `bash scripts/validate-plugin.sh` for diagnostics. Most common fix: re-run `setup.sh`.

## Known Limitations

- **Gemini auto-reconnect race:** `send.sh` can report `delivered` for a dying pane. The next message triggers reconnect.
- **Prompt injection surface:** The relay passes phone messages in bash variables via `send.sh`. Low risk (phone user is machine owner), but content is not sanitized.
- **No automated tests for prompt-based features:** Push attribution, auto-reconnect, and the health dashboard are behavioral instructions in the agent prompt, not executable code.

## License

[MIT](LICENSE)
