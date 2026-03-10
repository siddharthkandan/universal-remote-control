#!/usr/bin/env bash
# validate-plugin.sh — Validate URC plugin structure.
# Works from any context: inside Claude Code, raw terminal, or CI.
# Does NOT launch claude — avoids the CLAUDECODE nested session block.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

PASS=0
FAIL=0
WARN=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN + 1)); }

echo ""
echo "URC Plugin Validation"
echo "====================="
echo ""

# ── 1. plugin.json ──────────────────────────────────────────────────
echo "Manifest (.claude-plugin/plugin.json)"

if [[ -f .claude-plugin/plugin.json ]]; then
  pass "plugin.json exists"
else
  fail "plugin.json missing"
  echo ""; echo "RESULT: FAIL ($FAIL errors)"; exit 1
fi

if python3 -c "import json; json.load(open('.claude-plugin/plugin.json'))" 2>/dev/null; then
  pass "Valid JSON"
else
  fail "Invalid JSON"
fi

for field in name version hooks mcpServers; do
  if python3 -c "
import json, sys
d = json.load(open('.claude-plugin/plugin.json'))
sys.exit(0 if '$field' in d else 1)
" 2>/dev/null; then
    pass "Has '$field' field"
  else
    fail "Missing '$field' field"
  fi
done

echo ""

# ── 2. hooks.json ───────────────────────────────────────────────────
echo "Hooks (hooks/hooks.json)"

if [[ -f hooks/hooks.json ]]; then
  pass "hooks.json exists"
else
  fail "hooks.json missing"
fi

if python3 -c "
import json, sys
d = json.load(open('hooks/hooks.json'))
sys.exit(0 if 'hooks' in d else 1)
" 2>/dev/null; then
  pass "Has wrapping 'hooks' key"
else
  fail "Missing wrapping 'hooks' key — plugin loader won't discover hooks"
fi

if python3 -c "
import json, sys
d = json.load(open('hooks/hooks.json'))
events = list(d.get('hooks', {}).keys())
sys.exit(0 if 'Stop' in events else 1)
" 2>/dev/null; then
  pass "Stop hook registered"
else
  warn "No Stop hook — turn-completion signals won't fire in plugin mode"
fi

echo ""

# ── 3. Symlinks ─────────────────────────────────────────────────────
echo "Component Symlinks"

for link in agents skills; do
  if [[ -L "$link" ]]; then
    target=$(readlink "$link")
    if [[ -d "$link" ]]; then
      pass "$link -> $target (resolves)"
    else
      fail "$link -> $target (broken symlink)"
    fi
  elif [[ -d "$link" ]]; then
    pass "$link/ directory exists (not a symlink)"
  else
    fail "$link missing — plugin auto-discovery won't find components"
  fi
done

# Verify agent and skill content
if [[ -f agents/rc-bridge.md ]]; then
  pass "agents/rc-bridge.md found"
else
  fail "agents/rc-bridge.md missing"
fi

if [[ -f skills/urc/SKILL.md ]]; then
  pass "skills/urc/SKILL.md found"
else
  fail "skills/urc/SKILL.md missing"
fi

echo ""

# ── 4. MCP Servers ──────────────────────────────────────────────────
echo "MCP Servers"

if [[ -x .venv/bin/python3 ]]; then
  pass ".venv/bin/python3 exists"
else
  fail ".venv/bin/python3 missing — run setup.sh first"
  echo ""; echo "Skipping MCP tests (no venv)"; echo ""
  echo "====================="
  printf "RESULT: %d passed, %d failed, %d warnings\n" "$PASS" "$FAIL" "$WARN"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

if PYTHONPATH="$PROJECT_ROOT" .venv/bin/python3 -c "from urc.core import server" 2>/dev/null; then
  pass "server imports"
else
  fail "server import failed"
fi

if PYTHONPATH="$PROJECT_ROOT" .venv/bin/python3 -c "from urc.core import teams_server" 2>/dev/null; then
  pass "teams_server imports"
else
  fail "teams_server import failed"
fi

echo ""

# ── 5. Self-Tests ───────────────────────────────────────────────────
echo "Self-Tests"

if PYTHONPATH="$PROJECT_ROOT" .venv/bin/python3 urc/core/server.py --self-test 2>/dev/null | grep -q "PASS"; then
  pass "server self-test"
else
  fail "server self-test failed"
fi

if PYTHONPATH="$PROJECT_ROOT" .venv/bin/python3 urc/core/teams_server.py --self-test 2>/dev/null | grep -q "PASS"; then
  pass "teams_server self-test"
else
  fail "teams_server self-test failed"
fi

echo ""

# ── 6. Extras ───────────────────────────────────────────────────────
echo "Extras"

[[ -f requirements.txt ]] && pass "requirements.txt exists" || warn "No requirements.txt"
[[ -f README.md ]] && pass "README.md exists" || warn "No README.md"
[[ -f LICENSE ]] && pass "LICENSE exists" || warn "No LICENSE"
[[ -f .mcp.json ]] && pass ".mcp.json exists (git-clone mode)" || warn "No .mcp.json"

# -- Duplicate Hook Detection --
echo "-- Duplicate Hook Detection --"
if [ -f ".claude/settings.json" ] && [ -f "hooks/hooks.json" ]; then
    for event in Stop SessionStart PostToolUse UserPromptSubmit; do
        s_cmds=$(jq -r ".hooks.${event}[]?.hooks[]?.command // empty" .claude/settings.json 2>/dev/null | sort)
        p_cmds=$(jq -r ".hooks.${event}[]?.hooks[]?.command // empty" hooks/hooks.json 2>/dev/null | sort)
        dupes=$(comm -12 <(echo "$s_cmds") <(echo "$p_cmds"))
        if [ -n "$dupes" ]; then
            warn "Duplicate $event hooks in both settings.json and hooks.json (idempotent guards required):"
            echo "$dupes" | while read -r cmd; do
                [ -n "$cmd" ] && echo "  $cmd"
            done
        fi
    done
fi
pass "Duplicate hook detection complete"

echo ""

# ── Summary ─────────────────────────────────────────────────────────
echo "====================="
printf "RESULT: %d passed, %d failed, %d warnings\n" "$PASS" "$FAIL" "$WARN"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo "Plugin structure is valid."
  exit 0
else
  echo "Fix the failures above before publishing."
  exit 1
fi
