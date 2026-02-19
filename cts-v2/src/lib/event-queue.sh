#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Event Queue Library
# ============================================================================
# Provides thread-safe event queue operations for concurrent process
# communication using flock for atomic operations.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/event-queue.sh"
#
#   queue_init                                          # Create queue
#   queue_write "file_ready" "my-task" "001.md" ""      # Write event
#   events=$(queue_read_all)                            # Read & clear
#
# Event Format:
#   TIMESTAMP|EVENT_TYPE|TASK_NAME|FILE|METADATA
#
# Event Types:
#   file_ready          -- A file is ready for processing
#   stop_signal         -- <Stop> tag detected
#   heartbeat_trigger   -- Heartbeat/periodic check
#   complexity_assessed -- Task complexity has been evaluated
#
# Atomic Behavior:
#   queue_write uses flock for exclusive append
#   queue_read_all uses flock for exclusive read + truncate
#
# Dependencies:
#   - config.sh must be sourced first (provides STATE_DIR)
# ============================================================================

# --- Private Helpers ---

# Get the queue file path
_queue_get_path() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi
    echo "$STATE_DIR/events/queue"
}

# Get the lock file path for flock coordination
_queue_get_lock_path() {
    echo "$STATE_DIR/events/queue.lock"
}

# Ensure the events directory exists
_queue_ensure_dir() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        return 1
    fi
    mkdir -p "$STATE_DIR/events" 2>/dev/null || true
}

# Validate event type is one of the known types
_queue_validate_event_type() {
    local event_type="$1"
    case "$event_type" in
        file_ready|stop_signal|heartbeat_trigger|complexity_assessed)
            return 0
            ;;
        *)
            echo "ERROR: Invalid event type: $event_type" >&2
            return 1
            ;;
    esac
}

# --- Public API ---

# queue_init
# Creates the events directory and queue file if they don't exist.
# Idempotent -- safe to call multiple times.
queue_init() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    _queue_ensure_dir

    local queue_file
    queue_file="$(_queue_get_path)" || return 1

    if [[ ! -f "$queue_file" ]]; then
        touch "$queue_file" 2>/dev/null || {
            echo "ERROR: Could not create queue file: $queue_file" >&2
            return 1
        }
    fi

    return 0
}

# queue_write <event_type> <task_name> <file> [metadata]
# Appends a formatted event line with ISO timestamp to the queue.
# Uses flock for atomic append.
# Returns 0 on success, 1 on failure.
queue_write() {
    local event_type="$1"
    local task_name="$2"
    local file="$3"
    local metadata="${4:-}"

    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    if [[ -z "$event_type" ]] || [[ -z "$task_name" ]] || [[ -z "$file" ]]; then
        echo "ERROR: queue_write requires event_type, task_name, and file" >&2
        return 1
    fi

    _queue_validate_event_type "$event_type" || return 1

    # Validate task_name (path traversal protection)
    if [[ "$task_name" == *"/"* ]] || [[ "$task_name" == *".."* ]]; then
        echo "ERROR: Invalid task name: $task_name" >&2
        return 1
    fi

    local queue_file
    queue_file="$(_queue_get_path)" || return 1

    local lock_file
    lock_file="$(_queue_get_lock_path)"

    _queue_ensure_dir

    local timestamp
    timestamp="$(date -Iseconds)"

    # Atomic append with flock
    {
        flock -x 9 || return 1
        echo "${timestamp}|${event_type}|${task_name}|${file}|${metadata}" >> "$queue_file"
    } 9>"$lock_file"
}

# queue_read_all
# Reads the entire queue and truncates it atomically.
# Outputs all events to stdout (one per line).
# Returns 0 on success (even if empty), 1 on failure.
queue_read_all() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    local queue_file
    queue_file="$(_queue_get_path)" || return 1

    local lock_file
    lock_file="$(_queue_get_lock_path)"

    if [[ ! -f "$queue_file" ]]; then
        return 0
    fi

    # Atomic read and truncate with flock
    {
        flock -x 9 || return 1
        cat "$queue_file"
        > "$queue_file"
    } 9>"$lock_file"
}
