---
name: rc-bridge
description: |
  Launch an RC bridge to make this Codex pane accessible from the Claude Code
  phone app. Spawns a relay via urc-spawn.sh and pairs it with this pane.
  Use when the user says "bridge to phone", "start RC", "remote control",
  or "/rc-bridge".
---

# /rc-bridge — Bridge this Codex pane to the phone

Launch a Haiku relay pane paired with this Codex pane, making it controllable from the Claude Code iOS app.

## Steps

### 1. Get own pane ID and register

Run: `echo $TMUX_PANE` → store as CODEX_PANE.

Call MCP tool:
```
mcp__urc-coordination__register_agent(pane_id=CODEX_PANE, cli="codex-cli", role="engineer", pid=0)
```

### 2. Launch bridge

Run shell command (takes ~15-20s — includes orphan detection, relay spawn, bootstrap, and /remote-control activation):
```
bash urc/core/urc-spawn.sh bridge CODEX $TMUX_PANE $TMUX_PANE
```

The output is JSON:
- `{"status":"ready","relay":"%NNN","target":"%NNN","cli":"CODEX","method":"new"}` — new relay spawned
- `{"status":"ready","relay":"%NNN","target":"%NNN","cli":"CODEX","method":"re-paired"}` — orphaned relay reused
- `{"status":"failed","error":"..."}` — spawn failed

### 3. Confirm to user

If status is `"ready"`, display:
```
RC Bridge launched!

  Relay:  RELAY_PANE (Haiku)
  Target: CODEX_PANE (Codex)
  Method: new / re-paired

This pane is now accessible from your
Claude Code phone app via the relay.
```

If status is `"failed"`, display the error message.
