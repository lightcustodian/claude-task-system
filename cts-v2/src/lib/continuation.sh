#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Continuation State Tracking
# ============================================================================
# Manages continuation state for tasks that hit max-turns limit during LLM
# invocation. Tracks session IDs, turns used, and continuation metadata to
# enable seamless --resume across max-turns boundaries.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/continuation.sh"
#
#   continuation_init
#   continuation_mark_continuation "task-name" "session-123" 10 10 "001_input.md"
#   session_id=$(continuation_get_session_id "task-name")
#   continuation_clear "task-name"
#
# Public Functions:
#   continuation_init()                          - Create STATE_DIR/continuations/
#   continuation_mark_continuation(...)          - Record continuation state
#   continuation_get_session_id(task_name)       - Retrieve session ID for --resume
#   continuation_get_turns_used(task_name)       - Retrieve total turns used
#   continuation_clear(task_name)                - Clear continuation state
#   continuation_should_continue(task_name)      - Check if continuation needed
#
# Config Dependencies:
#   STATE_DIR  - Base directory for state files (from config.sh)
#
# External Dependencies:
#   jq  - JSON processing (for safe JSON construction and querying)
#
# State File Format:
#   STATE_DIR/continuations/<task-name>.json
#   {
#     "task_name": "example-task",
#     "session_id": "abc123-def456",
#     "turns_used": 10,
#     "max_turns": 10,
#     "file": "001_example.md",
#     "timestamp": "2026-02-18T10:30:45+00:00",
#     "continuation_count": 1
#   }
# ============================================================================

set -euo pipefail

# --- Private Helpers ---

# Get path to continuation state file
_continuation_get_state_path() {
    local task_name="$1"
    echo "${STATE_DIR}/continuations/${task_name}.json"
}

# Validate task name for path traversal
_continuation_validate_task_name() {
    local task_name="$1"

    if [[ "$task_name" == *"/"* ]] || [[ "$task_name" == *".."* ]]; then
        echo "Error: Invalid task_name (contains / or ..)" >&2
        return 1
    fi

    return 0
}

# Check if jq is available
_continuation_check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq not installed. Required for continuation tracking." >&2
        return 1
    fi
    return 0
}

# --- Public API ---

# Initialize continuation state directory
continuation_init() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before continuation.sh." >&2
        return 1
    fi

    mkdir -p "${STATE_DIR}/continuations" 2>/dev/null || true
    return 0
}

# Mark a task for continuation
# Args: $1=task_name, $2=session_id, $3=turns_used, $4=max_turns, $5=file
continuation_mark_continuation() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before continuation.sh." >&2
        return 1
    fi

    local task_name="$1"
    local session_id="$2"
    local turns_used="$3"
    local max_turns="$4"
    local file="$5"

    # Validate inputs
    if [[ -z "$task_name" ]]; then
        echo "Error: task_name is required" >&2
        return 1
    fi

    if ! _continuation_validate_task_name "$task_name"; then
        return 1
    fi

    if ! _continuation_check_jq; then
        return 1
    fi

    local state_path
    state_path=$(_continuation_get_state_path "$task_name")

    # Get existing continuation count or default to 0
    local continuation_count=0
    if [[ -f "$state_path" ]]; then
        continuation_count=$(jq -r '.continuation_count // 0' "$state_path" 2>/dev/null || echo 0)
        ((continuation_count++))
    else
        continuation_count=1
    fi

    # Create state file using jq for safe JSON construction
    local temp_file="${state_path}.tmp.$$"
    jq -n \
        --arg task_name "$task_name" \
        --arg session_id "$session_id" \
        --argjson turns_used "$turns_used" \
        --argjson max_turns "$max_turns" \
        --arg file "$file" \
        --arg timestamp "$(date -Iseconds)" \
        --argjson continuation_count "$continuation_count" \
        '{
            task_name: $task_name,
            session_id: $session_id,
            turns_used: $turns_used,
            max_turns: $max_turns,
            file: $file,
            timestamp: $timestamp,
            continuation_count: $continuation_count
        }' > "$temp_file"

    # Atomic move
    mv "$temp_file" "$state_path"

    return 0
}

# Get session ID for continuation
continuation_get_session_id() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before continuation.sh." >&2
        return 1
    fi

    local task_name="$1"

    if [[ -z "$task_name" ]]; then
        echo "Error: task_name is required" >&2
        return 1
    fi

    if ! _continuation_validate_task_name "$task_name"; then
        return 1
    fi

    local state_path
    state_path=$(_continuation_get_state_path "$task_name")

    if [[ ! -f "$state_path" ]]; then
        return 1
    fi

    if ! _continuation_check_jq; then
        return 1
    fi

    jq -r '.session_id // ""' "$state_path" 2>/dev/null || echo ""
}

# Get turns used for continuation
continuation_get_turns_used() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before continuation.sh." >&2
        return 1
    fi

    local task_name="$1"

    if [[ -z "$task_name" ]]; then
        echo "Error: task_name is required" >&2
        return 1
    fi

    if ! _continuation_validate_task_name "$task_name"; then
        return 1
    fi

    local state_path
    state_path=$(_continuation_get_state_path "$task_name")

    if [[ ! -f "$state_path" ]]; then
        return 1
    fi

    if ! _continuation_check_jq; then
        return 1
    fi

    jq -r '.turns_used // ""' "$state_path" 2>/dev/null || echo ""
}

# Clear continuation state
continuation_clear() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before continuation.sh." >&2
        return 1
    fi

    local task_name="$1"

    if [[ -z "$task_name" ]]; then
        echo "Error: task_name is required" >&2
        return 1
    fi

    if ! _continuation_validate_task_name "$task_name"; then
        return 1
    fi

    local state_path
    state_path=$(_continuation_get_state_path "$task_name")

    # Idempotent - no error if file doesn't exist
    rm -f "$state_path" 2>/dev/null || true

    return 0
}

# Check if task should continue (max continuation limit check)
continuation_should_continue() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before continuation.sh." >&2
        return 1
    fi

    local task_name="$1"

    if [[ -z "$task_name" ]]; then
        echo "Error: task_name is required" >&2
        return 1
    fi

    if ! _continuation_validate_task_name "$task_name"; then
        return 1
    fi

    local state_path
    state_path=$(_continuation_get_state_path "$task_name")

    if [[ ! -f "$state_path" ]]; then
        return 1  # No continuation state
    fi

    if ! _continuation_check_jq; then
        return 1
    fi

    # Check continuation count - don't auto-continue after 5 iterations
    local continuation_count
    continuation_count=$(jq -r '.continuation_count // 0' "$state_path" 2>/dev/null || echo 0)

    if [[ "$continuation_count" -ge 5 ]]; then
        log WARN "[$task_name] Hit maximum continuation count (5), halting auto-continuation" 2>/dev/null || true
        return 1
    fi

    return 0
}
