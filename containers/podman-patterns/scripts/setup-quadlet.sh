#!/usr/bin/env bash
# =============================================================================
# setup-quadlet.sh — Generate Quadlet unit files from running Podman containers
#
# Usage:
#   ./setup-quadlet.sh [OPTIONS] [CONTAINER_NAME...]
#
# Options:
#   --all          Generate Quadlet files for all running containers
#   --output DIR   Output directory (default: ~/.config/containers/systemd/)
#   --rootful      Generate for root systemd (/etc/containers/systemd/)
#   --dry-run      Print generated files to stdout without writing
#   --with-volumes Generate .volume unit files for named volumes
#   --with-networks Generate .network unit files for custom networks
#   --help         Show this help message
#
# Examples:
#   ./setup-quadlet.sh webapp                     # Single container
#   ./setup-quadlet.sh --all                      # All running containers
#   ./setup-quadlet.sh --all --with-volumes       # Include volume units
#   ./setup-quadlet.sh --all --dry-run            # Preview without writing
#   ./setup-quadlet.sh --rootful --all            # For system-wide services
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ALL_CONTAINERS=false
DRY_RUN=false
WITH_VOLUMES=false
WITH_NETWORKS=false
ROOTFUL=false
OUTPUT_DIR=""
CONTAINERS=()

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    sed -n '/^# Usage:/,/^# =====/p' "$0" | sed 's/^# //' | head -n -1
    exit 0
}

get_output_dir() {
    if [[ -n "$OUTPUT_DIR" ]]; then
        echo "$OUTPUT_DIR"
    elif $ROOTFUL; then
        echo "/etc/containers/systemd"
    else
        echo "${HOME}/.config/containers/systemd"
    fi
}

generate_container_unit() {
    local ctr_name="$1"
    local unit=""

    # Get container inspect data
    local inspect
    inspect=$(podman inspect "$ctr_name" 2>/dev/null) || {
        log_error "Container not found: $ctr_name"
        return 1
    }

    local image
    image=$(echo "$inspect" | jq -r '.[0].Config.Image // .[0].ImageName // empty')
    if [[ -z "$image" ]]; then
        log_error "Could not determine image for: $ctr_name"
        return 1
    fi

    # Start building the unit file
    unit+="[Unit]\n"
    unit+="Description=${ctr_name} container\n"
    unit+="\n"
    unit+="[Container]\n"
    unit+="Image=${image}\n"
    unit+="ContainerName=${ctr_name}\n"

    # Port mappings
    local ports
    ports=$(echo "$inspect" | jq -r '.[0].HostConfig.PortBindings // {} | to_entries[] | .key as $cport | .value[]? | (if .HostIp != "" and .HostIp != "0.0.0.0" then .HostIp + ":" else "" end) + .HostPort + ":" + $cport' 2>/dev/null || true)
    while IFS= read -r port; do
        [[ -n "$port" ]] && unit+="PublishPort=${port}\n"
    done <<< "$ports"

    # Environment variables (skip common defaults)
    local envs
    envs=$(echo "$inspect" | jq -r '.[0].Config.Env[]? // empty' 2>/dev/null || true)
    while IFS= read -r env; do
        case "$env" in
            PATH=*|HOME=*|HOSTNAME=*|TERM=*|container=*) continue ;;
        esac
        [[ -n "$env" ]] && unit+="Environment=${env}\n"
    done <<< "$envs"

    # Volume mounts
    local mounts
    mounts=$(echo "$inspect" | jq -r '.[0].Mounts[]? | .Source + ":" + .Destination + (if .RW then ":rw" else ":ro" end)' 2>/dev/null || true)
    while IFS= read -r mount; do
        if [[ -n "$mount" ]]; then
            # Convert named volume paths to volume references
            local vol_name
            vol_name=$(echo "$inspect" | jq -r --arg dst "$(echo "$mount" | cut -d: -f2)" '.[0].Mounts[]? | select(.Destination == $dst) | .Name // empty' 2>/dev/null || true)
            if [[ -n "$vol_name" ]]; then
                local dst rw_flag
                dst=$(echo "$mount" | cut -d: -f2)
                rw_flag=$(echo "$mount" | cut -d: -f3)
                unit+="Volume=${vol_name}.volume:${dst}:${rw_flag}\n"
            else
                unit+="Volume=${mount}\n"
            fi
        fi
    done <<< "$mounts"

    # Network
    local networks
    networks=$(echo "$inspect" | jq -r '.[0].NetworkSettings.Networks // {} | keys[]' 2>/dev/null || true)
    while IFS= read -r net; do
        [[ "$net" == "podman" || -z "$net" ]] && continue
        unit+="Network=${net}.network\n"
    done <<< "$networks"

    # Restart policy
    local restart_policy
    restart_policy=$(echo "$inspect" | jq -r '.[0].HostConfig.RestartPolicy.Name // empty' 2>/dev/null || true)

    # Labels for auto-update
    local autoupdate
    autoupdate=$(echo "$inspect" | jq -r '.[0].Config.Labels["io.containers.autoupdate"] // empty' 2>/dev/null || true)
    [[ -n "$autoupdate" ]] && unit+="AutoUpdate=${autoupdate}\n"

    # Health check
    local health_cmd
    health_cmd=$(echo "$inspect" | jq -r '.[0].Config.Healthcheck.Test | if type == "array" then .[1:] | join(" ") else empty end' 2>/dev/null || true)
    if [[ -n "$health_cmd" ]]; then
        unit+="HealthCmd=${health_cmd}\n"
        local interval retries start timeout
        interval=$(echo "$inspect" | jq -r '.[0].Config.Healthcheck.Interval // empty' 2>/dev/null || true)
        retries=$(echo "$inspect" | jq -r '.[0].Config.Healthcheck.Retries // empty' 2>/dev/null || true)
        start=$(echo "$inspect" | jq -r '.[0].Config.Healthcheck.StartPeriod // empty' 2>/dev/null || true)
        timeout=$(echo "$inspect" | jq -r '.[0].Config.Healthcheck.Timeout // empty' 2>/dev/null || true)
        [[ -n "$interval" && "$interval" != "0" ]] && unit+="HealthInterval=$(( interval / 1000000000 ))s\n"
        [[ -n "$retries" && "$retries" != "0" ]] && unit+="HealthRetries=${retries}\n"
        [[ -n "$start" && "$start" != "0" ]] && unit+="HealthStartPeriod=$(( start / 1000000000 ))s\n"
        [[ -n "$timeout" && "$timeout" != "0" ]] && unit+="HealthTimeout=$(( timeout / 1000000000 ))s\n"
    fi

    # User
    local user
    user=$(echo "$inspect" | jq -r '.[0].Config.User // empty' 2>/dev/null || true)
    [[ -n "$user" ]] && unit+="User=${user}\n"

    # Working directory
    local workdir
    workdir=$(echo "$inspect" | jq -r '.[0].Config.WorkingDir // empty' 2>/dev/null || true)
    [[ -n "$workdir" && "$workdir" != "/" ]] && unit+="WorkingDir=${workdir}\n"

    unit+="\n"
    unit+="[Service]\n"
    case "$restart_policy" in
        always|unless-stopped) unit+="Restart=always\n" ;;
        on-failure) unit+="Restart=on-failure\n" ;;
        *) unit+="Restart=on-failure\n" ;;
    esac
    unit+="TimeoutStartSec=120\n"

    unit+="\n"
    unit+="[Install]\n"
    if $ROOTFUL; then
        unit+="WantedBy=multi-user.target\n"
    else
        unit+="WantedBy=default.target\n"
    fi

    echo -e "$unit"
}

generate_volume_unit() {
    local vol_name="$1"
    local unit=""

    local inspect
    inspect=$(podman volume inspect "$vol_name" 2>/dev/null) || {
        log_error "Volume not found: $vol_name"
        return 1
    }

    unit+="[Unit]\n"
    unit+="Description=${vol_name} volume\n"
    unit+="\n"
    unit+="[Volume]\n"
    unit+="VolumeName=${vol_name}\n"

    # Labels
    local labels
    labels=$(echo "$inspect" | jq -r '.[0].Labels // {} | to_entries[] | .key + "=" + .value' 2>/dev/null || true)
    while IFS= read -r label; do
        [[ -n "$label" ]] && unit+="Label=${label}\n"
    done <<< "$labels"

    echo -e "$unit"
}

generate_network_unit() {
    local net_name="$1"
    local unit=""

    local inspect
    inspect=$(podman network inspect "$net_name" 2>/dev/null) || {
        log_error "Network not found: $net_name"
        return 1
    }

    unit+="[Unit]\n"
    unit+="Description=${net_name} network\n"
    unit+="\n"
    unit+="[Network]\n"
    unit+="NetworkName=${net_name}\n"

    # Subnets
    local subnets
    subnets=$(echo "$inspect" | jq -r '.[0].subnets[]? | .subnet' 2>/dev/null || true)
    while IFS= read -r subnet; do
        [[ -n "$subnet" ]] && unit+="Subnet=${subnet}\n"
    done <<< "$subnets"

    # Gateways
    local gateways
    gateways=$(echo "$inspect" | jq -r '.[0].subnets[]? | .gateway // empty' 2>/dev/null || true)
    while IFS= read -r gw; do
        [[ -n "$gw" ]] && unit+="Gateway=${gw}\n"
    done <<< "$gateways"

    # DNS enabled
    local dns_enabled
    dns_enabled=$(echo "$inspect" | jq -r '.[0].dns_enabled // empty' 2>/dev/null || true)
    [[ "$dns_enabled" == "true" ]] && unit+="DNSEnabled=true\n"

    # Internal
    local internal
    internal=$(echo "$inspect" | jq -r '.[0].internal // empty' 2>/dev/null || true)
    [[ "$internal" == "true" ]] && unit+="Internal=true\n"

    echo -e "$unit"
}

write_unit_file() {
    local filename="$1"
    local content="$2"
    local outdir
    outdir=$(get_output_dir)

    if $DRY_RUN; then
        echo "--- ${filename} ---"
        echo -e "$content"
        echo ""
        return
    fi

    mkdir -p "$outdir"
    local filepath="${outdir}/${filename}"

    if [[ -f "$filepath" ]]; then
        log_warn "File exists, backing up: ${filepath}"
        cp "$filepath" "${filepath}.bak.$(date +%s)"
    fi

    echo -e "$content" > "$filepath"
    log_ok "Created: ${filepath}"
}

# --- Parse arguments ---
if [[ $# -eq 0 ]]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)           ALL_CONTAINERS=true ;;
        --output)        OUTPUT_DIR="$2"; shift ;;
        --rootful)       ROOTFUL=true ;;
        --dry-run)       DRY_RUN=true ;;
        --with-volumes)  WITH_VOLUMES=true ;;
        --with-networks) WITH_NETWORKS=true ;;
        --help|-h)       usage ;;
        -*)              log_error "Unknown option: $1"; usage ;;
        *)               CONTAINERS+=("$1") ;;
    esac
    shift
done

# --- Main ---
echo "============================================"
echo "  Quadlet Unit File Generator"
echo "============================================"
$DRY_RUN && log_warn "DRY RUN MODE — files will be printed to stdout"

if ! command -v podman &>/dev/null; then
    log_error "Podman is not installed"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    exit 1
fi

# Collect container names
if $ALL_CONTAINERS; then
    mapfile -t CONTAINERS < <(podman ps --format '{{.Names}}')
    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        log_warn "No running containers found"
        exit 0
    fi
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    log_error "No containers specified. Use --all or provide container names."
    usage
fi

log_info "Processing ${#CONTAINERS[@]} container(s)..."

# Track volumes and networks for additional unit generation
declare -A SEEN_VOLUMES
declare -A SEEN_NETWORKS

for ctr in "${CONTAINERS[@]}"; do
    log_info "Generating Quadlet for: $ctr"

    unit_content=$(generate_container_unit "$ctr") || continue
    write_unit_file "${ctr}.container" "$unit_content"

    # Collect volumes
    if $WITH_VOLUMES; then
        local_vols=$(podman inspect "$ctr" 2>/dev/null | jq -r '.[0].Mounts[]? | select(.Name != null and .Name != "") | .Name' || true)
        while IFS= read -r v; do
            [[ -n "$v" ]] && SEEN_VOLUMES["$v"]=1
        done <<< "$local_vols"
    fi

    # Collect networks
    if $WITH_NETWORKS; then
        local_nets=$(podman inspect "$ctr" 2>/dev/null | jq -r '.[0].NetworkSettings.Networks // {} | keys[]' || true)
        while IFS= read -r n; do
            [[ "$n" == "podman" || -z "$n" ]] && continue
            SEEN_NETWORKS["$n"]=1
        done <<< "$local_nets"
    fi
done

# Generate volume units
if $WITH_VOLUMES && [[ ${#SEEN_VOLUMES[@]} -gt 0 ]]; then
    log_info "Generating volume units..."
    for vol in "${!SEEN_VOLUMES[@]}"; do
        vol_content=$(generate_volume_unit "$vol") || continue
        write_unit_file "${vol}.volume" "$vol_content"
    done
fi

# Generate network units
if $WITH_NETWORKS && [[ ${#SEEN_NETWORKS[@]} -gt 0 ]]; then
    log_info "Generating network units..."
    for net in "${!SEEN_NETWORKS[@]}"; do
        net_content=$(generate_network_unit "$net") || continue
        write_unit_file "${net}.network" "$net_content"
    done
fi

echo ""
log_ok "Quadlet generation complete!"
log_info "Next steps:"
outdir=$(get_output_dir)
echo "  1. Review generated files in: $outdir"
if $ROOTFUL; then
    echo "  2. Reload: sudo systemctl daemon-reload"
    echo "  3. Start:  sudo systemctl start <name>"
    echo "  4. Enable: sudo systemctl enable <name>"
else
    echo "  2. Reload: systemctl --user daemon-reload"
    echo "  3. Start:  systemctl --user start <name>"
    echo "  4. Enable: systemctl --user enable <name>"
fi
echo "  5. Stop existing containers first to avoid port conflicts"
