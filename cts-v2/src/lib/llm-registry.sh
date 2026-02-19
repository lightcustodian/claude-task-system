#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- LLM Registry
# ============================================================================
# Extensible LLM registry without hardcoded if/elif branching.
#
# Usage:
#   source config.sh                    # MUST be first
#   source lib/logging.sh              # for log() function
#   source lib/locking.sh              # for lock_count() function
#   source lib/llm-registry.sh         # source this module
#
# Public API:
#   llm_list                    -- Output all registered LLM names (space-separated)
#   llm_get_max_parallel <name> -- Output max concurrent slots for LLM
#   llm_get_command <name>      -- Output CLI command for LLM
#   llm_get_type <name>         -- Output 'api' or 'local' type
#   llm_get_invoker <name>      -- Output invoker script path
#   llm_route_task <complexity> -- Route task to appropriate LLM
#   llm_slots_available <name>  -- Output free slot count
#   llm_is_exhausted <name>     -- Check token-state.json for exhaustion
#
# Routing Rules:
#   - Complexity 1-2 (low)   -> ollama
#   - Complexity 3 (high)    -> claude
#   - Overflow routing: busy ollama with complexity 2 -> claude
#   - Returns LLM name or 'QUEUED' if no LLM available
#
# Config Dependencies (from config.sh):
#   - LLM_NAMES array               -- List of registered LLM names
#   - LLM_<NAME>_TYPE               -- 'api' or 'local'
#   - LLM_<NAME>_MAX_PARALLEL       -- Max concurrent slots
#   - LLM_<NAME>_COMMAND            -- CLI command
#   - LLM_<NAME>_INVOKER            -- Invoker script path (optional)
#   - STATE_DIR                     -- For token-state.json checks
#
# Behavior Notes:
#   - Uses associative arrays to store LLM metadata (no if/elif chains)
#   - Validates LLM names against registered list
#   - Returns empty string for unknown LLMs
#   - Token exhaustion checks STATE_DIR/token-state.json per LLM
# ============================================================================

set -euo pipefail

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

# Validate LLM name is registered
_llm_validate_name() {
    local name="$1"

    if [[ -z "$STATE_DIR" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before llm-registry.sh." >&2
        return 1
    fi

    # Check against LLM_NAMES array from config.sh
    for registered in "${LLM_NAMES[@]}"; do
        if [[ "$registered" == "$name" ]]; then
            return 0
        fi
    done

    return 1
}

# Get config variable for LLM using variable indirection
_llm_get_config() {
    local llm_name="$1"
    local config_key="$2"

    # Build variable name: LLM_CLAUDE_COMMAND, LLM_OLLAMA_MAX_PARALLEL, etc.
    local var_name="LLM_${llm_name^^}_${config_key}"

    # Use indirect reference to get value
    if [[ -n "${!var_name:-}" ]]; then
        echo "${!var_name}"
    fi
}

# Default invoker path based on LLM name
_llm_default_invoker() {
    local llm_name="$1"

    # For now, all invokers are in src/invokers/
    # If LLM_<NAME>_INVOKER is not set in config, construct default
    echo "src/invokers/invoke-${llm_name}.sh"
}

# Check if LLM has exhausted token quota
_llm_check_exhaustion() {
    local llm_name="$1"

    # Path to token state file
    local token_state_file="${STATE_DIR}/token-state.json"

    if [[ ! -f "$token_state_file" ]]; then
        # No token state file means not exhausted
        return 1
    fi

    # Check if jq is available for JSON parsing
    if ! command -v jq >/dev/null 2>&1; then
        # Can't check without jq, assume not exhausted
        return 1
    fi

    # Check for exhaustion flag for this LLM
    local exhausted
    exhausted=$(jq -r --arg llm "$llm_name" '.exhausted[$llm] // "false"' "$token_state_file" 2>/dev/null)

    if [[ "$exhausted" == "true" ]]; then
        return 0
    fi

    return 1
}

# ============================================================================
# PUBLIC API
# ============================================================================

# Output all registered LLM names (space-separated)
llm_list() {
    if [[ -z "$STATE_DIR" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before llm-registry.sh." >&2
        return 1
    fi

    # Output LLM_NAMES array as space-separated string
    echo "${LLM_NAMES[@]}"
}

# Output max concurrent slots for LLM
llm_get_max_parallel() {
    local llm_name="$1"

    if [[ -z "$STATE_DIR" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before llm-registry.sh." >&2
        return 1
    fi

    if ! _llm_validate_name "$llm_name"; then
        return 1
    fi

    _llm_get_config "$llm_name" "MAX_PARALLEL"
}

# Output CLI command for LLM
llm_get_command() {
    local llm_name="$1"

    if [[ -z "$STATE_DIR" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before llm-registry.sh." >&2
        return 1
    fi

    if ! _llm_validate_name "$llm_name"; then
        return 1
    fi

    _llm_get_config "$llm_name" "COMMAND"
}

# Output 'api' or 'local' type for LLM
llm_get_type() {
    local llm_name="$1"

    if [[ -z "$STATE_DIR" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before llm-registry.sh." >&2
        return 1
    fi

    if ! _llm_validate_name "$llm_name"; then
        return 1
    fi

    _llm_get_config "$llm_name" "TYPE"
}

# Output invoker script path for LLM
llm_get_invoker() {
    local llm_name="$1"

    if [[ -z "$STATE_DIR" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before llm-registry.sh." >&2
        return 1
    fi

    if ! _llm_validate_name "$llm_name"; then
        return 1
    fi

    # Try config-specific invoker first
    local invoker
    invoker=$(_llm_get_config "$llm_name" "INVOKER")

    if [[ -n "$invoker" ]]; then
        echo "$invoker"
    else
        _llm_default_invoker "$llm_name"
    fi
}

# Route task to appropriate LLM based on complexity
# Outputs: LLM name or 'QUEUED' if no LLM available
llm_route_task() {
    local complexity="$1"

    if [[ -z "$STATE_DIR" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before llm-registry.sh." >&2
        return 1
    fi

    # Ensure locking.sh is loaded for lock_count
    if ! declare -f lock_count >/dev/null 2>&1; then
        echo "Error: locking.sh not loaded. Source lib/locking.sh before llm-registry.sh." >&2
        return 1
    fi

    # Routing rules:
    # - Complexity 1-2 -> ollama (if available and not exhausted)
    # - Complexity 3 -> claude (if available and not exhausted)
    # - Overflow: if ollama busy for complexity 2, route to claude

    local target_llm=""

    if [[ "$complexity" -ge 1 ]] && [[ "$complexity" -le 2 ]]; then
        # Low complexity -> try ollama first
        target_llm="ollama"

        # Check if ollama is available
        local ollama_exhausted=0
        _llm_check_exhaustion "ollama" && ollama_exhausted=1

        local ollama_slots=0
        ollama_slots=$(llm_slots_available "ollama" 2>/dev/null || echo 0)

        if [[ "$ollama_exhausted" -eq 1 ]] || [[ "$ollama_slots" -le 0 ]]; then
            # Ollama unavailable - for complexity 2, try claude (overflow routing)
            if [[ "$complexity" -eq 2 ]]; then
                target_llm="claude"

                local claude_exhausted=0
                _llm_check_exhaustion "claude" && claude_exhausted=1

                local claude_slots=0
                claude_slots=$(llm_slots_available "claude" 2>/dev/null || echo 0)

                if [[ "$claude_exhausted" -eq 1 ]] || [[ "$claude_slots" -le 0 ]]; then
                    # Claude also unavailable
                    target_llm=""
                fi
            else
                # Complexity 1 can only go to ollama
                target_llm=""
            fi
        fi

    elif [[ "$complexity" -eq 3 ]]; then
        # High complexity -> claude
        target_llm="claude"

        local claude_exhausted=0
        _llm_check_exhaustion "claude" && claude_exhausted=1

        local claude_slots=0
        claude_slots=$(llm_slots_available "claude" 2>/dev/null || echo 0)

        if [[ "$claude_exhausted" -eq 1 ]] || [[ "$claude_slots" -le 0 ]]; then
            # Claude unavailable
            target_llm=""
        fi
    fi

    # Output result
    if [[ -n "$target_llm" ]]; then
        echo "$target_llm"
        return 0
    else
        echo "QUEUED"
        return 1
    fi
}

# Output free slot count for LLM
llm_slots_available() {
    local llm_name="$1"

    if [[ -z "$STATE_DIR" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before llm-registry.sh." >&2
        return 1
    fi

    if ! _llm_validate_name "$llm_name"; then
        return 1
    fi

    # Ensure locking.sh is loaded
    if ! declare -f lock_count >/dev/null 2>&1; then
        echo "Error: locking.sh not loaded. Source lib/locking.sh before llm-registry.sh." >&2
        return 1
    fi

    # Get max parallel slots
    local max_parallel
    max_parallel=$(llm_get_max_parallel "$llm_name")

    if [[ -z "$max_parallel" ]]; then
        echo 0
        return 1
    fi

    # Get current lock count
    local current_slots
    current_slots=$(lock_count "$llm_name" 2>/dev/null || echo 0)

    # Calculate available slots
    local available=$((max_parallel - current_slots))

    if [[ "$available" -lt 0 ]]; then
        available=0
    fi

    echo "$available"
}

# Check if LLM is exhausted (token-state.json)
# Returns 0 if exhausted, 1 otherwise
llm_is_exhausted() {
    local llm_name="$1"

    if [[ -z "$STATE_DIR" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before llm-registry.sh." >&2
        return 1
    fi

    if ! _llm_validate_name "$llm_name"; then
        return 1
    fi

    if _llm_check_exhaustion "$llm_name"; then
        return 0
    fi

    return 1
}
