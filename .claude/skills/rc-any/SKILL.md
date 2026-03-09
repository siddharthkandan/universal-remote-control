---
name: urc
description: Bridge any Codex or Gemini pane to the Claude Code phone app — auto-detects CLI type
argument-hint: "[pane_id | codex | gemini]"
allowed-tools: Bash(*)
---

# /urc

Run this ONE command. Display the JSON result. Done.

```bash
bash "${CLAUDE_PLUGIN_ROOT:-.}/urc/core/urc-dispatch.sh" "$ARGUMENTS" "$TMUX_PANE"
```

If status is "delegated": say "RC Bridge will be viewable in the Claude app when ready."
If status is "error": display the error message.
If no argument was given: it lists available panes — display that list.
