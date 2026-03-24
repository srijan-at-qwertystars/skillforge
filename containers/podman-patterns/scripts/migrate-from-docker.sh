#!/usr/bin/env bash
# =============================================================================
# migrate-from-docker.sh — Migrate Docker containers, images, and volumes to Podman
#
# Usage:
#   ./migrate-from-docker.sh [OPTIONS]
#
# Options:
#   --images       Migrate all Docker images to Podman
#   --volumes      Migrate all Docker volumes to Podman
#   --containers   Export running Docker container configs (as podman run commands)
#   --compose      Convert docker-compose.yml for Podman compatibility
#   --all          Migrate everything (images + volumes + containers + compose)
#   --dry-run      Show what would be done without executing
#   --help         Show this help message
#
# Prerequisites:
#   - Docker and Podman both installed
#   - Sufficient disk space for image/volume migration
#   - Run as the user who will own Podman resources (not root, unless intended)
#
# Examples:
#   ./migrate-from-docker.sh --all
#   ./migrate-from-docker.sh --images --volumes
#   ./migrate-from-docker.sh --all --dry-run
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MIGRATE_IMAGES=false
MIGRATE_VOLUMES=false
MIGRATE_CONTAINERS=false
MIGRATE_COMPOSE=false
DRY_RUN=false
TMPDIR="${TMPDIR:-/tmp}/podman-migration-$$"

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    sed -n '/^# Usage:/,/^# =====/p' "$0" | sed 's/^# //' | head -n -1
    exit 0
}

cleanup() {
    if [[ -d "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi

    if ! command -v podman &>/dev/null; then
        log_error "Podman is not installed or not in PATH"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running or not accessible"
        exit 1
    fi

    if ! podman info &>/dev/null; then
        log_error "Podman is not accessible"
        exit 1
    fi

    log_ok "Docker version: $(docker --version | awk '{print $3}' | tr -d ',')"
    log_ok "Podman version: $(podman --version | awk '{print $3}')"

    mkdir -p "$TMPDIR"
}

migrate_images() {
    log_info "=== Migrating Docker images to Podman ==="

    local images
    images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>')

    if [[ -z "$images" ]]; then
        log_warn "No Docker images found to migrate"
        return
    fi

    local count=0
    local total
    total=$(echo "$images" | wc -l)

    while IFS= read -r image; do
        count=$((count + 1))
        log_info "[$count/$total] Migrating image: $image"

        if $DRY_RUN; then
            echo "  Would run: docker save '$image' | podman load"
            continue
        fi

        # Check if image already exists in Podman
        if podman image exists "$image" 2>/dev/null; then
            log_warn "  Image already exists in Podman, skipping: $image"
            continue
        fi

        # Pipe directly to avoid large temp files
        if docker save "$image" | podman load; then
            log_ok "  Migrated: $image"
        else
            log_error "  Failed to migrate: $image"
        fi
    done <<< "$images"

    log_ok "Image migration complete ($count images processed)"
}

migrate_volumes() {
    log_info "=== Migrating Docker volumes to Podman ==="

    local volumes
    volumes=$(docker volume ls -q)

    if [[ -z "$volumes" ]]; then
        log_warn "No Docker volumes found to migrate"
        return
    fi

    local count=0
    local total
    total=$(echo "$volumes" | wc -l)

    while IFS= read -r vol; do
        count=$((count + 1))
        log_info "[$count/$total] Migrating volume: $vol"

        if $DRY_RUN; then
            echo "  Would export Docker volume '$vol' and import to Podman"
            continue
        fi

        # Check if volume already exists in Podman
        if podman volume exists "$vol" 2>/dev/null; then
            log_warn "  Volume already exists in Podman, skipping: $vol"
            continue
        fi

        # Create Podman volume
        podman volume create "$vol"

        # Export from Docker and import to Podman
        local archive="$TMPDIR/${vol}.tar.gz"
        if docker run --rm -v "${vol}:/data:ro" -v "$TMPDIR:/backup" \
            alpine tar czf "/backup/${vol}.tar.gz" -C /data .; then

            if podman run --rm -v "${vol}:/data" -v "$TMPDIR:/backup:Z" \
                alpine tar xzf "/backup/${vol}.tar.gz" -C /data; then
                log_ok "  Migrated: $vol"
            else
                log_error "  Failed to import volume: $vol"
            fi

            rm -f "$archive"
        else
            log_error "  Failed to export volume: $vol"
        fi
    done <<< "$volumes"

    log_ok "Volume migration complete ($count volumes processed)"
}

migrate_containers() {
    log_info "=== Generating Podman run commands from Docker containers ==="

    local containers
    containers=$(docker ps -a --format '{{.ID}} {{.Names}}')

    if [[ -z "$containers" ]]; then
        log_warn "No Docker containers found"
        return
    fi

    local output_file="$TMPDIR/podman-run-commands.sh"
    echo "#!/usr/bin/env bash" > "$output_file"
    echo "# Podman run commands generated from Docker containers" >> "$output_file"
    echo "# Generated on: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$output_file"
    echo "" >> "$output_file"

    local count=0
    while IFS=' ' read -r cid cname; do
        count=$((count + 1))
        log_info "Processing container: $cname ($cid)"

        # Extract container configuration
        local image ports envs volumes cmd
        image=$(docker inspect --format '{{.Config.Image}}' "$cid")
        cmd=$(docker inspect --format '{{join .Config.Cmd " "}}' "$cid" 2>/dev/null || echo "")

        echo "# Container: $cname" >> "$output_file"
        echo -n "podman run -d --name $cname" >> "$output_file"

        # Port mappings
        while IFS= read -r port; do
            [[ -n "$port" ]] && echo -n " -p $port" >> "$output_file"
        done < <(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostIp}}:{{.HostPort}}:{{$p}}{{"\n"}}{{end}}{{end}}' "$cid" 2>/dev/null | sed 's|0\.0\.0\.0:||')

        # Environment variables
        while IFS= read -r env; do
            [[ -n "$env" ]] && echo -n " -e '$env'" >> "$output_file"
        done < <(docker inspect --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$cid" 2>/dev/null | grep -v '^PATH=' | grep -v '^HOME=')

        # Volume mounts
        while IFS= read -r mount; do
            [[ -n "$mount" ]] && echo -n " -v $mount" >> "$output_file"
        done < <(docker inspect --format '{{range .Mounts}}{{.Source}}:{{.Destination}}:{{if .RW}}rw{{else}}ro{{end}}{{"\n"}}{{end}}' "$cid" 2>/dev/null)

        # Restart policy
        local restart
        restart=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null)
        [[ "$restart" != "no" && -n "$restart" ]] && echo -n " --restart=$restart" >> "$output_file"

        echo -n " $image" >> "$output_file"
        [[ -n "$cmd" ]] && echo -n " $cmd" >> "$output_file"
        echo "" >> "$output_file"
        echo "" >> "$output_file"

    done <<< "$containers"

    if $DRY_RUN; then
        log_info "Generated commands (dry-run):"
        cat "$output_file"
    else
        local dest="./podman-run-commands.sh"
        cp "$output_file" "$dest"
        chmod +x "$dest"
        log_ok "Generated: $dest ($count containers)"
        log_info "Review and run: ./$dest"
    fi
}

migrate_compose() {
    log_info "=== Checking Docker Compose files for Podman compatibility ==="

    local compose_files=()
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$f" ]] && compose_files+=("$f")
    done

    if [[ ${#compose_files[@]} -eq 0 ]]; then
        log_warn "No compose files found in current directory"
        return
    fi

    for compose_file in "${compose_files[@]}"; do
        log_info "Checking: $compose_file"

        # Check for Docker-specific features
        local issues=()

        if grep -q 'network_mode:\s*"bridge"' "$compose_file" 2>/dev/null; then
            issues+=("network_mode: bridge — works but rootless may differ")
        fi

        if grep -q 'privileged:\s*true' "$compose_file" 2>/dev/null; then
            issues+=("privileged: true — requires rootful Podman or --privileged")
        fi

        if grep -q 'docker.sock' "$compose_file" 2>/dev/null; then
            issues+=("docker.sock mount — replace with podman.sock path")
        fi

        if grep -qE '^\s+- "[0-9]+:[0-9]+"' "$compose_file" 2>/dev/null; then
            local low_ports
            low_ports=$(grep -oP '"(\d+):' "$compose_file" | grep -oP '\d+' | awk '$1 < 1024')
            if [[ -n "$low_ports" ]]; then
                issues+=("Ports < 1024 require net.ipv4.ip_unprivileged_port_start=0 for rootless")
            fi
        fi

        if [[ ${#issues[@]} -eq 0 ]]; then
            log_ok "  No compatibility issues found"
            log_info "  Run with: podman compose -f $compose_file up -d"
        else
            log_warn "  Potential issues found:"
            for issue in "${issues[@]}"; do
                echo "    - $issue"
            done
        fi

        # Suggest SELinux volume labels
        if grep -qE '^\s+- \.?/' "$compose_file" 2>/dev/null; then
            log_info "  Tip: Add :Z to bind mounts for SELinux compatibility"
        fi
    done
}

# --- Parse arguments ---
if [[ $# -eq 0 ]]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --images)     MIGRATE_IMAGES=true ;;
        --volumes)    MIGRATE_VOLUMES=true ;;
        --containers) MIGRATE_CONTAINERS=true ;;
        --compose)    MIGRATE_COMPOSE=true ;;
        --all)
            MIGRATE_IMAGES=true
            MIGRATE_VOLUMES=true
            MIGRATE_CONTAINERS=true
            MIGRATE_COMPOSE=true
            ;;
        --dry-run)    DRY_RUN=true ;;
        --help|-h)    usage ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
    shift
done

# --- Main ---
echo "============================================"
echo "  Docker → Podman Migration Tool"
echo "============================================"
$DRY_RUN && log_warn "DRY RUN MODE — no changes will be made"

check_prerequisites

$MIGRATE_IMAGES     && migrate_images
$MIGRATE_VOLUMES    && migrate_volumes
$MIGRATE_CONTAINERS && migrate_containers
$MIGRATE_COMPOSE    && migrate_compose

echo ""
log_ok "Migration complete!"
log_info "Next steps:"
echo "  1. Verify migrated images: podman images"
echo "  2. Verify migrated volumes: podman volume ls"
echo "  3. Test containers with: podman run ..."
echo "  4. Set up alias: alias docker=podman"
echo "  5. Consider converting to Quadlet for production services"
