#!/usr/bin/env bash
# monitoring-checks.sh — Three gap checks: log size, disk trend, response validation
# Can run standalone or be sourced by healthcheck/monitor scripts
set -uo pipefail

STATE_DIR="${HOME}/.claude-task-system"
LOG_DIR="${STATE_DIR}/shared/logs"
TASK_DIR="${HOME}/GoogleDrive/DriveSyncFiles/claude-tasks"
DISK_TREND_FILE="${STATE_DIR}/shared/disk-trend.json"
NTFY_TOPIC="johnlane-claude-tasks"

LOG_SIZE_THRESHOLD_MB=1024  # 1GB
DISK_DECREASE_THRESHOLD=10  # 10% decrease in 24h

notify() {
    local priority="$1" title="$2" body="$3"
    curl -s -o /dev/null \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -d "$body" \
        "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
}

# Check 1: Log directory size alert at 1GB
check_log_size() {
    local log_size_kb
    log_size_kb=$(du -s "$LOG_DIR" 2>/dev/null | cut -f1) || log_size_kb=0
    local log_size_mb=$((log_size_kb / 1024))

    if [[ $log_size_mb -ge $LOG_SIZE_THRESHOLD_MB ]]; then
        echo "[WARN] Log directory is ${log_size_mb}MB (threshold: ${LOG_SIZE_THRESHOLD_MB}MB)"
        notify "high" "CTS: Log directory large" "Log dir is ${log_size_mb}MB, exceeds ${LOG_SIZE_THRESHOLD_MB}MB threshold. Consider cleanup."
        return 1
    else
        echo "[OK] Log directory: ${log_size_mb}MB (threshold: ${LOG_SIZE_THRESHOLD_MB}MB)"
        return 0
    fi
}

# Check 2: Disk trend alert if free space decreased >10% in 24h
check_disk_trend() {
    local current_free_kb
    current_free_kb=$(df /home --output=avail | tail -1 | xargs)
    local current_time
    current_time=$(date +%s)

    # Read previous measurement
    local prev_free_kb=0 prev_time=0
    if [[ -f "$DISK_TREND_FILE" ]]; then
        prev_free_kb=$(python3 -c "import json; d=json.load(open('$DISK_TREND_FILE')); print(d.get('free_kb', 0))" 2>/dev/null) || prev_free_kb=0
        prev_time=$(python3 -c "import json; d=json.load(open('$DISK_TREND_FILE')); print(d.get('timestamp', 0))" 2>/dev/null) || prev_time=0
    fi

    # Save current measurement
    cat > "$DISK_TREND_FILE" <<EOF
{"free_kb": $current_free_kb, "timestamp": $current_time}
EOF

    # Only alert if previous measurement exists and is within 24-48h
    if [[ $prev_free_kb -gt 0 && $prev_time -gt 0 ]]; then
        local elapsed=$(( current_time - prev_time ))
        local min_elapsed=43200   # 12 hours
        local max_elapsed=172800  # 48 hours

        if [[ $elapsed -ge $min_elapsed && $elapsed -le $max_elapsed ]]; then
            if [[ $prev_free_kb -gt 0 ]]; then
                local decrease=$(( prev_free_kb - current_free_kb ))
                local pct_decrease=$(( (decrease * 100) / prev_free_kb ))

                if [[ $pct_decrease -ge $DISK_DECREASE_THRESHOLD ]]; then
                    local current_free_gb=$(( current_free_kb / 1048576 ))
                    local decrease_gb=$(( decrease / 1048576 ))
                    echo "[WARN] Disk free decreased ${pct_decrease}% in $(( elapsed / 3600 ))h (lost ${decrease_gb}GB, now ${current_free_gb}GB free)"
                    notify "high" "CTS: Disk space decreasing" "Free space dropped ${pct_decrease}% (${decrease_gb}GB) in $(( elapsed / 3600 ))h. Currently ${current_free_gb}GB free."
                    return 1
                else
                    local current_free_gb=$(( current_free_kb / 1048576 ))
                    echo "[OK] Disk trend: ${pct_decrease}% change in $(( elapsed / 3600 ))h (${current_free_gb}GB free)"
                    return 0
                fi
            fi
        else
            echo "[OK] Disk trend: measurement too old/new (${elapsed}s elapsed), baseline recorded"
            return 0
        fi
    else
        echo "[OK] Disk trend: first measurement recorded (${current_free_kb}KB free)"
        return 0
    fi
}

# Check 3: Task output validation — verify response files contain expected marker
check_response_validity() {
    local invalid_count=0
    local checked_count=0
    local invalid_files=""

    # Check the 10 most recent response files (even-numbered files are Claude responses)
    while IFS= read -r -d '' file; do
        checked_count=$((checked_count + 1))
        local basename
        basename=$(basename "$file")
        local filenum
        filenum=$(echo "$basename" | grep -oP '^\d+' || echo "0")

        # Only check even-numbered files (Claude responses) that are non-empty
        if [[ $((filenum % 2)) -eq 0 && -s "$file" ]]; then
            # Check for the CLAUDE-RESPONSE marker OR reasonable response content (>100 chars)
            local has_marker has_content
            has_marker=$(grep -c 'CLAUDE-RESPONSE\|<!-- CLAUDE\|^---$' "$file" 2>/dev/null) || has_marker=0
            has_content=$(wc -c < "$file" 2>/dev/null) || has_content=0

            if [[ $has_marker -eq 0 && $has_content -lt 100 ]]; then
                invalid_count=$((invalid_count + 1))
                invalid_files="${invalid_files}\n  - ${file}"
            fi
        fi
    done < <(find "$TASK_DIR" -name "*.md" -newer "$TASK_DIR" -mmin -1440 -print0 2>/dev/null | sort -z)

    if [[ $invalid_count -gt 0 ]]; then
        echo "[WARN] Found $invalid_count potentially invalid response files (of $checked_count checked):${invalid_files}"
        notify "default" "CTS: Invalid response files" "Found $invalid_count response files that may be incomplete or malformed."
        return 1
    else
        echo "[OK] Response validation: $checked_count files checked, all valid"
        return 0
    fi
}

# Main
if [[ "${1:-}" == "--quiet" ]]; then
    # Quiet mode: only output warnings
    check_log_size 2>/dev/null | grep -v '^\[OK\]' || true
    check_disk_trend 2>/dev/null | grep -v '^\[OK\]' || true
    check_response_validity 2>/dev/null | grep -v '^\[OK\]' || true
else
    echo "=== CTS Monitoring Checks ($(date '+%Y-%m-%d %H:%M:%S')) ==="
    echo ""
    check_log_size || true
    check_disk_trend || true
    check_response_validity || true
    echo ""
    echo "Done."
fi
