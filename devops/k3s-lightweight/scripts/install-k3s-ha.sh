#!/usr/bin/env bash
#
# install-k3s-ha.sh — Set up a 3-node K3s HA cluster with embedded etcd
#
# Usage:
#   # On the first server (init):
#   ./install-k3s-ha.sh --role init --token <TOKEN> --tls-san <LB_IP_OR_HOSTNAME>
#
#   # On additional servers (join):
#   ./install-k3s-ha.sh --role join --token <TOKEN> --server <FIRST_SERVER_IP> --tls-san <LB_IP_OR_HOSTNAME>
#
#   # On agent nodes:
#   ./install-k3s-ha.sh --role agent --token <TOKEN> --server <LB_IP_OR_HOSTNAME>
#
# Options:
#   --role <init|join|agent>    Node role (required)
#   --token <TOKEN>             Shared cluster token (required)
#   --server <IP_OR_HOSTNAME>   Server address to join (required for join/agent)
#   --tls-san <SAN>             TLS Subject Alternative Name (repeatable)
#   --version <VERSION>         K3s version (e.g., v1.30.2+k3s1)
#   --disable <COMPONENT>       Disable a component (repeatable: traefik, servicelb, etc.)
#   --config <FILE>             Path to additional config.yaml to merge
#   --dry-run                   Print the install command without executing
#   -h, --help                  Show this help message

set -euo pipefail

# --- Defaults ---
ROLE=""
TOKEN=""
SERVER=""
TLS_SANS=()
K3S_VERSION=""
DISABLE_COMPONENTS=()
EXTRA_CONFIG=""
DRY_RUN=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    sed -n '3,18p' "$0" | sed 's/^#\s\?//'
    exit 0
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)       ROLE="$2"; shift 2 ;;
        --token)      TOKEN="$2"; shift 2 ;;
        --server)     SERVER="$2"; shift 2 ;;
        --tls-san)    TLS_SANS+=("$2"); shift 2 ;;
        --version)    K3S_VERSION="$2"; shift 2 ;;
        --disable)    DISABLE_COMPONENTS+=("$2"); shift 2 ;;
        --config)     EXTRA_CONFIG="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage ;;
        *)            log_error "Unknown option: $1"; usage ;;
    esac
done

# --- Validate ---
if [[ -z "$ROLE" ]]; then
    log_error "--role is required (init, join, or agent)"
    exit 1
fi

if [[ -z "$TOKEN" ]]; then
    log_error "--token is required"
    exit 1
fi

if [[ "$ROLE" == "join" || "$ROLE" == "agent" ]] && [[ -z "$SERVER" ]]; then
    log_error "--server is required for role '$ROLE'"
    exit 1
fi

# --- Pre-flight Checks ---
preflight_checks() {
    log_info "Running pre-flight checks..."

    # Check root/sudo
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi

    # Check connectivity (unless air-gap)
    if curl -sfL --max-time 5 https://get.k3s.io > /dev/null 2>&1; then
        log_info "Internet connectivity: OK"
    else
        log_warn "Cannot reach https://get.k3s.io — ensure air-gap binaries are available"
    fi

    # Check required ports
    local ports_to_check=(6443 9345)
    if [[ "$ROLE" == "init" || "$ROLE" == "join" ]]; then
        ports_to_check+=(2379 2380 8472 10250)
    fi
    for port in "${ports_to_check[@]}"; do
        if ss -tlnp | grep -q ":${port} "; then
            log_warn "Port $port is already in use"
        fi
    done

    # Check kernel modules
    for mod in br_netfilter overlay; do
        if ! lsmod | grep -q "^${mod}"; then
            modprobe "$mod" 2>/dev/null || log_warn "Kernel module '$mod' not loaded"
        fi
    done

    # Check system resources
    local mem_mb
    mem_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    if [[ "$mem_mb" -lt 512 ]]; then
        log_warn "Low memory: ${mem_mb} MB (minimum 512 MB recommended)"
    else
        log_info "Memory: ${mem_mb} MB"
    fi

    log_info "Pre-flight checks complete"
}

# --- Generate Config ---
generate_config() {
    local config_dir="/etc/rancher/k3s"
    mkdir -p "$config_dir"

    local config_file="${config_dir}/config.yaml"
    log_info "Generating config: $config_file"

    {
        echo "token: \"${TOKEN}\""
        echo "write-kubeconfig-mode: \"0644\""

        # TLS SANs
        if [[ ${#TLS_SANS[@]} -gt 0 ]]; then
            echo "tls-san:"
            for san in "${TLS_SANS[@]}"; do
                echo "  - \"${san}\""
            done
        fi

        # Role-specific config
        case "$ROLE" in
            init)
                echo "cluster-init: true"
                echo ""
                echo "# etcd snapshot configuration"
                echo "etcd-snapshot-schedule-cron: \"0 */6 * * *\""
                echo "etcd-snapshot-retention: 10"
                echo "etcd-snapshot-compress: true"
                ;;
            join)
                echo "server: \"https://${SERVER}:6443\""
                echo ""
                echo "# etcd snapshot configuration"
                echo "etcd-snapshot-schedule-cron: \"0 */6 * * *\""
                echo "etcd-snapshot-retention: 10"
                echo "etcd-snapshot-compress: true"
                ;;
            agent)
                echo "server: \"https://${SERVER}:6443\""
                ;;
        esac

        # Disabled components
        if [[ ${#DISABLE_COMPONENTS[@]} -gt 0 ]]; then
            echo ""
            echo "disable:"
            for comp in "${DISABLE_COMPONENTS[@]}"; do
                echo "  - ${comp}"
            done
        fi

        # Node labels
        echo ""
        echo "node-label:"
        echo "  - \"k3s-role=${ROLE}\""

    } > "$config_file"

    # Merge extra config if provided
    if [[ -n "$EXTRA_CONFIG" && -f "$EXTRA_CONFIG" ]]; then
        log_info "Merging extra config from: $EXTRA_CONFIG"
        echo "" >> "$config_file"
        echo "# --- Merged from ${EXTRA_CONFIG} ---" >> "$config_file"
        cat "$EXTRA_CONFIG" >> "$config_file"
    fi

    log_info "Config written to $config_file"
    echo "---"
    cat "$config_file"
    echo "---"
}

# --- Install K3s ---
install_k3s() {
    local install_env=()

    if [[ -n "$K3S_VERSION" ]]; then
        install_env+=("INSTALL_K3S_VERSION=${K3S_VERSION}")
    else
        install_env+=("INSTALL_K3S_CHANNEL=stable")
    fi

    local install_exec=""
    case "$ROLE" in
        init|join) install_exec="server" ;;
        agent)     install_exec="agent" ;;
    esac

    install_env+=("INSTALL_K3S_EXEC=${install_exec}")

    # Check for air-gap binary
    if [[ -f /usr/local/bin/k3s ]]; then
        log_info "K3s binary already present, using INSTALL_K3S_SKIP_DOWNLOAD=true"
        install_env+=("INSTALL_K3S_SKIP_DOWNLOAD=true")
    fi

    local cmd="curl -sfL https://get.k3s.io | ${install_env[*]} sh -"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would execute:"
        echo "  $cmd"
        return 0
    fi

    log_info "Installing K3s (role=$ROLE)..."
    env "${install_env[@]}" sh -c 'curl -sfL https://get.k3s.io | sh -'
}

# --- Post-Install Verification ---
verify_install() {
    local service_name="k3s"
    if [[ "$ROLE" == "agent" ]]; then
        service_name="k3s-agent"
    fi

    log_info "Waiting for ${service_name} to start..."
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if systemctl is-active --quiet "$service_name"; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done

    if systemctl is-active --quiet "$service_name"; then
        log_info "${service_name} is running"
    else
        log_error "${service_name} failed to start. Check: journalctl -u ${service_name} -f"
        exit 1
    fi

    # Server-specific checks
    if [[ "$ROLE" != "agent" ]]; then
        log_info "Waiting for node to be Ready..."
        local node_retries=60
        while [[ $node_retries -gt 0 ]]; do
            if k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; then
                break
            fi
            sleep 5
            node_retries=$((node_retries - 1))
        done

        log_info "Cluster nodes:"
        k3s kubectl get nodes -o wide

        log_info "System pods:"
        k3s kubectl get pods -A

        if [[ "$ROLE" == "init" ]]; then
            echo ""
            log_info "=== HA Cluster Initialized ==="
            log_info "Join additional servers with:"
            echo "  ./install-k3s-ha.sh --role join --token '${TOKEN}' --server $(hostname -I | awk '{print $1}') --tls-san <LB_IP>"
            echo ""
            log_info "Join agent nodes with:"
            echo "  ./install-k3s-ha.sh --role agent --token '${TOKEN}' --server <LB_IP>"
        fi
    fi
}

# --- Main ---
main() {
    log_info "K3s HA Installer — role=${ROLE}"
    echo ""

    preflight_checks
    generate_config
    install_k3s

    if [[ "$DRY_RUN" != "true" ]]; then
        verify_install
    fi

    echo ""
    log_info "Done."
}

main
