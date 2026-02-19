#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Heartbeat Tier 3 (Daily Situation Report)
# ============================================================================
# Generates a daily situation report summarizing task activity, LLM usage,
# and system health. Runs once daily via systemd timer.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/logging.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/notifications.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/tier3.sh"
#
#   tier3_init
#   tier3_run
#
# Output:
#   - Markdown report at STATE_DIR/reports/daily/YYYY-MM-DD.md
#   - ntfy notification with summary
#
# Dependencies:
#   - config.sh (for STATE_DIR, VAULT_TASKS_DIR, LOG_DIR)
#   - lib/logging.sh (for log() function)
#   - lib/notifications.sh (for notify() function)
# ============================================================================

set -euo pipefail

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

_tier3_get_reports_dir() {
    echo "${STATE_DIR}/reports/daily"
}

_tier3_ensure_dir() {
    mkdir -p "$(_tier3_get_reports_dir)" 2>/dev/null || true
}

# Count task directories
_tier3_count_tasks() {
    local count=0
    if [[ -d "$VAULT_TASKS_DIR" ]]; then
        for task_dir in "${VAULT_TASKS_DIR}"/*/; do
            [[ -d "$task_dir" ]] || continue
            local name
            name="$(basename "$task_dir")"
            [[ "$name" == "project-index.md" ]] && continue
            [[ "$name" == "CLAUDE.md" ]] && continue
            count=$((count + 1))
        done
    fi
    echo "$count"
}

# Count tasks active in last 24 hours
_tier3_count_active_tasks() {
    local count=0
    local cutoff
    cutoff=$(( $(date +%s) - 86400 ))

    if [[ -d "$VAULT_TASKS_DIR" ]]; then
        for task_dir in "${VAULT_TASKS_DIR}"/*/; do
            [[ -d "$task_dir" ]] || continue
            for md_file in "$task_dir"/*.md; do
                [[ -f "$md_file" ]] || continue
                [[ "$(basename "$md_file")" == "_status.md" ]] && continue
                local mtime
                mtime="$(stat -c %Y "$md_file" 2>/dev/null || echo 0)"
                if [[ "$mtime" -gt "$cutoff" ]]; then
                    count=$((count + 1))
                    break
                fi
            done
        done
    fi
    echo "$count"
}

# Get daily usage stats
_tier3_get_usage_summary() {
    local today
    today="$(date '+%Y-%m-%d')"
    local usage_file="${STATE_DIR}/usage/${today}.json"

    if [[ -f "$usage_file" ]] && command -v jq >/dev/null 2>&1; then
        local total_turns total_invocations
        total_turns="$(jq -r '.total_turns // 0' "$usage_file" 2>/dev/null || echo 0)"
        total_invocations="$(jq -r '.total_invocations // 0' "$usage_file" 2>/dev/null || echo 0)"
        echo "- Invocations: $total_invocations"
        echo "- Turns used: $total_turns"

        # Per-LLM breakdown
        for llm in "${LLM_NAMES[@]:-}"; do
            [[ -z "$llm" ]] && continue
            local llm_turns
            llm_turns="$(jq -r ".llm_turns.${llm} // 0" "$usage_file" 2>/dev/null || echo 0)"
            if [[ "$llm_turns" -gt 0 ]]; then
                echo "- ${llm} turns: $llm_turns"
            fi
        done
    else
        echo "- No usage data available for today"
    fi
}

# Get audit journal stats for today
_tier3_get_audit_summary() {
    local journal="${STATE_DIR}/journal.log"
    local today
    today="$(date '+%Y-%m-%d')"

    if [[ ! -f "$journal" ]]; then
        echo "- No audit journal found"
        return
    fi

    local start_count end_count
    start_count="$(grep -c "^${today}.*START" "$journal" 2>/dev/null || echo 0)"
    end_count="$(grep -c "^${today}.*END" "$journal" 2>/dev/null || echo 0)"
    local incomplete=$(( start_count - end_count ))
    [[ "$incomplete" -lt 0 ]] && incomplete=0

    echo "- Started: $start_count"
    echo "- Completed: $end_count"
    if [[ "$incomplete" -gt 0 ]]; then
        echo "- Incomplete: $incomplete"
    fi
}

# Check disk space on key directories
_tier3_get_disk_info() {
    local vault_disk
    vault_disk="$(df -BM "$VAULT_TASKS_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")"
    local state_disk
    state_disk="$(df -BM "$STATE_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")"

    echo "- Vault directory free: $vault_disk"
    echo "- State directory free: $state_disk"
}

# Generate the full report
_tier3_generate_report() {
    local today
    today="$(date '+%Y-%m-%d')"
    local now
    now="$(date '+%Y-%m-%d %H:%M:%S')"

    local total_tasks active_tasks
    total_tasks="$(_tier3_count_tasks)"
    active_tasks="$(_tier3_count_active_tasks)"

    cat <<EOF
# Daily Situation Report — ${today}

Generated: ${now}

## Task Summary
- Total task directories: ${total_tasks}
- Active in last 24h: ${active_tasks}

## LLM Usage (Today)
$(_tier3_get_usage_summary)

## Audit Trail (Today)
$(_tier3_get_audit_summary)

## Disk Space
$(_tier3_get_disk_info)

## System Status
- Supervisor: $(pgrep -f 'supervisor.sh' >/dev/null 2>&1 && echo "running" || echo "not running")
- State directory: $(test -d "$STATE_DIR" && echo "exists" || echo "missing")
- Log directory: $(test -d "$LOG_DIR" && echo "exists" || echo "missing")
EOF
}

# ============================================================================
# PUBLIC API
# ============================================================================

tier3_init() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before tier3.sh." >&2
        return 1
    fi

    _tier3_ensure_dir
    log DEBUG "Heartbeat Tier 3 initialized"
    return 0
}

tier3_run() {
    if [[ -z "${STATE_DIR:-}" ]]; then
        echo "Error: STATE_DIR not set. Source config.sh before tier3.sh." >&2
        return 1
    fi

    log INFO "Starting Tier 3 daily situation report"

    local today
    today="$(date '+%Y-%m-%d')"
    local reports_dir
    reports_dir="$(_tier3_get_reports_dir)"
    local report_file="${reports_dir}/${today}.md"

    # Generate report
    _tier3_generate_report > "$report_file"
    log INFO "Daily report written to $report_file"

    # Send notification summary
    local total_tasks active_tasks
    total_tasks="$(_tier3_count_tasks)"
    active_tasks="$(_tier3_count_active_tasks)"

    if declare -f notify >/dev/null 2>&1; then
        notify "Daily Report: ${today}" "${active_tasks} active tasks of ${total_tasks} total. Report: ${report_file}" 2>/dev/null || true
    fi

    # Update last run timestamp
    date -Iseconds > "${STATE_DIR}/heartbeat/tier3-last-run.txt" 2>/dev/null || true

    log INFO "Tier 3 daily report completed"
    return 0
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    source "${SCRIPT_DIR}/config.sh"
    source "${SCRIPT_DIR}/lib/logging.sh"

    if [[ -f "${SCRIPT_DIR}/lib/notifications.sh" ]]; then
        source "${SCRIPT_DIR}/lib/notifications.sh"
    fi

    tier3_init || exit 1
    tier3_run || exit 1

    exit 0
fi
