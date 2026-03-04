#!/usr/bin/env bash
set -euo pipefail

# URC — Automated Installation
# Safe to run multiple times (idempotent).

# ── Color support ────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  GREEN=$(tput setaf 2)
  RED=$(tput setaf 1)
  YELLOW=$(tput setaf 3)
  CYAN=$(tput setaf 6)
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
else
  GREEN="" RED="" YELLOW="" CYAN="" BOLD="" RESET=""
fi

ok()   { printf '%s[OK]%s  %s\n' "$GREEN"  "$RESET" "$1"; }
fail() { printf '%s[X]%s  %s\n'  "$RED"    "$RESET" "$1"; }
warn() { printf '%s[!]%s  %s\n'  "$YELLOW" "$RESET" "$1"; }
info() { printf '%s-->%s  %s\n'  "$CYAN"   "$RESET" "$1"; }

# ── Resolve project root (directory containing this script) ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "${BOLD}URC Setup${RESET}"
echo "=================================="
echo ""

# ══════════════════════════════════════════════════════════════════════
# 1. PREFLIGHT CHECKS
# ══════════════════════════════════════════════════════════════════════
echo "${BOLD}Preflight Checks${RESET}"
echo ""

ERRORS=0

# -- Python 3.10+ -------------------------------------------------
PYTHON_CMD="python3"
if command -v python3 &>/dev/null; then
  PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
  PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
  PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
  if [[ "$PY_MAJOR" -ge 3 && "$PY_MINOR" -ge 10 ]]; then
    ok "Python $PY_VERSION"
  else
    warn "Python $PY_VERSION found — need 3.10+, checking alternatives..."
    echo "     macOS: brew install python@3.13"
    echo "     Linux: apt install python3 (or your distro equivalent)"
    # Try higher versions on macOS (Homebrew installs as python3.X)
    for v in python3.13 python3.12 python3.11 python3.10; do
      if command -v "$v" &>/dev/null; then
        warn "Found $v — will use that instead"
        PYTHON_CMD="$v"
        PY_VERSION=$($v -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
        ok "Using $v ($PY_VERSION)"
        break
      fi
    done
    # Re-check after fallback
    PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
    PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
    if [[ "$PY_MAJOR" -lt 3 || "$PY_MINOR" -lt 10 ]]; then
      ERRORS=$((ERRORS + 1))
    fi
  fi
else
  fail "Python 3 not found"
  echo "     macOS: brew install python@3.13"
  echo "     Linux: apt install python3"
  ERRORS=$((ERRORS + 1))
fi

# -- tmux ----------------------------------------------------------
if command -v tmux &>/dev/null; then
  TMUX_VER=$(tmux -V 2>/dev/null || echo "unknown")
  ok "tmux ($TMUX_VER)"
else
  fail "tmux not found"
  echo "     macOS: brew install tmux"
  echo "     Linux: apt install tmux"
  ERRORS=$((ERRORS + 1))
fi

# -- jq (required by observer.sh and hook scripts) ------------------
if command -v jq &>/dev/null; then
  JQ_VER=$(jq --version 2>/dev/null || echo "unknown")
  ok "jq ($JQ_VER)"
else
  fail "jq not found (required by observer.sh and hook scripts)"
  echo "     macOS: brew install jq"
  echo "     Linux: apt install jq"
  ERRORS=$((ERRORS + 1))
fi

# -- Claude CLI (recommended, not fatal) --------------------------
if command -v claude &>/dev/null; then
  ok "Claude CLI found"
else
  warn "Claude CLI not found (recommended)"
  echo "     Install: curl -fsSL https://claude.ai/install.sh | bash"
fi

# -- Codex CLI (optional) -----------------------------------------
if command -v codex &>/dev/null; then
  ok "Codex CLI found"
  HAS_CODEX=1
else
  info "Codex CLI not found (optional)"
  echo "     Install: see https://github.com/openai/codex"
  HAS_CODEX=0
fi

# -- Gemini CLI (optional) ----------------------------------------
if command -v gemini &>/dev/null; then
  ok "Gemini CLI found"
  HAS_GEMINI=1
else
  info "Gemini CLI not found (optional)"
  echo "     Install: see https://github.com/google-gemini/gemini-cli"
  HAS_GEMINI=0
fi

echo ""

if [[ $ERRORS -gt 0 ]]; then
  fail "Preflight failed with $ERRORS error(s). Fix the issues above and re-run."
  exit 1
fi

ok "All preflight checks passed"
echo ""

# -- Signal directories for turn-completion hooks --------------------
mkdir -p "$SCRIPT_DIR/.urc/signals"
ok ".urc/signals/ directory ready"
echo ""

# ══════════════════════════════════════════════════════════════════════
# 2. VIRTUAL ENVIRONMENT
# ══════════════════════════════════════════════════════════════════════
echo "${BOLD}Virtual Environment${RESET}"
echo ""

VENV_DIR="$SCRIPT_DIR/.venv"

if [[ -d "$VENV_DIR" && -x "$VENV_DIR/bin/python3" ]]; then
  ok "Virtual environment already exists at .venv/"
else
  info "Creating virtual environment..."
  VENV_ERR=$(mktemp /tmp/urc-venv-err.XXXXXX)
  trap "rm -f '$VENV_ERR'" EXIT
  if ! "$PYTHON_CMD" -m venv "$VENV_DIR" 2>"$VENV_ERR"; then
    fail "Failed to create virtual environment"
    if grep -qi "externally-managed" "$VENV_ERR" 2>/dev/null; then
      echo ""
      echo "     ${YELLOW}PEP 668: Your Python is externally managed.${RESET}"
      echo "     This usually means Homebrew Python 3.12+ on macOS."
      echo ""
      echo "     Fix options:"
      echo "       1. Use a specific Python version:"
      echo "          python3.13 -m venv .venv"
      echo "       2. Install pyenv and use a pyenv-managed Python"
      echo ""
    else
      echo "     Error output:"
      cat "$VENV_ERR" 2>/dev/null || true
    fi
    rm -f "$VENV_ERR"
    exit 1
  fi
  rm -f "$VENV_ERR"
  ok "Virtual environment created at .venv/"
fi

# Activate for the rest of this script
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
ok "Virtual environment activated"
echo ""

# ══════════════════════════════════════════════════════════════════════
# 3. PIP INSTALL
# ══════════════════════════════════════════════════════════════════════
echo "${BOLD}Installing Dependencies${RESET}"
echo ""

info "Installing coordination server dependencies..."
if ! pip install --quiet -r "$SCRIPT_DIR/requirements.txt"; then
  fail "pip install failed — check network connectivity and Python environment"
  exit 1
fi
ok "Dependencies installed (see requirements.txt)"

# Verify imports
echo ""
info "Verifying imports..."
if "$VENV_DIR/bin/python3" -c "import mcp, yaml; print('Dependencies OK')" 2>/dev/null; then
  ok "All Python dependencies verified"
else
  fail "Import verification failed — check pip install output above"
  exit 1
fi
echo ""

# ══════════════════════════════════════════════════════════════════════
# 4. MCP CONFIG GENERATION
# ══════════════════════════════════════════════════════════════════════
echo "${BOLD}MCP Configuration${RESET}"
echo ""

# -- .mcp.json (Claude Code) --------------------------------------
MCP_JSON="$SCRIPT_DIR/.mcp.json"
if [[ -f "$MCP_JSON" ]]; then
  ok ".mcp.json already exists — skipping (review manually if needed)"
else
  cat > "$MCP_JSON" << 'MCPEOF'
{
  "mcpServers": {
    "urc-coordination": {
      "command": ".venv/bin/python3",
      "args": ["urc/core/coordination_server.py"],
      "env": { "PYTHONPATH": "." }
    },
    "urc-teams": {
      "command": ".venv/bin/python3",
      "args": ["urc/core/teams_server.py"],
      "env": { "PYTHONPATH": "." }
    }
  }
}
MCPEOF
  ok ".mcp.json created for Claude Code"
fi

# -- .codex/config.toml (Codex) -----------------------------------
if [[ $HAS_CODEX -eq 1 ]]; then
  CODEX_DIR="$SCRIPT_DIR/.codex"
  CODEX_TOML="$CODEX_DIR/config.toml"
  if [[ -f "$CODEX_TOML" ]]; then
    ok ".codex/config.toml already exists — skipping"
  else
    mkdir -p "$CODEX_DIR"
    cat > "$CODEX_TOML" << 'CODEXEOF'
# URC project-scoped Codex configuration
project_doc_max_bytes = 65536
developer_instructions = "You are part of the URC multi-CLI system. See AGENTS.md for full protocol."
sandbox_mode = "workspace-write"
# Required for RC Bridge: dispatched messages must execute without interactive approval prompts
approval_policy = "never"
notify = ["bash", "__PROJECT_ROOT__/urc/core/turn-complete-hook.sh"]

[sandbox_workspace_write]
network_access = false

[history]
# Preserves session history for debugging cross-CLI interactions
persistence = "save-all"

# ── MCP Servers ──────────────────────────────────────────────────────
[mcp_servers.urc-coordination]
command = ".venv/bin/python3"
args = ["urc/core/coordination_server.py"]

[mcp_servers.urc-coordination.env]
PYTHONPATH = "."

[mcp_servers.urc-teams]
command = ".venv/bin/python3"
args = ["urc/core/teams_server.py"]

[mcp_servers.urc-teams.env]
PYTHONPATH = "."
CODEXEOF
    # Inject absolute path for hook command (heredoc can't expand variables)
    sed -i.bak "s|__PROJECT_ROOT__|$SCRIPT_DIR|g" "$CODEX_TOML" && rm -f "$CODEX_TOML.bak"
    ok ".codex/config.toml created for Codex"
  fi

  # -- Codex project trust (required for Codex v0.107+) ---------------
  # Codex won't read project-scoped config.toml unless the directory
  # is explicitly trusted in the global ~/.codex/config.toml.
  CODEX_GLOBAL="$HOME/.codex/config.toml"
  if [[ -f "$CODEX_GLOBAL" ]] && grep -qF "$SCRIPT_DIR" "$CODEX_GLOBAL" 2>/dev/null; then
    ok "Project already trusted in ~/.codex/config.toml"
  else
    echo ""
    warn "Codex project trust not configured"
    echo ""
    echo "     Codex requires projects to be explicitly trusted before"
    echo "     it reads project-scoped .codex/config.toml files."
    echo ""
    echo "     Add the following to ${BOLD}~/.codex/config.toml${RESET}:"
    echo ""
    echo "       ${CYAN}[projects.\"$SCRIPT_DIR\"]${RESET}"
    echo "       ${CYAN}trust_level = \"trusted\"${RESET}"
    echo ""
    echo "     Or launch Codex in this directory and approve the trust"
    echo "     prompt when it appears."
    echo ""
  fi
fi

# -- .gemini/settings.json (Gemini) --------------------------------
if [[ $HAS_GEMINI -eq 1 ]]; then
  GEMINI_DIR="$SCRIPT_DIR/.gemini"
  GEMINI_JSON="$GEMINI_DIR/settings.json"
  if [[ -f "$GEMINI_JSON" ]]; then
    ok ".gemini/settings.json already exists — skipping"
  else
    mkdir -p "$GEMINI_DIR"
    cat > "$GEMINI_JSON" << 'GEMINIEOF'
{
  "experimental": {
    "enableAgents": true
  },
  "tools": {
    "mcpServers": {
      "urc_coordination": {
        "command": ".venv/bin/python3",
        "args": ["urc/core/coordination_server.py"],
        "env": { "PYTHONPATH": "." }
      },
      "urc_teams": {
        "command": ".venv/bin/python3",
        "args": ["urc/core/teams_server.py"],
        "env": { "PYTHONPATH": "." }
      }
    }
  },
  "hooks": {
    "AfterAgent": [
      {
        "matcher": "*",
        "hooks": [
          {
            "name": "turn-signal",
            "type": "command",
            "command": "bash __PROJECT_ROOT__/urc/core/turn-complete-hook.sh"
          }
        ]
      }
    ]
  }
}
GEMINIEOF
    # Inject absolute path for hook command (heredoc can't expand variables)
    sed -i.bak "s|__PROJECT_ROOT__|$SCRIPT_DIR|g" "$GEMINI_JSON" && rm -f "$GEMINI_JSON.bak"
    ok ".gemini/settings.json created for Gemini"
  fi
fi

echo ""

# ══════════════════════════════════════════════════════════════════════
# 5. VERIFICATION
# ══════════════════════════════════════════════════════════════════════
echo "${BOLD}Verification${RESET}"
echo ""

info "Testing coordination server imports..."
if PYTHONPATH="$SCRIPT_DIR" "$VENV_DIR/bin/python3" -c \
  "from urc.core import coordination_db, coordination_server; print('Server imports OK')" 2>/dev/null; then
  ok "Coordination server imports verified"
else
  warn "Coordination server import check failed — server may still work via MCP"
fi

info "Running coordination server self-test..."
if PYTHONPATH="$SCRIPT_DIR" "$VENV_DIR/bin/python3" \
  "$SCRIPT_DIR/urc/core/coordination_server.py" --self-test 2>/dev/null; then
  ok "Coordination server self-test passed"
else
  warn "Coordination server self-test failed — check logs"
fi

info "Running teams server self-test..."
if PYTHONPATH="$SCRIPT_DIR" "$VENV_DIR/bin/python3" \
  "$SCRIPT_DIR/urc/core/teams_server.py" --self-test 2>/dev/null; then
  ok "Teams server self-test passed"
else
  warn "Teams server self-test failed — check logs"
fi

echo ""

# ══════════════════════════════════════════════════════════════════════
# 6. SUMMARY + NEXT STEPS
# ══════════════════════════════════════════════════════════════════════
echo "${BOLD}Setup Complete${RESET}"
echo "=================================="
echo ""
echo "  Python:      $PYTHON_CMD ($PY_VERSION)"
echo "  Venv:        .venv/"
echo "  MCP config:  .mcp.json"
[[ $HAS_CODEX -eq 1 ]]  && echo "  Codex:       .codex/config.toml"
[[ $HAS_GEMINI -eq 1 ]] && echo "  Gemini:      .gemini/settings.json"
echo ""
echo "${BOLD}Next Steps${RESET}"
echo ""
echo "  1. Start a tmux session:  tmux new -s urc"
echo "  2. Launch Claude Code and use /urc to bridge panes"
echo ""
echo "  See docs/getting-started.md for the full walkthrough."
echo ""
