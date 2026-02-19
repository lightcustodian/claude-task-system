#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- File Watcher
# ============================================================================
# Detection layer that monitors task directories for file changes and writes
# events to the event queue. Uses inotifywait for immediate detection with
# a polling fallback.
#
# This script does NOT directly invoke LLMs -- it only detects changes and
# notifies via the event queue. Deduplication happens at event consumption.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/turn-detection.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/event-queue.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/watcher.sh"
#
#   watcher_init
#   watcher_run_inotify &    # Start inotifywait watcher (background)
#   watcher_run_poller       # Start polling loop (foreground)
#
# Skip Logic:
#   - Files directly in VAULT_TASKS_DIR root (e.g., CLAUDE.md)
#   - _status.md files (metadata files)
#   - Hidden directories (starting with '.')
#
# Event Types Written:
#   file_ready   -- User turn + readiness check passes
#   stop_signal  -- <Stop> detected on its own line
#
# Dependencies:
#   - config.sh (VAULT_TASKS_DIR, POLL_INTERVAL, INOTIFY_SETTLE_DELAY)
#   - lib/logging.sh
#   - lib/turn-detection.sh (detect_turn, check_readiness, detect_stop, get_latest_md)
#   - lib/event-queue.sh (queue_init, queue_write)
# ============================================================================

set -euo pipefail

# --- Private Helpers ---

# Check if inotifywait is available
_watcher_check_inotify_available() {
    command -v inotifywait &>/dev/null
}

# Determine if a file should be skipped
# Args: $1 = relative path from VAULT_TASKS_DIR
# Returns: 0 if should skip, 1 if should process
_watcher_should_skip_file() {
    local relative="$1"
    local task_name="${relative%%/*}"
    local filename
    filename="$(basename "$relative")"

    # Skip files directly in VAULT_TASKS_DIR root (no subdirectory)
    if [[ "$relative" == "$task_name" ]]; then
        return 0
    fi

    # Skip _status.md files
    if [[ "$filename" == "_status.md" ]]; then
        return 0
    fi

    # Skip hidden directories
    if [[ "$task_name" == .* ]]; then
        return 0
    fi

    # Should process this file
    return 1
}

# Core processing logic for a task directory
# Args: $1 = task directory path
_watcher_process_task() {
    local task_dir="$1"
    local task_name
    task_name="$(basename "$task_dir")"

    # Get latest .md file
    local latest
    latest="$(get_latest_md "$task_dir")"
    if [[ -z "$latest" ]]; then
        return
    fi

    # Check for stop signal first
    if detect_stop "$task_dir" "$latest"; then
        log INFO "[$task_name] Stop signal detected in $latest"
        queue_write "stop_signal" "$task_name" "$latest" ""
        return
    fi

    # Detect whose turn it is
    local turn
    turn="$(detect_turn "$task_dir" "$latest")"

    case "$turn" in
        claude)
            # Unedited Claude response -- waiting for user
            log DEBUG "[$task_name] Waiting for user to edit $latest"
            return
            ;;
        user|edited)
            # User's file or annotated response -- check readiness
            if check_readiness "$task_dir" "$latest"; then
                log INFO "[$task_name] File ready: $latest"
                queue_write "file_ready" "$task_name" "$latest" ""
            fi
            ;;
    esac
}

# inotifywait event handler loop
_watcher_inotify_loop() {
    log INFO "Starting inotifywait watcher on $VAULT_TASKS_DIR"

    inotifywait -m -r \
        --event close_write \
        --include '.*\.md$' \
        --format '%w%f' \
        "$VAULT_TASKS_DIR" 2>/dev/null | while read -r changed_file; do

        # Determine relative path and task directory
        local relative="${changed_file#$VAULT_TASKS_DIR/}"
        local task_name="${relative%%/*}"
        local task_dir="$VAULT_TASKS_DIR/$task_name"

        # Apply skip logic
        if _watcher_should_skip_file "$relative"; then
            continue
        fi

        # Skip if not a real directory
        [[ -d "$task_dir" ]] || continue

        log DEBUG "inotify: change detected in $changed_file"

        # Small delay to let file writes settle (Google Drive FUSE can be bursty)
        sleep "${INOTIFY_SETTLE_DELAY:-2}"

        _watcher_process_task "$task_dir"
    done
}

# Polling loop implementation
_watcher_polling_loop() {
    log INFO "Starting polling watcher (interval: ${POLL_INTERVAL}s)"

    while true; do
        for task_dir in "$VAULT_TASKS_DIR"/*/; do
            [[ -d "$task_dir" ]] || continue

            local dirname
            dirname="$(basename "$task_dir")"

            # Skip hidden directories
            [[ "$dirname" == .* ]] && continue

            _watcher_process_task "$task_dir"
        done

        sleep "${POLL_INTERVAL:-30}"
    done
}

# --- Public API ---

# Initialize the watcher subsystem and event queue
watcher_init() {
    if [[ -z "${VAULT_TASKS_DIR:-}" ]]; then
        log ERROR "VAULT_TASKS_DIR not set"
        return 1
    fi

    if [[ ! -d "$VAULT_TASKS_DIR" ]]; then
        log ERROR "VAULT_TASKS_DIR does not exist: $VAULT_TASKS_DIR"
        return 1
    fi

    queue_init
    log INFO "Watcher initialized"
}

# Start the inotifywait watcher (runs in foreground, call with & for background)
watcher_run_inotify() {
    if ! _watcher_check_inotify_available; then
        log WARN "inotifywait not available -- use watcher_run_poller instead"
        return 1
    fi

    _watcher_inotify_loop
}

# Start the polling loop (runs in foreground, call with & for background)
watcher_run_poller() {
    _watcher_polling_loop
}

# --- Standalone Entry Point ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/config.sh"
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/turn-detection.sh"
    source "${SCRIPT_DIR}/lib/event-queue.sh"

    watcher_init || exit 1

    # Start inotifywait in background if available, always run poller
    if command -v inotifywait >/dev/null 2>&1; then
        watcher_run_inotify &
    fi
    watcher_run_poller
fi
