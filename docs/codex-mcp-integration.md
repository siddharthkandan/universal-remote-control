# Codex MCP Server Integration

Application-level injection for Claude->Codex orchestration. Bypasses terminal/tmux entirely — messages go through structured JSON-RPC directly into Codex's application layer. No PTY, no TUI, no paste buffer.

## Configuration

Added to `.mcp.json` as `codex` MCP server. Requires `codex` CLI to be installed and on PATH.

## Usage

### One-shot task
```
mcp__codex__codex(prompt="analyze this code for security issues")
```

### Multi-turn conversation
```
result = mcp__codex__codex(prompt="initial question")
followup = mcp__codex__codex_reply(threadId=result.threadId, prompt="follow-up")
```

## Token Cost Warning

Each `codex` tool call spawns a FULL Codex agent session — new model turn with its own context. This is NOT a lightweight RPC. Prefer batching multiple questions into a single prompt over making many small calls.

## When to Use vs tmux Dispatch

| Use Case | Approach |
|----------|----------|
| Agent-to-agent orchestration (results matter, not visibility) | `codex mcp-server` |
| Phone relay (user watches Codex work) | tmux dispatch (existing) |
| Interactive monitoring (user sees live output) | tmux dispatch (existing) |
| One-shot analysis (no ongoing session needed) | `codex mcp-server` |

## Limitations

- Each call spawns a new Codex process (no persistent session unless using `codex_reply`)
- No tmux pane — no live visibility into execution
- Codex runs as child process of Claude's MCP host
