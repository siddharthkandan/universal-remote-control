---
name: urc
description: Bridge any Codex or Gemini pane to the Claude Code phone app — auto-detects CLI type
argument-hint: "[pane_id | codex | gemini]"
allowed-tools: Bash(*)
---

# /urc

A UserPromptSubmit hook has already run `urc-dispatch.sh` in the background. Check your context for the hook's JSON output.

**If context contains `"status":"delegated"`**: say "RC Bridge will be viewable in the Claude app when ready." Do NOT run any commands. Done.

**If context contains `"status":"error"`**: display the error message from the JSON. Done.

**If no hook output in context** (hook didn't fire — fallback only):
```bash
bash "${CLAUDE_PLUGIN_ROOT:-.}/urc/core/urc-dispatch.sh" "$ARGUMENTS" "$TMUX_PANE"
```
Display the result. If delegated, say "RC Bridge will be viewable in the Claude app when ready."
