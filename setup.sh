#!/bin/bash
# pihole-ha unified installer — detects Docker or bare metal and runs the appropriate installer
set -euo pipefail

COL_NC='\e[0m'
COL_BOLD='\e[1m'
COL_GREEN='\e[32m'
COL_RED='\e[91m'
TICK="[${COL_GREEN}✓${COL_NC}]"
CROSS="[${COL_RED}✗${COL_NC}]"
INFO="[i]"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf "\\n"
printf "  ${COL_GREEN}╔═══════════════════════════════════════╗${COL_NC}\\n"
printf "  ${COL_GREEN}║${COL_NC}  ${COL_BOLD}Pi-hole HA Setup${COL_NC}                     ${COL_GREEN}║${COL_NC}\\n"
printf "  ${COL_GREEN}╚═══════════════════════════════════════╝${COL_NC}\\n"
printf "\\n"

# Detect environment
docker_found=false
pihole_container=""
bare_metal_found=false

# Check for Docker Pi-hole container
if command -v docker &>/dev/null; then
    pihole_container="$(docker ps --filter ancestor=pihole/pihole --format '{{.Names}}' 2>/dev/null | head -1)"
    [[ -z "$pihole_container" ]] && pihole_container="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -i pihole | head -1 | awk '{print $1}')"
    [[ -n "$pihole_container" ]] && docker_found=true
fi

# Check for bare metal Pi-hole (skip if Docker Pi-hole already found —
# Docker with host network leaks pihole-FTL process and /etc/pihole to the host)
if [[ "$docker_found" == "false" ]]; then
    if command -v pihole &>/dev/null || [[ -d /etc/pihole ]] || pgrep -x pihole-FTL &>/dev/null 2>&1; then
        bare_metal_found=true
    fi
fi

# Route to the right installer
if [[ "$docker_found" == "true" && "$bare_metal_found" == "true" ]]; then
    printf "  %b Detected Pi-hole running as both Docker (%s) and bare metal\\n" "${INFO}" "$pihole_container"
    printf "\\n"
    printf "  Which installation method?\\n"
    printf "    1) Docker sidecar (alongside container: %s)\\n" "$pihole_container"
    printf "    2) Bare metal (systemd services)\\n"
    printf "\\n"
    read -erp "  Choice [1/2]: " _choice
    case "$_choice" in
        1) mode="docker" ;;
        2) mode="bare" ;;
        *) printf "  %b Invalid choice\\n" "${CROSS}"; exit 1 ;;
    esac
elif [[ "$docker_found" == "true" ]]; then
    printf "  %b Detected Pi-hole Docker container: %b%s%b\\n" "${TICK}" "${COL_BOLD}" "$pihole_container" "${COL_NC}"
    mode="docker"
elif [[ "$bare_metal_found" == "true" ]]; then
    printf "  %b Detected Pi-hole bare metal installation\\n" "${TICK}"
    mode="bare"
else
    printf "  %b %bNo Pi-hole installation found%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"
    printf "\\n"
    printf "  Install Pi-hole first:\\n"
    printf "    Bare metal:  curl -sSL https://install.pi-hole.net | bash\\n"
    printf "    Docker:      docker run -d --name pihole --network host pihole/pihole:latest\\n"
    printf "\\n"
    exit 1
fi

printf "\\n"

if [[ "$mode" == "docker" ]]; then
    if [[ ! -f "$SCRIPT_DIR/docker-install.sh" ]]; then
        printf "  %b %bMissing docker-install.sh%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"
        exit 1
    fi
    exec bash "$SCRIPT_DIR/docker-install.sh"
else
    if [[ ! -f "$SCRIPT_DIR/install.sh" ]]; then
        printf "  %b %bMissing install.sh%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"
        exit 1
    fi
    exec bash "$SCRIPT_DIR/install.sh"
fi
