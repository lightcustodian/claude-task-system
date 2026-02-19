#!/usr/bin/env bash
# cts-status.sh — Show status of all CTS and Ralph Pro services/timers
set -uo pipefail

BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'

section() { echo -e "\n${BOLD}=== $1 ===${NC}"; }

show_unit() {
    local unit="$1"
    local active sub enabled

    active=$(systemctl --user show -p ActiveState --value "$unit" 2>/dev/null) || active="not-found"
    sub=$(systemctl --user show -p SubState --value "$unit" 2>/dev/null) || sub=""
    enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null) || enabled="disabled"

    if [[ "$active" == "not-found" || -z "$active" ]]; then
        echo -e "  ${GRAY}%-40s not installed${NC}" | xargs printf "  %-40s ${GRAY}not installed${NC}\n" "$unit"
        return
    fi

    local color="$GRAY"
    case "$active" in
        active)   color="$GREEN" ;;
        failed)   color="$RED" ;;
        inactive) color="$GRAY" ;;
    esac

    local en_color="$GRAY"
    [[ "$enabled" == "enabled" ]] && en_color="$GREEN"

    local status_text="$active"
    [[ -n "$sub" && "$sub" != "$active" ]] && status_text="$active ($sub)"

    printf "  %-40s ${color}%-20s${NC} ${en_color}%s${NC}\n" "$unit" "$status_text" "[$enabled]"

    if [[ "$unit" == *.timer && "$active" == "active" ]]; then
        local next last
        next=$(systemctl --user show -p NextElapseUSecRealtime --value "$unit" 2>/dev/null) || next=""
        last=$(systemctl --user show -p LastTriggerUSec --value "$unit" 2>/dev/null) || last=""
        [[ -n "$next" && "$next" != "n/a" ]] && echo -e "    ${GRAY}Next: $next${NC}"
        [[ -n "$last" && "$last" != "n/a" ]] && echo -e "    ${GRAY}Last: $last${NC}"
    fi
}

section "CTS v2 Services"
show_unit "claude-tasks.service"

section "Ralph Pro Services"
show_unit "ralph-pro-healthcheck.service"
show_unit "ralph-pro-monitor.service"
show_unit "ralph-pro-fixer.service"
show_unit "ralph-pro-digest.service"
show_unit "ralph-pro-failure.service"

section "Timers"
show_unit "ralph-pro-healthcheck.timer"
show_unit "ralph-pro-monitor.timer"
show_unit "ralph-pro-digest.timer"

section "Infrastructure"
show_unit "rclone-gdrive.service"
show_unit "ollama.service" 2>/dev/null || echo -e "  ${GRAY}ollama.service (system) — check with: systemctl status ollama${NC}"

section "System Services"
printf "  %-40s %s\n" "ollama" "$(systemctl is-active ollama.service 2>/dev/null || echo 'not installed')"
printf "  %-40s %s\n" "docker" "$(systemctl is-active docker.service 2>/dev/null || echo 'not installed')"
nvidia_info=$(nvidia-smi --query-gpu=driver_version,memory.used,memory.total --format=csv,noheader 2>/dev/null) || nvidia_info="not available"
printf "  %-40s %s\n" "nvidia-gpu" "$nvidia_info"

section "Disk & Resources"
printf "  %-25s %s\n" "Disk free:" "$(df -h /home --output=avail | tail -1 | xargs)"
printf "  %-25s %s\n" "State dir size:" "$(du -sh ~/.claude-task-system 2>/dev/null | cut -f1)"
printf "  %-25s %s\n" "Log dir size:" "$(du -sh ~/.claude-task-system/shared/logs 2>/dev/null | cut -f1)"
printf "  %-25s %s\n" "Ollama models:" "$(du -sh /usr/share/ollama/.ollama/models 2>/dev/null | cut -f1 || echo 'N/A')"

section "Ollama Models"
if command -v ollama &>/dev/null; then
    ollama list 2>/dev/null | while read -r line; do
        echo "  $line"
    done
else
    echo -e "  ${GRAY}ollama not installed${NC}"
fi

echo ""
