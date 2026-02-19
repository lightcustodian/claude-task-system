#!/usr/bin/env bash
# ============================================================================
# Ralph Pro Health Checker
# Lightweight, runs every 5 minutes via systemd timer.
# Detects problems and writes fix requests — never fixes anything itself.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-monitor.sh"

main() {
    init_state
    increment_state "check_count"
    local check_count
    check_count=$(get_state "check_count")

    log INFO "========== Health Check #${check_count} =========="

    # 1. Gather structured report
    local report
    report=$(gather_report)
    log INFO "Report: $(echo "$report" | jq -c .)"
    log_event "healthcheck" "$(echo "$report" | jq -c .)"

    # 2. Classify error
    local error_class
    error_class=$(classify_error "$report")
    log INFO "Classification: $error_class"

    # 3. Update dashboard
    update_dashboard "$report" "$error_class"

    # 4. Track progress changes
    local completed_count
    completed_count=$(echo "$report" | jq -r '.completed_count')
    local prev_completed
    prev_completed=$(get_state "total_stories_completed")
    prev_completed=${prev_completed:-0}
    if [[ "$completed_count" -gt "$prev_completed" ]]; then
        local newly=$((completed_count - prev_completed))
        update_state "total_stories_completed" "$completed_count"
        notify_structured "info" "Ralph Pro Progress" "${newly} new story(ies) completed. Total: ${completed_count}/36"
    fi

    # 5. If unhealthy, write a fix request
    if [[ "$error_class" != "healthy" && "$error_class" != "completed" ]]; then
        local consecutive
        consecutive=$(get_state "consecutive_failures")
        consecutive=${consecutive:-0}
        update_state "consecutive_failures" "$((consecutive + 1))"

        # Write atomically via temp file + mv to prevent partial reads by fixer
        local request_tmp="$FIX_REQUEST_DIR/.fix-$(date +%s)-$$.tmp"
        local request_file="$FIX_REQUEST_DIR/fix-$(date +%s).json"
        jq -n \
            --arg ec "$error_class" \
            --arg ts "$(date -Iseconds)" \
            --argjson report "$report" \
            --argjson cf "$((consecutive + 1))" \
            '{
                error_class: $ec,
                timestamp: $ts,
                consecutive_failures: $cf,
                report: $report
            }' > "$request_tmp" && mv "$request_tmp" "$request_file"

        log INFO "Fix request written: $request_file (class: $error_class)"

        # Escalate notification based on consecutive failures
        if [[ "$((consecutive + 1))" -ge 3 ]]; then
            notify_structured "error" "Ralph Pro: ${error_class}" "Consecutive failure #$((consecutive + 1)). Fix request queued."
        else
            notify_structured "warning" "Ralph Pro: ${error_class}" "Fix request queued."
        fi
    else
        update_state "consecutive_failures" "0"
        if [[ "$error_class" == "completed" ]]; then
            local already_notified
            already_notified=$(get_state "completion_notified")
            if [[ "$already_notified" != "true" ]]; then
                local cc fc
                cc=$(echo "$report" | jq -r '.completed_count')
                fc=$(echo "$report" | jq -r '.failed_count')
                notify_structured "info" "Ralph Pro COMPLETE" "${cc}/36 stories completed, ${fc} failed"
                update_state "completion_notified" "true"
            fi
        fi
    fi

    log INFO "========== Health Check #${check_count} complete =========="
}

# Entry point
case "${1:-check}" in
    check)
        main
        ;;
    status)
        if [[ -f "$DASHBOARD_FILE" ]]; then
            jq . "$DASHBOARD_FILE"
        else
            echo "No dashboard data yet."
        fi
        ;;
    *)
        echo "Usage: $0 {check|status}"
        exit 1
        ;;
esac
