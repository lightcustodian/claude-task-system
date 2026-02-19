#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Configuration
# ============================================================================
# Source this file in other scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
#
# All variables use ${VAR:-default} so they can be overridden by environment
# variables before sourcing.
# ============================================================================

# Auto-detect script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ================================================================
# DIRECTORY CONFIGURATION (Paths)
# ================================================================

# Local path to the claude-tasks directory (on Google Drive mount)
VAULT_TASKS_DIR="${VAULT_TASKS_DIR:-$HOME/GoogleDrive/DriveSyncFiles/claude-tasks}"

# Where Claude Code writes project/code files (outside the vault)
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"

# State directory for locks, logs, events, audit
STATE_DIR="${STATE_DIR:-$HOME/.claude-task-system}"

# ================================================================
# POLLING & TIMING
# ================================================================

# How often to check for stability timeout (seconds)
POLL_INTERVAL="${POLL_INTERVAL:-30}"

# Stability timeout: auto-trigger if file unchanged for this long (seconds)
STABILITY_TIMEOUT="${STABILITY_TIMEOUT:-300}"  # 5 minutes

# Default max LLM turns per task invocation
DEFAULT_MAX_TURNS="${DEFAULT_MAX_TURNS:-10}"

# Delay after inotifywait event to let FUSE writes settle (seconds)
INOTIFY_SETTLE_DELAY="${INOTIFY_SETTLE_DELAY:-2}"

# Scheduler main loop cycle time (seconds)
SCHEDULER_CYCLE="${SCHEDULER_CYCLE:-2}"

# How often to append stderr content to preview file (seconds)
PROGRESS_UPDATE_INTERVAL="${PROGRESS_UPDATE_INTERVAL:-5}"

# How often to update _status.md (seconds)
STATUS_UPDATE_INTERVAL="${STATUS_UPDATE_INTERVAL:-30}"

# ================================================================
# NOTIFICATION CONFIGURATION
# ================================================================

# Ntfy topic -- recognizable name for your notifications
NTFY_TOPIC="${NTFY_TOPIC:-johnlane-claude-tasks}"

# Ntfy server (use public server or your own)
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"

# ================================================================
# LOGGING CONFIGURATION
# ================================================================

LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR
LOG_DIR="${LOG_DIR:-$STATE_DIR/logs}"

# ================================================================
# DRY RUN MODE
# ================================================================

DRY_RUN="${DRY_RUN:-0}"  # Set to 1 to disable actual execution

# ================================================================
# LLM CONFIGURATION -- Claude
# ================================================================

LLM_CLAUDE_TYPE="${LLM_CLAUDE_TYPE:-cli}"
LLM_CLAUDE_MAX_PARALLEL="${LLM_CLAUDE_MAX_PARALLEL:-3}"
LLM_CLAUDE_COMMAND="${LLM_CLAUDE_COMMAND:-claude}"
LLM_CLAUDE_FLAGS="${LLM_CLAUDE_FLAGS:---dangerously-skip-permissions}"
LLM_CLAUDE_SESSION_TTL="${LLM_CLAUDE_SESSION_TTL:-3600}"

# ================================================================
# LLM CONFIGURATION -- Ollama
# ================================================================

LLM_OLLAMA_TYPE="${LLM_OLLAMA_TYPE:-api}"
LLM_OLLAMA_MAX_PARALLEL="${LLM_OLLAMA_MAX_PARALLEL:-3}"
LLM_OLLAMA_COMMAND="${LLM_OLLAMA_COMMAND:-ollama}"
LLM_OLLAMA_MODEL="${LLM_OLLAMA_MODEL:-mistral}"
LLM_OLLAMA_ENDPOINT="${LLM_OLLAMA_ENDPOINT:-http://localhost:11434}"

# ================================================================
# LLM REGISTRY
# ================================================================

# Array of known LLM names (used for lock directory scanning, etc.)
LLM_NAMES=("claude" "ollama")

# ================================================================
# ROUTING & COMPLEXITY
# ================================================================

DEFAULT_COMPLEXITY="${DEFAULT_COMPLEXITY:-medium}"
ROUTING_RULES=("high:claude" "medium:claude" "low:ollama")

# ================================================================
# VALIDATION -- ensure required directories exist
# ================================================================

ensure_dirs_exist() {
    local dirs=("$STATE_DIR" "$LOG_DIR")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || {
                echo "Warning: Could not create directory: $dir" >&2
            }
        fi
    done
}

# Auto-initialize directories when sourced
ensure_dirs_exist
