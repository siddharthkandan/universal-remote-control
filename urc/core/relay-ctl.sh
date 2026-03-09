#!/usr/bin/env bash
# relay-ctl.sh — Manage $0 relay configuration
#
# Usage:
#   relay-ctl.sh on                  Enable relay (creates config if needed)
#   relay-ctl.sh off                 Disable relay (removes config)
#   relay-ctl.sh add <name> <%NNN>   Add/update target pane
#   relay-ctl.sh remove <name>       Remove a target
#   relay-ctl.sh status              Show current config

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG="$PROJECT_ROOT/.urc/relay-config.json"
mkdir -p "$PROJECT_ROOT/.urc"

case "${1:-status}" in
    on)
        if [ ! -f "$CONFIG" ]; then
            echo '{"targets":{},"default":"codex","enabled":true}' | jq . > "$CONFIG"
            echo "Relay enabled (empty config created). Add targets: relay-ctl.sh add codex %NNN"
        else
            jq '.enabled = true' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
            echo "Relay enabled."
        fi
        ;;
    off)
        if [ -f "$CONFIG" ]; then
            jq '.enabled = false' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
            echo "Relay disabled."
        else
            echo "No relay config found."
        fi
        ;;
    add)
        NAME="${2:?Usage: relay-ctl.sh add <name> <%NNN>}"
        PANE="${3:?Usage: relay-ctl.sh add <name> <%NNN>}"
        NAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
        if [[ ! "$PANE" =~ ^%[0-9]+$ ]]; then
            echo "Invalid pane ID format: $PANE (expected %NNN)"
            exit 1
        fi
        if [ ! -f "$CONFIG" ]; then
            echo '{"targets":{},"default":"codex","enabled":true}' | jq . > "$CONFIG"
        fi
        jq --arg name "$NAME" --arg pane "$PANE" '.targets[$name] = $pane | .enabled = true' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
        echo "Added target: $NAME → $PANE"
        ;;
    remove)
        NAME="${2:?Usage: relay-ctl.sh remove <name>}"
        NAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
        if [ -f "$CONFIG" ]; then
            jq --arg name "$NAME" 'del(.targets[$name])' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
            echo "Removed target: $NAME"
        else
            echo "No relay config found."
        fi
        ;;
    status)
        if [ -f "$CONFIG" ]; then
            echo "=== Relay Config ==="
            cat "$CONFIG" | jq .
            echo ""
            # Check pane liveness
            for name in $(jq -r '.targets | keys[]' "$CONFIG" 2>/dev/null); do
                pane=$(jq -r --arg k "$name" '.targets[$k]' "$CONFIG")
                if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q "^${pane}$"; then
                    echo "  $name ($pane): ALIVE"
                else
                    echo "  $name ($pane): DEAD"
                fi
            done
        else
            echo "No relay config. Run: relay-ctl.sh add codex %NNN"
        fi
        ;;
    *)
        echo "Usage: relay-ctl.sh {on|off|add|remove|status}"
        exit 1
        ;;
esac
