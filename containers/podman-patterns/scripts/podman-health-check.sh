#!/usr/bin/env bash
# =============================================================================
# podman-health-check.sh — Check Podman installation, storage, and networking health
#
# Usage:
#   ./podman-health-check.sh [OPTIONS]
#
# Options:
#   --full         Run all checks (default)
#   --quick        Run only essential checks
#   --fix          Attempt to fix common issues
#   --json         Output results as JSON
#   --help         Show this help message
#
# Checks performed:
#   - Podman installation and version
#   - Runtime (crun/runc) availability
#   - Storage driver and configuration
#   - Rootless prerequisites (subuid/subgid, user namespaces)
#   - Network backend (Netavark/CNI)
#   - DNS resolver (Aardvark-DNS)
#   - Pasta/slirp4netns for rootless networking
#   - Cgroup version and delegation
#   - SELinux status
#   - Podman machine status (if applicable)
#   - Disk space for container storage
#   - Socket availability
#
# Examples:
#   ./podman-health-check.sh
#   ./podman-health-check.sh --quick
#   ./podman-health-check.sh --fix
#   ./podman-health-check.sh --json
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

MODE="full"
FIX_MODE=false
JSON_OUTPUT=false
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
RESULTS=()

check_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    RESULTS+=("{\"check\":\"$1\",\"status\":\"pass\",\"detail\":\"$2\"}")
    $JSON_OUTPUT || echo -e "  ${GREEN}✓${NC} $1: $2"
}

check_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    RESULTS+=("{\"check\":\"$1\",\"status\":\"warn\",\"detail\":\"$2\"}")
    $JSON_OUTPUT || echo -e "  ${YELLOW}⚠${NC} $1: $2"
}

check_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULTS+=("{\"check\":\"$1\",\"status\":\"fail\",\"detail\":\"$2\"}")
    $JSON_OUTPUT || echo -e "  ${RED}✗${NC} $1: $2"
}

section() {
    $JSON_OUTPUT || echo -e "\n${BOLD}$1${NC}"
}

# --- Check Functions ---

check_podman_install() {
    section "Podman Installation"

    if command -v podman &>/dev/null; then
        local version
        version=$(podman --version 2>/dev/null | awk '{print $NF}')
        check_pass "Podman installed" "version $version"

        # Check for major version
        local major
        major=$(echo "$version" | cut -d. -f1)
        if [[ "$major" -ge 5 ]]; then
            check_pass "Podman version" "5.x series (current)"
        elif [[ "$major" -ge 4 ]]; then
            check_warn "Podman version" "4.x series — consider upgrading to 5.x"
        else
            check_warn "Podman version" "$version — significantly outdated"
        fi
    else
        check_fail "Podman installed" "podman not found in PATH"
        return
    fi

    # Check runtime
    if command -v crun &>/dev/null; then
        check_pass "Container runtime" "crun $(crun --version 2>/dev/null | head -1 | awk '{print $NF}' || echo 'available')"
    elif command -v runc &>/dev/null; then
        check_pass "Container runtime" "runc (consider switching to crun for better performance)"
    else
        check_fail "Container runtime" "Neither crun nor runc found"
    fi

    # Check conmon
    if command -v conmon &>/dev/null; then
        check_pass "Container monitor" "conmon available"
    else
        check_warn "Container monitor" "conmon not in PATH (may be bundled)"
    fi
}

check_storage() {
    section "Storage"

    local driver
    driver=$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo "unknown")
    case "$driver" in
        overlay)
            check_pass "Storage driver" "overlay (native, optimal)"
            ;;
        fuse-overlayfs)
            check_pass "Storage driver" "fuse-overlayfs (rootless fallback)"
            ;;
        vfs)
            check_warn "Storage driver" "vfs (slow, no copy-on-write — check overlay support)"
            ;;
        *)
            check_warn "Storage driver" "$driver"
            ;;
    esac

    # Check storage path
    local store_path
    store_path=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "unknown")
    check_pass "Storage location" "$store_path"

    # Check disk space
    if [[ -d "$store_path" ]]; then
        local avail_kb
        avail_kb=$(df -k "$store_path" 2>/dev/null | awk 'NR==2 {print $4}')
        if [[ -n "$avail_kb" ]]; then
            local avail_gb=$((avail_kb / 1048576))
            if [[ $avail_gb -ge 20 ]]; then
                check_pass "Available disk space" "${avail_gb}GB free"
            elif [[ $avail_gb -ge 5 ]]; then
                check_warn "Available disk space" "${avail_gb}GB free — consider cleanup"
            else
                check_fail "Available disk space" "${avail_gb}GB free — critically low!"
            fi
        fi
    fi

    # Check image/container counts
    local image_count container_count
    image_count=$(podman images -q 2>/dev/null | wc -l)
    container_count=$(podman ps -aq 2>/dev/null | wc -l)
    check_pass "Resources" "${image_count} images, ${container_count} containers"

    # Check for dangling images
    local dangling
    dangling=$(podman images -f dangling=true -q 2>/dev/null | wc -l)
    if [[ $dangling -gt 10 ]]; then
        check_warn "Dangling images" "${dangling} — run 'podman image prune' to clean up"
    elif [[ $dangling -gt 0 ]]; then
        check_pass "Dangling images" "${dangling} (minor)"
    fi
}

check_rootless() {
    section "Rootless Configuration"

    if [[ $EUID -eq 0 ]]; then
        check_pass "Running as" "root (rootful mode)"
        return
    fi

    check_pass "Running as" "$(whoami) (UID $EUID) — rootless mode"

    # Check subuid/subgid
    if grep -q "^$(whoami):" /etc/subuid 2>/dev/null; then
        local subuid_range
        subuid_range=$(grep "^$(whoami):" /etc/subuid | head -1)
        check_pass "subuid mapping" "$subuid_range"
    else
        check_fail "subuid mapping" "No entry for $(whoami) in /etc/subuid"
        if $FIX_MODE; then
            echo "    → Fix: sudo usermod --add-subuids 100000-165535 $(whoami)"
        fi
    fi

    if grep -q "^$(whoami):" /etc/subgid 2>/dev/null; then
        local subgid_range
        subgid_range=$(grep "^$(whoami):" /etc/subgid | head -1)
        check_pass "subgid mapping" "$subgid_range"
    else
        check_fail "subgid mapping" "No entry for $(whoami) in /etc/subgid"
        if $FIX_MODE; then
            echo "    → Fix: sudo usermod --add-subgids 100000-165535 $(whoami)"
        fi
    fi

    # Check user namespaces
    local max_ns
    max_ns=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo "0")
    if [[ "$max_ns" -gt 0 ]]; then
        check_pass "User namespaces" "enabled (max: $max_ns)"
    else
        check_fail "User namespaces" "disabled"
        if $FIX_MODE; then
            echo "    → Fix: echo 28633 | sudo tee /proc/sys/user/max_user_namespaces"
        fi
    fi

    # Check newuidmap/newgidmap
    for cmd in newuidmap newgidmap; do
        if command -v "$cmd" &>/dev/null; then
            if [[ -u "$(command -v "$cmd")" ]] || getcap "$(command -v "$cmd")" 2>/dev/null | grep -q cap_set; then
                check_pass "$cmd" "available with proper permissions"
            else
                check_warn "$cmd" "available but may lack setuid/capabilities"
            fi
        else
            check_fail "$cmd" "not found"
        fi
    done

    # Check unprivileged ports
    local unpriv_port
    unpriv_port=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo "1024")
    if [[ "$unpriv_port" -eq 0 ]]; then
        check_pass "Unprivileged ports" "all ports available (start: 0)"
    elif [[ "$unpriv_port" -le 80 ]]; then
        check_pass "Unprivileged ports" "ports >= $unpriv_port available"
    else
        check_warn "Unprivileged ports" "ports >= $unpriv_port only (set to 0 for ports 80/443)"
        if $FIX_MODE; then
            echo "    → Fix: echo 0 | sudo tee /proc/sys/net/ipv4/ip_unprivileged_port_start"
        fi
    fi

    # Check linger
    local linger
    linger=$(loginctl show-user "$(whoami)" --property=Linger 2>/dev/null | cut -d= -f2 || echo "unknown")
    if [[ "$linger" == "yes" ]]; then
        check_pass "Linger enabled" "systemd services persist after logout"
    else
        check_warn "Linger disabled" "systemd services stop on logout"
        if $FIX_MODE; then
            echo "    → Fix: loginctl enable-linger $(whoami)"
        fi
    fi
}

check_networking() {
    section "Networking"

    local backend
    backend=$(podman info --format '{{.Host.NetworkBackendInfo.Backend}}' 2>/dev/null || echo "unknown")
    case "$backend" in
        netavark)
            check_pass "Network backend" "Netavark (modern, recommended)"
            ;;
        cni)
            check_warn "Network backend" "CNI (legacy — consider migrating to Netavark)"
            ;;
        *)
            check_warn "Network backend" "$backend"
            ;;
    esac

    # DNS backend
    local dns
    dns=$(podman info --format '{{.Host.NetworkBackendInfo.DNS}}' 2>/dev/null || echo "unknown")
    if [[ "$dns" == *"aardvark"* ]]; then
        check_pass "DNS backend" "Aardvark-DNS"
    else
        check_warn "DNS backend" "$dns"
    fi

    # Rootless network mode
    if [[ $EUID -ne 0 ]]; then
        if command -v pasta &>/dev/null; then
            check_pass "Rootless networking" "pasta available (recommended)"
        elif command -v slirp4netns &>/dev/null; then
            check_warn "Rootless networking" "slirp4netns only — install passt for better performance"
        else
            check_fail "Rootless networking" "neither pasta nor slirp4netns found"
        fi
    fi

    # Check network connectivity
    if podman run --rm docker.io/library/alpine:latest ping -c1 -W3 8.8.8.8 &>/dev/null; then
        check_pass "Network connectivity" "outbound networking works"
    else
        check_warn "Network connectivity" "could not verify (may need image pull)"
    fi
}

check_cgroups() {
    section "Cgroups"

    local cgroup_version
    cgroup_version=$(podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null || echo "unknown")
    case "$cgroup_version" in
        v2)
            check_pass "Cgroup version" "v2 (modern, full feature support)"
            ;;
        v1)
            check_warn "Cgroup version" "v1 (legacy — some features limited)"
            ;;
        *)
            check_warn "Cgroup version" "$cgroup_version"
            ;;
    esac

    # Check cgroup manager
    local cgroup_mgr
    cgroup_mgr=$(podman info --format '{{.Host.CgroupManager}}' 2>/dev/null || echo "unknown")
    if [[ "$cgroup_mgr" == "systemd" ]]; then
        check_pass "Cgroup manager" "systemd (recommended)"
    else
        check_warn "Cgroup manager" "$cgroup_mgr (systemd recommended)"
    fi

    # Check delegation for rootless
    if [[ $EUID -ne 0 && "$cgroup_version" == "v2" ]]; then
        local controllers
        controllers=$(cat "/sys/fs/cgroup/user.slice/user-${EUID}.slice/user@${EUID}.service/cgroup.controllers" 2>/dev/null || echo "")
        if echo "$controllers" | grep -q "memory"; then
            check_pass "Cgroup delegation" "memory controller delegated"
        else
            check_warn "Cgroup delegation" "memory controller not delegated — resource limits may not work"
            if $FIX_MODE; then
                echo "    → Fix: Create /etc/systemd/system/user@.service.d/delegate.conf with Delegate=cpu cpuset io memory pids"
            fi
        fi
    fi
}

check_selinux() {
    section "SELinux"

    if command -v getenforce &>/dev/null; then
        local status
        status=$(getenforce 2>/dev/null || echo "unknown")
        case "$status" in
            Enforcing)
                check_pass "SELinux" "Enforcing (use :Z/:z on volume mounts)"
                ;;
            Permissive)
                check_warn "SELinux" "Permissive (not enforcing, consider enabling)"
                ;;
            Disabled)
                check_pass "SELinux" "Disabled (no :Z/:z needed on volumes)"
                ;;
            *)
                check_warn "SELinux" "$status"
                ;;
        esac
    else
        check_pass "SELinux" "Not installed (AppArmor or none)"
    fi
}

check_machine() {
    section "Podman Machine"

    # Only relevant on macOS/Windows or when machines exist
    local machines
    machines=$(podman machine ls --format '{{.Name}} {{.Running}} {{.CPUs}} {{.Memory}} {{.DiskSize}}' 2>/dev/null || echo "")

    if [[ -z "$machines" ]]; then
        check_pass "Podman machine" "Not using Podman machines (native Linux)"
        return
    fi

    while IFS=' ' read -r name running cpus memory disk; do
        [[ -z "$name" ]] && continue
        if [[ "$running" == "true" || "$running" == "Currently" ]]; then
            check_pass "Machine: $name" "Running — CPUs: $cpus, Memory: $memory, Disk: $disk"
        else
            check_warn "Machine: $name" "Stopped — start with: podman machine start $name"
        fi
    done <<< "$machines"
}

check_socket() {
    section "API Socket"

    local socket_path
    if [[ $EUID -eq 0 ]]; then
        socket_path="/run/podman/podman.sock"
    else
        socket_path="/run/user/${EUID}/podman/podman.sock"
    fi

    if [[ -S "$socket_path" ]]; then
        check_pass "Podman socket" "Active at $socket_path"
    else
        check_warn "Podman socket" "Not active — enable with: systemctl --user enable --now podman.socket"
    fi
}

print_summary() {
    if $JSON_OUTPUT; then
        echo "{"
        echo "  \"pass\": $PASS_COUNT,"
        echo "  \"warn\": $WARN_COUNT,"
        echo "  \"fail\": $FAIL_COUNT,"
        echo "  \"checks\": [$(IFS=,; echo "${RESULTS[*]}")]"
        echo "}"
        return
    fi

    echo ""
    echo "============================================"
    echo -e "  ${GREEN}✓ $PASS_COUNT passed${NC}  ${YELLOW}⚠ $WARN_COUNT warnings${NC}  ${RED}✗ $FAIL_COUNT failed${NC}"
    echo "============================================"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "\n${RED}Some checks failed. Run with --fix for remediation suggestions.${NC}"
    elif [[ $WARN_COUNT -gt 0 ]]; then
        echo -e "\n${YELLOW}Some warnings found. Review and address if needed.${NC}"
    else
        echo -e "\n${GREEN}All checks passed! Podman is healthy.${NC}"
    fi
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)    MODE="full" ;;
        --quick)   MODE="quick" ;;
        --fix)     FIX_MODE=true ;;
        --json)    JSON_OUTPUT=true ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# =====/p' "$0" | sed 's/^# //' | head -n -1
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# --- Main ---
$JSON_OUTPUT || echo "============================================"
$JSON_OUTPUT || echo "  Podman Health Check"
$JSON_OUTPUT || echo "============================================"

check_podman_install

case "$MODE" in
    full)
        check_storage
        check_rootless
        check_networking
        check_cgroups
        check_selinux
        check_machine
        check_socket
        ;;
    quick)
        check_storage
        check_rootless
        check_networking
        ;;
esac

print_summary
