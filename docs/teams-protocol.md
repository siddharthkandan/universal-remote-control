# Teams Protocol — Cross-CLI Structured Messaging

**Status: Stable**

The Teams Protocol replaces raw tmux keystroke injection with structured,
typed messaging for inter-agent coordination. Claude, Codex, and Gemini
agents join teams, exchange messages through a shared SQLite database, and
manage tasks with dependency tracking — all via MCP tools.

---

## What is the Teams Protocol

When multiple AI CLIs work on the same project, they need to communicate.
The naive approach — injecting keystrokes into tmux panes — is fragile:
messages get swallowed, there's no delivery confirmation, and there's no
way to filter or route messages by type.

The Teams Protocol solves this with three primitives:

1. **Teams** — Named groups of agents stored as YAML files
2. **Typed messages** — JSON envelopes with sender, recipient, type, and payload, stored in SQLite
3. **Task dependencies** — A task board with `blocked_by` relationships and automatic unblocking

All three are exposed as MCP tools. Any CLI that supports MCP (Claude Code,
Codex, Gemini CLI) can use them without modification.

**Key files:**

| File | Role |
|---|---|
| `urc/core/teams_protocol.py` | Data layer — team CRUD, messaging, task deps |
| `urc/core/teams_server.py` | MCP server — 17 tools exposed via STDIO |
| `.urc/teams/*.yaml` | Team state (one YAML file per team) |
| `.urc/coordination.db` | SQLite WAL — messages and tasks |

## MCP Tools

The Teams MCP server currently exposes 17 tools:

| Tool | Description |
|---|---|
| `team_create` | Create a new team with a lead |
| `team_delete` | Delete a team |
| `team_add_member` | Add a member to a team |
| `team_remove_member` | Remove a member from a team |
| `team_status` | Get team details with live member status |
| `team_list` | List teams with summary info |
| `team_send` | Send a typed message between team members |
| `team_inbox` | Read unread team messages |
| `team_broadcast` | Broadcast a typed message to all teammates |
| `team_task_create` | Create a task with optional dependencies |
| `team_task_update` | Update a task, including dependency edits |
| `team_task_list` | List team tasks |
| `team_complete` | Signal completion to team lead |
| `team_idle` | Signal idle status to team lead |
| `team_check_stale` | Detect delivery/ack stalls |
| `team_retry_wake` | Retry wake for a stalled message |
| `team_auto_escalate` | Detect stalls and auto-notify team lead |

---

## Creating a Team

```
team_create(team_name, description, lead_pane_id)
```

| Parameter | Type | Description |
|---|---|---|
| `team_name` | string | Unique team identifier (used in filenames) |
| `description` | string | What the team is working on |
| `lead_pane_id` | string | Tmux pane ID of the team lead (e.g. `%NN1`) |

The lead is auto-added as the first member with name `"lead"` and role
`"lead"`. The team YAML file is written to `.urc/teams/{name}.yaml`.

**Example:**

```
team_create("auth-sprint", "Implement OAuth2 login flow", "%NN1")
```

Creates `.urc/teams/auth-sprint.yaml`:

```yaml
name: auth-sprint
description: Implement OAuth2 login flow
created_at: '2026-02-28T14:30:00Z'
lead: '%NN1'
members:
- name: lead
  pane_id: '%NN1'
  cli: claude-code
  role: lead
  joined_at: '2026-02-28T14:30:00Z'
status: active
```

**Other team management tools:**

| Tool | Description |
|---|---|
| `team_status(team_name)` | Get team details with live agent status per member |
| `team_list()` | List all teams (name, description, member count, status) |
| `team_delete(team_name)` | Delete the team YAML file |

---

## Adding Members

```
team_add_member(team_name, pane_id, name, cli, role)
```

| Parameter | Type | Description |
|---|---|---|
| `team_name` | string | Team to join |
| `pane_id` | string | Tmux pane ID (e.g. `%NN2`) |
| `name` | string | Human-readable name — used for all messaging |
| `cli` | string | `"claude-code"`, `"codex"`, or `"gemini-cli"` |
| `role` | string | Freeform role label (e.g. `"engineer"`, `"researcher"`, `"reviewer"`) |

**Constraints:**

- Name must be unique within the team
- Pane ID must be unique within the team
- Duplicate name or pane raises `ValueError`

**Example:**

```
team_add_member("auth-sprint", "%NN2", "backend-eng", "codex", "engineer")
team_add_member("auth-sprint", "%NN3", "reviewer", "gemini-cli", "researcher")
```

To remove a member:

```
team_remove_member(team_name, name)
```

---

## Messaging

### Sending a message

```
team_send(from_name, to_name, team_name, msg_type, body, metadata?)
```

| Parameter | Type | Description |
|---|---|---|
| `from_name` | string | Sender's member name |
| `to_name` | string | Recipient's member name |
| `team_name` | string | Team context |
| `msg_type` | string | One of the valid message types (see below) |
| `body` | string | Message content |
| `metadata` | dict | Optional extra fields (merged into payload) |

Messages are stored as JSON envelopes in the coordination SQLite database.
The envelope includes team name, type, sender, payload, and timestamp.

### Receiving messages

```
team_inbox(name, team_name)
```

Returns a list of unread messages for the named member, filtered to the
specified team. Messages from other teams are preserved as unread. Each
message contains:

```json
{
  "type": "task_assignment",
  "from_name": "lead",
  "body": "Implement the /login endpoint",
  "metadata": {},
  "timestamp": "2026-02-28T14:35:00Z"
}
```

### Broadcasting

```
team_broadcast(from_name, team_name, msg_type, body)
```

Sends the message to every team member except the sender. Internally sends
individual messages (not a database broadcast) so that team-scoped filtering
works correctly.

### Valid message types

| Type | Use case |
|---|---|
| `message` | General communication |
| `task_assignment` | Assign work to a team member |
| `status_update` | Progress or state change notification |
| `completion` | Signal that work is done |
| `idle_notification` | Signal availability for new work |
| `shutdown_request` | Ask a member to shut down |
| `shutdown_response` | Accept or reject a shutdown request |
| `plan_approval_request` | Submit a plan for lead review |
| `plan_approval_response` | Approve or reject a submitted plan |

Sending an invalid message type raises `ValueError`.

---

## Task Management

The Teams Protocol includes a dependency-aware task board stored in the
coordination SQLite database.

### Creating tasks

```
team_task_create(team_name, title, description?, priority?, blocked_by?)
```

| Parameter | Type | Description |
|---|---|---|
| `team_name` | string | Team the task belongs to |
| `title` | string | Short task title |
| `description` | string | Detailed requirements (optional) |
| `priority` | int | Higher = more important, default 0 |
| `blocked_by` | list | Task IDs that must complete first (optional) |

**Example with dependencies:**

```
t1 = team_task_create("auth-sprint", "Set up OAuth provider config")
t2 = team_task_create("auth-sprint", "Implement /login endpoint", blocked_by=[t1["id"]])
t3 = team_task_create("auth-sprint", "Write integration tests", blocked_by=[t1["id"]])
```

Tasks `t2` and `t3` cannot start until `t1` completes.

**Cycle detection:** The protocol runs BFS cycle detection before adding
dependencies. If adding a dependency would create a circular chain, it
raises `ValueError`.

### Updating tasks

```
team_task_update(task_id, status?, owner?, add_blocks?, add_blocked_by?)
```

| Parameter | Type | Description |
|---|---|---|
| `task_id` | int | Task to update |
| `status` | string | `"pending"`, `"claimed"`, or `"done"` |
| `owner` | string | Claim the task (sets `claimed_by`) |
| `add_blocks` | list | Task IDs this task now blocks |
| `add_blocked_by` | list | Task IDs that now block this task |

**Auto-unblock:** When a task is marked `"done"`, all tasks in its `blocks`
list have that dependency removed from their `blocked_by`. If a blocked
task's `blocked_by` list becomes empty, it's ready to start.

### Listing tasks

```
team_task_list(team_name)
```

Returns all tasks for the team, sorted by priority (descending) then ID
(ascending). Each task includes `id`, `title`, `description`, `status`,
`priority`, `claimed_by`, `blocked_by`, and `blocks`.

---

## Completion Signals

### Signaling completion

```
team_complete(name, team_name, task_id?, summary?)
```

Does two things:

1. If `task_id` is provided, marks the task as `"done"` (triggering auto-unblock)
2. Sends a `completion` message to the team lead

**Example:**

```
team_complete("backend-eng", "auth-sprint", task_id=42, summary="Login endpoint implemented with tests")
```

### Signaling idle

```
team_idle(name, team_name, reason?)
```

Sends an `idle_notification` to the team lead. Use this when you've
finished your assigned work and are available for the next task.

```
team_idle("backend-eng", "auth-sprint", reason="waiting for next assignment")
```

---

## MCP Configuration

The Teams Protocol server runs over STDIO transport. Each CLI needs a
config entry pointing to the server script. Replace paths with your
actual project location.

### Claude Code (`.mcp.json` in project root)

```json
{
  "mcpServers": {
    "urc-teams": {
      "command": ".venv/bin/python3",
      "args": ["urc/core/teams_server.py"],
      "env": { "PYTHONPATH": "." }
    }
  }
}
```

Claude Code uses relative paths — it resolves them from the project root
where `.mcp.json` lives. The server is auto-started as a subprocess when
Claude Code launches.

### Codex (`.codex/config.toml`)

```toml
[mcp_servers.urc-teams]
command = "/absolute/path/to/project/.venv/bin/python3"
args = ["/absolute/path/to/project/urc/core/teams_server.py"]

[mcp_servers.urc-teams.env]
PYTHONPATH = "/absolute/path/to/project"
```

Codex requires **absolute paths** for MCP servers. Update the paths if you
move the project directory.

### Gemini CLI (`.gemini/settings.json`)

```json
{
  "tools": {
    "mcpServers": {
      "urc-teams": {
        "command": "/absolute/path/to/project/.venv/bin/python3",
        "args": ["/absolute/path/to/project/urc/core/teams_server.py"],
        "env": {
          "PYTHONPATH": "/absolute/path/to/project"
        }
      }
    }
  }
}
```

Gemini also requires absolute paths. The `tools.mcpServers` nesting is
specific to Gemini's settings schema.

### Self-test

Verify the server loads correctly:

```bash
.venv/bin/python3 urc/core/teams_server.py --self-test
```

Expected output: `PASS: teams_server self-test (15/15 checks)`.

## How Messages Get Delivered (Notification Architecture)

The cross-CLI protocol uses a 4-layer notification stack. Each layer covers a different agent state:

**Layer 1: Spawn-Time Instructions (zero code)**
Workers are spawned with instructions: "After completing each task, call team_inbox() to check for new assignments." The agent's own turn loop drives inbox polling. Covers ~80% of notification cases.

**Layer 2: MCP Tool Middleware (active agents, universal)**
`_with_inbox_hint()` appends unread message counts to MCP tool responses (team_status, team_task_list, team_complete, team_idle). When an agent calls any of these tools, it sees "You have N unread messages." Primary notification channel for Gemini (whose hooks are limited to SessionStart/PreCompress).

**Layer 3: PostToolUse Hook Piggyback (active Claude agents, zero cost)**
A PostToolUse hook checks for a signal file at `.urc/inbox/%PANE.signal` (single stat() syscall, ~0.1ms). If a signal exists, it injects a notification via `additionalContextForAssistant` — the agent sees "TEAM NOTIFICATION: You have N unread messages" directly in its context. Zero overhead when no messages exist. The hook is read-only — it checks the signal file but does not delete it. The signal persists until the agent calls team_inbox(), which clears it only when zero unread messages remain across all teams. This ensures persistent reminders until the agent acts.

**Layer 4: tmux Wake Signal (idle agents)**
When `team_send()` commits a message to SQLite, it also:
1. Writes a signal file (`.urc/inbox/%NNN.signal`) for hook piggyback
2. Sends a ~60-char wake signal via `tmux-send-helper.sh --force --verify`
The wake signal is NOT the message — it's a trigger telling the agent to call `team_inbox()`. The actual message stays in SQLite (durable, queryable, structured).

**Delivery Tracking:**
The `inbox_attention` table tracks delivery lifecycle: pending → nudged → seen → escalated. Two stall classes are detected:
- Delivery stall: message pending >30s with 2+ wake attempts
- Ack stall: message nudged but unread >120s with fresh heartbeat

Escalation is automatic via `team_auto_escalate`: it detects stalls and sends
structured `status_update` notifications to the team lead with recommended
actions ("Retry wake", "Reassign task", "Check if agent is alive").

Use `team_check_stale` for read-only diagnostics, `team_retry_wake` for manual
retries, and `team_auto_escalate` for detection + escalation in one call.

**Cross-CLI Hook Quality:**

| CLI | Hook | Injection Quality |
|-----|------|------------------|
| Claude | PostToolUse → additionalContextForAssistant | Excellent (directly in LLM context) |
| Codex | notify → stderr | Moderate (user-visible, not LLM-injected) |
| Gemini | SessionStart/PreCompress | Low (infrequent); MCP middleware is primary |

---

## Quick Start Example

End-to-end walkthrough: create a team, add members, create tasks with
dependencies, assign work, and complete.

### 1. Create the team

The lead agent (Claude in pane `%NN1`) creates the team:

```
team_create("bugfix-sprint", "Fix auth token expiration bugs", "%NN1")
```

### 2. Add members

```
team_add_member("bugfix-sprint", "%NN2", "fixer", "codex", "engineer")
team_add_member("bugfix-sprint", "%NN3", "tester", "gemini-cli", "tester")
```

### 3. Create tasks with dependencies

```
t1 = team_task_create("bugfix-sprint", "Reproduce token expiration bug", priority=5)
t2 = team_task_create("bugfix-sprint", "Fix token refresh logic", blocked_by=[t1["id"]])
t3 = team_task_create("bugfix-sprint", "Write regression tests", blocked_by=[t2["id"]])
```

Task chain: reproduce (t1) -> fix (t2) -> test (t3).

### 4. Assign tasks

The lead sends assignments via typed messages:

```
team_send("lead", "fixer", "bugfix-sprint", "task_assignment",
          "Reproduce the token expiration bug — see issue #142")
team_task_update(t1["id"], owner="fixer")
```

### 5. Worker checks inbox and works

The Codex agent checks its inbox:

```
team_inbox("fixer", "bugfix-sprint")
```

Returns the task assignment. After completing the work:

```
team_complete("fixer", "bugfix-sprint", task_id=t1["id"],
              summary="Reproduced — token TTL is 0 instead of 3600")
```

This marks `t1` as done and auto-unblocks `t2`. The lead is notified.

### 6. Lead assigns next task

```
team_send("lead", "fixer", "bugfix-sprint", "task_assignment",
          "Fix the token refresh logic — TTL should be 3600s")
team_task_update(t2["id"], owner="fixer")
```

### 7. Continue until done

When `t2` completes, `t3` auto-unblocks. The lead assigns it to the tester:

```
team_send("lead", "tester", "bugfix-sprint", "task_assignment",
          "Write regression tests for token refresh")
team_task_update(t3["id"], owner="tester")
```

### 8. Check progress

At any point, check the task board:

```
team_task_list("bugfix-sprint")
```

Returns all tasks with their status, owner, and dependency state.

### 9. Clean up

```
team_delete("bugfix-sprint")
```

---

## Native Agent Teams vs Cross-CLI Protocol

Universal Remote Control has **two coordination mechanisms** that coexist without conflict:

| | Native Agent Teams | Cross-CLI Protocol (this doc) |
|---|---|---|
| **Scope** | Claude-to-Claude only | Claude, Codex, and Gemini |
| **Transport** | JSON files at `~/.claude/teams/` | SQLite + YAML at `.urc/teams/` |
| **Inbox polling** | Automatic (framework, between API turns) | Manual (`team_inbox` MCP call) |
| **Idle detection** | Auto `idle_notification` on turn end | Silence thresholds + heartbeat |
| **Lifecycle** | Session-scoped (TeamCreate → TeamDelete) | Project-scoped (persistent) |
| **Spawning** | Agent tool (spawn-only, fresh workers) | `tmux split-window` + `tmux-send-helper.sh` (any CLI) |

### When to use which

- **All workers are Claude** → Native Agent Teams (`TeamCreate` + `Agent` tool)
- **Any worker is Codex or Gemini** → Cross-CLI Protocol (this doc)
- **Mixed team (Claude + Codex)** → Cross-CLI Protocol (strict separation — no bridging between stores)

### How native works (brief)

The team lead calls `TeamCreate` to create a team, then spawns teammates via the `Agent` tool with `team_name` and `name` parameters. Each teammate gets a JSON inbox at `~/.claude/teams/{team}/inboxes/{agent}.json`. The framework automatically polls this inbox between every API turn and delivers messages as synthetic `<teammate-message>` conversation turns — no terminal injection, no custom hooks.

Communication uses `SendMessage` (DMs and broadcasts). Task management uses `TaskCreate`, `TaskUpdate`, `TaskList`, and `TaskGet` with dependency tracking (`blocks`/`blockedBy`) and auto-unblocking. Teammates auto-send `idle_notification` when their turn ends. Graceful shutdown uses `shutdown_request`/`shutdown_response`.

### Coexistence

The two systems use completely different directories, storage formats, and protocols. Running both simultaneously causes zero interference. A Claude agent can even participate in both systems at the same time.

---

## See Also

- [Architecture Overview](architecture-overview.md) — how the teams server fits into the system
- [Getting Started](getting-started.md) — install and configure MCP servers
