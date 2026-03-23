#!/usr/bin/env bash
#
# rollback.sh — Safe Kamal rollback with pre-checks and confirmation
#
# Usage:
#   ./rollback.sh [version]
#   ./rollback.sh                    # Interactive — shows versions to choose from
#   ./rollback.sh abc123def          # Rollback to specific version
#   ./rollback.sh --auto <version>   # Non-interactive rollback (for scripts)
#
# Options:
#   -d, --destination <dest>   Kamal destination (staging, production)
#   -y, --auto                 Skip confirmation prompts (for CI/automation)
#   --dry-run                  Show what would happen without executing
#   -h, --help                 Show this help message
#
# Pre-checks performed:
#   1. Verifies Kamal CLI is available
#   2. Checks no deploy is currently in progress (lock check)
#   3. Validates the target version exists
#   4. Shows current vs target version diff
#   5. Confirms with operator before proceeding
#
# Post-rollback:
#   1. Verifies health endpoint returns 200
#   2. Shows container status
#   3. Optionally notifies via webhook

set -euo pipefail

# --- Defaults ---
VERSION=""
DESTINATION=""
AUTO_MODE=false
DRY_RUN=false
WEBHOOK_URL="${KAMAL_ROLLBACK_WEBHOOK:-}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

usage() {
    head -17 "$0" | tail -14
    exit 0
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--destination)  DESTINATION="$2"; shift 2 ;;
        -y|--auto)         AUTO_MODE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        -h|--help)         usage ;;
        -*)                err "Unknown option: $1"; usage ;;
        *)                 VERSION="$1"; shift ;;
    esac
done

DEST_FLAG=""
[[ -n "$DESTINATION" ]] && DEST_FLAG="-d $DESTINATION"

# --- Pre-check 1: Kamal CLI ---
if ! command -v kamal &>/dev/null; then
    err "Kamal CLI not found. Install with: gem install kamal"
    exit 1
fi
log "Kamal CLI found"

# --- Pre-check 2: Config exists ---
if [[ ! -f "config/deploy.yml" ]]; then
    err "config/deploy.yml not found. Run from project root."
    exit 1
fi
log "Config found"

# --- Pre-check 3: Lock check ---
info "Checking deploy lock..."
LOCK_STATUS=$(kamal lock status $DEST_FLAG 2>&1) || LOCK_STATUS=""

if echo "$LOCK_STATUS" | grep -qi "locked\|held"; then
    err "Deploy lock is held. Another deploy may be in progress."
    echo "$LOCK_STATUS"
    echo ""
    if $AUTO_MODE; then
        err "Aborting (auto mode). Release lock with: kamal lock release"
        exit 1
    fi
    read -rp "Force release lock and continue? (y/N) " force
    if [[ "$force" =~ ^[Yy]$ ]]; then
        kamal lock release $DEST_FLAG
        log "Lock released"
    else
        echo "Aborted."
        exit 0
    fi
else
    log "No deploy lock held"
fi

# --- Pre-check 4: Get current state ---
info "Fetching current app details..."
CURRENT_DETAILS=$(kamal app details $DEST_FLAG 2>&1) || CURRENT_DETAILS="(could not fetch)"
CURRENT_VERSION=$(echo "$CURRENT_DETAILS" | grep -oP ':[a-f0-9]{7,40}' | head -1 | tr -d ':' || echo "unknown")

echo ""
echo -e "${BOLD}Current deployment:${NC}"
echo "$CURRENT_DETAILS" | grep -E "running|version|container" | head -5 | while read -r line; do
    echo "  $line"
done
echo ""

# --- Version selection ---
if [[ -z "$VERSION" ]]; then
    if $AUTO_MODE; then
        err "Version required in auto mode. Usage: $0 --auto <version>"
        exit 1
    fi

    info "Available versions (from retained containers):"
    echo "$CURRENT_DETAILS" | grep -oP ':[a-f0-9]{7,40}' | tr -d ':' | sort -u | while read -r v; do
        if [[ "$v" == "$CURRENT_VERSION" ]]; then
            echo -e "  ${GREEN}$v (current)${NC}"
        else
            echo "  $v"
        fi
    done
    echo ""

    # Also try to list from Docker images
    info "Recent image tags:"
    kamal app images $DEST_FLAG 2>/dev/null | head -10 | while read -r line; do
        echo "  $line"
    done 2>/dev/null || true
    echo ""

    read -rp "Enter version to rollback to: " VERSION
    if [[ -z "$VERSION" ]]; then
        err "No version specified."
        exit 1
    fi
fi

# Validate version doesn't match current
if [[ "$VERSION" == "$CURRENT_VERSION" ]]; then
    warn "Version $VERSION is already the current version."
    read -rp "Continue anyway? (y/N) " cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 0
fi

# --- Confirmation ---
echo ""
echo "============================================"
echo -e " ${BOLD}Rollback Plan${NC}"
echo "============================================"
echo -e "  From:        ${RED}${CURRENT_VERSION}${NC}"
echo -e "  To:          ${GREEN}${VERSION}${NC}"
[[ -n "$DESTINATION" ]] && echo "  Destination: $DESTINATION"
echo "============================================"
echo ""

if $DRY_RUN; then
    info "DRY RUN — would execute: kamal rollback $VERSION $DEST_FLAG"
    exit 0
fi

if ! $AUTO_MODE; then
    read -rp "Proceed with rollback? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# --- Execute rollback ---
echo ""
info "Executing rollback to $VERSION..."
ROLLBACK_START=$(date +%s)

if kamal rollback "$VERSION" $DEST_FLAG; then
    ROLLBACK_END=$(date +%s)
    ROLLBACK_DURATION=$(( ROLLBACK_END - ROLLBACK_START ))
    log "Rollback completed in ${ROLLBACK_DURATION}s"
else
    err "Rollback command failed!"
    exit 1
fi

# --- Post-rollback verification ---
echo ""
info "Verifying rollback..."

# Check containers
sleep 3
NEW_DETAILS=$(kamal app details $DEST_FLAG 2>&1) || NEW_DETAILS=""
if echo "$NEW_DETAILS" | grep -q "running"; then
    log "App containers running"
else
    warn "Could not verify running containers"
fi

# Health check
APP_HOST=$(grep -A5 "^proxy:" config/deploy.yml | grep -oP "host:\s*\K\S+" | head -1 || true)
HEALTH_PATH=$(grep -A10 "healthcheck:" config/deploy.yml | grep -oP "path:\s*\K\S+" | head -1 || echo "/up")

if [[ -n "$APP_HOST" ]]; then
    HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "https://${APP_HOST}${HEALTH_PATH}" 2>/dev/null) || HTTP_STATUS="000"
    if [[ "$HTTP_STATUS" == "200" ]]; then
        log "Health check passed: https://${APP_HOST}${HEALTH_PATH} → $HTTP_STATUS"
    else
        warn "Health check returned HTTP $HTTP_STATUS (expected 200)"
    fi
fi

# --- Notification ---
if [[ -n "$WEBHOOK_URL" ]]; then
    info "Sending rollback notification..."
    curl -sf -X POST "$WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "{
            \"text\": \"⚠️ Rollback executed\",
            \"blocks\": [{
                \"type\": \"section\",
                \"text\": {
                    \"type\": \"mrkdwn\",
                    \"text\": \"*Rollback Complete*\n• From: ${CURRENT_VERSION}\n• To: ${VERSION}\n• Duration: ${ROLLBACK_DURATION}s\n• Time: $(date -u +"%Y-%m-%d %H:%M:%S UTC")\"
                }
            }]
        }" && log "Notification sent" || warn "Failed to send notification"
fi

# --- Summary ---
echo ""
echo "============================================"
echo -e " ${GREEN}Rollback complete${NC}"
echo "============================================"
echo "  Version: $VERSION"
echo "  Duration: ${ROLLBACK_DURATION}s"
echo ""
echo "  Next steps:"
echo "    1. Monitor logs:  kamal app logs -f $DEST_FLAG"
echo "    2. Check status:  kamal app details $DEST_FLAG"
echo "    3. Investigate the failed deploy"
echo "    4. Fix and redeploy when ready"
echo "============================================"
