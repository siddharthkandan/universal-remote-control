# Turn-Completion Hook System

How URC detects when an AI CLI agent finishes a turn.

## What It Does

`urc/core/turn-complete-hook.sh` is a universal hook script (~25 lines)
that runs after every agent turn. It performs three actions:

1. **Touch signal file** — `touch .urc/turn_signal`
   Consumers detect the mtime change to know a turn just finished.

2. **Append audit line** — appends `<epoch> <pane_id> turn_complete` to
   `.urc/events.log` for debugging.

3. **Output JSON** — prints `{"continue": true}` to satisfy Gemini's hook
   requirement. Codex ignores stdout.

### Pane ID Detection

The hook resolves the pane ID using this fallback chain:

```bash
PANE="${TMUX_PANE:-${URC_PANE_ID:-unknown}}"
```

- `$TMUX_PANE` — set automatically by tmux
- `$URC_PANE_ID` — set explicitly at pane launch
- `"unknown"` — fallback

## CLI Wiring

### Claude — Stop hook

Claude Code's hook system fires `turn-complete-hook.sh` via a Stop hook
configured in `.claude/hooks/`. Claude can also call `report_event()` MCP
tool directly for structured event reporting.

### Codex — `notify` config

Configured in `.codex/config.toml`:

```toml
notify = ["bash", "urc/core/turn-complete-hook.sh"]
```

Codex fires this on the `agent-turn-complete` event.

### Gemini — `AfterAgent` hook

Configured in `.gemini/settings.json` using the nested structure:

```json
{
  "hooks": {
    "AfterAgent": [{
      "matcher": "*",
      "hooks": [{
        "name": "turn-signal",
        "type": "command",
        "command": "bash /absolute/path/to/turn-complete-hook.sh"
      }]
    }]
  }
}
```

Gemini reads settings at startup — restart after config changes. Use an
absolute path with explicit `bash` prefix.

## `wait_for_turn_complete` MCP Tool (Deprecated)

The coordination server exposes `wait_for_turn_complete`, which polls
`events.log` for new `turn_complete` entries.

**Deprecated:** This tool blocked the MCP event loop and caused STDIO
connection failures (`-32000: Connection closed`). The RC Bridge now uses
filesystem signal polling instead: Bash polls `.urc/signals/done_PANE`
at 2-second intervals with a 120-second timeout. The MCP tool remains
available for backward compatibility but should not be used.

## Troubleshooting

1. **Hook not firing** — check `chmod +x` on the hook script, verify CLI
   config (Codex: `notify` in config.toml, Gemini: `AfterAgent` in settings.json)
2. **Test manually** — `bash urc/core/turn-complete-hook.sh` should
   touch the signal file and append to events.log
3. **Check events.log** — `tail -5 .urc/events.log` for
   `turn_complete` entries

## Key Files

| File | Role |
|------|------|
| `urc/core/turn-complete-hook.sh` | Universal hook script |
| `urc/core/coordination_server.py` | `wait_for_turn_complete` MCP tool (deprecated) |
| `.codex/config.toml` | Codex `notify` configuration |
| `.gemini/settings.json` | Gemini `AfterAgent` hook configuration |
| `.urc/turn_signal` | Shared signal file (mtime-based) |
| `.urc/events.log` | Shared audit log |
