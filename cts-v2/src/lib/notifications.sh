#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Notification Library
# ============================================================================
# Provides notification functions using the ntfy.sh service for sending
# alerts from any component in the system.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/notifications.sh"
#
#   notify "Task Complete" "Your task has finished"
#   notify_priority "ERROR" "Something critical happened"
#   notify_with_link "Result" "View results" "https://example.com"
#
# Configuration (from config.sh):
#   NTFY_SERVER -- ntfy server URL (default: https://ntfy.sh)
#   NTFY_TOPIC  -- notification topic name
#
# Dependencies:
#   - config.sh must be sourced first (provides NTFY_SERVER, NTFY_TOPIC)
#   - logging.sh should be sourced first (provides log for failure warnings)
#   - curl must be available
# ============================================================================

# --- Private Helpers ---

# Validate that NTFY_SERVER and NTFY_TOPIC are set
_notify_validate_config() {
    if [[ -z "${NTFY_SERVER:-}" ]]; then
        log ERROR "NTFY_SERVER is not set"
        return 1
    fi
    if [[ -z "${NTFY_TOPIC:-}" ]]; then
        log ERROR "NTFY_TOPIC is not set"
        return 1
    fi
    return 0
}

# Send a notification via ntfy
# Args: $1 = title, $2 = message, $3... = extra curl headers
_notify_send() {
    local title="$1"
    local message="$2"
    shift 2

    _notify_validate_config || return 1

    local -a curl_args=()
    curl_args+=(-sf)
    curl_args+=(-H "Title: $title")

    # Add any extra headers
    while [[ $# -gt 0 ]]; do
        curl_args+=(-H "$1")
        shift
    done

    curl_args+=(-d "$message")
    curl_args+=("${NTFY_SERVER}/${NTFY_TOPIC}")

    curl "${curl_args[@]}" >/dev/null 2>&1 || {
        log WARN "Failed to send notification: $title"
        return 1
    }

    return 0
}

# --- Public API ---

# notify <title> <message>
# Sends a standard notification via ntfy.
# Returns 0 on success, 1 on failure. Never crashes the caller.
notify() {
    local title="$1"
    local message="$2"
    _notify_send "$title" "$message"
}

# notify_priority <title> <message>
# Sends a high-priority notification with urgent tag.
# Returns 0 on success, 1 on failure. Never crashes the caller.
notify_priority() {
    local title="$1"
    local message="$2"
    _notify_send "$title" "$message" "Priority: urgent"
}

# notify_with_link <title> <message> <url>
# Sends a notification with a clickable link action.
# Returns 0 on success, 1 on failure. Never crashes the caller.
notify_with_link() {
    local title="$1"
    local message="$2"
    local url="$3"
    _notify_send "$title" "$message" "Click: $url"
}
