#!/usr/bin/env bash
# ============================================================================
# Filesystem Audit Watcher
# Monitors critical directories for create/delete/move operations
# Logs all changes with timestamps for post-incident analysis
# ============================================================================
set -euo pipefail

AUDIT_LOG="$HOME/.claude-task-system/logs/filesystem-audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")"

WATCH_DIRS=(
    "$HOME/projects"
    "$HOME/GoogleDrive/DriveSyncFiles/claude-tasks"
    "$HOME/obsidian-tool"
    "$HOME/ralph-pro"
)

log_audit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$AUDIT_LOG"
}

log_audit "=== Audit watcher started ==="
log_audit "Monitoring: ${WATCH_DIRS[*]}"

# Build the watch list (only dirs that exist)
EXISTING_DIRS=()
for dir in "${WATCH_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        EXISTING_DIRS+=("$dir")
    else
        log_audit "WARN: $dir does not exist, skipping"
    fi
done

if [[ ${#EXISTING_DIRS[@]} -eq 0 ]]; then
    log_audit "ERROR: No directories to watch"
    exit 1
fi

# Watch for create, delete, move, modify events recursively
inotifywait -m -r \
    --event create,delete,moved_from,moved_to,delete_self \
    --timefmt '%Y-%m-%d %H:%M:%S' \
    --format '[%T] %e %w%f' \
    "${EXISTING_DIRS[@]}" 2>/dev/null | while read -r line; do

    # Filter out noise (temp files, .git internals, cache)
    if echo "$line" | grep -qE '\.(swp|tmp|lock|git/objects|__pycache__)'; then
        continue
    fi

    log_audit "$line"

    # Alert on critical deletions
    if echo "$line" | grep -qE 'DELETE_SELF|DELETE.*projects/|DELETE.*claude-tasks/'; then
        local msg="CRITICAL DELETION: $line"
        log_audit "ALERT: $msg"
        curl -sf \
            -H "Title: FILESYSTEM DELETION" \
            -H "Priority: urgent" \
            -d "$msg" \
            "https://ntfy.sh/johnlane-claude-tasks" >/dev/null 2>&1 || true
    fi
done
