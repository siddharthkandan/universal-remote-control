#!/usr/bin/env bash
# circuit.sh — Circuit breaker for dispatch-and-wait.sh
#
# Usage: source this file, then call circuit_check/circuit_record.
#
# State: .urc/circuits/{PANE} — "state failures last_fail_epoch"
# Trip: 3 consecutive failures (timeout or failed, NOT busy)
# Half-open: After 120s, check pane aliveness. If alive, allow one probe.

_CIRCUIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.urc/circuits"
mkdir -p "$_CIRCUIT_DIR"

# circuit_check <pane_id>
# Returns 0 (closed/half-open, OK to dispatch) or 1 (open, fast fail)
# On open circuit, outputs JSON to stdout
circuit_check() {
    local pane="$1"
    local file="$_CIRCUIT_DIR/$pane"

    [ ! -f "$file" ] && return 0

    local state failures last_fail
    read -r state failures last_fail < "$file" 2>/dev/null || return 0

    if [ "$state" = "open" ]; then
        local now elapsed retry_after
        now=$(date +%s)
        elapsed=$((now - last_fail))
        retry_after=$((last_fail + 120))

        if [ "$elapsed" -ge 120 ]; then
            # Half-open: check if pane is alive
            if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q "^${pane}$"; then
                # Pane alive — allow one probe (mark half-open)
                echo "half_open $failures $last_fail" > "$file"
                return 0
            else
                # Pane dead — stay open
                jq -n --arg pane "$pane" --argjson failures "$failures" --argjson retry "$retry_after" \
                    '{status:"circuit_open",pane:$pane,failures:$failures,retry_after:$retry,reason:"pane dead"}'
                return 1
            fi
        else
            jq -n --arg pane "$pane" --argjson failures "$failures" --argjson retry "$retry_after" \
                '{status:"circuit_open",pane:$pane,failures:$failures,retry_after:$retry}'
            return 1
        fi
    fi

    return 0
}

# circuit_record <pane_id> <status>
# status: "completed" = success, "timeout"/"failed" = failure, "busy" = ignored
circuit_record() {
    local pane="$1"
    local status="$2"
    local file="$_CIRCUIT_DIR/$pane"

    case "$status" in
        completed)
            # Success — reset circuit
            rm -f "$file"
            ;;
        timeout|failed)
            local state failures last_fail
            if [ -f "$file" ]; then
                read -r state failures last_fail < "$file" 2>/dev/null || { state="closed"; failures=0; }
            else
                state="closed"
                failures=0
            fi
            failures=$((failures + 1))
            local now
            now=$(date +%s)
            if [ "$failures" -ge 3 ]; then
                echo "open $failures $now" > "$file"
            else
                echo "closed $failures $now" > "$file"
            fi
            ;;
        busy)
            # Busy is not a failure — don't count
            ;;
    esac
}
