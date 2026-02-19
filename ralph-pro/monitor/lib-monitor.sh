#!/usr/bin/env bash
# ============================================================================
# Ralph Pro Monitor — Shared Library
# Sourced by both healthcheck.sh and fixer.sh
# ============================================================================

RALPH_PRO_URL="http://localhost:3000"
PROJECT_ID="proj-1771322660094"
TASK_ID="task-1771322680412"
PROJECT_PATH="/home/johnlane/projects/openclaw-alternative"
RALPH_PRO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOG_DIR="$HOME/.claude-task-system/logs"
STATE_DIR="$HOME/.claude-task-system"
LOG_FILE="$LOG_DIR/monitor.log"
JSON_LOG="$LOG_DIR/monitor-events.jsonl"
STATE_FILE="$STATE_DIR/monitor-state.json"
DASHBOARD_FILE="$STATE_DIR/monitor-status.json"
FIX_REQUEST_DIR="$STATE_DIR/fix-requests"

NTFY_TOPIC="johnlane-claude-tasks"
NTFY_SERVER="https://ntfy.sh"
NOTIFY_EMAIL="${RALPH_NOTIFY_EMAIL:-}"
SMTP_HOST="${RALPH_SMTP_HOST:-}"

PROGRESS_FILE="$RALPH_PRO_ROOT/data/projects/${PROJECT_ID}/tasks/${TASK_ID}/progress.json"
OUTPUT_DIR="$RALPH_PRO_ROOT/data/projects/${PROJECT_ID}/tasks/${TASK_ID}/output"

MAX_CONSECUTIVE_FAILURES=3
CLAUDE_MAX_TURNS=30

LOCK_FILE="$STATE_DIR/monitor.lock"

mkdir -p "$LOG_DIR" "$FIX_REQUEST_DIR"

# ============================================================================
# File Locking (protects shared state)
# ============================================================================
_lock_fd=9
with_lock() {
    # Usage: with_lock <command...>
    # Acquires exclusive lock on LOCK_FILE for the duration of the command
    (
        flock -w 10 "$_lock_fd" || { echo "Failed to acquire lock" >&2; return 1; }
        "$@"
    ) 9>"$LOCK_FILE"
}

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
    # Use jq to ensure the output is valid JSON
    jq -nc --arg ts "$ts" --arg ev "$event_type" --argjson det "$details" \
        '{"timestamp":$ts,"event":$ev,"details":$det}' >> "$JSON_LOG" 2>/dev/null || \
    jq -nc --arg ts "$ts" --arg ev "$event_type" --arg det "$details" \
        '{"timestamp":$ts,"event":$ev,"details":$det}' >> "$JSON_LOG" 2>/dev/null || true
}

# ============================================================================
# Structured Notifications
# ============================================================================
# Severity: info | warning | error | critical
notify_structured() {
    local severity="$1" title="$2" message="$3"

    local priority tags
    case "$severity" in
        info)
            priority="default"
            tags="white_check_mark"
            ;;
        warning)
            priority="high"
            tags="warning"
            ;;
        error)
            priority="urgent"
            tags="rotating_light"
            ;;
        critical)
            priority="max"
            tags="skull"
            ;;
        *)
            priority="default"
            tags="grey_question"
            ;;
    esac

    # Always send to ntfy
    if ! curl -sf \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -d "${message}" \
        "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] ntfy send failed for: ${title}" >> "$LOG_FILE" 2>/dev/null || true
    fi

    # Email fallback for critical
    if [[ "$severity" == "critical" && -n "$SMTP_HOST" && -n "$NOTIFY_EMAIL" ]]; then
        _send_email_fallback "$title" "$message" || true
    fi

    log "${severity^^}" "NOTIFY [${severity}]: ${title} — ${message}"
    log_event "notification" "$(printf '{"severity":"%s","title":"%s"}' "$severity" "$title")"
}

_send_email_fallback() {
    local subject="$1" body="$2"
    EMAIL_SUBJECT="$subject" EMAIL_BODY="$body" EMAIL_TO="$NOTIFY_EMAIL" EMAIL_SMTP="$SMTP_HOST" \
    python3 -c '
import os, smtplib
from email.mime.text import MIMEText
body = os.environ["EMAIL_BODY"]
subject = os.environ["EMAIL_SUBJECT"]
to = os.environ["EMAIL_TO"]
smtp = os.environ["EMAIL_SMTP"]
msg = MIMEText(body)
msg["Subject"] = "[Ralph Pro CRITICAL] " + subject
msg["From"] = "ralph-pro@labmachine"
msg["To"] = to
try:
    s = smtplib.SMTP(smtp, 587, timeout=10)
    s.starttls()
    s.send_message(msg)
    s.quit()
except Exception as e:
    print(f"Email fallback failed: {e}")
' 2>&1 | tee -a "$LOG_FILE" || true
}

# Backward-compatible wrappers
notify() {
    notify_structured "info" "$1" "$2"
}

notify_priority() {
    notify_structured "critical" "$1" "$2"
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
    jq -r ".$key // empty" "$STATE_FILE" 2>/dev/null || echo ""
}

update_state() {
    local key="$1" value="$2"
    (
        flock -w 10 200 || { log WARN "Failed to lock state file"; return 1; }
        jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    ) 200>"${STATE_FILE}.lock"
}

increment_state() {
    local key="$1"
    (
        flock -w 10 200 || { log WARN "Failed to lock state file"; return 1; }
        local current
        current=$(jq -r ".$key // 0" "$STATE_FILE" 2>/dev/null || echo 0)
        # Ensure numeric
        [[ "$current" =~ ^[0-9]+$ ]] || current=0
        jq --arg k "$key" --argjson v "$(( current + 1 ))" '.[$k] = $v' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    ) 200>"${STATE_FILE}.lock"
}

# ============================================================================
# Data Gathering
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

    local max_per_story
    max_per_story=$(echo "$progress_json" | jq -r '.executionConfig.maxPerStory // 5')
    failed_count=$(echo "$progress_json" | jq --argjson max "$max_per_story" '
        (.completedStories // []) as $completed |
        [.failedAttempts // {} | to_entries[] | select((.value | length) >= $max) | select(.key | IN($completed[]) | not)] | length
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
        last_error_story=$(echo "$progress_json" | jq -r --argjson max "$max_per_story" '
            (.completedStories // []) as $completed |
            [.failedAttempts // {} | to_entries[] | select((.value | length) >= $max) | select(.key | IN($completed[]) | not)] | last | .key // "none"
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

    # --- Rate limit detection ---
    local rate_limited="false"
    local rate_limit_reset=""
    if [[ -d "$OUTPUT_DIR" ]]; then
        local recent_output
        recent_output=$(ls -1t "$OUTPUT_DIR"/*_output.txt 2>/dev/null | head -1)
        if [[ -n "$recent_output" ]]; then
            local reset_time
            reset_time=$(grep -oP 'reset at \K[0-9-]+ [0-9:]+' "$recent_output" 2>/dev/null | head -1 || true)
            if [[ -n "$reset_time" ]]; then
                rate_limited="true"
                rate_limit_reset="$reset_time"
            fi
        fi
    fi
    report=$(echo "$report" | jq \
        --argjson rl "$rate_limited" \
        --arg rlr "$rate_limit_reset" \
        '.rate_limited = $rl | .rate_limit_reset = $rlr')

    # --- Git conflict detection ---
    local git_conflict="false"
    if [[ -d "$PROJECT_PATH/.git" ]]; then
        if git -C "$PROJECT_PATH" diff --name-only --diff-filter=U 2>/dev/null | head -1 | grep -q .; then
            git_conflict="true"
        fi
    fi
    report=$(echo "$report" | jq --argjson gc "$git_conflict" '.git_conflict = $gc')

    # --- OAuth token check ---
    local oauth_expired="false"
    local oauth_file="$HOME/.claude/oauth_credentials.json"
    if [[ -f "$oauth_file" ]]; then
        local expiry
        expiry=$(jq -r '.expires_at // .expiry // 0' "$oauth_file" 2>/dev/null || echo 0)
        # Only compare if expiry is numeric (epoch integer)
        if [[ "$expiry" =~ ^[0-9]+$ ]]; then
            local now_epoch
            now_epoch=$(date +%s)
            if [[ "$expiry" -gt 0 && "$expiry" -lt "$now_epoch" ]]; then
                oauth_expired="true"
            fi
        fi
    fi
    report=$(echo "$report" | jq --argjson oe "$oauth_expired" '.oauth_expired = $oe')

    echo "$report"
}

# ============================================================================
# Error Classification
# ============================================================================
# Returns one of:
#   healthy, completed, server_down, env_cwd_missing, env_sh_missing,
#   env_disk_full, stale_running, task_failed, task_pending,
#   stories_maxed, circuit_breaker, api_rate_limited, oauth_expired,
#   git_conflict, unknown
classify_error() {
    local report="$1"

    local server_healthy task_status orch_running cwd_exists sh_exists disk_free
    local failed_count last_error rate_limited oauth_expired git_conflict
    server_healthy=$(echo "$report" | jq -r '.server_healthy')
    task_status=$(echo "$report" | jq -r '.task_status')
    orch_running=$(echo "$report" | jq -r '.orchestrator_running')
    cwd_exists=$(echo "$report" | jq -r '.env_cwd_exists')
    sh_exists=$(echo "$report" | jq -r '.env_sh_exists')
    disk_free=$(echo "$report" | jq -r '.env_disk_free_mb')
    failed_count=$(echo "$report" | jq -r '.failed_count')
    last_error=$(echo "$report" | jq -r '.last_error')
    rate_limited=$(echo "$report" | jq -r '.rate_limited // false')
    oauth_expired=$(echo "$report" | jq -r '.oauth_expired // false')
    git_conflict=$(echo "$report" | jq -r '.git_conflict // false')

    # Priority order: environmental > server > auth > task state > story-level
    [[ "$cwd_exists" == "false" ]] && echo "env_cwd_missing" && return
    [[ "$sh_exists" == "false" ]] && echo "env_sh_missing" && return
    [[ "${disk_free:-0}" =~ ^[0-9]+$ ]] && [[ "$disk_free" -lt 100 ]] && echo "env_disk_full" && return
    [[ "$server_healthy" == "false" ]] && echo "server_down" && return
    [[ "$oauth_expired" == "true" ]] && echo "oauth_expired" && return
    [[ "$git_conflict" == "true" ]] && echo "git_conflict" && return

    case "$task_status" in
        completed|all_complete) echo "completed"; return ;;
        failed|error)
            if printf '%s\n' "$last_error" | grep -qi "circuit.breaker"; then
                echo "circuit_breaker"
            elif [[ "$rate_limited" == "true" ]]; then
                echo "api_rate_limited"
            else
                echo "task_failed"
            fi
            return ;;
        pending) echo "task_pending"; return ;;
        running|in_progress)
            if [[ "$orch_running" == "false" ]]; then
                echo "stale_running"; return
            fi
            ;;
    esac

    [[ "$rate_limited" == "true" ]] && echo "api_rate_limited" && return
    [[ "$failed_count" -gt 0 ]] && echo "stories_maxed" && return
    [[ "$task_status" == "running" || "$task_status" == "in_progress" ]] && [[ "$orch_running" == "true" ]] && echo "healthy" && return

    echo "unknown"
}

# ============================================================================
# Dashboard
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
