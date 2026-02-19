#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Audit Trail Library
# ============================================================================
# Provides audit trail functions for tracking LLM invocations, recording
# results, updating daily usage statistics, and detecting incomplete tasks.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/audit.sh"
#
#   audit_journal_start "my-task" "001.md" "claude" $$ "session-123"
#   audit_journal_end "my-task" "001.md" "claude" $$ 0 5
#   audit_write_record "my-task" "001.md" "claude" "session-123" 5 0
#   audit_update_usage "claude" 5
#   audit_check_incomplete
#
# State Directory Structure:
#   STATE_DIR/
#     journal.log                     -- Append-only START/END log
#     audit/<task-name>/<timestamp>.json -- Per-invocation JSON records
#     usage/YYYY-MM-DD.json           -- Daily usage counters
#
# Dependencies:
#   - config.sh must be sourced first (provides STATE_DIR)
#   - jq must be available for JSON manipulation
# ============================================================================

# --- Private Helpers ---

# Get the journal log file path
_audit_get_journal_path() {
    echo "$STATE_DIR/journal.log"
}

# Get the audit directory for a task
_audit_get_audit_dir() {
    local task_name="$1"
    echo "$STATE_DIR/audit/${task_name}"
}

# Get the usage file path for today
_audit_get_usage_path() {
    local date_str
    date_str="$(date '+%Y-%m-%d')"
    echo "$STATE_DIR/usage/${date_str}.json"
}

# Ensure a directory exists (race-condition safe)
_audit_ensure_dir() {
    local dir="$1"
    mkdir -p "$dir" 2>/dev/null || true
}

# Validate a task name (path traversal protection)
_audit_validate_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        return 1
    fi
    if [[ "$name" == *"/"* ]] || [[ "$name" == *".."* ]]; then
        return 1
    fi
    return 0
}

# Generate an ISO 8601 timestamp
_audit_timestamp() {
    date -Iseconds
}

# Generate a filename-safe timestamp
_audit_timestamp_filename() {
    date '+%Y%m%d_%H%M%S'
}

# Check if jq is available
_audit_check_jq() {
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required for audit functions" >&2
        return 1
    fi
    return 0
}

# --- Public API ---

# audit_journal_start <task_name> <filename> <llm> <pid> [session_id]
# Appends a START line to the journal log.
# Format: TIMESTAMP START task_name filename llm pid=N session=X
audit_journal_start() {
    local task_name="$1"
    local filename="$2"
    local llm="$3"
    local pid="$4"
    local session_id="${5:-unknown}"

    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    _audit_validate_name "$task_name" || {
        echo "ERROR: Invalid task name: $task_name" >&2
        return 1
    }

    _audit_validate_name "$llm" || {
        echo "ERROR: Invalid LLM name: $llm" >&2
        return 1
    }

    _audit_ensure_dir "$STATE_DIR"

    local journal
    journal="$(_audit_get_journal_path)"
    local timestamp
    timestamp="$(_audit_timestamp)"

    echo "${timestamp} START ${task_name} ${filename} ${llm} pid=${pid} session=${session_id}" >> "$journal"
}

# audit_journal_end <task_name> <filename> <llm> <pid> <exit_code> <turns>
# Appends an END line to the journal log.
# Format: TIMESTAMP END task_name filename llm pid=N exit=N turns=N
audit_journal_end() {
    local task_name="$1"
    local filename="$2"
    local llm="$3"
    local pid="$4"
    local exit_code="$5"
    local turns="$6"

    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    _audit_validate_name "$task_name" || {
        echo "ERROR: Invalid task name: $task_name" >&2
        return 1
    }

    _audit_validate_name "$llm" || {
        echo "ERROR: Invalid LLM name: $llm" >&2
        return 1
    }

    _audit_ensure_dir "$STATE_DIR"

    local journal
    journal="$(_audit_get_journal_path)"
    local timestamp
    timestamp="$(_audit_timestamp)"

    echo "${timestamp} END ${task_name} ${filename} ${llm} pid=${pid} exit=${exit_code} turns=${turns}" >> "$journal"
}

# audit_write_record <task_name> <filename> <llm> <session_id> <turns> <exit_code> [interrupted] [stderr_log]
# Creates a JSON audit record for a specific invocation.
# File: STATE_DIR/audit/<task-name>/<timestamp>.json
audit_write_record() {
    local task_name="$1"
    local filename="$2"
    local llm="$3"
    local session_id="${4:-unknown}"
    local turns="${5:-0}"
    local exit_code="${6:-0}"
    local interrupted="${7:-false}"
    local stderr_log="${8:-}"

    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    _audit_validate_name "$task_name" || {
        echo "ERROR: Invalid task name: $task_name" >&2
        return 1
    }

    _audit_check_jq || return 1

    local audit_dir
    audit_dir="$(_audit_get_audit_dir "$task_name")"
    _audit_ensure_dir "$audit_dir"

    local timestamp
    timestamp="$(_audit_timestamp)"
    local filename_ts
    filename_ts="$(_audit_timestamp_filename)"

    local record_file="${audit_dir}/${filename_ts}.json"

    # Build JSON with jq to prevent injection
    jq -n \
        --arg task "$task_name" \
        --arg file "$filename" \
        --arg llm "$llm" \
        --arg ts "$timestamp" \
        --arg session "$session_id" \
        --argjson turns "$turns" \
        --argjson exit_code "$exit_code" \
        --argjson interrupted "$interrupted" \
        --arg stderr_log "$stderr_log" \
        '{
            task: $task,
            file: $file,
            llm: $llm,
            timestamp: $ts,
            session_id: $session,
            turns: $turns,
            exit_code: $exit_code,
            interrupted: $interrupted,
            stderr_log: $stderr_log,
            tool_calls: [],
            files_modified: []
        }' > "$record_file"
}

# audit_update_usage <llm> <turns> [task_name]
# Increments daily usage counters in the usage JSON file.
# Uses atomic temp file + mv pattern for safety.
audit_update_usage() {
    local llm="$1"
    local turns="${2:-0}"
    local task_name="${3:-}"

    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    _audit_validate_name "$llm" || {
        echo "ERROR: Invalid LLM name: $llm" >&2
        return 1
    }

    _audit_check_jq || return 1

    _audit_ensure_dir "$STATE_DIR/usage"

    local usage_file
    usage_file="$(_audit_get_usage_path)"

    # Create initial file if it doesn't exist
    if [[ ! -f "$usage_file" ]]; then
        echo '{}' > "$usage_file"
    fi

    local tmp_file="${usage_file}.tmp.$$"

    # Update usage with jq
    if [[ -n "$task_name" ]]; then
        jq \
            --arg llm "$llm" \
            --argjson turns "$turns" \
            --arg task "$task_name" \
            '
            .[$llm] //= {"total_turns": 0, "task_count": 0, "tasks": []} |
            .[$llm].total_turns += $turns |
            .[$llm].task_count += 1 |
            .[$llm].tasks += [$task]
            ' "$usage_file" > "$tmp_file" && mv "$tmp_file" "$usage_file"
    else
        jq \
            --arg llm "$llm" \
            --argjson turns "$turns" \
            '
            .[$llm] //= {"total_turns": 0, "task_count": 0, "tasks": []} |
            .[$llm].total_turns += $turns |
            .[$llm].task_count += 1
            ' "$usage_file" > "$tmp_file" && mv "$tmp_file" "$usage_file"
    fi
}

# audit_check_incomplete
# Parses journal.log for unmatched START entries (no corresponding END).
# Outputs task names with incomplete invocations (one per line).
audit_check_incomplete() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "ERROR: STATE_DIR not set" >&2
        return 1
    fi

    local journal
    journal="$(_audit_get_journal_path)"

    if [[ ! -f "$journal" ]]; then
        return 0
    fi

    # Parse journal for START/END pairs
    # Use associative array to track active starts
    local -A active_starts

    while IFS= read -r line; do
        if [[ "$line" == *" START "* ]]; then
            # Extract task name (3rd field after timestamp and START)
            local task_name
            task_name="$(echo "$line" | awk '{print $3}')"
            local pid_field
            pid_field="$(echo "$line" | grep -oP 'pid=\K\d+')"
            local key="${task_name}:${pid_field}"
            active_starts["$key"]=1
        elif [[ "$line" == *" END "* ]]; then
            local task_name
            task_name="$(echo "$line" | awk '{print $3}')"
            local pid_field
            pid_field="$(echo "$line" | grep -oP 'pid=\K\d+')"
            local key="${task_name}:${pid_field}"
            unset "active_starts[$key]" 2>/dev/null || true
        fi
    done < "$journal"

    # Output incomplete task names
    for key in "${!active_starts[@]}"; do
        local task_name="${key%%:*}"
        echo "$task_name"
    done
}
