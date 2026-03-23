#!/usr/bin/env bash
# tc-health-check.sh — Check Testcontainers prerequisites.
#
# Verifies:
#   - Docker daemon availability
#   - Ryuk container capability
#   - Network creation permissions
#   - Available disk, memory, and CPU resources
#   - Testcontainers configuration
#
# Usage: ./tc-health-check.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0

pass() { echo -e "  ${GREEN}✅ PASS${NC}  $*"; ((PASS++)); }
warn() { echo -e "  ${YELLOW}⚠️  WARN${NC}  $*"; ((WARN++)); }
fail() { echo -e "  ${RED}❌ FAIL${NC}  $*"; ((FAIL++)); }
info() { echo -e "  ${BLUE}ℹ  INFO${NC}  $*"; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Testcontainers Health Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# -------------------------------------------------------------------
# 1. Docker CLI
# -------------------------------------------------------------------
echo "▸ Docker CLI"

if command -v docker &>/dev/null; then
    DOCKER_PATH=$(command -v docker)
    pass "Docker CLI found at $DOCKER_PATH"
else
    fail "Docker CLI not found in PATH"
    echo "       Install: https://docs.docker.com/get-docker/"
    echo ""
    echo "Cannot continue without Docker. Exiting."
    exit 1
fi

# -------------------------------------------------------------------
# 2. Docker Daemon
# -------------------------------------------------------------------
echo ""
echo "▸ Docker Daemon"

if docker info &>/dev/null; then
    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    pass "Docker daemon is running (version: $DOCKER_VERSION)"
else
    fail "Docker daemon is not reachable"
    if [[ -n "${DOCKER_HOST:-}" ]]; then
        info "DOCKER_HOST=$DOCKER_HOST"
    fi
    echo "       Start Docker: sudo systemctl start docker"
    echo "       Or start Docker Desktop"
fi

# Check Docker socket
SOCKET="${DOCKER_HOST:-unix:///var/run/docker.sock}"
if [[ "$SOCKET" == unix://* ]]; then
    SOCKET_PATH="${SOCKET#unix://}"
    if [[ -S "$SOCKET_PATH" ]]; then
        pass "Docker socket exists at $SOCKET_PATH"
        if [[ -r "$SOCKET_PATH" && -w "$SOCKET_PATH" ]]; then
            pass "Docker socket is readable and writable"
        else
            fail "Docker socket permissions insufficient"
            echo "       Fix: sudo usermod -aG docker \$USER && newgrp docker"
        fi
    else
        warn "Docker socket not found at $SOCKET_PATH"
    fi
fi

# -------------------------------------------------------------------
# 3. Ryuk (Resource Reaper)
# -------------------------------------------------------------------
echo ""
echo "▸ Ryuk Container"

if docker info &>/dev/null; then
    # Try starting a minimal container to verify container creation works
    RYUK_TEST_ID=$(docker run -d --rm --name tc-healthcheck-ryuk-test \
        -e "RYUK_PORT=8080" \
        testcontainers/ryuk:0.7.0 2>/dev/null || echo "FAILED")

    if [[ "$RYUK_TEST_ID" != "FAILED" && -n "$RYUK_TEST_ID" ]]; then
        pass "Ryuk container can be started"
        docker rm -f tc-healthcheck-ryuk-test &>/dev/null || true
    else
        warn "Could not start Ryuk container"
        echo "       Ryuk is optional. Set TESTCONTAINERS_RYUK_DISABLED=true to skip."
        echo "       If disabled, ensure manual cleanup of test containers."
    fi
fi

# Check Ryuk configuration
if [[ "${TESTCONTAINERS_RYUK_DISABLED:-}" == "true" ]]; then
    warn "Ryuk is disabled (TESTCONTAINERS_RYUK_DISABLED=true)"
    echo "       Orphaned containers won't be auto-cleaned."
fi

# -------------------------------------------------------------------
# 4. Network
# -------------------------------------------------------------------
echo ""
echo "▸ Docker Network"

if docker info &>/dev/null; then
    NET_ID=$(docker network create tc-healthcheck-net 2>/dev/null || echo "FAILED")
    if [[ "$NET_ID" != "FAILED" ]]; then
        pass "Can create Docker networks"
        docker network rm tc-healthcheck-net &>/dev/null || true
    else
        fail "Cannot create Docker networks"
        echo "       Network creation is needed for multi-container tests."
    fi
fi

# -------------------------------------------------------------------
# 5. Resources
# -------------------------------------------------------------------
echo ""
echo "▸ System Resources"

# Disk space
if command -v df &>/dev/null; then
    AVAIL_KB=$(df /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}' || df / | awk 'NR==2 {print $4}')
    if [[ -n "$AVAIL_KB" ]]; then
        AVAIL_GB=$((AVAIL_KB / 1048576))
        if (( AVAIL_GB >= 10 )); then
            pass "Disk space: ${AVAIL_GB}GB available"
        elif (( AVAIL_GB >= 5 )); then
            warn "Disk space: ${AVAIL_GB}GB available (recommend ≥10GB)"
        else
            fail "Disk space: ${AVAIL_GB}GB available (need ≥5GB)"
            echo "       Free space: docker system prune -af"
        fi
    fi
fi

# Memory
if command -v free &>/dev/null; then
    TOTAL_MB=$(free -m | awk '/^Mem:/ {print $2}')
    AVAIL_MB=$(free -m | awk '/^Mem:/ {print $7}')
    if [[ -n "$AVAIL_MB" ]]; then
        if (( AVAIL_MB >= 2048 )); then
            pass "Available memory: ${AVAIL_MB}MB (total: ${TOTAL_MB}MB)"
        elif (( AVAIL_MB >= 1024 )); then
            warn "Available memory: ${AVAIL_MB}MB (recommend ≥2GB)"
        else
            fail "Available memory: ${AVAIL_MB}MB (need ≥1GB)"
        fi
    fi
elif [[ "$(uname)" == "Darwin" ]]; then
    TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    TOTAL_MB=$((TOTAL_BYTES / 1048576))
    pass "Total memory: ${TOTAL_MB}MB"
fi

# CPU
CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "unknown")
if [[ "$CPUS" != "unknown" ]]; then
    if (( CPUS >= 2 )); then
        pass "CPUs: $CPUS"
    else
        warn "CPUs: $CPUS (recommend ≥2 for parallel tests)"
    fi
fi

# Docker disk usage
if docker info &>/dev/null; then
    echo ""
    info "Docker disk usage:"
    docker system df 2>/dev/null | sed 's/^/       /'
fi

# -------------------------------------------------------------------
# 6. Testcontainers Configuration
# -------------------------------------------------------------------
echo ""
echo "▸ Testcontainers Configuration"

TC_PROPS="$HOME/.testcontainers.properties"
if [[ -f "$TC_PROPS" ]]; then
    pass "Config file found: $TC_PROPS"
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        info "  $line"
    done < "$TC_PROPS"
else
    info "No ~/.testcontainers.properties file (using defaults)"
fi

# Environment variables
echo ""
info "Relevant environment variables:"
for var in DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH \
           TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE \
           TESTCONTAINERS_HOST_OVERRIDE \
           TESTCONTAINERS_RYUK_DISABLED \
           TC_CLOUD_TOKEN \
           TESTCONTAINERS_REUSE_ENABLE; do
    if [[ -n "${!var:-}" ]]; then
        # Mask tokens
        if [[ "$var" == *TOKEN* || "$var" == *SECRET* ]]; then
            info "  $var=****"
        else
            info "  $var=${!var}"
        fi
    fi
done

# -------------------------------------------------------------------
# 7. Existing Testcontainers containers
# -------------------------------------------------------------------
echo ""
echo "▸ Existing Testcontainers Resources"

if docker info &>/dev/null; then
    TC_CONTAINERS=$(docker ps --filter "label=org.testcontainers=true" --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' ')
    if (( TC_CONTAINERS > 0 )); then
        warn "$TC_CONTAINERS Testcontainers container(s) currently running"
        docker ps --filter "label=org.testcontainers=true" --format "  {{.Names}} ({{.Image}}, {{.Status}})" 2>/dev/null
    else
        pass "No orphaned Testcontainers containers found"
    fi

    TC_NETWORKS=$(docker network ls --filter "label=org.testcontainers=true" -q 2>/dev/null | wc -l | tr -d ' ')
    if (( TC_NETWORKS > 0 )); then
        warn "$TC_NETWORKS orphaned Testcontainers network(s) found"
    else
        pass "No orphaned Testcontainers networks found"
    fi
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${YELLOW}$WARN warnings${NC}, ${RED}$FAIL failed${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if (( FAIL > 0 )); then
    echo "Fix the failures above before running Testcontainers tests."
    exit 1
elif (( WARN > 0 )); then
    echo "Testcontainers should work, but review the warnings above."
    exit 0
else
    echo "All checks passed. Testcontainers is ready to use!"
    exit 0
fi
