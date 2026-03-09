# Code Review Guidelines

## Philosophy
This is a coordination system where multiple CLIs (Claude, Codex, Gemini) communicate through tmux panes, SQLite messaging, and file-based signals. Bugs here tend to be subtle: race conditions, ordering violations, silent data loss, and assumptions that hold in one CLI but not another.

Think like a distributed systems reviewer, not a style checker.

## What matters most
- Correctness at boundaries: bash-to-python, tmux-to-filesystem, cross-pane contracts
- Concurrency safety: signal ordering, file atomicity, message delivery guarantees
- Failure modes: what happens when a pane dies, a timeout fires, or a message is never read?
- Assumptions that are only documented in one place but relied on in many

## What doesn't matter
- Formatting, naming conventions, or style preferences
- Missing docstrings or type annotations
- Things our test suites already catch (147 assertions across 10 suites)
- Suggestions to add error handling "just in case" without a concrete failure scenario
