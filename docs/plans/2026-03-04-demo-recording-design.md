# URC Demo Recording — Shot List & Setup Guide

**Date:** 2026-03-04
**Format:** QuickTime screen recording with iPhone screen mirroring overlaid on CLI
**Output:** .mov → GIF (via ffmpeg + gifski)
**Duration target:** 30-45 seconds of compelling footage (can trim)

---

## Concept: "One Prompt, Three AIs, Your Phone"

The user types ONE vague prompt in the Claude App:

> **"Work with Codex and Gemini to make URC better. Make no mistakes."**

Claude broadcasts sub-tasks to Gemini and Codex. The phone becomes a dashboard — tap between three separate conversations to watch each AI independently exploring and working. The demo shows the **flow**, not the finish. Agents actively working, communicating, progressing — all visible from your phone.

**What makes this compelling:**
- Minimal user effort (one vague prompt)
- Maximum agent autonomy (they figure it out themselves)
- The phone UX IS the demo (swiping between agent conversations)
- Meta/self-referential: the tool improves itself

---

## Pre-Recording Setup

### Step 1: Create a clean demo branch

```bash
cd ~/Documents/ClaudeAssistant/UniversalRemoteControl
git checkout -b demo-recording
```

Isolates any changes the agents make. Delete after recording.

### Step 2: Create a clean tmux session

```bash
tmux new-session -d -s URC-DEMO -x 200 -y 50
tmux rename-window -t URC-DEMO:0 "demo"
```

**Session name:** `URC-DEMO`
**Window name:** `demo`

### Step 3: Clean up the terminal for camera

In the `URC-DEMO` session:

```bash
# Clean prompt — remove any PS1 noise
export PS1="%~ $ "

# Clear scrollback
clear && printf '\e[3J'

# Set terminal font size large enough to read on phone recording
# (Do this in iTerm2/Terminal.app preferences — 16pt+ recommended)
```

### Step 4: Launch Claude Code with a clean console line

```bash
cd ~/Documents/ClaudeAssistant/UniversalRemoteControl
claude
```

**What stays active (good — these ARE the product):**
- URC's own `.claude/settings.json` hooks (dispatch-watch, turn-complete, session-start)
- URC's plugin hooks (`hooks/hooks.json` — turn-complete + plugin-setup)
- URC's MCP servers (urc-coordination, urc-teams) via `.mcp.json`
- The `/urc` skill

**The URC project dir is self-contained** — launching `claude` from inside it picks up only URC's own hooks + global settings. No ContextPilot, no watchdog, no extra flags.

### Step 5: Verify clean state

Inside Claude:

```
/urc
```

Should show "No un-bridged Codex/Gemini panes." If stale panes appear:

```bash
rm -f .urc/coordination.db .urc/coordination.db-shm .urc/coordination.db-wal
```

### Step 6: Set up iPhone screen mirroring

1. Connect iPhone and Mac to same Wi-Fi
2. On Mac: QuickTime Player → File → New Movie Recording
3. Click dropdown arrow → select iPhone as camera
4. Position the iPhone mirror window overlaying the terminal
5. Claude App open and visible on phone

### Step 7: Set up screen recording

1. QuickTime Player → File → New Screen Recording
2. Select "Record Selected Portion"
3. Draw selection covering: terminal + iPhone mirror overlay
4. **Enable DND on both Mac and iPhone** (no notification popups)
5. Don't start recording yet

---

## The Demo Script

### Pre-Roll: Launch bridges (Terminal — do this BEFORE hitting record)

```
/urc gemini
```

Wait for Gemini pane + relay bootstrap (~10 seconds).

```
/urc codex
```

Wait for Codex pane + relay bootstrap (~10 seconds).

**Verify on phone:** You should now see 3 conversations in the Claude App:
1. Main Claude session (coordinator)
2. Gemini relay conversation
3. Codex relay conversation

Arrange tmux panes so all three CLIs are visible. Relays can be small/tucked.

**Why pre-roll:** Bridge setup is boring on camera (waiting for boot). Start recording AFTER bridges are live. The demo opens with everything ready.

### START RECORDING HERE

---

### Shot 1: The Prompt (Phone — 5 seconds)

**Action:** In the Claude App, tap into the **main Claude conversation** and type:

```
Work with Codex and Gemini to make URC better. Make no mistakes.
```

Send it.

**On camera:** Phone shows you typing one simple prompt. That's it. Maximum trust, minimum instructions.

### Shot 2: Claude Orchestrates (Terminal + Phone — 10 seconds)

**What happens automatically:**
1. Claude reads the prompt, checks the fleet (`get_fleet_status`)
2. Claude dispatches a sub-task to the Gemini relay pane (e.g., "Review URC architecture and suggest improvements")
3. Claude dispatches a sub-task to the Codex relay pane (e.g., "Review URC code quality and fix the top issue")
4. Claude starts its own analysis

**On terminal:** You see Claude calling `dispatch_to_pane`, then the Gemini and Codex panes light up — they're working.

**On phone (main Claude conversation):** Claude's orchestration plan appears as a message turn — "I'll have Gemini review the architecture while Codex reviews code quality..."

### Shot 3: Swipe Between Agents (Phone — 15-20 seconds)

**This is the money shot.**

**Action:** Navigate between the three conversations on your phone:

1. **Tap into Gemini relay conversation** → See Gemini's analysis appearing live. Architecture observations, suggestions, findings scrolling in.

2. **Tap into Codex relay conversation** → See Codex reviewing code, maybe already implementing a fix. Different perspective, different focus.

3. **Tap back to main Claude** → See Claude synthesizing or coordinating next steps.

**The visual:** Three AI ecosystems (Anthropic, OpenAI, Google) all independently working on the same codebase, all visible from one app, all triggered by one vague prompt. The phone is the command center.

**You don't need to wait for completion.** The demo is the FLOW — agents picking up work, producing output, progressing. As soon as you've shown all three conversations active, that's the demo. Cut.

### Shot 4: (Optional — if something finishes fast)

If any agent produces a particularly clean result (a diff, a test passing, a clear suggestion), linger on it for 2-3 seconds. That's the closing shot.

---

## What Claude Should Do (Expected Behavior)

When Claude receives "Work with Codex and Gemini to make URC better. Make no mistakes," it should:

1. Call `get_fleet_status()` to see available panes
2. Identify the Gemini relay and Codex relay panes
3. Formulate sub-tasks tailored to each AI's strengths:
   - **Gemini** (known for large context): architecture review, documentation gaps, design analysis
   - **Codex** (known for focused coding): code quality, bug fixes, test coverage
4. Dispatch to each relay via `dispatch_to_pane`
5. Start its own coordination/synthesis work

**If Claude doesn't auto-dispatch** (asks for clarification instead), gently nudge:
"Yes, dispatch to both. Gemini on architecture review, Codex on code improvements. Go."

---

## Phone Navigation Guide

```
┌─ Claude App ──────────────────┐
│                               │
│  Conversations:               │
│  ┌─────────────────────────┐  │
│  │ 🟢 Claude (main)       │ ← Coordinator. Shows orchestration.
│  ├─────────────────────────┤  │
│  │ 🟢 Gemini relay        │ ← Shows Gemini's analysis live.
│  ├─────────────────────────┤  │
│  │ 🟢 Codex relay         │ ← Shows Codex's code work live.
│  └─────────────────────────┘  │
│                               │
│  Tap each to see that agent   │
│  working independently.       │
└───────────────────────────────┘
```

Demo camera sequence: Claude → Gemini → Codex → Claude (loop once, ~15-20s)

---

## Terminal Pane Layout

Ideal for camera (3 CLIs visible, relays tucked):

```
┌──────────────────────────┬──────────────────────────┐
│                          │                          │
│   Claude Code            │   Codex                  │
│   (coordinator)          │   (coding)               │
│                          │                          │
│                          ├──────────────────────────┤
│                          │   Gemini                 │
│                          │   (analyzing)            │
│                          │                          │
├──────────────────────────┴──────────────────────────┤
│  relay panes (small / can be below frame edge)      │
└─────────────────────────────────────────────────────┘
```

After `/urc gemini` and `/urc codex`, rearrange:
```bash
tmux select-layout -t URC-DEMO tiled
# Or manually: Ctrl-B + arrow keys to resize
```

---

## Recording Checklist

### Before hitting record:
- [ ] Clean tmux session `URC-DEMO`
- [ ] Claude Code launched from URC directory
- [ ] `/urc` shows clean fleet
- [ ] `/urc gemini` — bridge up, RC active on phone
- [ ] `/urc codex` — bridge up, RC active on phone
- [ ] 3 conversations visible in Claude App
- [ ] Panes arranged for camera
- [ ] Terminal font ≥ 16pt
- [ ] Demo branch checked out (`demo-recording`)
- [ ] DND on Mac + iPhone
- [ ] QuickTime screen recording area selected (terminal + iPhone mirror)

### During recording:
- [ ] Hit record
- [ ] Phone: type "Work with Codex and Gemini to make URC better. Make no mistakes."
- [ ] Terminal: watch Claude dispatch, agents light up
- [ ] Phone: swipe to Gemini conversation → show activity
- [ ] Phone: swipe to Codex conversation → show activity
- [ ] Phone: swipe back to Claude → show coordination
- [ ] Stop recording (~30-45 seconds total)

### After recording:
- [ ] Trim in QuickTime (Edit → Trim)
- [ ] Export as .mov
- [ ] Convert to GIF (see cheat sheet below)
- [ ] Delete demo branch: `git checkout main && git branch -D demo-recording`

---

## Fallback Plans

### If Claude doesn't auto-dispatch:
Nudge it: "Dispatch to both now. Gemini on architecture, Codex on code quality."

### If relay dispatch doesn't work:
Tap into each relay conversation on phone and type the prompt manually:
- Gemini relay: "Review URC architecture and suggest the top 3 improvements"
- Codex relay: "Review URC code quality and fix the most important issue"
This is still a great demo — you're controlling two AIs from your phone.

### If everything fails:
Single-agent fallback. Tap into Codex relay, type: "List all TODO comments in URC and categorize by priority." Fast, reliable, always works.

---

## GIF Conversion Cheat Sheet

```bash
# Install tools (one time)
brew install ffmpeg gifski

# High quality GIF (~3-5MB, good for README)
mkdir -p /tmp/demo-frames
ffmpeg -i demo.mov -vf "fps=10,scale=800:-1" -pix_fmt rgb24 /tmp/demo-frames/%04d.png
gifski -o demo.gif --fps 10 --width 800 /tmp/demo-frames/*.png

# Smaller GIF (~1-2MB, for social media)
mkdir -p /tmp/demo-frames-sm
ffmpeg -i demo.mov -vf "fps=8,scale=640:-1" -pix_fmt rgb24 /tmp/demo-frames-sm/%04d.png
gifski -o demo-small.gif --fps 8 --width 640 /tmp/demo-frames-sm/*.png

# Quick-and-dirty (ffmpeg only, no gifski)
ffmpeg -i demo.mov -vf "fps=10,scale=800:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" demo.gif

# If GIF > 5MB: reduce fps to 8, width to 640, or trim duration
```

---

## Dry Run Protocol

**Do a full dry run before the real recording.** Run through the entire demo script once without QuickTime. Verify:

1. Claude dispatches to both relays on the vague prompt
2. Gemini and Codex both activate and produce visible output
3. Phone conversations update with results
4. Total time from prompt to visible activity on all three: < 30 seconds

If the dry run exposes issues, fix them and run again. Only hit record when you're confident in the flow.
