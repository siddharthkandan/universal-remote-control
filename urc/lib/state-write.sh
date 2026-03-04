# state-write.sh — Unified atomic JSON read-modify-write with POSIX mkdir locking
#
# Provides:
#   sw_acquire_lock <lock_dir>          — acquire POSIX mkdir lock (returns 0 success, 1 failure)
#   sw_release_lock <lock_dir>          — release lock
#   sw_cleanup_locks                    — release ALL held locks (call from your EXIT trap)
#   sw_atomic_jq <file> <filter> [args] — lock + jq transform + atomic mv + unlock
#   sw_cas_claim <file> <task_id> <by>  — CAS task claim with version counter
#
# Usage:
#   source "${PROJECT_DIR}/urc/lib/state-write.sh"
#
#   # Single-write (most common): lock, transform, move, unlock in one call
#   sw_atomic_jq "$TASKS_FILE" '.tasks[0].status = "done"' --arg id "$ID"
#
#   # Multi-operation critical section: manual lock management
#   sw_acquire_lock "${FILE}.lock" || exit 1
#   VALUE=$(jq -r '.key' "$FILE")
#   # ... compute ...
#   jq --arg v "$NEW" '.key = $v' "$FILE" > "${FILE}.tmp.$$" && mv "${FILE}.tmp.$$" "$FILE"
#   sw_release_lock "${FILE}.lock"
#
# Callers MUST add sw_cleanup_locks to their own EXIT trap if using manual locks:
#   trap 'sw_cleanup_locks; your_other_cleanup' EXIT
#
# This library does NOT set any traps (avoids Bash 3.2 trap-clobber issue).

# Source guard: prevent double-sourcing (${:-} syntax for set -u compatibility)
[ -n "${_STATE_WRITE_LOADED:-}" ] && return 0
_STATE_WRITE_LOADED=1

# Internal: track all held locks for cleanup
_sw_held_locks=""

# sw_acquire_lock <lock_dir>
# Attempts to acquire a POSIX mkdir-based lock. Retries up to 10 times with 0.1s sleep.
# Breaks stale locks older than 5 seconds (handles macOS + Linux stat differences).
# Returns 0 on success, 1 on failure (proceeds unlocked — caller decides policy).
sw_acquire_lock() {
    local lock_dir="$1"
    local retries=0
    local delay=0.05
    while ! mkdir "$lock_dir" 2>/dev/null; do
        retries=$((retries + 1))
        if [ $retries -gt 20 ]; then
            if [ -d "$lock_dir" ]; then
                local lock_age
                if [ "$(uname)" = "Darwin" ]; then
                    lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || echo 0) ))
                else
                    lock_age=$(( $(date +%s) - $(stat -c %Y "$lock_dir" 2>/dev/null || echo 0) ))
                fi
                if [ "$lock_age" -gt 5 ]; then
                    # Stale lock — break it
                    rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null
                    continue
                fi
            fi
            return 1
        fi
        sleep "$delay"
        # Exponential backoff: 0.05, 0.1, 0.2 (capped)
        case "$delay" in
            0.05) delay=0.1 ;;
            0.1)  delay=0.2 ;;
        esac
    done
    _sw_held_locks="$_sw_held_locks $lock_dir"
    return 0
}

# sw_release_lock <lock_dir>
# Releases a single lock. Safe to call even if lock is not held.
sw_release_lock() {
    local lock_dir="$1"
    rmdir "$lock_dir" 2>/dev/null || true
    # Remove from held list
    local new_list=""
    for lk in $_sw_held_locks; do
        [ "$lk" = "$lock_dir" ] && continue
        new_list="$new_list $lk"
    done
    _sw_held_locks="$new_list"
}

# sw_cleanup_locks
# Releases ALL held locks. Call this from your EXIT trap.
sw_cleanup_locks() {
    for lk in $_sw_held_locks; do
        rmdir "$lk" 2>/dev/null || true
    done
    _sw_held_locks=""
}

# sw_atomic_jq <file> <jq_filter> [jq_args...]
# Atomic read-modify-write: acquires lock, runs jq transform, atomic mv, releases lock.
# Uses PID-namespaced tmp file to prevent concurrent clobbering.
# Returns 0 on success, 1 on jq/mv failure (original file preserved).
sw_atomic_jq() {
    local file="$1"; shift
    local filter="$1"; shift
    # Remaining args are passed to jq (e.g., --arg key val)

    local lock_dir="${file}.lock"
    local tmp="${file}.tmp.$$"

    if ! sw_acquire_lock "$lock_dir"; then
        # Fail-closed: do not write without lock (prevents concurrent corruption)
        return 1
    fi

    if jq "$filter" "$@" "$file" > "$tmp" && mv "$tmp" "$file"; then
        sw_release_lock "$lock_dir"
        return 0
    else
        rm -f "$tmp"
        sw_release_lock "$lock_dir"
        return 1
    fi
}

# sw_cas_claim <file> <task_id> <claimed_by>
# Compare-and-swap task claim using version counter.
# Reads task version, writes with version check, verifies both version increment
# and claimed_by match to avoid false positives from concurrent modifications.
# Returns 0 on success, 1 on CAS failure (task was modified by another agent).
sw_cas_claim() {
    local file="$1" task_id="$2" claimed_by="$3"
    local expected_version
    expected_version=$(jq -r ".tasks[] | select(.id == \"$task_id\") | .version // 0" "$file" 2>/dev/null)
    [ -z "$expected_version" ] && return 1
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    sw_atomic_jq "$file" \
      '(.tasks[] | select(.id == $id and (.version // 0) == ($v | tonumber) and .status == "pending")) |=
        (.status = "claimed" | .claimed_by = $by | .claimed_at = $at | .version = ((.version // 0) + 1))' \
      --arg id "$task_id" \
      --arg v "$expected_version" \
      --arg by "$claimed_by" \
      --arg at "$now" || return 1

    # Verify CAS succeeded: version incremented AND we are the claimer
    local result
    result=$(jq -r ".tasks[] | select(.id == \"$task_id\") | \"\(.version // 0)|\(.claimed_by // \"\")\"" "$file" 2>/dev/null)
    local new_version="${result%%|*}"
    local actual_claimer="${result#*|}"
    [ "$new_version" != "$expected_version" ] && [ "$actual_claimer" = "$claimed_by" ] && return 0
    return 1
}
