#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Progress Writer
# ============================================================================
# Background daemon that monitors task-specific log files and provides live
# progress visibility in Obsidian by creating/updating working preview files
# and _status.md files.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/locking.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/progress-writer.sh"
#
#   progress_writer_init
#   progress_writer_run    # Runs in foreground (main loop)
#
# Monitors:
#   - STATE_DIR/logs/*.log for new log files
#   - STATE_DIR/locks/<llm>/<task>.lock for task completion
#
# Creates:
#   - _working.md preview files with <!-- CLAUDE-WORKING --> header
#   - _status.md files with task status (LLM, PID, turns, etc.)
#
# Dependencies:
#   - config.sh (STATE_DIR, VAULT_TASKS_DIR, PROGRESS_UPDATE_INTERVAL,
#                STATUS_UPDATE_INTERVAL, LLM_NAMES, DEFAULT_MAX_TURNS)
#   - lib/logging.sh
#   - lib/locking.sh (lock_get_pid)
# ============================================================================

set -euo pipefail

# Associative array tracking active log files
# Format: "task_dir|output_file|preview_file|last_offset|llm_name|start_time|last_status_update"
declare -A ACTIVE_TAILS

# --- Private Helpers ---

# Extract task name and output filename from log file path
# Log filename format: <task-name>_<output-filename>.log
# Args: $1 = log file path
# Output: "task_dir|output_file|preview_file" or empty on error
_progress_get_task_info() {
    local log_file="$1"
    local log_basename
    log_basename="$(basename "$log_file" .log)"

    # Extract task name (everything before the last underscore group)
    local task_name="${log_basename%%_*}"
    if [[ -z "$task_name" ]]; then
        return 1
    fi

    # Validate task name
    if [[ "$task_name" == *"/"* ]] || [[ "$task_name" == *".."* ]]; then
        return 1
    fi

    local task_dir="${VAULT_TASKS_DIR}/${task_name}"
    if [[ ! -d "$task_dir" ]]; then
        log DEBUG "Task directory does not exist: $task_dir"
        return 1
    fi

    # Find output file (first .md that's not _status.md or _working.md)
    local output_file=""
    for f in "$task_dir"/*.md; do
        [[ -f "$f" ]] || continue
        local fname
        fname="$(basename "$f")"
        [[ "$fname" == "_status.md" ]] && continue
        [[ "$fname" == "_working.md" ]] && continue
        output_file="$fname"
    done

    if [[ -z "$output_file" ]]; then
        # Use the log basename to derive output name
        local output_name="${log_basename#${task_name}_}"
        output_file="${output_name}.md"
    fi

    local preview_file="_working.md"

    echo "${task_dir}|${output_file}|${preview_file}"
}

# Check if any LLM has an active lock for a task
# Args: $1 = task name
# Returns: 0 if locked, 1 if not
_progress_is_lock_present() {
    local task_name="$1"

    for llm in "${LLM_NAMES[@]}"; do
        local lock_path="${STATE_DIR}/locks/${llm}/${task_name}.lock"
        if [[ -f "$lock_path" ]]; then
            local pid
            pid="$(cat "$lock_path" 2>/dev/null)"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                return 0
            fi
        fi
    done

    return 1
}

# Create the initial working preview file
# Args: $1 = preview file full path
_progress_create_preview() {
    local preview_path="$1"

    {
        echo "<!-- CLAUDE-WORKING -->"
        echo "# Started: $(date '+%Y-%m-%d %I:%M %p')"
        echo ""
    } > "$preview_path"
}

# Append new stderr content to preview file
# Args: $1 = log file path, $2 = preview file path, $3 = last byte offset
# Output: new byte offset
_progress_append_to_preview() {
    local log_file="$1"
    local preview_path="$2"
    local last_offset="$3"

    if [[ ! -f "$log_file" ]]; then
        echo "$last_offset"
        return
    fi

    local file_size
    file_size="$(stat -c %s "$log_file" 2>/dev/null || echo "0")"

    if [[ "$file_size" -gt "$last_offset" ]]; then
        # Read only new content
        tail -c "+$((last_offset + 1))" "$log_file" 2>/dev/null >> "$preview_path" || true
        echo "$file_size"
    else
        echo "$last_offset"
    fi
}

# Scan for log files and process them
_progress_scan_logs() {
    local logs_dir="${STATE_DIR}/logs"
    if [[ ! -d "$logs_dir" ]]; then
        return
    fi

    # Find all log files
    for log_file in "$logs_dir"/*.log; do
        [[ -f "$log_file" ]] || continue
        _progress_process_log "$log_file"
    done

    # Clean up finished tasks
    for log_file in "${!ACTIVE_TAILS[@]}"; do
        if [[ ! -f "$log_file" ]]; then
            _progress_cleanup_task "$log_file"
            continue
        fi

        local info="${ACTIVE_TAILS[$log_file]}"
        local task_dir
        task_dir="$(echo "$info" | cut -d'|' -f1)"
        local task_name
        task_name="$(basename "$task_dir")"

        if ! _progress_is_lock_present "$task_name"; then
            _progress_cleanup_task "$log_file"
        fi
    done
}

# Process a single log file
_progress_process_log() {
    local log_file="$1"

    if [[ -n "${ACTIVE_TAILS[$log_file]+x}" ]]; then
        # Already tracking -- update preview and maybe status
        local info="${ACTIVE_TAILS[$log_file]}"
        local task_dir
        task_dir="$(echo "$info" | cut -d'|' -f1)"
        local output_file
        output_file="$(echo "$info" | cut -d'|' -f2)"
        local preview_file
        preview_file="$(echo "$info" | cut -d'|' -f3)"
        local last_offset
        last_offset="$(echo "$info" | cut -d'|' -f4)"
        local llm_name
        llm_name="$(echo "$info" | cut -d'|' -f5)"
        local start_time
        start_time="$(echo "$info" | cut -d'|' -f6)"
        local last_status_update
        last_status_update="$(echo "$info" | cut -d'|' -f7)"

        local preview_path="${task_dir}/${preview_file}"
        local task_name
        task_name="$(basename "$task_dir")"

        # Check if lock still exists
        if ! _progress_is_lock_present "$task_name"; then
            _progress_cleanup_task "$log_file"
            return
        fi

        # Append new content to preview
        local new_offset
        new_offset="$(_progress_append_to_preview "$log_file" "$preview_path" "$last_offset")"

        # Check if status needs updating (every STATUS_UPDATE_INTERVAL seconds)
        local now
        now="$(date +%s)"
        if [[ $(( now - last_status_update )) -ge "${STATUS_UPDATE_INTERVAL:-30}" ]]; then
            _progress_update_status "$task_dir" "$task_name" "$output_file" "$llm_name" "$log_file" "$start_time"
            last_status_update="$now"
        fi

        # Update tracking
        ACTIVE_TAILS[$log_file]="${task_dir}|${output_file}|${preview_file}|${new_offset}|${llm_name}|${start_time}|${last_status_update}"
    else
        # New log file -- start tracking
        local task_info
        task_info="$(_progress_get_task_info "$log_file")" || return

        local task_dir
        task_dir="$(echo "$task_info" | cut -d'|' -f1)"
        local output_file
        output_file="$(echo "$task_info" | cut -d'|' -f2)"
        local preview_file
        preview_file="$(echo "$task_info" | cut -d'|' -f3)"
        local task_name
        task_name="$(basename "$task_dir")"

        # Only track if there's an active lock
        if ! _progress_is_lock_present "$task_name"; then
            return
        fi

        local preview_path="${task_dir}/${preview_file}"

        # Create preview file
        _progress_create_preview "$preview_path"
        log INFO "Created preview file: $preview_path"

        # Determine LLM name
        local llm_name
        llm_name="$(_progress_get_llm_for_task "$task_name")"

        local now
        now="$(date +%s)"

        # Create initial status file
        _progress_update_status "$task_dir" "$task_name" "$output_file" "$llm_name" "$log_file" "$now"

        # Start tracking with initial offset of 0
        ACTIVE_TAILS[$log_file]="${task_dir}|${output_file}|${preview_file}|0|${llm_name}|${now}|${now}"
    fi
}

# Clean up when a task completes
_progress_cleanup_task() {
    local log_file="$1"

    if [[ -n "${ACTIVE_TAILS[$log_file]+x}" ]]; then
        local info="${ACTIVE_TAILS[$log_file]}"
        local task_dir
        task_dir="$(echo "$info" | cut -d'|' -f1)"

        # Delete _status.md
        rm -f "${task_dir}/_status.md" 2>/dev/null || true

        log INFO "Task completed, cleaned up status for: $(basename "$task_dir")"
        unset "ACTIVE_TAILS[$log_file]"
    fi
}

# --- US-021: _status.md Support ---

# Format a timestamp as relative time
# Args: $1 = start timestamp (epoch seconds)
# Output: human-readable relative time string
_progress_format_relative_time() {
    local start_time="$1"
    local now
    now="$(date +%s)"
    local elapsed=$(( now - start_time ))

    if [[ "$elapsed" -lt 60 ]]; then
        echo "${elapsed} sec ago"
    elif [[ "$elapsed" -lt 3600 ]]; then
        local mins=$(( elapsed / 60 ))
        echo "${mins} min ago"
    elif [[ "$elapsed" -lt 86400 ]]; then
        local hours=$(( elapsed / 3600 ))
        echo "${hours} hours ago"
    else
        local days=$(( elapsed / 86400 ))
        echo "${days} days ago"
    fi
}

# Determine which LLM owns a task's lock
# Args: $1 = task name
# Output: LLM name (e.g., "claude") or "unknown"
_progress_get_llm_for_task() {
    local task_name="$1"

    for llm in "${LLM_NAMES[@]}"; do
        local lock_path="${STATE_DIR}/locks/${llm}/${task_name}.lock"
        if [[ -f "$lock_path" ]]; then
            echo "$llm"
            return
        fi
    done

    echo "unknown"
}

# Extract session ID from Claude Code project directory or log
# Args: $1 = log file path
# Output: session ID or "waiting..."
_progress_get_session_id() {
    local log_file="$1"

    if [[ -f "$log_file" ]]; then
        local session_id
        session_id=$(grep -oP 'SESSION_ID:\K[a-f0-9-]+' "$log_file" 2>/dev/null | head -1)
        if [[ -n "$session_id" ]]; then
            echo "$session_id"
            return
        fi

        session_id=$(grep -oP 'Session:\s*\K[a-f0-9-]+' "$log_file" 2>/dev/null | head -1)
        if [[ -n "$session_id" ]]; then
            echo "$session_id"
            return
        fi
    fi

    echo "waiting..."
}

# Create or update the _status.md file
# Args: $1=task_dir, $2=task_name, $3=output_file, $4=llm_name, $5=log_file, $6=start_time
_progress_update_status() {
    local task_dir="$1"
    local task_name="$2"
    local output_file="$3"
    local llm_name="$4"
    local log_file="$5"
    local start_time="$6"

    local status_file="${task_dir}/_status.md"

    # Get PID from lock file
    local pid="unknown"
    for llm in "${LLM_NAMES[@]}"; do
        local lock_path="${STATE_DIR}/locks/${llm}/${task_name}.lock"
        if [[ -f "$lock_path" ]]; then
            pid="$(cat "$lock_path" 2>/dev/null || echo "unknown")"
            break
        fi
    done

    # Get session ID
    local session_id
    session_id="$(_progress_get_session_id "$log_file")"

    # Format times
    local started_time
    started_time="$(date -d "@${start_time}" '+%I:%M %p' 2>/dev/null || date '+%I:%M %p')"
    local relative_time
    relative_time="$(_progress_format_relative_time "$start_time")"

    # Don't write if it's a symlink (security)
    if [[ -L "$status_file" ]]; then
        log WARN "Refusing to write to symlink: $status_file"
        return 1
    fi

    # Write status file
    {
        echo "**Status:** Working on \`${output_file}\`"
        echo ""
        echo "**Started:** ${started_time} (_${relative_time}_)"
        echo ""
        echo "**LLM:** ${llm_name} (session ${session_id})"
        echo ""
        echo "**Turns used:** N/A"
        echo ""
        echo "**PID:** ${pid}"
    } > "$status_file"
}

# --- Public API ---

# Initialize the progress writer
progress_writer_init() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    if [[ -z "${VAULT_TASKS_DIR:-}" ]]; then
        echo "ERROR: VAULT_TASKS_DIR not set" >&2
        return 1
    fi

    mkdir -p "${STATE_DIR}/logs" 2>/dev/null || true

    # Initialize tracking
    ACTIVE_TAILS=()

    log INFO "Progress writer initialized"
    return 0
}

# Main monitoring loop
progress_writer_run() {
    log INFO "Progress writer starting (update interval: ${PROGRESS_UPDATE_INTERVAL:-5}s)"

    while true; do
        _progress_scan_logs
        sleep "${PROGRESS_UPDATE_INTERVAL:-5}"
    done
}
