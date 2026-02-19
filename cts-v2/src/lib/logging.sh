#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Shared Logging Library
# ============================================================================
# Provides log() and log_to_file() functions with level-based filtering.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
#
#   log INFO "Application starting"
#   log DEBUG "Detailed debug info"
#   log WARN "Something unexpected"
#   log ERROR "Something went wrong"
#   log_to_file INFO "This goes to file only"
#
# Log Levels (in order of priority):
#   DEBUG (0) < INFO (1) < WARN (2) < ERROR (3)
#
# Output Format:
#   [YYYY-MM-DD HH:MM:SS] [LEVEL] message
#
# Configuration (from config.sh):
#   LOG_DIR   -- Directory for log files
#   LOG_LEVEL -- Minimum level to output (default: INFO)
#
# Dependencies:
#   - config.sh must be sourced first (provides LOG_DIR, LOG_LEVEL)
# ============================================================================

# --- Private Helpers ---

# Ensure the log directory exists
_ensure_log_dir() {
    local dir="${1:-$LOG_DIR}"
    if [[ -n "$dir" ]] && [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null || true
    fi
}

# Get default log file based on the calling script name
_get_default_log_file() {
    local caller="${BASH_SOURCE[2]:-unknown}"
    local basename
    basename="$(basename "$caller" .sh)"
    echo "${LOG_DIR}/${basename}.log"
}

# Map a log level string to a numeric priority
_log_level_priority() {
    local level="$1"
    case "${level^^}" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        *)     echo 1 ;;  # Default to INFO for unknown levels
    esac
}

# Check if a message at the given level should be output
_log_should_output() {
    local msg_level="$1"
    local threshold="${LOG_LEVEL:-INFO}"
    local msg_priority
    msg_priority="$(_log_level_priority "$msg_level")"
    local threshold_priority
    threshold_priority="$(_log_level_priority "$threshold")"
    [[ "$msg_priority" -ge "$threshold_priority" ]]
}

# --- Public API ---

# log <level> <message> [log_file]
# Writes to both stdout and log file
log() {
    local level="${1:-INFO}"
    shift
    local message="$*"
    local log_file="${log_file:-$(_get_default_log_file)}"

    # Check if this level should be output
    if ! _log_should_output "$level"; then
        return 0
    fi

    _ensure_log_dir "$(dirname "$log_file")"

    local log_entry
    log_entry="[$(date '+%Y-%m-%d %H:%M:%S')] [${level^^}] $message"

    echo "$log_entry" | tee -a "$log_file" 2>/dev/null || echo "$log_entry" >&2
}

# log_to_file <level> <message> [log_file]
# Writes to log file only (no stdout)
log_to_file() {
    local level="${1:-INFO}"
    shift
    local message="$*"
    local log_file="${log_file:-$(_get_default_log_file)}"

    # Check if this level should be output
    if ! _log_should_output "$level"; then
        return 0
    fi

    _ensure_log_dir "$(dirname "$log_file")"

    local log_entry
    log_entry="[$(date '+%Y-%m-%d %H:%M:%S')] [${level^^}] $message"

    echo "$log_entry" >> "$log_file" 2>/dev/null || true
}
