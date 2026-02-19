#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- PID-Based Locking Library
# ============================================================================
# Provides semaphore management for coordinating concurrent LLM task
# executions. Each lock is a file containing the PID of the owning process.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/locking.sh"
#
#   lock_acquire "claude" "my-task"     # Create lock for current PID
#   lock_check "claude" "my-task"       # Check if locked by living process
#   lock_get_pid "claude" "my-task"     # Get PID from lock file
#   lock_count "claude"                 # Count active locks for an LLM
#   lock_release "claude" "my-task"     # Remove lock file
#   lock_cleanup_stale                  # Remove all locks for dead PIDs
#
# Lock Storage:
#   $STATE_DIR/locks/<llm-name>/<task-name>.lock
#   Each file contains only the PID of the owning process.
#
# Return Codes:
#   0 = success
#   1 = failure (lock exists, invalid params, etc.)
#
# Dependencies:
#   - config.sh must be sourced first (provides STATE_DIR)
# ============================================================================

# --- Private Helpers ---

# Construct the lock file path with input validation
_lock_get_path() {
    local llm_name="$1"
    local task_name="$2"

    # Validate inputs - reject path traversal
    if [[ "$llm_name" == *"/"* ]] || [[ "$llm_name" == *".."* ]]; then
        return 1
    fi
    if [[ "$task_name" == *"/"* ]] || [[ "$task_name" == *".."* ]]; then
        return 1
    fi

    echo "$STATE_DIR/locks/${llm_name}/${task_name}.lock"
}

# Check if a PID is alive
_lock_is_pid_alive() {
    local pid="$1"

    # Validate PID is numeric
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    kill -0 "$pid" 2>/dev/null
}

# Ensure the lock directory exists for an LLM
_lock_ensure_dir() {
    local llm_name="$1"

    if [[ -z "$STATE_DIR" ]]; then
        return 1
    fi

    mkdir -p "$STATE_DIR/locks/${llm_name}" 2>/dev/null || true
}

# --- Public API ---

# lock_acquire <llm_name> <task_name>
# Creates a lock file with the current PID.
# Returns 0 on success, 1 if already locked by another living process.
lock_acquire() {
    local llm_name="$1"
    local task_name="$2"

    if [[ -z "$STATE_DIR" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    if [[ -z "$llm_name" ]] || [[ -z "$task_name" ]]; then
        echo "ERROR: lock_acquire requires llm_name and task_name" >&2
        return 1
    fi

    local lock_path
    lock_path="$(_lock_get_path "$llm_name" "$task_name")" || return 1

    # Check for existing lock
    if [[ -f "$lock_path" ]]; then
        local existing_pid
        existing_pid="$(cat "$lock_path" 2>/dev/null)"
        if _lock_is_pid_alive "$existing_pid"; then
            # Lock is held by a living process
            return 1
        fi
        # Stale lock - remove it
        rm -f "$lock_path" 2>/dev/null || true
    fi

    # Create lock directory and write PID
    _lock_ensure_dir "$llm_name"
    echo "$$" > "$lock_path"

    # Verify we wrote our PID (simple race condition check)
    local written_pid
    written_pid="$(cat "$lock_path" 2>/dev/null)"
    if [[ "$written_pid" != "$$" ]]; then
        return 1
    fi

    return 0
}

# lock_release <llm_name> <task_name>
# Removes the lock file. Idempotent - succeeds even if lock doesn't exist.
lock_release() {
    local llm_name="$1"
    local task_name="$2"

    if [[ -z "$STATE_DIR" ]]; then
        return 1
    fi

    if [[ -z "$llm_name" ]] || [[ -z "$task_name" ]]; then
        return 1
    fi

    local lock_path
    lock_path="$(_lock_get_path "$llm_name" "$task_name")" || return 1

    rm -f "$lock_path" 2>/dev/null || true
    return 0
}

# lock_check <llm_name> <task_name>
# Returns 0 if locked by a living process, 1 otherwise.
lock_check() {
    local llm_name="$1"
    local task_name="$2"

    if [[ -z "$STATE_DIR" ]]; then
        return 1
    fi

    if [[ -z "$llm_name" ]] || [[ -z "$task_name" ]]; then
        return 1
    fi

    local lock_path
    lock_path="$(_lock_get_path "$llm_name" "$task_name")" || return 1

    if [[ ! -f "$lock_path" ]]; then
        return 1
    fi

    local pid
    pid="$(cat "$lock_path" 2>/dev/null)"

    if _lock_is_pid_alive "$pid"; then
        return 0
    fi

    return 1
}

# lock_get_pid <llm_name> <task_name>
# Outputs the PID from the lock file. Returns 1 if no lock exists.
lock_get_pid() {
    local llm_name="$1"
    local task_name="$2"

    if [[ -z "$STATE_DIR" ]]; then
        return 1
    fi

    if [[ -z "$llm_name" ]] || [[ -z "$task_name" ]]; then
        return 1
    fi

    local lock_path
    lock_path="$(_lock_get_path "$llm_name" "$task_name")" || return 1

    if [[ ! -f "$lock_path" ]]; then
        return 1
    fi

    cat "$lock_path" 2>/dev/null
}

# lock_count <llm_name>
# Outputs the count of active locks (with living PIDs) for the given LLM.
lock_count() {
    local llm_name="$1"

    if [[ -z "$STATE_DIR" ]]; then
        echo "0"
        return 1
    fi

    if [[ -z "$llm_name" ]]; then
        echo "0"
        return 1
    fi

    # Validate input
    if [[ "$llm_name" == *"/"* ]] || [[ "$llm_name" == *".."* ]]; then
        echo "0"
        return 1
    fi

    local lock_dir="$STATE_DIR/locks/${llm_name}"
    if [[ ! -d "$lock_dir" ]]; then
        echo "0"
        return 0
    fi

    local count=0
    for lock_file in "$lock_dir"/*.lock; do
        [[ -f "$lock_file" ]] || continue
        local pid
        pid="$(cat "$lock_file" 2>/dev/null)"
        if _lock_is_pid_alive "$pid"; then
            count=$((count + 1))
        fi
    done

    echo "$count"
}

# lock_cleanup_stale
# Removes lock files for dead PIDs across all LLMs.
# Outputs the count of cleaned locks.
lock_cleanup_stale() {
    if [[ -z "$STATE_DIR" ]]; then
        echo "0"
        return 1
    fi

    local locks_dir="$STATE_DIR/locks"
    if [[ ! -d "$locks_dir" ]]; then
        echo "0"
        return 0
    fi

    local cleaned=0
    for llm_dir in "$locks_dir"/*/; do
        [[ -d "$llm_dir" ]] || continue
        for lock_file in "$llm_dir"*.lock; do
            [[ -f "$lock_file" ]] || continue
            local pid
            pid="$(cat "$lock_file" 2>/dev/null)"
            if ! _lock_is_pid_alive "$pid"; then
                rm -f "$lock_file" 2>/dev/null || true
                cleaned=$((cleaned + 1))
            fi
        done
    done

    echo "$cleaned"
}
