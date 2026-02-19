#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Turn Detection Library
# ============================================================================
# Provides turn detection logic for monitoring conversation flow in
# markdown-based task files. Extracted from daemon.sh (lines 40-133).
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/turn-detection.sh"
#
#   latest=$(get_latest_md "/path/to/task")
#   turn=$(detect_turn "/path/to/task" "$latest")
#   # turn is 'claude', 'user', or 'edited'
#
#   if check_readiness "/path/to/task" "$latest"; then
#       echo "File is ready for processing"
#   fi
#
#   if detect_stop "/path/to/task" "$latest"; then
#       echo "Stop signal found"
#   fi
#
# Functions:
#   get_latest_md       - Returns latest NNN_name.md file in a task dir
#   get_file_number     - Extracts numeric prefix from filename
#   get_next_filename   - Generates next numbered filename
#   get_file_mtime      - Returns file modification time (epoch seconds)
#   detect_turn         - Returns 'claude', 'user', or 'edited'
#   check_readiness     - Returns 0 if file is ready (signal or timeout)
#   detect_stop         - Returns 0 if <Stop> found on its own line
#
# Dependencies:
#   - config.sh must be sourced first (provides STABILITY_TIMEOUT)
# ============================================================================

# --- File Utilities ---

# Get the latest .md file in a task directory (supports NNN_name.md format)
# Args: $1 = task directory path
# Output: filename (e.g., "003_taskname.md") or empty string
get_latest_md() {
    local task_dir="$1"
    find "$task_dir" -maxdepth 1 -name '[0-9]*.md' -printf '%f\n' 2>/dev/null | \
        sort -t_ -k1,1n | tail -1
}

# Extract the numeric prefix from a filename like 001_taskname.md
# Args: $1 = filename
# Output: numeric string (e.g., "001")
get_file_number() {
    local filename="$1"
    echo "$filename" | grep -oP '^\d+'
}

# Generate the next filename given the current one and the task name
# Args: $1 = current filename, $2 = task name
# Output: next filename (e.g., "002_taskname.md")
get_next_filename() {
    local current="$1"
    local task_name="$2"
    local num
    num="$(get_file_number "$current")"
    local next=$(( 10#$num + 1 ))
    printf "%03d_%s.md" "$next" "$task_name"
}

# Get file modification time as epoch seconds
# Args: $1 = file path
# Output: epoch seconds (integer) or "0" if file not found
get_file_mtime() {
    local filepath="$1"
    stat -c %Y "$filepath" 2>/dev/null || echo "0"
}

# --- Turn Detection ---

# Signal system:
#   - Claude's responses start with <!-- CLAUDE-RESPONSE --> and end with "# <User>"
#   - When the user is done editing, they remove the "#" so it becomes "<User>"
#   - For user-created files (first message), the user adds "<User>" at the end
#   - The 5-minute stability timeout remains as a fallback

# Returns "claude" if the latest file is an unedited Claude response,
# "user" if the file is a user-created file,
# "edited" if a Claude response has been modified by the user
# Args: $1 = task directory, $2 = filename
# Output: 'claude' | 'user' | 'edited'
detect_turn() {
    local task_dir="$1"
    local latest="$2"
    local filepath="$task_dir/$latest"

    # Check if file STARTS with the Claude response marker (first line only)
    if head -1 "$filepath" 2>/dev/null | grep -q '<!-- CLAUDE-RESPONSE -->'; then
        # It's a Claude response -- check if "# <User>" is still intact (unedited)
        if grep -qP '^\s*#\s*<User>\s*$' "$filepath" 2>/dev/null; then
            echo "claude"
        else
            echo "edited"
        fi
    else
        # No Claude marker -- this is a user-created file
        echo "user"
    fi
}

# --- Readiness Check ---

# Check if a file is ready to be processed
# Instant trigger: <User> tag (without # prefix) on its own line
# Fallback: stability timeout (file unchanged for STABILITY_TIMEOUT seconds)
# Args: $1 = task directory, $2 = filename
# Returns: 0 if ready, 1 if not
check_readiness() {
    local task_dir="$1"
    local latest="$2"
    local filepath="$task_dir/$latest"

    # Instant trigger: <User> on its own line (not "# <User>" which is Claude's placeholder)
    if grep -qP '^\s*<User>\s*$' "$filepath" 2>/dev/null; then
        local user_lines
        user_lines=$(grep -cP '^\s*<User>\s*$' "$filepath" 2>/dev/null || echo "0")
        if [[ "$user_lines" -gt 0 ]]; then
            return 0
        fi
    fi

    # Stability trigger: file hasn't changed for STABILITY_TIMEOUT seconds
    local mtime
    mtime="$(get_file_mtime "$filepath")"
    local now
    now="$(date +%s)"
    local age=$(( now - mtime ))

    if [[ "$age" -ge "${STABILITY_TIMEOUT:-300}" ]]; then
        return 0
    fi

    return 1
}

# --- Stop Signal Detection ---

# Check if a file contains a <Stop> signal on its own line
# Args: $1 = task directory, $2 = filename
# Returns: 0 if <Stop> found, 1 if not
detect_stop() {
    local task_dir="$1"
    local latest="$2"
    local filepath="$task_dir/$latest"

    grep -qP '^\s*<Stop>\s*$' "$filepath" 2>/dev/null
}
