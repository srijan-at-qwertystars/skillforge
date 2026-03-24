#!/usr/bin/env bash
# =============================================================================
# service-generator.sh — Interactive systemd service unit file generator
# =============================================================================
# Usage: ./service-generator.sh [--preset web|worker|cron] [--output DIR]
#
# Generates systemd unit files with common presets:
#   web    — Web application (Node.js, Python, Go) with full hardening
#   worker — Background worker with restart policies
#   cron   — Timer-based cron replacement (generates .timer + .service pair)
#
# Examples:
#   ./service-generator.sh                           # Interactive mode
#   ./service-generator.sh --preset web              # Web app preset
#   ./service-generator.sh --preset cron --output /tmp
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OUTPUT_DIR="."
PRESET=""

usage() {
    echo "Usage: $0 [--preset web|worker|cron] [--output DIR]"
    echo ""
    echo "Options:"
    echo "  --preset TYPE   Use a preset (web, worker, cron)"
    echo "  --output DIR    Output directory (default: current directory)"
    echo "  --help          Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --preset) PRESET="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

prompt() {
    local var_name="$1" prompt_text="$2" default="${3:-}"
    local input
    if [[ -n "$default" ]]; then
        printf "${CYAN}%s${NC} [${YELLOW}%s${NC}]: " "$prompt_text" "$default"
    else
        printf "${CYAN}%s${NC}: " "$prompt_text"
    fi
    read -r input
    eval "$var_name=\"${input:-$default}\""
}

prompt_yn() {
    local var_name="$1" prompt_text="$2" default="${3:-y}"
    local input
    printf "${CYAN}%s${NC} [${YELLOW}%s${NC}]: " "$prompt_text" "$default"
    read -r input
    input="${input:-$default}"
    if [[ "${input,,}" == "y" || "${input,,}" == "yes" ]]; then
        eval "$var_name=yes"
    else
        eval "$var_name=no"
    fi
}

select_option() {
    local var_name="$1" prompt_text="$2"
    shift 2
    local options=("$@")
    echo -e "${CYAN}${prompt_text}${NC}"
    for i in "${!options[@]}"; do
        echo -e "  ${BOLD}$((i+1)))${NC} ${options[$i]}"
    done
    local choice
    printf "Choice: "
    read -r choice
    choice=$((choice - 1))
    if [[ $choice -ge 0 && $choice -lt ${#options[@]} ]]; then
        eval "$var_name=\"${options[$choice]}\""
    else
        eval "$var_name=\"${options[0]}\""
    fi
}

generate_hardening() {
    local level="$1"
    case "$level" in
        minimal)
            cat << 'HARDENING'
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
HARDENING
            ;;
        moderate)
            cat << 'HARDENING'
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
HARDENING
            ;;
        maximum)
            cat << 'HARDENING'
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077
HARDENING
            ;;
    esac
}

generate_web_service() {
    prompt SERVICE_NAME "Service name" "myapp"
    prompt DESCRIPTION "Description" "Web Application"
    prompt EXEC_START "ExecStart command" "/usr/bin/node /opt/${SERVICE_NAME}/server.js"
    prompt USER "Run as user" "$SERVICE_NAME"
    prompt PORT "Listen port (for documentation)" "8080"
    prompt WORK_DIR "Working directory" "/opt/${SERVICE_NAME}"
    prompt ENV_FILE "Environment file path" "/etc/${SERVICE_NAME}/env"
    select_option HARDENING_LEVEL "Security hardening level:" "minimal" "moderate" "maximum"
    prompt MEMORY_MAX "Memory limit (e.g., 512M, 1G)" "1G"
    prompt CPU_QUOTA "CPU quota (e.g., 100%, 200%)" "200%"

    local outfile="${OUTPUT_DIR}/${SERVICE_NAME}.service"
    cat > "$outfile" << EOF
[Unit]
Description=${DESCRIPTION}
Documentation=man:${SERVICE_NAME}(8)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=notify
User=${USER}
Group=${USER}
WorkingDirectory=${WORK_DIR}
EnvironmentFile=${ENV_FILE}
EnvironmentFile=-/etc/${SERVICE_NAME}/env.local
ExecStart=${EXEC_START}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
WatchdogSec=30
TimeoutStartSec=30
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGTERM

# Resource Limits
MemoryMax=${MEMORY_MAX}
MemoryHigh=$(echo "$MEMORY_MAX" | sed 's/G/000M/;s/M//' | awk '{printf "%dM", $1 * 0.75}')
CPUQuota=${CPU_QUOTA}
TasksMax=256
LimitNOFILE=65536

# Directories
ReadWritePaths=/var/lib/${SERVICE_NAME} /var/log/${SERVICE_NAME}

# Security Hardening (${HARDENING_LEVEL})
$(generate_hardening "$HARDENING_LEVEL")

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${GREEN}✓ Generated: ${outfile}${NC}"
    echo -e "${BLUE}  Next steps:${NC}"
    echo "    sudo useradd -r -s /usr/sbin/nologin ${USER}"
    echo "    sudo mkdir -p /var/lib/${SERVICE_NAME} /var/log/${SERVICE_NAME} $(dirname "$ENV_FILE")"
    echo "    sudo cp ${outfile} /etc/systemd/system/"
    echo "    sudo systemctl daemon-reload"
    echo "    sudo systemctl enable --now ${SERVICE_NAME}.service"
}

generate_worker_service() {
    prompt SERVICE_NAME "Service name" "worker"
    prompt DESCRIPTION "Description" "Background Worker"
    prompt EXEC_START "ExecStart command" "/usr/bin/${SERVICE_NAME}"
    prompt USER "Run as user" "$SERVICE_NAME"
    prompt ENV_FILE "Environment file path" "/etc/${SERVICE_NAME}/env"
    select_option RESTART_POLICY "Restart policy:" "on-failure" "always" "on-abnormal"
    prompt RESTART_SEC "Restart delay (seconds)" "10"
    select_option HARDENING_LEVEL "Security hardening level:" "minimal" "moderate" "maximum"
    prompt MEMORY_MAX "Memory limit" "512M"

    local outfile="${OUTPUT_DIR}/${SERVICE_NAME}.service"
    cat > "$outfile" << EOF
[Unit]
Description=${DESCRIPTION}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
User=${USER}
Group=${USER}
EnvironmentFile=${ENV_FILE}
EnvironmentFile=-/etc/${SERVICE_NAME}/env.local
ExecStart=${EXEC_START}
Restart=${RESTART_POLICY}
RestartSec=${RESTART_SEC}
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGTERM

# Resource Limits
MemoryMax=${MEMORY_MAX}
TasksMax=128
LimitNOFILE=65536

# Directories
StateDirectory=${SERVICE_NAME}
LogsDirectory=${SERVICE_NAME}

# Security Hardening (${HARDENING_LEVEL})
$(generate_hardening "$HARDENING_LEVEL")

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${GREEN}✓ Generated: ${outfile}${NC}"
}

generate_cron_service() {
    prompt SERVICE_NAME "Service/timer name" "scheduled-task"
    prompt DESCRIPTION "Description" "Scheduled Task"
    prompt EXEC_START "ExecStart command" "/usr/local/bin/${SERVICE_NAME}.sh"
    prompt USER "Run as user" "root"
    prompt ON_CALENDAR "OnCalendar schedule (e.g., daily, *-*-* 02:30:00, *:0/15)" "daily"
    prompt_yn PERSISTENT "Catch up missed runs?" "y"
    prompt RANDOM_DELAY "Random delay (e.g., 5min, 1h)" "5min"

    local timer_file="${OUTPUT_DIR}/${SERVICE_NAME}.timer"
    cat > "$timer_file" << EOF
[Unit]
Description=${DESCRIPTION} Timer

[Timer]
OnCalendar=${ON_CALENDAR}
Persistent=${PERSISTENT}
RandomizedDelaySec=${RANDOM_DELAY}
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

    local service_file="${OUTPUT_DIR}/${SERVICE_NAME}.service"
    cat > "$service_file" << EOF
[Unit]
Description=${DESCRIPTION}

[Service]
Type=oneshot
User=${USER}
ExecStart=${EXEC_START}
Nice=19
IOSchedulingClass=idle

# Security Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
EOF

    echo -e "${GREEN}✓ Generated: ${timer_file}${NC}"
    echo -e "${GREEN}✓ Generated: ${service_file}${NC}"
    echo -e "${BLUE}  Schedule validation:${NC}"
    echo "    systemd-analyze calendar '${ON_CALENDAR}'"
    echo -e "${BLUE}  Enable the timer (not the service):${NC}"
    echo "    sudo systemctl enable --now ${SERVICE_NAME}.timer"
}

# Main
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   systemd Service Unit File Generator    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

mkdir -p "$OUTPUT_DIR"

if [[ -z "$PRESET" ]]; then
    select_option PRESET "Select service type:" "web" "worker" "cron"
fi

case "$PRESET" in
    web)    generate_web_service ;;
    worker) generate_worker_service ;;
    cron)   generate_cron_service ;;
    *)      echo -e "${RED}Unknown preset: ${PRESET}${NC}"; exit 1 ;;
esac
