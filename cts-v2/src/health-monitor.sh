#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Health Monitor
# ============================================================================
# System health checks that run every 2 minutes via systemd timer.
# Pure bash implementation — no LLM invocations.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/notifications.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/health-monitor.sh"
#
#   health_monitor_init
#   health_monitor_run
#
# Checks:
#   - Supervisor process running
#   - Disk space on Google Drive mount
#   - rclone-gdrive.service status
#   - State directories writable
#
# Output:
#   - STATE_DIR/health-state.json — current health state
#   - Priority ntfy notification on critical issues
#
# Dependencies:
#   - config.sh (for STATE_DIR, VAULT_TASKS_DIR)
#   - lib/logging.sh (for log())
#   - lib/notifications.sh (for notify_priority())
# ============================================================================

set -euo pipefail

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

# Check if supervisor process is running
_health_check_supervisor() {
    if pgrep -f 'supervisor.sh' >/dev/null 2>&1; then
        echo "running"
    else
        echo "not_running"
    fi
}

# Check disk space (returns MB free)
_health_check_disk() {
    local path="$1"
    if [[ -d "$path" ]]; then
        df -BM "$path" 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}' || echo "0"
    else
        echo "0"
    fi
}

# Check if rclone-gdrive.service is active
_health_check_rclone() {
    if systemctl --user is-active rclone-gdrive.service >/dev/null 2>&1; then
        echo "active"
    else
        echo "inactive"
    fi
}

# Check if a directory is writable
_health_check_writable() {
    local path="$1"
    if [[ -d "$path" ]] && [[ -w "$path" ]]; then
        echo "writable"
    else
        echo "not_writable"
    fi
}

# Check if Google Drive mount is accessible
_health_check_gdrive_mount() {
    if [[ -d "$VAULT_TASKS_DIR" ]] && ls "$VAULT_TASKS_DIR" >/dev/null 2>&1; then
        echo "accessible"
    else
        echo "not_accessible"
    fi
}

# ============================================================================
# PUBLIC API
# ============================================================================

health_monitor_init() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh first." >&2
        return 1
    fi

    log DEBUG "Health monitor initialized"
    return 0
}

health_monitor_run() {
    log INFO "Running health checks"

    local supervisor_status rclone_status gdrive_status state_writable
    local vault_disk_mb state_disk_mb

    supervisor_status="$(_health_check_supervisor)"
    rclone_status="$(_health_check_rclone)"
    gdrive_status="$(_health_check_gdrive_mount)"
    state_writable="$(_health_check_writable "$STATE_DIR")"
    vault_disk_mb="$(_health_check_disk "$VAULT_TASKS_DIR")"
    state_disk_mb="$(_health_check_disk "$STATE_DIR")"

    local timestamp
    timestamp="$(date -Iseconds)"

    # Write health state JSON
    local health_file="${STATE_DIR}/health-state.json"
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg ts "$timestamp" \
            --arg sup "$supervisor_status" \
            --arg rcl "$rclone_status" \
            --arg gdrive "$gdrive_status" \
            --arg sw "$state_writable" \
            --argjson vdisk "${vault_disk_mb:-0}" \
            --argjson sdisk "${state_disk_mb:-0}" \
            '{
                timestamp: $ts,
                supervisor: $sup,
                rclone: $rcl,
                gdrive_mount: $gdrive,
                state_writable: $sw,
                vault_disk_free_mb: $vdisk,
                state_disk_free_mb: $sdisk
            }' > "$health_file" 2>/dev/null || true
    fi

    log INFO "Health: supervisor=$supervisor_status rclone=$rclone_status gdrive=$gdrive_status state=$state_writable vault_disk=${vault_disk_mb}MB state_disk=${state_disk_mb}MB"

    # Check for critical issues and alert
    local critical_issues=()

    if [[ "$supervisor_status" != "running" ]]; then
        critical_issues+=("Supervisor is not running")
    fi

    if [[ "$gdrive_status" != "accessible" ]]; then
        critical_issues+=("Google Drive mount not accessible")
    fi

    if [[ "$rclone_status" != "active" ]]; then
        critical_issues+=("rclone-gdrive.service is not active")
    fi

    if [[ "$state_writable" != "writable" ]]; then
        critical_issues+=("State directory is not writable")
    fi

    # Disk space warnings (< 500MB)
    if [[ "${vault_disk_mb:-0}" -lt 500 ]]; then
        critical_issues+=("Vault disk space low: ${vault_disk_mb}MB free")
    fi

    if [[ "${state_disk_mb:-0}" -lt 500 ]]; then
        critical_issues+=("State disk space low: ${state_disk_mb}MB free")
    fi

    # Send alert if critical issues found
    if [[ ${#critical_issues[@]} -gt 0 ]]; then
        local issue_text=""
        for issue in "${critical_issues[@]}"; do
            issue_text="${issue_text}- ${issue}\n"
            log ERROR "CRITICAL: $issue"
        done

        if declare -f notify_priority >/dev/null 2>&1; then
            notify_priority "Health Alert" "$(printf '%b' "$issue_text")" 2>/dev/null || true
        fi
    else
        log INFO "All health checks passed"
    fi

    return 0
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    source "${SCRIPT_DIR}/config.sh"
    source "${SCRIPT_DIR}/lib/logging.sh"

    if [[ -f "${SCRIPT_DIR}/lib/notifications.sh" ]]; then
        source "${SCRIPT_DIR}/lib/notifications.sh"
    fi

    health_monitor_init || exit 1
    health_monitor_run || exit 1

    exit 0
fi
