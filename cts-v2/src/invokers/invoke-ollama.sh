#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Ollama Invoker
# ============================================================================
# Standalone invoker script implementing the PRD section 6.1 invoker contract.
# Invokes Ollama API for a given task, handles response formatting,
# and system prompt generation based on complexity.
#
# Usage:
#   ./invoke-ollama.sh <task-dir> <input-file> <output-file>
#
# Arguments:
#   task-dir     -- Path to the task directory
#   input-file   -- Input markdown file (prompt)
#   output-file  -- Output markdown file (response)
#
# Output Protocol:
#   - Response file starts with: <!-- CLAUDE-RESPONSE -->
#   - Response file ends with: # <User>
#
# Exit Codes:
#   0  -- Success
#   1  -- Argument error / validation failure
#   2  -- Ollama daemon not running
#   *  -- Propagated from ollama command
#
# Environment:
#   COMPLEXITY    -- 1 (minimal context) or 2 (fuller context), default 1
#   STDERR_LOG    -- Path to stderr log file (optional)
#
# Dependencies:
#   - config.sh (LLM_OLLAMA_COMMAND, LLM_OLLAMA_MODEL, STATE_DIR)
# ============================================================================

set -euo pipefail

# --- Private Helpers ---

# Validate arguments and set up variables
_invoke_parse_args() {
    if [[ $# -ne 3 ]]; then
        echo "ERROR: Usage: invoke-ollama.sh <task-dir> <input-file> <output-file>" >&2
        return 1
    fi

    TASK_DIR="$1"
    INPUT_FILE="$2"
    OUTPUT_FILE="$3"

    # Validate paths - path traversal protection
    if [[ "$TASK_DIR" == *".."* ]]; then
        echo "ERROR: Path traversal detected in task-dir" >&2
        return 1
    fi

    if [[ ! -d "$TASK_DIR" ]]; then
        echo "ERROR: Task directory does not exist: $TASK_DIR" >&2
        return 1
    fi
}

# Validate environment variables
_invoke_validate_env() {
    if [[ -z "${LLM_OLLAMA_COMMAND:-}" ]]; then
        echo "ERROR: LLM_OLLAMA_COMMAND not set (source config.sh first)" >&2
        return 1
    fi

    if [[ -z "${LLM_OLLAMA_MODEL:-}" ]]; then
        echo "ERROR: LLM_OLLAMA_MODEL not set (source config.sh first)" >&2
        return 1
    fi
}

# Build system prompt based on COMPLEXITY level
_invoke_build_system_prompt() {
    local complexity="${COMPLEXITY:-1}"

    case "$complexity" in
        1)
            # Minimal context for complexity 1
            cat <<'EOF'
You are a helpful AI assistant. Provide concise, direct responses to user requests.
Focus on the immediate task without excessive elaboration.
EOF
            ;;
        2)
            # Fuller context for complexity 2
            cat <<'EOF'
You are a helpful AI assistant with access to comprehensive context.
Provide detailed, thorough responses that consider:
- The broader context of the user's request
- Potential implications and edge cases
- Clear explanations of your reasoning
- Actionable next steps when relevant

Balance completeness with clarity.
EOF
            ;;
        *)
            # Default to minimal
            cat <<'EOF'
You are a helpful AI assistant. Provide concise, direct responses to user requests.
EOF
            ;;
    esac
}

# Check if Ollama daemon is running
_invoke_check_ollama_running() {
    local ollama_cmd="${LLM_OLLAMA_COMMAND:-ollama}"

    # Try to list models - this fails if daemon is not running
    if "$ollama_cmd" list >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Read the prompt from the input file, stripping turn markers
_invoke_read_prompt() {
    local input_path="$TASK_DIR/$INPUT_FILE"

    if [[ ! -f "$input_path" ]]; then
        echo "ERROR: Input file does not exist: $input_path" >&2
        return 1
    fi

    # Read file content, strip Claude response markers and user signal
    local content
    content="$(cat "$input_path")"

    # Remove the CLAUDE-RESPONSE marker if present
    content="${content//<!-- CLAUDE-RESPONSE -->/}"

    # Remove trailing # <User> or <User> markers
    content="${content//
#
<User>/}"
    content="${content//<User>/}"

    echo "$content"
}

# --- Main Execution ---

_invoke_run() {
    _invoke_parse_args "$@" || exit 1
    _invoke_validate_env || exit 1

    # Check if Ollama is running
    if ! _invoke_check_ollama_running; then
        echo "ERROR: Ollama daemon is not running" >&2
        echo "Start it with: ollama serve" >&2
        exit 2
    fi

    local task_name
    task_name="$(basename "$TASK_DIR")"

    # Set up stderr log
    local stderr_log="${STDERR_LOG:-${STATE_DIR:-$HOME/.claude-task-system}/logs/${task_name}_${OUTPUT_FILE%.md}.log}"
    mkdir -p "$(dirname "$stderr_log")"

    # Read the prompt
    local prompt
    prompt="$(_invoke_read_prompt)" || exit 1

    # Build system prompt
    local system_prompt
    system_prompt="$(_invoke_build_system_prompt)"

    # Build the full prompt with system prompt
    local full_prompt
    full_prompt="${system_prompt}

${prompt}"

    # Invoke Ollama with stdin
    local response=""
    local exit_code=0
    local ollama_cmd="${LLM_OLLAMA_COMMAND:-ollama}"
    local model="${LLM_OLLAMA_MODEL:-mistral}"

    response=$(echo "$full_prompt" | "$ollama_cmd" run "$model" --stdin 2>>"$stderr_log") || exit_code=$?

    # Write response with markers if Ollama succeeded
    if [[ $exit_code -eq 0 ]]; then
        local output_path="$TASK_DIR/$OUTPUT_FILE"
        {
            echo "<!-- CLAUDE-RESPONSE -->"
            echo ""
            echo "$response"
            echo ""
            echo "# <User>"
        } > "$output_path"
    fi

    exit $exit_code
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Source config if available
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$SCRIPT_DIR/../config.sh" ]]; then
        source "$SCRIPT_DIR/../config.sh"
    fi

    _invoke_run "$@"
fi
