---
name: urc
description: Bridge any Codex or Gemini pane to the Claude Code phone app — auto-detects CLI type
argument-hint: "[pane_id | codex | gemini]"
allowed-tools: Bash(*), AskUserQuestion
---

# /urc — Bridge any CLI pane to the Claude Code phone app

Launch a Haiku relay pane paired with a Codex or Gemini CLI pane, making it visible and controllable from the Claude Code iOS app. Auto-detects CLI type for existing panes.

## Aliases

This skill can be invoked as: `/urc`, `/rc-bridge`, `/rc-relay`, `/rc-any`, `/rc-cli`, `/rc-universal`

## Arguments

`$ARGUMENTS` can be:
- A pane ID (e.g. `%875` or `875`) — auto-detects whether it's Codex or Gemini
- `codex` — spawn a new Codex pane and bridge it
- `gemini` — spawn a new Gemini pane and bridge it
- Empty — scan fleet for un-bridged Codex/Gemini panes and list them

## CLI Config Map

| CLI_TYPE | Launch Command | Register As | Bootstrap Token |
|----------|---------------|-------------|-----------------|
| CODEX | `codex --full-auto` | `codex-cli` | `CODEX` |
| GEMINI | `gemini --yolo` | `gemini-cli` | `GEMINI` |

## Steps

### 0. Preflight — tmux environment check

RC Bridge requires tmux to spawn and communicate with CLI panes. Run these checks before anything else:

**Check 1: Is tmux installed?**
```bash
command -v tmux &>/dev/null && echo "INSTALLED" || echo "MISSING"
```
If MISSING → use AskUserQuestion to tell the user:
- Question: "RC Bridge requires tmux (terminal multiplexer) to manage CLI panes. It's not currently installed. Install it now?"
- Option 1: "Install via Homebrew" (description: "Runs `brew install tmux` — requires Homebrew")
- Option 2: "I'll install it myself" (description: "Stop here — you'll install tmux and re-run /rc-bridge")
- If they choose Option 1 → run `brew install tmux`, verify it worked, continue
- If they choose Option 2 or anything else → display install instructions (`brew install tmux` on macOS, `apt install tmux` on Linux) and **stop**

**Check 2: Is there an active tmux server with a usable session?**
```bash
tmux has-session 2>/dev/null && echo "SESSION_EXISTS" || echo "NO_SESSION"
```
If NO_SESSION → use AskUserQuestion to tell the user:
- Question: "RC Bridge needs a tmux session to spawn CLI panes into. No tmux session is running. Create one now?"
- Option 1: "Create tmux session" (description: "Creates a detached `urc` session — your current terminal stays as-is")
- Option 2: "I'll set it up myself" (description: "Stop here — run `tmux new -s urc` and re-run /rc-bridge")
- If they choose Option 1 → run `tmux new-session -d -s urc -x 200 -y 50`, then continue
- If they choose Option 2 or anything else → **stop**

If both checks pass, proceed to Step 1.

### 1. Parse arguments and detect CLI type

First, resolve the URC root for portable paths:
```bash
URC_ROOT="${CLAUDE_PLUGIN_ROOT:-.}"
```

**If `$ARGUMENTS` is a pane ID** (contains digits, no alpha-only words like "codex"/"gemini"):
- Store it as TARGET_PANE (ensure it has `%` prefix)
- Verify the pane exists: run `tmux display-message -t TARGET_PANE -p '#{pane_id}'`
- If verification fails, tell the user the pane doesn't exist and stop
- **Auto-detect CLI type**: Call `get_fleet_status()` MCP tool, find the entry matching TARGET_PANE, read the `cli` field:
  - If `cli` contains "codex" → CLI_TYPE = CODEX
  - If `cli` contains "gemini" → CLI_TYPE = GEMINI
  - If not found in DB or `cli` is unrecognized → **Fallback**: run `tmux display-message -t TARGET_PANE -p '#{pane_current_command}'` and match:
    - Contains "codex" → CLI_TYPE = CODEX
    - Contains "gemini" → CLI_TYPE = GEMINI
    - Still unrecognized → tell user "Can't detect CLI type for pane TARGET_PANE. Pass 'codex' or 'gemini' as argument." and stop

**If `$ARGUMENTS` is "codex"** (case-insensitive):
- CLI_TYPE = CODEX, no existing pane — proceed to spawn (Step 2)

**If `$ARGUMENTS` is "gemini"** (case-insensitive):
- CLI_TYPE = GEMINI, no existing pane — proceed to spawn (Step 2)

**If `$ARGUMENTS` is empty**:
- Call `get_fleet_status()` MCP tool
- Find all panes where `cli` contains "codex" or "gemini" AND `role` is "engineer"
- For each, check if a bridge already exists: look for entries with `role: "bridge"` whose `label` contains that pane's number
- List un-bridged panes to the user, e.g.:
  ```
  Found un-bridged CLI panes:
    %875  codex   (engineer)
    %877  gemini  (engineer)

  Run /urc 875 to bridge a pane,
  or /urc codex to spawn a new one.
  ```
- If no un-bridged panes found, tell the user: `No un-bridged Codex/Gemini panes. Run /urc codex or /urc gemini to spawn one.`
- Stop here (do not proceed to further steps)

### 2. Spawn target pane (only if no existing pane ID was provided)

Skip this step if TARGET_PANE was already set from a pane ID argument.

Using the CLI Config Map above for the resolved CLI_TYPE:
- Determine the split target: if `$TMUX_PANE` is set (we're inside tmux), use `-t $TMUX_PANE`. Otherwise (orchestrating from outside tmux), use `-t urc` (the session created in Step 0).
- Run this Bash command to spawn a new pane:
  ```
  tmux split-window -h -d -P -F '#{pane_id}' -t SPLIT_TARGET
  ```
  Store the output as TARGET_PANE
- Wait 1 second, then send the CLI launch command via tmux-send-helper:
  ```
  bash "$URC_ROOT/urc/core/tmux-send-helper.sh" TARGET_PANE "LAUNCH_COMMAND" --force
  ```
  Where LAUNCH_COMMAND is `codex --full-auto` or `gemini --yolo` per the config map.
- Wait 5 seconds for the CLI to boot
- Register the pane in the coordination DB using MCP tools:
  ```
  register_agent(pane_id=TARGET_PANE, cli=REGISTER_AS, role="engineer", pid=0)
  heartbeat(pane_id=TARGET_PANE, context_pct=0)
  ```
  Where REGISTER_AS is `codex-cli` or `gemini-cli` per the config map.

### 3. Launch the Haiku relay pane

Run this Bash command to create the relay pane in the same window as the target pane:
```
tmux split-window -v -d -P -F '#{pane_id}' -t TARGET_PANE "cd $URC_ROOT && source .venv/bin/activate && claude --agent rc-bridge --model haiku --dangerously-skip-permissions"
```
Store the output as RELAY_PANE.

### 4. Wait for relay boot

Wait 8 seconds for the Haiku relay to boot (Claude Code initialization).

### 5. Bootstrap the relay

Send the bootstrap message to pair the relay with the target pane. Use TARGET_NUM = TARGET_PANE without the `%` prefix (e.g. if TARGET_PANE is `%875`, TARGET_NUM is `875`):
```
bash "$URC_ROOT/urc/core/tmux-send-helper.sh" RELAY_PANE "(TARGET_NUM) BOOTSTRAP_TOKEN" --force
```
Where BOOTSTRAP_TOKEN is `CODEX` or `GEMINI` per the config map.

### 6. Confirm

The bridge agent activates `/rc` itself as its last bootstrap step (background-scheduled, fires 3s after bootstrap turn ends). No need to send `/rc` externally.

Display to the user:
```
URC Bridge launched! (CLI_TYPE)

  Relay:  RELAY_PANE (Haiku)
  Target: TARGET_PANE (CLI_TYPE)

The relay pane is now visible in your
Claude Code app. Send messages from your
phone — they'll be forwarded to CLI_TYPE.
```
