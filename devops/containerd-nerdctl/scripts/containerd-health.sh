#!/usr/bin/env bash
# containerd-health.sh — Check containerd health: service status, socket, namespaces,
# images, containers, BuildKit, and CNI
#
# Usage: sudo ./containerd-health.sh [--json] [--quiet]
#   --json    Output results as JSON
#   --quiet   Only show failures

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

JSON_OUTPUT=false
QUIET=false
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0
JSON_RESULTS=()

for arg in "$@"; do
    case "$arg" in
        --json)  JSON_OUTPUT=true ;;
        --quiet) QUIET=true ;;
        --help|-h)
            echo "Usage: sudo $0 [--json] [--quiet]"
            echo "  --json    Output results as JSON"
            echo "  --quiet   Only show failures"
            exit 0
            ;;
    esac
done

pass() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    if $JSON_OUTPUT; then
        JSON_RESULTS+=("{\"check\":\"$1\",\"status\":\"pass\",\"detail\":\"$2\"}")
    elif ! $QUIET; then
        echo -e "  ${GREEN}✓${NC} $1: $2"
    fi
}

fail() {
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    if $JSON_OUTPUT; then
        JSON_RESULTS+=("{\"check\":\"$1\",\"status\":\"fail\",\"detail\":\"$2\"}")
    else
        echo -e "  ${RED}✗${NC} $1: $2"
    fi
}

warn_check() {
    CHECKS_WARNED=$((CHECKS_WARNED + 1))
    if $JSON_OUTPUT; then
        JSON_RESULTS+=("{\"check\":\"$1\",\"status\":\"warn\",\"detail\":\"$2\"}")
    elif ! $QUIET; then
        echo -e "  ${YELLOW}!${NC} $1: $2"
    fi
}

header() {
    if ! $JSON_OUTPUT && ! $QUIET; then
        echo ""
        echo -e "${BLUE}=== $1 ===${NC}"
    fi
}

# ─── containerd Service ───────────────────────────────────────────────
check_containerd_service() {
    header "containerd Service"

    # Binary exists
    if command -v containerd &>/dev/null; then
        local ver
        ver=$(containerd --version 2>/dev/null | awk '{print $3}' || echo "unknown")
        pass "containerd binary" "found (${ver})"
    else
        fail "containerd binary" "not found in PATH"
        return
    fi

    # Service status
    if systemctl is-active containerd &>/dev/null; then
        local uptime
        uptime=$(systemctl show containerd --property=ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")
        pass "containerd service" "active (since ${uptime})"
    else
        fail "containerd service" "not running"
    fi

    # Socket
    local sock="/run/containerd/containerd.sock"
    if [[ -S "$sock" ]]; then
        pass "containerd socket" "${sock} exists"
    else
        fail "containerd socket" "${sock} not found"
    fi

    # Config file
    if [[ -f /etc/containerd/config.toml ]]; then
        pass "containerd config" "/etc/containerd/config.toml exists"

        # Check SystemdCgroup
        if grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
            pass "SystemdCgroup" "enabled"
        else
            warn_check "SystemdCgroup" "not enabled (may cause issues on cgroup v2)"
        fi

        # Check config version
        local config_ver
        config_ver=$(grep '^version' /etc/containerd/config.toml 2>/dev/null | awk '{print $3}' || echo "unknown")
        if [[ "$config_ver" == "3" ]]; then
            pass "config version" "v3 (current)"
        elif [[ "$config_ver" == "2" ]]; then
            warn_check "config version" "v2 (consider migrating to v3)"
        else
            warn_check "config version" "${config_ver} (expected 3)"
        fi
    else
        warn_check "containerd config" "/etc/containerd/config.toml not found (using defaults)"
    fi
}

# ─── runc ──────────────────────────────────────────────────────────────
check_runc() {
    header "Container Runtime (runc)"

    if command -v runc &>/dev/null; then
        local ver
        ver=$(runc --version 2>/dev/null | head -1 || echo "unknown")
        pass "runc binary" "${ver}"
    else
        fail "runc binary" "not found in PATH"
    fi
}

# ─── nerdctl ───────────────────────────────────────────────────────────
check_nerdctl() {
    header "nerdctl CLI"

    if command -v nerdctl &>/dev/null; then
        local ver
        ver=$(nerdctl --version 2>/dev/null || echo "unknown")
        pass "nerdctl binary" "${ver}"
    else
        warn_check "nerdctl binary" "not found (optional but recommended)"
        return
    fi

    # nerdctl info
    if nerdctl info &>/dev/null; then
        pass "nerdctl info" "responds successfully"
    else
        fail "nerdctl info" "failed to connect"
    fi
}

# ─── Namespaces ────────────────────────────────────────────────────────
check_namespaces() {
    header "Namespaces"

    if ! command -v ctr &>/dev/null; then
        warn_check "ctr binary" "not found, skipping namespace check"
        return
    fi

    local ns_list
    ns_list=$(ctr namespaces ls -q 2>/dev/null || echo "")
    if [[ -n "$ns_list" ]]; then
        local ns_count
        ns_count=$(echo "$ns_list" | wc -l)
        pass "namespaces" "${ns_count} found ($(echo "$ns_list" | tr '\n' ', ' | sed 's/,$//'))"
    else
        warn_check "namespaces" "none found"
    fi
}

# ─── Images ────────────────────────────────────────────────────────────
check_images() {
    header "Images"

    if ! command -v nerdctl &>/dev/null; then
        return
    fi

    local img_count
    img_count=$(nerdctl images -q 2>/dev/null | wc -l || echo "0")
    pass "images (default ns)" "${img_count} images"

    # Check k8s.io namespace
    local k8s_count
    k8s_count=$(nerdctl --namespace k8s.io images -q 2>/dev/null | wc -l || echo "0")
    if [[ "$k8s_count" -gt 0 ]]; then
        pass "images (k8s.io ns)" "${k8s_count} images"
    fi

    # Check disk usage
    local content_size
    content_size=$(du -sh /var/lib/containerd/io.containerd.content.v1.content/ 2>/dev/null | awk '{print $1}' || echo "unknown")
    pass "content store size" "${content_size}"

    local snapshot_size
    snapshot_size=$(du -sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/ 2>/dev/null | awk '{print $1}' || echo "unknown")
    pass "snapshot store size" "${snapshot_size}"
}

# ─── Containers ────────────────────────────────────────────────────────
check_containers() {
    header "Containers"

    if ! command -v nerdctl &>/dev/null; then
        return
    fi

    local running stopped
    running=$(nerdctl ps -q 2>/dev/null | wc -l || echo "0")
    stopped=$(nerdctl ps -aq 2>/dev/null | wc -l || echo "0")
    stopped=$((stopped - running))

    pass "containers" "${running} running, ${stopped} stopped"

    # Check for containers restarting in a loop
    local restarting
    restarting=$(nerdctl ps --format '{{.Status}}' 2>/dev/null | grep -c "Restarting" || echo "0")
    if [[ "$restarting" -gt 0 ]]; then
        warn_check "restarting containers" "${restarting} containers in restart loop"
    fi
}

# ─── BuildKit ──────────────────────────────────────────────────────────
check_buildkit() {
    header "BuildKit"

    if command -v buildkitd &>/dev/null; then
        local ver
        ver=$(buildkitd --version 2>/dev/null || echo "unknown")
        pass "buildkitd binary" "${ver}"
    else
        warn_check "buildkitd binary" "not found (nerdctl build won't work)"
        return
    fi

    # Service status
    if systemctl is-active buildkit &>/dev/null; then
        pass "buildkit service" "active"
    else
        warn_check "buildkit service" "not running (nerdctl build won't work)"
    fi

    # Socket
    local sock="/run/buildkit/buildkitd.sock"
    if [[ -S "$sock" ]]; then
        pass "buildkit socket" "${sock} exists"
    else
        warn_check "buildkit socket" "${sock} not found"
    fi

    # BuildKit cache size
    if [[ -d /var/lib/buildkit ]]; then
        local cache_size
        cache_size=$(du -sh /var/lib/buildkit/ 2>/dev/null | awk '{print $1}' || echo "unknown")
        pass "buildkit cache" "${cache_size}"
    fi
}

# ─── CNI ───────────────────────────────────────────────────────────────
check_cni() {
    header "CNI Networking"

    # CNI plugins
    if [[ -d /opt/cni/bin ]]; then
        local plugin_count
        plugin_count=$(ls /opt/cni/bin/ 2>/dev/null | wc -l || echo "0")
        if [[ "$plugin_count" -gt 0 ]]; then
            pass "CNI plugins" "${plugin_count} plugins in /opt/cni/bin/"
        else
            fail "CNI plugins" "/opt/cni/bin/ is empty"
        fi
    else
        fail "CNI plugins" "/opt/cni/bin/ directory not found"
    fi

    # CNI config
    if [[ -d /etc/cni/net.d ]]; then
        local config_count
        config_count=$(ls /etc/cni/net.d/*.conf* 2>/dev/null | wc -l || echo "0")
        if [[ "$config_count" -gt 0 ]]; then
            pass "CNI config" "${config_count} configs in /etc/cni/net.d/"
        else
            warn_check "CNI config" "no configs in /etc/cni/net.d/ (will be created on first network use)"
        fi
    else
        warn_check "CNI config dir" "/etc/cni/net.d/ not found"
    fi

    # ip_forward
    local ip_fwd
    ip_fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    if [[ "$ip_fwd" == "1" ]]; then
        pass "ip_forward" "enabled"
    else
        warn_check "ip_forward" "disabled (containers won't have internet access)"
    fi
}

# ─── Rootless ──────────────────────────────────────────────────────────
check_rootless() {
    header "Rootless Support"

    # Check subuid/subgid
    if [[ -f /etc/subuid ]] && [[ -s /etc/subuid ]]; then
        pass "subuid" "configured"
    else
        warn_check "subuid" "/etc/subuid empty or missing (rootless won't work)"
    fi

    # Check uidmap
    if command -v newuidmap &>/dev/null; then
        pass "newuidmap" "found"
    else
        warn_check "newuidmap" "not found (install uidmap package for rootless)"
    fi

    # Check user namespace support
    if [[ -f /proc/sys/kernel/unprivileged_userns_clone ]]; then
        local userns
        userns=$(cat /proc/sys/kernel/unprivileged_userns_clone)
        if [[ "$userns" == "1" ]]; then
            pass "user namespaces" "enabled"
        else
            warn_check "user namespaces" "disabled (set kernel.unprivileged_userns_clone=1)"
        fi
    else
        pass "user namespaces" "not restricted by sysctl"
    fi
}

# ─── Kernel & System ──────────────────────────────────────────────────
check_system() {
    header "System"

    pass "kernel" "$(uname -r)"
    pass "architecture" "$(uname -m)"

    # cgroup version
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        pass "cgroup" "v2 (unified)"
    else
        warn_check "cgroup" "v1 (consider upgrading to v2)"
    fi

    # Overlay filesystem support
    if grep -q overlay /proc/filesystems 2>/dev/null; then
        pass "overlayfs" "supported"
    else
        warn_check "overlayfs" "not found in /proc/filesystems"
    fi

    # Disk space on containerd root
    local avail
    avail=$(df -h /var/lib/containerd/ 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown")
    if [[ "$avail" != "unknown" ]]; then
        pass "disk available" "${avail} on /var/lib/containerd/"
    fi
}

# ─── CRI (Kubernetes) ─────────────────────────────────────────────────
check_cri() {
    header "CRI (Kubernetes)"

    if command -v crictl &>/dev/null; then
        pass "crictl binary" "found"

        if crictl --runtime-endpoint unix:///run/containerd/containerd.sock info &>/dev/null; then
            pass "CRI plugin" "responding"
        else
            warn_check "CRI plugin" "not responding (may be disabled or no kubelet)"
        fi
    else
        warn_check "crictl" "not found (not needed unless running Kubernetes)"
    fi

    if command -v kubelet &>/dev/null; then
        local kubelet_endpoint
        kubelet_endpoint=$(ps aux 2>/dev/null | grep kubelet | grep -o 'container-runtime-endpoint=[^ ]*' | head -1 || echo "")
        if [[ -n "$kubelet_endpoint" ]]; then
            pass "kubelet runtime" "${kubelet_endpoint}"
        else
            warn_check "kubelet runtime" "could not detect runtime endpoint"
        fi
    fi
}

# ─── Run all checks ───────────────────────────────────────────────────
main() {
    if ! $JSON_OUTPUT && ! $QUIET; then
        echo -e "${BLUE}containerd Health Check${NC}"
        echo "─────────────────────────────────"
    fi

    check_containerd_service
    check_runc
    check_nerdctl
    check_namespaces
    check_images
    check_containers
    check_buildkit
    check_cni
    check_rootless
    check_system
    check_cri

    if $JSON_OUTPUT; then
        echo "{"
        echo "  \"summary\": {\"passed\": ${CHECKS_PASSED}, \"failed\": ${CHECKS_FAILED}, \"warnings\": ${CHECKS_WARNED}},"
        echo "  \"results\": ["
        local first=true
        for r in "${JSON_RESULTS[@]}"; do
            if $first; then
                echo "    $r"
                first=false
            else
                echo "    ,$r"
            fi
        done
        echo "  ]"
        echo "}"
    else
        echo ""
        echo "─────────────────────────────────"
        echo -e "  ${GREEN}Passed:${NC}   ${CHECKS_PASSED}"
        echo -e "  ${YELLOW}Warnings:${NC} ${CHECKS_WARNED}"
        echo -e "  ${RED}Failed:${NC}   ${CHECKS_FAILED}"
        echo ""

        if [[ $CHECKS_FAILED -gt 0 ]]; then
            echo -e "${RED}Some checks failed. Review the output above.${NC}"
            exit 1
        elif [[ $CHECKS_WARNED -gt 0 ]]; then
            echo -e "${YELLOW}All checks passed with warnings.${NC}"
        else
            echo -e "${GREEN}All checks passed!${NC}"
        fi
    fi
}

main
