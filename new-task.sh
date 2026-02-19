#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- New Task Helper
# ============================================================================
# Creates a new task directory and initial prompt file.
#
# Usage:
#   ./new-task.sh <task-name> [--complexity high|medium|low]
#
# Example:
#   ./new-task.sh fix-login-bug --complexity high
#   ./new-task.sh refactor-auth
#
# Creates:
#   VAULT_TASKS_DIR/<task-name>/001_<task-name>.md
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cts-v2/src/config.sh"

# --- Argument parsing ---

TASK_NAME=""
COMPLEXITY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --complexity)
            shift
            COMPLEXITY="${1:-}"
            if [[ ! "$COMPLEXITY" =~ ^(high|medium|low)$ ]]; then
                echo "Error: --complexity must be high, medium, or low" >&2
                exit 1
            fi
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <task-name> [--complexity high|medium|low]"
            echo ""
            echo "Creates a new task directory with initial prompt file."
            echo "Task name should be lowercase with hyphens (e.g., fix-login-bug)."
            exit 0
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$TASK_NAME" ]]; then
                TASK_NAME="$1"
            else
                echo "Error: Multiple task names provided" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TASK_NAME" ]]; then
    echo "Error: Task name required" >&2
    echo "Usage: $0 <task-name> [--complexity high|medium|low]" >&2
    exit 1
fi

# Validate task name: lowercase, hyphens, numbers only
if [[ ! "$TASK_NAME" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] && [[ ! "$TASK_NAME" =~ ^[a-z0-9]$ ]]; then
    echo "Error: Task name must be lowercase letters, numbers, and hyphens" >&2
    echo "  Good: fix-login-bug, add-auth, refactor-api" >&2
    echo "  Bad:  Fix_Login, my task, --test" >&2
    exit 1
fi

# --- Create task ---

TASK_DIR="${VAULT_TASKS_DIR}/${TASK_NAME}"
FIRST_FILE="${TASK_DIR}/001_${TASK_NAME}.md"

if [[ -d "$TASK_DIR" ]]; then
    echo "Error: Task directory already exists: $TASK_DIR" >&2
    exit 1
fi

mkdir -p "$TASK_DIR"

# Write initial file with optional complexity metadata
{
    if [[ -n "$COMPLEXITY" ]]; then
        echo "<!-- complexity: ${COMPLEXITY} -->"
        echo ""
    fi
    echo "# ${TASK_NAME}"
    echo ""
    echo ""
    echo "<User>"
} > "$FIRST_FILE"

echo "Created: $TASK_DIR"
echo "Edit:    $FIRST_FILE"
echo ""
echo "Write your instructions in the file above, then save."
if [[ -z "$COMPLEXITY" ]]; then
    echo "Tip: Use --complexity high|medium|low to set routing priority."
fi
