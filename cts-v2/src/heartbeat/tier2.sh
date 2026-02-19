#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Heartbeat Tier 2 (Local LLM Proactive Work)
# ============================================================================
# Local LLM (Ollama) proactive work script that runs every 30 minutes via
# systemd timer. Uses Ollama to assess tasks and handle low-complexity work.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/locking.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/llm-registry.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/event-queue.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/tier2.sh"
#
#   tier2_init                    # Initialize state
#   tier2_run                     # Run proactive work cycle
#
# Workflow:
#   1. Check ollama slot availability (exit if no slots)
#   2. Build context from project-index.md, task list, token state
#   3. Invoke ollama to identify next task and assess complexity
#   4. For unrated tasks, assess complexity (1-3)
#   5. Handle complexity 1-2 tasks directly via ollama
#   6. Add complexity 3 tasks to Claude queue with summary
#
# Dependencies:
#   - config.sh (for STATE_DIR, VAULT_TASKS_DIR, LOG_DIR, LLM_NAMES)
#   - lib/logging.sh (for log() function)
#   - lib/locking.sh (for lock_count())
#   - lib/llm-registry.sh (for llm_slots_available())
#   - lib/event-queue.sh (for queue_write())
#   - src/invokers/invoke-ollama.sh (for LLM invocation)
#
# State Files:
#   - $STATE_DIR/heartbeat/tier2-last-run.txt -- Timestamp of last run
#   - $STATE_DIR/heartbeat/tier2-work.md -- Input prompt for ollama
#   - $STATE_DIR/heartbeat/tier2-response.md -- Ollama response
#   - $LOG_DIR/heartbeat.log -- Activity log
# ============================================================================

set -euo pipefail

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

# Get heartbeat state directory
_tier2_get_state_dir() {
    echo "${STATE_DIR}/heartbeat"
}

# Initialize heartbeat state directory
_tier2_ensure_dir() {
    local state_dir
    state_dir="$(_tier2_get_state_dir)"
    mkdir -p "$state_dir" 2>/dev/null || true
}

# Build context prompt for Ollama
# Outputs: full prompt text
_tier2_build_context() {
    local project_index="${VAULT_TASKS_DIR}/project-index.md"
    local state_dir
    state_dir="$(_tier2_get_state_dir)"

    cat <<EOF
# Proactive Task Assessment

You are assisting with task management for the Claude Task System v2 project.
Your role is to:
1. Identify the next task that needs attention
2. Assess complexity for unrated tasks (1=simple, 2=moderate, 3=complex)
3. Handle complexity 1-2 tasks directly
4. Create summaries for complexity 3 tasks to queue for Claude

## Project Context

EOF

    # Include project-index.md if available
    if [[ -f "$project_index" ]]; then
        echo "### Project Index"
        echo ""
        cat "$project_index"
        echo ""
    else
        echo "### Project Index"
        echo ""
        echo "*No project-index.md found*"
        echo ""
    fi

    # Include active/pending tasks
    echo "### Active Tasks"
    echo ""
    _tier2_list_tasks
    echo ""

    # Include token state
    echo "### LLM Token State"
    echo ""
    _tier2_show_token_state
    echo ""

    # Instructions
    cat <<EOF
## Instructions

1. Review the active tasks and their last activity timestamps
2. For any unrated tasks, assign a complexity rating (1-3)
3. Identify the highest priority task to work on next
4. If complexity 1-2: Provide direct work/response
5. If complexity 3: Create a brief summary to queue for Claude

Format your response as:

NEXT_TASK: <task-name>
COMPLEXITY: <1-3>
ACTION: <direct_work|queue_for_claude>

[Your work/summary here]
EOF
}

# List active/pending tasks with last activity timestamp
_tier2_list_tasks() {
    if [[ ! -d "$VAULT_TASKS_DIR" ]]; then
        echo "*No tasks directory found*"
        return 0
    fi

    local found_any=0
    for task_dir in "${VAULT_TASKS_DIR}"/*/; do
        [[ -d "$task_dir" ]] || continue

        local task_name
        task_name="$(basename "$task_dir")"

        # Skip project-index and other root files
        if [[ "$task_name" == "project-index.md" ]] || [[ "$task_name" == "CLAUDE.md" ]]; then
            continue
        fi

        # Find latest .md file
        local latest_file=""
        local latest_mtime=0

        for md_file in "$task_dir"/*.md; do
            [[ -f "$md_file" ]] || continue

            # Skip _status.md
            if [[ "$(basename "$md_file")" == "_status.md" ]]; then
                continue
            fi

            local mtime
            mtime="$(stat -c %Y "$md_file" 2>/dev/null || echo 0)"

            if [[ "$mtime" -gt "$latest_mtime" ]]; then
                latest_mtime="$mtime"
                latest_file="$md_file"
            fi
        done

        if [[ -n "$latest_file" ]]; then
            found_any=1
            local last_activity
            last_activity="$(date -d "@$latest_mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')"

            echo "- **$task_name**: Last activity $last_activity"
        fi
    done

    if [[ "$found_any" -eq 0 ]]; then
        echo "*No active tasks found*"
    fi
}

# Show token state for all LLMs
_tier2_show_token_state() {
    local token_state_file="${STATE_DIR}/token-state.json"

    if [[ ! -f "$token_state_file" ]]; then
        echo "*No token state file found*"
        return 0
    fi

    # Simple display of token state
    if command -v jq >/dev/null 2>&1; then
        for llm in "${LLM_NAMES[@]:-}"; do
            local exhausted
            exhausted="$(jq -r ".exhausted.${llm} // \"false\"" "$token_state_file" 2>/dev/null || echo "false")"

            if [[ "$exhausted" == "true" ]]; then
                local reset_time
                reset_time="$(jq -r ".reset_time.${llm} // \"unknown\"" "$token_state_file" 2>/dev/null || echo "unknown")"
                echo "- **$llm**: Exhausted (resets at $reset_time)"
            else
                echo "- **$llm**: Available"
            fi
        done
    else
        echo "*jq not available, cannot parse token state*"
    fi
}

# Check if ollama has available slots
# Returns: 0 if slots available, 1 if no slots
_tier2_check_ollama_slots() {
    if ! declare -f llm_slots_available >/dev/null 2>&1; then
        log WARN "llm_slots_available not available, assuming no slots"
        return 1
    fi

    local slots
    slots="$(llm_slots_available "ollama" 2>/dev/null || echo "0")"

    if [[ "$slots" -le 0 ]]; then
        log INFO "No ollama slots available (slots=$slots), exiting"
        return 1
    fi

    log DEBUG "Ollama has $slots slot(s) available"
    return 0
}

# Invoke ollama with the context prompt
# Returns: 0 on success, non-zero on failure
_tier2_invoke_ollama() {
    local state_dir
    state_dir="$(_tier2_get_state_dir)"

    local input_file="${state_dir}/tier2-work.md"
    local output_file="${state_dir}/tier2-response.md"

    # Build context and write to input file
    _tier2_build_context > "$input_file"

    # Get invoker path
    local invoker
    invoker="$(dirname "${BASH_SOURCE[0]}")/../invokers/invoke-ollama.sh"

    if [[ ! -x "$invoker" ]]; then
        log ERROR "Invoker not found or not executable: $invoker"
        return 1
    fi

    # Invoke ollama with complexity 1 (minimal context for tier2)
    log INFO "Invoking ollama for proactive work assessment"

    export COMPLEXITY=1
    export STDERR_LOG="${LOG_DIR}/tier2-ollama.log"

    if "$invoker" "$state_dir" "$input_file" "$output_file" 2>>"${STDERR_LOG}" ; then
        log INFO "Ollama invocation successful"
        return 0
    else
        local exit_code=$?
        log WARN "Ollama invocation failed with exit code $exit_code"
        return "$exit_code"
    fi
}

# Parse ollama response and take action
# Returns: 0 always (errors logged)
_tier2_process_response() {
    local state_dir
    state_dir="$(_tier2_get_state_dir)"

    local response_file="${state_dir}/tier2-response.md"

    if [[ ! -f "$response_file" ]]; then
        log WARN "No response file found at $response_file"
        return 0
    fi

    # Extract structured fields from response
    local next_task=""
    local complexity=""
    local action=""

    if grep -q "^NEXT_TASK:" "$response_file"; then
        next_task="$(grep "^NEXT_TASK:" "$response_file" | head -1 | sed 's/^NEXT_TASK: *//')"
    fi

    if grep -q "^COMPLEXITY:" "$response_file"; then
        complexity="$(grep "^COMPLEXITY:" "$response_file" | head -1 | sed 's/^COMPLEXITY: *//')"
    fi

    if grep -q "^ACTION:" "$response_file"; then
        action="$(grep "^ACTION:" "$response_file" | head -1 | sed 's/^ACTION: *//')"
    fi

    # Log extracted fields
    log DEBUG "Parsed response: task=$next_task, complexity=$complexity, action=$action"

    # Handle based on action
    if [[ "$action" == "queue_for_claude" ]] && [[ -n "$next_task" ]]; then
        log INFO "Queueing task '$next_task' (complexity $complexity) for Claude"

        # Write to event queue if available
        if declare -f queue_write >/dev/null 2>&1; then
            # Use placeholder filename since tier2 escalations don't have a specific file
            queue_write "heartbeat_trigger" "$next_task" "tier2-escalation" "complexity=$complexity,action=tier2_escalation" 2>/dev/null || true
        else
            log WARN "queue_write not available, cannot queue task"
        fi
    elif [[ "$action" == "direct_work" ]]; then
        log INFO "Tier2 handled task '$next_task' directly (complexity $complexity)"
    else
        log DEBUG "No specific action required from tier2 response"
    fi

    return 0
}

# ============================================================================
# PUBLIC API
# ============================================================================

# tier2_init
# Initialize tier2 state directory
tier2_init() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before tier2.sh." >&2
        return 1
    fi

    _tier2_ensure_dir
    log DEBUG "Heartbeat Tier 2 initialized"
    return 0
}

# tier2_run
# Run proactive work cycle
# Returns: 0 always (errors logged)
tier2_run() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before tier2.sh." >&2
        return 1
    fi

    if [[ -z "${VAULT_TASKS_DIR:-}" ]]; then
        echo "Error: VAULT_TASKS_DIR not set. Source config.sh before tier2.sh." >&2
        return 1
    fi

    log INFO "Starting Tier 2 proactive work cycle"

    # Check ollama slot availability
    if ! _tier2_check_ollama_slots; then
        log INFO "Tier 2 exiting: no ollama slots available"
        return 0
    fi

    # Invoke ollama with context
    if ! _tier2_invoke_ollama; then
        log WARN "Tier 2 ollama invocation failed, exiting"
        return 0
    fi

    # Process response and take action
    _tier2_process_response

    # Update last run timestamp
    local state_dir
    state_dir="$(_tier2_get_state_dir)"
    local last_run_file="${state_dir}/tier2-last-run.txt"
    date -Iseconds > "$last_run_file" 2>/dev/null || true

    log INFO "Tier 2 proactive work cycle completed"
    return 0
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

# If script is executed directly (not sourced), run the cycle
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Source dependencies
    # Get to the project root from heartbeat/ subdirectory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    source "${SCRIPT_DIR}/config.sh"
    source "${SCRIPT_DIR}/lib/logging.sh"

    # Optional dependencies - degrade gracefully if missing
    if [[ -f "${SCRIPT_DIR}/lib/locking.sh" ]]; then
        source "${SCRIPT_DIR}/lib/locking.sh"
    fi

    if [[ -f "${SCRIPT_DIR}/lib/llm-registry.sh" ]]; then
        source "${SCRIPT_DIR}/lib/llm-registry.sh"
    fi

    if [[ -f "${SCRIPT_DIR}/lib/event-queue.sh" ]]; then
        source "${SCRIPT_DIR}/lib/event-queue.sh"
    fi

    # Initialize and run
    tier2_init || exit 1
    tier2_run || exit 1

    exit 0
fi
