#!/usr/bin/env bash
# ============================================================================
# Directory Snapshot — captures state of critical dirs before/after operations
# Usage: snapshot-dirs.sh <label>  (e.g., "pre-claude-invoke" or "post-claude-invoke")
# ============================================================================
set -euo pipefail

LABEL="${1:-snapshot}"
SNAPSHOT_DIR="$HOME/.claude-task-system/snapshots"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SNAPSHOT_FILE="$SNAPSHOT_DIR/${TIMESTAMP}_${LABEL}.txt"

mkdir -p "$SNAPSHOT_DIR"

{
    echo "=== Snapshot: $LABEL ==="
    echo "=== Timestamp: $(date -Iseconds) ==="
    echo ""

    echo "--- ~/projects/ ---"
    find "$HOME/projects" -maxdepth 3 -type f 2>/dev/null | sort || echo "(directory does not exist)"
    echo ""

    echo "--- ~/GoogleDrive/DriveSyncFiles/claude-tasks/ ---"
    find "$HOME/GoogleDrive/DriveSyncFiles/claude-tasks" -maxdepth 3 -type f 2>/dev/null | sort || echo "(directory does not exist)"
    echo ""

    echo "--- ~/obsidian-tool/ ---"
    find "$HOME/obsidian-tool" -maxdepth 2 -type f 2>/dev/null | sort || echo "(directory does not exist)"
    echo ""

    echo "--- ~/ralph-pro/ (top-level only) ---"
    find "$HOME/ralph-pro" -maxdepth 1 -type f 2>/dev/null | sort || echo "(directory does not exist)"
    echo ""

    echo "=== End Snapshot ==="
} > "$SNAPSHOT_FILE"

echo "$SNAPSHOT_FILE"
