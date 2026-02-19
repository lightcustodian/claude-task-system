#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Installer
# ============================================================================
# Installs systemd user units for CTS v2 and Ralph Pro.
#
# Usage:
#   ./install.sh [--uninstall]
#
# What it does:
#   - Copies systemd unit files to ~/.config/systemd/user/
#   - Reloads systemd daemon
#   - Enables timers (but does NOT start them — you start manually)
#   - Makes scripts executable
#
# Uninstall:
#   ./install.sh --uninstall
#   Stops, disables, and removes all units.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

# All service/timer units to install
units=(
    "claude-tasks.service"
    "claude-heartbeat-tier3.service"
    "claude-heartbeat-tier3.timer"
    "claude-health-monitor.service"
    "claude-health-monitor.timer"
    "ralph-pro-healthcheck.service"
    "ralph-pro-healthcheck.timer"
    "ralph-pro-monitor.service"
    "ralph-pro-monitor.timer"
    "ralph-pro-digest.service"
    "ralph-pro-digest.timer"
    "ralph-pro-fixer.service"
    "ralph-pro-failure.service"
)

# Timers to enable
timers=(
    "claude-heartbeat-tier3.timer"
    "claude-health-monitor.timer"
    "ralph-pro-healthcheck.timer"
    "ralph-pro-monitor.timer"
    "ralph-pro-digest.timer"
)

# Scripts that need +x
scripts=(
    "cts-v2/src/supervisor.sh"
    "cts-v2/src/watcher.sh"
    "cts-v2/src/scheduler.sh"
    "cts-v2/src/health-monitor.sh"
    "cts-v2/src/heartbeat/tier1.sh"
    "cts-v2/src/heartbeat/tier2.sh"
    "cts-v2/src/heartbeat/tier3.sh"
    "cts-v2/src/invokers/invoke-claude.sh"
    "cts-v2/src/invokers/invoke-ollama.sh"
    "new-task.sh"
    "test/mock-claude.sh"
    "test/mock-ollama.sh"
)

# --- Uninstall ---
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Uninstalling CTS v2 systemd units..."

    for timer in "${timers[@]}"; do
        systemctl --user stop "$timer" 2>/dev/null || true
        systemctl --user disable "$timer" 2>/dev/null || true
    done

    systemctl --user stop claude-tasks.service 2>/dev/null || true
    systemctl --user disable claude-tasks.service 2>/dev/null || true

    for unit in "${units[@]}"; do
        rm -f "${SYSTEMD_USER_DIR}/${unit}"
    done

    systemctl --user daemon-reload
    echo "Uninstall complete."
    exit 0
fi

# --- Install ---
echo "Installing CTS v2 systemd units..."

# Create systemd user dir if needed
mkdir -p "$SYSTEMD_USER_DIR"

# Copy unit files
for unit in "${units[@]}"; do
    src="${SCRIPT_DIR}/systemd/${unit}"
    if [[ -f "$src" ]]; then
        cp "$src" "${SYSTEMD_USER_DIR}/${unit}"
        echo "  Installed: $unit"
    else
        echo "  Warning: $unit not found in systemd/, skipping" >&2
    fi
done

# Make scripts executable
for script in "${scripts[@]}"; do
    src="${SCRIPT_DIR}/${script}"
    if [[ -f "$src" ]]; then
        chmod +x "$src"
    fi
done

# Reload systemd
systemctl --user daemon-reload
echo "Systemd daemon reloaded."

# Enable timers (but don't start them)
for timer in "${timers[@]}"; do
    systemctl --user enable "$timer" 2>/dev/null && echo "  Enabled: $timer" || echo "  Warning: Could not enable $timer" >&2
done

echo ""
echo "Installation complete. Units are enabled but NOT started."
echo "To start CTS:  systemctl --user start claude-tasks.service"
echo "To start timers manually: systemctl --user start <timer-name>"
