#!/usr/bin/env bash
#
# deploy-stack.sh — Deploy a Docker Swarm stack with pre-flight checks
#
# Usage:
#   ./deploy-stack.sh -f <COMPOSE_FILE> -n <STACK_NAME> [OPTIONS]
#
# Options:
#   -f, --file <FILE>       Compose file path (required)
#   -n, --name <NAME>       Stack name (required)
#   --with-registry-auth    Pass registry credentials to agents
#   --skip-checks           Skip pre-flight checks
#   --create-secrets        Interactively create missing secrets
#   --create-networks       Auto-create missing external networks
#   --wait <SECONDS>        Wait for services to converge (default: 120)
#   --dry-run               Run checks only, do not deploy
#   --help                  Show this help message
#
set -euo pipefail

# --- Defaults ---
COMPOSE_FILE=""
STACK_NAME=""
REGISTRY_AUTH=""
SKIP_CHECKS=false
CREATE_SECRETS=false
CREATE_NETWORKS=false
WAIT_TIMEOUT=120
DRY_RUN=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_check() { echo -e "${CYAN}[CHECK]${NC} $*"; }

CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

check_pass() { log_check "✅ $*"; ((CHECKS_PASSED++)); }
check_fail() { log_check "❌ $*"; ((CHECKS_FAILED++)); }
check_warn() { log_check "⚠️  $*"; ((CHECKS_WARNED++)); }

usage() {
    sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)              COMPOSE_FILE="$2"; shift 2 ;;
        -n|--name)              STACK_NAME="$2"; shift 2 ;;
        --with-registry-auth)   REGISTRY_AUTH="--with-registry-auth"; shift ;;
        --skip-checks)          SKIP_CHECKS=true; shift ;;
        --create-secrets)       CREATE_SECRETS=true; shift ;;
        --create-networks)      CREATE_NETWORKS=true; shift ;;
        --wait)                 WAIT_TIMEOUT="$2"; shift 2 ;;
        --dry-run)              DRY_RUN=true; shift ;;
        --help|-h)              usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# --- Validate required args ---
if [[ -z "$COMPOSE_FILE" || -z "$STACK_NAME" ]]; then
    log_error "Both --file and --name are required"
    usage
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
    log_error "Compose file not found: ${COMPOSE_FILE}"
    exit 1
fi

# --- Check Docker and Swarm ---
if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
    log_error "This node is not part of a Docker Swarm. Run 'docker swarm init' first."
    exit 1
fi

if ! docker node ls &>/dev/null; then
    log_error "This node is not a Swarm manager. Run this script on a manager node."
    exit 1
fi

# --- Pre-flight checks ---
if [[ "$SKIP_CHECKS" == false ]]; then
    echo ""
    log_info "=== Pre-flight Checks ==="
    echo ""

    # 1. Validate compose file syntax
    log_check "Validating compose file syntax..."
    if docker compose -f "$COMPOSE_FILE" config --quiet 2>/dev/null; then
        check_pass "Compose file syntax is valid"
    elif docker-compose -f "$COMPOSE_FILE" config --quiet 2>/dev/null; then
        check_pass "Compose file syntax is valid (docker-compose v1)"
    else
        check_fail "Compose file has syntax errors"
        docker compose -f "$COMPOSE_FILE" config 2>&1 | head -5
    fi

    # 2. Check images availability
    log_check "Checking image availability..."
    IMAGES=$(grep -E '^\s+image:' "$COMPOSE_FILE" | sed 's/.*image:\s*//' | tr -d '"' | tr -d "'" | sort -u)
    for image in $IMAGES; do
        # Skip images with variable substitution
        if echo "$image" | grep -q '\$'; then
            check_warn "Image '${image}' contains variable — cannot verify"
            continue
        fi
        if docker manifest inspect "$image" &>/dev/null 2>&1; then
            check_pass "Image available: ${image}"
        elif docker image inspect "$image" &>/dev/null 2>&1; then
            check_pass "Image available locally: ${image}"
        else
            check_fail "Image not found: ${image}"
        fi
    done

    # 3. Check external networks
    log_check "Checking external networks..."
    EXT_NETWORKS=$(grep -A2 'external:' "$COMPOSE_FILE" | grep -B2 'external:\s*true' | grep -E '^\s+\w' | awk '{print $1}' | tr -d ':' 2>/dev/null || true)
    # Also check named external networks
    NAMED_NETWORKS=$(grep -A3 'external:' "$COMPOSE_FILE" | grep 'name:' | sed 's/.*name:\s*//' | tr -d '"' | tr -d "'" 2>/dev/null || true)
    ALL_EXT_NETS="$EXT_NETWORKS $NAMED_NETWORKS"
    for net in $ALL_EXT_NETS; do
        [[ -z "$net" ]] && continue
        if docker network inspect "$net" &>/dev/null; then
            check_pass "Network exists: ${net}"
        else
            if [[ "$CREATE_NETWORKS" == true ]]; then
                log_info "Creating overlay network: ${net}"
                docker network create --driver overlay --attachable "$net"
                check_pass "Network created: ${net}"
            else
                check_fail "Network missing: ${net} (use --create-networks to auto-create)"
            fi
        fi
    done

    # 4. Check external secrets
    log_check "Checking external secrets..."
    EXT_SECRETS=$(grep -A2 'external:' "$COMPOSE_FILE" | grep -B1 'external:\s*true' | grep -E '^\s+\w' | awk '{print $1}' | tr -d ':' 2>/dev/null || true)
    NAMED_SECRETS=$(grep -A3 'external:' "$COMPOSE_FILE" | grep 'name:' | sed 's/.*name:\s*//' | tr -d '"' | tr -d "'" 2>/dev/null || true)
    # Simple extraction from secrets section
    SECRETS_SECTION=$(sed -n '/^secrets:/,/^[a-z]/p' "$COMPOSE_FILE" | grep 'external:\s*true' -B1 | grep -E '^\s+\w' | awk '{print $1}' | tr -d ':' 2>/dev/null || true)
    ALL_SECRETS="$EXT_SECRETS $NAMED_SECRETS $SECRETS_SECTION"
    for secret in $ALL_SECRETS; do
        [[ -z "$secret" ]] && continue
        if docker secret inspect "$secret" &>/dev/null; then
            check_pass "Secret exists: ${secret}"
        else
            if [[ "$CREATE_SECRETS" == true ]]; then
                log_warn "Secret '${secret}' is missing. Enter value (or press Ctrl+C to abort):"
                read -r -s secret_value
                echo "$secret_value" | docker secret create "$secret" -
                check_pass "Secret created: ${secret}"
            else
                check_fail "Secret missing: ${secret} (use --create-secrets to create interactively)"
            fi
        fi
    done

    # 5. Check node availability
    log_check "Checking node availability..."
    TOTAL_NODES=$(docker node ls --format '{{.Status}}' | grep -c "Ready" || true)
    ACTIVE_NODES=$(docker node ls --format '{{.Availability}}' | grep -c "Active" || true)
    if [[ "$TOTAL_NODES" -gt 0 ]]; then
        check_pass "${TOTAL_NODES} nodes ready, ${ACTIVE_NODES} active"
    else
        check_fail "No ready nodes in the cluster"
    fi

    # 6. Check for port conflicts
    log_check "Checking for port conflicts..."
    PUBLISHED_PORTS=$(grep -oP 'published:\s*\K\d+' "$COMPOSE_FILE" 2>/dev/null || true)
    SHORT_PORTS=$(grep -oP '^\s+-\s+"?\K\d+(?=:)' "$COMPOSE_FILE" 2>/dev/null || true)
    ALL_PORTS="$PUBLISHED_PORTS $SHORT_PORTS"
    EXISTING_PORTS=$(docker service ls --format '{{.Ports}}' | grep -oP '\d+(?=->)' 2>/dev/null || true)
    for port in $ALL_PORTS; do
        [[ -z "$port" ]] && continue
        if echo "$EXISTING_PORTS" | grep -qw "$port"; then
            CONFLICT_SVC=$(docker service ls --format '{{.Name}} {{.Ports}}' | grep "${port}->" | awk '{print $1}')
            # Ignore if it's the same stack being redeployed
            if echo "$CONFLICT_SVC" | grep -q "^${STACK_NAME}_"; then
                check_pass "Port ${port} used by same stack (update)"
            else
                check_warn "Port ${port} already in use by: ${CONFLICT_SVC}"
            fi
        else
            check_pass "Port ${port} is available"
        fi
    done

    # --- Results ---
    echo ""
    log_info "=== Pre-flight Results ==="
    echo "  Passed:  ${CHECKS_PASSED}"
    echo "  Warned:  ${CHECKS_WARNED}"
    echo "  Failed:  ${CHECKS_FAILED}"
    echo ""

    if [[ "$CHECKS_FAILED" -gt 0 ]]; then
        log_error "Pre-flight checks failed. Fix the issues above or use --skip-checks to bypass."
        exit 1
    fi
fi

# --- Dry run exit ---
if [[ "$DRY_RUN" == true ]]; then
    log_info "Dry run complete. No deployment performed."
    exit 0
fi

# --- Deploy ---
log_info "Deploying stack '${STACK_NAME}' from ${COMPOSE_FILE}..."
docker stack deploy -c "$COMPOSE_FILE" $REGISTRY_AUTH "$STACK_NAME"

# --- Wait for convergence ---
if [[ "$WAIT_TIMEOUT" -gt 0 ]]; then
    log_info "Waiting up to ${WAIT_TIMEOUT}s for services to converge..."
    DEADLINE=$((SECONDS + WAIT_TIMEOUT))

    while [[ $SECONDS -lt $DEADLINE ]]; do
        ALL_CONVERGED=true
        while IFS= read -r line; do
            svc_name=$(echo "$line" | awk '{print $2}')
            replicas=$(echo "$line" | awk '{print $4}')
            current=$(echo "$replicas" | cut -d/ -f1)
            desired=$(echo "$replicas" | cut -d/ -f2)
            if [[ "$current" != "$desired" ]]; then
                ALL_CONVERGED=false
                break
            fi
        done < <(docker stack services "$STACK_NAME" 2>/dev/null | tail -n +2)

        if [[ "$ALL_CONVERGED" == true ]]; then
            break
        fi
        sleep 5
    done

    echo ""
    if [[ "$ALL_CONVERGED" == true ]]; then
        log_info "All services converged successfully"
    else
        log_warn "Some services did not converge within ${WAIT_TIMEOUT}s"
    fi
fi

# --- Summary ---
echo ""
log_info "=== Stack Services ==="
docker stack services "$STACK_NAME"
echo ""
log_info "=== Stack Tasks ==="
docker stack ps "$STACK_NAME" --format "table {{.Name}}\t{{.Node}}\t{{.CurrentState}}\t{{.Error}}" | head -30
echo ""
log_info "Deployment of '${STACK_NAME}' complete"
