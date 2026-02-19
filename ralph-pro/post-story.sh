#!/usr/bin/env bash
# ============================================================================
# Ralph Pro Post-Story Hook
# Called after each successful story completion.
# 1. Pushes to local bare repo backup
# 2. Creates a tar+git-bundle checkpoint
# ============================================================================
set -euo pipefail

PROJECT_PATH="${1:-/home/johnlane/projects/openclaw-alternative}"
STORY_ID="${2:-unknown}"
BACKUP_REMOTE="backup"
CHECKPOINT_DIR="/home/johnlane/git-backups/checkpoints"

NTFY_TOPIC="johnlane-claude-tasks"
NTFY_SERVER="https://ntfy.sh"

LOG_FILE="$HOME/.claude-task-system/logs/post-story-hook.log"
mkdir -p "$(dirname "$LOG_FILE")" "$CHECKPOINT_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [post-story] $*" | tee -a "$LOG_FILE"
}

# --- Send ntfy notification ---
send_ntfy() {
    local completed total remaining
    cd "$PROJECT_PATH"
    # Count completed from progress.json
    local progress_file
    progress_file="$(find "$HOME/ralph-pro/data/projects" -name progress.json -path "*/task-*/progress.json" -newer "$LOG_FILE" 2>/dev/null | head -1)"
    if [[ -z "$progress_file" ]]; then
        progress_file="$(find "$HOME/ralph-pro/data/projects" -name progress.json -path "*/task-*/progress.json" 2>/dev/null | tail -1)"
    fi
    if [[ -n "$progress_file" ]] && command -v python3 >/dev/null 2>&1; then
        completed=$(python3 -c "import json; d=json.load(open('$progress_file')); print(len(d.get('completedStories',[])))" 2>/dev/null || echo "?")
        total=36
        remaining=$((total - completed))
    else
        completed="?"
        total=36
        remaining="?"
    fi
    local title="Ralph Pro: ${STORY_ID} completed"
    local message="${completed}/${total} stories done, ${remaining} remaining"
    curl -sf \
        -H "Title: ${title}" \
        -H "Tags: white_check_mark" \
        -d "${message}" \
        "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null 2>&1 || {
        log "WARNING: ntfy notification failed"
    }
    log "Sent ntfy notification: ${title} - ${message}"
}

# --- Push to bare repo backup ---
push_to_backup() {
    cd "$PROJECT_PATH"
    if git remote get-url "$BACKUP_REMOTE" >/dev/null 2>&1; then
        if git rev-parse HEAD >/dev/null 2>&1; then
            git push "$BACKUP_REMOTE" --all 2>&1 | tee -a "$LOG_FILE" || {
                log "WARNING: Push to backup failed, but continuing"
            }
            log "Pushed to backup remote after $STORY_ID"
        else
            log "No commits yet, skipping push"
        fi
    else
        log "WARNING: No backup remote configured"
    fi
}

# --- Create checkpoint ---
create_checkpoint() {
    cd "$PROJECT_PATH"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local checkpoint_name="${timestamp}_${STORY_ID}"

    # Git bundle (compact, contains full history)
    if git rev-parse HEAD >/dev/null 2>&1; then
        local bundle_file="$CHECKPOINT_DIR/${checkpoint_name}.bundle"
        git bundle create "$bundle_file" --all 2>&1 | tee -a "$LOG_FILE" || {
            log "WARNING: Git bundle creation failed"
        }
        log "Created git bundle: $bundle_file"
    fi

    # Tar of working directory (quick snapshot of current state)
    local tar_file="$CHECKPOINT_DIR/${checkpoint_name}.tar.gz"
    tar czf "$tar_file" \
        --exclude='.git' \
        --exclude='node_modules' \
        -C "$(dirname "$PROJECT_PATH")" \
        "$(basename "$PROJECT_PATH")" 2>&1 | tee -a "$LOG_FILE" || {
        log "WARNING: Tar checkpoint failed"
    }
    log "Created tar checkpoint: $tar_file"

    # Prune old checkpoints (keep last 20)
    local count
    count=$(ls -1 "$CHECKPOINT_DIR"/*.tar.gz 2>/dev/null | wc -l)
    if [[ "$count" -gt 20 ]]; then
        ls -1t "$CHECKPOINT_DIR"/*.tar.gz | tail -n +21 | xargs rm -f
        ls -1t "$CHECKPOINT_DIR"/*.bundle 2>/dev/null | tail -n +21 | xargs rm -f
        log "Pruned old checkpoints (kept 20)"
    fi
}

# --- Main ---
log "Post-story hook triggered for $STORY_ID in $PROJECT_PATH"
push_to_backup
create_checkpoint
send_ntfy
log "Post-story hook complete for $STORY_ID"
