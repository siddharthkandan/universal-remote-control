---
name: rc-bridge
description: |
  Launch an RC bridge to make this Codex pane accessible from the Claude Code
  phone app. Spawns a Claude Code Haiku relay pane, bootstraps it, and pairs
  it with this pane. Use when the user says "bridge to phone", "start RC",
  "remote control", or "/rc-bridge".
---

# /rc-bridge — Bridge this Codex pane to the Claude Code phone app

Launch a Haiku relay pane paired with this Codex pane, making it controllable from the Claude Code iOS app.

## Steps

### 1. Get own pane ID

Run shell command:
```
echo $TMUX_PANE
```
Store the output as CODEX_PANE (e.g. `%856`).

### 2. Register in coordination DB

Call MCP tools:
```
mcp__urc-coordination__register_agent(pane_id=CODEX_PANE, cli="codex-cli", role="engineer", pid=0)
mcp__urc-coordination__heartbeat(pane_id=CODEX_PANE, context_pct=0)
```

### 3. Spawn Claude Code relay pane

Run shell command:
```
tmux split-window -v -d -P -F '#{pane_id}' -t $TMUX_PANE "cd $(pwd) && source .venv/bin/activate && claude --agent rc-bridge --model haiku --dangerously-skip-permissions"
```
Store the output as RELAY_PANE (e.g. `%860`).

### 4. Wait for relay boot

Wait 8 seconds for Claude Code to initialize:
```
sleep 8
```

### 5. Bootstrap the relay

Extract CODEX_NUM = CODEX_PANE without the `%` prefix (e.g. `856`).

Send the bootstrap message:
```
bash urc/core/tmux-send-helper.sh RELAY_PANE "(CODEX_NUM) CODEX" --force
```

For example, if CODEX_PANE is `%856` and RELAY_PANE is `%860`:
```
bash urc/core/tmux-send-helper.sh %860 "(856) CODEX" --force
```

### 6. Confirm to user

Display:
```
RC Bridge launched!

  Relay:  RELAY_PANE (Haiku)
  Target: CODEX_PANE (Codex)

This pane is now accessible from your
Claude Code phone app via the relay.
```

The relay agent activates `/remote-control` itself as its last bootstrap step (background-scheduled, fires 3s after bootstrap turn ends). No need to send `/rc` externally.
