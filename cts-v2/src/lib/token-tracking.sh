#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Token State Tracking
# ============================================================================
# Track LLM token exhaustion and usage state.
#
# Usage:
#   source config.sh                    # MUST be first
#   source lib/logging.sh              # for log() function
#   source lib/token-tracking.sh       # source this module
#
# Public API:
#   token_init                      -- Create token-state.json if not exists
#   token_mark_exhausted <llm> <time> -- Mark LLM as exhausted with reset time
#   token_clear_exhausted <llm>      -- Clear exhaustion flag for LLM
#   token_is_exhausted <llm>         -- Return 0 if exhausted (not past reset), 1 if available
#   token_get_reset_time <llm>       -- Output reset time for LLM
#
# State File:
#   STATE_DIR/token-state.json -- JSON format with exhaustion state and reset times
#
# Config Dependencies (from config.sh):
#   - STATE_DIR -- Directory for token-state.json
#
# External dependencies:
#   - jq -- For JSON manipulation (optional, functions fail gracefully without it)
#
# Behavior Notes:
#   - token_init creates initial JSON with empty exhausted object
#   - token_is_exhausted checks both flag and reset_time against current time
#   - Reset time format: ISO 8601 (e.g., '2025-02-18T00:00:00Z')
#   - Functions use jq for safe JSON manipulation
# ============================================================================

set -euo pipefail

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

# Get path to token state file
_token_get_state_path() {
    echo "${STATE_DIR:-}/token-state.json"
}

# Ensure jq is available, return 1 if not
_token_check_jq() {
    command -v jq >/dev/null 2>&1
}

# ============================================================================
# PUBLIC API
# ============================================================================

# Create token-state.json if it doesn't exist
token_init() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before token-tracking.sh." >&2
        return 1
    fi

    local state_path
    state_path=$(_token_get_state_path)

    # Create file if it doesn't exist
    if [[ ! -f "$state_path" ]]; then
        # Create parent directory if needed
        mkdir -p "$(dirname "$state_path")" 2>/dev/null || true

        # Initialize with empty exhausted object
        cat > "$state_path" << 'EOF'
{
  "exhausted": {}
}
EOF

        return 0
    fi

    # File already exists
    return 0
}

# Mark LLM as exhausted with estimated reset time
token_mark_exhausted() {
    local llm_name="$1"
    local reset_time="$2"

    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before token-tracking.sh." >&2
        return 1
    fi

    if [[ -z "$llm_name" ]]; then
        echo "Error: llm_name is required" >&2
        return 1
    fi

    if [[ -z "$reset_time" ]]; then
        echo "Error: reset_time is required" >&2
        return 1
    fi

    # Check for jq
    if ! _token_check_jq; then
        echo "Error: jq not installed. Required for token_mark_exhausted." >&2
        return 1
    fi

    local state_path
    state_path=$(_token_get_state_path)

    # Initialize state file if it doesn't exist
    token_init

    # Update JSON: set exhausted flag and reset_time for LLM
    local temp_file="${state_path}.tmp.$$"
    jq --arg llm "$llm_name" \
       --arg reset "$reset_time" \
       '.exhausted[$llm] = true | .reset_time[$llm] = $reset' \
       "$state_path" > "$temp_file" && mv "$temp_file" "$state_path"

    return $?
}

# Clear exhaustion flag for LLM
token_clear_exhausted() {
    local llm_name="$1"

    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before token-tracking.sh." >&2
        return 1
    fi

    if [[ -z "$llm_name" ]]; then
        echo "Error: llm_name is required" >&2
        return 1
    fi

    # Check for jq
    if ! _token_check_jq; then
        echo "Error: jq not installed. Required for token_clear_exhausted." >&2
        return 1
    fi

    local state_path
    state_path=$(_token_get_state_path)

    # If state file doesn't exist, nothing to clear
    if [[ ! -f "$state_path" ]]; then
        return 0
    fi

    # Update JSON: remove exhausted flag and reset_time for LLM
    local temp_file="${state_path}.tmp.$$"
    jq --arg llm "$llm_name" \
       'del(.exhausted[$llm]) | del(.reset_time[$llm])' \
       "$state_path" > "$temp_file" && mv "$temp_file" "$state_path"

    return $?
}

# Check if LLM is exhausted
# Returns 0 if exhausted (and reset time hasn't passed), 1 if available
token_is_exhausted() {
    local llm_name="$1"

    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before token-tracking.sh." >&2
        return 1
    fi

    if [[ -z "$llm_name" ]]; then
        echo "Error: llm_name is required" >&2
        return 1
    fi

    local state_path
    state_path=$(_token_get_state_path)

    # If state file doesn't exist, not exhausted
    if [[ ! -f "$state_path" ]]; then
        return 1
    fi

    # Check for jq
    if ! _token_check_jq; then
        # Can't check without jq, assume not exhausted
        return 1
    fi

    # Check exhaustion flag
    local exhausted
    exhausted=$(jq -r --arg llm "$llm_name" '.exhausted[$llm] // "false"' "$state_path" 2>/dev/null)

    if [[ "$exhausted" != "true" ]]; then
        # Not marked as exhausted
        return 1
    fi

    # Check reset time
    local reset_time
    reset_time=$(jq -r --arg llm "$llm_name" '.reset_time[$llm] // ""' "$state_path" 2>/dev/null)

    if [[ -z "$reset_time" ]]; then
        # No reset time but marked as exhausted - treat as exhausted
        return 0
    fi

    # Get current time in seconds since epoch
    local current_time
    current_time=$(date +%s)

    # Parse reset time to seconds (GNU date handles ISO 8601)
    local reset_seconds
    reset_seconds=$(date -d "$reset_time" +%s 2>/dev/null || echo 0)

    if [[ "$reset_seconds" -eq 0 ]]; then
        # Failed to parse reset time, treat as exhausted to be safe
        return 0
    fi

    # If reset time has passed, not exhausted anymore
    if [[ "$current_time" -ge "$reset_seconds" ]]; then
        return 1
    fi

    # Still exhausted
    return 0
}

# Output reset time for LLM
token_get_reset_time() {
    local llm_name="$1"

    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before token-tracking.sh." >&2
        return 1
    fi

    if [[ -z "$llm_name" ]]; then
        echo "Error: llm_name is required" >&2
        return 1
    fi

    local state_path
    state_path=$(_token_get_state_path)

    # If state file doesn't exist, no reset time
    if [[ ! -f "$state_path" ]]; then
        return 1
    fi

    # Check for jq
    if ! _token_check_jq; then
        return 1
    fi

    # Get reset time
    local reset_time
    reset_time=$(jq -r --arg llm "$llm_name" '.reset_time[$llm] // ""' "$state_path" 2>/dev/null)

    if [[ -n "$reset_time" ]]; then
        echo "$reset_time"
        return 0
    fi

    return 1
}
