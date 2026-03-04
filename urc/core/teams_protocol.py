"""
teams_protocol.py — Core protocol layer for Cross-CLI Teams.

Provides team CRUD (YAML-based), structured messaging with typed envelopes,
task dependency management with cycle detection, completion/idle signals,
and notification infrastructure (signal files, wake signals,
inbox_attention tracking, stall detection).

Teams are stored as YAML files in .urc/teams/{name}.yaml.
Messages and tasks use the existing coordination_db SQLite backend.
"""

import json
import os
import re
import sqlite3
import subprocess
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

import yaml

from urc.core.coordination_db import (
    get_connection,
    init_schema,
    execute_with_retry,
    send_message,
    receive_messages,
    get_agent,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

TEAMS_DIR = ".urc/teams"
INBOX_DIR = ".urc/inbox"

# ---------------------------------------------------------------------------
# Input Validation (path traversal prevention)
# ---------------------------------------------------------------------------

_SAFE_NAME_RE = re.compile(r'^[a-zA-Z0-9._-]{1,64}$')
_PANE_ID_RE = re.compile(r'^%[0-9]+$')


def _validate_name(name: str, label: str = "name") -> None:
    """Validate a name contains only safe characters."""
    if not _SAFE_NAME_RE.match(name):
        raise ValueError(f"Invalid {label}: {name!r} — must match [a-zA-Z0-9._-]{{1,64}}")


def _validate_pane_id(pane_id: str) -> None:
    """Validate pane ID format (%NNN)."""
    if not _PANE_ID_RE.match(pane_id):
        raise ValueError(f"Invalid pane_id: {pane_id!r} — must match %NNN")

# Path to tmux-send-helper.sh — overridable via env for testing
_HELPER_PATH = os.environ.get(
    "URC_SEND_HELPER",
    str(Path(__file__).parent / "tmux-send-helper.sh"),
)

MESSAGE_TYPES = frozenset({
    "message",
    "task_assignment",
    "status_update",
    "completion",
    "idle_notification",
    "shutdown_request",
    "shutdown_response",
    "plan_approval_request",
    "plan_approval_response",
})

# Module-level connection — lazily initialized
_conn = None


def _get_conn():
    """Return the shared SQLite connection, initializing on first call."""
    global _conn
    if _conn is None:
        _conn = get_connection()
        init_schema(_conn)
        _ensure_task_columns(_conn)
        _ensure_inbox_attention_table(_conn)
    return _conn


def _teams_path() -> Path:
    """Return the absolute path to the teams directory, creating it if needed."""
    p = Path(TEAMS_DIR)
    p.mkdir(parents=True, exist_ok=True)
    return p


def _team_file(team_name: str) -> Path:
    """Return the path to a team's YAML file."""
    _validate_name(team_name, "team_name")
    return _teams_path() / f"{team_name}.yaml"


def _now_iso() -> str:
    """Return current UTC time as ISO-8601 string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_team(team_name: str) -> dict:
    """Read a team YAML file. Raises FileNotFoundError if missing."""
    path = _team_file(team_name)
    if not path.exists():
        raise FileNotFoundError(f"Team '{team_name}' not found at {path}")
    with open(path, "r") as f:
        return yaml.safe_load(f)


def _write_team(team_name: str, data: dict):
    """Write team data to YAML using temp-file + mv for atomicity."""
    path = _team_file(team_name)
    tmp = path.with_suffix(".yaml.tmp")
    with open(tmp, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
    tmp.rename(path)


# ---------------------------------------------------------------------------
# Signal File Infrastructure (Notification Layer)
# ---------------------------------------------------------------------------


def _inbox_path() -> Path:
    """Return the inbox signal directory, creating it if needed."""
    p = Path(INBOX_DIR)
    p.mkdir(parents=True, exist_ok=True)
    return p


def _write_signal_file(to_pane: str):
    """Write a presence-flag signal file for a recipient pane.

    Signal files are zero-byte sentinels — the actual unread count comes
    from SQLite at read time. Touch-based: idempotent if multiple messages
    arrive between hook checks.
    """
    _validate_pane_id(to_pane)
    sig = _inbox_path() / f"{to_pane}.signal"
    resolved = sig.resolve()
    if not resolved.is_relative_to(Path(INBOX_DIR).resolve()):
        raise ValueError(f"Signal path escapes inbox directory: {resolved}")
    sig.touch(exist_ok=True)


def _clear_signal_file(pane_id: str):
    """Delete the signal file for a pane after inbox is read."""
    _validate_pane_id(pane_id)
    sig = _inbox_path() / f"{pane_id}.signal"
    resolved = sig.resolve()
    if not resolved.is_relative_to(Path(INBOX_DIR).resolve()):
        raise ValueError(f"Signal path escapes inbox directory: {resolved}")
    try:
        sig.unlink()
    except FileNotFoundError:
        pass


def _send_wake_signal(to_pane: str, to_name: str, team_name: str) -> dict:
    """Send a minimal tmux wake nudge to an idle recipient.

    Uses tmux-send-helper.sh with --force --verify per CLAUDE.md rules
    for AI CLI panes. Returns {"status": "nudged|failed|timeout", "pane": to_pane}.
    """
    nudge_text = f'Check team inbox: team_inbox("{to_name}", "{team_name}")'
    try:
        result = subprocess.run(
            ["bash", _HELPER_PATH, to_pane, nudge_text, "--force", "--verify"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            return {"status": "nudged", "pane": to_pane}
        return {"status": "failed", "pane": to_pane}
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "pane": to_pane}
    except FileNotFoundError:
        return {"status": "failed", "pane": to_pane}


def _ensure_inbox_attention_table(conn):
    """Idempotent migration: create inbox_attention table for delivery tracking."""
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS inbox_attention (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id  INTEGER NOT NULL REFERENCES messages(id),
            to_pane     TEXT NOT NULL,
            state       TEXT NOT NULL DEFAULT 'pending',
            created_at  REAL NOT NULL,
            nudged_at   REAL,
            seen_at     REAL,
            attempts    INTEGER NOT NULL DEFAULT 0,
            UNIQUE(message_id, to_pane)
        );
        CREATE INDEX IF NOT EXISTS idx_attention_state
            ON inbox_attention(to_pane, state, created_at);
    """)


def _insert_attention(conn, msg_id: int, to_pane: str):
    """Insert an inbox_attention row for delivery tracking."""
    execute_with_retry(
        conn,
        """INSERT OR IGNORE INTO inbox_attention
           (message_id, to_pane, state, created_at, attempts)
           VALUES (?, ?, 'pending', ?, 0)""",
        (msg_id, to_pane, time.time()),
    )


def _update_attention_after_wake(conn, msg_id: int, to_pane: str, wake_status: str):
    """Update attention row after any wake attempt.

    Always increments attempts so failed wakes are visible to stall detection.
    Only transitions to 'nudged' state on successful delivery.
    """
    now = time.time()
    if wake_status == "nudged":
        execute_with_retry(
            conn,
            """UPDATE inbox_attention SET state = 'nudged', nudged_at = ?,
               attempts = attempts + 1
               WHERE message_id = ? AND to_pane = ?""",
            (now, msg_id, to_pane),
        )
    else:
        execute_with_retry(
            conn,
            """UPDATE inbox_attention SET attempts = attempts + 1
               WHERE message_id = ? AND to_pane = ?""",
            (msg_id, to_pane),
        )


def _mark_attention_seen(conn, pane_id: str, message_ids: list):
    """Transition attention rows to 'seen' when inbox is read."""
    if not message_ids:
        return
    placeholders = ",".join("?" * len(message_ids))
    execute_with_retry(
        conn,
        f"""UPDATE inbox_attention SET state = 'seen', seen_at = ?
            WHERE message_id IN ({placeholders})
            AND to_pane = ? AND state IN ('pending', 'nudged')""",
        (time.time(), *message_ids, pane_id),
    )


def _mark_attention_escalated(conn, message_id: int, to_pane: str) -> bool:
    """Transition a pending/nudged attention row to escalated.

    Returns True when a row changed state, False when already seen/escalated.
    """
    cursor = execute_with_retry(
        conn,
        """UPDATE inbox_attention SET state = 'escalated'
           WHERE message_id = ? AND to_pane = ?
           AND state IN ('pending', 'nudged')""",
        (message_id, to_pane),
    )
    return (cursor.rowcount or 0) > 0


# ---------------------------------------------------------------------------
# Team CRUD
# ---------------------------------------------------------------------------


def create_team(team_name: str, description: str, lead_pane_id: str) -> dict:
    """Create a new team with the given lead agent.

    Writes .urc/teams/{name}.yaml with schema:
      name, description, created_at, lead, members[], status

    Returns the created team dict.
    """
    path = _team_file(team_name)
    if path.exists():
        raise ValueError(f"Team '{team_name}' already exists")

    now = _now_iso()
    team = {
        "name": team_name,
        "description": description,
        "created_at": now,
        "lead": lead_pane_id,
        "members": [
            {
                "name": "lead",
                "pane_id": lead_pane_id,
                "cli": "unknown",
                "role": "lead",
                "joined_at": now,
            }
        ],
        "status": "active",
    }

    # Enrich lead member with DB info if available
    conn = _get_conn()
    agent = get_agent(conn, lead_pane_id)
    if agent:
        team["members"][0]["cli"] = agent["cli"] or "unknown"

    _write_team(team_name, team)
    return team


def delete_team(team_name: str) -> dict:
    """Delete a team's YAML file. Returns confirmation."""
    path = _team_file(team_name)
    if not path.exists():
        raise FileNotFoundError(f"Team '{team_name}' not found")
    path.unlink()
    return {"deleted": team_name}


def add_member(team_name: str, pane_id: str, name: str, cli: str, role: str) -> dict:
    """Add a member to a team. Validates no duplicate name or pane_id.

    Returns the updated team dict.
    """
    _validate_pane_id(pane_id)
    _validate_name(name, "member_name")
    team = _read_team(team_name)
    for m in team["members"]:
        if m["name"] == name:
            raise ValueError(f"Member name '{name}' already exists in team '{team_name}'")
        if m["pane_id"] == pane_id:
            raise ValueError(f"Pane '{pane_id}' already in team '{team_name}'")

    team["members"].append({
        "name": name,
        "pane_id": pane_id,
        "cli": cli,
        "role": role,
        "joined_at": _now_iso(),
    })
    _write_team(team_name, team)
    return team


def remove_member(team_name: str, name: str) -> dict:
    """Remove a member by name. Returns the updated team dict."""
    team = _read_team(team_name)
    original_len = len(team["members"])
    team["members"] = [m for m in team["members"] if m["name"] != name]
    if len(team["members"]) == original_len:
        raise ValueError(f"Member '{name}' not found in team '{team_name}'")
    _write_team(team_name, team)
    return team


def get_team(team_name: str) -> dict:
    """Read team YAML and enrich members with live agent status from coordination_db.

    Adds 'status' and 'context_pct' fields to each member from the agents table.
    """
    team = _read_team(team_name)
    conn = _get_conn()
    for member in team["members"]:
        agent = get_agent(conn, member["pane_id"])
        if agent:
            member["agent_status"] = agent["status"]
            member["context_pct"] = agent["context_pct"]
        else:
            member["agent_status"] = "unregistered"
            member["context_pct"] = None
    return team


def list_teams() -> list:
    """List all teams as summaries (name, description, member_count, status)."""
    teams_dir = _teams_path()
    result = []
    for path in sorted(teams_dir.glob("*.yaml")):
        if path.suffix == ".yaml" and not path.name.endswith(".tmp"):
            try:
                with open(path, "r") as f:
                    data = yaml.safe_load(f)
                result.append({
                    "name": data.get("name", path.stem),
                    "description": data.get("description", ""),
                    "member_count": len(data.get("members", [])),
                    "status": data.get("status", "unknown"),
                })
            except Exception:
                continue
    return result


# ---------------------------------------------------------------------------
# Name Resolution
# ---------------------------------------------------------------------------


def _resolve_name(team_name: str, name: str) -> str:
    """Resolve a human-readable member name to a pane_id within a team.

    Raises ValueError if the name is not found in the team roster.
    """
    team = _read_team(team_name)
    for m in team["members"]:
        if m["name"] == name:
            return m["pane_id"]
    raise ValueError(f"Member '{name}' not found in team '{team_name}'")


def _resolve_pane(team_name: str, pane_id: str) -> str:
    """Resolve a pane_id to a human-readable name. Returns pane_id if not found."""
    team = _read_team(team_name)
    for m in team["members"]:
        if m["pane_id"] == pane_id:
            return m["name"]
    return pane_id


# ---------------------------------------------------------------------------
# Structured Messaging
# ---------------------------------------------------------------------------


def team_send(from_name: str, to_name: str, team_name: str,
              msg_type: str, body: str, metadata: dict = None,
              wake: bool = True) -> dict:
    """Send a typed message between team members.

    Builds a JSON envelope with team, type, from_name, payload, timestamp
    and stores it via coordination_db.send_message. Then writes a signal
    file and optionally sends a tmux wake nudge to the recipient.

    Returns {"message_id": int, "type": str, "notify": {...}}.
    """
    if msg_type not in MESSAGE_TYPES:
        raise ValueError(f"Invalid message type '{msg_type}'. Must be one of: {sorted(MESSAGE_TYPES)}")

    from_pane = _resolve_name(team_name, from_name)
    to_pane = _resolve_name(team_name, to_name)

    payload = {"body": body}
    if metadata:
        safe_meta = {k: v for k, v in metadata.items() if k != "body"}
        payload.update(safe_meta)

    envelope = json.dumps({
        "team": team_name,
        "type": msg_type,
        "from_name": from_name,
        "payload": payload,
        "timestamp": _now_iso(),
    })

    conn = _get_conn()
    msg_id = send_message(conn, from_pane, to_pane, envelope)

    # Notification: attention tracking + signal file + wake
    _insert_attention(conn, msg_id, to_pane)
    _write_signal_file(to_pane)

    notify_result = {"status": "signal_only", "pane": to_pane, "attempts": 0}
    if wake:
        notify_result = _send_wake_signal(to_pane, to_name, team_name)
        _update_attention_after_wake(conn, msg_id, to_pane, notify_result["status"])

    return {"message_id": msg_id, "type": msg_type, "notify": notify_result}


def team_inbox(name: str, team_name: str) -> list:
    """Get unread messages for a team member, filtered to this team.

    Fetches unread messages WITHOUT marking them read, then filters by
    team_name. Only messages that match this team are marked as read,
    preserving unread status for messages belonging to other teams.

    Each returned item has: type, from_name, body, metadata, timestamp.
    """
    pane_id = _resolve_name(team_name, name)
    conn = _get_conn()
    raw_msgs = receive_messages(conn, pane_id, mark_read=False)

    result = []
    matched_direct_ids = []
    matched_broadcast_ids = []

    for msg in raw_msgs:
        try:
            env = json.loads(msg["body"])
        except (json.JSONDecodeError, TypeError):
            continue
        # Guard: envelope must be a dict (not list/str/int)
        if not isinstance(env, dict):
            continue
        if env.get("team") != team_name:
            continue

        # Track which messages to mark as read
        if msg["to_pane"]:  # direct message
            matched_direct_ids.append(msg["id"])
        else:  # broadcast
            matched_broadcast_ids.append(msg["id"])

        payload = env.get("payload", {})
        # Guard: payload must be a dict
        if not isinstance(payload, dict):
            payload = {}
        result.append({
            "type": env.get("type", "message"),
            "from_name": env.get("from_name", "unknown"),
            "body": payload.get("body", ""),
            "metadata": {k: v for k, v in payload.items() if k != "body"},
            "timestamp": env.get("timestamp", ""),
        })

    # Mark only matched messages as read
    now = time.time()
    if matched_direct_ids:
        placeholders = ",".join("?" * len(matched_direct_ids))
        execute_with_retry(
            conn,
            f"UPDATE messages SET read = 1 WHERE id IN ({placeholders})",
            tuple(matched_direct_ids),
        )
    for mid in matched_broadcast_ids:
        execute_with_retry(
            conn,
            "INSERT OR IGNORE INTO message_reads (message_id, pane_id, read_at) VALUES (?, ?, ?)",
            (mid, pane_id, now),
        )

    # Mark attention rows as seen
    all_matched = matched_direct_ids + matched_broadcast_ids
    _mark_attention_seen(conn, pane_id, all_matched)

    # Only clear signal file if zero unread messages remain across ALL teams
    remaining = conn.execute(
        "SELECT COUNT(*) as cnt FROM messages WHERE to_pane = ? AND read = 0",
        (pane_id,),
    ).fetchone()
    if remaining["cnt"] == 0:
        _clear_signal_file(pane_id)

    return result


def team_broadcast(from_name: str, team_name: str, msg_type: str,
                   body: str, wake: bool = True) -> dict:
    """Broadcast a typed message to all team members except the sender.

    Sends individual messages to each member (not DB broadcast) so that
    envelope filtering by team works correctly. Writes signal files and
    optionally sends wake nudges.

    Returns {"sent_to": [names], "type": str}.
    """
    if msg_type not in MESSAGE_TYPES:
        raise ValueError(f"Invalid message type '{msg_type}'. Must be one of: {sorted(MESSAGE_TYPES)}")

    team = _read_team(team_name)
    from_pane = _resolve_name(team_name, from_name)
    sent_to = []

    envelope_base = {
        "team": team_name,
        "type": msg_type,
        "from_name": from_name,
        "payload": {"body": body},
        "timestamp": _now_iso(),
    }

    conn = _get_conn()
    for member in team["members"]:
        if member["name"] == from_name:
            continue
        envelope_json = json.dumps(envelope_base)
        msg_id = send_message(conn, from_pane, member["pane_id"], envelope_json)
        sent_to.append(member["name"])

        # Notification: attention + signal + wake per recipient
        _insert_attention(conn, msg_id, member["pane_id"])
        _write_signal_file(member["pane_id"])
        if wake:
            notify = _send_wake_signal(member["pane_id"], member["name"], team_name)
            _update_attention_after_wake(conn, msg_id, member["pane_id"], notify["status"])

    return {"sent_to": sent_to, "type": msg_type}


# ---------------------------------------------------------------------------
# Task Dependencies
# ---------------------------------------------------------------------------


def _ensure_task_columns(conn):
    """Idempotent migration: add team_name, blocked_by, blocks, description to tasks.

    Uses ALTER TABLE ADD COLUMN with try/except for each column.
    """
    migrations = [
        ("team_name", "TEXT"),
        ("blocked_by", "TEXT DEFAULT '[]'"),
        ("blocks", "TEXT DEFAULT '[]'"),
        ("description", "TEXT DEFAULT ''"),
    ]
    for col_name, col_type in migrations:
        try:
            conn.execute(f"ALTER TABLE tasks ADD COLUMN {col_name} {col_type};")
        except sqlite3.OperationalError as e:
            if "duplicate column name" in str(e).lower():
                pass  # Column already exists — expected
            else:
                raise  # Real error (lock, corruption, etc.) — propagate


def _detect_cycle(conn, task_id: int, new_blocked_by: list) -> bool:
    """BFS cycle detection. Returns True if adding deps would create a cycle.

    Walks the 'blocked_by' chain from each task in new_blocked_by.
    If we reach task_id, adding these deps would create a cycle.
    """
    visited = set()
    queue = deque(new_blocked_by)
    while queue:
        current = queue.popleft()
        if current == task_id:
            return True
        if current in visited:
            continue
        visited.add(current)
        row = conn.execute("SELECT blocked_by FROM tasks WHERE id = ?", (current,)).fetchone()
        if row and row["blocked_by"]:
            try:
                deps = json.loads(row["blocked_by"])
                queue.extend(deps)
            except (json.JSONDecodeError, TypeError):
                pass
    return False


def team_task_create(team_name: str, title: str, description: str = "",
                     priority: int = 0, blocked_by: list = None) -> dict:
    """Create a task with optional dependencies for a team.

    Validates no cycles if blocked_by is specified. Updates the blocks
    lists of referenced tasks. All mutations run in a single BEGIN
    IMMEDIATE transaction for atomicity (no partial graph states).
    Returns the created task dict.
    """
    conn = _get_conn()
    now = time.time()
    blocked = blocked_by or []

    for attempt in range(3):
        try:
            conn.execute("BEGIN IMMEDIATE")

            # Validate that blocked_by tasks exist (inside txn)
            for dep_id in blocked:
                row = conn.execute("SELECT id FROM tasks WHERE id = ?", (dep_id,)).fetchone()
                if not row:
                    conn.execute("ROLLBACK")
                    raise ValueError(f"Dependency task {dep_id} does not exist")

            cursor = conn.execute(
                """INSERT INTO tasks (title, priority, created_at, team_name, blocked_by, blocks, description)
                   VALUES (?, ?, ?, ?, ?, '[]', ?)""",
                (title, priority, now, team_name, json.dumps(blocked), description),
            )
            task_id = cursor.lastrowid

            # Update blocks lists of referenced tasks (same txn)
            for dep_id in blocked:
                row = conn.execute("SELECT blocks FROM tasks WHERE id = ?", (dep_id,)).fetchone()
                blocks_list = json.loads(row["blocks"]) if row and row["blocks"] else []
                if task_id not in blocks_list:
                    blocks_list.append(task_id)
                    conn.execute(
                        "UPDATE tasks SET blocks = ? WHERE id = ?",
                        (json.dumps(blocks_list), dep_id),
                    )

            conn.execute("COMMIT")
            return {
                "id": task_id,
                "title": title,
                "description": description,
                "status": "pending",
                "team_name": team_name,
                "priority": priority,
                "blocked_by": blocked,
                "blocks": [],
            }
        except sqlite3.OperationalError as e:
            try:
                conn.execute("ROLLBACK")
            except sqlite3.OperationalError:
                pass
            if "database is locked" in str(e) and attempt < 2:
                time.sleep(0.1 * (2 ** attempt))
                continue
            raise


def team_task_update(task_id: int, status: str = None, owner: str = None,
                     add_blocks: list = None, add_blocked_by: list = None) -> dict:
    """Update a task. When status='done', auto-unblocks dependent tasks.

    Cycle detection runs before the transaction (read-only). All
    mutations run in a single BEGIN IMMEDIATE transaction for atomicity
    (no partial graph states on crash or concurrent writers).
    Returns the updated task dict.
    """
    conn = _get_conn()

    # Pre-transaction validation (read-only, outside txn)
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if not row:
        raise ValueError(f"Task {task_id} not found")

    if add_blocked_by:
        for dep_id in add_blocked_by:
            if not conn.execute("SELECT id FROM tasks WHERE id = ?", (dep_id,)).fetchone():
                raise ValueError(f"Dependency task {dep_id} does not exist")
        if _detect_cycle(conn, task_id, add_blocked_by):
            raise ValueError(f"Adding dependencies {add_blocked_by} to task {task_id} would create a cycle")

    if add_blocks:
        for blocked_id in add_blocks:
            if not conn.execute("SELECT id FROM tasks WHERE id = ?", (blocked_id,)).fetchone():
                raise ValueError(f"Task {blocked_id} does not exist")
        if _detect_cycle(conn, task_id, add_blocks):
            raise ValueError(f"Adding blocks {add_blocks} to task {task_id} would create a cycle")

    for attempt in range(3):
        try:
            conn.execute("BEGIN IMMEDIATE")

            # Re-read inside txn to avoid TOCTOU
            row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
            if not row:
                conn.execute("ROLLBACK")
                raise ValueError(f"Task {task_id} not found")

            current_blocked_by = json.loads(row["blocked_by"]) if row["blocked_by"] else []
            current_blocks = json.loads(row["blocks"]) if row["blocks"] else []

            # Add new blocked_by entries + update reciprocal blocks
            if add_blocked_by:
                for dep_id in add_blocked_by:
                    if dep_id not in current_blocked_by:
                        current_blocked_by.append(dep_id)
                    dep_row = conn.execute("SELECT blocks FROM tasks WHERE id = ?", (dep_id,)).fetchone()
                    if not dep_row:
                        conn.execute("ROLLBACK")
                        raise ValueError(f"Dependency task {dep_id} does not exist")
                    dep_blocks = json.loads(dep_row["blocks"]) if dep_row["blocks"] else []
                    if task_id not in dep_blocks:
                        dep_blocks.append(task_id)
                        conn.execute("UPDATE tasks SET blocks = ? WHERE id = ?",
                                     (json.dumps(dep_blocks), dep_id))

            # Add new blocks entries + update reciprocal blocked_by
            if add_blocks:
                for blocked_id in add_blocks:
                    if blocked_id not in current_blocks:
                        current_blocks.append(blocked_id)
                    blocked_row = conn.execute("SELECT blocked_by FROM tasks WHERE id = ?", (blocked_id,)).fetchone()
                    if not blocked_row:
                        conn.execute("ROLLBACK")
                        raise ValueError(f"Task {blocked_id} does not exist")
                    b_deps = json.loads(blocked_row["blocked_by"]) if blocked_row["blocked_by"] else []
                    if task_id not in b_deps:
                        b_deps.append(task_id)
                        conn.execute("UPDATE tasks SET blocked_by = ? WHERE id = ?",
                                     (json.dumps(b_deps), blocked_id))

            # Build and execute main task update
            updates = ["blocked_by = ?", "blocks = ?"]
            params = [json.dumps(current_blocked_by), json.dumps(current_blocks)]

            if status:
                updates.append("status = ?")
                params.append(status)
                if status == "done":
                    updates.append("completed_at = ?")
                    params.append(time.time())

            if owner:
                updates.append("claimed_by = ?")
                params.append(owner)
                if not status:
                    updates.append("status = ?")
                    params.append("claimed")
                    updates.append("claimed_at = ?")
                    params.append(time.time())

            params.append(task_id)
            conn.execute(f"UPDATE tasks SET {', '.join(updates)} WHERE id = ?", tuple(params))

            # Auto-unblock when done (same txn)
            if status == "done":
                for blocked_id in current_blocks:
                    b_row = conn.execute("SELECT blocked_by FROM tasks WHERE id = ?", (blocked_id,)).fetchone()
                    if b_row and b_row["blocked_by"]:
                        b_deps = json.loads(b_row["blocked_by"])
                        b_deps = [d for d in b_deps if d != task_id]
                        conn.execute("UPDATE tasks SET blocked_by = ? WHERE id = ?",
                                     (json.dumps(b_deps), blocked_id))

            conn.execute("COMMIT")

            updated = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
            return {
                "id": updated["id"],
                "title": updated["title"],
                "status": updated["status"],
                "claimed_by": updated["claimed_by"],
                "blocked_by": json.loads(updated["blocked_by"]) if updated["blocked_by"] else [],
                "blocks": json.loads(updated["blocks"]) if updated["blocks"] else [],
            }
        except sqlite3.OperationalError as e:
            try:
                conn.execute("ROLLBACK")
            except sqlite3.OperationalError:
                pass
            if "database is locked" in str(e) and attempt < 2:
                time.sleep(0.1 * (2 ** attempt))
                continue
            raise


def team_task_list(team_name: str) -> list:
    """List all tasks for a team with dependency info.

    Returns list of dicts with id, title, status, priority, claimed_by,
    blocked_by, blocks, description.
    """
    conn = _get_conn()
    rows = conn.execute(
        "SELECT * FROM tasks WHERE team_name = ? ORDER BY priority DESC, id ASC",
        (team_name,),
    ).fetchall()
    result = []
    for row in rows:
        result.append({
            "id": row["id"],
            "title": row["title"],
            "description": row["description"] or "",
            "status": row["status"],
            "priority": row["priority"],
            "claimed_by": row["claimed_by"],
            "blocked_by": json.loads(row["blocked_by"]) if row["blocked_by"] else [],
            "blocks": json.loads(row["blocks"]) if row["blocks"] else [],
        })
    return result


# ---------------------------------------------------------------------------
# Completion / Idle Signals
# ---------------------------------------------------------------------------


def team_complete(name: str, team_name: str, task_id: int = None, summary: str = "") -> dict:
    """Signal task completion. Optionally marks a task done and sends notification to team lead.

    Routes through team_send() so that notifications (signal file,
    wake signal, inbox_attention tracking) are triggered for the lead.

    Returns {"status": "completed", "task_id": ..., "notified": lead_name}.
    """
    team = _read_team(team_name)
    lead_pane = team["lead"]
    lead_name = _resolve_pane(team_name, lead_pane)

    if task_id is not None:
        team_task_update(task_id, status="done")

    team_send(name, lead_name, team_name, "completion", summary,
              metadata={"task_id": task_id})

    return {"status": "completed", "task_id": task_id, "notified": lead_name}


def team_idle(name: str, team_name: str, reason: str = "available") -> dict:
    """Signal idle status. Sends idle_notification to team lead.

    Routes through team_send() so that notifications (signal file,
    wake signal, inbox_attention tracking) are triggered for the lead.

    Returns {"status": "idle", "notified": lead_name}.
    """
    team = _read_team(team_name)
    lead_pane = team["lead"]
    lead_name = _resolve_pane(team_name, lead_pane)

    team_send(name, lead_name, team_name, "idle_notification", reason)

    return {"status": "idle", "notified": lead_name}


# ---------------------------------------------------------------------------
# Stall Detection
# ---------------------------------------------------------------------------


def detect_stalled_messages(team_name: str, delivery_sla: float = 30.0,
                            ack_sla: float = 120.0) -> list:
    """Detect stalled messages in two classes:

    1. Delivery stall: state='pending', attempts >= 2, age > delivery_sla
    2. Ack stall: state='nudged', message still unread, age > ack_sla

    Returns list of stalled message dicts with classification.
    """
    conn = _get_conn()
    now = time.time()
    stalled = []

    # Delivery stalls: wake signal failed to deliver
    rows = conn.execute(
        """SELECT ia.*, m.body FROM inbox_attention ia
           JOIN messages m ON m.id = ia.message_id
           WHERE ia.state = 'pending' AND ia.attempts >= 2
           AND (? - ia.created_at) > ?
           AND json_extract(m.body, '$.team') = ?""",
        (now, delivery_sla, team_name),
    ).fetchall()
    for row in rows:
        env = {}
        payload = {}
        try:
            env = json.loads(row["body"])
            payload = env.get("payload", {}) if isinstance(env, dict) else {}
        except (json.JSONDecodeError, TypeError):
            pass
        stalled.append({
            "message_id": row["message_id"],
            "to_pane": row["to_pane"],
            "classification": "delivery_stall",
            "age_seconds": round(now - row["created_at"], 1),
            "attempts": row["attempts"],
            "team": env.get("team", team_name),
            "from_name": env.get("from_name", "unknown"),
            "msg_type": env.get("type", "unknown"),
            "meta_reason": payload.get("reason", ""),
        })

    # Ack stalls: wake delivered but message not read
    rows = conn.execute(
        """SELECT ia.*, m.body FROM inbox_attention ia
           JOIN messages m ON m.id = ia.message_id
           WHERE ia.state = 'nudged'
           AND (? - ia.created_at) > ?
           AND json_extract(m.body, '$.team') = ?""",
        (now, ack_sla, team_name),
    ).fetchall()
    for row in rows:
        env = {}
        payload = {}
        try:
            env = json.loads(row["body"])
            payload = env.get("payload", {}) if isinstance(env, dict) else {}
        except (json.JSONDecodeError, TypeError):
            pass
        # Check heartbeat freshness for the recipient
        agent = get_agent(conn, row["to_pane"])
        heartbeat_status = "unknown"
        if agent and agent["last_heartbeat"]:
            hb_age = now - agent["last_heartbeat"]
            heartbeat_status = "fresh" if hb_age < 120 else "stale"
        stalled.append({
            "message_id": row["message_id"],
            "to_pane": row["to_pane"],
            "classification": "ack_stall",
            "age_seconds": round(now - row["created_at"], 1),
            "attempts": row["attempts"],
            "heartbeat": heartbeat_status,
            "team": env.get("team", team_name),
            "from_name": env.get("from_name", "unknown"),
            "msg_type": env.get("type", "unknown"),
            "meta_reason": payload.get("reason", ""),
        })

    return stalled


def team_auto_escalate(team_name: str, delivery_sla: float = 30.0,
                       ack_sla: float = 120.0) -> dict:
    """Detect stale deliveries and escalate them to the team lead.

    Escalation rules:
    - delivery_stall: escalate immediately when detected.
    - ack_stall: escalate only when heartbeat is fresh.

    Escalation writes attention state='escalated' and sends a structured
    status_update to the team lead with actionable metadata.
    """
    stalled = detect_stalled_messages(team_name, delivery_sla=delivery_sla, ack_sla=ack_sla)
    if not stalled:
        return {"team": team_name, "checked": 0, "escalated": 0, "items": []}

    team = _read_team(team_name)
    lead_pane = team["lead"]
    lead_name = _resolve_pane(team_name, lead_pane)
    conn = _get_conn()
    escalated_items = []

    for item in stalled:
        reason = item.get("classification", "unknown")

        # Avoid escalation loops from previous auto-escalation status_update messages.
        if item.get("meta_reason") in ("delivery_stall", "ack_stall"):
            continue

        # Ack stalls only escalate when the target appears alive.
        if reason == "ack_stall" and item.get("heartbeat") != "fresh":
            continue

        changed = _mark_attention_escalated(conn, item["message_id"], item["to_pane"])
        if not changed:
            continue

        recommendations = ["Retry wake", "Reassign task", "Check if agent is alive"]
        body = (
            f"AUTO ESCALATION: {reason} detected for message {item['message_id']} "
            f"(to {item['to_pane']}, age {item['age_seconds']}s, attempts {item['attempts']}). "
            f"Recommended actions: {', '.join(recommendations)}."
        )
        metadata = {
            "reason": reason,
            "message_id": item["message_id"],
            "to_pane": item["to_pane"],
            "age_seconds": item["age_seconds"],
            "attempts": item["attempts"],
            "recommended_actions": recommendations,
        }
        if "heartbeat" in item:
            metadata["heartbeat"] = item["heartbeat"]

        notify = team_send(
            lead_name,
            lead_name,
            team_name,
            "status_update",
            body,
            metadata=metadata,
        )
        escalated_items.append({
            "message_id": item["message_id"],
            "to_pane": item["to_pane"],
            "reason": reason,
            "notify": notify.get("notify", {}),
        })

    return {
        "team": team_name,
        "checked": len(stalled),
        "escalated": len(escalated_items),
        "items": escalated_items,
    }


def retry_wake(message_id: int) -> dict:
    """Retry wake signal for a specific message. Returns notify result."""
    conn = _get_conn()
    row = conn.execute(
        """SELECT ia.to_pane, m.body FROM inbox_attention ia
           JOIN messages m ON m.id = ia.message_id
           WHERE ia.message_id = ? AND ia.state IN ('pending', 'nudged')""",
        (message_id,),
    ).fetchone()
    if not row:
        return {"error": f"No pending/nudged attention for message {message_id}"}

    to_pane = row["to_pane"]
    env = {}
    try:
        env = json.loads(row["body"])
    except (json.JSONDecodeError, TypeError):
        pass

    team_name = env.get("team", "unknown")
    # Resolve to_name from the team roster
    to_name = _resolve_pane(team_name, to_pane)

    notify = _send_wake_signal(to_pane, to_name, team_name)
    _update_attention_after_wake(conn, message_id, to_pane, notify["status"])

    return {"message_id": message_id, "notify": notify}


# ---------------------------------------------------------------------------
# Attention Status (Notification Diagnostics)
# ---------------------------------------------------------------------------


def get_attention_status(name: str, team_name: str) -> dict:
    """Read-only diagnostic: pending/nudged/seen counts for a team member."""
    pane_id = _resolve_name(team_name, name)
    conn = _get_conn()
    rows = conn.execute(
        "SELECT state, COUNT(*) as cnt FROM inbox_attention WHERE to_pane = ? GROUP BY state",
        (pane_id,),
    ).fetchall()
    counts = {row["state"]: row["cnt"] for row in rows}
    return {
        "pane": pane_id,
        "name": name,
        "team": team_name,
        "pending": counts.get("pending", 0),
        "nudged": counts.get("nudged", 0),
        "seen": counts.get("seen", 0),
        "escalated": counts.get("escalated", 0),
    }


# ---------------------------------------------------------------------------
# Test-only: override connection for in-memory testing
# ---------------------------------------------------------------------------


def _set_conn_for_test(conn):
    """Replace the module-level connection. For testing only."""
    global _conn
    _conn = conn
    _ensure_task_columns(conn)
    _ensure_inbox_attention_table(conn)
