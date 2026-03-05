# URC Communication Architecture: Findings & Recommendations

**Date:** 2026-03-04 (final revision — post cross-CLI review)
**Status:** Decision proposal ready for approval
**Scope:** CLI-to-CLI communication + Haiku relay bridge
**Sources:** This session's 4 research agents + 4 experiment agents + 3 cross-CLI reviewers (%1000 Opus, %1001 Codex, %1002 Gemini) + parallel session synthesis + ContextPilot v1/v2 comparative analysis + Codex swarm investigation

---

## Part 1: What Hasn't Worked

### 1.1 tmux send-keys as the primary delivery mechanism

**The approach:** Inject text directly into another CLI's terminal via `tmux send-keys`, treating it as both the message delivery AND notification system.

**What went wrong:**
- TUI swallowing: Claude Code's TUI silently discards text sent while mid-turn rendering. `tmux-send-helper.sh` has retry logic (up to 4 retries, 2s apart), but delivery remains "uncertain" for ~10% of sends.
- Timing sensitivity: CLI-specific delays before pressing Enter (Claude: 0.3-2.0s adaptive, Codex: 0.1s, Gemini: 0.1s) are fragile heuristics.
- 1000-char message limit: tmux paste buffers silently truncate longer messages. The tool reports "delivered" even when content was lost.
- No confirmation channel: the sender has no reliable way to know the receiver actually processed the message.

**Evidence:** `tmux-send-helper.sh` source (15KB of workarounds), `investigation-relay-design.md` showing 5-8s overhead per relay cycle, `result-e2e-codex.md` showing double-send artifacts.

**Verdict:** tmux send-keys works for short wake nudges but fails as a primary data channel. Keep it for "wake up and check your inbox" messages, not for carrying payloads.

### 1.2 Signal file polling for turn completion

**The approach:** Target CLI's hook writes `touch .urc/signals/done_%PANE`. Relay polls the file in a bash loop at 2-second intervals.

**What went wrong:**
- 1-2s average detection latency (half the poll interval).
- Burns LLM API calls: each poll iteration in the Haiku relay costs a model turn. Over a 60-second Codex task, that's ~30 wasted Haiku turns.
- No data in the signal: the file only says "done," not what happened. Requires a separate `tmux capture-pane` call.
- Race conditions: signal file can be consumed before the push-refresh fires (turn-complete-hook.sh has a 3s sleep workaround).

**Evidence:** `investigation-optimal-protocol.md` latency analysis, `synthesis-relay-architecture-v2.md`.

**Verdict:** Polling is the anti-pattern we're trying to eliminate. Replace with push-based notification.

### 1.3 MCP tool-based wait (wait_for_turn_complete)

**The approach:** An MCP tool that blocks until the target pane completes its turn.

**What went wrong:** MCP uses STDIO transport. A blocking MCP tool starves the event loop, causing `-32000: Connection closed` errors. The tool was deprecated.

**Evidence:** `docs/turn-completion-system.md`, `docs/architecture-overview.md`.

**Verdict:** Cannot block inside MCP tools. Notification must happen outside the MCP event loop.

### 1.4 The ContextPilot v1/v2 watchdog daemon (1,638 LOC)

**The approach:** A persistent Python asyncio process monitoring all panes via heartbeat files, making coordination decisions, nudging stuck panes, respawning dead ones.

**What went wrong (for the URC open-source context):**
- Heavy dependency: requires a running daemon, which is fragile and adds setup complexity.
- The watchdog's decision tree is 400+ LOC of heuristics (nudge counts, stale thresholds, debouncing).
- Couples all coordination into one process — when the watchdog dies, everything stops.
- Not suitable for an open-source project where users download and run without managing background services.

**Evidence:** `Automating-CC/contextpilot/watchdog/unified_loop.py`, comparative analysis of ContextPilot v1/v2 vs URC.

**Verdict:** The watchdog solved real problems, but for URC we need the coordination to be distributed across hooks, not centralized in a daemon.

### 1.5 Assumption that Codex hooks run inside the sandbox

**The approach:** Multiple investigation sessions assumed Codex's `notify` hook couldn't access tmux because Codex runs tools in a seatbelt sandbox.

**What went wrong:** This was tested by running `tmux wait-for` from INSIDE Codex's agent tool execution (which IS sandboxed). But the `notify` hook is spawned by the Codex HOST process, outside the sandbox. This incorrect assumption led to weeks of designing around a non-existent constraint.

**Evidence:** `research-codex-hooks-deep.md` (reading `registry.rs` and `seatbelt_base_policy.sbpl`), `investigation-codex-notification.md` (the test that created the misconception).

**Verdict:** Codex notify hooks have FULL system access. This eliminates the need for file-based bridges, FIFOs, or any workaround for Codex notification.

### 1.6 CWD mismatch preventing hooks from loading

**The approach:** Configure CLI-specific hooks in project-scoped config files (`.codex/config.toml`, `.gemini/settings.json`) inside the URC directory.

**What went wrong:** Both Codex and Gemini were launched from the parent workspace (`~/Documents/ClaudeAssistant`), not from `UniversalRemoteControl/`. Both CLIs only load project-scoped config from CWD. Hooks were correctly configured but never loaded.

**Evidence:** `result-e2e-codex.md` (no signal files created), `result-e2e-gemini.md` (AfterAgent hook not firing despite correct config + trust).

**Verdict:** This is a P0 setup/onboarding bug. Must either launch CLIs from URC directory, propagate hooks to global config, or document the requirement clearly.

### 1.7 Named Pipes (FIFOs) — Rejected 3 times across ContextPilot v1

**The approach:** Use FIFOs for cross-CLI IPC. Tried three ways: CLI stdin replacement (TUI CLIs crash without a real TTY), message queue (no persistence, data lost on reader crash, single reader), tmux pipe-pane -I (unproven with TUI CLIs).

**Evidence:** `Automating-CC/DESIGN/archive/research/ipc-messaging-patterns-research-2026-02-20.md` (scored 3/10 in comparison matrix), Architecture Decision Record DEC-IPC-001.

**Verdict:** FIFOs are wrong for this use case. No persistence, no inspection, single-reader constraint.

### 1.8 Maildir file queues — Over-engineered

**The approach:** Senders write JSON files to `ipc/queues/<peer>/new/`, delivery agent renames `new/ → cur/`, injects via tmux.

**What went wrong:** Still required polling the directory. Race conditions between concurrent writers. More complexity without solving the fundamental notification problem.

**Evidence:** `Automating-CC/DESIGN/archive/architecture-ipc-redesign.md`.

**Verdict:** Simpler approaches (signal files + tmux injection) proved sufficient.

### 1.9 Content stability as turn completion — False positives

**The approach:** Two identical `tmux capture-pane` outputs N seconds apart = pane is done.

**What went wrong:** During processing, gaps between tool calls can appear stable for 3-5 seconds, causing false positives.

**Evidence:** ContextPilot v1 archive, commit `11fbb4d`.

**Verdict:** Demoted to boot-only detection (initial pane startup). Not used for turn completion.

### 1.10 `❯` prompt detection for idle — Unreliable

**The approach:** Poll `tmux capture-pane` for `❯` character to detect idle state.

**What went wrong:** Claude Code's TUI always shows `❯` in the prompt area, even during processing. It's permanent UI chrome, not an idle signal.

**Evidence:** ContextPilot v1 archive, commit `fa9cdc7`.

**Verdict:** Cannot use prompt characters for state detection.

---

## Part 2: What Has Shown Evidence of Working

### 2.1 tmux wait-for as an instant notification primitive

**What it is:** `tmux wait-for CHANNEL` blocks until `tmux wait-for -S CHANNEL` signals it. Zero CPU while waiting. Sub-millisecond delivery.

**Experimental evidence (result-waitfor-jsonl.md):**
- Direct signal latency: ~10ms overhead (consistent across 5 runs)
- Hybrid file→waitfor bridge: 25-80ms (bounded by poll interval of file watcher)
- Blocking accuracy: <15ms jitter for a 1-second delay

**Confirmed behaviors:**
- `tmux wait-for -S` broadcasts to ALL waiters on that channel (confirmed from tmux source `cmd-wait-for.c`)
- The `woken` flag means: if signaled before a waiter registers, the next wait returns immediately (race-safe)
- Works from: Claude Code hooks ✓, Codex notify hooks ✓ (outside sandbox), Gemini hooks ✓

**Verdict:** This is the primary notification primitive. Replace all polling with `tmux wait-for`.

### 2.2 JSONL append as a durable event log

**What it is:** Each CLI appends one JSON line per event to a per-pane `.urc/streams/{pane}.jsonl` file.

**Experimental evidence (result-waitfor-jsonl.md):**
- 4 concurrent writers × 50 lines: 200/200 valid JSON, 0 corruption
- 8 concurrent writers × 100 lines: 800/800 valid, 0 corruption
- Long payloads (~500 chars): 200/200 valid, 0 corruption
- POSIX `O_APPEND` guarantees atomicity for writes under PIPE_BUF (4KB on macOS)

**Verdict:** Safe for concurrent multi-agent writes without locking. Use `echo >> file` pattern only (single write syscall).

### 2.3 The relay-wait.sh prototype

**What it is:** A script that polls a JSONL event stream at 1-second intervals, detecting turn_start, tool_call, and turn_end events.

**Experimental evidence (result-e2e-codex.md):**
- Detection latency: ~1 second (bounded by sleep interval)
- Correctly displayed progress: "[Started processing]" → "[Using: read_file]" → "[Completed: calculation done]"
- `tmux capture-pane` worked correctly for final output capture

**Verdict:** Functional prototype. Can be improved with `tmux wait-for` to eliminate the 1s poll delay.

### 2.4 tmux-send-helper.sh for message delivery

**What it is:** An 8-step dispatch pipeline for injecting text into CLI panes (resolve → idle check → CLI detection → send → settle → Enter → verify).

**Experimental evidence (result-e2e-codex.md, result-e2e-gemini.md):**
- Codex: delivered and processed correctly ("2+2 = 4")
- Gemini: delivered and processed correctly ("3+3 = 6")
- Buffer-paste mode for Gemini bypasses the `!` shell-mode bug

**Known issues:** `?` character stripped by Gemini's keyboard shortcut handler. Double-send artifact on Codex (message appears twice).

**Verdict:** Keep for initial message injection. Not needed for notification/signaling (use tmux wait-for instead).

### 2.5 Claude Code's Agent Teams filesystem inbox pattern

**What it is:** JSON files at `~/.claude/teams/{team}/inboxes/{agent}.json` with file locking. Team lead polls at 1000ms, teammates at 500ms.

**Evidence source:** Deobfuscated Claude Code source (cli.js v2.1.68), verified from `research-claude-hooks-deep.md`.

**Key insight:** The "magic" of Agent Teams isn't the transport (it's just file polling). It's the runtime integration — messages become conversation turns via `<teammate-message>` XML injection. The transport is the simplest possible approach.

**Verdict:** Validates that file-based IPC is sufficient. But we can do better than 500-1000ms polling with `tmux wait-for`.

---

## Part 3: Established Truths (With Evidence Sources)

### Truth 1: Every CLI's hooks run unsandboxed and can access tmux — CONFIRMED FOR ALL 3

| CLI | Hook | Runs Outside Sandbox | Can Call tmux | Evidence | Confidence |
|---|---|---|---|---|---|
| Claude Code | All hooks | ✓ | ✓ | `research-claude-hooks-deep.md` | **Confirmed** (empirical) |
| Codex CLI | `notify` | ✓ (host process child) | ✓ | **Empirical test 2026-03-04** (see below) | **Confirmed** (empirical) |
| Gemini CLI | All hooks | ✓ (not sandboxed) | ✓ | `result-e2e-gemini.md` (Test B: exit_code=0) | **Confirmed** (empirical) |

**Codex tmux access — EMPIRICALLY VERIFIED 2026-03-04:**

Codex v0.107.0 launched from the URC directory (pane %1008). Custom test hook replaced the notify script. Codex answered "What is 1+1?" → hook fired → results:

```json
{
  "tmux_pane": "%1008",
  "tmux_list_exit": 0,
  "tmux_list_output_chars": 274,
  "tmux_waitfor_exit": 0,
  "tmux_display_exit": 0,
  "env_tmux": "/private/tmp/tmux-501/default,34461,164",
  "verdict": "PASS"
}
```

All tmux operations succeeded: `tmux list-panes` (exit 0), `tmux wait-for -S` (exit 0), `tmux display-message` (exit 0). The `$TMUX_PANE` and `$TMUX` environment variables were both inherited from the Codex host process. Signal file `done_%1008` was created correctly.

**Result file:** `.urc/test-results/codex-tmux-access.json`

**Implication:** All three CLIs can fire `tmux wait-for -S` from their hooks. No bridge process needed. No fallback required for Codex notification. This was the #1 open question flagged by all three cross-CLI reviewers — now closed.

### Truth 2: Hook event coverage varies dramatically

| Event | Claude (20 hooks) | Codex (2 hooks) | Gemini (11 hooks) |
|---|---|---|---|
| Turn start | ✗ | ✗ | ✓ (BeforeAgent) |
| Turn end | ✓ (Stop, Notification) | ✓ (notify/AfterAgent) | ✓ (AfterAgent) |
| Per-tool call | ✓ (Pre/PostToolUse) | In code, not wired | ✓ (Before/AfterTool) |
| Context injection | ✓ (additionalContext) | ✗ (fire-and-forget) | ✓ (additionalContext) |
| Can block/abort | ✓ | ✗ | ✓ |
| Session lifecycle | ✓ (SessionStart/End) | ✗ | ✓ (SessionStart/End) |
| HTTP webhook | ✓ (type: "http") | ✗ | ✗ |

**Evidence:** `research-claude-hooks-deep.md`, `research-codex-hooks-deep.md`, `research-gemini-hooks-deep.md`.

**Implication:** Claude and Gemini are near-parity for event-driven coordination. Codex is limited to turn-complete notification only (per-tool events exist in Rust code but not yet configurable via Issue #2109).

### Truth 3: Codex's `notify` payload includes the assistant's response

```json
{
    "type": "agent-turn-complete",
    "thread-id": "...",
    "turn-id": "...",
    "last-assistant-message": "The full response text from Codex",
    "input-messages": ["What the user asked"]
}
```

**Evidence:** `research-codex-hooks-deep.md` (user_notification.rs serialization tests with stable wire format).

**Implication:** The relay doesn't need `tmux capture-pane` to get Codex's response — it's in the hook payload. This eliminates terminal scraping for Codex.

### Truth 4: Gemini has native context injection via BeforeAgent

Gemini's `BeforeAgent` hook can return `{"additionalContext": "text"}` which is appended directly to the user's prompt before the model sees it. This is functionally equivalent to Claude Code's `additionalContextForAssistant`.

**Evidence:** `research-gemini-hooks-deep.md` (source: `packages/core/src/hooks/types.ts`).

**Implication:** Both Claude and Gemini can be told about cross-CLI events by injecting text into their LLM context. Only Codex lacks this (fire-and-forget hooks).

### Truth 5: Claude Code's Bash tool does NOT stream output

Foreground Bash commands return all output as a single block when the process exits. `tail -f` in a foreground Bash call shows nothing until timeout kills it.

**Workaround:** Background Bash (`run_in_background: true`) writes to an output file incrementally. A foreground `cat` of that file gets partial results.

**Evidence:** `result-tail-streaming.md` (5 test variants, all confirmed buffered-until-exit).

**Implication:** The relay cannot do a single streaming `tail -f` command. Must either poll the stream file or use the background+poll pattern.

### Truth 6: tmux wait-for signals are NOT lost if fired before a waiter

From tmux source code analysis (`cmd-wait-for.c`): the `woken` flag means if `tmux wait-for -S CHANNEL` fires and no waiter is registered, the channel is marked as "woken." The next `tmux wait-for CHANNEL` returns immediately.

**Evidence:** `result-waitfor-jsonl.md` (pre-signal test: returned in ~23ms = measurement overhead), `research-push-notification-patterns.md`.

**Implication:** The signal-before-wait race condition is handled by tmux natively. A simple check-file-then-wait pattern is sufficient.

### Truth 7: Claude Code has 20 hook events including TeammateIdle and Notification

Previously thought to have 9. The complete list includes `TeammateIdle` (can block idle with exit code 2), `TaskCompleted` (can block completion), `Notification` (fires on `idle_prompt` — the exact "pane finished" signal), `PermissionRequest` (auto-approve), HTTP hooks (`type: "http"` for webhook push), and more.

**Evidence:** `research-claude-hooks-deep.md` (deobfuscated from cli.js v2.1.68).

### Truth 8: Gemini CLI has 11 hook events including BeforeTool/AfterTool

Gemini has the richest hook taxonomy: `BeforeAgent`, `AfterAgent`, `BeforeTool`, `AfterTool`, `BeforeModel`, `AfterModel`, `BeforeToolSelection`, `SessionStart`, `SessionEnd`, `PreCompress`, `Notification`. AfterTool supports `tailToolCallRequest` to chain additional tool calls programmatically.

**Evidence:** `research-gemini-hooks-deep.md` (source: `packages/core/src/hooks/types.ts` at google-gemini/gemini-cli).

### Truth 9: ALL three CLIs provide response content in turn-completion hooks

This is the single most important finding from the parallel session. Every CLI's turn-completion hook receives the full assistant response:

| CLI | Hook | Field | Delivery |
|---|---|---|---|
| Claude Code | `Stop` | `last_assistant_message` | JSON on stdin |
| Codex | `notify` | `last-assistant-message` | JSON as `$1` CLI argument |
| Gemini | `AfterAgent` | `prompt_response` | JSON on stdin |

**Implication:** The hook can write the response to `.urc/responses/{PANE}.json`. No process EVER needs `tmux capture-pane` or `read_pane_output` for the response. The relay reads a local file. This eliminates terminal scraping entirely.

**Caveat for Codex:** Response is passed as CLI argument (`$1`), subject to macOS `ARG_MAX`. Measured on this machine: `getconf ARG_MAX` = 1,048,576 bytes (1MB). This is total argument space, not per-argument. Typical responses are well under this limit. For edge cases (very long code output), the hook should check `${#1}` and fall back to `tmux capture-pane` if the payload appears truncated or absent.

**Evidence:** `research-codex-hooks-deep.md` (`user_notification.rs` stable wire format), `research-gemini-hooks-deep.md` (`AfterAgentInput.prompt_response`), `research-claude-hooks-deep.md` (Stop hook `last_assistant_message`).

### Truth 10: kqueue provides zero-polling filesystem watching (0.1ms) — BUT DROPPED FROM DESIGN

Python's built-in `select.kqueue` module (macOS) can watch a directory for file changes with **0.1ms latency** — 47x faster than `tmux wait-for` (4.7ms). Zero external dependencies.

**However, the cross-CLI review unanimously recommended dropping kqueue:**
- Gemini (%1002): "Drop kqueue entirely. It adds OS-coupling and Python dependency for no human-perceptible gain. 0.1ms vs 4.7ms is irrelevant in the context of LLM operations that take 2,000+ ms."
- Codex (%1001): "kqueue latency focus is over-optimized. Correctness matters more than micro-latency."
- Opus (%1000): Acknowledged tmux wait-for alone is sufficient.

**Revised position:** tmux wait-for is the SOLE notification primitive. Signal files serve as the durable pre-check (check file first, then block on wait-for). This is OS-agnostic, has zero Python dependencies, and relies entirely on tmux — which is already a hard requirement for URC.

**Evidence:** Parallel session benchmarks + cross-CLI reviewer consensus.

### Truth 11: `anyio.to_thread.run_sync()` keeps the MCP SERVER alive — but MCP CLIENT timeout is the real risk

The previous `wait_for_turn_complete` MCP tool was deprecated because `time.sleep()` blocked the anyio event loop, killing the STDIO connection. `anyio.to_thread.run_sync()` runs blocking operations in a thread pool while the event loop stays alive. This fixes the SERVER-side problem.

**However, the cross-CLI review identified a critical CLIENT-side risk:**
- Gemini (%1002): "Claude Code and other MCP clients often have hardcoded timeouts for tool execution (e.g., 60 seconds). If dispatch_and_wait blocks for 120s, the Claude Code client will likely throw a timeout error, crashing the agent's turn."
- Opus (%1000): "I recommend MCP over Bash, BUT test the MCP client timeout first with a simple sleep-based tool to verify 120s blocking doesn't kill the connection."

**Revised position:** The SERVER-side blocking is solved by anyio. But the CLIENT-side timeout is unverified and could be a showstopper. The safe approach: build `dispatch_and_wait` as a **Bash script** that returns JSON. The relay calls `bash dispatch-and-wait.sh %TARGET "message" 120`. Zero MCP timeout risk. If empirical testing later confirms MCP clients tolerate long-blocking calls, we can promote it to an MCP tool.

**Evidence:** anyio documentation + dispatch_and_wait evaluation (`eval-dispatch-and-wait.md`) + cross-CLI reviewer flags.

### Truth 12 (NEW — from cross-CLI review): Request/turn correlation is non-negotiable

All three reviewers independently flagged the same gap: `done_%PANE` + `responses/%PANE.json` can return the WRONG turn if concurrent sends or manual user input happen.

**The problem:** Dispatcher clears signal, sends message, waits. Meanwhile, the user types something in the target pane manually. That manual input completes first, writing a response and signaling done. The dispatcher reads the response from the MANUAL turn, not the dispatched message.

**The Phase 0 solution:** Timestamp-based correlation:
- `dispatch_timestamp`: epoch seconds recorded by dispatcher BEFORE sending
- `timestamp`: epoch seconds written by the hook into the response file

The dispatcher validates `response.timestamp > dispatch_timestamp`. If stale, waits for the next signal.

**Honest limitation of timestamp-only:** Timestamp correlation catches the common case (stale response from a prior turn). It does NOT catch the case where a user manually types something in the target pane AFTER the dispatch, and that manual turn also completes with a newer timestamp. In that scenario, the dispatcher returns the manual turn's response, not the dispatched message's response. This is acceptable for Phase 0 because: (a) the relay use case has one relay per target with no manual interaction, (b) the `flock` in dispatch-and-wait.sh prevents concurrent automated dispatchers. For Phase 2, if multi-dispatcher or mixed manual/automated scenarios arise, stronger correlation (e.g., monotonic `seq` counter per pane, or embedding a correlation token in a sidecar file rather than the message itself) can be added.

**Evidence:** All three cross-CLI reviewers flagged this independently. Codex specifically noted "recency is not identity" — timestamp proves recency but not that the response matches the request.

### Truth 13: Codex has upcoming lifecycle hooks PRs

PR #13498 (draft) adds SessionStart, SessionStop, Turn boundaries, Compaction, and Subagent transitions to Codex. Explicitly aligns with "Claude-style naming and payloads." PR #13276 and #13408 also expand hook coverage.

**Implication:** Codex's hook gap is closing. Design for richer hooks now — they'll be available soon.

**Evidence:** `research-codex-hooks-deep.md` (GitHub PR search).

---

## Part 4: Recommendations

### Assessment: Do we have enough to proceed?

**Yes.** The exploration phase has answered every critical question:

1. **Can every CLI push notifications?** Yes — all hooks run unsandboxed with tmux access.
2. **What's the fastest viable notification primitive?** tmux wait-for at ~5ms.
3. **Is JSONL safe for concurrent writes?** Yes — zero corruption across all trials.
4. **Can we avoid terminal scraping?** Yes — all three CLIs provide response text in hook payloads.
5. **Can MCP tools safely block?** Yes — `anyio.to_thread.run_sync()` keeps the event loop alive.
6. **What hook events are available per CLI?** Fully mapped (Claude: 20, Codex: 2 today + more coming, Gemini: 11).

No further exploration needed. We should proceed to design.

### Ask 1: CLI-to-CLI Communication

**Recommended approach: Enhanced hooks + composite MCP tools + 4-layer notification stack**

#### The Architecture (4 layers)

**Layer 1 — Enhanced Turn-Completion Hook** (~60 LOC, all CLIs)

The existing `turn-complete-hook.sh` gains three capabilities:

A. **Response content capture:** Parse the hook payload (stdin JSON for Claude/Gemini, `$1` arg for Codex) and write the full response to `.urc/responses/{PANE}.json`. No CLI ever needs to scrape a terminal buffer again.

B. **Dual-channel signal:** After the signal file (`signals/done_{PANE}`), fire `tmux wait-for -S "urc_done_{PANE}"` for instant notification. Also append a `turn_end` event to the JSONL stream (`.urc/streams/{PANE}.jsonl`) for durability and observability.

~~C. Inbox reconciliation~~ **REMOVED per Correction 2 below.** Inbox notification is handled by SEPARATE per-CLI hooks (Claude: PostToolUse piggyback, Gemini: BeforeAgent hook, Codex: MCP middleware), NOT by the turn-complete hook. The turn-complete hook stays focused on response capture + signaling only.

**Layer 2 — tmux wait-for Waiter** (~15 LOC, Bash)

Simple, OS-agnostic notification primitive:
1. Pre-check: does `signals/done_{PANE}` exist? If yes, return immediately.
2. Block: `tmux wait-for "urc_done_{PANE}"` — instant wake (~5ms) when hook signals, zero CPU while waiting.
3. Timeout: background process does `sleep $TIMEOUT && touch .urc/timeout/{PANE} && tmux wait-for -S "urc_done_{PANE}"`. After wait-for returns, check: if signal file exists = real completion; if timeout sentinel exists = timeout. This distinguishes genuine completion from synthetic timeout.

No kqueue. No Python. No OS-coupling. tmux is already a hard requirement. The 5ms latency is irrelevant vs. multi-second model turns.

**Why kqueue was dropped:** Cross-CLI review unanimously recommended it. Adds OS-coupling (macOS-only), Python dependency, and complexity for a 4.6ms improvement that no human or model will ever perceive.

**Layer 3 — Inbox Notification (4-layer stack, ~50 LOC)**

Port the proven pattern from ContextPilot v1:
1. **Spawn-time instructions:** Agent prompts say "check inbox after each task."
2. **MCP middleware hints:** `_with_inbox_hint()` expanded to all frequently-called tools (dispatch, read, fleet_status, heartbeat).
3. **PostToolUse piggyback** (Claude-only): `inbox-piggyback.sh` — O(1) stat on signal file → if present, query SQLite → inject `additionalContextForAssistant`. Fires every tool call.
4. **tmux wake pulse:** `tmux-send-helper.sh --force` for idle panes.

**Layer 4 — Composite MCP Tools** (~150 LOC)

Three tools that wrap common multi-step operations into single deterministic calls:

`dispatch-and-wait.sh` (Bash script, not MCP tool) — The highest-value tool. Atomically: record dispatch_timestamp → clear signal → dispatch via tmux-send-helper → pre-check signal file → block on `tmux wait-for` with timeout → validate response.timestamp > dispatch_timestamp → read response from `.urc/responses/{PANE}.json` → fall back to `tmux capture-pane` if absent → return structured JSON on stdout. Replaces 3-5 model tool calls with 1. Bash-first avoids MCP client timeout risk entirely.

`relay_cycle` (MCP tool wrapping `dispatch-and-wait.sh`) — The relay's per-message composite. Reads `@bridge_target` from tmux pane options, calls dispatch-and-wait.sh via `subprocess.run()`, strips ANSI, returns clean response text. The relay agent calls ONE MCP tool per cycle.

**MCP timeout caveat:** `relay_cycle` delegates blocking to a Bash subprocess, so the MCP server's event loop stays alive. However, the MCP CLIENT (Claude Code) may have a hardcoded tool-call timeout. If the target CLI takes >60s to respond, the client may time out the `relay_cycle` call before `dispatch-and-wait.sh` returns. **Mitigation options:** (a) empirically test MCP client timeout tolerance during Phase 1 validation, (b) if timeout is hit, the relay agent falls back to calling `bash dispatch-and-wait.sh` directly via the Bash tool instead of the MCP wrapper, (c) for known-long tasks, the relay can pass a shorter timeout and retry. This is flagged as a Phase 1 gate check.

`send_with_notify(from_pane, to_pane, body)` (MCP tool) — Atomically: commit message to SQLite → touch inbox signal → fire wake pulse → fire tmux wait-for signal → record delivery attempt. Makes the entire notification stack a side effect of sending. One call instead of manual send + signal + pulse.

`bootstrap_validate()` (MCP tool, from Codex review) — First-run validation: verifies CWD is URC root, hooks are loadable, tmux socket is accessible, `.urc/` directories exist, MCP servers are running. Returns structured pass/fail with fix instructions. Eliminates the "hooks silently don't load" class of setup bugs.

`cancel_dispatch(pane_id)` (MCP tool, from Gemini review) — Emergency interrupt: sends SIGINT via tmux to target pane, clears any pending signal/response files, unblocks any waiting `tmux wait-for` channels. For when a dispatch is stuck or needs to be aborted.

#### Why composite tools, not just hooks + Bash

| Dimension | Model orchestrates primitives | Composite MCP tool |
|---|---|---|
| Tool calls per relay cycle | 4-5 | **1** |
| Tokens per cycle | 200-500 | **~50** |
| Error handling | Model must detect and recover | **Tool handles retries, fallbacks, timeouts** |
| Race conditions | Model must manage signal timing | **Tool handles atomically** |
| Format correctness | Model composes JSON/paths | **Guaranteed by code** |
| Reliability | Depends on prompt adherence | **Deterministic** |

The composite tools apply the same principle as `tmux-send-helper.sh` — wrap complexity in a deterministic tool so the model calls one thing and gets a guaranteed result.

#### Layered API

```
Level 0 — Primitives (shell scripts, filesystem, tmux)
Level 1 — Low-Level MCP Tools (existing 15 + 17 tools, unchanged)
Level 2 — Composite MCP Tools (dispatch_and_wait, send_with_notify, relay_forward)
Level 3 — Workflow Tools (future: coordinate_parallel, multi_pane_broadcast)
```

Models call the highest level appropriate. Lower levels remain for fine-grained control and debugging.

#### What stays / what changes

| Component | Verdict |
|---|---|
| `tmux-send-helper.sh` | **KEEP** — still the dispatch primitive |
| `observer.sh` | **KEEP** — pane resolution, state detection |
| `coordination_db.py` (SQLite) | **KEEP** — for messages, tasks, delivery tracking |
| `turn-complete-hook.sh` | **ENHANCE** — add response capture + dual signal (NO inbox reconciliation — separate hooks handle that) |
| Signal files (`.urc/signals/`) | **KEEP** — tmux wait-for pre-check reads these, durable record |
| `coordination_server.py` | **ENHANCE** — add `dispatch_and_wait`, `relay_forward`, `send_with_notify` |
| Polling loops | **REPLACE** — tmux wait-for (zero polling, ~5ms notification) |
| `read_pane_output` for responses | **REPLACE** — read from `.urc/responses/{PANE}.json` (hook-written) |
| JSONL streams | **ADD** — per-pane event log for observability + debugging |

### Ask 2: Haiku Relay Bridge for Claude App

**Recommended approach: One composite tool per cycle + response-from-hook**

#### The Relay Cycle (proposed)

```
Phone sends message → relay receives it
  ↓
relay_forward(my_pane, message)
  → internally: clear signal + dispatch (no-verify, ~0.3s)
  → internally: pre-check signal file + block on tmux wait-for (~5ms)
  → internally: read .urc/responses/{TARGET}.json (local file, <1ms)
  → returns: {"status":"completed", "response_text":"...", "latency_ms":1234}
  ↓
Relay displays response_text verbatim to phone
```

**One tool call. One model turn. Sub-second overhead (dominated by Haiku inference, not plumbing).**

#### Why this eliminates terminal scraping

The turn-completion hook on the TARGET CLI writes the full response to `.urc/responses/{PANE}.json` before signaling. The relay reads a local file — no `tmux capture-pane`, no MCP call to `read_pane_output`, no ANSI escape parsing, no buffer offset management.

If the response file is absent (hook didn't fire, timeout, etc.), the tool falls back to `tmux capture-pane`. This is the degradation path, not the happy path.

#### The Relay Agent Prompt (proposed)

```
You are a relay bridge. For each user message:
1. Call relay_forward(TARGET, message)
2. Display response_text verbatim
3. After 6 exchanges, /clear
Never add commentary. Never interpret. Just relay.
```

~10 lines. Haiku executes this deterministically. Zero orchestration, zero context drift, zero token waste on plumbing.

#### Mid-turn progress

Two approaches, pick based on desired complexity:

**Option A — No progress (simplest, recommended for v1):** The relay blocks on `relay_forward` until the target completes. Phone user sees "forwarded..." then the response. Total latency: dominated by target CLI's processing time + ~0.5s overhead.

**Option B — Progress via event stream (v2 enhancement):** The `dispatch_and_wait` tool internally reads the JSONL event stream during the wait for `tool_call` events (Claude and Gemini emit these). It includes a `progress` field in the return value. The relay displays intermediate status. Codex (turn-level only today) gives less granularity but will improve as AfterToolUse hooks are wired.

#### Latency comparison

| Step | Current | Proposed |
|---|---|---|
| Forward (dispatch) | 2-5s (MCP + verify) | **~0.3s** (no-verify) |
| Wait for completion | 500-2,000ms (polling) | **~5ms** (tmux wait-for) |
| Read response | 50-200ms (MCP + capture-pane) | **<1ms** (local file) |
| **Total overhead** | **5-8s** | **~0.5-1s** |

#### Making the relay truly stateless

- Target pane ID: stored in tmux pane options (`@bridge_target`), survives `/clear`
- Response content: on disk at `.urc/responses/`, not in relay context
- Event history: JSONL stream on disk, not in relay context
- Auto-clear: every 6 relays (but could be every relay — no information loss)

### Corrections From Tool Evaluation Agents

**Correction 1: Gemini `additionalContext` is BeforeAgent-only, not AfterAgent.**
The hook enhancement section originally stated inbox reconciliation could inject context via AfterAgent's `additionalContext`. This is WRONG. `additionalContext` is only supported on `BeforeAgent` output, not `AfterAgent`. For Gemini inbox notification, we need a SEPARATE `BeforeAgent` hook (not the turn-complete hook). This keeps the turn-complete hook simple and universal.

**Correction 2: Inbox reconciliation should NOT be in the turn-complete hook.**
The hook evaluation agent recommends keeping the turn-complete hook focused on response capture + signaling only. Each CLI needs a different inbox notification mechanism:
- Claude: PostToolUse piggyback hook (fires every tool call — most effective)
- Gemini: Separate BeforeAgent hook with `additionalContext` (fires on each new prompt)
- Codex: MCP middleware hints only (no context injection available)

Adding CLI-specific branching would complicate what should be a simple universal script.

**Correction 3: The relay's "forgotten read" is the #1 agent error.**
The tool landscape agent found that `dispatch-watch.sh` (an entire PostToolUse hook infrastructure) exists solely to catch agents forgetting to call `read_pane_output` after `dispatch_to_pane`. The `dispatch_and_wait` composite tool eliminates this bug class entirely.

**Correction 4: `relay_cycle` is a better name than `relay_forward` for the composite relay tool.**
The tool landscape agent identified that the relay pattern needs 7-9 tool calls today, not 3-5 as I estimated. The composite tool should be called `relay_cycle` and handle the COMPLETE per-message flow (clear → dispatch → wait → read → cleanup), not just the forward step. This reduces the relay from 8 model turns to 3 per phone message.

### Validated Technical Decisions

**`dispatch_and_wait` as MCP tool: CONFIRMED FEASIBLE.**
- FastMCP does NOT auto-offload sync functions to threads (this is why the old tool died)
- Using `async def` + `anyio.to_thread.run_sync(abandon_on_cancel=True)` keeps the event loop alive
- kqueue directory watching was confirmed working at 0.1ms but subsequently DROPPED from design (cross-platform concern — see Truth 10)
- Default thread pool has 40 tokens; only 1 call in flight per MCP server instance
- 68 LOC implementation sketch in `eval-dispatch-and-wait.md`

**Enhanced turn-complete hook: CONFIRMED FEASIBLE.**
- +58 LOC in the synchronous path (82 → ~140 LOC total)
- Latency increase: <10ms → 25-35ms (acceptable)
- Response file written atomically (temp + mv) with SHA-256 checksum
- Order: response file → signal file → tmux wait-for (guarantees data available when reader wakes)
- All three CLI payload formats handled: stdin JSON (Claude/Gemini), $1 arg JSON (Codex)
- ARG_MAX on this machine is 1MB (not 256KB as commonly cited)
- Self-testable with synthetic payloads via `--self-test` flag

**Token savings quantified:**
- Current relay: 7-9 tool calls per cycle (source: `eval-tool-landscape.md` traced the rc-bridge agent's actual call sequence: state recovery + clear signal + relay_forward + optional retry + poll loop + relay_read + display + delete signal + counter/auto-clear). ~1,400-3,700 tokens per cycle, ~20,000 tokens of system prompt re-read per message (173-line prompt × 8 turns × ~15 tokens/line).
- With `relay_cycle` composite: 3 model turns (state recovery + relay_cycle + display), ~50 tokens of tool orchestration, ~7,500 tokens of prompt re-read
- Savings: ~12,500 tokens per relay message (conservative — the 7-9 call count includes retry paths that don't always fire; baseline is more like 6-7 calls for the happy path). At 100 messages/day = **~1.25M tokens/day saved**.
- Relay agent prompt: currently 173 lines → ~50 lines total (core loop is ~10 lines, but bootstrap/reconnect/refresh/error handling adds ~40 lines)

### Updated Tool Priority and Estimates (Post Cross-CLI Review)

| Priority | Tool | Type | LOC | What It Eliminates |
|---|---|---|---|---|
| **P0** | Enhanced turn-complete hook | Shell | ~58 | Terminal scraping, `read_pane_output` for responses |
| **P0** | `dispatch-and-wait.sh` | Bash script | ~50 | dispatch-watch hook, forgotten-read bugs, poll loops |
| **P0** | `bootstrap_validate` | MCP tool | ~30 | CWD/hook-loading setup bugs (NEW from Codex review) |
| **P1** | `relay_cycle` | MCP tool | ~40 | 5-6 relay tool calls, prompt re-read (~15K tokens/msg) |
| **P1** | `send_with_notify` | MCP tool | ~40 | manual signal + wake + delivery tracking |
| **P1** | `inbox-piggyback.sh` (Claude) | Hook script | ~40 | missed messages between tool calls |
| **P2** | `cancel_dispatch` | MCP tool | ~25 | stuck dispatches, no abort mechanism (NEW from Gemini review) |
| **P2** | Gemini BeforeAgent inbox hook | Hook script | ~30 | missed messages at turn boundaries |
| **P2** | MCP middleware expansion | Python | ~20 | Codex/Gemini inbox blindness |
| **P3** | Relay agent prompt rewrite | Markdown | ~10 | 123 lines → ~50 lines of prompt |
| ~~P3~~ **P0** | JSONL event stream append | Shell | ~10 | Included in hook enhancement (Phase 0), not a separate task |

### Total Implementation Estimate (Post Cross-CLI Review)

| Component | LOC | Category | Phase |
|---|---|---|---|
| Enhanced turn-complete hook (response capture + dual signal) | ~58 | Primitives | P0 |
| `dispatch-and-wait.sh` (Bash, returns JSON) | ~50 | Composite script | P0 |
| `bootstrap_validate` MCP tool | ~30 | Setup/validation | P0 |
| `relay_cycle` MCP tool (wraps dispatch-and-wait.sh) | ~40 | Composite tool | P1 |
| `send_with_notify` MCP tool | ~40 | Composite tool | P1 |
| `inbox-piggyback.sh` (port from v1, Claude-only) | ~40 | Notification | P1 |
| `cancel_dispatch` MCP tool | ~25 | Safety | P2 |
| Gemini BeforeAgent inbox hook | ~30 | Notification | P2 |
| MCP middleware expansion (`_with_inbox_hint`) | ~20 | Notification | P2 |
| Inbox signal in `team_send`/`send_message` | ~10 | Notification | P2 |
| JSONL event stream append (in hook) | ~10 | Observability | P0 (included in hook enhancement) |
| Relay agent prompt rewrite | ~10 | Agent | P3 |
| **Total** | **~415 LOC** | | |

**Phase delivery:**
- P0 (~160 LOC): lib-cli.sh + hook + dispatch-and-wait + bootstrap. The foundation. Everything else depends on this.
- P1 (~130 LOC): Relay prompt + send_with_notify + inbox piggyback. Makes the relay sub-second and inbox-aware.
- P2 (~125 LOC): relay_cycle MCP (conditional), cancel_dispatch, Gemini inbox, middleware. Hardening and polish.
- P3 (~20 LOC): Observability, prompt cleanup. Nice-to-have.

### Evaluation Evidence Index

| Document | What It Contains |
|---|---|
| `.urc/eval-dispatch-and-wait.md` | MCP feasibility, kqueue implementation, anyio threading, edge cases, 68 LOC sketch |
| `.urc/eval-tool-landscape.md` | Token waste analysis, relay call trace, error-prone operations, build priority, NOT-to-build list |
| `.urc/eval-hook-enhancement.md` | CLI payload parsing, response file format, signal ordering, Gemini additionalContext correction, 140 LOC implementation |

---

## Part 5: Build vs. Rely — Where Custom Tools Add the Most Value

### The Problem With Hook-Only Architecture

Hooks capture events. But the coordination ACTIONS — dispatching messages, waiting for responses, reading output, managing state — currently rely on either:

1. **The model calling Bash** with tmux commands, jq pipelines, file reads — which means the model must interpret raw output, handle errors, and compose multi-step sequences. Every step burns tokens and introduces interpretation risk.
2. **The model calling MCP tools** (coordination_server.py) — which is better, but the current tools are thin wrappers around Bash commands. They still shell out to `tmux-send-helper.sh` and return raw text.

The question: where does building a dedicated tool give us **guaranteed reliability** that no amount of prompt engineering or hook configuration can match?

### The Decision Framework

| Situation | Build a tool | Rely on hooks/Bash |
|---|---|---|
| Operation must succeed every time (delivery guarantee) | ✓ Tool | |
| Operation is fire-and-forget (best-effort notification) | | ✓ Hook |
| Model needs structured data back (not raw text) | ✓ Tool | |
| Operation involves multi-step coordination (send→wait→read) | ✓ Tool (atomic) | |
| Operation is a single write (append event to file) | | ✓ Hook/Bash |
| Cost matters (don't waste tokens on plumbing) | ✓ Tool | |
| Must work identically across Claude/Codex/Gemini | ✓ Tool | |

### Tools Worth Building

> **Note:** This section was written before the cross-CLI review established Decision 6 (SQLite for truth, JSONL for observability only). The JSONL-querying tools (`stream_read`, `stream_write`, `fleet_snapshot`) described below were subsequently **removed from the implementation plan** — they contradict Decision 6 by treating JSONL as a programmatic data plane. The authoritative tool list is in Part 4's "Updated Tool Priority and Estimates" table. The tools retained below (`dispatch-and-wait.sh`, `relay_cycle`, `send_with_notify`, `bootstrap_validate`, `cancel_dispatch`) are consistent with Decision 6.

#### Tool 1: `dispatch_and_wait` — The Atomic Relay Cycle

**Problem it solves:** Today the relay makes 3 separate calls: `relay_forward` → Bash poll loop → `relay_read`. Each call costs a Haiku model turn (~$0.001), burns tokens for the model to interpret raw output, and can fail independently.

**What the tool does (one MCP call):**
1. Dispatch message to target via tmux-send-helper.sh (no-verify, fast)
2. Block on `tmux wait-for "urc-{TARGET}"` with configurable timeout
3. On wake: read the response from the event stream (hook payload has `last_assistant_message`) OR fall back to `tmux capture-pane`
4. Return structured JSON: `{"status": "completed", "response": "...", "elapsed_ms": 1234}`

**Why build it:** Eliminates 2 model turns per relay cycle. The relay agent calls ONE tool and gets back the response. No interpretation needed. No multi-step coordination. No token waste.

**MCP blocking concern:** This tool BLOCKS while waiting. The original `wait_for_turn_complete` was deprecated for blocking the STDIO loop. The solution: run the wait in a subprocess or thread, and use MCP's async notification pattern (if available), OR accept the block with a reasonable timeout (the MCP server can handle one in-flight blocking call). Alternatively, this could be a Bash script rather than an MCP tool — the relay calls `bash dispatch-and-wait.sh %TARGET "message" 120` and gets structured output.

**Recommendation:** Build as a **Bash script** that returns JSON. Avoids the MCP blocking problem entirely. The relay agent does one Bash call, gets structured JSON back.

```bash
# dispatch-and-wait.sh %TARGET "message" [timeout]
# Returns: {"status":"completed","response":"...","elapsed_ms":1234}
# Or:      {"status":"timeout","elapsed_ms":120000,"partial":"..."}
```

### Tools That Are NOT Worth Building

| Candidate | Why Not |
|---|---|
| Custom notification daemon | Hooks + tmux wait-for already push. No daemon needed. |
| Custom heartbeat tool | Event stream IS the heartbeat. Last event timestamp = last heartbeat. |
| Custom pane resolution tool | `observer.sh` already handles this well. Not worth reimplementing. |
| Custom context injection tool | Each CLI's hook system handles this natively. Not something a tool can do. |
| Custom sandbox escape | Not needed — hooks run outside sandbox. |

The authoritative tool list and build priority is in Part 4. Tools previously described here (stream_read, stream_write, fleet_snapshot) were removed per Decision 6 (SQLite truth, JSONL observability only).

### Scaling With Time

The architecture is designed to scale:

- **New event types:** Just add to the JSONL schema. External consumers (dashboards, scripts) filter by type.
- **New CLIs:** Any CLI that can write files and call tmux adds a 5-line hook. Core tools don't change.
- **More panes:** Response files and JSONL per-pane scale linearly. SQLite handles concurrent access.
- **Richer payloads:** Events can carry arbitrary metadata. The hook writes whatever the CLI provides.
- **Web dashboard:** The JSONL streams are `tail -f`able by any external process. A web dashboard can watch them without any URC changes.
- **AfterToolUse on Codex:** When Codex wires it to config, the hook just appends `tool_call` events to the same stream. Dispatch-and-wait works unchanged.

---

---

## Part 6: Decision Parameters and Final Proposal

### 6.1 The Parameters

These are the constraints, priorities, and trade-offs that shape the decision. Each parameter has a weight reflecting Sid's stated priorities.

| # | Parameter | Weight | Description |
|---|---|---|---|
| 1 | **Minimal overhead / dependencies** | CRITICAL | "Without getting an overhead process involved." No daemons, no background services, no complex setup. Download, configure hooks, run. |
| 2 | **Push over polling** | CRITICAL | "A notification system response from session to session CLI is way better than polling and waiting." Event-driven, not poll-driven. |
| 3 | **Reliability and certainty** | CRITICAL | "Guarantee that we have reliability and certainty of things working." Deterministic tools over model interpretation. Code guarantees over prompt hope. |
| 4 | **Minimal code** | HIGH | "Minimal code and that we can easily scale on top of incredibly well." ~415 LOC for the complete system. Each component does one thing. |
| 5 | **Token efficiency** | HIGH | "Not burning tokens or relying on a model's interpretation." Composite tools reduce relay from ~20K tokens/message to ~7.5K. 4-10x improvement. |
| 6 | **Open source usability** | HIGH | "Anyone that wants to take this open source project and just download it and then run it and have work." First 5 minutes determine adoption. bootstrap_validate solves this. |
| 7 | **Scalability** | HIGH | "Strong foundation that we can easily scale on top of incredibly well." Layered API (Level 0-3). Adding a new CLI = one 5-line hook. Tools don't change. |
| 8 | **Cross-platform** | MEDIUM | Gemini review flagged kqueue is macOS-only. tmux wait-for is universal. Dropped kqueue to stay OS-agnostic. |
| 9 | **Correctness under concurrency** | MEDIUM | Codex review flagged request/turn correlation. Without it, concurrent dispatches or manual input cause wrong-turn reads. Added correlation protocol. |
| 10 | **Future-proofing** | MEDIUM | Codex's AfterToolUse is coming (PRs #13276, #13408, #13498). Design should absorb richer hooks without architectural changes. It does — just append more event types to the stream. |

### 6.2 How Each Decision Was Made

**Decision 1: tmux wait-for as sole notification primitive (drop kqueue)**

| Parameter | kqueue + wait-for | wait-for only |
|---|---|---|
| Minimal overhead | ✗ Python dependency for kqueue | ✓ Bash + tmux only |
| Cross-platform | ✗ macOS-only | ✓ Wherever tmux runs |
| Minimal code | ✗ ~25 LOC Python waiter | ✓ ~15 LOC Bash |
| Reliability | ~ Both work | ✓ Simpler = fewer failure modes |
| Latency | 0.1ms | 5ms | **Irrelevant** — model turns take 2,000ms+ |

**Verdict:** tmux wait-for wins on 4 of 5 parameters. kqueue wins only on latency, which doesn't matter at human/model timescales. Dropped.

**Decision 2: Bash script for dispatch-and-wait (not MCP tool)**

| Parameter | MCP tool (anyio threads) | Bash script |
|---|---|---|
| Reliability | ✗ MCP client timeout unknown | ✓ Zero timeout risk — Bash runs until done |
| Minimal overhead | ~ Same | ✓ No Python threading complexity |
| Token efficiency | ✓ Structured JSON return | ~ Model parses JSON from stdout (easy) |
| Scalability | ✓ Could promote to MCP later | ✓ Works as-is, MCP wrapper trivial to add |

**Verdict:** Bash wins on reliability (the most critical parameter). MCP tool approach has an unverified client timeout risk that could be a showstopper. Bash is safe, proven, and can be wrapped in an MCP tool (`relay_cycle`) once the blocking behavior is empirically validated.

**Decision 3: Response-from-hook (not terminal scraping)**

| Parameter | tmux capture-pane | Response file from hook |
|---|---|---|
| Reliability | ✗ ANSI parsing, buffer offset, timing | ✓ Clean JSON, atomic write |
| Correctness | ✗ Gets whatever's in the buffer | ✓ Gets the actual model response |
| Minimal code | ~ Similar | ✓ Hook writes, reader reads — simple |
| Cross-CLI | ✗ CLI-specific buffer formats | ✓ Universal JSON schema |

**Verdict:** Response-from-hook wins on every parameter. Terminal scraping becomes the fallback path only.

**Decision 4: Request/turn correlation in the response protocol**

| Parameter | Without correlation | With correlation |
|---|---|---|
| Correctness | ✗ Wrong-turn reads under concurrency | ✓ Guaranteed correct response |
| Minimal code | ✓ Simpler | ~ +10-15 LOC for correlation check |
| Reliability | ✗ Nondeterministic under load | ✓ Deterministic always |

**Verdict:** Correctness is non-negotiable. All three cross-CLI reviewers flagged this independently. +15 LOC is trivial for guaranteed correctness.

**Decision 5: Composite tools (not model-orchestrated primitives)**

| Parameter | Model orchestrates 4-5 calls | One composite tool |
|---|---|---|
| Token efficiency | ✗ 200-500 tokens/cycle reasoning | ✓ ~50 tokens/cycle |
| Reliability | ✗ Depends on prompt adherence | ✓ Deterministic code |
| Minimal code | ~ Same total LOC | ✓ LOC is in tools, not prompts |
| Scalability | ✗ Every new CLI needs prompt updates | ✓ CLI differences hidden inside tools |

**Verdict:** Composite tools win on every parameter. The same principle behind `tmux-send-helper.sh` — wrap complexity in deterministic code so the model calls one thing and gets a guaranteed result.

**Decision 6: SQLite for data, JSONL for observability (not dual truth)**

| Parameter | Dual data plane (SQLite + JSONL) | SQLite truth, JSONL observability |
|---|---|---|
| Reliability | ✗ "Which datastore is correct?" bugs | ✓ One truth, one debug view |
| Minimal code | ✗ Tools for both | ✓ Tools query SQLite only |
| Correctness | ✗ Dual-write consistency undefined | ✓ Clear hierarchy |

**Verdict:** Codex review was right. One truth (SQLite), one debug channel (JSONL append in hooks for `tail -f` observability). No MCP tools to query JSONL — it's for humans, not models.

### 6.3 Architectural Principle: CLI Adapter Pattern (Modularity)

**The risk:** Without deliberate modularity, URC becomes a growing `if claude ... elif codex ... elif gemini` snowflake in every component. Adding a new CLI means touching 10+ files. When a CLI changes its hook system, changes cascade across the codebase.

**The solution: CLI Adapter configs.** CLI-specific behavior lives in exactly ONE place per CLI — a `.conf` file in `urc/adapters/`. Core code is fully CLI-agnostic. It reads the adapter config and uses it.

```
urc/adapters/
  claude.conf       # ~15 lines: payload format, output contract, dispatch config, inbox type
  codex.conf        # ~15 lines: same interface, Codex-specific values
  gemini.conf       # ~15 lines: same interface, Gemini-specific values
  detect.sh         # CLI detection from hook payload structure
  README.md         # "How to add a new CLI in 5 minutes"
```

**Adapter config interface (each CLI implements ALL fields):**

| Field | Purpose | Example (Claude) | Example (Codex) | Example (Gemini) |
|---|---|---|---|---|
| `RESPONSE_FIELD` | jq path to response in hook payload | `last_assistant_message` | `last-assistant-message` | `prompt_response` |
| `PAYLOAD_SOURCE` | How hook receives payload | `stdin` | `argv1` | `stdin` |
| `HOOK_OUTPUT` | Required stdout on hook exit | (empty) | (empty) | `{"continue":true}` |
| `INBOX_HOOK_TYPE` | How CLI receives inbox notifications | `PostToolUse` | `middleware` | `BeforeAgent` |
| `INBOX_CONTEXT_FIELD` | Field name for context injection | `additionalContextForAssistant` | (empty) | `additionalContext` |
| `DISPATCH_DELAY_BASE_MS` | Base delay before Enter | `300` | `100` | `100` |
| `DISPATCH_USE_PASTE_BUFFER` | Force paste-buffer mode | `false` | `false` | `true` |

**The core hook becomes CLI-agnostic:**
```bash
CLI=$(bash "$ADAPTER_DIR/detect.sh" "$@")
source "$ADAPTER_DIR/${CLI}.conf"
[ "$PAYLOAD_SOURCE" = "stdin" ] && PAYLOAD=$(cat) || PAYLOAD="${1:-}"
RESPONSE=$(echo "$PAYLOAD" | jq -r ".[\"$RESPONSE_FIELD\"] // empty")
# ... all universal from here ...
[ -n "$HOOK_OUTPUT" ] && echo "$HOOK_OUTPUT"
```

**Adding a new CLI:** Create one `.conf` file (~15 lines) + add detection signature to `detect.sh` (~3 lines). Zero core code changes. A 5-minute open source contribution.

**When a CLI evolves:** Edit ONE adapter file. If Codex adds `additionalContext` support, change two fields in `codex.conf`. Nothing else changes.

### 6.4 The Final Proposal

**Architecture: Enhanced hook + tmux wait-for + composite Bash/MCP tools + 4-layer notification stack**

```
┌─────────────────────────────────────────────────────────┐
│                    THE URC v2 STACK                      │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Layer 4: Agent Interface                               │
│  ┌───────────────────────────────────────────────────┐  │
│  │ relay_cycle (MCP) → calls dispatch-and-wait.sh    │  │
│  │ send_with_notify (MCP) → SQLite + signal + wake   │  │
│  │ bootstrap_validate (MCP) → setup verification     │  │
│  │ cancel_dispatch (MCP) → interrupt + cleanup       │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  Layer 3: Composite Scripts                             │
│  ┌───────────────────────────────────────────────────┐  │
│  │ dispatch-and-wait.sh (Bash)                       │  │
│  │   clear → dispatch → pre-check → tmux wait-for   │  │
│  │   → validate correlation → read response → JSON   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  Layer 2: Notification Stack                            │
│  ┌───────────────────────────────────────────────────┐  │
│  │ 1. Spawn instructions (prompt says check inbox)   │  │
│  │ 2. MCP middleware hints (_with_inbox_hint)         │  │
│  │ 3. PostToolUse piggyback (Claude) / BeforeAgent   │  │
│  │    (Gemini) / middleware-only (Codex)              │  │
│  │ 4. tmux wake pulse (for idle panes)               │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  Layer 1: Primitives                                    │
│  ┌───────────────────────────────────────────────────┐  │
│  │ tmux-send-helper.sh (dispatch)                    │  │
│  │ tmux wait-for (notification)                      │  │
│  │ .urc/responses/{PANE}.json (response content)     │  │
│  │ .urc/signals/done_{PANE} (durable signal)         │  │
│  │ SQLite coordination.db (messages, tasks, state)   │  │
│  │ JSONL streams (observability only, not queried)    │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  Layer 0: CLI Hooks (the push engine)                   │
│  ┌───────────────────────────────────────────────────┐  │
│  │ turn-complete-hook.sh (all CLIs):                 │  │
│  │   parse payload → write response file → touch     │  │
│  │   signal → tmux wait-for -S → append JSONL        │  │
│  │ inbox-piggyback.sh (Claude PostToolUse)           │  │
│  │ inbox-inject.sh (Gemini BeforeAgent)              │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

#### 6.4.1 Foundation vs Enhancement Layers

The architecture separates into a **foundation** (the transport) and **enhancement layers** (consumers of the transport). This mirrors Claude Code Agent Teams' approach (write to inbox file + poll) — except push-based instead of poll-based.

**FOUNDATION (3 components — the transport):**

1. **Enhanced turn-complete hook** — writes `.urc/responses/{PANE}.json` + fires `tmux wait-for -S "urc_done_{PANE}"`. This is the push primitive that all CLIs implement identically.
2. **dispatch-and-wait.sh** — sends message to a pane + blocks on `tmux wait-for` + reads the response file. This is the atomic send-receive primitive.
3. **Relay agent calling dispatch-and-wait.sh via Bash** — the simplest possible consumer. One Bash tool call per relay cycle.

These three components are the entire transport. Everything else builds ON TOP of them without changing them.

**ENHANCEMENT LAYERS (consumers of the same transport):**

- **Layer 1 (Notification):** inbox-piggyback.sh, BeforeAgent hooks, MCP middleware hints — for async cross-CLI messaging. These inject "you have messages" context into CLI sessions. They do not touch the transport.
- **Layer 2 (Agent Experience):** MCP wrappers (relay_cycle, send_with_notify), structured JSON returns — for token savings and deterministic tool interfaces. These call the transport (dispatch-and-wait.sh) internally.
- **Layer 3 (Observability):** JSONL stream appends, progress events — for humans and dashboards. The hook appends one line to a JSONL file as a side effect; no component reads it programmatically.

**Why this layering matters:**
- Each layer plugs into the foundation without changing it.
- New capabilities = new consumers of the same transport.
- New CLIs = new hooks writing to the same file format (`.urc/responses/{PANE}.json`).
- A layer can be removed, replaced, or disabled without affecting the foundation or other layers.

### 6.4 Why This Is the 99th Percentile Decision

**It satisfies every parameter at its weight:**

| Parameter | Weight | How This Design Satisfies It |
|---|---|---|
| Minimal overhead | CRITICAL ✓ | No daemons. Hooks fire on CLI events. tmux wait-for uses zero CPU while waiting. No Python beyond existing MCP server. |
| Push over polling | CRITICAL ✓ | Hooks push events + signals. tmux wait-for delivers instant (~5ms) notification. Zero polling loops anywhere in the system. |
| Reliability | CRITICAL ✓ | Response-from-hook eliminates terminal scraping. Bash dispatch-and-wait has zero MCP timeout risk. Correlation prevents wrong-turn reads. Atomic file writes prevent partial reads. |
| Minimal code | HIGH ✓ | ~415 LOC total (per implementation plan). Each component does one thing. No 1,638 LOC watchdog. No complex event servers. |
| Token efficiency | HIGH ✓ | Relay: 8 turns → 3 turns per message. ~15K tokens/message saved. ~1.5M tokens/day at 100 messages. |
| Open source usability | HIGH ✓ | `bootstrap_validate` verifies setup on first run. CWD requirement documented and validated. hook configs are 5 lines per CLI. |
| Scalability | HIGH ✓ | New CLI = 5-line hook. Composite tools are CLI-agnostic. SQLite handles concurrent access. Layered API lets models call the right level. |
| Cross-platform | MEDIUM ✓ | tmux-only (no kqueue). Bash-only for composite scripts (no Python waiter). Runs wherever tmux runs. |
| Correctness | MEDIUM ✓ | Request/turn correlation. Atomic writes. Signal ordering (response → signal → tmux). Timeout fallbacks. |
| Future-proofing | MEDIUM ✓ | When Codex adds AfterToolUse: one line in hook to append tool_call events. When new CLI appears: one 5-line hook. Tools unchanged. |

**What makes it 99th percentile vs. 90th:**

The 90th percentile solution would stop at "enhance the hook and use tmux wait-for." That works but leaves the model orchestrating 4-5 primitive calls per relay cycle, burning tokens, handling race conditions in prompts, and hoping the model remembers to clean up signal files.

The 99th percentile solution adds the composite tool layer — `dispatch-and-wait.sh` and `relay_cycle` — which convert multi-step coordination from "model-interpreted sequences" to "deterministic code." This is the same principle that made `tmux-send-helper.sh` successful: wrap complexity in tools, give the model a clean interface. The model's job becomes "pass the message through" — not "orchestrate a 5-step protocol with race conditions and error handling."

The additional ~100 LOC for composite tools pays for itself within the first day of usage via token savings alone.

### 6.5 Build Sequence

```
Phase 0 (Foundation, ~138 LOC):
  1. Enhanced turn-complete hook (response capture + dual signal)
  2. dispatch-and-wait.sh (Bash, with correlation)
  3. bootstrap_validate (MCP tool)
  → Milestone: dispatch to any CLI, get structured response, zero polling

Phase 1 (Relay + Notifications, ~160 LOC):
  4. relay_cycle MCP tool (wraps dispatch-and-wait.sh)
  5. send_with_notify MCP tool
  6. inbox-piggyback.sh (Claude PostToolUse)
  → Milestone: sub-second relay, inbox-aware Claude sessions

Phase 2 (Hardening, ~85 LOC):
  7. cancel_dispatch MCP tool
  8. Gemini BeforeAgent inbox hook
  9. MCP middleware expansion
  10. Inbox signal integration in team_send/send_message
  → Milestone: full 4-layer notification, abort capability

Phase 3 (Polish, ~10 LOC):
  11. Relay agent prompt rewrite
  → Milestone: minimal relay prompt
  Note: JSONL event stream append is included in Phase 0 (hook enhancement), not deferred.
```

### 6.6 Cross-CLI Review Incorporation

| Reviewer | Key Contribution | Incorporated? |
|---|---|---|
| **Opus (%1000)** | Turn counter for signal protocol; trap cleanup in hook; `urc init` command; Unix domain socket alternative (acknowledged, not adopted) | ✓ Turn counter → correlation protocol. ✓ Trap cleanup → hook implementation note. ✓ `urc init` → `bootstrap_validate`. |
| **Codex (%1001)** | Request/turn correlation (P0); pane lease concept; `bootstrap_validate`; strict event envelope schema; one truth hierarchy (SQLite vs JSONL); build contracts before code | ✓ Correlation protocol. ~ Pane lease deferred to P2 (relay pattern naturally serializes). ✓ bootstrap_validate. ✓ SQLite truth, JSONL observability. ✓ Build order: contracts first. |
| **Gemini (%1002)** | Drop kqueue; Bash for dispatch_and_wait (MCP timeout risk); `cancel_dispatch` tool; dynamic auto-clear; Codex ARG_MAX fallback; process death blindness | ✓ kqueue dropped. ✓ Bash-first. ✓ cancel_dispatch added (P2). ~ Dynamic auto-clear noted for relay prompt. ✓ ARG_MAX fallback in hook design. ~ Process death → timeout handles it. |

### 6.8 Open Items

1. ~~**Codex notify hook tmux access.**~~ **RESOLVED 2026-03-04.** Empirically confirmed: `tmux wait-for -S` returns exit 0 from Codex notify hook. All tmux operations work. See Truth 1 for full test results.

2. **MCP client timeout for long-blocking tools.** If empirical testing shows Claude Code tolerates 120s MCP tool calls, we can promote `dispatch-and-wait.sh` to an MCP tool for cleaner integration. Low risk: Bash version works regardless. Test during Phase 1.

3. **Codex ARG_MAX for very long responses.** macOS is 1MB (confirmed via `getconf`), but edge cases exist. The hook should check `$1` length and fall back to `tmux capture-pane` for oversized payloads. Low risk: most responses are well under 1MB.

4. **Gemini BeforeAgent `additionalContext` injection.** Source code confirms the field exists but we haven't tested it live. If it doesn't work, fall back to MCP middleware hints. Low risk: fallback is proven. Test during Phase 2.

5. **Pane lease / mutual exclusion.** Cross-CLI reviewers flagged concurrent dispatch risk. The relay pattern naturally serializes (one relay per target). For Phase 0: add simple `flock` in `dispatch-and-wait.sh` on `.urc/locks/{PANE}.lock`. Full lease protocol deferred to Phase 2 if multi-dispatcher scenarios arise.

---

## Evidence Index (Complete)

All documents at `.urc/` in the UniversalRemoteControl directory:

### Deep Research (4 Opus agents, this session)
| Document | What It Contains |
|---|---|
| `research-codex-hooks-deep.md` | Codex hooks framework, sandbox analysis, notify runs OUTSIDE sandbox, app-server API, Issue #2109 |
| `research-gemini-hooks-deep.md` | Gemini's 11 hook events, config schema, BeforeAgent context injection, extension system |
| `research-claude-hooks-deep.md` | Claude's 20 hook events, HTTP hooks, TeammateIdle, Agent Teams inbox mechanism |
| `research-push-notification-patterns.md` | tmux wait-for source analysis, Unix signals, FIFOs, kqueue, fswatch, hybrid patterns |

### Tool Evaluations (3 Opus agents, this session)
| Document | What It Contains |
|---|---|
| `eval-dispatch-and-wait.md` | MCP feasibility confirmed, kqueue implementation, anyio threading, edge cases, 68 LOC sketch |
| `eval-tool-landscape.md` | Token waste analysis (20K tokens/relay cycle), relay 7-9 call trace, error-prone operations, build priority |
| `eval-hook-enhancement.md` | CLI payload parsing, response file format, signal ordering, Gemini additionalContext CORRECTION, 140 LOC implementation |

### Cross-CLI Reviews (3 live panes: Opus %1000, Codex %1001, Gemini %1002)
| Reviewer | Key Contributions |
|---|---|
| Opus (%1000) | Turn counter for correlation, trap cleanup in hook, `urc init` command, 10 specific recommendations |
| Codex (%1001) | Correlation protocol (P0), pane lease concept, bootstrap_validate, event envelope schema, truth hierarchy, build contracts first |
| Gemini (%1002) | Drop kqueue (cross-platform), Bash over MCP for blocking (client timeout risk), cancel_dispatch, dynamic auto-clear, ARG_MAX fallback |

### Experiments (4 agents, this session)
| Document | What It Contains |
|---|---|
| `experiments/result-tail-streaming.md` | Bash tool does NOT stream (5 test variants confirmed) |
| `experiments/result-waitfor-jsonl.md` | tmux wait-for ~10ms overhead, JSONL 0/800 corruption |
| `experiments/result-e2e-codex.md` | Codex dispatch works, hooks not loaded (CWD mismatch) |
| `experiments/result-e2e-gemini.md` | Gemini dispatch works, NOT sandboxed, CWD mismatch found |

### Parallel Session
| Document | What It Contains |
|---|---|
| `architecture-research-synthesis-2026-03-04.md` | Full parallel synthesis — kqueue benchmarks, response-from-hook, composite tools, layered API |
| `handoff-992-to-939.md` | RC Bridge investigation, Codex sandbox finding, tmux wait-for hybrid |
| `handoff-investigation-to-939.md` | ContextPilot v1/v2 vs URC comparative analysis |

### Codex Swarm
| Document | What It Contains |
|---|---|
| `research-993-cross-cli-parity-synthesis.md` | Cross-CLI parity analysis, 3 architecture options |
| `research-941-agent-team-parity.md` | Agent Teams portability table, 5 responsiveness changes |
| `research-994-notification-architecture.md` | Commit-Then-Pulse + Action-Edge Reconciliation design |
| `research-995-gemini-surfaces.md` | Gemini signaling surfaces and constraints |

### Historical
| Document | What It Contains |
|---|---|
| `investigation-optimal-protocol.md` | tmux wait-for hybrid, latency comparison table |
| `investigation-codex-notification.md` | Codex sandbox tmux failure test (later corrected — hooks run outside sandbox) |
| `synthesis-relay-architecture-v2.md` | Combined synthesis from R1/R2 investigations |
