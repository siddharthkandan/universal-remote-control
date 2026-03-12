# Design Decisions & Rejected Approaches

Read this before modifying `urc/core/` components — especially `send.sh`, `hook.sh`, `wait.sh`, `dispatch-and-wait.sh`.

## Key Design Decisions

### Bridge & State
- **Stateless bridge**: State lives in tmux pane options (`@bridge_target`, `@bridge_cli`, `@bridge_relays`, `@bridge_respawns`)
- **Relay uses Bash, not MCP**: `send.sh` via Bash tool has zero MCP timeout risk (switched from `dispatch-and-wait.sh` to async 2026-03-09)

### tmux Text Injection (send.sh)
- **0.1s settle between Escape and Enter is CRITICAL**: Ink's React TUI needs one full render cycle to process Escape before accepting Enter. Without this, Enter is always dropped — even with 2s paste delay. Empirically validated 2026-03-08.
- **paste_delay**: 0.15s for all CLIs (bumped from 0.05 in v3 fix). Gives TUI initial processing time before fingerprint polling.
- **Pre-Enter fingerprint check**: Polls up to 2s for pasted text to appear before pressing Enter (fixes Enter swallowing on fresh sessions). No post-Enter capture-pane (false negatives on Claude's 1-2s render delay).
- **Post-Enter stuck-input detection (2026-03-09)**: Captures pane bottom before Enter, compares after 0.5s. If unchanged → Enter was dropped during TUI state transition → retries Enter (up to 2x). Fixes wake nudge stuck-input regression where Enter arrived during Ink render transition (agent completing → idle prompt). Skipped for relay control messages (`__urc_push__`, `__urc_refresh__`, `/remote-control`) and shell targets to avoid unnecessary latency. Previous known limitation ("delivered means tmux commands succeeded, NOT text submitted") is now partially mitigated — most stuck-input cases caught by the before/after comparison.

### Synchronization
- **Locking**: mkdir-based in `dispatch-and-wait.sh` (POSIX portable)
- **tmux wait-for over kqueue**: 5ms vs 0.1ms irrelevant at model timescales
- **Timestamp correlation**: Response epoch > dispatch epoch

### Inbox & Wake
- **run_in_background wakes idle agents**: Empirically validated 2026-03-08 — background task completion auto-creates new model turn. BUT historically unreliable (regressions in v2.19–v2.1.22, fixed v2.1.29+). Layer 5 must be complementary to Layer 4, never sole mechanism.
- **Wake nudge rate-limiting**: 30s cooldown per recipient prevents stuck input field from rapid-fire nudges. If nudged within 30s, skip — agent discovers additional messages via `receive_messages()` during the turn started by the first nudge.

### CLI-Specific
- **Gemini stdout CRITICAL**: Only `{"continue":true}` on stdout. ALL debug to stderr.
- **Codex $1 before stdin**: Check `$1` first (Codex passes JSON as arg). If empty, read stdin.
- **Bootstrap protocol**: `(NNN) CODEX|GEMINI` format via legacy text bootstrap. Preferred: tmux options pre-set by `urc-spawn.sh` + `/rename` for session naming (no user bubble on phone). Agent lazy-bootstraps on first message by reading `@bridge_target`/`@bridge_cli`.

### Relay Optimization (Phases 1-4, 2026-03-09)
- **Phase 1 — Bash block reduction**: Plain text output only, no commentary. Anti-commentary rules in agent prompt. Code blocks render as collapsed elements on phone — always plain text.
- **Phase 2 — Hook-based push reading**: `bridge-push-hook.sh` (UserPromptSubmit) reads push files on wake tokens (`message delivered to %`, `response from %`), returns formatted content via `additionalContext` (`PUSH_DATA:` prefix). Model echoes content as plain text — zero Bash blocks for push reading. Registered in `.claude/settings.json` (project-level), NOT `hooks/hooks.json` (plugin-level) — **plugin hooks don't fire on independent sessions**.
- **Phase 3 — Wake token redesign**: Changed from `__urc_push__` to descriptive wake tokens: `message delivered to %NNN (cli)` (processing acknowledgment), `response from %NNN (cli) below:` (response ready). DB message attribution via dispatch metadata files `.urc/dispatches/{PANE}.json`.
- **Phase 4 — Hook-based dispatch**: Bridge push hook extended to handle normal message dispatch. Calls `send.sh`, returns `DISPATCH_OK`/`DISPATCH_FAIL` via `additionalContext`. Model checks `additionalContext` first (route 0) — no double dispatch. `DISPATCH_FAIL` triggers model auto-reconnect with explicit state recovery. No `CLAUDE_CODE_REMOTE` guard — env var not available in hook subprocesses (verified via env dump).
- **Key finding — `CLAUDE_CODE_REMOTE`**: Documented as available in hooks but NOT actually exported to hook subprocesses. Env vars available in hooks: `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_SESSION_ACCESS_TOKEN`. No reliable way to distinguish phone vs terminal sessions in hooks.

### Relay Lifecycle
- **Respawn threshold**: 25 sends (counter only tracks outgoing, not push/status turns; ~50 total turns)
- **Respawn /remote-control re-send**: `hook.sh` backgrounds `respawn-pane -k` then waits 12s and sends `/remote-control` to restore phone connection.
- **Push attribution**: Dispatch metadata files `.urc/dispatches/{PANE}.json` written at dispatch time (source, message, type). `hook.sh` reads+consumes them, includes in push files as `triggered_by`/`triggered_msg`/`triggered_type`. Three categories: relay, dispatch, autonomous.
- **Auto-reconnect**: On `send.sh` `failed`, relay spawns replacement via `tmux split-window`, 8s init wait, updates bridge state, retries message. Capped at 3 attempts via `@bridge_respawns`. Does NOT trigger on `delivered` (known race with dying panes).
- **Health dashboard**: Relay "status" command shows target alive/dead, relay count N/25, respawn count N/3, last activity.
- **Gemini auto-reconnect race (known limitation)**: `send.sh` can return `delivered` for a dying pane. Auto-reconnect requires `failed` status. Narrow race window accepted.
- **No dispatch_async / reply_to**: Cut — zero production callers. Protocol documented in spec for future rebuild.
- **Bootstrap elimination (2026-03-09)**: `urc-spawn.sh` pre-sets `@bridge_target`, `@bridge_cli`, `@bridge_relays` on relay pane + `@bridge_relay` on target pane immediately after spawn. Pre-registers relay in coordination DB. Uses `/rename (NNN) CLI_TYPE` to name session (no user bubble on phone). Agent lazy-bootstraps on first message. Legacy text bootstrap `(NNN) CLI_TYPE` kept in agent prompt for backwards compatibility.
- **Dispatch-acknowledged push (2026-03-09)**: When `send.sh` delivers text to a pane with `@bridge_relay`, it writes a `status:"processing"` push file and fires `__urc_push__` to the relay. Gives phone user immediate "message received" visibility. Fixes 4+ minute relay blind spot during Codex tool-call chains (Codex's notify hook only fires with `last-assistant-message` on text output, not during tool execution). No recursion risk — relay panes never have `@bridge_relay`. Skipped for control messages. Processing push files now include `dispatched_by` attribution read from dispatch metadata (`.urc/dispatches/{PANE}.json`), displayed as `[PROCESSING on %NNN (cli) -- dispatched by %SRC: "msg"]`. Push files are always deleted after hook read (`SHOULD_DELETE=1` unconditional) — both "message delivered" and "response from" wake tokens consume their files atomically via `additionalContext`.

### Codex Paste Burst Detection & Bracketed Paste
- **Codex's paste burst detector fires at 8ms between chars on Unix** (30ms on Windows). When 3+ chars arrive faster than 8ms apart, Codex's `PasteBurst` state machine (in `paste_burst.rs`) buffers them and **suppresses Enter** — treating it as newline instead of submit. This means any injection method that sends chars individually (e.g., `tmux send-keys "hello" Enter`) would trigger burst detection if chars arrive <8ms apart, causing the message to get stuck in the input field.
- **`tmux paste-buffer -p` (bracketed paste) is mandatory**: The `-p` flag wraps the paste in `\e[200~...\e[201~` escape sequences. `crossterm` delivers this as a single `Event::Paste(String)`, which Codex routes directly to the composer's paste handler — completely bypassing the per-char burst detector. Without `-p`, tmux injects raw chars through the PTY, which hit the burst detector at PTY speed (<1ms between chars).
- **Enter after bracketed paste works correctly**: `Event::Paste(String)` doesn't trigger autocomplete popups in Codex (unlike Claude/Gemini), so Enter immediately submits. No Escape needed. This is why `send.sh` skips Escape for Codex targets.
- **If `-p` were removed from `send.sh`**: Every message would trigger burst detection → Enter becomes newline → message sits in input field indefinitely → agent appears dead.
- **Source**: `codex-rs/tui/src/bottom_pane/paste_burst.rs`, `chat_composer.rs`. Timing constants: 8ms burst threshold (Unix), 3-char minimum, 8ms flush timeout. Documented from Codex source analysis (2026-03-11).

### MCP Tool Timeout Defaults
- **Claude Code's MCP tool call timeout defaults to ~27.8 hours** (`s8z=1e8` = 100,000,000ms in cli.js). This is effectively unlimited — MCP tools will never timeout from the MCP layer in any practical scenario.
- **Codex's MCP tool timeout defaults to 60s** (`tool_timeout_sec = 60` in config.toml). URC overrides this to 120s via `.codex/config.toml`.
- **URC's own timeouts are the only effective protection**: `dispatch-and-wait.sh` (60-300s configurable), circuit breaker (`urc/core/circuit.sh`), and `send.sh` fingerprint polling (2s) provide the real timeout boundaries. The MCP layer provides no meaningful guard.
- **`MCP_TOOL_TIMEOUT` env var** can override Claude Code's default (set in `.mcp.json` env block). URC sets `MCP_TOOL_TIMEOUT=120000` for the codex MCP server entry.
- **Design implication**: Never rely on MCP-layer timeouts for correctness. Always implement application-level timeouts in URC tools and scripts.
- **Source**: `cli.js` line 587 (`s8z=1e8`), Codex `config.toml` schema. Documented from static analysis of Claude Code v2.1.71 and Codex source (2026-03-11).

## Rejected Approaches (2026-03-08 — Enter regression investigation)

These were all tested and failed. Do not retry without new evidence.

- **tmux `\;` semicolon chain**: Batches paste+Escape+Enter into single PTY write. FAILS on Claude Code (3/3) and Gemini (3/3). Only works on Codex. Root cause: Ink TUI drops Enter when it arrives in same event loop tick as Escape.
- **`pipe-pane -I`**: Atomic but async (no delivery confirmation), replaces existing pipes, 2x slower.
- **send-keys -H**: Identical to send-keys Enter — same race condition.
- **tmux wait-for for readiness**: Can't detect TUI readiness — only for downstream signaling.
- **Cursor stability polling**: `display-message -p '#{cursor_x},#{cursor_y}'` — potentially faster than fingerprint check but deprioritized (fingerprint works reliably).
- **No tmux-native solution exists** for the timing race. tmux maintainer confirmed (issue #1185): tmux doesn't drop keys, apps discard when not ready.

## Removed Tools (v3 — do not re-add without justification)

`relay_forward`, `relay_read`, `claim_task`, `complete_task`, `report_event`, `health_check`, `send_with_notify` (merged into `send_message`), `dispatch_async` (zero callers)
