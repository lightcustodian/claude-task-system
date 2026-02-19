#!/usr/bin/env bash
# ============================================================================
# Ralph Pro Overnight Monitor v2
# Architecture: detect → classify → decide → dispatch → verify
#
# Components:
#   1. Structured data gathering (bash-only)
#   2. Error classification engine (bash-only)
#   3. Decision engine (bash → dispatch to bash fix or Claude fix)
#   4. Post-fix verification
#   5. Structured JSON logging + health dashboard
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_PRO_URL="http://localhost:3000"
PROJECT_ID="proj-1771322660094"
TASK_ID="task-1771322680412"
PROJECT_PATH="/home/johnlane/projects/openclaw-alternative"
LOG_FILE="$HOME/.claude-task-system/logs/overnight-monitor.log"
JSON_LOG="$HOME/.claude-task-system/logs/overnight-monitor-events.jsonl"
STATE_FILE="$HOME/.claude-task-system/overnight-monitor-state.json"
DASHBOARD_FILE="$HOME/.claude-task-system/monitor-status.json"
NTFY_TOPIC="johnlane-claude-tasks"
NTFY_SERVER="https://ntfy.sh"
MAX_CONSECUTIVE_FAILURES=3
CLAUDE_MAX_TURNS=30
PROGRESS_FILE="$SCRIPT_DIR/data/projects/${PROJECT_ID}/tasks/${TASK_ID}/progress.json"
OUTPUT_DIR="$SCRIPT_DIR/data/projects/${PROJECT_ID}/tasks/${TASK_ID}/output"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$JSON_LOG")"

# ============================================================================
# Logging
# ============================================================================
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

log_event() {
    local event_type="$1" details="$2"
    local ts
    ts="$(date -Iseconds)"
    printf '{"timestamp":"%s","event":"%s","details":%s}\n' "$ts" "$event_type" "$details" >> "$JSON_LOG"
}

# ============================================================================
# Notifications
# ============================================================================
notify() {
    local title="$1" message="$2"
    curl -sf -H "Title: $title" -d "$message" "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
    log INFO "NOTIFY: $title — $message"
}

notify_priority() {
    local title="$1" message="$2"
    curl -sf -H "Title: $title" -H "Priority: urgent" -d "$message" "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
    log WARN "NOTIFY-URGENT: $title — $message"
}

# ============================================================================
# State Management
# ============================================================================
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" <<'STATEEOF'
{
  "check_count": 0,
  "consecutive_failures": 0,
  "last_completed_story": null,
  "total_stories_completed": 0,
  "claude_interventions": 0,
  "started_at": null,
  "last_error_class": null,
  "last_fix_action": null
}
STATEEOF
        jq --arg ts "$(date -Iseconds)" '.started_at = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
}

get_state() {
    local key="$1"
    jq -r ".$key // empty" "$STATE_FILE" 2>/dev/null
}

update_state() {
    local key="$1" value="$2"
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

increment_state() {
    local key="$1"
    local current
    current=$(get_state "$key")
    current=${current:-0}
    update_state "$key" "$(( current + 1 ))"
}

# ============================================================================
# 1. STRUCTURED DATA GATHERING (bash-only)
# ============================================================================
gather_report() {
    local report="{}"

    # --- Server health ---
    local server_healthy="false"
    if curl -sf --max-time 5 "${RALPH_PRO_URL}/api/projects" >/dev/null 2>&1; then
        server_healthy="true"
    fi
    report=$(echo "$report" | jq --argjson h "$server_healthy" '.server_healthy = $h')

    # --- Progress data ---
    local progress_json="{}"
    if [[ -f "$PROGRESS_FILE" ]]; then
        progress_json=$(cat "$PROGRESS_FILE" 2>/dev/null || echo '{}')
    fi

    local status completed_count failed_count current_story current_phase
    status=$(echo "$progress_json" | jq -r '.status // "unknown"')
    completed_count=$(echo "$progress_json" | jq '[.completedStories // [] | length] | .[0]' 2>/dev/null || echo 0)
    current_story=$(echo "$progress_json" | jq -r '.currentStory // "none"')
    current_phase=$(echo "$progress_json" | jq -r '.currentPhase // "none"')

    # Count failed stories (maxed out attempts)
    local max_per_story
    max_per_story=$(echo "$progress_json" | jq -r '.executionConfig.maxPerStory // 5')
    failed_count=$(echo "$progress_json" | jq --argjson max "$max_per_story" '
        [.failedAttempts // {} | to_entries[] | select((.value | length) >= $max)] | length
    ' 2>/dev/null || echo 0)

    report=$(echo "$report" | jq \
        --arg s "$status" \
        --argjson cc "$completed_count" \
        --argjson fc "$failed_count" \
        --arg cs "$current_story" \
        --arg cp "$current_phase" \
        '.task_status = $s | .completed_count = $cc | .failed_count = $fc | .current_story = $cs | .current_phase = $cp')

    # --- Orchestrator process ---
    local orch_running="false"
    if pgrep -f "ralph-pro.js.*--task.*${TASK_ID}" >/dev/null 2>&1; then
        orch_running="true"
    fi
    report=$(echo "$report" | jq --argjson r "$orch_running" '.orchestrator_running = $r')

    # --- Environment health ---
    local cwd_exists="false"
    [[ -d "$PROJECT_PATH" ]] && cwd_exists="true"
    local sh_exists="false"
    [[ -x "/bin/sh" ]] && sh_exists="true"
    local disk_free
    disk_free=$(df -BM --output=avail /home 2>/dev/null | tail -1 | tr -d ' M')
    local proc_count
    proc_count=$(ps aux 2>/dev/null | wc -l)

    report=$(echo "$report" | jq \
        --argjson cwd "$cwd_exists" \
        --argjson sh "$sh_exists" \
        --argjson df "${disk_free:-0}" \
        --argjson pc "${proc_count:-0}" \
        '.env_cwd_exists = $cwd | .env_sh_exists = $sh | .env_disk_free_mb = $df | .env_process_count = $pc')

    # --- Recent error analysis ---
    local last_error="none"
    local last_error_story="none"
    if [[ "$failed_count" -gt 0 ]]; then
        # Get the most recent failure's output file
        last_error_story=$(echo "$progress_json" | jq -r --argjson max "$max_per_story" '
            [.failedAttempts // {} | to_entries[] | select((.value | length) >= $max)] | last | .key // "none"
        ')
        if [[ "$last_error_story" != "none" ]]; then
            local last_attempt
            last_attempt=$(echo "$progress_json" | jq --arg s "$last_error_story" '[.failedAttempts[$s] | length] | .[0] // 0')
            local error_file="$OUTPUT_DIR/${last_error_story}_attempt${last_attempt}_DESIGN_output.txt"
            if [[ -f "$error_file" ]]; then
                last_error=$(head -5 "$error_file" 2>/dev/null | tr '\n' ' ' | cut -c1-200)
            fi
        fi
    fi
    report=$(echo "$report" | jq \
        --arg le "$last_error" \
        --arg les "$last_error_story" \
        '.last_error = $le | .last_error_story = $les')

    # --- Filesystem snapshot diff ---
    local snapshot_changes="none"
    if [[ -x "$HOME/.claude-task-system/snapshot-dirs.sh" ]]; then
        local snap
        snap=$("$HOME/.claude-task-system/snapshot-dirs.sh" "monitor-check" 2>/dev/null || echo "")
        # Compare with previous snapshot if exists
        local prev_snap="$HOME/.claude-task-system/snapshots/last-monitor-snapshot.txt"
        if [[ -f "$prev_snap" && -f "$snap" ]]; then
            local changes
            changes=$(diff "$prev_snap" "$snap" 2>/dev/null | head -20 || true)
            if [[ -n "$changes" ]]; then
                snapshot_changes="$changes"
            fi
        fi
        [[ -f "$snap" ]] && cp "$snap" "$prev_snap" 2>/dev/null || true
    fi
    report=$(echo "$report" | jq --arg sc "$snapshot_changes" '.snapshot_changes = $sc')

    echo "$report"
}

# ============================================================================
# 2. ERROR CLASSIFICATION ENGINE (bash-only)
# ============================================================================
# Returns one of:
#   healthy          — everything is fine
#   completed        — task finished
#   server_down      — Ralph Pro server not responding
#   env_cwd_missing  — working directory deleted
#   env_sh_missing   — /bin/sh not found
#   env_disk_full    — disk space < 100MB
#   stale_running    — status=running but no process
#   task_failed      — task status is failed/error
#   task_pending     — task is pending (needs restart)
#   stories_maxed    — stories hit max retries (needs diagnosis)
#   circuit_breaker  — Ralph Pro circuit breaker tripped
#   unknown          — unclassifiable
classify_error() {
    local report="$1"

    local server_healthy task_status orch_running cwd_exists sh_exists disk_free failed_count last_error
    server_healthy=$(echo "$report" | jq -r '.server_healthy')
    task_status=$(echo "$report" | jq -r '.task_status')
    orch_running=$(echo "$report" | jq -r '.orchestrator_running')
    cwd_exists=$(echo "$report" | jq -r '.env_cwd_exists')
    sh_exists=$(echo "$report" | jq -r '.env_sh_exists')
    disk_free=$(echo "$report" | jq -r '.env_disk_free_mb')
    failed_count=$(echo "$report" | jq -r '.failed_count')
    last_error=$(echo "$report" | jq -r '.last_error')

    # Priority order: environmental > server > task state > story-level
    [[ "$server_healthy" == "false" ]] && echo "server_down" && return
    [[ "$cwd_exists" == "false" ]] && echo "env_cwd_missing" && return
    [[ "$sh_exists" == "false" ]] && echo "env_sh_missing" && return
    [[ "$disk_free" -lt 100 ]] 2>/dev/null && echo "env_disk_full" && return

    case "$task_status" in
        completed) echo "completed"; return ;;
        failed|error)
            if echo "$last_error" | grep -qi "circuit.breaker"; then
                echo "circuit_breaker"
            else
                echo "task_failed"
            fi
            return ;;
        pending) echo "task_pending"; return ;;
        running)
            if [[ "$orch_running" == "false" ]]; then
                echo "stale_running"; return
            fi
            ;;
    esac

    [[ "$failed_count" -gt 0 ]] && echo "stories_maxed" && return

    [[ "$task_status" == "running" && "$orch_running" == "true" ]] && echo "healthy" && return

    echo "unknown"
}

# ============================================================================
# 3. DECISION ENGINE — dispatch to appropriate fixer
# ============================================================================
dispatch_fix() {
    local error_class="$1"
    local report="$2"

    log INFO "[DECISION] Error class: $error_class"
    log_event "decision" "$(printf '{"error_class":"%s"}' "$error_class")"
    update_state "last_error_class" "\"$error_class\""

    case "$error_class" in
        healthy)
            log INFO "System healthy. No action needed."
            update_state "consecutive_failures" "0"
            return 0
            ;;
        completed)
            local cc
            cc=$(echo "$report" | jq -r '.completed_count')
            local fc
            fc=$(echo "$report" | jq -r '.failed_count')
            notify "Ralph Pro COMPLETE" "${cc}/36 stories completed, ${fc} failed"
            if [[ "$fc" -gt 0 ]]; then
                log WARN "Task completed with $fc failed stories — invoking Claude for analysis"
                invoke_claude_narrow "post_mortem" "Task completed but $fc stories failed. Analyze failures and report."
            fi
            return 0
            ;;
        server_down)
            log ERROR "Server down — restarting"
            bash_fix_server_restart
            ;;
        env_cwd_missing)
            log ERROR "Working directory missing — recreating"
            bash_fix_recreate_cwd
            ;;
        env_sh_missing)
            log ERROR "/bin/sh missing — critical system error"
            notify_priority "CRITICAL" "/bin/sh not found. System may be compromised."
            return 1
            ;;
        env_disk_full)
            log ERROR "Disk nearly full — cleaning up"
            bash_fix_disk_cleanup
            ;;
        stale_running)
            log WARN "Stale running state — restarting task"
            bash_fix_restart_task
            ;;
        task_failed)
            log ERROR "Task failed — analyzing"
            bash_fix_analyze_and_restart
            ;;
        task_pending)
            log WARN "Task pending — starting"
            bash_fix_restart_task
            ;;
        circuit_breaker)
            log ERROR "Circuit breaker tripped — deep diagnosis needed"
            invoke_claude_narrow "circuit_breaker" "Ralph Pro circuit breaker tripped after consecutive environmental failures. Diagnose root cause."
            ;;
        stories_maxed)
            log WARN "Stories maxed out — analyzing failures"
            bash_fix_analyze_and_restart
            ;;
        unknown)
            log WARN "Unknown error class — invoking Claude for diagnosis"
            invoke_claude_narrow "unknown_error" "Monitor cannot classify the current state. Report: $(echo "$report" | jq -c .)"
            ;;
    esac
}

# ============================================================================
# 4. BASH FIX FUNCTIONS (no Claude needed)
# ============================================================================
bash_fix_server_restart() {
    update_state "last_fix_action" '"server_restart"'
    sudo systemctl restart ralph-pro 2>/dev/null || {
        # Try starting the node server directly
        cd "$SCRIPT_DIR" && nohup node server/index.js &>/dev/null &
        sleep 3
    }
    if curl -sf --max-time 5 "${RALPH_PRO_URL}/api/projects" >/dev/null 2>&1; then
        log INFO "Server restarted successfully"
        notify "Ralph Pro Monitor" "Server restarted successfully"
        log_event "fix_applied" '{"action":"server_restart","success":true}'
    else
        log ERROR "Server restart failed"
        notify_priority "Ralph Pro DOWN" "Server restart failed. Manual intervention needed."
        log_event "fix_applied" '{"action":"server_restart","success":false}'
    fi
}

bash_fix_recreate_cwd() {
    update_state "last_fix_action" '"recreate_cwd"'
    # The directory is protected by chattr +i, so if it's gone something very wrong happened
    if [[ -d "$PROJECT_PATH" ]]; then
        log INFO "CWD already exists (race condition?)"
        return 0
    fi
    # Try to recreate — this should work since chattr +i is on ~/projects/ not the subdirectory
    mkdir -p "$PROJECT_PATH/src/lib" "$PROJECT_PATH/src/invokers" "$PROJECT_PATH/src/heartbeat" \
             "$PROJECT_PATH/test/fixtures" "$PROJECT_PATH/systemd" "$PROJECT_PATH/docs"
    log INFO "Recreated project directory structure"

    # Restore from latest checkpoint if available
    local latest_tar
    latest_tar=$(ls -1t /home/johnlane/git-backups/checkpoints/*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$latest_tar" ]]; then
        tar xzf "$latest_tar" -C "$(dirname "$PROJECT_PATH")" 2>/dev/null && {
            log INFO "Restored from checkpoint: $latest_tar"
            notify "Ralph Pro Monitor" "CWD restored from checkpoint"
            log_event "fix_applied" '{"action":"restore_from_checkpoint","success":true}'
            return 0
        }
    fi

    # Restore from git bundle
    local latest_bundle
    latest_bundle=$(ls -1t /home/johnlane/git-backups/checkpoints/*.bundle 2>/dev/null | head -1)
    if [[ -n "$latest_bundle" ]]; then
        cd "$PROJECT_PATH"
        git init 2>/dev/null
        git bundle unbundle "$latest_bundle" 2>/dev/null && {
            git checkout master 2>/dev/null || git checkout main 2>/dev/null
            log INFO "Restored from git bundle: $latest_bundle"
            log_event "fix_applied" '{"action":"restore_from_bundle","success":true}'
            return 0
        }
    fi

    log WARN "No checkpoint or bundle available for restoration"
    notify_priority "Ralph Pro" "CWD recreated but no backup to restore from"
    log_event "fix_applied" '{"action":"recreate_cwd_empty","success":true}'
}

bash_fix_disk_cleanup() {
    update_state "last_fix_action" '"disk_cleanup"'
    # Clean old snapshots
    find "$HOME/.claude-task-system/snapshots" -name "*.txt" -mtime +3 -delete 2>/dev/null
    # Clean old logs
    find "$HOME/.claude-task-system/logs" -name "*.log" -mtime +7 -delete 2>/dev/null
    log INFO "Cleaned up old snapshots and logs"
    log_event "fix_applied" '{"action":"disk_cleanup","success":true}'
}

bash_fix_restart_task() {
    update_state "last_fix_action" '"restart_task"'

    # Kill any orphaned processes
    cleanup_orphaned_processes

    # Health check before restart
    local health_result
    health_result=$(env -u CLAUDECODE echo "HEALTHY" | claude -p --model claude-sonnet-4-5-20250929 --dangerously-skip-permissions 2>&1 | head -1) || true
    if [[ "$health_result" != *"HEALTHY"* ]]; then
        log ERROR "Backend health check FAILED before restart: $health_result"
        notify_priority "Ralph Pro" "Backend unhealthy, NOT restarting"
        log_event "fix_applied" '{"action":"restart_task","success":false,"reason":"backend_unhealthy"}'
        return 1
    fi

    local start_result
    start_result=$(curl -sf --max-time 15 -X POST "${RALPH_PRO_URL}/api/projects/${PROJECT_ID}/tasks/${TASK_ID}/start" \
        -H "Content-Type: application/json" \
        -d '{"totalAttempts": 200, "maxPerStory": 5}' 2>&1) || true

    if echo "$start_result" | jq -e '.pid' >/dev/null 2>&1; then
        notify "Ralph Pro Monitor" "Task restarted successfully"
        log INFO "Task restarted"
        log_event "fix_applied" '{"action":"restart_task","success":true}'
        update_state "consecutive_failures" "0"
    else
        log ERROR "Failed to restart task: $start_result"
        notify_priority "Ralph Pro" "Task restart failed"
        log_event "fix_applied" '{"action":"restart_task","success":false}'
    fi
}

bash_fix_analyze_and_restart() {
    update_state "last_fix_action" '"analyze_and_restart"'

    local progress
    progress=$(cat "$PROGRESS_FILE" 2>/dev/null || echo '{}')

    # Identify failure patterns
    local error_types
    error_types=$(echo "$progress" | jq -r '
        [.failedAttempts // {} | to_entries[] | .value[-1].reason // "unknown"] | group_by(.) | map({reason: .[0], count: length}) | .[]
    ' 2>/dev/null)

    log INFO "Failure analysis:"
    echo "$error_types" | while IFS= read -r line; do
        log INFO "  $line"
    done

    # Check if failures are environmental (spawn ENOENT pattern)
    local has_spawn_error="false"
    if [[ -d "$OUTPUT_DIR" ]]; then
        local sample_error
        sample_error=$(find "$OUTPUT_DIR" -name "*_DESIGN_output.txt" -size -200c -newer "$PROGRESS_FILE" 2>/dev/null | head -1)
        if [[ -n "$sample_error" ]]; then
            if grep -q "spawn /bin/sh ENOENT" "$sample_error" 2>/dev/null; then
                has_spawn_error="true"
                log ERROR "Detected spawn ENOENT errors — environmental failure"
            fi
        fi
    fi

    if [[ "$has_spawn_error" == "true" ]]; then
        # Environmental failure — check and fix environment, then reset and restart
        if [[ ! -d "$PROJECT_PATH" ]]; then
            bash_fix_recreate_cwd
        fi
        # Reset failed stories in progress
        reset_failed_stories
        bash_fix_restart_task
    else
        # Non-environmental — invoke Claude for code-level diagnosis
        local failed_stories
        failed_stories=$(echo "$progress" | jq -r '[.failedAttempts // {} | to_entries[] | select((.value | length) >= 5) | .key] | join(", ")' 2>/dev/null)
        invoke_claude_narrow "story_failures" "Stories failed verification: ${failed_stories}. Examine the VERIFY output files in ${OUTPUT_DIR} for each failed story, fix the code issues, and retry."
    fi
}

reset_failed_stories() {
    log INFO "Resetting failed stories in progress.json"
    python3 -c "
import json
with open('$PROGRESS_FILE', 'r') as f:
    p = json.load(f)
completed = set(p.get('completedStories', []))
max_per = p.get('executionConfig', {}).get('maxPerStory', 5)
reset_count = 0
for sid, attempts in list(p.get('failedAttempts', {}).items()):
    if sid not in completed and len(attempts) >= max_per:
        del p['failedAttempts'][sid]
        if sid in p.get('storyPhases', {}):
            del p['storyPhases'][sid]
        reset_count += 1
p['status'] = 'pending'
with open('$PROGRESS_FILE', 'w') as f:
    json.dump(p, f, indent=2)
print(f'Reset {reset_count} failed stories')
" 2>&1 | tee -a "$LOG_FILE"
    log_event "fix_applied" '{"action":"reset_failed_stories","success":true}'
}

cleanup_orphaned_processes() {
    local count=0
    while IFS= read -r pid; do
        if [[ -n "$pid" ]]; then
            local ppid
            ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
            if [[ "$ppid" == "1" ]]; then
                log WARN "Killing orphaned Claude process PID $pid"
                kill "$pid" 2>/dev/null || true
                ((count++)) || true
            fi
        fi
    done < <(pgrep -f "claude.*dangerously-skip-permissions" 2>/dev/null || true)
    [[ "$count" -gt 0 ]] && log INFO "Cleaned up $count orphaned process(es)"
}

# ============================================================================
# 5. CLAUDE INTERVENTION (narrow, specific mandate)
# ============================================================================
invoke_claude_narrow() {
    local mandate="$1"
    local details="$2"

    local intervention_count
    increment_state "claude_interventions"
    intervention_count=$(get_state "claude_interventions")

    # Circuit breaker for Claude interventions
    if [[ "$intervention_count" -gt 5 ]]; then
        local last_class
        last_class=$(get_state "last_error_class")
        log ERROR "Too many Claude interventions ($intervention_count). Same error class: $last_class"
        notify_priority "Ralph Pro NEEDS HELP" "Monitor has invoked Claude $intervention_count times. Manual help needed. Error: $last_class"
        return 1
    fi

    # Pre-invocation snapshot
    local pre_snap=""
    if [[ -x "$HOME/.claude-task-system/snapshot-dirs.sh" ]]; then
        pre_snap=$("$HOME/.claude-task-system/snapshot-dirs.sh" "pre-monitor-fix" 2>/dev/null || true)
    fi

    local claude_log="$HOME/.claude-task-system/logs/claude-intervention-$(date +%Y%m%d_%H%M%S).log"

    log INFO "Invoking Claude Code (mandate: $mandate, intervention #$intervention_count)"
    notify "Ralph Pro Monitor" "Claude intervention #$intervention_count: $mandate"

    local prompt
    prompt=$(cat <<PROMPTEOF
You are the Ralph Pro overnight monitor's automated repair agent.

**Mandate:** ${mandate}
**Details:** ${details}

**Environment:**
- Ralph Pro server: ${RALPH_PRO_URL}
- Project: ${PROJECT_ID} / Task: ${TASK_ID}
- Project path: ${PROJECT_PATH}
- Progress file: ${PROGRESS_FILE}
- Output dir: ${OUTPUT_DIR}

**Rules:**
1. NEVER delete ~/projects/, ~/GoogleDrive/, ~/git-backups/, or ~/ralph-pro/
2. NEVER run rm -rf on any directory outside ${PROJECT_PATH}/src/ or ${PROJECT_PATH}/test/
3. Focus ONLY on your mandate — do not explore beyond what's needed
4. After fixing, verify your fix works (run a test, check file exists, etc.)
5. Log what you did to: ${claude_log}
6. Send a notification with results: curl -H "Title: Monitor Fix: ${mandate}" -d "SUMMARY" ${NTFY_SERVER}/${NTFY_TOPIC}
7. This is intervention #${intervention_count}. Be efficient.

**To restart the task after fixing:**
curl -X POST ${RALPH_PRO_URL}/api/projects/${PROJECT_ID}/tasks/${TASK_ID}/start \\
  -H "Content-Type: application/json" \\
  -d '{"totalAttempts": 200, "maxPerStory": 5}'
PROMPTEOF
)

    local exit_code=0
    cd "$PROJECT_PATH" && env -u CLAUDECODE claude -p "$prompt" \
        --max-turns "$CLAUDE_MAX_TURNS" \
        --dangerously-skip-permissions \
        2>>"$claude_log" >> "$claude_log" || exit_code=$?

    log_event "claude_intervention" "$(printf '{"mandate":"%s","intervention":%d,"exit_code":%d}' "$mandate" "$intervention_count" "$exit_code")"

    # Post-invocation snapshot + diff
    if [[ -x "$HOME/.claude-task-system/snapshot-dirs.sh" && -n "$pre_snap" ]]; then
        local post_snap
        post_snap=$("$HOME/.claude-task-system/snapshot-dirs.sh" "post-monitor-fix" 2>/dev/null || true)
        if [[ -f "$pre_snap" && -f "$post_snap" ]]; then
            local changes
            changes=$(diff "$pre_snap" "$post_snap" 2>/dev/null || true)
            if [[ -n "$changes" ]]; then
                log WARN "Filesystem changes during Claude intervention:"
                echo "$changes" >> "$LOG_FILE"
            fi
        fi
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        log ERROR "Claude intervention failed (exit $exit_code)"
        notify_priority "Ralph Pro Monitor" "Claude intervention FAILED (exit $exit_code)"
    else
        log INFO "Claude intervention completed. Log: $claude_log"
    fi
}

# ============================================================================
# 6. HEALTH DASHBOARD
# ============================================================================
update_dashboard() {
    local report="$1"
    local error_class="$2"
    local check_count
    check_count=$(get_state "check_count")
    local claude_interventions
    claude_interventions=$(get_state "claude_interventions")
    local consecutive_failures
    consecutive_failures=$(get_state "consecutive_failures")

    jq -n \
        --arg ts "$(date -Iseconds)" \
        --argjson cc "${check_count:-0}" \
        --argjson ci "${claude_interventions:-0}" \
        --argjson cf "${consecutive_failures:-0}" \
        --arg ec "$error_class" \
        --argjson report "$report" \
        '{
            last_check: $ts,
            check_count: $cc,
            claude_interventions: $ci,
            consecutive_failures: $cf,
            error_class: $ec,
            report: $report
        }' > "$DASHBOARD_FILE"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    init_state
    increment_state "check_count"
    local check_count
    check_count=$(get_state "check_count")

    log INFO "========== Monitor Check #${check_count} =========="

    # Clean up orphaned processes first
    cleanup_orphaned_processes

    # 1. Gather structured report
    local report
    report=$(gather_report)
    log INFO "Report: $(echo "$report" | jq -c .)"
    log_event "check" "$(echo "$report" | jq -c .)"

    # 2. Classify error
    local error_class
    error_class=$(classify_error "$report")
    log INFO "Error class: $error_class"

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
        notify "Ralph Pro Progress" "${newly} new story(ies) completed. Total: ${completed_count}/36"
    fi

    # 5. First 2 checks: always use Claude for thorough check (if healthy)
    if [[ "$check_count" -le 2 && "$error_class" == "healthy" ]]; then
        invoke_claude_narrow "routine_check" "Routine startup check #$check_count. Verify everything is running correctly and report status."
        log INFO "========== Check #${check_count} complete =========="
        return
    fi

    # 6. Dispatch fix if needed
    if [[ "$error_class" != "healthy" ]]; then
        local consecutive
        consecutive=$(get_state "consecutive_failures")
        consecutive=${consecutive:-0}
        update_state "consecutive_failures" "$((consecutive + 1))"

        dispatch_fix "$error_class" "$report"
    else
        update_state "consecutive_failures" "0"
    fi

    log INFO "========== Check #${check_count} complete =========="
}

# ============================================================================
# ENTRY POINTS
# ============================================================================
case "${1:-check}" in
    check)
        main
        ;;
    failure)
        log ERROR "Ralph Pro process exited unexpectedly!"
        notify_priority "Ralph Pro CRASHED" "Orchestrator crashed. Running monitor."
        main
        ;;
    reset)
        rm -f "$STATE_FILE"
        log INFO "Monitor state reset"
        ;;
    status)
        if [[ -f "$DASHBOARD_FILE" ]]; then
            cat "$DASHBOARD_FILE" | jq .
        else
            echo "No dashboard data yet. Run a check first."
        fi
        ;;
    *)
        echo "Usage: $0 {check|failure|reset|status}"
        exit 1
        ;;
esac
