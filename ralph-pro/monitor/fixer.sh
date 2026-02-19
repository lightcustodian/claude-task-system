#!/usr/bin/env bash
# ============================================================================
# Ralph Pro Fixer
# Path-activated by systemd. Processes fix requests from the health checker.
# Handles bash-fixable problems directly; delegates complex issues to Claude.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-monitor.sh"

# ============================================================================
# Fix Functions (bash-only, no Claude needed)
# ============================================================================
fix_server_restart() (
    update_state "last_fix_action" '"server_restart"'
    sudo systemctl restart ralph-pro 2>/dev/null || {
        cd "$RALPH_PRO_ROOT" && nohup node server/index.js &>/dev/null &
        sleep 3
    }
    if curl -sf --max-time 5 "${RALPH_PRO_URL}/api/projects" >/dev/null 2>&1; then
        log INFO "Server restarted successfully"
        notify_structured "info" "Ralph Pro Monitor" "Server restarted successfully"
        log_event "fix_applied" '{"action":"server_restart","success":true}'
    else
        log ERROR "Server restart failed"
        notify_structured "critical" "Ralph Pro DOWN" "Server restart failed. Manual intervention needed."
        log_event "fix_applied" '{"action":"server_restart","success":false}'
    fi
)

fix_recreate_cwd() (
    update_state "last_fix_action" '"recreate_cwd"'
    if [[ -d "$PROJECT_PATH" ]]; then
        log INFO "CWD already exists (race condition?)"
        return 0
    fi
    mkdir -p "$PROJECT_PATH/src/lib" "$PROJECT_PATH/src/invokers" "$PROJECT_PATH/src/heartbeat" \
             "$PROJECT_PATH/test/fixtures" "$PROJECT_PATH/systemd" "$PROJECT_PATH/docs"
    log INFO "Recreated project directory structure"

    # Restore from latest checkpoint
    local latest_tar
    latest_tar=$(ls -1t /home/johnlane/git-backups/checkpoints/*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$latest_tar" ]]; then
        tar xzf "$latest_tar" -C "$(dirname "$PROJECT_PATH")" 2>/dev/null && {
            log INFO "Restored from checkpoint: $latest_tar"
            notify_structured "warning" "Ralph Pro Monitor" "CWD restored from checkpoint"
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
    notify_structured "error" "Ralph Pro" "CWD recreated but no backup to restore from"
    log_event "fix_applied" '{"action":"recreate_cwd_empty","success":true}'
)

fix_disk_cleanup() {
    update_state "last_fix_action" '"disk_cleanup"'
    find "$HOME/.claude-task-system/snapshots" -name "*.txt" -mtime +3 -delete 2>/dev/null || true
    find "$HOME/.claude-task-system/logs" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    find "/home/johnlane/git-backups/checkpoints" -name "*.tar.gz" -mtime +7 -delete 2>/dev/null || true
    find "/home/johnlane/git-backups/checkpoints" -name "*.bundle" -mtime +7 -delete 2>/dev/null || true
    log INFO "Cleaned up old files"
    log_event "fix_applied" '{"action":"disk_cleanup","success":true}'
}

fix_restart_task() {
    update_state "last_fix_action" '"restart_task"'
    cleanup_orphaned_processes

    # Check if orchestrator is already running
    if pgrep -f "ralph-pro.js.*--task.*${TASK_ID}" >/dev/null 2>&1; then
        log INFO "Orchestrator already running, skipping restart"
        return 0
    fi

    # Reset progress status so CLI picks up the work
    if [[ -f "$PROGRESS_FILE" ]]; then
        local current_status
        current_status=$(jq -r '.status // "unknown"' "$PROGRESS_FILE" 2>/dev/null)
        if [[ "$current_status" == "running" || "$current_status" == "failed" || "$current_status" == "error" ]]; then
            jq '.status = "in_progress"' "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
            log INFO "Reset progress status from '$current_status' to 'in_progress'"
        fi
    fi

    # Reset failed PRD stories to pending so CLI finds them
    local prd_file
    prd_file="$(dirname "$PROGRESS_FILE")/prd.json"
    if [[ -f "$prd_file" ]]; then
        local reset_count
        reset_count=$(python3 -c "
import json, sys
with open('$prd_file') as f:
    prd = json.load(f)
c = 0
for s in prd.get('stories', []):
    if s.get('status') == 'failed':
        s['status'] = 'pending'
        c += 1
with open('$prd_file', 'w') as f:
    json.dump(prd, f, indent=4)
print(c)
" 2>/dev/null || echo 0)
        [[ "$reset_count" -gt 0 ]] && log INFO "Reset $reset_count failed PRD stories to pending"
    fi

    # Start via CLI (not API, since server may not be running)
    local log_file="$LOG_DIR/ralph-pro-restart-$(date +%Y%m%d_%H%M%S).log"
    nohup node "$RALPH_PRO_ROOT/cli/ralph-pro.js" \
        --project "$PROJECT_PATH" \
        --task "$TASK_ID" \
        --total-attempts 200 \
        --max-per-story 5 \
        > "$log_file" 2>&1 &
    local pid=$!
    sleep 3

    if kill -0 "$pid" 2>/dev/null; then
        notify_structured "info" "Ralph Pro Monitor" "Task restarted (PID $pid)"
        log INFO "Task restarted: PID $pid, log: $log_file"
        log_event "fix_applied" "$(printf '{"action":"restart_task","success":true,"pid":%d}' "$pid")"
        update_state "consecutive_failures" "0"
    else
        log ERROR "Task restart failed (process exited immediately)"
        notify_structured "error" "Ralph Pro" "Task restart failed"
        log_event "fix_applied" '{"action":"restart_task","success":false}'
    fi
}

fix_api_rate_limited() {
    update_state "last_fix_action" '"wait_rate_limit"'
    local report="$1"
    local reset_time
    reset_time=$(echo "$report" | jq -r '.rate_limit_reset // ""')

    if [[ -n "$reset_time" ]]; then
        local reset_epoch now_epoch wait_seconds
        reset_epoch=$(date -d "$reset_time" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        wait_seconds=$((reset_epoch - now_epoch))

        if [[ "$wait_seconds" -gt 0 && "$wait_seconds" -lt 21600 ]]; then
            log INFO "Rate limited. Reset at $reset_time ($wait_seconds seconds away)"
            notify_structured "warning" "Ralph Pro Rate Limited" "Waiting until $reset_time (${wait_seconds}s). Orchestrator will use fallback backends."
            # Don't actually block — the orchestrator handles backend fallback itself.
            # Just log and let the next healthcheck pick it up.
            log_event "fix_applied" "$(printf '{"action":"rate_limit_acknowledged","reset":"%s","wait_s":%d}' "$reset_time" "$wait_seconds")"
        else
            log WARN "Rate limit reset time unparseable or too far out: $reset_time"
        fi
    else
        log WARN "Rate limited but no reset time found"
        notify_structured "warning" "Ralph Pro Rate Limited" "API rate limited, no reset time parsed"
    fi
}

fix_oauth_expired() {
    update_state "last_fix_action" '"oauth_refresh"'
    # Attempt to refresh the OAuth token
    local oauth_file="$HOME/.claude/oauth_credentials.json"
    if [[ -f "$oauth_file" ]]; then
        local refresh_token
        refresh_token=$(jq -r '.refresh_token // ""' "$oauth_file" 2>/dev/null)
        if [[ -n "$refresh_token" ]]; then
            log INFO "Attempting OAuth token refresh"
            # Claude CLI handles its own token refresh on next invocation
            # Just notify and let the next story attempt trigger the refresh
            notify_structured "warning" "Ralph Pro OAuth" "Token expired. Next CLI invocation will attempt refresh."
            log_event "fix_applied" '{"action":"oauth_expired_noted","success":true}'
        else
            notify_structured "error" "Ralph Pro OAuth" "Token expired and no refresh token available. Manual re-auth needed."
            log_event "fix_applied" '{"action":"oauth_no_refresh_token","success":false}'
        fi
    else
        notify_structured "error" "Ralph Pro OAuth" "No oauth_credentials.json found."
        log_event "fix_applied" '{"action":"oauth_file_missing","success":false}'
    fi
}

fix_git_conflict() (
    update_state "last_fix_action" '"git_conflict_reset"'
    cd "$PROJECT_PATH"

    # Get list of conflicted files into array safely
    local -a conflicted_files=()
    while IFS= read -r file; do
        [[ -n "$file" ]] && conflicted_files+=("$file")
    done < <(git diff --name-only --diff-filter=U 2>/dev/null || true)

    if [[ ${#conflicted_files[@]} -eq 0 ]]; then
        log INFO "No git conflicts found (race condition?)"
        return 0
    fi

    log WARN "Git conflicts detected in: ${conflicted_files[*]}"

    # Reset conflicted files to HEAD (keep our changes, discard theirs)
    if git checkout --ours -- "${conflicted_files[@]}" 2>/dev/null && \
       git add -- "${conflicted_files[@]}" 2>/dev/null; then
        git commit -m "Auto-resolve merge conflicts (keep ours)" --no-verify 2>/dev/null || true
        log INFO "Resolved git conflicts by keeping HEAD version"
        notify_structured "warning" "Ralph Pro Monitor" "Git conflicts auto-resolved (kept HEAD)"
        log_event "fix_applied" '{"action":"git_conflict_reset","success":true}'
    else
        # Fallback: hard reset
        git reset --hard HEAD 2>/dev/null || true
        log WARN "Could not resolve conflicts gracefully, reset to HEAD"
        notify_structured "warning" "Ralph Pro Monitor" "Git conflicts resolved via reset --hard HEAD"
        log_event "fix_applied" '{"action":"git_hard_reset","success":true}'
    fi
)

fix_analyze_and_restart() {
    update_state "last_fix_action" '"analyze_and_restart"'

    local progress
    progress=$(cat "$PROGRESS_FILE" 2>/dev/null || echo '{}')

    # Check if failures are environmental (spawn ENOENT pattern)
    local has_spawn_error="false"
    if [[ -d "$OUTPUT_DIR" ]]; then
        local sample_error
        sample_error=$(find "$OUTPUT_DIR" -name "*_DESIGN_output.txt" -size -200c 2>/dev/null | head -1)
        if [[ -n "$sample_error" ]]; then
            if grep -q "spawn /bin/sh ENOENT" "$sample_error" 2>/dev/null; then
                has_spawn_error="true"
                log ERROR "Detected spawn ENOENT errors — environmental failure"
            fi
        fi
    fi

    if [[ "$has_spawn_error" == "true" ]]; then
        [[ ! -d "$PROJECT_PATH" ]] && fix_recreate_cwd
        reset_failed_stories
        fix_restart_task
    else
        # Non-environmental — invoke Claude for code-level diagnosis
        local failed_stories
        failed_stories=$(echo "$progress" | jq -r '[.failedAttempts // {} | to_entries[] | select((.value | length) >= 5) | .key] | join(", ")' 2>/dev/null)
        invoke_claude_narrow "story_failures" "Stories failed verification: ${failed_stories}. Examine the VERIFY output files in ${OUTPUT_DIR} for each failed story, fix the code issues, and retry."
    fi
}

reset_failed_stories() {
    log INFO "Resetting failed stories in progress.json"
    PROGRESS_FILE_PATH="$PROGRESS_FILE" python3 -c '
import json, os
pf = os.environ["PROGRESS_FILE_PATH"]
with open(pf, "r") as f:
    p = json.load(f)
completed = set(p.get("completedStories", []))
max_per = p.get("executionConfig", {}).get("maxPerStory", 5)
reset_count = 0
for sid, attempts in list(p.get("failedAttempts", {}).items()):
    if sid not in completed and len(attempts) >= max_per:
        del p["failedAttempts"][sid]
        if sid in p.get("storyPhases", {}):
            del p["storyPhases"][sid]
        reset_count += 1
p["status"] = "pending"
with open(pf, "w") as f:
    json.dump(p, f, indent=2)
print(f"Reset {reset_count} failed stories")
' 2>&1 | tee -a "$LOG_FILE"
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
# Claude Intervention (narrow, specific mandate)
# ============================================================================
invoke_claude_narrow() {
    local mandate="$1"
    local details="$2"

    increment_state "claude_interventions"
    local intervention_count
    intervention_count=$(get_state "claude_interventions")

    if [[ "$intervention_count" -gt 5 ]]; then
        local last_class
        last_class=$(get_state "last_error_class")
        log ERROR "Too many Claude interventions ($intervention_count). Error: $last_class"
        notify_structured "critical" "Ralph Pro NEEDS HELP" "Monitor has invoked Claude $intervention_count times. Manual help needed. Error: $last_class"
        return 1
    fi

    local claude_log="$LOG_DIR/claude-intervention-$(date +%Y%m%d_%H%M%S).log"

    log INFO "Invoking Claude Code (mandate: $mandate, intervention #$intervention_count)"
    notify_structured "warning" "Ralph Pro Monitor" "Claude intervention #$intervention_count: $mandate"

    local prompt
    prompt=$(cat <<PROMPTEOF
You are the Ralph Pro monitor's automated repair agent.

**Mandate:** ${mandate}
**Details:** ${details}

**Environment:**
- Project: ${PROJECT_ID} / Task: ${TASK_ID}
- Project path: ${PROJECT_PATH}
- Progress file: ${PROGRESS_FILE}
- Output dir: ${OUTPUT_DIR}

**Rules:**
1. NEVER delete ~/projects/, ~/GoogleDrive/, ~/git-backups/, or ~/ralph-pro/
2. NEVER run rm -rf on any directory outside ${PROJECT_PATH}/src/ or ${PROJECT_PATH}/test/
3. Focus ONLY on your mandate
4. After fixing, verify your fix works
5. Log what you did to: ${claude_log}
6. Send a notification: curl -H "Title: Monitor Fix: ${mandate}" -d "SUMMARY" ${NTFY_SERVER}/${NTFY_TOPIC}
7. This is intervention #${intervention_count}. Be efficient.
PROMPTEOF
)

    local exit_code=0
    ( cd "$PROJECT_PATH" && env -u CLAUDECODE claude -p "$prompt" \
        --max-turns "$CLAUDE_MAX_TURNS" \
        --dangerously-skip-permissions \
        2>>"$claude_log" >> "$claude_log" ) || exit_code=$?

    log_event "claude_intervention" "$(printf '{"mandate":"%s","intervention":%d,"exit_code":%d}' "$mandate" "$intervention_count" "$exit_code")"

    if [[ "$exit_code" -ne 0 ]]; then
        log ERROR "Claude intervention failed (exit $exit_code)"
        notify_structured "error" "Ralph Pro Monitor" "Claude intervention FAILED (exit $exit_code)"
    else
        log INFO "Claude intervention completed. Log: $claude_log"
        # Analyze intervention log for pattern promotion
        analyze_intervention_log "$claude_log" "$mandate"
    fi
}

# ============================================================================
# Intervention Log Analysis (for pattern promotion)
# ============================================================================
analyze_intervention_log() {
    local log_file="$1"
    local mandate="$2"
    local patterns_file="$STATE_DIR/intervention-patterns.jsonl"

    # Record what mandate was used
    local ts
    ts="$(date -Iseconds)"
    printf '{"timestamp":"%s","mandate":"%s","log":"%s"}\n' "$ts" "$mandate" "$log_file" >> "$patterns_file"

    # Count how many times this mandate has been used
    local count
    count=$(grep -cF "\"mandate\":\"$mandate\"" "$patterns_file" 2>/dev/null || echo 0)
    if [[ "$count" -ge 3 ]]; then
        log WARN "Mandate '$mandate' has been used $count times. Consider promoting to bash fix."
        notify_structured "warning" "Monitor Pattern" "Claude mandate '$mandate' used ${count}x. Candidate for bash promotion."
    fi
}

# ============================================================================
# Main: Process Fix Requests
# ============================================================================
dispatch_fix() {
    local error_class="$1"
    local report="$2"

    log INFO "[FIXER] Dispatching fix for: $error_class"
    log_event "fix_dispatch" "$(printf '{"error_class":"%s"}' "$error_class")"
    update_state "last_error_class" "\"$error_class\""

    case "$error_class" in
        server_down)        fix_server_restart ;;
        env_cwd_missing)    fix_recreate_cwd ;;
        env_sh_missing)
            notify_structured "critical" "CRITICAL" "/bin/sh not found. System may be compromised."
            ;;
        env_disk_full)      fix_disk_cleanup ;;
        stale_running)      fix_restart_task ;;
        task_failed)        fix_analyze_and_restart ;;
        task_pending)       fix_restart_task ;;
        circuit_breaker)
            invoke_claude_narrow "circuit_breaker" "Ralph Pro circuit breaker tripped after consecutive environmental failures. Diagnose root cause."
            ;;
        api_rate_limited)   fix_api_rate_limited "$report" ;;
        oauth_expired)      fix_oauth_expired ;;
        git_conflict)       fix_git_conflict ;;
        stories_maxed)      fix_analyze_and_restart ;;
        unknown)
            invoke_claude_narrow "unknown_error" "Monitor cannot classify the current state. Report: $(echo "$report" | jq -c .)"
            ;;
        *)
            log WARN "Unhandled error class: $error_class"
            ;;
    esac
}

process_fix_requests() {
    local processed=0
    local -A seen_classes=()

    for request_file in "$FIX_REQUEST_DIR"/fix-*.json; do
        [[ -f "$request_file" ]] || continue

        local error_class report
        error_class=$(jq -r '.error_class' "$request_file" 2>/dev/null)
        report=$(jq -c '.report' "$request_file" 2>/dev/null)

        if [[ -z "$error_class" || "$error_class" == "null" ]]; then
            log WARN "Invalid fix request: $request_file"
            rm -f "$request_file"
            continue
        fi

        # Deduplicate: only dispatch the first request per error class
        if [[ -n "${seen_classes[$error_class]:-}" ]]; then
            log INFO "Skipping duplicate fix request: $error_class (from $request_file)"
            rm -f "$request_file"
            continue
        fi
        seen_classes["$error_class"]=1

        log INFO "Processing fix request: $error_class (from $request_file)"
        dispatch_fix "$error_class" "$report"

        rm -f "$request_file"
        ((processed++)) || true
    done

    if [[ "$processed" -gt 0 ]]; then
        log INFO "Processed $processed fix request(s)"
    fi
}

# ============================================================================
# Entry Point (only when executed directly, not sourced)
# ============================================================================
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0
case "${1:-process}" in
    process)
        process_fix_requests
        ;;
    fix)
        # Direct fix: fixer.sh fix <error_class> [report_json]
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 fix <error_class> [report_json]"
            exit 1
        fi
        dispatch_fix "$2" "${3:-'{}'}"
        ;;
    *)
        echo "Usage: $0 {process|fix <error_class>}"
        exit 1
        ;;
esac
