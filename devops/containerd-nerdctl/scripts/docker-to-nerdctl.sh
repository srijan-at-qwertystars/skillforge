#!/usr/bin/env bash
# docker-to-nerdctl.sh — Migration helper: exports Docker images and imports
# them into a containerd namespace via nerdctl.
#
# Usage: sudo ./docker-to-nerdctl.sh [OPTIONS]
#
# Options:
#   --namespace <ns>    Target containerd namespace (default: "default")
#   --images <list>     Comma-separated image list to migrate (default: all)
#   --export-dir <dir>  Directory for image tar archives (default: /tmp/docker-migration)
#   --skip-export       Skip export step (use existing tarballs in export-dir)
#   --skip-import       Skip import step (only export)
#   --volumes           Also migrate Docker volumes
#   --networks          Also recreate Docker networks in nerdctl
#   --cleanup           Remove exported tarballs after import
#   --dry-run           Show what would be done without doing it
#   --help              Show this help message

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# Defaults
NAMESPACE="default"
IMAGE_LIST=""
EXPORT_DIR="/tmp/docker-migration"
SKIP_EXPORT=false
SKIP_IMPORT=false
MIGRATE_VOLUMES=false
MIGRATE_NETWORKS=false
CLEANUP=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)    NAMESPACE="$2"; shift 2 ;;
        --images)       IMAGE_LIST="$2"; shift 2 ;;
        --export-dir)   EXPORT_DIR="$2"; shift 2 ;;
        --skip-export)  SKIP_EXPORT=true; shift ;;
        --skip-import)  SKIP_IMPORT=true; shift ;;
        --volumes)      MIGRATE_VOLUMES=true; shift ;;
        --networks)     MIGRATE_NETWORKS=true; shift ;;
        --cleanup)      CLEANUP=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --help|-h)
            head -17 "$0" | tail -16
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Validate prerequisites
check_prerequisites() {
    if ! $SKIP_EXPORT; then
        command -v docker &>/dev/null || die "Docker CLI not found. Install Docker or use --skip-export."
        docker info &>/dev/null || die "Docker daemon not responding. Start Docker or use --skip-export."
    fi
    if ! $SKIP_IMPORT; then
        command -v nerdctl &>/dev/null || die "nerdctl not found. Install nerdctl first."
        nerdctl info &>/dev/null || die "containerd not responding. Start containerd first."
    fi
}

# Get list of images to migrate
get_image_list() {
    if [[ -n "$IMAGE_LIST" ]]; then
        echo "$IMAGE_LIST" | tr ',' '\n'
    else
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>'
    fi
}

# Export Docker images
export_images() {
    local images
    images=$(get_image_list)
    local count
    count=$(echo "$images" | wc -l)

    info "Exporting ${count} Docker images to ${EXPORT_DIR}/"
    mkdir -p "$EXPORT_DIR"

    local i=0
    while IFS= read -r image; do
        i=$((i + 1))
        # Create safe filename
        local safe_name
        safe_name=$(echo "$image" | tr '/:' '__')
        local tarfile="${EXPORT_DIR}/${safe_name}.tar"

        if [[ -f "$tarfile" ]]; then
            warn "[${i}/${count}] Skipping ${image} — tarball already exists"
            continue
        fi

        if $DRY_RUN; then
            info "[${i}/${count}] Would export: ${image} → ${tarfile}"
        else
            info "[${i}/${count}] Exporting: ${image}"
            if docker save -o "$tarfile" "$image" 2>/dev/null; then
                local size
                size=$(du -sh "$tarfile" | awk '{print $1}')
                info "  → ${tarfile} (${size})"
            else
                warn "  Failed to export ${image} — skipping"
                rm -f "$tarfile"
            fi
        fi
    done <<< "$images"

    info "Export complete. Tarballs in ${EXPORT_DIR}/"
}

# Import images into containerd via nerdctl
import_images() {
    local tarballs
    tarballs=$(ls "${EXPORT_DIR}"/*.tar 2>/dev/null || true)

    if [[ -z "$tarballs" ]]; then
        die "No tarballs found in ${EXPORT_DIR}/. Run export first or check the directory."
    fi

    local count
    count=$(echo "$tarballs" | wc -l)
    info "Importing ${count} image tarballs into containerd namespace '${NAMESPACE}'"

    local i=0 success=0 failed=0
    for tarfile in ${EXPORT_DIR}/*.tar; do
        i=$((i + 1))
        local basename
        basename=$(basename "$tarfile")

        if $DRY_RUN; then
            info "[${i}/${count}] Would import: ${basename} → namespace '${NAMESPACE}'"
        else
            info "[${i}/${count}] Importing: ${basename}"
            if nerdctl --namespace "$NAMESPACE" load -i "$tarfile" 2>/dev/null; then
                success=$((success + 1))
            else
                warn "  Failed to import ${basename}"
                failed=$((failed + 1))
            fi
        fi
    done

    info "Import complete: ${success} succeeded, ${failed} failed"
}

# Migrate Docker volumes
migrate_volumes() {
    info "Migrating Docker volumes..."

    local volumes
    volumes=$(docker volume ls -q 2>/dev/null || true)

    if [[ -z "$volumes" ]]; then
        info "No Docker volumes found."
        return
    fi

    local count
    count=$(echo "$volumes" | wc -l)
    info "Found ${count} Docker volumes"

    local vol_dir="${EXPORT_DIR}/volumes"
    mkdir -p "$vol_dir"

    local i=0
    while IFS= read -r vol; do
        i=$((i + 1))

        if $DRY_RUN; then
            info "[${i}/${count}] Would migrate volume: ${vol}"
            continue
        fi

        info "[${i}/${count}] Migrating volume: ${vol}"

        # Export from Docker
        local vol_tar="${vol_dir}/${vol}.tar.gz"
        if [[ ! -f "$vol_tar" ]]; then
            docker run --rm -v "${vol}":/data -v "${vol_dir}":/backup alpine \
                tar czf "/backup/${vol}.tar.gz" -C /data . 2>/dev/null || {
                    warn "  Failed to export volume ${vol}"
                    continue
                }
        fi

        # Create nerdctl volume and import
        nerdctl volume create "$vol" 2>/dev/null || true
        nerdctl run --rm -v "${vol}":/data -v "${vol_dir}":/backup alpine \
            sh -c "cd /data && tar xzf /backup/${vol}.tar.gz" 2>/dev/null || {
                warn "  Failed to import volume ${vol}"
                continue
            }

        info "  ✓ Volume ${vol} migrated"
    done <<< "$volumes"
}

# Recreate Docker networks in nerdctl
migrate_networks() {
    info "Migrating Docker networks..."

    local networks
    networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v -E '^(bridge|host|none)$' || true)

    if [[ -z "$networks" ]]; then
        info "No custom Docker networks found."
        return
    fi

    while IFS= read -r net; do
        local subnet gateway
        subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "")
        gateway=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo "")

        if $DRY_RUN; then
            info "Would create network: ${net} (subnet: ${subnet:-auto})"
            continue
        fi

        info "Creating network: ${net}"
        local cmd="nerdctl network create"
        [[ -n "$subnet" ]] && cmd+=" --subnet $subnet"
        [[ -n "$gateway" ]] && cmd+=" --gateway $gateway"
        cmd+=" $net"

        if eval "$cmd" 2>/dev/null; then
            info "  ✓ Network ${net} created"
        else
            warn "  Network ${net} may already exist or failed to create"
        fi
    done <<< "$networks"
}

# Cleanup exported tarballs
cleanup_exports() {
    if [[ -d "$EXPORT_DIR" ]]; then
        info "Cleaning up ${EXPORT_DIR}/"
        if $DRY_RUN; then
            info "Would remove: ${EXPORT_DIR}/"
        else
            rm -rf "$EXPORT_DIR"
            info "Cleanup complete."
        fi
    fi
}

# Print summary
print_summary() {
    echo ""
    echo -e "${BLUE}=== Migration Summary ===${NC}"

    if ! $SKIP_IMPORT && command -v nerdctl &>/dev/null; then
        local img_count
        img_count=$(nerdctl --namespace "$NAMESPACE" images -q 2>/dev/null | wc -l || echo "0")
        echo -e "  Images in namespace '${NAMESPACE}': ${img_count}"

        if $MIGRATE_VOLUMES; then
            local vol_count
            vol_count=$(nerdctl volume ls -q 2>/dev/null | wc -l || echo "0")
            echo -e "  Volumes: ${vol_count}"
        fi

        if $MIGRATE_NETWORKS; then
            local net_count
            net_count=$(nerdctl network ls --format '{{.Name}}' 2>/dev/null | wc -l || echo "0")
            echo -e "  Networks: ${net_count}"
        fi
    fi

    echo ""
    echo -e "${GREEN}Next steps:${NC}"
    echo "  1. Verify images:  nerdctl --namespace ${NAMESPACE} images"
    echo "  2. Test a container: nerdctl --namespace ${NAMESPACE} run --rm <image> echo hello"
    echo "  3. Start compose:  nerdctl compose up -d"
    echo "  4. Alias docker:   alias docker=nerdctl"
    echo ""
    if ! $SKIP_EXPORT && ! $CLEANUP; then
        echo -e "  ${YELLOW}Exported tarballs are in ${EXPORT_DIR}/${NC}"
        echo -e "  ${YELLOW}Run with --cleanup to remove them after verification.${NC}"
    fi
}

# Main
main() {
    echo -e "${BLUE}Docker → containerd/nerdctl Migration${NC}"
    echo "───────────────────────────────────────"

    if $DRY_RUN; then
        warn "DRY RUN — no changes will be made"
        echo ""
    fi

    check_prerequisites

    if ! $SKIP_EXPORT; then
        export_images
    fi

    if ! $SKIP_IMPORT; then
        import_images
    fi

    if $MIGRATE_VOLUMES; then
        migrate_volumes
    fi

    if $MIGRATE_NETWORKS; then
        migrate_networks
    fi

    if $CLEANUP; then
        cleanup_exports
    fi

    print_summary
}

main
