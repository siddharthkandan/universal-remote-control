#!/usr/bin/env python3
"""
teams_server.py — MCP server for Cross-CLI Teams Protocol.

Provides structured messaging, team management, and task dependencies
for coordination across Claude, Codex, and Gemini CLIs.

Usage:
    python3 urc/core/teams_server.py
    python3 urc/core/teams_server.py --self-test
"""

import os
import sys
import tempfile
from pathlib import Path
from typing import Optional

_project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

from mcp.server.fastmcp import FastMCP
from urc.core import teams_protocol as tp

try:
    from urc.core.jsonl_recovery import append_log as _append_log
except ImportError:
    def _append_log(*args, **kwargs):
        pass

mcp = FastMCP("urc-teams")


# ---------------------------------------------------------------------------
# MCP Middleware: Inbox Hint (Notification Layer 2)
# ---------------------------------------------------------------------------


def _peek_inbox_hint(pane_id: str) -> dict:
    """Non-destructive check for unread team messages via signal file.

    Returns inbox_hint dict if unread messages exist, empty dict otherwise.
    Does NOT mark messages as read or delete the signal file.
    """
    if not pane_id:
        return {}
    signal = Path(tp.INBOX_DIR) / f"{pane_id}.signal"
    if not signal.exists():
        return {}
    # Signal exists — peek at SQLite for count + preview
    try:
        conn = tp._get_conn()
        row = conn.execute(
            """SELECT COUNT(*) as cnt FROM messages
               WHERE to_pane = ? AND read = 0
               AND json_extract(body, '$.team') IS NOT NULL""",
            (pane_id,),
        ).fetchone()
        count = row["cnt"] if row else 0
        if count == 0:
            return {}
        # Get preview from most recent unread
        preview_row = conn.execute(
            """SELECT json_extract(body, '$.type') as mtype,
                      json_extract(body, '$.from_name') as sender,
                      json_extract(body, '$.team') as team
               FROM messages
               WHERE to_pane = ? AND read = 0
               AND json_extract(body, '$.team') IS NOT NULL
               ORDER BY id DESC LIMIT 1""",
            (pane_id,),
        ).fetchone()
        preview = f"{preview_row['mtype']} from {preview_row['sender']}" if preview_row else ""
        return {
            "inbox_hint": {
                "unread_count": count,
                "team": preview_row["team"] if preview_row else "",
                "preview": preview,
            }
        }
    except Exception:
        return {}


def _with_inbox_hint(result, pane_id: str = None):
    """Append inbox_hint to a dict tool result if unread messages exist.

    Skips list results to preserve homogeneous list contracts (callers
    iterating over [task, task, ...] would crash on a trailing hint dict).
    """
    if pane_id is None:
        pane_id = os.environ.get("TMUX_PANE", "")
    if not isinstance(result, dict):
        return result
    hint = _peek_inbox_hint(pane_id)
    if hint:
        result.update(hint)
    return result


# ---------------------------------------------------------------------------
# Team Management Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def team_create(team_name: str, description: str, lead_pane_id: str) -> dict:
    """Create a new team with the given name and lead agent."""
    try:
        result = tp.create_team(team_name, description, lead_pane_id)
        _append_log("team_create", lead_pane_id, {"team_name": team_name, "description": description})
        return result
    except Exception as e:
        return {"error": str(e), "tool": "team_create"}


@mcp.tool()
def team_delete(team_name: str) -> dict:
    """Delete a team by name."""
    try:
        result = tp.delete_team(team_name)
        _append_log("team_delete", "", {"team_name": team_name})
        return result
    except Exception as e:
        return {"error": str(e), "tool": "team_delete"}


@mcp.tool()
def team_add_member(team_name: str, pane_id: str, name: str, cli: str, role: str) -> dict:
    """Add a member to a team."""
    try:
        result = tp.add_member(team_name, pane_id, name, cli, role)
        _append_log("team_add_member", pane_id, {"team_name": team_name, "name": name, "cli": cli, "role": role})
        return result
    except Exception as e:
        return {"error": str(e), "tool": "team_add_member"}


@mcp.tool()
def team_remove_member(team_name: str, name: str) -> dict:
    """Remove a member from a team by name."""
    try:
        result = tp.remove_member(team_name, name)
        _append_log("team_remove_member", "", {"team_name": team_name, "name": name})
        return result
    except Exception as e:
        return {"error": str(e), "tool": "team_remove_member"}


@mcp.tool()
def team_status(team_name: str) -> dict:
    """Get team details with live agent status for each member."""
    try:
        return _with_inbox_hint(tp.get_team(team_name))
    except Exception as e:
        return {"error": str(e), "tool": "team_status"}


@mcp.tool()
def team_list() -> list:
    """List all teams with summary info (name, description, member count, status)."""
    try:
        return tp.list_teams()
    except Exception as e:
        return [{"error": str(e), "tool": "team_list"}]


# ---------------------------------------------------------------------------
# Messaging Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def team_send(from_name: str, to_name: str, team_name: str,
              msg_type: str, body: str, metadata: Optional[dict] = None,
              wake: bool = True) -> dict:
    """Send a typed message between team members.

    msg_type must be one of: message, task_assignment, status_update,
    completion, idle_notification, shutdown_request, shutdown_response,
    plan_approval_request, plan_approval_response.
    metadata is an optional dict of extra fields.
    wake: if True (default), send a tmux wake nudge to the recipient.
    """
    try:
        return tp.team_send(from_name, to_name, team_name, msg_type, body,
                            metadata, wake=wake)
    except Exception as e:
        return {"error": str(e), "tool": "team_send"}


@mcp.tool()
def team_inbox(name: str, team_name: str) -> list:
    """Get unread messages for a team member, filtered to this team."""
    try:
        return tp.team_inbox(name, team_name)
    except Exception as e:
        return [{"error": str(e), "tool": "team_inbox"}]


@mcp.tool()
def team_broadcast(from_name: str, team_name: str, msg_type: str, body: str) -> dict:
    """Broadcast a typed message to all team members except the sender."""
    try:
        return tp.team_broadcast(from_name, team_name, msg_type, body)
    except Exception as e:
        return {"error": str(e), "tool": "team_broadcast"}


# ---------------------------------------------------------------------------
# Task Dependency Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def team_task_create(team_name: str, title: str, description: str = "",
                     priority: int = 0, blocked_by: Optional[list] = None) -> dict:
    """Create a task with optional dependencies.

    blocked_by is a list of task IDs (e.g. [1, 3]) that must complete first.
    """
    try:
        result = tp.team_task_create(team_name, title, description, priority, blocked_by)
        _append_log("team_task_create", "", {"team_name": team_name, "title": title, "task_id": result.get("id")})
        return result
    except Exception as e:
        return {"error": str(e), "tool": "team_task_create"}


@mcp.tool()
def team_task_update(task_id: int, status: Optional[str] = None,
                     owner: Optional[str] = None,
                     add_blocks: Optional[list] = None,
                     add_blocked_by: Optional[list] = None) -> dict:
    """Update a task. When status='done', auto-unblocks dependent tasks.

    add_blocks and add_blocked_by are lists of task IDs.
    """
    try:
        result = tp.team_task_update(task_id, status, owner, add_blocks, add_blocked_by)
        _append_log("team_task_update", "", {"task_id": task_id, "status": status, "owner": owner})
        return result
    except Exception as e:
        return {"error": str(e), "tool": "team_task_update"}


@mcp.tool()
def team_task_list(team_name: str) -> list:
    """List all tasks for a team with dependency info."""
    try:
        return tp.team_task_list(team_name)
    except Exception as e:
        return [{"error": str(e), "tool": "team_task_list"}]


# ---------------------------------------------------------------------------
# Completion / Idle Signal Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def team_complete(name: str, team_name: str, task_id: Optional[int] = None,
                  summary: str = "") -> dict:
    """Signal task completion and notify team lead."""
    try:
        result = tp.team_complete(name, team_name, task_id, summary)
        _append_log("team_complete", "", {"team_name": team_name, "name": name, "task_id": task_id})
        return _with_inbox_hint(result)
    except Exception as e:
        return {"error": str(e), "tool": "team_complete"}


@mcp.tool()
def team_idle(name: str, team_name: str, reason: str = "available") -> dict:
    """Signal idle status and notify team lead."""
    try:
        return _with_inbox_hint(tp.team_idle(name, team_name, reason))
    except Exception as e:
        return {"error": str(e), "tool": "team_idle"}


# ---------------------------------------------------------------------------
# Notification Diagnostic Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def team_check_stale(team_name: str) -> list:
    """Detect stalled messages (delivery stall or ack stall) with recommended action."""
    try:
        return tp.detect_stalled_messages(team_name)
    except Exception as e:
        return [{"error": str(e), "tool": "team_check_stale"}]


@mcp.tool()
def team_retry_wake(message_id: int) -> dict:
    """Retry wake signal for a specific stalled message."""
    try:
        return tp.retry_wake(message_id)
    except Exception as e:
        return {"error": str(e), "tool": "team_retry_wake"}


@mcp.tool()
def team_auto_escalate(team_name: str) -> dict:
    """Detect stalls and escalate them to the team lead in one call."""
    try:
        return tp.team_auto_escalate(team_name)
    except Exception as e:
        return {"error": str(e), "tool": "team_auto_escalate"}


# ---------------------------------------------------------------------------
# Self-Test
# ---------------------------------------------------------------------------


def _run_self_test():
    """Smoke test all protocol functions with an in-memory DB and temp teams dir."""
    from urc.core.db import get_connection, init_schema, register_agent

    # Set up in-memory DB
    conn = get_connection(":memory:")
    init_schema(conn)
    tp._set_conn_for_test(conn)

    # Use a temp directory for team YAML
    with tempfile.TemporaryDirectory() as tmpdir:
        original_dir = tp.TEAMS_DIR
        tp.TEAMS_DIR = os.path.join(tmpdir, "teams")

        try:
            # Register test agents
            register_agent(conn, "%100", "claude-code", "lead", 1000, model="opus")
            register_agent(conn, "%101", "codex-cli", "engineer", 1001, model="codex")
            register_agent(conn, "%102", "gemini-cli", "researcher", 1002, model="gemini")

            # 1. Create team
            team = tp.create_team("test-team", "Self-test team", "%100")
            assert team["name"] == "test-team", f"Name mismatch: {team['name']}"
            assert team["lead"] == "%100"
            assert len(team["members"]) == 1
            print("  PASS: create_team")

            # 2. Add members
            tp.add_member("test-team", "%101", "engineer-1", "codex-cli", "engineer")
            tp.add_member("test-team", "%102", "researcher-1", "gemini-cli", "researcher")
            team = tp.get_team("test-team")
            assert len(team["members"]) == 3
            print("  PASS: add_member + get_team")

            # 3. Duplicate detection
            try:
                tp.add_member("test-team", "%103", "engineer-1", "claude-code", "engineer")
                assert False, "Should reject duplicate name"
            except ValueError:
                pass
            print("  PASS: duplicate name rejected")

            # 4. List teams
            teams = tp.list_teams()
            assert len(teams) == 1
            assert teams[0]["member_count"] == 3
            print("  PASS: list_teams")

            # 5. Name resolution
            assert tp._resolve_name("test-team", "engineer-1") == "%101"
            assert tp._resolve_pane("test-team", "%102") == "researcher-1"
            print("  PASS: name resolution")

            # 6. Messaging
            result = tp.team_send("lead", "engineer-1", "test-team", "task_assignment", "Fix bug X")
            assert result["type"] == "task_assignment"
            msgs = tp.team_inbox("engineer-1", "test-team")
            assert len(msgs) == 1
            assert msgs[0]["type"] == "task_assignment"
            assert msgs[0]["body"] == "Fix bug X"
            print("  PASS: team_send + team_inbox")

            # 7. Broadcast
            result = tp.team_broadcast("lead", "test-team", "status_update", "Sprint starts now")
            assert len(result["sent_to"]) == 2
            assert "lead" not in result["sent_to"]
            print("  PASS: team_broadcast")

            # 8. Task dependencies
            t1 = tp.team_task_create("test-team", "Setup infra", priority=5)
            t2 = tp.team_task_create("test-team", "Write code", blocked_by=[t1["id"]])
            t3 = tp.team_task_create("test-team", "Write tests", blocked_by=[t1["id"]])
            assert t2["blocked_by"] == [t1["id"]]
            print("  PASS: task creation with deps")

            # 9. Cycle detection
            try:
                tp.team_task_update(t1["id"], add_blocked_by=[t2["id"]])
                assert False, "Should reject cycle"
            except ValueError as e:
                assert "cycle" in str(e).lower()
            print("  PASS: cycle detection")

            # 10. Auto-unblock
            tp.team_task_update(t1["id"], status="done")
            tasks = tp.team_task_list("test-team")
            for t in tasks:
                if t["id"] == t2["id"]:
                    assert t["blocked_by"] == [], f"t2 should be unblocked: {t['blocked_by']}"
                if t["id"] == t3["id"]:
                    assert t["blocked_by"] == [], f"t3 should be unblocked: {t['blocked_by']}"
            print("  PASS: auto-unblock on completion")

            # 11. Completion signal
            result = tp.team_complete("engineer-1", "test-team", task_id=t2["id"], summary="Done")
            assert result["status"] == "completed"
            print("  PASS: team_complete")

            # 12. Idle signal
            result = tp.team_idle("researcher-1", "test-team", reason="waiting for work")
            assert result["status"] == "idle"
            print("  PASS: team_idle")

            # 13. Remove member
            tp.remove_member("test-team", "researcher-1")
            team = tp.get_team("test-team")
            assert len(team["members"]) == 2
            print("  PASS: remove_member")

            # 14. Delete team
            tp.delete_team("test-team")
            assert tp.list_teams() == []
            print("  PASS: delete_team")

            # 15. Invalid message type
            tp.create_team("test-team-2", "Validation test", "%100")
            tp.add_member("test-team-2", "%101", "eng", "codex", "engineer")
            try:
                tp.team_send("lead", "eng", "test-team-2", "invalid_type", "bad")
                assert False, "Should reject invalid type"
            except ValueError:
                pass
            tp.delete_team("test-team-2")
            print("  PASS: invalid message type rejected")

            print("\nPASS: teams_server self-test (15/15 checks)")

        finally:
            tp.TEAMS_DIR = original_dir


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        _run_self_test()
    else:
        mcp.run(transport="stdio")
