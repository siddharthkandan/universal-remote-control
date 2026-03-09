#!/usr/bin/env bash
# test-cli-adapter.sh — tests for cli-adapter.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the adapter
. "$SCRIPT_DIR/cli-adapter.sh"

PASS=0; FAIL=0

_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL+1))
    fi
}

echo "=== Test 4: validate_pane_id ==="
# Valid pane IDs
_check "Valid: %0" validate_pane_id "%0"
_check "Valid: %42" validate_pane_id "%42"
_check "Valid: %99999" validate_pane_id "%99999"
# Invalid pane IDs (validate_pane_id should return non-zero)
validate_pane_id "42" && V42="valid" || V42="invalid"
_check "Invalid: 42 (no prefix)" test "$V42" = "invalid"
validate_pane_id "%" && VP="valid" || VP="invalid"
_check "Invalid: % (no digits)" test "$VP" = "invalid"
validate_pane_id "%abc" && VABC="valid" || VABC="invalid"
_check "Invalid: %abc (non-numeric)" test "$VABC" = "invalid"
validate_pane_id "" && VE="valid" || VE="invalid"
_check "Invalid: empty string" test "$VE" = "invalid"
validate_pane_id '%;DROP TABLE' && VINJ="valid" || VINJ="invalid"
_check "Invalid: injection attempt" test "$VINJ" = "invalid"

echo ""
echo "=== Test 5: paste_delay values ==="
_check "Gemini paste_delay is 0.15" test "$(paste_delay gemini)" = "0.15"
_check "Claude paste_delay is 0.15" test "$(paste_delay claude)" = "0.15"
_check "Codex paste_delay is 0.15" test "$(paste_delay codex)" = "0.15"
_check "Unknown paste_delay is 0.15" test "$(paste_delay unknown)" = "0.15"

echo ""
echo "=== Test 6: shell CLI type ==="
_check "Shell paste_delay is 0" test "$(paste_delay shell)" = "0"

# Invalid pane ID should default to "shell" (not "claude")
DEFAULT_CLI=$(detect_cli "invalid")
_check "Invalid pane defaults to shell" test "$DEFAULT_CLI" = "shell"

# Nonexistent pane (valid format, no DB entry, no tmux pane) should default to "shell"
UNKNOWN_CLI=$(detect_cli "%99987")
_check "Unknown pane defaults to shell" test "$UNKNOWN_CLI" = "shell"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
