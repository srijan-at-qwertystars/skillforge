#!/usr/bin/env bash
#
# k3s-health-check.sh — Comprehensive K3s cluster health check
#
# Usage:
#   ./k3s-health-check.sh [--json] [--quiet]
#
# Options:
#   --json     Output results as JSON
#   --quiet    Only output failures and summary
#   -h,--help  Show this help

set -euo pipefail

# --- Defaults ---
JSON_OUTPUT=false
QUIET=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Counters ---
PASS=0
WARN=0
FAIL=0
CHECKS=()

# --- Parse Args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)  JSON_OUTPUT=true; shift ;;
        --quiet) QUIET=true; shift ;;
        -h|--help)
            sed -n '3,10p' "$0" | sed 's/^#\s\?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Helpers ---
KUBECTL="k3s kubectl"
if ! command -v k3s &>/dev/null; then
    if command -v kubectl &>/dev/null; then
        KUBECTL="kubectl"
    else
        echo "ERROR: k3s or kubectl not found"
        exit 1
    fi
fi

record_check() {
    local name="$1" status="$2" detail="$3"
    CHECKS+=("${name}|${status}|${detail}")
    case "$status" in
        PASS) PASS=$((PASS + 1))
              if [[ "$QUIET" == "false" && "$JSON_OUTPUT" == "false" ]]; then
                  echo -e "  ${GREEN}✓${NC} ${name}: ${detail}"
              fi
              ;;
        WARN) WARN=$((WARN + 1))
              if [[ "$JSON_OUTPUT" == "false" ]]; then
                  echo -e "  ${YELLOW}⚠${NC} ${name}: ${detail}"
              fi
              ;;
        FAIL) FAIL=$((FAIL + 1))
              if [[ "$JSON_OUTPUT" == "false" ]]; then
                  echo -e "  ${RED}✗${NC} ${name}: ${detail}"
              fi
              ;;
    esac
}

section() {
    if [[ "$QUIET" == "false" && "$JSON_OUTPUT" == "false" ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}[$1]${NC}"
    fi
}

# --- Checks ---

check_k3s_service() {
    section "K3s Service"

    # Determine if this is a server or agent
    if systemctl list-units --type=service --all | grep -q "k3s.service"; then
        local svc="k3s"
    elif systemctl list-units --type=service --all | grep -q "k3s-agent.service"; then
        local svc="k3s-agent"
    else
        record_check "k3s-service" "FAIL" "K3s service not found"
        return
    fi

    if systemctl is-active --quiet "$svc"; then
        local uptime
        uptime=$(systemctl show "$svc" --property=ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")
        record_check "k3s-service" "PASS" "${svc} is active (since ${uptime})"
    else
        record_check "k3s-service" "FAIL" "${svc} is not running"
    fi

    # Check for recent restarts
    local restart_count
    restart_count=$(systemctl show "$svc" --property=NRestarts --value 2>/dev/null || echo "0")
    if [[ "$restart_count" -gt 5 ]]; then
        record_check "k3s-restarts" "WARN" "${svc} has restarted ${restart_count} times"
    else
        record_check "k3s-restarts" "PASS" "Restart count: ${restart_count}"
    fi

    # K3s version
    local version
    version=$(k3s --version 2>/dev/null | head -1 || echo "unknown")
    record_check "k3s-version" "PASS" "$version"
}

check_node_status() {
    section "Node Status"

    local nodes
    nodes=$($KUBECTL get nodes --no-headers 2>/dev/null) || {
        record_check "node-list" "FAIL" "Cannot reach API server"
        return
    }

    local total=0 ready=0 not_ready=0
    while IFS= read -r line; do
        total=$((total + 1))
        local name status
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        if [[ "$status" == "Ready" ]]; then
            ready=$((ready + 1))
            record_check "node-${name}" "PASS" "Ready"
        else
            not_ready=$((not_ready + 1))
            record_check "node-${name}" "FAIL" "Status: ${status}"
        fi
    done <<< "$nodes"

    if [[ $not_ready -eq 0 ]]; then
        record_check "nodes-summary" "PASS" "All ${total} nodes Ready"
    else
        record_check "nodes-summary" "FAIL" "${not_ready}/${total} nodes NotReady"
    fi
}

check_system_pods() {
    section "System Pods"

    local pods
    pods=$($KUBECTL get pods -n kube-system --no-headers 2>/dev/null) || {
        record_check "system-pods" "FAIL" "Cannot list kube-system pods"
        return
    }

    local total=0 running=0 failed=0 pending=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        total=$((total + 1))
        local name status
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $3}')
        case "$status" in
            Running|Completed)
                running=$((running + 1))
                ;;
            Pending)
                pending=$((pending + 1))
                record_check "pod-${name}" "WARN" "Pending"
                ;;
            CrashLoopBackOff|Error|Failed|ImagePullBackOff|ErrImagePull)
                failed=$((failed + 1))
                local restarts
                restarts=$(echo "$line" | awk '{print $4}')
                record_check "pod-${name}" "FAIL" "${status} (restarts: ${restarts})"
                ;;
            *)
                record_check "pod-${name}" "WARN" "Status: ${status}"
                ;;
        esac
    done <<< "$pods"

    if [[ $failed -eq 0 && $pending -eq 0 ]]; then
        record_check "system-pods-summary" "PASS" "All ${total} system pods healthy"
    elif [[ $failed -gt 0 ]]; then
        record_check "system-pods-summary" "FAIL" "${failed} failed, ${pending} pending out of ${total}"
    else
        record_check "system-pods-summary" "WARN" "${pending} pending out of ${total}"
    fi
}

check_certificates() {
    section "Certificates"

    local cert_dir="/var/lib/rancher/k3s/server/tls"
    if [[ ! -d "$cert_dir" ]]; then
        record_check "certificates" "WARN" "Certificate directory not found (agent node?)"
        return
    fi

    local now_epoch
    now_epoch=$(date +%s)
    local warn_days=30
    local warn_seconds=$((warn_days * 86400))

    for cert in "${cert_dir}"/*.crt; do
        [[ -f "$cert" ]] || continue
        local basename
        basename=$(basename "$cert")

        local expiry_date expiry_epoch
        expiry_date=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2) || continue
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null) || continue

        local remaining=$((expiry_epoch - now_epoch))

        if [[ $remaining -lt 0 ]]; then
            record_check "cert-${basename}" "FAIL" "EXPIRED on ${expiry_date}"
        elif [[ $remaining -lt $warn_seconds ]]; then
            local days_left=$((remaining / 86400))
            record_check "cert-${basename}" "WARN" "Expires in ${days_left} days (${expiry_date})"
        else
            local days_left=$((remaining / 86400))
            record_check "cert-${basename}" "PASS" "Valid for ${days_left} days"
        fi
    done
}

check_etcd_health() {
    section "etcd Health"

    # Check if this is an etcd-enabled server
    if ! pgrep -f "etcd" > /dev/null 2>&1; then
        record_check "etcd" "PASS" "Not using embedded etcd (SQLite or external DB)"
        return
    fi

    # Check etcd health endpoint
    local etcd_cert="/var/lib/rancher/k3s/server/tls/etcd/server-client.crt"
    local etcd_key="/var/lib/rancher/k3s/server/tls/etcd/server-client.key"
    local etcd_ca="/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt"

    if [[ -f "$etcd_cert" && -f "$etcd_key" ]]; then
        local health_response
        health_response=$(curl -sf --max-time 5 \
            --cert "$etcd_cert" \
            --key "$etcd_key" \
            --cacert "$etcd_ca" \
            https://127.0.0.1:2379/health 2>/dev/null) || health_response=""

        if echo "$health_response" | grep -q '"health":"true"'; then
            record_check "etcd-health" "PASS" "etcd is healthy"
        elif [[ -n "$health_response" ]]; then
            record_check "etcd-health" "WARN" "etcd response: ${health_response}"
        else
            record_check "etcd-health" "FAIL" "Cannot reach etcd health endpoint"
        fi
    else
        record_check "etcd-health" "WARN" "etcd TLS certificates not found"
    fi

    # Check etcd snapshots
    local snapshot_dir="/var/lib/rancher/k3s/server/db/snapshots"
    if [[ -d "$snapshot_dir" ]]; then
        local snapshot_count
        snapshot_count=$(find "$snapshot_dir" -type f 2>/dev/null | wc -l)
        if [[ "$snapshot_count" -gt 0 ]]; then
            local latest
            latest=$(find "$snapshot_dir" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -1)
            record_check "etcd-snapshots" "PASS" "${snapshot_count} snapshots, latest: ${latest##* }"
        else
            record_check "etcd-snapshots" "WARN" "No etcd snapshots found"
        fi
    fi

    # Check etcd data directory size
    local db_dir="/var/lib/rancher/k3s/server/db"
    if [[ -d "$db_dir" ]]; then
        local db_size
        db_size=$(du -sh "$db_dir" 2>/dev/null | awk '{print $1}')
        record_check "etcd-db-size" "PASS" "Database size: ${db_size}"
    fi
}

check_storage() {
    section "Storage"

    # Check StorageClasses
    local sc_count
    sc_count=$($KUBECTL get sc --no-headers 2>/dev/null | wc -l)
    if [[ "$sc_count" -gt 0 ]]; then
        local default_sc
        default_sc=$($KUBECTL get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)
        if [[ -n "$default_sc" ]]; then
            record_check "storage-class" "PASS" "Default StorageClass: ${default_sc}"
        else
            record_check "storage-class" "WARN" "No default StorageClass set"
        fi
    else
        record_check "storage-class" "WARN" "No StorageClasses found"
    fi

    # Check PersistentVolumeClaims
    local pvc_info
    pvc_info=$($KUBECTL get pvc -A --no-headers 2>/dev/null)
    if [[ -n "$pvc_info" ]]; then
        local bound pending
        bound=$(echo "$pvc_info" | grep -c "Bound" || true)
        pending=$(echo "$pvc_info" | grep -c "Pending" || true)
        if [[ "$pending" -gt 0 ]]; then
            record_check "pvc-status" "WARN" "${pending} PVCs Pending, ${bound} Bound"
        else
            record_check "pvc-status" "PASS" "All ${bound} PVCs Bound"
        fi
    else
        record_check "pvc-status" "PASS" "No PVCs in cluster"
    fi

    # Disk space on K3s data directory
    local data_dir="/var/lib/rancher/k3s"
    if [[ -d "$data_dir" ]]; then
        local disk_usage
        disk_usage=$(df -h "$data_dir" | tail -1)
        local use_pct
        use_pct=$(echo "$disk_usage" | awk '{print $5}' | tr -d '%')
        local avail
        avail=$(echo "$disk_usage" | awk '{print $4}')
        if [[ "$use_pct" -gt 90 ]]; then
            record_check "disk-space" "FAIL" "K3s data disk ${use_pct}% full (${avail} available)"
        elif [[ "$use_pct" -gt 80 ]]; then
            record_check "disk-space" "WARN" "K3s data disk ${use_pct}% full (${avail} available)"
        else
            record_check "disk-space" "PASS" "K3s data disk ${use_pct}% full (${avail} available)"
        fi
    fi
}

check_networking() {
    section "Networking"

    # CoreDNS
    local coredns_pods
    coredns_pods=$($KUBECTL get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null)
    if [[ -n "$coredns_pods" ]]; then
        if echo "$coredns_pods" | grep -q "Running"; then
            record_check "coredns" "PASS" "CoreDNS is running"
        else
            record_check "coredns" "FAIL" "CoreDNS is not running"
        fi
    else
        record_check "coredns" "WARN" "CoreDNS pods not found"
    fi

    # Flannel / CNI
    if $KUBECTL get ds -n kube-system 2>/dev/null | grep -q "canal\|flannel"; then
        record_check "cni" "PASS" "Flannel/Canal DaemonSet running"
    elif $KUBECTL get pods -n kube-system --no-headers 2>/dev/null | grep -q "calico\|cilium"; then
        record_check "cni" "PASS" "Custom CNI detected"
    else
        record_check "cni" "WARN" "CNI status unclear"
    fi

    # Kubernetes API health
    local api_health
    api_health=$($KUBECTL get --raw /healthz 2>/dev/null) || api_health="unreachable"
    if [[ "$api_health" == "ok" ]]; then
        record_check "api-server" "PASS" "API server healthy"
    else
        record_check "api-server" "FAIL" "API server: ${api_health}"
    fi
}

check_workloads() {
    section "Workloads"

    # Deployments with unavailable replicas
    local unhealthy_deploys
    unhealthy_deploys=$($KUBECTL get deployments -A --no-headers 2>/dev/null | \
        awk '$3 != $4 || $4 != $5 {print $1"/"$2, "desired="$3, "ready="$5}')
    if [[ -n "$unhealthy_deploys" ]]; then
        while IFS= read -r line; do
            record_check "deploy-$(echo "$line" | awk '{print $1}')" "WARN" "$line"
        done <<< "$unhealthy_deploys"
    else
        local total_deploys
        total_deploys=$($KUBECTL get deployments -A --no-headers 2>/dev/null | wc -l)
        record_check "deployments" "PASS" "All ${total_deploys} deployments healthy"
    fi

    # DaemonSets with unavailable
    local ds_issues
    ds_issues=$($KUBECTL get ds -A --no-headers 2>/dev/null | \
        awk '$4 != $6 {print $1"/"$2, "desired="$4, "ready="$6}')
    if [[ -n "$ds_issues" ]]; then
        while IFS= read -r line; do
            record_check "ds-$(echo "$line" | awk '{print $1}')" "WARN" "$line"
        done <<< "$ds_issues"
    else
        record_check "daemonsets" "PASS" "All DaemonSets healthy"
    fi
}

# --- Output ---
print_summary() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "{"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"summary\": {\"pass\": $PASS, \"warn\": $WARN, \"fail\": $FAIL},"
        echo "  \"checks\": ["
        local first=true
        for check in "${CHECKS[@]}"; do
            IFS='|' read -r name status detail <<< "$check"
            if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
            printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
                "$name" "$status" "$detail"
        done
        echo ""
        echo "  ]"
        echo "}"
    else
        echo ""
        echo -e "${BOLD}=== Health Check Summary ===${NC}"
        echo -e "  ${GREEN}Pass: ${PASS}${NC}  ${YELLOW}Warn: ${WARN}${NC}  ${RED}Fail: ${FAIL}${NC}"
        echo ""
        if [[ $FAIL -gt 0 ]]; then
            echo -e "${RED}${BOLD}UNHEALTHY${NC} — $FAIL check(s) failed"
            exit 2
        elif [[ $WARN -gt 0 ]]; then
            echo -e "${YELLOW}${BOLD}DEGRADED${NC} — $WARN warning(s)"
            exit 1
        else
            echo -e "${GREEN}${BOLD}HEALTHY${NC} — all checks passed"
            exit 0
        fi
    fi
}

# --- Main ---
main() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${BOLD}K3s Health Check${NC} — $(date)"
        echo "Host: $(hostname) ($(uname -r))"
    fi

    check_k3s_service
    check_node_status
    check_system_pods
    check_certificates
    check_etcd_health
    check_storage
    check_networking
    check_workloads

    print_summary
}

main
