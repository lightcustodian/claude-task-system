#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Event Scheduler
# ============================================================================
# Reads events from the queue and invokes LLMs. Main loop runs continuously,
# checking queue every SCHEDULER_CYCLE seconds (default: 2).
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/locking.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/event-queue.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/notifications.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/llm-registry.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/audit.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/scheduler.sh"
#
#   scheduler_init
#   scheduler_run    # Runs main loop (foreground, call with & for background)
#
# Event Processing:
#   file_ready   -- Check lock, acquire, invoke LLM invoker in background
#   stop_signal  -- Send SIGTERM (wait 5s) then SIGKILL to running task
#                  Saves partial output to STATE_DIR/partial/
#                  Invalidates session file for this task
#                  Writes audit record with interrupted: true
#                  Sends ntfy notification about the interrupt
#
# Environment Variables for Invokers:
#   STDERR_LOG   -- Path to stderr log file
#   MAX_TURNS    -- Maximum turns per invocation
#   TASK_NAME    -- Task name
#
# Lock Management:
#   Uses lib/locking.sh to coordinate concurrent executions
#   Lock file contains PID of background invoker process
#
# Retry Queue:
#   In-memory queue for events that couldn't be processed (no slots)
#   Re-checked on each cycle
#
# Dry Run Mode:
#   DRY_RUN=1 logs actions without invoking LLMs
#
# Dependencies:
#   - config.sh (SCHEDULER_CYCLE, STATE_DIR, DEFAULT_MAX_TURNS, DRY_RUN, LLM_CLAUDE_MAX_PARALLEL)
#   - lib/logging.sh
#   - lib/locking.sh
#   - lib/event-queue.sh
#   - lib/notifications.sh
#   - lib/llm-registry.sh
#   - lib/audit.sh
#   - lib/continuation.sh
#   - lib/turn-detection.sh
# ============================================================================

set -euo pipefail

# --- Private State ---

# In-memory retry queue: array of event lines
declare -a _SCHEDULER_RETRY_QUEUE=()

# Track active background jobs
declare -A _SCHEDULER_ACTIVE_PIDS=()

# --- Private Helpers ---

# Get task complexity from file metadata, cache, or default
# Args: $1 = task_dir, $2 = filename
# Returns: complexity value (1, 2, or 3)
get_task_complexity() {
    local task_dir="$1"
    local filename="$2"

    if [[ -z "$task_dir" ]] || [[ -z "$filename" ]]; then
        echo 3
        return 0
    fi

    local task_name
    task_name="$(basename "$task_dir")"

    local input_file="$task_dir/$filename"
    local cache_dir="$STATE_DIR/complexity"
    local cache_file="$cache_dir/$task_name"

    # 1. Check input file for <!-- complexity: N --> metadata
    if [[ -f "$input_file" ]]; then
        local file_complexity
        file_complexity=$(grep -oP '<!-- complexity: \K[0-9]+' "$input_file" 2>/dev/null | head -1)

        if [[ -n "$file_complexity" ]] && [[ "$file_complexity" =~ ^[123]$ ]]; then
            # Cache the complexity
            mkdir -p "$cache_dir" 2>/dev/null || true
            echo "$file_complexity" > "$cache_file" 2>/dev/null || true
            echo "$file_complexity"
            return 0
        fi
    fi

    # 2. Check cached complexity from STATE_DIR/complexity/<task-name>
    if [[ -f "$cache_file" ]]; then
        local cached_complexity
        cached_complexity=$(cat "$cache_file" 2>/dev/null | head -1)

        if [[ -n "$cached_complexity" ]] && [[ "$cached_complexity" =~ ^[123]$ ]]; then
            echo "$cached_complexity"
            return 0
        fi
    fi

    # 3. Default to complexity 3
    local default_complexity=3

    # Cache the default
    mkdir -p "$cache_dir" 2>/dev/null || true
    echo "$default_complexity" > "$cache_file" 2>/dev/null || true

    echo "$default_complexity"
    return 0
}

# Parse an event line into components
# Args: $1 = event line (TIMESTAMP|EVENT_TYPE|TASK_NAME|FILE|METADATA)
# Outputs: EVENT_TYPE, TASK_NAME, EVENT_FILE, EVENT_METADATA
_scheduler_parse_event() {
    local line="$1"
    IFS='|' read -r _ EVENT_TYPE TASK_NAME EVENT_FILE EVENT_METADATA <<< "$line"
}

# Check if a task has a failed attempt record
_scheduler_has_failed_attempt() {
    local task_name="$1"
    local file="$2"
    local failure_file="$STATE_DIR/failures/${task_name}/${file}.failed"

    [[ -f "$failure_file" ]]
}

# Record a failed attempt
_scheduler_record_failure() {
    local task_name="$1"
    local file="$2"

    mkdir -p "$STATE_DIR/failures/${task_name}"
    touch "$STATE_DIR/failures/${task_name}/${file}.failed"
}

# Clear a failed attempt record
_scheduler_clear_failure() {
    local task_name="$1"
    local file="$2"

    rm -f "$STATE_DIR/failures/${task_name}/${file}.failed" 2>/dev/null || true
}

# Process a file_ready event
_scheduler_process_file_ready() {
    local task_name="$1"
    local file="$2"

    # Check if this is a continuation event (from metadata)
    local is_continuation=false
    local continuation_session_id=""

    # Parse EVENT_METADATA for "continuation:session-id"
    if [[ "${EVENT_METADATA:-}" == continuation:* ]]; then
        is_continuation=true
        continuation_session_id="${EVENT_METADATA#continuation:}"
        log DEBUG "[$task_name] Processing continuation with session: $continuation_session_id"
    fi

    # Determine task complexity and route to appropriate LLM
    local task_dir="$VAULT_TASKS_DIR/$task_name"
    local complexity
    complexity="$(get_task_complexity "$task_dir" "$file")"

    # Route task to LLM based on complexity
    local llm_name
    llm_name="$(llm_route_task "$complexity")"

    # Check if task was queued (no LLM available)
    if [[ "$llm_name" == "QUEUED" ]]; then
        log DEBUG "[$task_name] All LLMs busy or exhausted for complexity $complexity, will retry"

        # Check if queued due to token exhaustion (complexity 3 only routes to claude)
        if [[ "$complexity" -eq 3 ]]; then
            # Source token-tracking.sh for exhaustion checks
            if declare -f token_is_exhausted >/dev/null 2>&1; then
                if token_is_exhausted "claude"; then
                    local reset_time=""
                    if declare -f token_get_reset_time >/dev/null 2>&1; then
                        reset_time=$(token_get_reset_time "claude" 2>/dev/null || echo "")
                    fi

                    if [[ -n "$reset_time" ]]; then
                        notify_priority "Token Exhausted" "Claude tokens exhausted. Reset at: $reset_time. Task $task_name queued."
                        log WARN "[$task_name] Claude tokens exhausted, reset at $reset_time"
                    else
                        notify_priority "Token Exhausted" "Claude tokens exhausted. Task $task_name queued."
                        log WARN "[$task_name] Claude tokens exhausted"
                    fi
                fi
            fi
        fi

        return 2  # Return code 2 means "retry later"
    fi

    # Check if already locked
    if lock_check "$llm_name" "$task_name"; then
        log DEBUG "[$task_name] Already locked, skipping"
        return 1
    fi

    # Check if previously failed
    if _scheduler_has_failed_attempt "$task_name" "$file"; then
        log DEBUG "[$task_name] Previous failure recorded for $file, skipping"
        return 1
    fi

    # Acquire lock
    if ! lock_acquire "$llm_name" "$task_name"; then
        log WARN "[$task_name] Failed to acquire lock"
        return 1
    fi

    log INFO "[$task_name] Acquired lock, invoking LLM for $file"

    # Set up environment variables for invoker
    local task_dir="$VAULT_TASKS_DIR/$task_name"
    local stderr_log="$STATE_DIR/logs/${task_name}_${file%.md}.log"
    mkdir -p "$(dirname "$stderr_log")"

    # In dry run mode, just log what we would do
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: Would invoke invoker for $task_name/$file (LLM: $llm_name, Complexity: $complexity)"
        log INFO "DRY_RUN:   TASK_DIR=$task_dir"
        log INFO "DRY_RUN:   INPUT=$file OUTPUT=${file%.md}_response.md"
        log INFO "DRY_RUN:   STDERR_LOG=$stderr_log"
        lock_release "$llm_name" "$task_name"
        return 0
    fi

    # Invoke LLM invoker in background
    local invoker_script
    invoker_script="$(llm_get_invoker "$llm_name")"

    if [[ -z "$invoker_script" ]]; then
        log ERROR "[$task_name] No invoker found for LLM: $llm_name"
        lock_release "$llm_name" "$task_name"
        return 1
    fi

    # Create stdout log path for capturing invoker output
    local stdout_log="$STATE_DIR/logs/${task_name}_${file%.md}_stdout.log"

    # Write audit journal START record before invocation
    if declare -f audit_journal_start >/dev/null 2>&1; then
        audit_journal_start "$task_name" "$file" "$llm_name" $$ "" 2>/dev/null || true
    fi

    (
        # Set environment variables for invoker
        export STDERR_LOG="$stderr_log"
        export MAX_TURNS="${DEFAULT_MAX_TURNS:-10}"
        export TASK_NAME="$task_name"

        # Invoke the script with --resume if continuation
        if [[ "$is_continuation" == "true" ]] && [[ -n "$continuation_session_id" ]]; then
            "$invoker_script" "$task_dir" "$file" "${file%.md}_response.md" --resume "$continuation_session_id"
        else
            "$invoker_script" "$task_dir" "$file" "${file%.md}_response.md"
        fi
    ) > "$stdout_log" 2>&1 &

    local invoker_pid=$!

    # Store PID in lock file (overwrite with invoker PID)
    local lock_path
    lock_path="$(_lock_get_path "$llm_name" "$task_name")" 2>/dev/null || true
    if [[ -n "$lock_path" ]]; then
        echo "$invoker_pid" > "$lock_path"
    fi

    # Track active PID
    _SCHEDULER_ACTIVE_PIDS[$invoker_pid]="${llm_name}:${task_name}:${file}"

    log INFO "[$task_name] Invoker started in background (PID: $invoker_pid)"

    # Monitor the background process
    _scheduler_monitor_invoker "$invoker_pid" "$llm_name" "$task_name" "$file" "$stdout_log" &

    return 0
}

# Monitor a background invoker process
_scheduler_monitor_invoker() {
    local pid="$1"
    local llm_name="$2"
    local task_name="$3"
    local file="$4"
    local stdout_log="${5:-}"
    local stderr_log="$STATE_DIR/logs/${task_name}_${file%.md}.log"

    # Wait for process to complete
    wait "$pid" 2>/dev/null || true
    local exit_code=$?

    # Extract session_id and turns_used from stdout if available
    local session_id=""
    local turns_used=""
    local max_turns="${DEFAULT_MAX_TURNS:-10}"
    local response_file="${file%.md}_response.md"

    if [[ -f "$stdout_log" ]]; then
        session_id=$(grep -oP 'SESSION_ID:\K.*' "$stdout_log" 2>/dev/null | tail -1 || echo "")
        turns_used=$(grep -oP 'TURNS_USED:\K[0-9]+' "$stdout_log" 2>/dev/null | tail -1 || echo "")
    fi

    # Write audit journal END record after completion
    if declare -f audit_journal_end >/dev/null 2>&1; then
        audit_journal_end "$task_name" "$file" "$llm_name" "$pid" "$exit_code" "${turns_used:-0}" 2>/dev/null || true
    fi

    # Write full audit record
    if declare -f audit_write_record >/dev/null 2>&1; then
        # Read stderr log for audit trail
        local stderr_content=""
        if [[ -f "$stderr_log" ]]; then
            stderr_content=$(cat "$stderr_log" 2>/dev/null || echo "")
        fi
        audit_write_record "$task_name" "$file" "$llm_name" "${session_id:-unknown}" "${turns_used:-0}" "$exit_code" "false" "$stderr_content" 2>/dev/null || true
    fi

    # Update daily usage statistics
    if declare -f audit_update_usage >/dev/null 2>&1; then
        audit_update_usage "$llm_name" "${turns_used:-0}" "$task_name" 2>/dev/null || true
    fi

    # Check for max-turns continuation
    if [[ -n "$turns_used" ]] && [[ -n "$max_turns" ]] && [[ "$turns_used" -eq "$max_turns" ]]; then
        log DEBUG "[$task_name] Hit max turns ($turns_used/$max_turns), checking continuation"

        # Mark continuation state
        if [[ -n "$session_id" ]] && declare -f continuation_mark_continuation >/dev/null 2>&1; then
            continuation_mark_continuation "$task_name" "$session_id" "$turns_used" "$max_turns" "$file" 2>/dev/null || true
        fi

        # Determine response file path
        local response_file="${file%.md}_response.md"
        local response_path="$VAULT_TASKS_DIR/$task_name/$response_file"

        # Check user edit using turn detection
        local turn_type=""
        if declare -f detect_turn >/dev/null 2>&1; then
            turn_type=$(detect_turn "$VAULT_TASKS_DIR/$task_name" "$response_file" 2>/dev/null || echo "")
        fi

        # Check for stop signal using turn detection
        local stop_detected=false
        if declare -f detect_stop >/dev/null 2>&1; then
            if detect_stop "$VAULT_TASKS_DIR/$task_name" "$response_file" 2>/dev/null; then
                stop_detected=true
            fi
        fi

        if [[ "$turn_type" == "edited" ]]; then
            log INFO "[$task_name] User edited response, treating as new input"
            if declare -f continuation_clear >/dev/null 2>&1; then
                continuation_clear "$task_name" 2>/dev/null || true
            fi
            # Re-queue as new file_ready event with edited response file
            if declare -f queue_write >/dev/null 2>&1; then
                queue_write "file_ready" "$task_name" "$response_file" "turn:edited" 2>/dev/null || true
            fi
        elif [[ "$stop_detected" == "true" ]]; then
            log INFO "[$task_name] <Stop> signal detected, halting continuation"
            if declare -f continuation_clear >/dev/null 2>&1; then
                continuation_clear "$task_name" 2>/dev/null || true
            fi
        else
            # Check if we should continue (not at continuation limit)
            local should_continue=true
            if declare -f continuation_should_continue >/dev/null 2>&1; then
                if ! continuation_should_continue "$task_name" 2>/dev/null; then
                    should_continue=false
                    log WARN "[$task_name] Hit continuation limit, not auto-continuing"
                fi
            fi

            if [[ "$should_continue" == "true" ]] && [[ -n "$session_id" ]]; then
                log INFO "[$task_name] No user edit or stop signal, will continue"
                # Re-queue for continuation with --resume
                if declare -f queue_write >/dev/null 2>&1; then
                    queue_write "file_ready" "$task_name" "$response_file" "continuation:$session_id" 2>/dev/null || true
                fi
            fi
        fi
    fi

    # Release the lock
    lock_release "$llm_name" "$task_name"

    # Clear failure record on success
    if [[ $exit_code -eq 0 ]]; then
        _scheduler_clear_failure "$task_name" "$file"
        log INFO "[$task_name] Invoker completed successfully (PID: $pid)"
        notify "Task Complete" "[$task_name] $file completed successfully"
    else
        # Record failure
        _scheduler_record_failure "$task_name" "$file"
        log ERROR "[$task_name] Invoker failed with exit code $exit_code (PID: $pid)"
        notify_priority "Task Failed" "[$task_name] $file failed (exit: $exit_code)"
    fi

    # Remove from active PIDs
    unset "_SCHEDULER_ACTIVE_PIDS[$pid]"
}

# Save partial output from a task's response file
# Args: $1 = task_name, $2 = file (response filename)
_scheduler_save_partial_output() {
    local task_name="$1"
    local file="$2"

    local task_dir="$VAULT_TASKS_DIR/$task_name"
    local response_file="$task_dir/$file"

    # Check if response file exists and has content
    if [[ ! -f "$response_file" ]]; then
        log DEBUG "[$task_name] No response file to save as partial"
        return 0
    fi

    # Create partial output directory
    local partial_dir="$STATE_DIR/partial"
    mkdir -p "$partial_dir" 2>/dev/null || true

    # Sanitize task name for filename (remove special chars)
    local safe_task_name="${task_name//[^a-zA-Z0-9_-]/_}"
    local safe_file_name="${file//[^a-zA-Z0-9_.-]/_}"

    # Generate partial output filename with timestamp
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local partial_file="$partial_dir/${safe_task_name}_${safe_file_name}_${timestamp}.md"

    # Copy response file to partial directory
    cp "$response_file" "$partial_file" 2>/dev/null || {
        log WARN "[$task_name] Failed to copy partial output to $partial_file"
        return 1
    }

    log INFO "[$task_name] Partial output saved to $partial_file"
    return 0
}

# Invalidate session file for a task
# Args: $1 = task_name
_scheduler_invalidate_session() {
    local task_name="$1"

    # Session files are stored in STATE_DIR/sessions/
    local session_file="$STATE_DIR/sessions/${task_name}.json"

    if [[ -f "$session_file" ]]; then
        # Add "invalidated": true flag to session file
        if command -v jq >/dev/null 2>&1; then
            local temp_file="${session_file}.tmp.$$"
            jq '.invalidated = true' "$session_file" > "$temp_file" 2>/dev/null && mv "$temp_file" "$session_file"
            log INFO "[$task_name] Session file invalidated"
        else
            # Fallback: append invalidation marker
            echo '{"invalidated": true}' >> "$session_file"
            log INFO "[$task_name] Session file marked as invalidated (jq not available)"
        fi
    else
        log DEBUG "[$task_name] No session file to invalidate"
    fi

    return 0
}

# Write audit record for interrupted task
# Args: $1 = task_name, $2 = file, $3 = llm_name, $4 = pid
_scheduler_write_interrupt_audit() {
    local task_name="$1"
    local file="$2"
    local llm_name="$3"
    local pid="$4"

    # Check if audit library is available
    if declare -f audit_write_record >/dev/null 2>&1; then
        # Write audit record with interrupted: true
        # Format: audit_write_record task_name file llm_name session_id turns exit_code interrupted stderr_log
        audit_write_record "$task_name" "$file" "$llm_name" "interrupted" "0" "130" "true" "" 2>/dev/null || true
        log INFO "[$task_name] Audit record written for interrupted task"
    else
        log DEBUG "[$task_name] Audit library not available, skipping audit record"
    fi

    return 0
}

# Process a stop_signal event
_scheduler_process_stop_signal() {
    local task_name="$1"
    local file="$2"

    # Find which LLM has the lock for this task
    local llm_name=""
    local pid=""

    for llm in $(llm_list); do
        if lock_check "$llm" "$task_name"; then
            llm_name="$llm"
            pid="$(lock_get_pid "$llm" "$task_name")" || continue
            break
        fi
    done

    if [[ -z "$llm_name" ]] || [[ -z "$pid" ]]; then
        log WARN "[$task_name] No active lock found for stop_signal"
        return 1
    fi

    log INFO "[$task_name] Processing stop signal for PID $pid (LLM: $llm_name)"

    # Send SIGTERM
    kill -TERM "$pid" 2>/dev/null || {
        log WARN "[$task_name] Failed to send SIGTERM to $pid"
        return 1
    }

    log INFO "[$task_name] SIGTERM sent to PID $pid, waiting up to 5 seconds"

    # Wait up to 5 seconds for graceful termination
    local waited=0
    local terminated=false
    while [[ $waited -lt 5 ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log INFO "[$task_name] Process $pid terminated gracefully after ${waited}s"
            terminated=true
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Force kill if still running
    if [[ "$terminated" == "false" ]]; then
        log WARN "[$task_name] Process $pid did not terminate gracefully, sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1

        # Verify it's dead now
        if kill -0 "$pid" 2>/dev/null; then
            log ERROR "[$task_name] Process $pid survived SIGKILL, giving up"
        else
            log INFO "[$task_name] Process $pid terminated via SIGKILL"
        fi
    fi

    # Save partial output if response file exists
    # Determine response filename (input file with _response suffix)
    local response_file="${file%.md}_response.md"
    _scheduler_save_partial_output "$task_name" "$response_file"

    # Invalidate session file
    _scheduler_invalidate_session "$task_name"

    # Write audit record
    _scheduler_write_interrupt_audit "$task_name" "$file" "$llm_name" "$pid"

    # Release lock
    lock_release "$llm_name" "$task_name"

    # Send ntfy notification about the interrupt
    notify_priority "Task Interrupted" "[$task_name] Task was interrupted via stop signal"

    log INFO "[$task_name] Stop signal processed and cleanup complete"
    return 0
}

# Process a single event line
_scheduler_process_event() {
    local line="$1"

    _scheduler_parse_event "$line"

    case "$EVENT_TYPE" in
        file_ready)
            _scheduler_process_file_ready "$TASK_NAME" "$EVENT_FILE"
            ;;
        stop_signal)
            _scheduler_process_stop_signal "$TASK_NAME" "$EVENT_FILE"
            ;;
        *)
            log DEBUG "Unknown event type: $EVENT_TYPE"
            ;;
    esac
}

# Main scheduler loop
_scheduler_main_loop() {
    log INFO "Scheduler started (cycle: ${SCHEDULER_CYCLE:-2}s)"

    while true; do
        # Read all events from queue
        local events
        events="$(queue_read_all)" || {
            log WARN "Failed to read from queue"
            sleep "${SCHEDULER_CYCLE:-2}"
            continue
        }

        # Process each event
        if [[ -n "$events" ]]; then
            log DEBUG "Processing $(echo "$events" | wc -l) events"

            while IFS= read -r line; do
                [[ -z "$line" ]] && continue

                _scheduler_process_event "$line"
                local result=$?

                # If result is 2 (retry later), add to retry queue
                if [[ $result -eq 2 ]]; then
                    _SCHEDULER_RETRY_QUEUE+=("$line")
                fi
            done <<< "$events"
        fi

        # Process retry queue
        if [[ ${#_SCHEDULER_RETRY_QUEUE[@]} -gt 0 ]]; then
            log DEBUG "Retrying ${#_SCHEDULER_RETRY_QUEUE[@]} queued events"

            local -a new_retry_queue=()
            for retry_line in "${_SCHEDULER_RETRY_QUEUE[@]}"; do
                _scheduler_parse_event "$retry_line"

                if [[ "$EVENT_TYPE" == "file_ready" ]]; then
                    _scheduler_process_file_ready "$TASK_NAME" "$EVENT_FILE"
                    local result=$?

                    # Still no slots? Keep in retry queue
                    if [[ $result -eq 2 ]]; then
                        new_retry_queue+=("$retry_line")
                    fi
                else
                    # Non-file_ready events are not retried
                    :
                fi
            done

            _SCHEDULER_RETRY_QUEUE=("${new_retry_queue[@]}")
        fi

        # Clean up stale locks periodically
        lock_cleanup_stale >/dev/null || true

        # Sleep until next cycle
        sleep "${SCHEDULER_CYCLE:-2}"
    done
}

# --- Public API ---

# Initialize the scheduler subsystem
scheduler_init() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        log ERROR "STATE_DIR not set"
        return 1
    fi

    if [[ -z "${VAULT_TASKS_DIR:-}" ]]; then
        log ERROR "VAULT_TASKS_DIR not set"
        return 1
    fi

    # Initialize queue
    queue_init

    # Initialize continuation tracking
    if declare -f continuation_init >/dev/null 2>&1; then
        continuation_init 2>/dev/null || true
    fi

    # Create necessary directories
    mkdir -p "$STATE_DIR/failures"
    mkdir -p "$STATE_DIR/logs"
    mkdir -p "$STATE_DIR/complexity"
    mkdir -p "$STATE_DIR/partial"
    mkdir -p "$STATE_DIR/sessions"

    # Check for incomplete audit entries from previous runs
    if declare -f audit_check_incomplete >/dev/null 2>&1; then
        local incomplete_tasks
        incomplete_tasks=$(audit_check_incomplete 2>/dev/null || echo "")
        if [[ -n "$incomplete_tasks" ]]; then
            log WARN "Found incomplete tasks from previous run:"
            while IFS= read -r task; do
                [[ -n "$task" ]] && log WARN "  - $task"
            done <<< "$incomplete_tasks"
        fi
    fi

    log INFO "Scheduler initialized"
}

# Run the scheduler main loop (runs in foreground)
scheduler_run() {
    _scheduler_main_loop
}

# --- Standalone Entry Point ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/config.sh"
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/locking.sh"
    source "${SCRIPT_DIR}/lib/event-queue.sh"
    source "${SCRIPT_DIR}/lib/notifications.sh"
    source "${SCRIPT_DIR}/lib/llm-registry.sh"
    source "${SCRIPT_DIR}/lib/token-tracking.sh"
    source "${SCRIPT_DIR}/lib/turn-detection.sh"
    source "${SCRIPT_DIR}/lib/continuation.sh"
    # Audit is optional — source if available
    if [[ -f "${SCRIPT_DIR}/lib/audit.sh" ]]; then
        source "${SCRIPT_DIR}/lib/audit.sh"
    fi

    scheduler_init || exit 1
    scheduler_run
fi
