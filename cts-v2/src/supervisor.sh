#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Supervisor
# ============================================================================
# Main entry point (systemd ExecStart) that manages child processes:
# watcher.sh and scheduler.sh. Monitors PIDs, restarts crashed children,
# and handles graceful shutdown.
#
# Usage:
#   ./supervisor.sh [--dry-run]
#
# Children Managed:
#   1. watcher.sh        -- File change detection (inotify + polling)
#   2. scheduler.sh      -- Event processing and LLM dispatch
#
# Features:
#   - Creates all required state directories on startup
#   - Cleans stale locks on startup
#   - Starts watcher.sh and scheduler.sh as background processes
#   - Monitors child PIDs every 5 seconds and restarts dead children
#   - Sends ntfy alert if child restarts >5 times in 5 minutes
#   - Graceful shutdown on SIGTERM: kills children, cleans locks
#   - Dry run mode with --dry-run flag (passed as DRY_RUN=1)
#
# State Directories Created:
#   $STATE_DIR/locks/claude/, $STATE_DIR/locks/ollama/
#   $STATE_DIR/sessions/
#   $STATE_DIR/events/
#   $STATE_DIR/audit/
#   $STATE_DIR/partial/
#   $STATE_DIR/usage/
#   $STATE_DIR/reports/daily/
#   $STATE_DIR/logs/
#
# Dependencies:
#   - config.sh (STATE_DIR, VAULT_TASKS_DIR, etc.)
#   - lib/logging.sh
#   - lib/locking.sh
#   - lib/turn-detection.sh
#   - lib/event-queue.sh
#   - lib/notifications.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/locking.sh"
source "$SCRIPT_DIR/lib/turn-detection.sh"
source "$SCRIPT_DIR/lib/event-queue.sh"
source "$SCRIPT_DIR/lib/notifications.sh"

# --- Configuration ---

# Maximum restarts per 5-minute window before alerting
MAX_RESTARTS="${MAX_RESTARTS:-5}"

# Time window for restart rate limiting (seconds)
RESTART_WINDOW="${RESTART_WINDOW:-300}"  # 5 minutes

# Monitoring interval (seconds)
MONITOR_INTERVAL="${MONITOR_INTERVAL:-5}"

# Shutdown timeout (seconds)
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-30}"

# Child process PIDs (0 = not running)
WATCHER_PID=0
SCHEDULER_PID=0

# Restart tracking
RESTART_COUNT_WATCHER=0
RESTART_COUNT_SCHEDULER=0
RESTART_WINDOW_START=0

# Shutdown flag
SHUTDOWN_REQUESTED=0

# --- Private Helpers ---

# Signal handler for SIGTERM/SIGINT
_supervisor_signal_handler() {
    SHUTDOWN_REQUESTED=1
    _supervisor_graceful_shutdown
    exit 130  # Standard exit code for SIGINT
}

# Create all required state directories
_supervisor_create_directories() {
    log INFO "Creating state directories"

    local dirs=(
        "$STATE_DIR/locks/claude"
        "$STATE_DIR/locks/ollama"
        "$STATE_DIR/sessions"
        "$STATE_DIR/events"
        "$STATE_DIR/audit"
        "$STATE_DIR/partial"
        "$STATE_DIR/usage"
        "$STATE_DIR/reports/daily"
        "$STATE_DIR/logs"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" 2>/dev/null || {
            log ERROR "Failed to create directory: $dir"
            return 1
        }
    done

    log INFO "State directories created successfully"
    return 0
}

# Clean stale locks on startup
_supervisor_clean_stale_locks() {
    log INFO "Cleaning stale locks"

    local cleaned
    cleaned="$(lock_cleanup_stale 2>/dev/null || echo 0)"

    if [[ "$cleaned" -gt 0 ]]; then
        log INFO "Cleaned $cleaned stale lock(s)"
    else
        log DEBUG "No stale locks to clean"
    fi

    return 0
}

# Check restart rate limit and reset window if expired
_supervisor_check_reset_window() {
    local now
    now="$(date +%s)"

    # Reset window if more than RESTART_WINDOW seconds have passed
    if [[ -n "$RESTART_WINDOW_START" ]] && [[ $(( now - RESTART_WINDOW_START )) -ge "$RESTART_WINDOW" ]]; then
        log DEBUG "Restart window expired, resetting counters"
        RESTART_COUNT_WATCHER=0
        RESTART_COUNT_SCHEDULER=0
        RESTART_WINDOW_START="$now"
    fi
}

# Check and restart a child process if dead
# Args: $1 = child_name, $2 = pid_var_name, $3 = restart_count_var_name, $4 = script_path
_supervisor_check_and_restart() {
    local child_name="$1"
    local pid_var_name="$2"
    local restart_count_var_name="$3"
    local script_path="$4"

    # Get current PID using indirect reference
    local pid
    pid="${!pid_var_name}"

    # Check if PID is alive (skip if PID is 0 or unset)
    if [[ "$pid" -eq 0 ]] || [[ -z "$pid" ]]; then
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        # Process is alive
        return 0
    fi

    # Process is dead
    log WARN "$child_name (PID $pid) has died"

    # Get restart count using indirect reference
    local restart_count
    restart_count="${!restart_count_var_name}"

    # Check restart rate limit
    _supervisor_check_reset_window

    # Update restart count using indirect reference
    restart_count="${!restart_count_var_name}"

    if [[ "$restart_count" -ge "$MAX_RESTARTS" ]]; then
        log ERROR "$child_name has exceeded max restarts ($MAX_RESTARTS in ${RESTART_WINDOW}s). Giving up."
        notify_priority "Supervisor Alert" "$child_name has crashed $restart_count times in 5 minutes. Stopping restart attempts."
        # Don't retry anymore
        return 1
    fi

    # Increment restart count
    restart_count=$((restart_count + 1))
    eval "$restart_count_var_name=$restart_count"

    log INFO "Restarting $child_name (attempt $restart_count/$MAX_RESTARTS)"

    # Check if script exists
    if [[ ! -f "$script_path" ]]; then
        log ERROR "Script not found: $script_path"
        return 1
    fi

    # Restart the child
    local log_file="$STATE_DIR/logs/${child_name}.log"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: Would restart $child_name"
        return 0
    fi

    # Start child in background with stderr redirection
    "$script_path" >> "$log_file" 2>&1 &
    local new_pid=$!

    # Update PID variable using indirect reference
    eval "$pid_var_name=$new_pid"

    log INFO "Restarted $child_name (new PID $new_pid)"
    return 0
}

# Graceful shutdown: send SIGTERM to all children, wait, then SIGKILL
_supervisor_graceful_shutdown() {
    log INFO "Supervisor shutting down..."

    local pids=()
    local names=()

    # Collect running children
    if [[ "$WATCHER_PID" -ne 0 ]] && kill -0 "$WATCHER_PID" 2>/dev/null; then
        pids+=("$WATCHER_PID")
        names+=("watcher")
    fi

    if [[ "$SCHEDULER_PID" -ne 0 ]] && kill -0 "$SCHEDULER_PID" 2>/dev/null; then
        pids+=("$SCHEDULER_PID")
        names+=("scheduler")
    fi

    if [[ ${#pids[@]} -eq 0 ]]; then
        log INFO "No children running, exiting immediately"
        return 0
    fi

    # Send SIGTERM to all children
    for i in "${!pids[@]}"; do
        local pid="${pids[$i]}"
        local name="${names[$i]}"
        log INFO "Sending SIGTERM to $name (PID $pid)"
        kill -TERM "$pid" 2>/dev/null || true
    done

    # Wait for children to exit (with timeout)
    local waited=0
    while [[ "$waited" -lt "$SHUTDOWN_TIMEOUT" ]]; do
        local all_dead=true
        for i in "${!pids[@]}"; do
            local pid="${pids[$i]}"
            if kill -0 "$pid" 2>/dev/null; then
                all_dead=false
                break
            fi
        done

        if $all_dead; then
            log INFO "All children terminated gracefully"
            break
        fi

        sleep 1
        waited=$((waited + 1))
    done

    # Force kill any remaining children
    for i in "${!pids[@]}"; do
        local pid="${pids[$i]}"
        local name="${names[$i]}"
        if kill -0 "$pid" 2>/dev/null; then
            log WARN "Force killing $name (PID $pid)"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done

    # Clean up locks
    log INFO "Cleaning up locks"
    lock_cleanup_stale >/dev/null 2>&1 || true

    log INFO "Supervisor shutdown complete"
}

# Send notification about child status
_supervisor_send_notification() {
    local title="$1"
    local message="$2"

    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        notify_priority "$title" "$message"
    else
        log INFO "DRY_RUN: Would send notification: $title - $message"
    fi
}

# Start watcher.sh
_supervisor_start_watcher() {
    local script_path="$SCRIPT_DIR/watcher.sh"
    local log_file="$STATE_DIR/logs/watcher.log"

    if [[ ! -f "$script_path" ]]; then
        log ERROR "watcher.sh not found at $script_path"
        return 1
    fi

    log INFO "Starting watcher.sh"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: Would start watcher.sh"
        WATCHER_PID=1  # Fake PID for dry run
        return 0
    fi

    # Source and run watcher in background
    "$script_path" >> "$log_file" 2>&1 &
    WATCHER_PID=$!

    log INFO "Started watcher.sh (PID $WATCHER_PID)"
    return 0
}

# Start scheduler.sh
_supervisor_start_scheduler() {
    local script_path="$SCRIPT_DIR/scheduler.sh"
    local log_file="$STATE_DIR/logs/scheduler.log"

    if [[ ! -f "$script_path" ]]; then
        log ERROR "scheduler.sh not found at $script_path"
        return 1
    fi

    log INFO "Starting scheduler.sh"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: Would start scheduler.sh"
        SCHEDULER_PID=1  # Fake PID for dry run
        return 0
    fi

    # Source and run scheduler in background
    "$script_path" >> "$log_file" 2>&1 &
    SCHEDULER_PID=$!

    log INFO "Started scheduler.sh (PID $SCHEDULER_PID)"
    return 0
}

# --- Public API ---

# Initialize supervisor (create directories, clean locks)
supervisor_init() {
    log INFO "Supervisor initializing"

    _supervisor_create_directories || return 1
    _supervisor_clean_stale_locks || return 1

    log INFO "Supervisor initialized"
    return 0
}

# Main supervisor loop
supervisor_run() {
    log INFO "Claude Task System v2 supervisor starting"
    log INFO "State directory: $STATE_DIR"

    # Set up signal handlers
    trap _supervisor_signal_handler SIGINT SIGTERM

    # Initialize
    supervisor_init || {
        log ERROR "Supervisor initialization failed"
        exit 1
    }

    # Start children
    _supervisor_start_watcher || {
        log WARN "Failed to start watcher, continuing anyway"
    }

    _supervisor_start_scheduler || {
        log WARN "Failed to start scheduler, continuing anyway"
    }

    # Initialize restart window start time
    RESTART_WINDOW_START="$(date +%s)"

    # Main monitoring loop
    log INFO "Starting monitoring loop (interval: ${MONITOR_INTERVAL}s)"

    while true; do
        # Check if shutdown requested
        if [[ "$SHUTDOWN_REQUESTED" -eq 1 ]]; then
            break
        fi

        # Check and restart watcher if needed
        if [[ "$WATCHER_PID" -ne 0 ]]; then
            _supervisor_check_and_restart "watcher" "WATCHER_PID" "RESTART_COUNT_WATCHER" "$SCRIPT_DIR/watcher.sh" || true
        fi

        # Check and restart scheduler if needed
        if [[ "$SCHEDULER_PID" -ne 0 ]]; then
            _supervisor_check_and_restart "scheduler" "SCHEDULER_PID" "RESTART_COUNT_SCHEDULER" "$SCRIPT_DIR/scheduler.sh" || true
        fi

        # Sleep until next cycle
        sleep "$MONITOR_INTERVAL"
    done

    log INFO "Supervisor main loop exited"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                export DRY_RUN=1
                log INFO "Dry run mode enabled"
                shift
                ;;
            *)
                log ERROR "Unknown option: $1"
                echo "Usage: $0 [--dry-run]" >&2
                exit 1
                ;;
        esac
    done

    supervisor_run
fi
