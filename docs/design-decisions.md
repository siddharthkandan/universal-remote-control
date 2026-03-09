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
- **Bootstrap protocol**: `(NNN) CODEX|GEMINI` message format

### Relay Lifecycle
- **Respawn threshold**: 25 sends (counter only tracks outgoing, not push/status turns; ~50 total turns)
- **Respawn /remote-control re-send**: `hook.sh` backgrounds `respawn-pane -k` then waits 12s and sends `/remote-control` to restore phone connection.
- **Push attribution**: Dispatch metadata files `.urc/dispatches/{PANE}.json` written at dispatch time (source, message, type). `hook.sh` reads+consumes them, includes in push files as `triggered_by`/`triggered_msg`/`triggered_type`. Three categories: relay, dispatch, autonomous.
- **Auto-reconnect**: On `send.sh` `failed`, relay spawns replacement via `tmux split-window`, 8s init wait, updates bridge state, retries message. Capped at 3 attempts via `@bridge_respawns`. Does NOT trigger on `delivered` (known race with dying panes).
- **Health dashboard**: Relay "status" command shows target alive/dead, relay count N/25, respawn count N/3, last activity.
- **Gemini auto-reconnect race (known limitation)**: `send.sh` can return `delivered` for a dying pane. Auto-reconnect requires `failed` status. Narrow race window accepted.
- **No dispatch_async / reply_to**: Cut — zero production callers. Protocol documented in spec for future rebuild.
- **Dispatch-acknowledged push (2026-03-09)**: When `send.sh` delivers text to a pane with `@bridge_relay`, it writes a `status:"processing"` push file and fires `__urc_push__` to the relay. Gives phone user immediate "message received" visibility. Fixes 4+ minute relay blind spot during Codex tool-call chains (Codex's notify hook only fires with `last-assistant-message` on text output, not during tool execution). No recursion risk — relay panes never have `@bridge_relay`. Skipped for control messages.

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
