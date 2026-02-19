#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Claude Code Invoker
# ============================================================================
# Standalone invoker script implementing the PRD section 6.1 invoker contract.
# Invokes Claude Code CLI for a given task, handles response formatting,
# session management, and rate limit detection.
#
# Usage:
#   ./invoke-claude.sh <task-dir> <input-file> <output-file> [--resume <session-id>]
#
# Arguments:
#   task-dir     -- Path to the task directory
#   input-file   -- Input markdown file (prompt)
#   output-file  -- Output markdown file (response)
#   --resume     -- Optional: resume an existing session
#
# Output Protocol:
#   - Response file starts with: <!-- CLAUDE-RESPONSE -->
#   - Response file ends with: # <User>
#   - On rate limit: outputs TOKEN_EXHAUSTED:<reset-time> to stdout
#   - Session ID: outputs SESSION_ID:<id> to stdout when available
#
# Exit Codes:
#   0  -- Success
#   1  -- Argument error / validation failure
#   10 -- Rate limit / token exhaustion
#   *  -- Propagated from Claude CLI
#
# Environment:
#   Uses env -u CLAUDECODE to prevent nested session error
#
# Dependencies:
#   - config.sh (LLM_CLAUDE_COMMAND, LLM_CLAUDE_FLAGS, DEFAULT_MAX_TURNS,
#                PROJECTS_DIR, STATE_DIR)
# ============================================================================

set -euo pipefail

# --- Private Helpers ---

# Validate arguments and set up variables
_invoke_parse_args() {
    if [[ $# -lt 3 ]]; then
        echo "ERROR: Usage: invoke-claude.sh <task-dir> <input-file> <output-file> [--resume <session-id>]" >&2
        return 1
    fi

    TASK_DIR="$1"
    INPUT_FILE="$2"
    OUTPUT_FILE="$3"
    RESUME_SESSION=""

    shift 3

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resume)
                if [[ $# -lt 2 ]]; then
                    echo "ERROR: --resume requires a session ID" >&2
                    return 1
                fi
                RESUME_SESSION="$2"
                shift 2
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                return 1
                ;;
        esac
    done

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
    if [[ -z "${LLM_CLAUDE_COMMAND:-}" ]]; then
        echo "ERROR: LLM_CLAUDE_COMMAND not set (source config.sh first)" >&2
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
    content="$(echo "$content" | sed '1{/<!-- CLAUDE-RESPONSE -->/d}')"

    # Remove trailing # <User> or <User> markers
    content="$(echo "$content" | sed '/^\s*#\?\s*<User>\s*$/d')"

    echo "$content"
}

# Check stderr log for rate limit patterns
_invoke_check_rate_limit() {
    local stderr_log="$1"

    if [[ ! -f "$stderr_log" ]]; then
        return 1
    fi

    # Look for rate limit / token exhaustion patterns
    if grep -qiE '(rate.?limit|token.?exhaust|too.?many.?requests|429)' "$stderr_log" 2>/dev/null; then
        # Try to extract reset time
        local reset_time
        reset_time=$(grep -oiP '(reset|retry).{0,20}?(\d+)' "$stderr_log" 2>/dev/null | grep -oP '\d+' | tail -1)
        reset_time="${reset_time:-60}"
        echo "TOKEN_EXHAUSTED:${reset_time}"
        return 0
    fi

    return 1
}

# Extract turns used from Claude's stderr
_invoke_extract_turns_used() {
    local stderr_log="$1"

    if [[ ! -f "$stderr_log" ]]; then
        return 1
    fi

    # Pattern 1: "Turns used: 10/10" or "turns: 10"
    local turns
    turns=$(grep -oiP '(?:turns?\s*(?:used)?)\s*:?\s*(\d+)(?:/\d+)?' "$stderr_log" 2>/dev/null | grep -oP '\d+' | head -1)

    if [[ -n "$turns" ]]; then
        echo "$turns"
        return 0
    fi

    # Pattern 2: "max turns reached" or "maximum turns"
    if grep -qiP '(?:max(?:imum)?|hit)\s+turns?\s+(?:reached|limit)' "$stderr_log" 2>/dev/null; then
        # If max turns mentioned, try to extract the number
        turns=$(grep -oiP '(?:max(?:imum)?|hit)\s+turns?.*?(\d+)' "$stderr_log" 2>/dev/null | grep -oP '\d+' | head -1)
        if [[ -n "$turns" ]]; then
            echo "$turns"
            return 0
        fi
    fi

    return 1
}

# Extract session ID from Claude's stderr or project directory
_invoke_extract_session_id() {
    local stderr_log="$1"
    local task_name="$2"

    # Method 1: Parse stderr for session patterns
    if [[ -f "$stderr_log" ]]; then
        local session_id
        session_id=$(grep -oP 'Session:\s*\K[a-f0-9-]+' "$stderr_log" 2>/dev/null | head -1)
        if [[ -n "$session_id" ]]; then
            echo "$session_id"
            return
        fi

        # Alternative pattern
        session_id=$(grep -oP 'session[_-]?id[=:]\s*\K[a-f0-9-]+' "$stderr_log" 2>/dev/null | head -1)
        if [[ -n "$session_id" ]]; then
            echo "$session_id"
            return
        fi
    fi

    # Method 2: Check Claude project directory
    local claude_project_dir="$HOME/.claude/projects"
    if [[ -d "$claude_project_dir" ]]; then
        # Look for recent session files
        local session_file
        session_file=$(find "$claude_project_dir" -name "*.json" -newer "$TASK_DIR/$INPUT_FILE" 2>/dev/null | head -1)
        if [[ -n "$session_file" ]]; then
            local sid
            sid=$(basename "$session_file" .json)
            echo "$sid"
            return
        fi
    fi

    # Method 3: Generate fallback UUID
    if command -v uuidgen &>/dev/null; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "unknown"
    fi
}

# Store session ID to session file for resume capability
_invoke_store_session_id() {
    local session_id="$1"
    local task_name="$2"

    # Validate inputs
    if [[ -z "$session_id" ]]; then
        echo "ERROR: session_id is required" >&2
        return 1
    fi

    if [[ -z "$task_name" ]]; then
        echo "ERROR: task_name is required" >&2
        return 1
    fi

    # Path traversal protection
    if [[ "$task_name" == *".."* ]] || [[ "$task_name" == *"/"* ]]; then
        echo "ERROR: Path traversal detected in task_name" >&2
        return 1
    fi

    # Ensure sessions directory exists
    local sessions_dir="${STATE_DIR:-$HOME/.claude-task-system}/sessions"
    mkdir -p "$sessions_dir" 2>/dev/null || true

    # Write session ID to file
    local session_file="$sessions_dir/${task_name}.session"
    echo "$session_id" > "$session_file"
}

# Load session ID from session file
_invoke_load_session_id() {
    local task_name="$1"

    # Validate input
    if [[ -z "$task_name" ]]; then
        echo "ERROR: task_name is required" >&2
        return 1
    fi

    # Path traversal protection
    if [[ "$task_name" == *".."* ]] || [[ "$task_name" == *"/"* ]]; then
        echo "ERROR: Path traversal detected in task_name" >&2
        return 1
    fi

    local sessions_dir="${STATE_DIR:-$HOME/.claude-task-system}/sessions"
    local session_file="$sessions_dir/${task_name}.session"

    if [[ -f "$session_file" ]]; then
        cat "$session_file"
    else
        return 1
    fi
}

# Invalidate (remove) session files older than 24 hours
_invoke_invalidate_old_sessions() {
    local sessions_dir="${STATE_DIR:-$HOME/.claude-task-system}/sessions"

    if [[ ! -d "$sessions_dir" ]]; then
        return 0
    fi

    # Find and remove sessions older than 24 hours (1440 minutes)
    find "$sessions_dir" -name "*.session" -type f -mmin +1440 -delete 2>/dev/null || true
}

# --- Main Execution ---

_invoke_run() {
    _invoke_parse_args "$@" || exit 1
    _invoke_validate_env || exit 1

    local task_name
    task_name="$(basename "$TASK_DIR")"

    # Invalidate old session files (cleanup)
    _invoke_invalidate_old_sessions 2>/dev/null || true

    # Create project directory for Claude
    local task_project_dir="${PROJECTS_DIR:-$HOME/projects}/$task_name"
    mkdir -p "$task_project_dir"

    # Set up stderr log
    local stderr_log="${STATE_DIR:-$HOME/.claude-task-system}/logs/${task_name}_${OUTPUT_FILE%.md}.log"
    mkdir -p "$(dirname "$stderr_log")"

    # Try to load existing session ID if no resume session was provided
    if [[ -z "$RESUME_SESSION" ]]; then
        RESUME_SESSION=$(_invoke_load_session_id "$task_name" 2>/dev/null || echo "")
    fi

    # Read the prompt
    local prompt
    prompt="$(_invoke_read_prompt)" || exit 1

    # Build Claude command arguments
    local -a claude_args=()
    claude_args+=(-p "$prompt")
    claude_args+=(--max-turns "${DEFAULT_MAX_TURNS:-10}")

    # Add flags from config
    if [[ -n "${LLM_CLAUDE_FLAGS:-}" ]]; then
        # shellcheck disable=SC2206
        claude_args+=($LLM_CLAUDE_FLAGS)
    fi

    # Add resume if specified
    if [[ -n "$RESUME_SESSION" ]]; then
        claude_args+=(--resume "$RESUME_SESSION")
    fi

    # Invoke Claude Code with env -u CLAUDECODE to prevent nested session error
    local response=""
    local exit_code=0

    response=$(cd "$TASK_DIR" && env -u CLAUDECODE ${LLM_CLAUDE_COMMAND} "${claude_args[@]}" 2>>"$stderr_log") || exit_code=$?

    # Check for rate limit
    local rate_limit_info
    rate_limit_info="$(_invoke_check_rate_limit "$stderr_log" || true)"
    if [[ -n "$rate_limit_info" ]]; then
        echo "$rate_limit_info"
        exit 10
    fi

    # Extract and output session ID
    local session_id
    session_id="$(_invoke_extract_session_id "$stderr_log" "$task_name" || true)"
    if [[ -n "$session_id" ]]; then
        echo "SESSION_ID:$session_id"

        # Store session ID for future resume
        _invoke_store_session_id "$session_id" "$task_name" 2>/dev/null || true
    fi

    # Extract and output turns used
    local turns_used
    turns_used="$(_invoke_extract_turns_used "$stderr_log" || true)"
    if [[ -n "$turns_used" ]]; then
        echo "TURNS_USED:$turns_used"
    fi

    # Write response with markers if Claude succeeded
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
