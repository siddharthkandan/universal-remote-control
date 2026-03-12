"""
db.py — SQLite foundation for URC agent registration, messaging, and maintenance.

Simplified fork of coordination_db.py. Three tables only: agents, messages,
message_reads. No tasks or events tables.

Usage:
    from urc.core.db import get_connection, init_schema
    conn = get_connection()
    init_schema(conn)
"""

import os
import sqlite3
import time

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DB_PATH = os.path.join(_PROJECT_ROOT, ".urc", "coordination.db")

# ---------------------------------------------------------------------------
# DDL
# ---------------------------------------------------------------------------

_CREATE_TABLES = """
CREATE TABLE IF NOT EXISTS agents (
    pane_id            TEXT PRIMARY KEY,
    cli                TEXT NOT NULL,
    model              TEXT DEFAULT '',
    role               TEXT DEFAULT 'worker',
    status             TEXT DEFAULT 'active',
    pid                INTEGER,
    pid_start_time     REAL,
    context_pct        INTEGER DEFAULT -1,
    silence_threshold  INTEGER DEFAULT 120,
    last_heartbeat     REAL,
    health             TEXT DEFAULT 'ok',
    restart_count      INTEGER DEFAULT 0,
    registered_at      TEXT DEFAULT (datetime('now')),
    label              TEXT DEFAULT '',
    source             TEXT DEFAULT 'urc'
);

CREATE TABLE IF NOT EXISTS messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    from_pane   TEXT,
    to_pane     TEXT,
    body        TEXT NOT NULL,
    read        INTEGER DEFAULT 0,
    created_at  TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS message_reads (
    message_id  INTEGER REFERENCES messages(id),
    pane_id     TEXT,
    read_at     TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (message_id, pane_id)
);
"""

_CREATE_INDEXES = """
CREATE INDEX IF NOT EXISTS idx_agents_stale
    ON agents(status, last_heartbeat);

CREATE INDEX IF NOT EXISTS idx_messages_inbox
    ON messages(to_pane, read, created_at);

CREATE INDEX IF NOT EXISTS idx_message_reads_lookup
    ON message_reads(pane_id, message_id);
"""

# ---------------------------------------------------------------------------
# Connection + Schema
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

    if path != ":memory:":
        db_dir = os.path.dirname(path)
        if db_dir and not os.path.isdir(db_dir):
            os.makedirs(db_dir, exist_ok=True)

    conn = sqlite3.connect(path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA wal_autocheckpoint=100")
    return conn


def init_schema(conn):
    """Create all tables and indexes if they do not already exist.

    Idempotent — safe to call on every startup.

    Args:
        conn: An open sqlite3.Connection (from get_connection).
    """
    with conn:
        conn.executescript(_CREATE_TABLES)
        conn.executescript(_CREATE_INDEXES)

        # Schema migration: add source column if missing (safe for existing DBs)
        try:
            conn.execute("SELECT source FROM agents LIMIT 0")
        except sqlite3.OperationalError:
            conn.execute("ALTER TABLE agents ADD COLUMN source TEXT DEFAULT 'urc'")


# ---------------------------------------------------------------------------
# Retry Utility
# ---------------------------------------------------------------------------


def execute_with_retry(conn, sql, params=(), retries=3):
    """Execute a SQL statement with exponential backoff on SQLITE_BUSY.

    Backoff schedule: 100ms, 200ms, 400ms (doubles each attempt).

    Args:
        conn:    An open sqlite3.Connection.
        sql:     SQL statement string.
        params:  Parameter tuple for the statement.
        retries: Maximum number of attempts (default 3).

    Returns:
        sqlite3.Cursor from the successful execute call.

    Raises:
        sqlite3.OperationalError: Re-raised after all retries exhausted, or
            immediately for non-lock errors.
    """
    for attempt in range(retries):
        try:
            with conn:
                return conn.execute(sql, params)
        except sqlite3.OperationalError as e:
            if "database is locked" in str(e) and attempt < retries - 1:
                time.sleep(0.1 * (2 ** attempt))
                continue
            raise


# ---------------------------------------------------------------------------
# Agents CRUD
# ---------------------------------------------------------------------------


def register_agent(conn, pane_id, cli, role="worker", pid=None, model="", source="urc"):
    """Register or re-register an agent via INSERT OR REPLACE.

    Preserves existing label on re-register. Sets registered_at and
    last_heartbeat to current time.

    Args:
        conn:    An open sqlite3.Connection.
        pane_id: Tmux pane ID (e.g. "%393").
        cli:     CLI type: "claude", "codex", or "gemini".
        role:    Agent role string (default "worker").
        pid:     Process ID of the agent process.
        model:   Model name string (default "").
        source:  Registration source: "urc" or "agent_teams" (default "urc").
    """
    now = time.time()

    # Capture pid_start_time if pid is provided
    pid_start = now if pid else None

    # Preserve existing label on re-register (INSERT OR REPLACE clobbers defaults)
    existing = get_agent(conn, pane_id)
    existing_label = existing["label"] if existing and existing["label"] else ""

    execute_with_retry(
        conn,
        """INSERT OR REPLACE INTO agents
           (pane_id, cli, model, role, status, pid, pid_start_time,
            context_pct, silence_threshold, last_heartbeat, health,
            restart_count, registered_at, label, source)
           VALUES (?, ?, ?, ?, 'active', ?, ?, -1, 120, ?, 'ok', 0, datetime('now'), ?, ?)""",
        (pane_id, cli, model, role, pid, pid_start, now, existing_label, source),
    )


def update_heartbeat(conn, pane_id, context_pct=-1, status="active"):
    """Update heartbeat timestamp, context_pct, and status for an agent.

    Args:
        conn:        An open sqlite3.Connection.
        pane_id:     Tmux pane ID to update.
        context_pct: Current context usage percentage (default -1).
        status:      Current agent status string (default "active").
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


def list_agents(conn, status=None, max_age=None):
    """List all agents, optionally filtered by status and/or heartbeat freshness.

    Args:
        conn:    An open sqlite3.Connection.
        status:  Optional status string to filter by (e.g. "active").
        max_age: Optional max heartbeat age in seconds. When > 0, only return
                 agents whose last_heartbeat is within max_age seconds of now.

    Returns:
        List of sqlite3.Row objects.
    """
    clauses = []
    params = []
    if status:
        clauses.append("status = ?")
        params.append(status)
    if max_age and max_age > 0:
        clauses.append("last_heartbeat >= ?")
        params.append(time.time() - max_age)
    where = (" WHERE " + " AND ".join(clauses)) if clauses else ""
    return conn.execute(f"SELECT * FROM agents{where}", tuple(params)).fetchall()


def update_agent_label(conn, pane_id, label):
    """Set or clear a display label for an agent.

    Args:
        conn:    An open sqlite3.Connection.
        pane_id: Tmux pane ID to update.
        label:   Display label string, or empty/None to clear.
    """
    execute_with_retry(
        conn,
        "UPDATE agents SET label = ? WHERE pane_id = ?",
        (label if label else "", pane_id),
    )


def deregister_agent(conn, pane_id):
    """Mark an agent as offline. Preserves history (does not DELETE).

    Args:
        conn:    An open sqlite3.Connection.
        pane_id: Tmux pane ID to deregister.
    """
    execute_with_retry(
        conn,
        "UPDATE agents SET status = 'offline' WHERE pane_id = ?",
        (pane_id,),
    )


# ---------------------------------------------------------------------------
# Messages CRUD
# ---------------------------------------------------------------------------


def send_message(conn, from_pane, to_pane, body):
    """Send a message between agents. to_pane=None for broadcast.

    Args:
        conn:      An open sqlite3.Connection.
        from_pane: Sender pane ID.
        to_pane:   Recipient pane ID, or None for broadcast.
        body:      Message body text.

    Returns:
        The message ID (integer).
    """
    cursor = execute_with_retry(
        conn,
        "INSERT INTO messages (from_pane, to_pane, body) VALUES (?, ?, ?)",
        (from_pane, to_pane, body),
    )
    return cursor.lastrowid


def receive_messages(conn, pane_id, mark_read=True):
    """Get unread messages for a pane (direct + broadcasts).

    Direct messages: tracked via messages.read column.
    Broadcasts (to_pane IS NULL): tracked per-pane via message_reads table
    to prevent the same broadcast from being delivered twice to the same pane.

    Args:
        conn:      An open sqlite3.Connection.
        pane_id:   Tmux pane ID receiving messages.
        mark_read: If True, mark returned messages as read atomically.

    Returns:
        List of sqlite3.Row objects ordered by created_at ASC.
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
    msgs.sort(key=lambda m: m["id"])

    if mark_read and msgs:
        # Mark direct messages as read
        direct_ids = [m["id"] for m in direct]
        if direct_ids:
            placeholders = ",".join("?" * len(direct_ids))
            execute_with_retry(
                conn,
                f"UPDATE messages SET read = 1 WHERE id IN ({placeholders})",
                tuple(direct_ids),
            )

        # Record broadcast reads in message_reads table
        for msg in broadcasts:
            execute_with_retry(
                conn,
                "INSERT OR IGNORE INTO message_reads (message_id, pane_id) VALUES (?, ?)",
                (msg["id"], pane_id),
            )

    return msgs


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import sys

    if "--self-test" not in sys.argv:
        print("Usage: python3 db.py --self-test")
        sys.exit(1)

    passed = 0
    failed = 0

    def check(name, condition, detail=""):
        global passed, failed
        if condition:
            print(f"  PASS: {name}")
            passed += 1
        else:
            print(f"  FAIL: {name}{' — ' + detail if detail else ''}")
            failed += 1

    conn = get_connection(":memory:")
    init_schema(conn)

    # 1. init_schema — verify tables and indexes exist
    tables = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()}
    check("init_schema tables",
          {"agents", "messages", "message_reads"} <= tables,
          f"got {tables}")

    indexes = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='index'"
    ).fetchall()}
    check("init_schema indexes",
          {"idx_agents_stale", "idx_messages_inbox", "idx_message_reads_lookup"} <= indexes,
          f"got {indexes}")

    # 2. register_agent — register 2 agents, verify they exist
    register_agent(conn, "%100", "claude", role="engineer", pid=1001, model="opus")
    register_agent(conn, "%200", "codex", role="researcher", pid=2002)

    a1 = get_agent(conn, "%100")
    a2 = get_agent(conn, "%200")
    check("register_agent creates agents",
          a1 is not None and a2 is not None)
    check("register_agent cli field",
          a1["cli"] == "claude" and a2["cli"] == "codex",
          f"got {a1['cli']}, {a2['cli']}")
    check("register_agent status default",
          a1["status"] == "active" and a2["status"] == "active")
    check("register_agent pid stored",
          a1["pid"] == 1001 and a2["pid"] == 2002,
          f"got {a1['pid']}, {a2['pid']}")
    check("register_agent pid_start_time set",
          a1["pid_start_time"] is not None)

    # 3. update_heartbeat — update, verify timestamp changed
    old_hb = a1["last_heartbeat"]
    time.sleep(0.01)  # ensure time difference
    update_heartbeat(conn, "%100", context_pct=55, status="active")
    a1_updated = get_agent(conn, "%100")
    check("update_heartbeat timestamp",
          a1_updated["last_heartbeat"] > old_hb,
          f"old={old_hb}, new={a1_updated['last_heartbeat']}")
    check("update_heartbeat context_pct",
          a1_updated["context_pct"] == 55,
          f"got {a1_updated['context_pct']}")

    # 4. get_agent — verify returns correct agent, None for missing
    check("get_agent found",
          get_agent(conn, "%100") is not None)
    check("get_agent missing returns None",
          get_agent(conn, "%999") is None)

    # 5. list_agents — verify count and filtering
    all_agents = list_agents(conn)
    check("list_agents count",
          len(all_agents) == 2,
          f"got {len(all_agents)}")
    active_agents = list_agents(conn, status="active")
    check("list_agents status filter",
          len(active_agents) == 2)
    offline_agents = list_agents(conn, status="offline")
    check("list_agents empty filter",
          len(offline_agents) == 0)

    # 6. update_agent_label — set label, verify
    update_agent_label(conn, "%100", "Auth-Fixer")
    check("update_agent_label set",
          get_agent(conn, "%100")["label"] == "Auth-Fixer")
    update_agent_label(conn, "%100", "")
    check("update_agent_label clear",
          get_agent(conn, "%100")["label"] == "")

    # Verify re-register preserves label
    update_agent_label(conn, "%100", "Preserved")
    register_agent(conn, "%100", "claude", role="engineer", pid=1001, model="opus")
    check("register_agent preserves label",
          get_agent(conn, "%100")["label"] == "Preserved",
          f"got '{get_agent(conn, '%100')['label']}'")

    # 7. send_message — send direct + broadcast, verify message_ids
    mid1 = send_message(conn, "%100", "%200", "Hello from 100")
    mid2 = send_message(conn, "%100", None, "Broadcast from 100")
    check("send_message direct returns id",
          mid1 is not None and isinstance(mid1, int))
    check("send_message broadcast returns id",
          mid2 is not None and isinstance(mid2, int))
    check("send_message ids increment",
          mid2 > mid1)

    # 8. receive_messages — direct + broadcast, dedup test
    msgs_200 = receive_messages(conn, "%200")
    check("receive_messages count",
          len(msgs_200) == 2,
          f"expected 2, got {len(msgs_200)}")
    bodies = [m["body"] for m in msgs_200]
    check("receive_messages content",
          "Hello from 100" in bodies and "Broadcast from 100" in bodies,
          f"got {bodies}")

    # After reading, same pane gets nothing
    msgs_200_again = receive_messages(conn, "%200")
    check("receive_messages idempotent (no re-read)",
          len(msgs_200_again) == 0,
          f"expected 0, got {len(msgs_200_again)}")

    # A different pane sees only the broadcast (not the direct to %200)
    msgs_300 = receive_messages(conn, "%300")
    check("receive_messages broadcast to other pane",
          len(msgs_300) == 1,
          f"expected 1, got {len(msgs_300)}")
    check("receive_messages broadcast content",
          msgs_300[0]["body"] == "Broadcast from 100")

    # Same other pane gets nothing on second call (broadcast dedup)
    msgs_300_again = receive_messages(conn, "%300")
    check("receive_messages broadcast dedup",
          len(msgs_300_again) == 0,
          f"expected 0, got {len(msgs_300_again)}")

    # mark_read=False leaves messages unread
    send_message(conn, "%200", "%100", "Peek message")
    msgs_peek = receive_messages(conn, "%100", mark_read=False)
    check("receive_messages mark_read=False returns msg",
          len(msgs_peek) >= 1)
    msgs_peek2 = receive_messages(conn, "%100", mark_read=False)
    check("receive_messages mark_read=False preserves unread",
          len(msgs_peek2) >= 1)

    # Now actually consume it
    receive_messages(conn, "%100", mark_read=True)
    msgs_consumed = receive_messages(conn, "%100")
    check("receive_messages consumed after mark_read=True",
          len(msgs_consumed) == 0)

    # 9. deregister_agent — verify status becomes 'offline'
    deregister_agent(conn, "%200")
    a2_dereg = get_agent(conn, "%200")
    check("deregister_agent status offline",
          a2_dereg is not None and a2_dereg["status"] == "offline",
          f"got {a2_dereg['status'] if a2_dereg else 'None'}")
    check("deregister_agent preserves row",
          a2_dereg is not None)

    # 10. execute_with_retry — verify retry on locked
    lock_conn = get_connection(":memory:")
    init_schema(lock_conn)
    register_agent(lock_conn, "%lock_test", "claude")

    # Verify basic retry succeeds under normal conditions
    try:
        execute_with_retry(lock_conn, "UPDATE agents SET status = 'testing' WHERE pane_id = ?", ("%lock_test",))
        result = lock_conn.execute("SELECT status FROM agents WHERE pane_id = '%lock_test'").fetchone()
        check("execute_with_retry basic", result["status"] == "testing", f"got {result['status']}")
    except Exception as e:
        check("execute_with_retry basic", False, str(e))

    # Summary
    total = passed + failed
    print(f"\n{'=' * 50}")
    print(f"db.py self-test: {passed}/{total} passed, {failed} failed")
    if failed:
        print("FAIL")
        sys.exit(1)
    else:
        print("PASS")
        sys.exit(0)
