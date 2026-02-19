#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Mock Claude CLI (for testing)
# ============================================================================
# Drop-in replacement for the `claude` command during tests.
# Reads canned responses from MOCK_RESPONSE_DIR or generates minimal output.
#
# Environment Variables:
#   MOCK_RESPONSE_DIR  -- Directory containing canned .md response files
#                         (matched by task name). If unset, generates default.
#   MOCK_ERROR         -- If set, exit with this code (simulates failure)
#   MOCK_RATE_LIMIT    -- If "1", simulate rate limit (exit 10, TOKEN_EXHAUSTED)
#   MOCK_SESSION_ID    -- Session ID to emit (default: mock-session-001)
#   MOCK_DELAY         -- Seconds to sleep before responding (default: 0)
#   MOCK_LOG           -- If set, append invocation args to this file
#
# Usage (as a test double):
#   export LLM_CLAUDE_COMMAND="$PROJECT_ROOT/test/mock-claude.sh"
# ============================================================================

set -euo pipefail

# Log invocation if requested
if [[ -n "${MOCK_LOG:-}" ]]; then
    echo "$(date -Iseconds) mock-claude $*" >> "$MOCK_LOG"
fi

# Simulate delay
if [[ "${MOCK_DELAY:-0}" -gt 0 ]]; then
    sleep "$MOCK_DELAY"
fi

# Simulate rate limit
if [[ "${MOCK_RATE_LIMIT:-}" == "1" ]]; then
    echo "TOKEN_EXHAUSTED:$(date -d '+1 hour' -Iseconds 2>/dev/null || date -Iseconds)" >&1
    exit 10
fi

# Simulate error
if [[ -n "${MOCK_ERROR:-}" ]]; then
    echo "Mock error triggered (code $MOCK_ERROR)" >&2
    exit "$MOCK_ERROR"
fi

# Parse args to find the prompt/input file
# Claude Code CLI: claude [flags] -p "prompt" or claude [flags] --print "prompt"
input_text=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--print)
            shift
            input_text="${1:-}"
            shift
            ;;
        --resume)
            shift  # skip session id
            shift
            ;;
        --max-turns)
            shift  # skip number
            shift
            ;;
        --dangerously-skip-permissions)
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Emit session ID
echo "SESSION_ID:${MOCK_SESSION_ID:-mock-session-001}"

# Look for canned response
if [[ -n "${MOCK_RESPONSE_DIR:-}" ]] && [[ -d "$MOCK_RESPONSE_DIR" ]]; then
    # Try to find a matching response file
    for response_file in "${MOCK_RESPONSE_DIR}"/*.md; do
        if [[ -f "$response_file" ]]; then
            cat "$response_file"
            exit 0
        fi
    done
fi

# Default response
cat <<'RESPONSE'
This is a mock Claude response for testing purposes.

The task has been analyzed and a response generated.
RESPONSE

exit 0
