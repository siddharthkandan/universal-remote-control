"""
jsonl_recovery.py — JSONL crash-recovery log for URC state coordination.

Appends every coordination operation to a flat JSONL file so that the SQLite
database can be fully reconstructed after a crash or fresh boot.

Usage:
    from urc.core.jsonl_recovery import append_log, read_log, reconstruct_state

Design principles:
    - append_log: O_APPEND + immediate flush — crash-safe even mid-write
    - read_log: per-line try/except — a truncated final line is silently skipped
    - rotate_log: temp-file + atomic rename — no window where log is absent
"""

import json
import os
import sys
import time

# ---------------------------------------------------------------------------
# Default path
# ---------------------------------------------------------------------------

JSONL_PATH = ".urc/coordination.jsonl"

# ---------------------------------------------------------------------------
# Core log I/O
# ---------------------------------------------------------------------------


def append_log(op, pane_id, data, path=None):
    """Append one operation record to the JSONL log.

    Creates the parent directory if it does not exist. Flushes and syncs
    the file descriptor immediately so the record survives a process crash.

    Args:
        op:      Operation name string. One of: register, heartbeat,
                 claim_task, complete_task, create_task.
        pane_id: Tmux pane ID string (e.g. "%393").
        data:    Dict of operation-specific fields.
        path:    Override log path. Defaults to JSONL_PATH.
    """
    log_path = path or JSONL_PATH
    os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)

    record = {"ts": time.time(), "op": op, "pane": pane_id, "data": data}
    line = json.dumps(record, separators=(",", ":")) + "\n"

    with open(log_path, "a") as fh:
        fh.write(line)
        fh.flush()
        os.fsync(fh.fileno())


def read_log(path=None):
    """Parse all valid records from the JSONL log.

    Each line is parsed independently. Corrupt or truncated lines are
    silently skipped so a mid-write crash never prevents recovery.

    Args:
        path: Override log path. Defaults to JSONL_PATH.

    Returns:
        List of dicts, one per valid log record, in file order.
    """
    log_path = path or JSONL_PATH
    if not os.path.exists(log_path):
        return []

    entries = []
    with open(log_path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except (json.JSONDecodeError, ValueError):
                pass  # skip corrupt/partial line
    return entries


# ---------------------------------------------------------------------------
# State reconstruction
# ---------------------------------------------------------------------------


def reconstruct_state(log_entries):
    """Replay log entries to rebuild last-known in-memory state.

    Processes entries in order, updating state dicts so that each entry
    overwrites earlier state for the same entity.

    Supported ops:
        register      → agents[pane_id] = data
        heartbeat     → agents[pane_id].update(data)
        create_task   → tasks[task_id] = data
        claim_task    → tasks[task_id].update(data)
        complete_task → tasks[task_id].update(data)

    Args:
        log_entries: List of dicts from read_log().

    Returns:
        Dict with keys "agents" (dict keyed by pane_id) and
        "tasks" (dict keyed by task_id string).
    """
    state = {"agents": {}, "tasks": {}}

    for entry in log_entries:
        op = entry.get("op")
        pane = entry.get("pane")
        data = entry.get("data") or {}

        if op == "register":
            state["agents"][pane] = dict(data)

        elif op == "heartbeat":
            if pane not in state["agents"]:
                state["agents"][pane] = {}
            state["agents"][pane].update(data)

        elif op == "create_task":
            task_id = str(data.get("task_id", data.get("id", "")))
            if task_id:
                state["tasks"][task_id] = dict(data)

        elif op in ("claim_task", "complete_task"):
            task_id = str(data.get("task_id", data.get("id", "")))
            if task_id:
                if task_id not in state["tasks"]:
                    state["tasks"][task_id] = {}
                state["tasks"][task_id].update(data)

    return state


# ---------------------------------------------------------------------------
# SQLite replay
# ---------------------------------------------------------------------------


def replay_to_db(conn, log_entries):
    """Reconstruct the SQLite agents table by replaying JSONL entries.

    Only register and heartbeat ops are replayed — tasks are managed by
    create_task / claim_task / complete_task calls that carry their own
    atomic semantics in SQLite.

    Args:
        conn:        An open sqlite3.Connection (from coordination_db.get_connection).
        log_entries: List of dicts from read_log().
    """
    from urc.core.coordination_db import register_agent, update_heartbeat

    for entry in log_entries:
        op = entry.get("op")
        pane = entry.get("pane")
        data = entry.get("data") or {}

        try:
            if op == "register":
                register_agent(
                    conn,
                    pane_id=pane,
                    cli=data.get("cli", "unknown"),
                    role=data.get("role", "unknown"),
                    pid=data.get("pid"),
                    model=data.get("model"),
                )

            elif op == "heartbeat":
                update_heartbeat(
                    conn,
                    pane_id=pane,
                    context_pct=data.get("context_pct", 0.0),
                    status=data.get("status", "active"),
                )

        except Exception:
            # Non-fatal — skip entries that reference missing agents etc.
            pass


# ---------------------------------------------------------------------------
# Log rotation
# ---------------------------------------------------------------------------


def rotate_log(path=None, max_lines=10000):
    """Keep only the most recent max_lines records in the log.

    Uses an atomic temp-file + rename so the log is never absent. A no-op
    when the log has max_lines or fewer entries.

    Args:
        path:      Override log path. Defaults to JSONL_PATH.
        max_lines: Maximum number of lines to retain (default 10000).
    """
    log_path = path or JSONL_PATH
    if not os.path.exists(log_path):
        return

    with open(log_path, "r") as fh:
        lines = fh.readlines()

    if len(lines) <= max_lines:
        return

    keep = lines[-max_lines:]
    tmp_path = log_path + ".tmp"
    with open(tmp_path, "w") as fh:
        fh.writelines(keep)
        fh.flush()
        os.fsync(fh.fileno())

    os.replace(tmp_path, log_path)


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    if "--self-test" not in sys.argv:
        print("Usage: python3 jsonl_recovery.py --self-test")
        sys.exit(1)

    import tempfile
    from urc.core.coordination_db import (
        get_connection,
        init_schema,
        get_agent,
    )

    with tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False) as tf:
        tmp_log = tf.name

    try:
        # -- append and read back ------------------------------------------
        append_log("register", "%test1",
                   {"cli": "claude-code", "role": "engineer", "pid": 1001, "model": "sonnet"},
                   path=tmp_log)
        append_log("heartbeat", "%test1",
                   {"context_pct": 42.5, "status": "active"},
                   path=tmp_log)
        append_log("create_task", "%test1",
                   {"task_id": "1", "title": "Do work", "status": "pending"},
                   path=tmp_log)
        append_log("claim_task", "%test1",
                   {"task_id": "1", "status": "claimed", "claimed_by": "%test1"},
                   path=tmp_log)

        # inject a corrupt line to confirm skip logic
        with open(tmp_log, "a") as fh:
            fh.write("{broken json\n")

        append_log("complete_task", "%test1",
                   {"task_id": "1", "status": "done", "commit_sha": "abc123"},
                   path=tmp_log)

        entries = read_log(path=tmp_log)
        assert len(entries) == 5, f"Expected 5 valid entries, got {len(entries)}"

        # -- reconstruct_state ---------------------------------------------
        state = reconstruct_state(entries)
        assert "%test1" in state["agents"], "Agent missing from reconstructed state"
        agent = state["agents"]["%test1"]
        assert agent.get("context_pct") == 42.5, (
            f"Expected context_pct=42.5, got {agent.get('context_pct')}"
        )
        assert "1" in state["tasks"], "Task missing from reconstructed state"
        assert state["tasks"]["1"]["status"] == "done", (
            f"Expected done, got {state['tasks']['1']['status']}"
        )

        # -- replay_to_db --------------------------------------------------
        conn = get_connection(":memory:")
        init_schema(conn)
        replay_to_db(conn, entries)
        db_agent = get_agent(conn, "%test1")
        assert db_agent is not None, "Agent not found in DB after replay"
        assert db_agent["cli"] == "claude-code", (
            f"Expected cli=claude-code, got {db_agent['cli']}"
        )
        conn.close()

        # -- rotation ------------------------------------------------------
        with tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False, mode="w") as rf:
            rot_log = rf.name
            for i in range(150):
                rf.write(json.dumps({"ts": time.time(), "op": "heartbeat",
                                     "pane": f"%p{i}", "data": {}}) + "\n")

        rotate_log(path=rot_log, max_lines=100)
        rotated = read_log(path=rot_log)
        assert len(rotated) == 100, f"Expected 100 after rotation, got {len(rotated)}"
        # verify last entry is preserved (p149)
        assert rotated[-1]["pane"] == "%p149", (
            f"Expected %p149 as last entry, got {rotated[-1]['pane']}"
        )

        os.unlink(rot_log)

    finally:
        if os.path.exists(tmp_log):
            os.unlink(tmp_log)

    print("PASS: jsonl_recovery self-test")
    sys.exit(0)
