#!/usr/bin/env bash
# compose-cleanup.sh — Clean up orphan containers, unused volumes, and dangling images
#                       from Docker Compose projects
#
# Usage:
#   ./compose-cleanup.sh              # interactive mode (confirms before each step)
#   ./compose-cleanup.sh --force      # skip confirmations
#   ./compose-cleanup.sh --dry-run    # show what would be cleaned without removing
#   ./compose-cleanup.sh --project myapp  # target a specific project
#
# Cleans:
#   - Stopped/orphan containers from Compose projects
#   - Unused named volumes (not attached to any container)
#   - Dangling images (<none> tags from failed/old builds)
#   - Unused networks from Compose projects
#   - Build cache (optional)

set -euo pipefail

FORCE=false
DRY_RUN=false
PROJECT=""

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f)   FORCE=true; shift ;;
        --dry-run|-n) DRY_RUN=true; shift ;;
        --project|-p) PROJECT="$2"; shift 2 ;;
        -h|--help)
            head -14 "$0" | tail -12
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

confirm() {
    if $FORCE || $DRY_RUN; then return 0; fi
    read -rp "$(echo -e "${YELLOW}$1 [y/N]:${NC} ")" answer
    [[ "$answer" =~ ^[Yy] ]]
}

run() {
    if $DRY_RUN; then
        echo -e "${CYAN}[DRY RUN]${NC} $*"
    else
        "$@"
    fi
}

echo "═══════════════════════════════════════════"
echo " Docker Compose Cleanup"
$DRY_RUN && echo -e " ${CYAN}(dry-run mode)${NC}"
echo "═══════════════════════════════════════════"
echo ""

# --- Disk usage before ---
echo -e "${CYAN}Current disk usage:${NC}"
docker system df 2>/dev/null || true
echo ""

# --- 1. Orphan & stopped containers ---
echo -e "${CYAN}── Orphan & Stopped Containers ──${NC}"
if [[ -n "$PROJECT" ]]; then
    STOPPED=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
        --filter "status=exited" --filter "status=dead" --format "{{.ID}} {{.Names}}" 2>/dev/null || true)
else
    STOPPED=$(docker ps -a --filter "status=exited" --filter "status=dead" \
        --format "{{.ID}} {{.Names}}" 2>/dev/null || true)
fi

if [[ -n "$STOPPED" ]]; then
    echo "$STOPPED" | while read -r id name; do
        echo "  - $name ($id)"
    done
    if confirm "Remove stopped containers?"; then
        CONTAINER_IDS=$(echo "$STOPPED" | awk '{print $1}')
        run docker rm $CONTAINER_IDS
        echo -e "${GREEN}✓ Removed stopped containers${NC}"
    fi
else
    echo -e "${GREEN}  No stopped containers found${NC}"
fi
echo ""

# --- 2. Remove orphans via compose down ---
if [[ -n "$PROJECT" ]]; then
    echo -e "${CYAN}── Compose Orphan Cleanup (project: $PROJECT) ──${NC}"
    if confirm "Run 'docker compose down --remove-orphans' for project $PROJECT?"; then
        run docker compose -p "$PROJECT" down --remove-orphans 2>/dev/null || true
        echo -e "${GREEN}✓ Orphans removed for project ${PROJECT}${NC}"
    fi
    echo ""
fi

# --- 3. Dangling images ---
echo -e "${CYAN}── Dangling Images ──${NC}"
DANGLING=$(docker images -f "dangling=true" --format "{{.ID}} {{.Size}}" 2>/dev/null || true)
if [[ -n "$DANGLING" ]]; then
    DANGLING_COUNT=$(echo "$DANGLING" | wc -l)
    DANGLING_SIZE=$(docker images -f "dangling=true" --format "{{.Size}}" 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo "unknown")
    echo "  Found $DANGLING_COUNT dangling image(s)"
    echo "$DANGLING" | head -10 | while read -r id size; do
        echo "  - $id ($size)"
    done
    if confirm "Remove dangling images?"; then
        run docker image prune -f
        echo -e "${GREEN}✓ Dangling images removed${NC}"
    fi
else
    echo -e "${GREEN}  No dangling images found${NC}"
fi
echo ""

# --- 4. Unused volumes ---
echo -e "${CYAN}── Unused Volumes ──${NC}"
UNUSED_VOLS=$(docker volume ls -f "dangling=true" --format "{{.Name}}" 2>/dev/null || true)
if [[ -n "$UNUSED_VOLS" ]]; then
    VOL_COUNT=$(echo "$UNUSED_VOLS" | wc -l)
    echo "  Found $VOL_COUNT unused volume(s):"
    echo "$UNUSED_VOLS" | head -20 | while read -r vol; do
        echo "  - $vol"
    done
    if confirm "Remove unused volumes? (WARNING: data will be lost)"; then
        run docker volume prune -f
        echo -e "${GREEN}✓ Unused volumes removed${NC}"
    fi
else
    echo -e "${GREEN}  No unused volumes found${NC}"
fi
echo ""

# --- 5. Unused networks ---
echo -e "${CYAN}── Unused Networks ──${NC}"
UNUSED_NETS=$(docker network ls --filter "type=custom" --format "{{.Name}}" 2>/dev/null || true)
if [[ -n "$UNUSED_NETS" ]]; then
    if confirm "Prune unused networks?"; then
        run docker network prune -f
        echo -e "${GREEN}✓ Unused networks pruned${NC}"
    fi
else
    echo -e "${GREEN}  No unused custom networks found${NC}"
fi
echo ""

# --- 6. Build cache ---
echo -e "${CYAN}── Build Cache ──${NC}"
CACHE_SIZE=$(docker system df --format "{{.Size}}" 2>/dev/null | tail -1 || echo "unknown")
echo "  Build cache size: $CACHE_SIZE"
if confirm "Prune build cache?"; then
    run docker builder prune -f
    echo -e "${GREEN}✓ Build cache pruned${NC}"
fi
echo ""

# --- Summary ---
echo "═══════════════════════════════════════════"
echo -e "${GREEN} Cleanup complete!${NC}"
$DRY_RUN && echo -e " ${CYAN}(dry-run — nothing was actually removed)${NC}"
echo ""
echo -e "${CYAN}Disk usage after:${NC}"
docker system df 2>/dev/null || true
