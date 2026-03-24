#!/usr/bin/env bash
#
# health-check.sh — Docker Swarm cluster health check
#
# Usage:
#   ./health-check.sh [OPTIONS]
#
# Options:
#   --json          Output results as JSON
#   --quiet         Only show failures and warnings
#   --cert-warn <D> Warn if certificates expire within D days (default: 30)
#   --help          Show this help message
#
set -euo pipefail

# --- Defaults ---
JSON_OUTPUT=false
QUIET=false
CERT_WARN_DAYS=30
EXIT_CODE=0

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Counters ---
TOTAL_CHECKS=0
PASSED=0
WARNINGS=0
FAILURES=0

pass() {
    ((TOTAL_CHECKS++))
    ((PASSED++))
    [[ "$QUIET" == false ]] && echo -e "  ${GREEN}✅${NC} $*"
}

warn() {
    ((TOTAL_CHECKS++))
    ((WARNINGS++))
    echo -e "  ${YELLOW}⚠️${NC}  $*"
}

fail() {
    ((TOTAL_CHECKS++))
    ((FAILURES++))
    EXIT_CODE=1
    echo -e "  ${RED}❌${NC} $*"
}

section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━ $* ━━━${NC}"
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)       JSON_OUTPUT=true; shift ;;
        --quiet)      QUIET=true; shift ;;
        --cert-warn)  CERT_WARN_DAYS="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Pre-checks ---
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is not installed"
    exit 1
fi

if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
    echo "ERROR: This node is not part of a Docker Swarm"
    exit 1
fi

IS_MANAGER=true
if ! docker node ls &>/dev/null 2>&1; then
    IS_MANAGER=false
    echo "WARNING: This node is not a manager. Some checks will be skipped."
fi

echo ""
echo -e "${BOLD}Docker Swarm Health Check${NC}"
echo -e "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo -e "Hostname:  $(hostname)"

# ============================================================
# 1. NODE STATUS
# ============================================================
if [[ "$IS_MANAGER" == true ]]; then
    section "Node Status"

    MANAGER_COUNT=0
    WORKER_COUNT=0
    DOWN_NODES=0

    while IFS= read -r line; do
        node_id=$(echo "$line" | awk '{print $1}')
        hostname=$(docker node inspect --format '{{.Description.Hostname}}' "$node_id" 2>/dev/null || echo "unknown")
        status=$(docker node inspect --format '{{.Status.State}}' "$node_id" 2>/dev/null)
        availability=$(docker node inspect --format '{{.Spec.Availability}}' "$node_id" 2>/dev/null)
        role=$(docker node inspect --format '{{.Spec.Role}}' "$node_id" 2>/dev/null)

        if [[ "$role" == "manager" ]]; then
            ((MANAGER_COUNT++))
        else
            ((WORKER_COUNT++))
        fi

        if [[ "$status" == "ready" ]]; then
            pass "Node ${hostname} (${role}): ${status} / ${availability}"
        else
            ((DOWN_NODES++))
            fail "Node ${hostname} (${role}): ${status} / ${availability}"
        fi
    done < <(docker node ls -q 2>/dev/null)

    # Manager count check (odd number)
    if (( MANAGER_COUNT % 2 == 0 )); then
        warn "Even number of managers (${MANAGER_COUNT}) — risk of split-brain"
    elif (( MANAGER_COUNT == 1 )); then
        warn "Single manager — no HA. Use 3 or 5 managers for production"
    else
        pass "Manager count: ${MANAGER_COUNT} (odd ✓)"
    fi

    # Quorum check
    QUORUM=$((MANAGER_COUNT / 2 + 1))
    MANAGERS_UP=$((MANAGER_COUNT - DOWN_NODES))
    if (( MANAGERS_UP >= QUORUM )); then
        pass "Quorum: ${MANAGERS_UP}/${MANAGER_COUNT} managers up (need ${QUORUM})"
    else
        fail "QUORUM LOST: only ${MANAGERS_UP}/${MANAGER_COUNT} managers up (need ${QUORUM})"
    fi
fi

# ============================================================
# 2. SERVICE REPLICAS
# ============================================================
if [[ "$IS_MANAGER" == true ]]; then
    section "Service Replicas"

    SERVICES_OK=0
    SERVICES_DEGRADED=0

    while IFS='|' read -r svc_name svc_mode svc_replicas; do
        svc_name=$(echo "$svc_name" | xargs)
        svc_mode=$(echo "$svc_mode" | xargs)
        svc_replicas=$(echo "$svc_replicas" | xargs)

        if [[ "$svc_mode" == "global" ]]; then
            pass "Service ${svc_name}: global mode (${svc_replicas})"
            ((SERVICES_OK++))
            continue
        fi

        current=$(echo "$svc_replicas" | cut -d/ -f1)
        desired=$(echo "$svc_replicas" | cut -d/ -f2)

        if [[ "$current" == "$desired" ]]; then
            pass "Service ${svc_name}: ${svc_replicas}"
            ((SERVICES_OK++))
        elif [[ "$current" == "0" ]]; then
            fail "Service ${svc_name}: ${svc_replicas} — NO replicas running"
            ((SERVICES_DEGRADED++))
        else
            warn "Service ${svc_name}: ${svc_replicas} — degraded"
            ((SERVICES_DEGRADED++))
        fi
    done < <(docker service ls --format '{{.Name}}|{{.Mode}}|{{.Replicas}}' 2>/dev/null)

    if [[ $((SERVICES_OK + SERVICES_DEGRADED)) -eq 0 ]]; then
        pass "No services deployed"
    fi
fi

# ============================================================
# 3. TASK STATES
# ============================================================
if [[ "$IS_MANAGER" == true ]]; then
    section "Task States"

    FAILED_TASKS=0
    REJECTED_TASKS=0
    ORPHANED_TASKS=0

    # Check for failed tasks (across all services)
    FAILED_TASKS=$(docker service ls -q 2>/dev/null | xargs -I{} docker service ps {} --filter "desired-state=shutdown" --format "{{.Error}}" 2>/dev/null | grep -cv "^$" || true)

    if [[ "$FAILED_TASKS" -gt 0 ]]; then
        warn "${FAILED_TASKS} failed/shutdown tasks across services"
        # Show recent failures
        for svc in $(docker service ls -q 2>/dev/null); do
            svc_name=$(docker service inspect --format '{{.Spec.Name}}' "$svc" 2>/dev/null)
            errors=$(docker service ps "$svc" --filter "desired-state=shutdown" --format "{{.Error}}" 2>/dev/null | grep -v "^$" | head -3)
            if [[ -n "$errors" ]]; then
                echo -e "      ${svc_name}: $(echo "$errors" | head -1)"
            fi
        done
    else
        pass "No failed tasks"
    fi

    # Check for tasks with no suitable node
    PENDING_TASKS=$(docker service ls -q 2>/dev/null | xargs -I{} docker service ps {} --filter "desired-state=running" --format "{{.CurrentState}}" 2>/dev/null | grep -c "Pending" || true)
    if [[ "$PENDING_TASKS" -gt 0 ]]; then
        fail "${PENDING_TASKS} tasks stuck in Pending state (scheduling issues)"
    else
        pass "No pending tasks"
    fi
fi

# ============================================================
# 4. NETWORK CONNECTIVITY
# ============================================================
section "Network Status"

# Check overlay networks
OVERLAY_COUNT=$(docker network ls --filter driver=overlay --format '{{.Name}}' | wc -l)
pass "Overlay networks: ${OVERLAY_COUNT}"

# Check ingress network
if docker network inspect ingress &>/dev/null; then
    INGRESS_SUBNET=$(docker network inspect ingress --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
    pass "Ingress network: ${INGRESS_SUBNET}"
else
    fail "Ingress network missing"
fi

# Check docker_gwbridge
if docker network inspect docker_gwbridge &>/dev/null; then
    pass "docker_gwbridge network present"
else
    warn "docker_gwbridge network not found"
fi

# Check required ports (from this node's perspective)
for port_proto in "2377/tcp" "7946/tcp" "4789/udp"; do
    port=$(echo "$port_proto" | cut -d/ -f1)
    if ss -lnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        pass "Port ${port_proto} is listening"
    else
        warn "Port ${port_proto} may not be listening (check firewall)"
    fi
done

# ============================================================
# 5. CERTIFICATE EXPIRY
# ============================================================
section "TLS Certificates"

CERT_FILE="/var/lib/docker/swarm/certificates/swarm-node.crt"
if [[ -f "$CERT_FILE" ]]; then
    EXPIRY_DATE=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    if [[ -n "$EXPIRY_DATE" ]]; then
        EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

        if (( DAYS_LEFT < 0 )); then
            fail "Node certificate EXPIRED (${EXPIRY_DATE})"
        elif (( DAYS_LEFT < CERT_WARN_DAYS )); then
            warn "Node certificate expires in ${DAYS_LEFT} days (${EXPIRY_DATE})"
        else
            pass "Node certificate valid for ${DAYS_LEFT} days (${EXPIRY_DATE})"
        fi
    fi
else
    warn "Cannot read certificate file (need root access to ${CERT_FILE})"
fi

# Check cert expiry configuration
if [[ "$IS_MANAGER" == true ]]; then
    CERT_EXPIRY=$(docker info --format '{{.Swarm.Cluster.Spec.CAConfig.NodeCertExpiry}}' 2>/dev/null || echo "unknown")
    pass "Certificate rotation interval: ${CERT_EXPIRY}"

    # Check autolock status
    AUTOLOCK=$(docker info --format '{{.Swarm.Cluster.Spec.EncryptionConfig.AutoLockManagers}}' 2>/dev/null || echo "unknown")
    if [[ "$AUTOLOCK" == "true" ]]; then
        pass "Autolock: enabled"
    else
        warn "Autolock: disabled (consider enabling for production)"
    fi
fi

# ============================================================
# 6. RESOURCE UTILIZATION
# ============================================================
section "Resource Overview"

# Docker disk usage
DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
if command -v df &>/dev/null; then
    DISK_USAGE=$(df -h "$DOCKER_ROOT" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    if [[ -n "$DISK_USAGE" ]]; then
        if (( DISK_USAGE > 90 )); then
            fail "Disk usage at ${DISK_USAGE}% on ${DOCKER_ROOT}"
        elif (( DISK_USAGE > 80 )); then
            warn "Disk usage at ${DISK_USAGE}% on ${DOCKER_ROOT}"
        else
            pass "Disk usage: ${DISK_USAGE}% on ${DOCKER_ROOT}"
        fi
    fi
fi

# Docker system info
CONTAINERS_RUNNING=$(docker info --format '{{.ContainersRunning}}' 2>/dev/null || echo "?")
CONTAINERS_STOPPED=$(docker info --format '{{.ContainersStopped}}' 2>/dev/null || echo "?")
IMAGES=$(docker info --format '{{.Images}}' 2>/dev/null || echo "?")
pass "Containers: ${CONTAINERS_RUNNING} running, ${CONTAINERS_STOPPED} stopped"
pass "Images: ${IMAGES} cached"

# ============================================================
# SUMMARY
# ============================================================
section "Summary"

echo ""
echo -e "  Total checks: ${TOTAL_CHECKS}"
echo -e "  ${GREEN}Passed:${NC}   ${PASSED}"
echo -e "  ${YELLOW}Warnings:${NC} ${WARNINGS}"
echo -e "  ${RED}Failures:${NC} ${FAILURES}"
echo ""

if [[ "$FAILURES" -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}HEALTH: UNHEALTHY${NC}"
elif [[ "$WARNINGS" -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}HEALTH: DEGRADED${NC}"
else
    echo -e "  ${GREEN}${BOLD}HEALTH: HEALTHY${NC}"
fi

echo ""
exit $EXIT_CODE
