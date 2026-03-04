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

### 3. Check for orphaned relay (before spawning a new one)

An orphaned relay is a Haiku bridge pane whose original target died. Instead of spawning a new relay, re-pair the orphan with this Codex pane.

Call MCP tool:
```
mcp__urc-coordination__get_fleet_status()
```

Scan the results for agents where `role` is `"bridge"` AND `label` contains `"CODEX"` (case-insensitive).

For each candidate relay pane (CANDIDATE_PANE):

1. Check if its target is dead by running shell command:
   ```
   tmux display-message -t $(tmux show-options -pv -t CANDIDATE_PANE @bridge_target) -p '#{pane_id}' 2>&1
   ```
   If this command fails (returns error / non-zero exit), the target is dead — this relay is orphaned.

2. If orphaned relay found, re-pair it:
   - Extract CODEX_NUM = CODEX_PANE without the `%` prefix (e.g. `856`)
   - Update tmux pane options to re-pair:
     ```
     tmux set-option -p -t CANDIDATE_PANE @bridge_target CODEX_PANE
     tmux set-option -p -t CODEX_PANE @bridge_relay CANDIDATE_PANE
     ```
   - Update the relay's label in the coordination DB:
     ```
     mcp__urc-coordination__rename_agent(pane_id=CANDIDATE_PANE, label="(CODEX_NUM) CODEX")
     ```
   - Wake the relay with a refresh signal:
     ```
     bash urc/core/tmux-send-helper.sh CANDIDATE_PANE "__urc_refresh__" --force
     ```
   - Store CANDIDATE_PANE as RELAY_PANE
   - Display:
     ```
     RC Bridge re-paired!

       Relay:  RELAY_PANE (Haiku, re-used)
       Target: CODEX_PANE (Codex)

     Existing orphaned relay was reconnected
     to this pane. No new relay spawned.
     ```
   - **STOP here** — skip steps 4, 5, and 6.

3. If no orphaned relay found, continue to step 4.

### 4. Spawn Claude Code relay pane

Run shell command:
```
tmux split-window -v -d -P -F '#{pane_id}' -t $TMUX_PANE "cd $(pwd) && source .venv/bin/activate && claude --agent rc-bridge --model haiku --dangerously-skip-permissions"
```
Store the output as RELAY_PANE (e.g. `%860`).

### 5. Wait for relay boot

Wait 8 seconds for Claude Code to initialize:
```
sleep 8
```

### 6. Bootstrap the relay

Extract CODEX_NUM = CODEX_PANE without the `%` prefix (e.g. `856`).

Send the bootstrap message:
```
bash urc/core/tmux-send-helper.sh RELAY_PANE "(CODEX_NUM) CODEX" --force
```

For example, if CODEX_PANE is `%856` and RELAY_PANE is `%860`:
```
bash urc/core/tmux-send-helper.sh %860 "(856) CODEX" --force
```

### 7. Confirm to user

Display:
```
RC Bridge launched!

  Relay:  RELAY_PANE (Haiku)
  Target: CODEX_PANE (Codex)

This pane is now accessible from your
Claude Code phone app via the relay.
```

The relay agent activates `/remote-control` itself as its last bootstrap step (background-scheduled, fires 3s after bootstrap turn ends). No need to send `/rc` externally.
