# Turn-Completion Hook System

How URC detects when an AI CLI agent finishes a turn.

## What It Does

`urc/core/hook.sh` is a universal hook script that runs after every agent
turn. It performs four actions in strict order (changing the order breaks
`wait.sh`):

1. **Write response file** — Atomically writes the assistant's response to
   `.urc/responses/{PANE}.json` via a temp file + `mv`. The JSON contains
   5 fields: `{pane, cli, epoch, response, len}`.

2. **Touch signal file** — `touch .urc/signals/done_{PANE}`
   Per-pane file so multiple dispatches don't interfere.

3. **tmux wait-for** — `tmux wait-for -S "urc_done_{PANE}"`
   Wakes the blocking `wait.sh` dispatcher immediately.

4. **Append JSONL audit** — Appends one JSON line to
   `.urc/streams/{PANE}.jsonl` (best-effort, same 5-field schema).

### Pane ID Detection

The hook resolves the pane ID with a validation guard:

```bash
PANE="${TMUX_PANE:-unknown}"
[[ "$PANE" == "unknown" || "$PANE" =~ ^%[0-9]+$ ]] || PANE="unknown"
```

- `$TMUX_PANE` — set automatically by tmux (always `%NNN` format)
- `"unknown"` — fallback if not inside tmux

### CLI Detection + Payload Parsing

The hook identifies the calling CLI and extracts the response:

- **Codex** — passes JSON as `$1` argument; field: `.["last-assistant-message"]`
- **Gemini** — passes JSON on stdin; detected by `has("prompt_response")`; field: `.prompt_response`
- **Claude** — passes JSON on stdin; field: `.last_assistant_message`

Critical: `$1` is checked before stdin. Codex's stdin is `/dev/null`, so
reading stdin without checking `$1` first would block forever.

### Response File Schema

```json
{
  "pane": "%42",
  "cli": "codex",
  "epoch": 1741363200,
  "response": "The assistant's full response text...",
  "len": 42
}
```

## CLI Wiring

### Claude — Stop hook

Claude Code's hook system fires `hook.sh` via a Stop hook
configured in `.claude/hooks/`.

### Codex — `notify` config

Configured in `.codex/config.toml`:

```toml
notify = ["bash", "urc/core/hook.sh"]
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
        "command": "bash /absolute/path/to/hook.sh"
      }]
    }]
  }
}
```

Gemini reads settings at startup — restart after config changes. Use an
absolute path with explicit `bash` prefix.

## Wait Mechanism

`urc/core/wait.sh` blocks until the target pane completes its turn:

1. Checks for a fresh response file (epoch >= dispatch timestamp)
2. Blocks on `tmux wait-for "urc_done_{PANE}"` — woken by the hook
3. A watchdog subprocess fires after the timeout, unblocking via the same
   `tmux wait-for` channel

Returns structured JSON:
- **Completed**: `{status: "completed", response: "...", cli: "...", latency_s: N}`
- **Timeout**: `{status: "timeout", captured: "..."}`

The full dispatch cycle is driven by `urc/core/dispatch-and-wait.sh`, which
wraps `send.sh` + `wait.sh` into an atomic lock + send + wait + read
operation.

## Troubleshooting

1. **Hook not firing** — check `chmod +x` on the hook script, verify CLI
   config (Codex: `notify` in config.toml, Gemini: `AfterAgent` in settings.json)
2. **Test manually** — `bash urc/core/hook.sh` should
   write to `.urc/responses/` and touch `.urc/signals/`
3. **Check audit stream** — `tail -5 .urc/streams/%NNN.jsonl` for
   per-pane turn records
4. **Stale response** — `wait.sh` compares response epoch against dispatch
   timestamp; stale responses are ignored and the signal file is cleared

## Key Files

| File | Role |
|------|------|
| `urc/core/hook.sh` | Universal turn-completion hook (3-CLI) |
| `urc/core/wait.sh` | Blocking wait with watchdog timeout |
| `urc/core/dispatch-and-wait.sh` | Atomic dispatch + wait + read composite |
| `urc/core/send.sh` | Text injection via bracketed paste |
| `.codex/config.toml` | Codex `notify` configuration |
| `.gemini/settings.json` | Gemini `AfterAgent` hook configuration |
| `.urc/responses/{PANE}.json` | Per-pane response file (5-field JSON) |
| `.urc/signals/done_{PANE}` | Per-pane signal file (mtime-based) |
| `.urc/streams/{PANE}.jsonl` | Per-pane JSONL audit stream |
