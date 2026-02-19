#!/usr/bin/env bash
# ============================================================================
# Ralph Pro Daily Digest
# Sends a summary notification at 08:00 UTC
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-monitor.sh"

main() {
    local report
    report=$(gather_report)

    local status completed failed current_story current_phase orch_running disk_free
    status=$(echo "$report" | jq -r '.task_status')
    completed=$(echo "$report" | jq -r '.completed_count')
    failed=$(echo "$report" | jq -r '.failed_count')
    current_story=$(echo "$report" | jq -r '.current_story')
    current_phase=$(echo "$report" | jq -r '.current_phase')
    orch_running=$(echo "$report" | jq -r '.orchestrator_running')
    disk_free=$(echo "$report" | jq -r '.env_disk_free_mb')

    local check_count claude_interventions
    check_count=$(get_state "check_count" 2>/dev/null || echo 0)
    claude_interventions=$(get_state "claude_interventions" 2>/dev/null || echo 0)

    # Count events from last 24h using jq to properly extract timestamps
    local events_24h fixes_24h
    local yesterday
    yesterday=$(date -d '24 hours ago' -Iseconds 2>/dev/null || date -Iseconds)
    if [[ -f "$JSON_LOG" ]]; then
        events_24h=$(jq -r --arg ts "$yesterday" 'select(.timestamp > $ts) | .timestamp' "$JSON_LOG" 2>/dev/null | wc -l || echo 0)
        fixes_24h=$(jq -r --arg ts "$yesterday" 'select(.timestamp > $ts and .event == "fix_applied") | .timestamp' "$JSON_LOG" 2>/dev/null | wc -l || echo 0)
    else
        events_24h=0
        fixes_24h=0
    fi

    local running_icon="stopped"
    [[ "$orch_running" == "true" ]] && running_icon="running"

    local message
    message=$(cat <<EOF
Daily Ralph Pro Summary ($(date '+%Y-%m-%d'))

Status: ${status} (orchestrator ${running_icon})
Progress: ${completed}/36 completed, ${failed} failed
Current: ${current_story} / ${current_phase}
Disk: ${disk_free}MB free
Health checks (24h): ${events_24h}
Fixes applied (24h): ${fixes_24h}
Claude interventions (total): ${claude_interventions}
EOF
)

    notify_structured "info" "Ralph Pro Daily Digest" "$message"
    log INFO "Daily digest sent"
    log_event "daily_digest" "$(echo "$report" | jq -c .)"
}

main
