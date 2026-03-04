"""
coordination_db.py — SQLite foundation for URC state coordination.

Provides connection management, schema initialization, retry logic, and
maintenance utilities. All operations are safe for concurrent multi-pane use
via WAL mode + busy_timeout.

Usage:
    from urc.core.coordination_db import get_connection, init_schema
    conn = get_connection()
    init_schema(conn)
"""

import os
import sqlite3
import time

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

DB_PATH = ".urc/coordination.db"

# ---------------------------------------------------------------------------
# PRAGMAs applied to every new connection
# ---------------------------------------------------------------------------

_PRAGMAS = [
    "PRAGMA journal_mode = WAL;",
    "PRAGMA busy_timeout = 5000;",
    "PRAGMA wal_autocheckpoint = 100;",
    "PRAGMA synchronous = NORMAL;",
]

# ---------------------------------------------------------------------------
# DDL
# ---------------------------------------------------------------------------

_CREATE_TABLES = """
CREATE TABLE IF NOT EXISTS agents (
    pane_id           TEXT PRIMARY KEY,
    cli               TEXT NOT NULL,
    model             TEXT,
    role              TEXT,
    status            TEXT DEFAULT 'active',
    pid               INTEGER,
    pid_start_time    TEXT,
    context_pct       REAL,
    silence_threshold INTEGER DEFAULT 60,
    last_heartbeat    REAL,
    health            TEXT DEFAULT 'passing',
    restart_count     INTEGER DEFAULT 0,
    registered_at     REAL
);

CREATE TABLE IF NOT EXISTS tasks (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT NOT NULL,
    status       TEXT DEFAULT 'pending',
    claimed_by   TEXT REFERENCES agents(pane_id),
    priority     INTEGER DEFAULT 0,
    commit_sha   TEXT,
    created_at   REAL,
    claimed_at   REAL,
    completed_at REAL
);

CREATE TABLE IF NOT EXISTS messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    from_pane  TEXT NOT NULL,
    to_pane    TEXT,
    body       TEXT NOT NULL,
    read       INTEGER DEFAULT 0,
    created_at REAL
);

CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    pane_id    TEXT,
    event_type TEXT,
    data       TEXT,
    created_at REAL
);

CREATE TABLE IF NOT EXISTS message_reads (
    message_id INTEGER NOT NULL REFERENCES messages(id),
    pane_id    TEXT NOT NULL,
    read_at    REAL,
    PRIMARY KEY (message_id, pane_id)
);
"""

_CREATE_INDEXES = """
CREATE INDEX IF NOT EXISTS idx_tasks_claimable
    ON tasks(status, priority DESC, id ASC);

CREATE INDEX IF NOT EXISTS idx_agents_stale
    ON agents(status, last_heartbeat);

CREATE INDEX IF NOT EXISTS idx_messages_inbox
    ON messages(to_pane, read, created_at);

CREATE INDEX IF NOT EXISTS idx_events_recent
    ON events(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_message_reads_lookup
    ON message_reads(pane_id, message_id);
"""

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def get_connection(db_path=None):
    """Open a SQLite connection with WAL mode and safe concurrency settings.

    Args:
        db_path: Path to the SQLite database file. Defaults to DB_PATH.
                 Pass ":memory:" for an in-memory database (testing).

    Returns:
        sqlite3.Connection with row_factory set to sqlite3.Row.
    """
    path = db_path if db_path is not None else DB_PATH
    # Guard: coordination.db must NOT be on cloud-sync mounts (WAL corruption risk)
    if path != ":memory:":
        real = os.path.realpath(path)
        for cloud_dir in ("/Library/Mobile Documents", "/Library/CloudStorage", "Dropbox"):
            if cloud_dir in real:
                raise RuntimeError(f"coordination.db MUST NOT be on cloud-sync mount: {real}")
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    for pragma in _PRAGMAS:
        conn.execute(pragma)
    return conn


def init_schema(conn):
    """Create all tables and indexes if they do not already exist.

    Idempotent — safe to call on every startup. Does not drop or alter
    existing tables.

    Args:
        conn: An open sqlite3.Connection (from get_connection).
    """
    with conn:
        conn.executescript(_CREATE_TABLES)
        conn.executescript(_CREATE_INDEXES)
        # Schema migration: add label column (idempotent)
        try:
            conn.execute("ALTER TABLE agents ADD COLUMN label TEXT;")
        except sqlite3.OperationalError:
            pass  # Column already exists


def execute_with_retry(conn, sql, params=(), max_retries=3):
    """Execute a SQL statement with exponential backoff on SQLITE_BUSY.

    Backoff schedule: 100 ms, 200 ms, 400 ms (doubles each attempt).

    Args:
        conn:        An open sqlite3.Connection.
        sql:         SQL statement string.
        params:      Parameter tuple for the statement.
        max_retries: Maximum number of attempts (default 3).

    Returns:
        sqlite3.Cursor from the successful execute call.

    Raises:
        sqlite3.OperationalError: Re-raised after all retries exhausted, or
            immediately for non-lock errors.
    """
    for attempt in range(max_retries):
        try:
            with conn:
                return conn.execute(sql, params)
        except sqlite3.OperationalError as e:
            if "database is locked" in str(e) and attempt < max_retries - 1:
                time.sleep(0.1 * (2 ** attempt))
                continue
            raise


def run_maintenance(conn):
    """Run integrity check and passive WAL checkpoint.

    Args:
        conn: An open sqlite3.Connection.

    Returns:
        The integrity_check result string (e.g. "ok" when healthy).
    """
    rows = conn.execute("PRAGMA integrity_check;").fetchall()
    # integrity_check returns one or more rows; a healthy DB returns a single "ok"
    result = ", ".join(str(r[0]) for r in rows)
    conn.execute("PRAGMA wal_checkpoint(PASSIVE);")
    return result


# ---------------------------------------------------------------------------
# Agents CRUD
# ---------------------------------------------------------------------------

SILENCE_THRESHOLDS = {
    "opus": 90,
    "sonnet": 45,
    "haiku": 30,
    "codex": 60,
    "gemini": 60,  # Gemini bumped from 45 → 60 (deep research phases)
}


def _get_silence_threshold(cli, model=None):
    """Auto-select silence threshold based on model or CLI type."""
    if model and model.lower() in SILENCE_THRESHOLDS:
        return SILENCE_THRESHOLDS[model.lower()]
    if cli:
        # Extract model hint from cli name (e.g., "claude-code" → check model param)
        for key in SILENCE_THRESHOLDS:
            if key in cli.lower():
                return SILENCE_THRESHOLDS[key]
    return 60  # default


def register_agent(conn, pane_id, cli, role, pid, model=None):
    """Register or re-register an agent. INSERT OR REPLACE into agents table.

    Auto-sets silence_threshold based on model/cli.
    Sets registered_at and last_heartbeat to now.

    Args:
        conn:    An open sqlite3.Connection.
        pane_id: Tmux pane ID (e.g. "%393").
        cli:     CLI type string (e.g. "claude-code", "gemini-cli").
        role:    Agent role string (e.g. "engineer", "researcher").
        pid:     Process ID of the agent process.
        model:   Optional model name hint for threshold selection.
    """
    now = time.time()
    threshold = _get_silence_threshold(cli, model)

    pid_start = None

    # Preserve existing label on re-register (INSERT OR REPLACE would clobber it)
    existing = get_agent(conn, pane_id)
    existing_label = existing["label"] if existing and existing["label"] else None

    execute_with_retry(
        conn,
        """INSERT OR REPLACE INTO agents
           (pane_id, cli, model, role, status, pid, pid_start_time,
            silence_threshold, last_heartbeat, registered_at, label)
           VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)""",
        (pane_id, cli, model, role, pid, pid_start, threshold, now, now, existing_label),
    )


def update_heartbeat(conn, pane_id, context_pct, status):
    """Update heartbeat timestamp, context_pct, and status for an agent.

    Args:
        conn:        An open sqlite3.Connection.
        pane_id:     Tmux pane ID to update.
        context_pct: Current context usage percentage (float).
        status:      Current agent status string.
    """
    execute_with_retry(
        conn,
        """UPDATE agents SET last_heartbeat = ?, context_pct = ?, status = ?
           WHERE pane_id = ?""",
        (time.time(), context_pct, status, pane_id),
    )


def get_agent(conn, pane_id):
    """Get a single agent row by pane_id.

    Args:
        conn:    An open sqlite3.Connection.
        pane_id: Tmux pane ID to look up.

    Returns:
        sqlite3.Row if found, None otherwise.
    """
    return conn.execute(
        "SELECT * FROM agents WHERE pane_id = ?", (pane_id,)
    ).fetchone()


def list_agents(conn, status=None):
    """List all agents, optionally filtered by status.

    Args:
        conn:   An open sqlite3.Connection.
        status: Optional status string to filter by (e.g. "active").

    Returns:
        List of sqlite3.Row objects.
    """
    if status:
        return conn.execute(
            "SELECT * FROM agents WHERE status = ?", (status,)
        ).fetchall()
    return conn.execute("SELECT * FROM agents").fetchall()


def detect_stale_agents(conn):
    """Find agents whose heartbeat is older than 2x their silence threshold.

    Excludes agents in shutdown or crashed status.

    Args:
        conn: An open sqlite3.Connection.

    Returns:
        List of sqlite3.Row objects with pane_id, cli, silence_threshold.
    """
    return conn.execute(
        """SELECT pane_id, cli, silence_threshold FROM agents
           WHERE last_heartbeat < (CAST(strftime('%s', 'now') AS INTEGER) - silence_threshold * 2)
           AND status NOT IN ('shutdown', 'crashed')"""
    ).fetchall()


def set_agent_status(conn, pane_id, status):
    """Update agent status.

    Args:
        conn:    An open sqlite3.Connection.
        pane_id: Tmux pane ID to update.
        status:  New status. Must be one of: active, idle, processing,
                 crashed, shutdown.

    Raises:
        ValueError: If status is not one of the valid values.
    """
    valid = {"active", "idle", "processing", "crashed", "shutdown"}
    if status not in valid:
        raise ValueError(f"Invalid status '{status}'. Must be one of: {valid}")
    execute_with_retry(
        conn,
        "UPDATE agents SET status = ? WHERE pane_id = ?",
        (status, pane_id),
    )


def deregister_agent(conn, pane_id):
    """Remove an agent from the table.

    Args:
        conn:    An open sqlite3.Connection.
        pane_id: Tmux pane ID to remove.
    """
    execute_with_retry(
        conn,
        "DELETE FROM agents WHERE pane_id = ?",
        (pane_id,),
    )


def update_agent_label(conn, pane_id, label):
    """Set or clear a display label for an agent.

    Args:
        conn:    An open sqlite3.Connection.
        pane_id: Tmux pane ID to update.
        label:   Display label string, or None/empty to clear.
    """
    execute_with_retry(
        conn,
        "UPDATE agents SET label = ? WHERE pane_id = ?",
        (label or None, pane_id),
    )


# ---------------------------------------------------------------------------
# Tasks CRUD
# ---------------------------------------------------------------------------


def create_task(conn, title, priority=0):
    """Create a new pending task. Returns the task ID."""
    now = time.time()
    cursor = execute_with_retry(
        conn,
        "INSERT INTO tasks (title, priority, created_at) VALUES (?, ?, ?)",
        (title, priority, now),
    )
    return cursor.lastrowid


def claim_task(conn, pane_id):
    """Atomically claim the highest-priority pending task.

    Uses BEGIN IMMEDIATE to acquire write lock immediately.
    Returns the claimed task Row, or None if no pending tasks.
    """
    now = time.time()
    for attempt in range(3):
        try:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute(
                """UPDATE tasks SET status='claimed', claimed_by=?, claimed_at=?
                   WHERE id = (
                       SELECT id FROM tasks
                       WHERE status='pending'
                       ORDER BY priority DESC, id ASC
                       LIMIT 1
                   )
                   RETURNING *""",
                (pane_id, now),
            ).fetchone()
            conn.execute("COMMIT")
            return row
        except sqlite3.OperationalError as e:
            try:
                conn.execute("ROLLBACK")
            except Exception:
                pass
            if "database is locked" in str(e) and attempt < 2:
                time.sleep(0.1 * (2 ** attempt))
                continue
            raise
    return None


def complete_task(conn, task_id, commit_sha=None):
    """Mark a task as done with optional commit SHA."""
    execute_with_retry(
        conn,
        "UPDATE tasks SET status='done', completed_at=?, commit_sha=? WHERE id=?",
        (time.time(), commit_sha, task_id),
    )


def fail_task(conn, task_id):
    """Mark a task as failed."""
    execute_with_retry(
        conn,
        "UPDATE tasks SET status='failed' WHERE id=?",
        (task_id,),
    )


def list_tasks(conn, status=None):
    """List all tasks, optionally filtered by status."""
    if status:
        return conn.execute(
            "SELECT * FROM tasks WHERE status = ?", (status,)
        ).fetchall()
    return conn.execute("SELECT * FROM tasks ORDER BY priority DESC, id ASC").fetchall()


def get_task(conn, task_id):
    """Get a single task by ID. Returns Row or None."""
    return conn.execute(
        "SELECT * FROM tasks WHERE id = ?", (task_id,)
    ).fetchone()


# ---------------------------------------------------------------------------
# Messages + Events CRUD
# ---------------------------------------------------------------------------


def send_message(conn, from_pane, to_pane, body):
    """Send a message between agents. to_pane=None for broadcast.

    Returns the message ID.
    """
    now = time.time()
    cursor = execute_with_retry(
        conn,
        "INSERT INTO messages (from_pane, to_pane, body, created_at) VALUES (?, ?, ?, ?)",
        (from_pane, to_pane, body, now),
    )
    return cursor.lastrowid


def receive_messages(conn, pane_id, mark_read=True):
    """Get unread messages for a pane (direct + broadcasts).

    Direct messages: tracked via messages.read column.
    Broadcasts: tracked per-pane in message_reads table.

    If mark_read=True, marks them as read atomically.
    Returns list of Row objects.
    """
    # Direct messages addressed to this pane
    direct = conn.execute(
        """SELECT * FROM messages
           WHERE to_pane = ? AND read = 0
           ORDER BY created_at ASC""",
        (pane_id,),
    ).fetchall()

    # Broadcasts not yet read by this pane
    broadcasts = conn.execute(
        """SELECT m.* FROM messages m
           WHERE m.to_pane IS NULL
             AND NOT EXISTS (
                 SELECT 1 FROM message_reads r
                 WHERE r.message_id = m.id AND r.pane_id = ?
             )
           ORDER BY m.created_at ASC""",
        (pane_id,),
    ).fetchall()

    msgs = list(direct) + list(broadcasts)

    if mark_read and msgs:
        now = time.time()
        direct_ids = [m["id"] for m in direct]
        if direct_ids:
            placeholders = ",".join("?" * len(direct_ids))
            execute_with_retry(
                conn,
                f"UPDATE messages SET read = 1 WHERE id IN ({placeholders})",
                tuple(direct_ids),
            )
        for msg in broadcasts:
            execute_with_retry(
                conn,
                "INSERT OR IGNORE INTO message_reads (message_id, pane_id, read_at) VALUES (?, ?, ?)",
                (msg["id"], pane_id, now),
            )

    return msgs


def report_event(conn, pane_id, event_type, data=None):
    """Log a structured event. data should be a JSON string or None.

    Returns the event ID.
    """
    now = time.time()
    cursor = execute_with_retry(
        conn,
        "INSERT INTO events (pane_id, event_type, data, created_at) VALUES (?, ?, ?, ?)",
        (pane_id, event_type, data, now),
    )
    return cursor.lastrowid


def list_events(conn, pane_id=None, event_type=None, limit=100):
    """List events with optional filters. Ordered by most recent first."""
    query = "SELECT * FROM events WHERE 1=1"
    params = []
    if pane_id is not None:
        query += " AND pane_id = ?"
        params.append(pane_id)
    if event_type is not None:
        query += " AND event_type = ?"
        params.append(event_type)
    query += " ORDER BY created_at DESC LIMIT ?"
    params.append(limit)
    return conn.execute(query, tuple(params)).fetchall()


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import sys

    if "--self-test" in sys.argv:
        conn = get_connection(":memory:")
        init_schema(conn)

        # ── Schema + maintenance tests ──
        tables = [
            r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        ]
        assert set(tables) >= {"agents", "tasks", "messages", "events"}, (
            f"Missing tables: {set(tables)}"
        )
        indexes = [
            r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='index'"
            ).fetchall()
        ]
        assert "idx_tasks_claimable" in indexes
        assert "idx_agents_stale" in indexes
        assert "idx_messages_inbox" in indexes
        assert "idx_events_recent" in indexes

        execute_with_retry(
            conn,
            "INSERT INTO events (pane_id, event_type, data, created_at) VALUES (?, ?, ?, ?)",
            ("%test", "self_test", "{}", time.time()),
        )
        row = conn.execute("SELECT COUNT(*) FROM events").fetchone()
        assert row[0] == 1, f"Expected 1 event row, got {row[0]}"

        result = run_maintenance(conn)
        assert "ok" in str(result).lower(), f"Maintenance failed: {result}"

        # ── Agents CRUD tests ──
        register_agent(conn, "%393", "claude-code", "engineer", 12345, model="opus")
        agent = get_agent(conn, "%393")
        assert agent is not None, "Agent not found after register"
        assert agent["silence_threshold"] == 90, (
            f"Expected 90 for opus, got {agent['silence_threshold']}"
        )
        assert agent["status"] == "active"

        register_agent(conn, "%397", "gemini-cli", "researcher", 12346, model="gemini")
        assert get_agent(conn, "%397")["silence_threshold"] == 60, (
            "Gemini should be 60s"
        )

        update_heartbeat(conn, "%393", 42.5, "active")
        assert get_agent(conn, "%393")["context_pct"] == 42.5

        agents = list_agents(conn)
        assert len(agents) == 2

        active_agents = list_agents(conn, status="active")
        assert len(active_agents) == 2

        # Simulate stale agent
        conn.execute(
            "UPDATE agents SET last_heartbeat = CAST(strftime('%s', 'now') AS INTEGER) - 300 WHERE pane_id = '%393'"
        )
        stale = detect_stale_agents(conn)
        assert len(stale) >= 1, "Should detect stale agent"

        set_agent_status(conn, "%393", "idle")
        assert get_agent(conn, "%393")["status"] == "idle"

        # Test invalid status
        try:
            set_agent_status(conn, "%393", "invalid")
            assert False, "Should have raised ValueError"
        except ValueError:
            pass

        # Label CRUD
        update_agent_label(conn, "%393", "Research")
        assert get_agent(conn, "%393")["label"] == "Research"
        update_agent_label(conn, "%393", "")
        assert get_agent(conn, "%393")["label"] is None  # empty clears

        # Re-register preserves label
        update_agent_label(conn, "%393", "Auth-Fixer")
        register_agent(conn, "%393", "claude-code", "engineer", 12345, model="opus")
        assert get_agent(conn, "%393")["label"] == "Auth-Fixer", (
            "Re-register should preserve existing label"
        )

        deregister_agent(conn, "%397")
        assert get_agent(conn, "%397") is None
        assert len(list_agents(conn)) == 1

        # ── Tasks CRUD tests ──
        t1 = create_task(conn, "Fix bug A", priority=1)
        t2 = create_task(conn, "Fix bug B", priority=5)
        assert t1 is not None and t2 is not None, "create_task failed"

        # Higher priority claimed first
        claimed = claim_task(conn, "%393")
        assert claimed is not None, "claim_task returned None"
        assert claimed["title"] == "Fix bug B", f"Expected 'Fix bug B', got '{claimed['title']}'"

        # Second claim gets the lower priority one
        register_agent(conn, "%386", "codex", "engineer", 12346)
        claimed2 = claim_task(conn, "%386")
        assert claimed2 is not None and claimed2["title"] == "Fix bug A"

        # No more tasks to claim
        assert claim_task(conn, "%393") is None, "Should return None when no pending tasks"

        # Complete and verify
        complete_task(conn, claimed["id"], commit_sha="abc123")
        done_task = get_task(conn, claimed["id"])
        assert done_task["status"] == "done"
        assert done_task["commit_sha"] == "abc123"

        # Fail and verify
        fail_task(conn, claimed2["id"])
        assert get_task(conn, claimed2["id"])["status"] == "failed"

        # List tasks
        all_tasks = list_tasks(conn)
        assert len(all_tasks) == 2
        done_tasks = list_tasks(conn, status="done")
        assert len(done_tasks) == 1

        # ── Messages + events CRUD tests ──
        msg_id = send_message(conn, "%393", "%386", "Hello from 393")
        assert msg_id is not None
        bcast_id = send_message(conn, "%393", None, "Broadcast message")
        assert bcast_id is not None

        msgs = receive_messages(conn, "%386")
        assert len(msgs) == 2, f"Expected 2 messages, got {len(msgs)}"
        msgs_again = receive_messages(conn, "%386")
        assert len(msgs_again) == 0, f"Expected 0 after read, got {len(msgs_again)}"

        msgs_other = receive_messages(conn, "%397_new")
        assert len(msgs_other) == 1, f"Expected 1 broadcast, got {len(msgs_other)}"
        msgs_other2 = receive_messages(conn, "%397_new")
        assert len(msgs_other2) == 0, "Broadcast should be read now"

        evt_id = report_event(conn, "%393", "heartbeat", '{"context_pct": 42.5}')
        assert evt_id is not None
        report_event(conn, "%393", "silence", None)
        report_event(conn, "%386", "heartbeat", '{"context_pct": 30.0}')

        pane_events = list_events(conn, pane_id="%393")
        assert len(pane_events) == 2, f"Expected 2 events for %393, got {len(pane_events)}"
        hb_events = list_events(conn, event_type="heartbeat")
        assert len(hb_events) == 2

        print("PASS: coordination_db self-test (schema + agents + tasks + messages + labels)")
        sys.exit(0)
