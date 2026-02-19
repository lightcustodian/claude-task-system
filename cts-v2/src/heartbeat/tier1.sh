#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Heartbeat Tier 1 (Bash-Only Quick Check)
# ============================================================================
# Pure bash health monitoring script that runs every 5 minutes via systemd
# timer. Performs quick checks without invoking any LLM.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/token-tracking.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/event-queue.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/tier1.sh"
#
#   tier1_init                    # Initialize state
#   tier1_run_checks              # Run all checks and take actions
#
# Checks Performed:
#   - Stale tasks: No activity >1 hour with pending user turn
#   - Token state: All LLMs checked for exhaustion
#   - Event queue: Backlog size monitored
#
# Actions Taken:
#   - Triggers Tier 2 early (writes heartbeat_trigger event) if issues found
#   - Cleans up stale _status.md files
#   - Logs summary to heartbeat.log
#
# Dependencies:
#   - config.sh (for STATE_DIR, VAULT_TASKS_DIR, LOG_DIR, LLM_NAMES)
#   - lib/logging.sh (for log() function)
#   - lib/token-tracking.sh (for token_is_exhausted())
#   - lib/event-queue.sh (for queue_write())
#
# State Files:
#   - $STATE_DIR/heartbeat/last-run.txt -- Timestamp of last run
#   - $LOG_DIR/heartbeat.log -- Check results log
# ============================================================================

set -euo pipefail

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

# Get heartbeat state directory
_tier1_get_state_dir() {
    echo "${STATE_DIR}/heartbeat"
}

# Initialize heartbeat state directory
_tier1_ensure_dir() {
    local state_dir
    state_dir="$(_tier1_get_state_dir)"
    mkdir -p "$state_dir" 2>/dev/null || true
}

# Check if a task file has been stale (>1 hour no activity)
# Args: $1 = task directory path, $2 = filename
# Returns: 0 if stale, 1 if not stale
_tier1_is_stale_task() {
    local task_dir="$1"
    local filename="$2"
    local filepath="${task_dir}/${filename}"

    if [[ ! -f "$filepath" ]]; then
        return 1
    fi

    # Get file modification time
    local mtime
    mtime="$(stat -c %Y "$filepath" 2>/dev/null || echo 0)"

    # Get current time
    local now
    now="$(date +%s)"

    # Check if file is older than 1 hour (3600 seconds)
    local age=$((now - mtime))
    if [[ "$age" -gt 3600 ]]; then
        return 0
    fi

    return 1
}

# Check if task has pending user turn (not Claude's turn)
# Args: $1 = task directory path, $2 = filename
# Returns: 0 if pending user turn, 1 if Claude turn
_tier1_has_pending_turn() {
    local task_dir="$1"
    local filename="$2"
    local filepath="${task_dir}/${filename}"

    if [[ ! -f "$filepath" ]]; then
        return 1
    fi

    # Check if file starts with Claude response marker (Claude's turn)
    if head -1 "$filepath" 2>/dev/null | grep -q '<!-- CLAUDE-RESPONSE -->'; then
        # Claude's turn - not pending user turn
        return 1
    fi

    # User turn (no Claude marker or has been edited)
    return 0
}

# Get event queue backlog size
# Outputs: number of events in queue
_tier1_get_queue_backlog() {
    local queue_file="${STATE_DIR}/events/queue"

    if [[ ! -f "$queue_file" ]]; then
        echo 0
        return 0
    fi

    # Count non-empty lines
    local count
    count=$(grep -c . "$queue_file" 2>/dev/null || echo 0)
    echo "$count"
}

# Clean up stale _status.md files
_tier1_cleanup_stale_status() {
    local cleaned=0

    # Iterate through task directories
    for task_dir in "${VAULT_TASKS_DIR}"/*/; do
        # Skip if no directories
        [[ -d "$task_dir" ]] || continue

        local status_file="${task_dir}_status.md"

        if [[ -f "$status_file" ]]; then
            # Check if status file is stale (>2 hours old)
            if _tier1_is_stale_task "$task_dir" "_status.md"; then
                # Get age to verify it's very stale (2 hours = 7200 seconds)
                local mtime
                mtime="$(stat -c %Y "$status_file" 2>/dev/null || echo 0)"
                local now
                now="$(date +%s)"
                local age=$((now - mtime))

                if [[ "$age" -gt 7200 ]]; then
                    rm -f "$status_file" 2>/dev/null && ((cleaned++))
                    log DEBUG "Cleaned stale status file: $status_file"
                fi
            fi
        fi
    done

    echo "$cleaned"
}

# ============================================================================
# PUBLIC API
# ============================================================================

# tier1_init
# Initialize heartbeat state directory and log file
tier1_init() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before tier1.sh." >&2
        return 1
    fi

    _tier1_ensure_dir
    log DEBUG "Heartbeat Tier 1 initialized"
    return 0
}

# tier1_run_checks
# Run all health checks and take appropriate actions
# Returns: 0 always (errors are logged, not returned)
tier1_run_checks() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before tier1.sh." >&2
        return 1
    fi

    if [[ -z "${VAULT_TASKS_DIR:-}" ]]; then
        echo "Error: VAULT_TASKS_DIR not set. Source config.sh before tier1.sh." >&2
        return 1
    fi

    log INFO "Starting Tier 1 heartbeat checks"

    local issues_found=0
    local stale_count=0
    local exhausted_llms=()
    local queue_backlog=0

    # Check 1: Stale tasks (>1 hour no activity with pending user turn)
    log DEBUG "Checking for stale tasks..."
    for task_dir in "${VAULT_TASKS_DIR}"/*/; do
        [[ -d "$task_dir" ]] || continue

        local latest
        latest="$(get_latest_md "$task_dir" 2>/dev/null || echo "")"

        if [[ -n "$latest" ]]; then
            if _tier1_has_pending_turn "$task_dir" "$latest"; then
                if _tier1_is_stale_task "$task_dir" "$latest"; then
                    ((stale_count++))
                    log WARN "Stale task detected: $(basename "$task_dir") ($latest)"
                fi
            fi
        fi
    done

    if [[ "$stale_count" -gt 0 ]]; then
        ((issues_found++))
        log WARN "Found $stale_count stale task(s) needing attention"
    fi

    # Check 2: Token state for all LLMs
    log DEBUG "Checking token state for all LLMs..."
    if declare -f token_is_exhausted >/dev/null 2>&1; then
        for llm in "${LLM_NAMES[@]:-}"; do
            if token_is_exhausted "$llm" 2>/dev/null; then
                exhausted_llms+=("$llm")
                log WARN "LLM exhausted: $llm"
            fi
        done

        if [[ "${#exhausted_llms[@]}" -gt 0 ]]; then
            ((issues_found++))
            log WARN "Found ${#exhausted_llms[@]} exhausted LLM(s)"
        fi
    else
        log DEBUG "token_is_exhausted not available, skipping token check"
    fi

    # Check 3: Event queue backlog
    log DEBUG "Checking event queue backlog..."
    queue_backlog="$(_tier1_get_queue_backlog)"
    if [[ "$queue_backlog" -gt 10 ]]; then
        ((issues_found++))
        log WARN "Event queue backlog: $queue_backlog events"
    else
        log DEBUG "Event queue backlog: $queue_backlog events (normal)"
    fi

    # Action 1: Clean up stale _status.md files
    log DEBUG "Cleaning up stale _status.md files..."
    local cleaned
    cleaned="$(_tier1_cleanup_stale_status)"
    if [[ "$cleaned" -gt 0 ]]; then
        log INFO "Cleaned $cleaned stale status file(s)"
    fi

    # Action 2: Trigger Tier 2 early if issues found
    if [[ "$issues_found" -gt 0 ]]; then
        log WARN "Issues detected, triggering Tier 2 early"
        if declare -f queue_write >/dev/null 2>&1; then
            queue_write "heartbeat_trigger" "tier1" "" "issues=$issues_found" 2>/dev/null || true
        else
            log WARN "queue_write not available, cannot trigger Tier 2"
        fi
    else
        log INFO "All checks passed - no issues detected"
    fi

    # Update last run timestamp
    local state_dir
    state_dir="$(_tier1_get_state_dir)"
    local last_run_file="${state_dir}/last-run.txt"
    date -Iseconds > "$last_run_file" 2>/dev/null || true

    log INFO "Tier 1 heartbeat checks completed"
    return 0
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

# If script is executed directly (not sourced), run the checks
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Source dependencies
    # Get to the project root from heartbeat/ subdirectory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    source "${SCRIPT_DIR}/config.sh"
    source "${SCRIPT_DIR}/lib/logging.sh"

    # Optional dependencies - degrade gracefully if missing
    if [[ -f "${SCRIPT_DIR}/lib/token-tracking.sh" ]]; then
        source "${SCRIPT_DIR}/lib/token-tracking.sh"
    fi

    if [[ -f "${SCRIPT_DIR}/lib/event-queue.sh" ]]; then
        source "${SCRIPT_DIR}/lib/event-queue.sh"
    fi

    if [[ -f "${SCRIPT_DIR}/lib/turn-detection.sh" ]]; then
        source "${SCRIPT_DIR}/lib/turn-detection.sh"
    fi

    # Initialize and run
    tier1_init || exit 1
    tier1_run_checks || exit 1

    exit 0
fi
