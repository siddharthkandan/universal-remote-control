#!/usr/bin/env python3
"""
coordination_server.py — MCP server for URC state coordination.

Wraps coordination_db and jsonl_recovery as MCP tools over STDIO transport.
Agents register, send heartbeats, and query health via this server.

16 tools: register_agent, heartbeat, health_check, claim_task, complete_task,
send_message, receive_messages, get_fleet_status, report_event, rename_agent,
dispatch_to_pane, read_pane_output, kill_pane, relay_forward, relay_read,
bootstrap_validate.

Usage (normal):
    python3 urc/core/coordination_server.py

Usage (self-test):
    python3 urc/core/coordination_server.py --self-test
"""

import json
import os
import subprocess
import sys
import time
from typing import Optional

# Ensure project root is on sys.path when run directly (e.g. python3 urc/core/...)
_project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Server instance + startup time
# ---------------------------------------------------------------------------

mcp = FastMCP("urc-coordination")

_SERVER_START = time.time()

# Auto-registration: register this pane on first MCP tool call
_auto_registered = False


def _ensure_registered():
    """Auto-register the calling pane on first use. No-op if not in tmux."""
    global _auto_registered
    if _auto_registered:
        return
    pane_id = os.environ.get("TMUX_PANE")
    if not pane_id:
        _auto_registered = True  # no tmux — skip permanently
        return
    try:
        from urc.core.coordination_db import register_agent as db_register_agent
        conn = _get_conn()
        db_register_agent(conn, pane_id, "claude-code", "mcp-server", os.getpid(), None)
        _auto_registered = True
    except Exception:
        pass  # best-effort — never break tool calls


# Detect the tmux pane this server is running in (for reply_to auto-detect).
_server_pane: Optional[str] = os.environ.get("TMUX_PANE")
if not _server_pane:
    try:
        _pane_check = subprocess.run(
            ["tmux", "display-message", "-p", "#{pane_id}"],
            capture_output=True, text=True, timeout=3,
        )
        if _pane_check.returncode == 0 and _pane_check.stdout.strip().startswith("%"):
            _server_pane = _pane_check.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

# Module-level connection — lazily initialized on first use
_conn = None


def _get_conn():
    """Return the shared SQLite connection, initializing on first call."""
    global _conn
    if _conn is None:
        from urc.core.coordination_db import get_connection, init_schema
        _conn = get_connection()
        init_schema(_conn)
    return _conn


# ---------------------------------------------------------------------------
# Inline pane dispatch helper (replaces TmuxRuntime.send())
# ---------------------------------------------------------------------------

_HELPER_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tmux-send-helper.sh")


def _pane_exists(pane_id: str) -> bool:
    """Return True if pane_id exists in tmux, False otherwise."""
    try:
        r = subprocess.run(
            ["tmux", "display-message", "-t", pane_id, "-p", "#{pane_id}"],
            capture_output=True, timeout=5, text=True,
        )
        return r.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False


def _send_to_pane(pane_id: str, message: str, force: bool = False) -> dict:
    """Send a message to a tmux pane via tmux-send-helper.sh.

    Returns dict with 'status' key: delivered, uncertain, queued, or failed.
    """
    if not _pane_exists(pane_id):
        return {"status": "failed", "error": f"Pane {pane_id} does not exist in tmux"}

    cmd = ["bash", _HELPER_PATH, pane_id, message, "--verify"]
    if force:
        cmd.append("--force")

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return {"status": "failed", "error": "Dispatch timed out (30s)"}
    except (FileNotFoundError, OSError) as exc:
        return {"status": "failed", "error": f"Cannot run helper: {exc}"}

    # Parse helper JSON stdout
    helper_response: dict = {}
    if result.stdout and result.stdout.strip():
        try:
            helper_response = json.loads(result.stdout.strip())
        except json.JSONDecodeError:
            helper_response = {"raw_stdout": result.stdout.strip()[:200]}

    if result.returncode == 3:
        return {
            "status": "queued",
            "warning": "target is PROCESSING; message NOT sent (use force=True to override)",
        }
    if result.returncode == 4:
        return {"status": "failed", "error": helper_response.get("error", "cross-group send blocked")}
    if result.returncode == 2:
        return {"status": "uncertain", "warning": "delivery timed out — pane content did not change"}
    if result.returncode == 1:
        stderr = result.stderr.strip()[:200] if result.stderr else ""
        return {"status": "failed", "error": helper_response.get("error", stderr or "helper failed")}

    # returncode == 0 — delivered
    warning = helper_response.get("warning")
    resp: dict = {"status": "delivered"}
    if warning:
        resp["status"] = "uncertain"
        resp["warning"] = warning
    return resp


def _get_bridge_target(my_pane: str) -> Optional[str]:
    """Read @bridge_target tmux pane option for a relay pane.

    Returns the target pane ID (e.g. '%856') or None if not set.
    """
    try:
        result = subprocess.run(
            ["tmux", "show-options", "-pv", "-t", my_pane, "@bridge_target"],
            capture_output=True, text=True, timeout=5,
        )
        target = result.stdout.strip()
        if target and target.startswith("%"):
            return target
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None


# ---------------------------------------------------------------------------
# Tool 1: register_agent
# ---------------------------------------------------------------------------


@mcp.tool()
def register_agent(
    pane_id: str,
    cli: str,
    role: str,
    pid: int,
    model: Optional[str] = None,
) -> dict:
    """Register or re-register an agent with the coordination server.

    Args:
        pane_id: Tmux pane ID (e.g. "%393").
        cli:     CLI type (e.g. "claude-code", "gemini-cli", "codex").
        role:    Agent role (e.g. "engineer", "researcher").
        pid:     Process ID of the agent.
        model:   Optional model name hint (e.g. "opus", "sonnet").
    """
    try:
        from urc.core.coordination_db import (
            register_agent as db_register_agent,
        )
        from urc.core.jsonl_recovery import append_log

        conn = _get_conn()
        db_register_agent(conn, pane_id, cli, role, pid, model)
        append_log("register", pane_id, {"cli": cli, "role": role, "pid": pid, "model": model})

        return {"status": "registered", "pane_id": pane_id}

    except Exception as e:
        return {"error": str(e), "tool": "register_agent"}


# ---------------------------------------------------------------------------
# Tool 2: heartbeat
# ---------------------------------------------------------------------------


@mcp.tool()
def heartbeat(
    pane_id: str,
    context_pct: float,
    status: str = "active",
) -> dict:
    """Send a heartbeat update for an agent.

    Args:
        pane_id:     Tmux pane ID.
        context_pct: Current context usage percentage (0-100).
        status:      Agent status string (default "active").
    """
    try:
        from urc.core.coordination_db import update_heartbeat
        from urc.core.jsonl_recovery import append_log

        conn = _get_conn()
        update_heartbeat(conn, pane_id, context_pct, status)
        append_log("heartbeat", pane_id, {"context_pct": context_pct, "status": status})

        return {"status": "ok", "pane_id": pane_id}

    except Exception as e:
        return {"error": str(e), "tool": "heartbeat"}


# ---------------------------------------------------------------------------
# Tool 3: health_check
# ---------------------------------------------------------------------------


@mcp.tool()
def health_check() -> dict:
    """Return server health metrics and database statistics.

    Returns uptime, DB size, and counts of agents, tasks, and messages.
    """
    try:
        from urc.core.coordination_db import DB_PATH

        conn = _get_conn()

        db_size = 0
        try:
            db_size = os.path.getsize(DB_PATH)
        except OSError:
            pass

        agent_count = len(conn.execute("SELECT 1 FROM agents").fetchall())
        task_count = len(conn.execute("SELECT 1 FROM tasks").fetchall())
        message_count = len(conn.execute("SELECT 1 FROM messages").fetchall())

        return {
            "uptime_seconds": round(time.time() - _SERVER_START, 2),
            "db_size_bytes": db_size,
            "agent_count": agent_count,
            "task_count": task_count,
            "message_count": message_count,
        }

    except Exception as e:
        return {"error": str(e), "tool": "health_check"}


# ---------------------------------------------------------------------------
# Tool 4: claim_task
# ---------------------------------------------------------------------------


@mcp.tool()
def claim_task(pane_id: str) -> dict:
    """Claim the highest-priority pending task for the given agent.

    Args:
        pane_id: Tmux pane ID of the claiming agent (e.g. "%393").
    """
    try:
        from urc.core.coordination_db import claim_task as db_claim_task
        from urc.core.jsonl_recovery import append_log

        conn = _get_conn()
        row = db_claim_task(conn, pane_id)
        if row is None:
            return {"result": None}

        task = dict(row)
        append_log("claim_task", pane_id, {"task_id": task["id"], "title": task["title"]})
        return task

    except Exception as e:
        return {"error": str(e), "tool": "claim_task"}


# ---------------------------------------------------------------------------
# Tool 5: complete_task
# ---------------------------------------------------------------------------


@mcp.tool()
def complete_task(task_id: int, commit_sha: Optional[str] = None) -> dict:
    """Mark a claimed task as completed.

    Args:
        task_id:    ID of the task to complete.
        commit_sha: Optional git commit SHA associated with the completion.
    """
    try:
        from urc.core.coordination_db import complete_task as db_complete_task
        from urc.core.jsonl_recovery import append_log

        conn = _get_conn()
        db_complete_task(conn, task_id, commit_sha)
        append_log("complete_task", "", {"task_id": task_id, "commit_sha": commit_sha})
        return {"status": "completed", "task_id": task_id}

    except Exception as e:
        return {"error": str(e), "tool": "complete_task"}


# ---------------------------------------------------------------------------
# Tool 6: send_message
# ---------------------------------------------------------------------------


@mcp.tool()
def send_message(from_pane: str, body: str, to_pane: Optional[str] = None) -> dict:
    """Send a message from one agent to another, or broadcast to all agents.

    Args:
        from_pane: Tmux pane ID of the sending agent.
        body:      Message body text.
        to_pane:   Tmux pane ID of the recipient. Omit or pass None for broadcast.
    """
    _ensure_registered()
    try:
        from urc.core.coordination_db import send_message as db_send_message
        from urc.core.jsonl_recovery import append_log

        conn = _get_conn()
        msg_id = db_send_message(conn, from_pane, to_pane, body)
        append_log("send_message", from_pane, {"to_pane": to_pane, "body": body})

        # Best-effort tmux wake signal to nudge idle recipient
        wake_status = None
        if to_pane and to_pane != from_pane and _server_pane:
            try:
                nudge = f'You have an unread message from {from_pane}. Use receive_messages to read it.'
                result = subprocess.run(
                    ['bash', _HELPER_PATH, to_pane, nudge, '--force', '--verify'],
                    capture_output=True, text=True, timeout=15,
                )
                wake_status = 'nudged' if result.returncode == 0 else 'failed'
            except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
                wake_status = 'failed'

        return {"status": "sent", "message_id": msg_id, "wake": wake_status}

    except Exception as e:
        return {"error": str(e), "tool": "send_message"}


# ---------------------------------------------------------------------------
# Tool 7: receive_messages
# ---------------------------------------------------------------------------


@mcp.tool()
def receive_messages(pane_id: str) -> dict:
    """Receive unread messages for an agent (direct messages + broadcasts).

    Marks messages as read atomically. Read-only from the caller's perspective —
    no JSONL entry is written.

    Args:
        pane_id: Tmux pane ID of the receiving agent.
    """
    try:
        from urc.core.coordination_db import receive_messages as db_receive_messages

        conn = _get_conn()
        msgs = db_receive_messages(conn, pane_id)
        return {"messages": [dict(m) for m in msgs]}

    except Exception as e:
        return {"error": str(e), "tool": "receive_messages"}


# ---------------------------------------------------------------------------
# MCP Resource: inbox
# ---------------------------------------------------------------------------


@mcp.resource("inbox://{pane_id}")
async def relay_inbox(pane_id: str) -> str:
    """Inbox resource for a pane. Returns recent messages as JSON."""
    try:
        conn = _get_conn()
        msgs = conn.execute(
            "SELECT id, from_pane, body, created_at FROM messages WHERE to_pane = ? OR to_pane IS NULL ORDER BY created_at DESC",
            (pane_id,)
        ).fetchall()
        return json.dumps([dict(m) for m in msgs])
    except Exception as e:
        return json.dumps({"error": str(e)})


# ---------------------------------------------------------------------------
# Tool 8: get_fleet_status
# ---------------------------------------------------------------------------


@mcp.tool()
def get_fleet_status() -> dict:
    """Return the status of all registered agents in the fleet.

    Read-only — no JSONL entry is written.

    Returns a list of agent dicts with computed heartbeat age.
    """
    _ensure_registered()
    try:
        from urc.core.coordination_db import list_agents

        conn = _get_conn()
        rows = list_agents(conn)
        now = time.time()

        agents = []
        for row in rows:
            r = dict(row)
            last_hb = r.get("last_heartbeat") or 0.0
            agents.append({
                "pane_id": r.get("pane_id", ""),
                "cli": r.get("cli", ""),
                "role": r.get("role", ""),
                "status": r.get("status", ""),
                "context_pct": float(r.get("context_pct") or 0.0),
                "heartbeat_age_seconds": round(now - float(last_hb), 3),
                "health": r.get("health", ""),
                "model": r.get("model", ""),
                "label": r.get("label", ""),
            })

        return {"agents": agents}

    except Exception as e:
        return {"error": str(e), "tool": "get_fleet_status"}


# ---------------------------------------------------------------------------
# Tool 9: report_event
# ---------------------------------------------------------------------------


@mcp.tool()
def report_event(
    pane_id: str,
    event_type: str,
    data: Optional[str] = None,
) -> dict:
    """Record a structured event for an agent.

    Args:
        pane_id:    Tmux pane ID of the reporting agent.
        event_type: Event type string (e.g. "context_warning", "task_started").
        data:       Optional JSON string with additional event payload.
    """
    try:
        from urc.core.coordination_db import report_event as db_report_event
        from urc.core.jsonl_recovery import append_log

        # Auto-convert dict/list data to JSON string
        if data is not None and not isinstance(data, str):
            data = json.dumps(data)

        conn = _get_conn()
        evt_id = db_report_event(conn, pane_id, event_type, data)
        append_log("report_event", pane_id, {"event_type": event_type, "data": data})
        return {"status": "recorded", "event_id": evt_id}

    except Exception as e:
        return {"error": str(e), "tool": "report_event"}


# ---------------------------------------------------------------------------
# Tool 10: rename_agent
# ---------------------------------------------------------------------------


@mcp.tool()
def rename_agent(pane_id: str, label: str) -> dict:
    """Set or clear a display label for an agent.

    Args:
        pane_id: Tmux pane ID (e.g. "%633").
        label:   Display label (e.g. "Research"). Empty string clears it.
    """
    try:
        from urc.core.coordination_db import (
            get_agent, update_agent_label,
        )
        from urc.core.jsonl_recovery import append_log

        conn = _get_conn()
        agent = get_agent(conn, pane_id)
        if agent is None:
            return {"error": f"No agent registered for {pane_id}", "tool": "rename_agent"}

        update_agent_label(conn, pane_id, label)
        append_log("rename_agent", pane_id, {"label": label})
        return {"status": "renamed", "pane_id": pane_id, "label": label or None}

    except Exception as e:
        return {"error": str(e), "tool": "rename_agent"}


# ---------------------------------------------------------------------------
# Tool 11: dispatch_to_pane
# ---------------------------------------------------------------------------


@mcp.tool()
def dispatch_to_pane(pane_id: str, message: str, force: bool = False) -> dict:
    """Send a message to an existing tmux pane via tmux-send-helper.sh.

    Validates pane exists via tmux before dispatching. Returns delivery
    certainty via a 3-phase policy (admission, delivery, emergency override).

    Possible return statuses:
        delivered  — helper confirmed content change in target pane.
        uncertain  — helper delivered but with a warning (e.g. target was
                     PROCESSING) or delivery timed out without confirmation.
        queued     — target is PROCESSING and force was not set; message
                     was NOT sent.
        failed     — pane does not exist, helper error, or other failure.

    Note: Messages over ~1000 characters may be silently truncated by tmux
    paste buffers. The tool may still report "delivered" even when the full
    message did not arrive. For long content (handoffs, detailed tasks,
    multi-step instructions), write to a uniquely-named file and dispatch a
    short reference instead:
      - Naming: .urc/handoff-{FROM}-to-{TO}.md (e.g. .urc/handoff-896-to-906.md)
      - Strip the % from pane IDs in filenames
      - Then dispatch: "Read .urc/handoff-896-to-906.md for full context"

    Args:
        pane_id: Tmux pane ID (e.g. "%391").
        message: The message/task to send to the pane.
        force:   When True, send with --force (bypasses PROCESSING block)
                 but still parse and return any warning from the helper.
    """
    _ensure_registered()
    try:
        result = _send_to_pane(pane_id, message, force=force)

        # Append JSONL audit entry for delivered and uncertain outcomes
        status = result.get("status", "")
        if status in ("delivered", "uncertain"):
            from urc.core.jsonl_recovery import append_log
            log_data: dict = {"message": message[:200]}
            if result.get("warning"):
                log_data["warning"] = result["warning"]
            append_log("dispatch_to_pane", pane_id, log_data)

        return result

    except Exception as e:
        return {
            "status": "failed",
            "error": str(e),
            "tool": "dispatch_to_pane",
        }


# ---------------------------------------------------------------------------
# Tool 12: read_pane_output
# ---------------------------------------------------------------------------


@mcp.tool()
def read_pane_output(pane_id: str, lines: int = 30) -> dict:
    """Capture recent visible output from a tmux pane's buffer.

    Use this AFTER dispatch_to_pane to read the target's response.
    The relay pattern is: send message -> wait -> read_pane_output.

    Read-only — no JSONL entry.

    Args:
        pane_id: Tmux pane ID to read from (e.g. "%391").
        lines:   Number of lines to capture from the bottom (default 30, max 200).
    """
    try:
        n = min(max(lines, 1), 200)

        result = subprocess.run(
            ["tmux", "capture-pane", "-t", pane_id, "-p", "-S", f"-{n}"],
            capture_output=True, text=True, timeout=10,
        )

        if result.returncode != 0:
            return {"error": f"capture-pane failed: {result.stderr.strip()[:200]}", "tool": "read_pane_output"}

        output = result.stdout
        # Trim leading empty lines
        output_lines = output.split("\n")
        while output_lines and not output_lines[0].strip():
            output_lines.pop(0)
        output = "\n".join(output_lines)

        return {
            "pane_id": pane_id,
            "output": output,
            "line_count": len(output_lines),
        }

    except subprocess.TimeoutExpired:
        return {"error": "capture-pane timed out (10s)", "tool": "read_pane_output"}
    except Exception as e:
        return {"error": str(e), "tool": "read_pane_output"}


# ---------------------------------------------------------------------------
# Tool 13: kill_pane
# ---------------------------------------------------------------------------


@mcp.tool()
def kill_pane(pane_id: str, confirm: bool = False) -> dict:
    """Kill a tmux pane. REQUIRES explicit confirmation.

    Args:
        pane_id: Tmux pane ID to kill (e.g. "%391").
        confirm: Must be True to actually kill. Returns warning if False.
    """
    try:
        if not confirm:
            return {
                "status": "confirmation_required",
                "warning": f"This will kill pane {pane_id} and terminate any running process. "
                           f"Call again with confirm=true to proceed.",
                "pane_id": pane_id,
            }

        # Validate pane exists
        pane_check = subprocess.run(
            ["tmux", "display-message", "-t", pane_id, "-p", "#{pane_id}"],
            capture_output=True, timeout=5, text=True,
        )
        if pane_check.returncode != 0:
            return {"error": f"Pane {pane_id} does not exist", "tool": "kill_pane"}

        result = subprocess.run(
            ["tmux", "kill-pane", "-t", pane_id],
            capture_output=True, text=True, timeout=10,
        )

        if result.returncode == 0:
            from urc.core.jsonl_recovery import append_log
            append_log("kill_pane", pane_id, {"confirmed": True})
            return {"status": "killed", "pane_id": pane_id}
        else:
            return {
                "error": f"kill-pane failed: {result.stderr.strip()[:200]}",
                "tool": "kill_pane",
            }

    except subprocess.TimeoutExpired:
        return {"error": "kill-pane timed out", "tool": "kill_pane"}
    except Exception as e:
        return {"error": str(e), "tool": "kill_pane"}


# ---------------------------------------------------------------------------
# Tool 14: relay_forward
# ---------------------------------------------------------------------------


@mcp.tool()
def relay_forward(my_pane: str, message: str, force: bool = False) -> dict:
    """Forward a message to this relay's bridge target pane.

    Reads @bridge_target from tmux pane options for my_pane, then dispatches
    to that target. The relay never chooses the target — it is structurally
    locked to the pane set during bootstrap.

    If the first dispatch returns 'queued' (target is PROCESSING), automatically
    retries with force=true.

    Args:
        my_pane: Tmux pane ID of the relay (e.g. "%860"). Used to look up
                 the bridge target from pane options.
        message: The message to forward verbatim to the target pane.
        force:   When True, bypass PROCESSING check on first attempt.
    """
    _ensure_registered()
    try:
        target = _get_bridge_target(my_pane)
        if not target:
            return {"error": "no @bridge_target set for pane", "tool": "relay_forward"}

        result = _send_to_pane(target, message, force=force)

        # Auto-retry with force if target was PROCESSING
        if result.get("status") == "queued" and not force:
            result = _send_to_pane(target, message, force=True)
            result["auto_forced"] = True

        # JSONL audit for successful dispatches
        status = result.get("status", "")
        if status in ("delivered", "uncertain"):
            from urc.core.jsonl_recovery import append_log
            log_data: dict = {
                "relay": my_pane,
                "target": target,
                "message": message[:200],
            }
            if result.get("warning"):
                log_data["warning"] = result["warning"]
            if result.get("auto_forced"):
                log_data["auto_forced"] = True
            append_log("relay_forward", my_pane, log_data)

        result["target"] = target
        return result

    except Exception as e:
        return {"status": "failed", "error": str(e), "tool": "relay_forward"}


# ---------------------------------------------------------------------------
# Tool 15: relay_read
# ---------------------------------------------------------------------------


@mcp.tool()
def relay_read(my_pane: str, lines: int = 100) -> dict:
    """Read recent output from this relay's bridge target pane.

    Reads @bridge_target from tmux pane options for my_pane, then captures
    the target pane's buffer. The relay never chooses which pane to read —
    it is structurally locked.

    Args:
        my_pane: Tmux pane ID of the relay (e.g. "%860").
        lines:   Number of lines to capture from the bottom (default 100, max 200).
    """
    try:
        target = _get_bridge_target(my_pane)
        if not target:
            return {"error": "no @bridge_target set for pane", "tool": "relay_read"}

        n = min(max(lines, 1), 200)

        result = subprocess.run(
            ["tmux", "capture-pane", "-t", target, "-p", "-S", f"-{n}"],
            capture_output=True, text=True, timeout=10,
        )

        if result.returncode != 0:
            return {
                "error": f"capture-pane failed: {result.stderr.strip()[:200]}",
                "tool": "relay_read",
            }

        output = result.stdout
        output_lines = output.split("\n")
        while output_lines and not output_lines[0].strip():
            output_lines.pop(0)
        output = "\n".join(output_lines)

        return {
            "target": target,
            "output": output,
            "line_count": len(output_lines),
        }

    except subprocess.TimeoutExpired:
        return {"error": "capture-pane timed out (10s)", "tool": "relay_read"}
    except Exception as e:
        return {"error": str(e), "tool": "relay_read"}


@mcp.tool()
def bootstrap_validate() -> dict:
    """Validate URC setup: CWD, directories, hook configs, tmux, MCP servers.
    Call this before any cross-CLI operation to catch setup issues early.
    """
    issues = []
    # 1. Check CWD contains urc/core/
    if not os.path.isdir(os.path.join(_project_root, "urc", "core")):
        issues.append({"severity": "error", "check": "cwd",
                       "message": f"URC project root not found. CWD: {_project_root}"})
    # 2. Check/create .urc/ directories
    for d in ["responses", "signals", "streams", "locks", "timeout"]:
        path = os.path.join(_project_root, ".urc", d)
        if not os.path.isdir(path):
            os.makedirs(path, exist_ok=True)
            issues.append({"severity": "fixed", "check": f"dir_{d}",
                           "message": f"Created missing directory: .urc/{d}"})
    # 3. Check tmux is accessible
    try:
        subprocess.run(["tmux", "list-sessions"], capture_output=True, timeout=3)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        issues.append({"severity": "error", "check": "tmux",
                       "message": "tmux not accessible"})
    # 4. Check hook script exists
    hook_path = os.path.join(_project_root, "urc", "core", "turn-complete-hook.sh")
    if not os.path.isfile(hook_path):
        issues.append({"severity": "error", "check": "hook",
                       "message": "turn-complete-hook.sh not found"})
    # 5. Check dispatch-and-wait.sh exists
    daw_path = os.path.join(_project_root, "urc", "core", "dispatch-and-wait.sh")
    if not os.path.isfile(daw_path):
        issues.append({"severity": "warning", "check": "dispatch_and_wait",
                       "message": "dispatch-and-wait.sh not found"})
    # 6. Check lib-cli.sh exists
    lib_path = os.path.join(_project_root, "urc", "core", "lib-cli.sh")
    if not os.path.isfile(lib_path):
        issues.append({"severity": "warning", "check": "lib_cli",
                       "message": "lib-cli.sh not found"})
    errors = [i for i in issues if i["severity"] == "error"]
    return {"valid": len(errors) == 0, "issues": issues, "project_root": _project_root}


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------


def _run_self_test():
    """Exercise all 16 tools via direct function calls against in-memory DB."""
    import tempfile
    from urc.core.coordination_db import (
        get_connection, init_schema, get_agent, create_task,
    )
    from urc.core.jsonl_recovery import read_log

    # Override module-level connection to use in-memory DB
    global _conn
    _conn = get_connection(":memory:")
    init_schema(_conn)

    with tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False) as tf:
        tmp_jsonl = tf.name

    import urc.core.jsonl_recovery as jrl
    _orig_append = jrl.append_log

    def _patched_append(op, pane_id, data, path=None):
        return _orig_append(op, pane_id, data, path=tmp_jsonl)

    jrl.append_log = _patched_append

    try:
        # ── Tool 1: register_agent ─────────────────────────────────────────
        result = register_agent(
            pane_id="%test",
            cli="claude-code",
            role="engineer",
            pid=os.getpid(),
            model="sonnet",
        )
        assert result.get("status") == "registered", f"register_agent failed: {result}"
        assert result.get("pane_id") == "%test", f"Wrong pane_id: {result}"

        agent = get_agent(_conn, "%test")
        assert agent is not None, "Agent not found in DB after register_agent"
        assert agent["cli"] == "claude-code", f"Unexpected cli: {agent['cli']}"

        # ── Tool 2: heartbeat ──────────────────────────────────────────────
        hb_result = heartbeat(pane_id="%test", context_pct=55.0, status="active")
        assert hb_result.get("status") == "ok", f"heartbeat failed: {hb_result}"

        updated = get_agent(_conn, "%test")
        assert updated["context_pct"] == 55.0, f"context_pct not updated: {updated['context_pct']}"

        # ── Tool 3: health_check ───────────────────────────────────────────
        hc_result = health_check()
        required_keys = {
            "uptime_seconds", "db_size_bytes", "agent_count",
            "task_count", "message_count",
        }
        missing = required_keys - set(hc_result.keys())
        assert not missing, f"health_check missing keys: {missing}"
        assert hc_result["agent_count"] == 1, f"Expected 1 agent, got {hc_result['agent_count']}"

        # ── Tool 4: claim_task ─────────────────────────────────────────────
        create_task(_conn, "Test task", priority=5)
        ct_result = claim_task("%test")
        assert "error" not in ct_result, f"claim_task returned error: {ct_result}"
        assert ct_result.get("title") == "Test task"
        claimed_task_id = ct_result["id"]

        empty_claim = claim_task("%test")
        assert empty_claim == {"result": None}

        # ── Tool 5: complete_task ──────────────────────────────────────────
        comp_result = complete_task(claimed_task_id, commit_sha="abc123")
        assert comp_result.get("status") == "completed", f"complete_task failed: {comp_result}"

        # ── Tool 6: send_message ───────────────────────────────────────────
        sm_result = send_message(from_pane="%test", to_pane="%other", body="Hello")
        assert sm_result.get("status") == "sent", f"send_message failed: {sm_result}"
        assert "message_id" in sm_result

        # ── Tool 7: receive_messages ───────────────────────────────────────
        rm_result = receive_messages("%other")
        assert "messages" in rm_result
        msgs = rm_result["messages"]
        assert len(msgs) == 1, f"Expected 1 message for %other, got {len(msgs)}"
        assert msgs[0]["body"] == "Hello"

        rm_result2 = receive_messages("%other")
        assert rm_result2["messages"] == [], "Expected empty inbox after read"

        # ── Tool 8: get_fleet_status ───────────────────────────────────────
        fs_result = get_fleet_status()
        assert "agents" in fs_result
        assert len(fs_result["agents"]) >= 1

        # ── Tool 9: report_event ───────────────────────────────────────────
        re_result = report_event("%test", "context_warning", '{"pct": 80}')
        assert re_result.get("status") == "recorded"
        assert "event_id" in re_result

        # ── Tool 10: rename_agent ──────────────────────────────────────────
        rn_result = rename_agent(pane_id="%test", label="Research")
        assert rn_result.get("status") == "renamed"
        assert rn_result.get("label") == "Research"
        rn_bad = rename_agent(pane_id="%nonexistent", label="X")
        assert "error" in rn_bad

        # ── Verify JSONL entries ───────────────────────────────────────────
        entries = read_log(path=tmp_jsonl)
        ops = [e["op"] for e in entries]
        assert "register" in ops, f"JSONL missing 'register'; ops={ops}"
        assert "heartbeat" in ops
        assert "claim_task" in ops
        assert "complete_task" in ops
        assert "send_message" in ops
        assert "report_event" in ops
        assert "rename_agent" in ops
        assert "receive_messages" not in ops
        assert "get_fleet_status" not in ops
        assert len(entries) >= 6

    finally:
        jrl.append_log = _orig_append
        if os.path.exists(tmp_jsonl):
            os.unlink(tmp_jsonl)

        # ── Tool 11: dispatch_to_pane (tmux-dependent) ─────────────────
        dtp_result = dispatch_to_pane("%nonexistent_test_pane", "hello")
        assert isinstance(dtp_result, dict), f"dispatch_to_pane returned non-dict"
        assert "error" in dtp_result or "status" in dtp_result

        # ── Tool 12: read_pane_output (tmux-dependent) ─────────────────
        # Just verify it handles missing panes gracefully
        rpo_result = read_pane_output("%nonexistent_test_pane", lines=5)
        assert isinstance(rpo_result, dict), f"read_pane_output returned non-dict"

        # ── Tool 13: kill_pane (no-confirm gate) ───────────────────────
        kp_result = kill_pane("%nonexistent_test_pane", confirm=False)
        assert kp_result.get("status") == "confirmation_required"
        assert "warning" in kp_result

        # ── Tool 14: relay_forward (no bridge target) ────────────────
        rf_result = relay_forward(my_pane="%nonexistent_relay", message="hello")
        assert isinstance(rf_result, dict), "relay_forward returned non-dict"
        assert rf_result.get("error") == "no @bridge_target set for pane", (
            f"Expected bridge_target error, got: {rf_result}"
        )
        assert rf_result.get("tool") == "relay_forward"

        # ── Tool 15: relay_read (no bridge target) ───────────────────
        rr_result = relay_read(my_pane="%nonexistent_relay", lines=10)
        assert isinstance(rr_result, dict), "relay_read returned non-dict"
        assert rr_result.get("error") == "no @bridge_target set for pane", (
            f"Expected bridge_target error, got: {rr_result}"
        )
        assert rr_result.get("tool") == "relay_read"

        # ── Tool 16: bootstrap_validate ──────────────────────────────
        bv_result = bootstrap_validate()
        assert isinstance(bv_result, dict), "bootstrap_validate returned non-dict"
        assert "valid" in bv_result, f"bootstrap_validate missing 'valid' key: {bv_result}"
        assert "project_root" in bv_result

    print("PASS: coordination_server self-test (16 tools)")
    sys.exit(0)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        _run_self_test()
    elif len(sys.argv) > 1:
        print(f"ERROR: Unknown argument '{sys.argv[1]}'. This is an MCP server, not a CLI tool.", file=sys.stderr)
        print("Use MCP tools (dispatch_to_pane, read_pane_output, etc.) via your CLI's MCP integration.", file=sys.stderr)
        print("For self-test: python3 coordination_server.py --self-test", file=sys.stderr)
        sys.exit(1)
    else:
        _get_conn()
        mcp.run(transport="stdio")
