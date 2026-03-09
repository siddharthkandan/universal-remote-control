#!/usr/bin/env python3
"""
server.py -- MCP coordination server for URC pane communication and fleet management.

11 tools: register_agent, heartbeat, get_fleet_status, rename_agent,
dispatch_to_pane, read_pane_output, send_message, receive_messages,
kill_pane, cancel_dispatch, bootstrap_validate.

Simplified fork of coordination_server.py (19 tools -> 11).
CUT: health_check, claim_task, complete_task, report_event, relay_forward,
     relay_read, dispatch_async.
MERGED: send_with_notify into send_message (notify parameter).

Usage (normal):
    python3 urc/core/server.py

Usage (self-test):
    python3 urc/core/server.py --self-test
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Ensure project root is on sys.path when run directly
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Server instance + constants
# ---------------------------------------------------------------------------

mcp = FastMCP("urc-coordination")

_SERVER_START = time.time()
_SEND_SH = PROJECT_ROOT / "urc" / "core" / "send.sh"
_URC_DIR = PROJECT_ROOT / ".urc"

# Auto-registration: register this pane on first MCP tool call
_auto_registered = False

# Wake nudge rate-limiting: pane_id -> last nudge timestamp
# NOTE: _last_nudge is safe because all access is synchronous (no awaits between
# read and write). If _send_to_pane is ever made async, add a lock.
_last_nudge: dict[str, float] = {}
_NUDGE_COOLDOWN = 30  # seconds
_NUDGE_FAIL_COOLDOWN = 10  # shorter retry on failure (avoid hammering dead panes)

# Module-level connection -- lazily initialized on first use
_conn = None

# Detect the tmux pane this server is running in
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


# ---------------------------------------------------------------------------
# Shared infrastructure
# ---------------------------------------------------------------------------


def _get_conn():
    """Return the shared SQLite connection, initializing on first call."""
    global _conn
    if _conn is None:
        from urc.core.db import get_connection, init_schema
        _conn = get_connection()
        init_schema(_conn)
    return _conn


def _ensure_registered():
    """Auto-register the calling pane on first use. No-op if not in tmux.

    Uses INSERT OR IGNORE to avoid clobbering existing agent records.
    CLI type auto-detected from TMUX pane options when available.
    """
    global _auto_registered
    if _auto_registered:
        return
    pane_id = os.environ.get("TMUX_PANE")
    if not pane_id:
        _auto_registered = True  # no tmux -- skip permanently
        return
    try:
        from urc.core.db import get_agent, register_agent as db_register_agent
        conn = _get_conn()
        existing = get_agent(conn, pane_id)
        if existing:
            _auto_registered = True  # already registered -- don't overwrite
            return
        # Detect CLI type from tmux pane option (set by bootstrap/session-start)
        cli_type = "claude"
        try:
            cli_check = subprocess.run(
                ["tmux", "display-message", "-t", pane_id, "-p", "#{@urc_cli}"],
                capture_output=True, text=True, timeout=3,
            )
            if cli_check.returncode == 0 and cli_check.stdout.strip():
                cli_type = cli_check.stdout.strip()
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass
        db_register_agent(conn, pane_id, cli_type, "mcp-server", os.getpid(), "")
        _auto_registered = True
    except Exception:
        pass  # best-effort -- never break tool calls


def _peek_inbox_hint(pane_id: Optional[str] = None) -> Optional[str]:
    """O(1) check for unread inbox messages. Returns hint string or None.

    1. Check if .urc/inbox/{pane}.signal exists (O(1) stat)
    2. If no signal -> return None
    3. If signal -> query DB for unread count + latest sender
    4. Return "INBOX: N unread from %SENDER" string
    """
    pid = pane_id or _server_pane
    if not pid:
        return None
    signal = _URC_DIR / "inbox" / f"{pid}.signal"
    if not signal.exists():
        return None
    try:
        from urc.core.db import receive_messages as db_recv
        conn = _get_conn()
        msgs = db_recv(conn, pid, mark_read=False)
        count = len(msgs) if msgs else 0
        if count == 0:
            return None
        # Extract sender from most recent message
        latest_sender = msgs[-1]["from_pane"] if msgs else "unknown"
        return f"INBOX: {count} unread from {latest_sender}"
    except Exception:
        return None


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


def _send_to_pane(pane_id: str, message: str) -> dict:
    """Call send.sh. Returns parsed JSON result.

    send.sh uses EXIT-CODE verification only.
    Exit 0 = delivered, Exit 1 = failed.
    """
    cmd = ["bash", str(_SEND_SH), pane_id, message]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return json.loads(result.stdout)
    except subprocess.TimeoutExpired:
        return {"status": "failed", "pane": pane_id, "error": "send.sh timeout"}
    except (json.JSONDecodeError, Exception) as e:
        return {"status": "failed", "pane": pane_id, "error": str(e)}


def _session_group_check(target_pane: str) -> Optional[str]:
    """Validate target is in the same tmux session group as the server.

    Returns None if valid, error string if not.
    """
    if not _server_pane:
        return None  # Can't check without server pane -- allow through
    try:
        result = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{session_group} #{pane_id}"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return None  # Can't determine -- allow through

        pane_groups = {}
        for line in result.stdout.strip().split("\n"):
            parts = line.split(" ", 1)
            if len(parts) == 2:
                group, pid = parts
                pane_groups[pid] = group

        server_group = pane_groups.get(_server_pane)
        target_group = pane_groups.get(target_pane)

        if server_group and target_group and server_group != target_group:
            return (f"Target {target_pane} is in session group '{target_group}', "
                    f"server is in '{server_group}'. Cross-group dispatch blocked.")
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None  # Can't determine -- allow through


def append_log(op: str, pane_id: str, data: dict):
    """JSONL audit append. Best-effort, never raises."""
    try:
        log_path = _URC_DIR / "streams" / f"{pane_id}.jsonl"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        entry = {"ts": time.time(), "action": op, "pane": pane_id}
        if data:
            entry.update(data)
        with open(log_path, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Tool 1: register_agent
# ---------------------------------------------------------------------------


@mcp.tool()
async def register_agent(
    pane_id: str,
    cli: str,
    role: str = "worker",
    model: str = "",
) -> dict:
    """Register this pane as an agent in the coordination DB."""
    try:
        from urc.core.db import register_agent as db_register_agent
        conn = _get_conn()
        db_register_agent(conn, pane_id, cli, role, os.getpid(), model)
        append_log("register", pane_id, {"cli": cli, "role": role, "model": model})
        return {"status": "registered", "pane_id": pane_id, "cli": cli}
    except Exception as e:
        return {"error": str(e), "tool": "register_agent"}


# ---------------------------------------------------------------------------
# Tool 2: heartbeat
# ---------------------------------------------------------------------------


@mcp.tool()
async def heartbeat(
    pane_id: str,
    status: str = "active",
    context_pct: int = -1,
) -> dict:
    """Update heartbeat. Returns inbox hint if messages are waiting."""
    try:
        from urc.core.db import update_heartbeat, get_agent
        conn = _get_conn()
        update_heartbeat(conn, pane_id, context_pct, status)
        append_log("heartbeat", pane_id, {"context_pct": context_pct, "status": status})

        # Warn if heartbeat was sent for an unregistered pane (UPDATE matched 0 rows)
        agent = get_agent(conn, pane_id)
        if not agent:
            return {"status": "warning", "message": f"pane {pane_id} not registered"}

        result = {"status": "ok", "pane_id": pane_id}
        hint = _peek_inbox_hint(pane_id)
        if hint:
            result["inbox_hint"] = hint
        return result
    except Exception as e:
        return {"error": str(e), "tool": "heartbeat"}


# ---------------------------------------------------------------------------
# Tool 3: get_fleet_status
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_fleet_status(stale_threshold: int = 3600) -> dict:
    """List registered agents, filtered by heartbeat freshness. For fleet-wide discovery of existing panes only — not needed before spawning Agent Teams. Set stale_threshold=0 for all."""
    _ensure_registered()
    try:
        from urc.core.db import list_agents
        conn = _get_conn()
        rows = list_agents(conn, max_age=stale_threshold if stale_threshold > 0 else None)
        now = time.time()

        # Get live tmux panes once for alive check
        live_panes = set()
        try:
            result = subprocess.run(
                ["tmux", "list-panes", "-a", "-F", "#{pane_id}"],
                capture_output=True, text=True, timeout=3,
            )
            if result.returncode == 0:
                live_panes = set(result.stdout.strip().split("\n"))
        except Exception:
            pass

        agents = []
        for row in rows:
            r = dict(row)
            last_hb = r.get("last_heartbeat") or 0.0
            agents.append({
                "pane_id": r.get("pane_id", ""),
                "cli": r.get("cli", ""),
                "role": r.get("role", ""),
                "status": r.get("status", ""),
                "context_pct": int(r.get("context_pct") or -1),
                "heartbeat_age_seconds": round(now - float(last_hb), 1),
                "model": r.get("model", ""),
                "label": r.get("label", ""),
                "alive": r.get("pane_id", "") in live_panes,
            })

        result = {"agents": agents, "count": len(agents)}
        hint = _peek_inbox_hint()
        if hint:
            result["inbox_hint"] = hint
        return result
    except Exception as e:
        return {"error": str(e), "tool": "get_fleet_status"}


# ---------------------------------------------------------------------------
# Tool 4: rename_agent
# ---------------------------------------------------------------------------


@mcp.tool()
async def rename_agent(pane_id: str, label: str) -> dict:
    """Set a display label for an agent."""
    try:
        from urc.core.db import get_agent, update_agent_label
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
# Tool 5: dispatch_to_pane
# ---------------------------------------------------------------------------


@mcp.tool()
async def dispatch_to_pane(pane_id: str, message: str) -> dict:
    """Send text to a pane via bracketed paste. Fire-and-forget -- does not wait for response.
    For synchronous dispatch-and-wait, use dispatch-and-wait.sh via Bash."""
    _ensure_registered()
    try:
        # Session-group guard
        group_err = _session_group_check(pane_id)
        if group_err:
            return {"status": "failed", "pane_id": pane_id, "error": group_err}

        # Write dispatch metadata for push attribution (hook.sh reads this)
        dispatch_dir = _URC_DIR / "dispatches"
        dispatch_dir.mkdir(parents=True, exist_ok=True)
        meta_file = dispatch_dir / f"{pane_id}.json"
        try:
            # Staleness guard: don't overwrite recent metadata (<=5s)
            # to avoid misattribution on back-to-back dispatches
            _skip = False
            if meta_file.exists():
                try:
                    age = int(time.time()) - int(meta_file.stat().st_mtime)
                    _skip = age <= 5
                except OSError:
                    pass
            if not _skip:
                meta = json.dumps({
                    "type": "dispatch",
                    "source": _server_pane or "unknown",
                    "message": message[:100],
                    "ts": int(time.time()),
                })
                meta_file.write_text(meta)
        except OSError:
            pass  # Best-effort — attribution is non-critical

        result = _send_to_pane(pane_id, message)

        # Append JSONL audit entry for delivered outcomes
        status = result.get("status", "")
        if status == "delivered":
            append_log("dispatch_to_pane", pane_id, {"message": message[:200]})

        # Add inbox hint
        hint = _peek_inbox_hint()
        if hint:
            result["inbox_hint"] = hint
        return result
    except Exception as e:
        return {"status": "failed", "error": str(e), "tool": "dispatch_to_pane"}


# ---------------------------------------------------------------------------
# Tool 6: read_pane_output
# ---------------------------------------------------------------------------


@mcp.tool()
async def read_pane_output(pane_id: str, lines: int = 50) -> dict:
    """Capture visible text from a pane's terminal buffer."""
    try:
        n = min(max(lines, 1), 200)

        result = subprocess.run(
            ["tmux", "capture-pane", "-t", pane_id, "-p", "-S", f"-{n}"],
            capture_output=True, text=True, timeout=10,
        )

        if result.returncode != 0:
            return {"error": f"capture-pane failed: {result.stderr.strip()[:200]}",
                    "tool": "read_pane_output"}

        output = result.stdout
        # Trim leading empty lines
        output_lines = output.split("\n")
        while output_lines and not output_lines[0].strip():
            output_lines.pop(0)
        output = "\n".join(output_lines)

        resp = {
            "pane_id": pane_id,
            "lines": n,
            "output": output,
        }
        hint = _peek_inbox_hint()
        if hint:
            resp["inbox_hint"] = hint
        return resp
    except subprocess.TimeoutExpired:
        return {"error": "capture-pane timed out (10s)", "tool": "read_pane_output"}
    except Exception as e:
        return {"error": str(e), "tool": "read_pane_output"}


# ---------------------------------------------------------------------------
# Tool 7: send_message
# ---------------------------------------------------------------------------


@mcp.tool()
async def send_message(
    from_pane: str,
    to_pane: str,
    body: str,
    notify: bool = True,
) -> dict:
    """Store a message in SQLite, signal recipient's inbox. Optionally send tmux wake nudge.
    This is the merged send_message + send_with_notify."""
    _ensure_registered()
    try:
        from urc.core.db import send_message as db_send_message, list_agents
        conn = _get_conn()

        # For broadcasts (to_pane="*"), store with to_pane=None
        actual_to = None if to_pane == "*" else to_pane

        msg_id = db_send_message(conn, from_pane, actual_to, body)
        append_log("send_message", from_pane, {"to_pane": actual_to, "body": body[:200]})

        # Determine which panes to signal
        if actual_to is None:
            # Broadcast: signal all registered panes
            try:
                all_agents = list_agents(conn)
                signal_panes = [dict(a)["pane_id"] for a in all_agents
                                if dict(a)["pane_id"] != from_pane]
            except Exception:
                signal_panes = []
        else:
            signal_panes = [actual_to]

        # Touch inbox signal file(s) for O(1) stat check by PostToolUse hook
        inbox_dir = _URC_DIR / "inbox"
        inbox_dir.mkdir(parents=True, exist_ok=True)
        for sp in signal_panes:
            try:
                with open(inbox_dir / f"{sp}.signal", "w") as f:
                    f.write(f"{from_pane}\n")
            except OSError:
                pass

        # Fire tmux wait-for for instant inbox notification
        if notify:
            for sp in signal_panes:
                try:
                    subprocess.run(
                        ["tmux", "wait-for", "-S", f"urc_inbox_{sp}"],
                        capture_output=True, timeout=3,
                    )
                except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
                    pass

        # Best-effort wake nudge via send.sh (rate-limited per recipient)
        wake_status = None
        wake_error = None
        if notify and actual_to and actual_to != from_pane:
            now = time.time()
            last = _last_nudge.get(actual_to, 0)
            if now - last < _NUDGE_COOLDOWN:
                wake_status = "skipped_recent"
            else:
                try:
                    nudge = f"You have an unread message from {from_pane}. Use receive_messages to read it."
                    wake_result = _send_to_pane(actual_to, nudge)
                    wake_status = wake_result.get("status", "failed")
                    if wake_status == "failed":
                        wake_error = wake_result.get("error", "unknown")
                        # Short backoff on failure (avoid hammering dead panes)
                        _last_nudge[actual_to] = now - _NUDGE_COOLDOWN + _NUDGE_FAIL_COOLDOWN
                    else:
                        _last_nudge[actual_to] = now
                except Exception as e:
                    wake_status = "failed"
                    wake_error = str(e)
                    _last_nudge[actual_to] = now - _NUDGE_COOLDOWN + _NUDGE_FAIL_COOLDOWN

        result = {"status": "sent", "message_id": msg_id}
        if notify:
            result["wake_status"] = wake_status or "signalled"
            if wake_error:
                result["wake_error"] = wake_error
        return result
    except Exception as e:
        return {"error": str(e), "tool": "send_message"}


# ---------------------------------------------------------------------------
# Tool 8: receive_messages
# ---------------------------------------------------------------------------


@mcp.tool()
async def receive_messages(pane_id: str, mark_read: bool = True) -> dict:
    """Get unread messages from inbox (direct + broadcasts)."""
    try:
        from urc.core.db import receive_messages as db_receive_messages
        conn = _get_conn()
        msgs = db_receive_messages(conn, pane_id, mark_read=mark_read)

        # Clear inbox signal file after reading
        if mark_read:
            signal = _URC_DIR / "inbox" / f"{pane_id}.signal"
            try:
                signal.unlink(missing_ok=True)
            except OSError:
                pass

        return {"messages": [dict(m) for m in msgs], "count": len(msgs)}
    except Exception as e:
        return {"error": str(e), "tool": "receive_messages"}


# ---------------------------------------------------------------------------
# Tool 9: kill_pane
# ---------------------------------------------------------------------------


@mcp.tool()
async def kill_pane(pane_id: str, confirm: bool = False) -> dict:
    """Kill a tmux pane. Requires confirm=True as safety guard."""
    try:
        if not confirm:
            return {
                "status": "confirmation_required",
                "warning": f"This will kill pane {pane_id} and terminate any running process. "
                           f"Call again with confirm=True to proceed.",
                "pane_id": pane_id,
            }

        # Validate pane exists
        if not _pane_exists(pane_id):
            return {"error": f"Pane {pane_id} does not exist", "tool": "kill_pane"}

        result = subprocess.run(
            ["tmux", "kill-pane", "-t", pane_id],
            capture_output=True, text=True, timeout=10,
        )

        if result.returncode == 0:
            # Mark agent as offline in DB
            try:
                from urc.core.db import deregister_agent
                conn = _get_conn()
                deregister_agent(conn, pane_id)
            except Exception:
                pass
            append_log("kill_pane", pane_id, {"confirmed": True})
            return {"status": "killed", "pane_id": pane_id}
        else:
            return {"error": f"kill-pane failed: {result.stderr.strip()[:200]}",
                    "tool": "kill_pane"}
    except subprocess.TimeoutExpired:
        return {"error": "kill-pane timed out", "tool": "kill_pane"}
    except Exception as e:
        return {"error": str(e), "tool": "kill_pane"}


# ---------------------------------------------------------------------------
# Tool 10: cancel_dispatch
# ---------------------------------------------------------------------------


@mcp.tool()
async def cancel_dispatch(pane_id: str) -> dict:
    """Emergency: SIGINT the target pane, clear all dispatch signals, unblock any waiting dispatcher."""
    try:
        # Send Ctrl-C to target pane
        subprocess.run(
            ["tmux", "send-keys", "-t", pane_id, "C-c"],
            capture_output=True, timeout=5,
        )

        # Clear signal, timeout, and response files
        signal_file = _URC_DIR / "signals" / f"done_{pane_id}"
        timeout_file = _URC_DIR / "timeout" / f"{pane_id}"
        response_file = _URC_DIR / "responses" / f"{pane_id}.json"
        for f in [signal_file, timeout_file, response_file]:
            try:
                f.unlink(missing_ok=True)
            except OSError:
                pass

        # Signal the wait-for channel to unblock any waiting dispatcher
        subprocess.run(
            ["tmux", "wait-for", "-S", f"urc_done_{pane_id}"],
            capture_output=True, timeout=3,
        )

        return {"status": "cancelled", "pane_id": pane_id}
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "pane_id": pane_id, "error": "tmux command timed out"}
    except Exception as e:
        return {"error": str(e), "tool": "cancel_dispatch"}


# ---------------------------------------------------------------------------
# Tool 11: bootstrap_validate
# ---------------------------------------------------------------------------


@mcp.tool()
async def bootstrap_validate() -> dict:
    """Validate URC setup: CWD, directories, hooks, tmux. Clean stale state."""
    checks = {}
    warnings = []

    # 1. Check CWD contains urc/core/
    urc_core = PROJECT_ROOT / "urc" / "core"
    if urc_core.is_dir():
        checks["project_root"] = "ok"
    else:
        checks["project_root"] = "FAIL"
        warnings.append(f"URC project root not found at {PROJECT_ROOT}")

    # 2. Check/create .urc/ directories
    for d in ["responses", "signals", "streams", "locks", "timeout", "inbox"]:
        path = _URC_DIR / d
        if path.is_dir():
            checks[f"dir_{d}"] = "ok"
        else:
            path.mkdir(parents=True, exist_ok=True)
            checks[f"dir_{d}"] = "created"
            warnings.append(f"Created missing directory: .urc/{d}")

    # 3. Check tmux is accessible
    try:
        r = subprocess.run(["tmux", "list-sessions"], capture_output=True, timeout=3)
        checks["tmux"] = "ok" if r.returncode == 0 else "FAIL"
        if r.returncode != 0:
            warnings.append("tmux not accessible or no sessions")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        checks["tmux"] = "FAIL"
        warnings.append("tmux not accessible")

    # 4. Check hook script exists
    hook_path = PROJECT_ROOT / "urc" / "core" / "hook.sh"
    if hook_path.is_file():
        checks["turn_complete_hook"] = "ok"
    else:
        checks["turn_complete_hook"] = "missing"
        warnings.append("hook.sh not found")

    # 5. Check send.sh exists
    if _SEND_SH.is_file():
        checks["send_sh"] = "ok"
    else:
        checks["send_sh"] = "missing"
        warnings.append("send.sh not found")

    # 6. Check dispatch-and-wait.sh exists
    daw_path = PROJECT_ROOT / "urc" / "core" / "dispatch-and-wait.sh"
    if daw_path.is_file():
        checks["dispatch_and_wait"] = "ok"
    else:
        checks["dispatch_and_wait"] = "missing"
        warnings.append("dispatch-and-wait.sh not found")

    # 7. Clean stale files (>2h, pane dead)
    stale_cleaned = 0
    cutoff = time.time() - 7200
    live_panes = set()
    try:
        result = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id}"],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode == 0:
            live_panes = set(result.stdout.strip().split("\n"))
    except Exception:
        pass

    if live_panes:
        for dirname in ["responses", "signals", "timeout", "reply_to", "streams", "inbox"]:
            dirpath = _URC_DIR / dirname
            if not dirpath.is_dir():
                continue
            for entry in dirpath.iterdir():
                if entry.is_dir():
                    continue
                try:
                    mtime = entry.stat().st_mtime
                except OSError:
                    continue
                if mtime > cutoff:
                    continue
                # Extract pane ID from filename
                pane_from_file = entry.name.replace("done_", "").replace(".json", "").replace(".signal", "").replace(".jsonl", "")
                if pane_from_file not in live_panes:
                    try:
                        entry.unlink()
                        stale_cleaned += 1
                    except OSError:
                        pass

        # Clean v2 lock files with stale prefixes
        locks_cleaned = 0
        v2_prefixes = ("stop_", "urc-intercept_", "relay-nothink_")
        locks_dir = _URC_DIR / "locks"
        if locks_dir.is_dir():
            for entry in locks_dir.iterdir():
                if entry.is_dir():
                    continue
                if entry.name.startswith(v2_prefixes):
                    try:
                        entry.unlink()
                        locks_cleaned += 1
                    except OSError:
                        pass
        if locks_cleaned:
            checks["v2_locks_cleanup"] = f"cleaned {locks_cleaned} files"
            warnings.append(f"Cleaned {locks_cleaned} v2 lock files")
        else:
            checks["v2_locks_cleanup"] = "ok"

        if stale_cleaned:
            checks["stale_cleanup"] = f"cleaned {stale_cleaned} files"
            warnings.append(f"Cleaned {stale_cleaned} stale files from dead panes")
        else:
            checks["stale_cleanup"] = "ok"

    # 8. DB reaper: deregister agents whose panes no longer exist
    db_reaped = 0
    if live_panes:
        try:
            from urc.core.db import list_agents, deregister_agent
            conn = _get_conn()
            all_agents = list_agents(conn)
            for agent in all_agents:
                a = dict(agent)
                if a.get("status") != "offline" and a.get("pane_id", "") not in live_panes:
                    deregister_agent(conn, a["pane_id"])
                    db_reaped += 1
        except Exception:
            pass
    if db_reaped:
        checks["db_reaper"] = f"deregistered {db_reaped} agents"
        warnings.append(f"Deregistered {db_reaped} agents with dead panes")
    else:
        checks["db_reaper"] = "ok"

    # 9. DB purge: delete offline agents >24h, read messages >24h
    db_purged_agents = 0
    db_purged_messages = 0
    try:
        conn = _get_conn()
        cur = conn.execute(
            "DELETE FROM agents WHERE status = 'offline' AND last_heartbeat < ?",
            (time.time() - 86400,),
        )
        db_purged_agents = cur.rowcount
        cur = conn.execute(
            "DELETE FROM messages WHERE read = 1 AND created_at < datetime('now', '-24 hours')"
        )
        db_purged_messages = cur.rowcount
        conn.commit()
    except Exception:
        pass
    if db_purged_agents or db_purged_messages:
        checks["db_purge"] = f"deleted {db_purged_agents} agents, {db_purged_messages} messages"
        warnings.append(f"Purged {db_purged_agents} offline agents and {db_purged_messages} read messages (>24h)")
    else:
        checks["db_purge"] = "ok"

    has_errors = any(v == "FAIL" for v in checks.values())
    return {
        "status": "error" if has_errors else "ok",
        "checks": checks,
        "warnings": warnings,
        "project_root": str(PROJECT_ROOT),
    }


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------


def _run_self_test():
    """Exercise all 11 tools via direct function calls against in-memory DB."""
    import asyncio
    import tempfile

    from urc.core.db import get_connection, init_schema, get_agent

    # Override module-level connection to use in-memory DB
    global _conn
    _conn = get_connection(":memory:")
    init_schema(_conn)

    # Patch JSONL to use temp directory so self-test doesn't pollute .urc/
    tmp_dir = tempfile.mkdtemp(prefix="urc_selftest_")
    _orig_urc_dir = globals()["_URC_DIR"]
    globals()["_URC_DIR"] = Path(tmp_dir)

    passed = 0
    failed = 0

    def check(name, condition, detail=""):
        nonlocal passed, failed
        if condition:
            print(f"  PASS: {name}")
            passed += 1
        else:
            print(f"  FAIL: {name}{' -- ' + detail if detail else ''}")
            failed += 1

    async def run_tests():
        nonlocal passed, failed

        # -- Tool 1: register_agent --
        r = await register_agent(pane_id="%test", cli="claude", role="engineer", model="opus")
        check("register_agent status", r.get("status") == "registered", str(r))
        check("register_agent pane_id", r.get("pane_id") == "%test", str(r))
        check("register_agent cli", r.get("cli") == "claude", str(r))

        agent = get_agent(_conn, "%test")
        check("register_agent in DB", agent is not None)

        # Register a second agent for later tests
        await register_agent(pane_id="%other", cli="codex", role="worker")

        # -- Tool 2: heartbeat --
        r = await heartbeat(pane_id="%test", status="active", context_pct=55)
        check("heartbeat status", r.get("status") == "ok", str(r))

        updated = get_agent(_conn, "%test")
        check("heartbeat context_pct", updated["context_pct"] == 55, str(updated["context_pct"]))

        # -- Tool 3: get_fleet_status --
        r = await get_fleet_status(stale_threshold=0)
        check("get_fleet_status has agents", "agents" in r, str(r))
        check("get_fleet_status count", r.get("count", 0) >= 2, str(r))

        # -- Tool 4: rename_agent --
        r = await rename_agent(pane_id="%test", label="relay-for-codex")
        check("rename_agent status", r.get("status") == "renamed", str(r))
        check("rename_agent label", r.get("label") == "relay-for-codex", str(r))

        r_bad = await rename_agent(pane_id="%nonexistent", label="X")
        check("rename_agent missing agent", "error" in r_bad, str(r_bad))

        # -- Tool 5: dispatch_to_pane (tmux-dependent, test graceful failure) --
        r = await dispatch_to_pane(pane_id="%nonexistent_test_pane", message="hello")
        check("dispatch_to_pane returns dict", isinstance(r, dict), str(r))
        check("dispatch_to_pane has status", "status" in r or "error" in r, str(r))

        # -- Tool 6: read_pane_output (tmux-dependent, test graceful failure) --
        r = await read_pane_output(pane_id="%nonexistent_test_pane", lines=5)
        check("read_pane_output returns dict", isinstance(r, dict), str(r))

        # -- Tool 7: send_message (direct) --
        r = await send_message(from_pane="%test", to_pane="%other", body="Hello", notify=False)
        check("send_message status", r.get("status") == "sent", str(r))
        check("send_message has message_id", "message_id" in r, str(r))

        # -- Tool 7b: send_message (broadcast) --
        r = await send_message(from_pane="%test", to_pane="*", body="Broadcast!", notify=False)
        check("send_message broadcast", r.get("status") == "sent", str(r))

        # -- Tool 7c: send_message with notify (rate-limiting) --
        _last_nudge.clear()  # reset rate-limit state
        r = await send_message(from_pane="%test", to_pane="%other", body="Nudge1", notify=True)
        check("send_message notify has wake_status", "wake_status" in r, str(r))

        r2 = await send_message(from_pane="%test", to_pane="%other", body="Nudge2", notify=True)
        check("send_message rate-limit skips", r2.get("wake_status") == "skipped_recent", str(r2))

        # -- Tool 8: receive_messages --
        r = await receive_messages(pane_id="%other")
        check("receive_messages has messages", "messages" in r, str(r))
        msgs = r.get("messages", [])
        check("receive_messages count", r.get("count", 0) >= 1, str(r))
        bodies = [m["body"] for m in msgs]
        check("receive_messages content", "Hello" in bodies, str(bodies))

        # Verify idempotency (second read returns empty)
        r2 = await receive_messages(pane_id="%other")
        check("receive_messages idempotent", r2.get("count", -1) == 0, str(r2))

        # -- Tool 9: kill_pane (no-confirm gate) --
        r = await kill_pane(pane_id="%nonexistent_test_pane", confirm=False)
        check("kill_pane confirm gate", r.get("status") == "confirmation_required", str(r))
        check("kill_pane has warning", "warning" in r, str(r))

        # -- Tool 10: cancel_dispatch (tmux-dependent, test graceful handling) --
        r = await cancel_dispatch(pane_id="%nonexistent_test_pane")
        check("cancel_dispatch returns dict", isinstance(r, dict), str(r))

        # -- Tool 11: bootstrap_validate --
        r = await bootstrap_validate()
        check("bootstrap_validate returns dict", isinstance(r, dict), str(r))
        check("bootstrap_validate has status", "status" in r, str(r))
        check("bootstrap_validate has checks", "checks" in r, str(r))
        check("bootstrap_validate has project_root", "project_root" in r, str(r))

    try:
        asyncio.run(run_tests())
    finally:
        globals()["_URC_DIR"] = _orig_urc_dir
        import shutil
        shutil.rmtree(tmp_dir, ignore_errors=True)

    total = passed + failed
    print(f"\n{'=' * 50}")
    print(f"server.py self-test: {passed}/{total} passed, {failed} failed")
    if failed:
        print("FAIL")
        sys.exit(1)
    else:
        print("PASS: server.py self-test (11 tools)")
        sys.exit(0)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        _run_self_test()
    elif len(sys.argv) > 1:
        print(f"ERROR: Unknown argument '{sys.argv[1]}'. This is an MCP server, not a CLI tool.",
              file=sys.stderr)
        print("Use MCP tools via your CLI's MCP integration.", file=sys.stderr)
        print("For self-test: python3 urc/core/server.py --self-test", file=sys.stderr)
        sys.exit(1)
    else:
        _get_conn()
        mcp.run(transport="stdio")
