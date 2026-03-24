#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# backup-restore.sh
# Create and restore Meilisearch dumps; view snapshot configuration.
#
# Subcommands:
#   dump-create     Create a new dump
#   dump-download   Copy a dump file from the Docker container to the host
#   dump-restore    Stop Meilisearch and restart with --import-dump
#   snapshot-info   Show snapshot configuration and list snapshot files
# =============================================================================

# ---------------------------------------------------------------------------
# Color output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Configurable variables (override via environment)
# ---------------------------------------------------------------------------
MEILI_URL="${MEILI_URL:-http://localhost:7700}"
MEILI_MASTER_KEY="${MEILI_MASTER_KEY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-meilisearch}"
BACKUP_DIR="${BACKUP_DIR:-./meilisearch-backups}"

# Temp files for cleanup
CLEANUP_FILES=()
cleanup() {
    for f in "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Auth header builder
# ---------------------------------------------------------------------------
build_auth_header() {
    if [[ -n "$MEILI_MASTER_KEY" ]]; then
        echo "Authorization: Bearer ${MEILI_MASTER_KEY}"
    fi
}

AUTH_HEADER=""
refresh_auth() {
    AUTH_HEADER=$(build_auth_header)
}
refresh_auth

# Curl wrapper with optional auth
meili_curl() {
    local method="$1"; shift
    local endpoint="$1"; shift
    local args=(-s -X "$method" "${MEILI_URL}${endpoint}")
    if [[ -n "$AUTH_HEADER" ]]; then
        args+=(-H "$AUTH_HEADER")
    fi
    args+=(-H "Content-Type: application/json")
    curl "${args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage_main() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") <subcommand> [options]

Manage Meilisearch dumps and snapshots.

${BOLD}Subcommands:${NC}
  dump-create               Create a new dump of all indexes and settings
  dump-download             Copy the dump file from the Docker container
  dump-restore <file>       Restore Meilisearch from a dump file
  snapshot-info             Show snapshot configuration and list files

${BOLD}Options:${NC}
  -h, --help                Show this help message

${BOLD}Environment variables:${NC}
  MEILI_URL          Meilisearch URL         (default: http://localhost:7700)
  MEILI_MASTER_KEY   Master key for auth     (default: empty)
  CONTAINER_NAME     Docker container name   (default: meilisearch)
  BACKUP_DIR         Local backup directory  (default: ./meilisearch-backups)

${BOLD}Examples:${NC}
  $(basename "$0") dump-create
  $(basename "$0") dump-download
  $(basename "$0") dump-restore ./meilisearch-backups/20240101-120000.dump
  $(basename "$0") snapshot-info
EOF
}

usage_dump_create() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") dump-create

Create a new Meilisearch dump containing all indexes, documents, and settings.
The dump is created inside the Meilisearch container at /meili_data/dumps/.

Use 'dump-download' afterwards to copy it to the host.
EOF
}

usage_dump_download() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") dump-download

Copy all dump files from the Meilisearch Docker container to the local
backup directory (\$BACKUP_DIR, default: ./meilisearch-backups).
EOF
}

usage_dump_restore() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") dump-restore <dump-file>

Restore Meilisearch from a dump file. This will:
  1. Stop the running Meilisearch container
  2. Copy the dump file into the container's data volume
  3. Start a new container with --import-dump
  4. Wait for Meilisearch to become healthy
  5. Verify that indexes are restored

${BOLD}Arguments:${NC}
  <dump-file>   Path to the .dump file on the host
EOF
}

usage_snapshot_info() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") snapshot-info

Display the current snapshot configuration and list any snapshot files
present in the Meilisearch container.
EOF
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_docker() {
    if ! command -v docker &>/dev/null; then
        die "Docker is not installed or not in PATH."
    fi
    if ! docker info &>/dev/null; then
        die "Docker daemon is not running."
    fi
}

require_curl() {
    if ! command -v curl &>/dev/null; then
        die "curl is required but not found."
    fi
}

require_jq() {
    if ! command -v jq &>/dev/null; then
        die "jq is required but not found."
    fi
}

check_meili_reachable() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "${MEILI_URL}/health" 2>/dev/null || echo "000")
    if [[ "$code" != "200" ]]; then
        die "Meilisearch is not reachable at ${MEILI_URL} (HTTP ${code})."
    fi
}

check_container_exists() {
    if ! docker ps -a --format '{{.Names}}' | grep -qw "${CONTAINER_NAME}"; then
        die "Container '${CONTAINER_NAME}' not found."
    fi
}

# ---------------------------------------------------------------------------
# Subcommand: dump-create
# ---------------------------------------------------------------------------
cmd_dump_create() {
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage_dump_create; exit 0 ;;
        esac
    done

    require_curl
    require_jq
    check_meili_reachable

    info "Creating a new dump..."
    RESPONSE=$(meili_curl POST "/dumps")
    TASK_UID=$(echo "$RESPONSE" | jq -r '.taskUid // empty' 2>/dev/null || echo "")

    if [[ -z "$TASK_UID" ]]; then
        ERR=$(echo "$RESPONSE" | jq -r '.message // "unknown error"' 2>/dev/null || echo "unknown")
        die "Failed to create dump: ${ERR}"
    fi

    info "Dump task UID: ${TASK_UID}"
    info "Polling for completion..."

    POLL_TIMEOUT=300
    POLL_START=$(date +%s)

    while true; do
        ELAPSED=$(( $(date +%s) - POLL_START ))
        if (( ELAPSED > POLL_TIMEOUT )); then
            die "Timed out after ${POLL_TIMEOUT}s waiting for dump task."
        fi

        TASK_INFO=$(meili_curl GET "/tasks/${TASK_UID}")
        STATUS=$(echo "$TASK_INFO" | jq -r '.status' 2>/dev/null || echo "unknown")

        case "$STATUS" in
            succeeded)
                DUMP_UID=$(echo "$TASK_INFO" | jq -r '.details.dumpUid // "unknown"' 2>/dev/null || echo "unknown")
                success "Dump created successfully!"
                echo ""
                echo -e "  ${BOLD}Dump UID:${NC}   ${DUMP_UID}"
                echo -e "  ${BOLD}Location:${NC}   /meili_data/dumps/${DUMP_UID}.dump (inside container)"
                echo ""
                echo -e "  Use '${BOLD}$(basename "$0") dump-download${NC}' to copy it to the host."
                return 0
                ;;
            failed)
                ERR_MSG=$(echo "$TASK_INFO" | jq -r '.error.message // "unknown error"' 2>/dev/null || echo "unknown")
                die "Dump creation failed: ${ERR_MSG}"
                ;;
            *)
                printf "\r  Status: %-20s (elapsed: %ds)" "$STATUS" "$ELAPSED"
                sleep 2
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Subcommand: dump-download
# ---------------------------------------------------------------------------
cmd_dump_download() {
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage_dump_download; exit 0 ;;
        esac
    done

    require_docker
    check_container_exists

    mkdir -p "$BACKUP_DIR"

    info "Looking for dump files in container '${CONTAINER_NAME}'..."

    # List dump files inside the container
    DUMP_FILES=$(docker exec "${CONTAINER_NAME}" sh -c 'ls /meili_data/dumps/*.dump 2>/dev/null || true')

    if [[ -z "$DUMP_FILES" ]]; then
        warn "No dump files found in /meili_data/dumps/."
        echo "  Run '$(basename "$0") dump-create' first."
        return 1
    fi

    COPY_COUNT=0
    while IFS= read -r dump_path; do
        [[ -z "$dump_path" ]] && continue
        FILENAME=$(basename "$dump_path")
        DEST="${BACKUP_DIR}/${FILENAME}"

        if [[ -f "$DEST" ]]; then
            warn "Skipping ${FILENAME} (already exists at ${DEST})."
            continue
        fi

        info "Copying ${FILENAME} → ${DEST}..."
        docker cp "${CONTAINER_NAME}:${dump_path}" "$DEST" \
            || { error "Failed to copy ${FILENAME}."; continue; }
        (( COPY_COUNT++ )) || true
        success "Copied ${FILENAME}."
    done <<< "$DUMP_FILES"

    echo ""
    if (( COPY_COUNT > 0 )); then
        success "Downloaded ${COPY_COUNT} dump file(s) to ${BACKUP_DIR}/."
    else
        info "No new dump files to download."
    fi

    echo ""
    echo -e "  ${BOLD}Backup directory:${NC} ${BACKUP_DIR}"
    ls -lh "${BACKUP_DIR}"/*.dump 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Subcommand: dump-restore
# ---------------------------------------------------------------------------
cmd_dump_restore() {
    # Parse subcommand args
    local DUMP_FILE=""
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage_dump_restore; exit 0 ;;
            *) DUMP_FILE="$arg" ;;
        esac
    done

    if [[ -z "$DUMP_FILE" ]]; then
        die "Dump file path required. Usage: $(basename "$0") dump-restore <file>"
    fi

    if [[ ! -f "$DUMP_FILE" ]]; then
        die "Dump file not found: ${DUMP_FILE}"
    fi

    require_docker
    check_container_exists

    DUMP_FILE_ABS=$(cd "$(dirname "$DUMP_FILE")" && pwd)/$(basename "$DUMP_FILE")
    DUMP_FILENAME=$(basename "$DUMP_FILE")

    # --- Capture current container configuration ---
    info "Inspecting current container configuration..."

    # Get the image, ports, volumes, and environment from the running container
    CONTAINER_IMAGE=$(docker inspect --format='{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "getmeili/meilisearch:v1.12")

    # Get published port mapping
    HOST_PORT=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || echo "7700")

    # Get volume mounts
    VOLUME_MOUNT=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/meili_data"}}{{.Source}}{{end}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
    VOLUME_NAME=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/meili_data"}}{{.Name}}{{end}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || echo "meilisearch-data")

    # Get environment variables
    MEILI_ENV=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null | grep '^MEILI_ENV=' | head -1 | cut -d= -f2 || echo "production")

    # Try to get the master key from container env if not provided
    if [[ -z "$MEILI_MASTER_KEY" ]]; then
        MEILI_MASTER_KEY=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null | grep '^MEILI_MASTER_KEY=' | head -1 | cut -d= -f2 || echo "")
    fi

    # --- Step 1: Stop the running container ---
    warn "Stopping container '${CONTAINER_NAME}'..."
    docker stop "${CONTAINER_NAME}" &>/dev/null || true
    docker rm "${CONTAINER_NAME}" &>/dev/null || true
    success "Container stopped and removed."

    # --- Step 2: Copy dump file into the volume ---
    # We use a temporary container to copy the dump into the volume
    info "Copying dump file into volume..."
    docker run --rm -v "${VOLUME_NAME}:/meili_data" -v "${DUMP_FILE_ABS}:/tmp/${DUMP_FILENAME}" \
        alpine sh -c "mkdir -p /meili_data/dumps && cp /tmp/${DUMP_FILENAME} /meili_data/dumps/${DUMP_FILENAME}" \
        || die "Failed to copy dump file into volume."
    success "Dump file placed in volume."

    # --- Step 3: Start new container with --import-dump ---
    info "Starting Meilisearch with --import-dump /meili_data/dumps/${DUMP_FILENAME}..."

    DOCKER_ARGS=(-d --name "${CONTAINER_NAME}")
    DOCKER_ARGS+=(-p "${HOST_PORT:-7700}:7700")
    DOCKER_ARGS+=(-v "${VOLUME_NAME}:/meili_data")
    DOCKER_ARGS+=(-e "MEILI_ENV=${MEILI_ENV}")

    if [[ -n "$MEILI_MASTER_KEY" ]]; then
        DOCKER_ARGS+=(-e "MEILI_MASTER_KEY=${MEILI_MASTER_KEY}")
    fi

    DOCKER_ARGS+=(--health-cmd="curl -sf http://localhost:7700/health || exit 1")
    DOCKER_ARGS+=(--health-interval=5s --health-timeout=3s --health-retries=20)

    docker run "${DOCKER_ARGS[@]}" \
        "${CONTAINER_IMAGE}" \
        meilisearch --import-dump "/meili_data/dumps/${DUMP_FILENAME}" \
        || die "Failed to start Meilisearch with dump import."

    success "Container started."

    # --- Step 4: Wait for health ---
    MEILI_URL="http://localhost:${HOST_PORT:-7700}"
    refresh_auth

    info "Waiting for Meilisearch to become healthy..."
    MAX_RETRIES=60
    for (( i=1; i<=MAX_RETRIES; i++ )); do
        if curl -sf "${MEILI_URL}/health" &>/dev/null; then
            success "Meilisearch is healthy (attempt ${i}/${MAX_RETRIES})."
            break
        fi
        if (( i == MAX_RETRIES )); then
            error "Meilisearch did not become healthy after ${MAX_RETRIES} attempts."
            echo "  Check logs: docker logs ${CONTAINER_NAME}"
            exit 1
        fi
        sleep 2
    done

    # --- Step 5: Verify indexes ---
    info "Verifying restored indexes..."
    INDEXES_RESP=$(meili_curl GET "/indexes?limit=100")
    INDEX_COUNT=$(echo "$INDEXES_RESP" | jq -r '.results | length' 2>/dev/null || echo "0")

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║           Dump Restore Complete                              ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Dump file:${NC}    ${DUMP_FILE_ABS}"
    echo -e "  ${BOLD}Container:${NC}    ${CONTAINER_NAME}"
    echo -e "  ${BOLD}URL:${NC}          ${MEILI_URL}"
    echo -e "  ${BOLD}Indexes:${NC}      ${INDEX_COUNT} restored"
    echo ""

    if (( INDEX_COUNT > 0 )); then
        echo -e "  ${BOLD}Restored indexes:${NC}"
        echo "$INDEXES_RESP" | jq -r '.results[] | "    - \(.uid) (\(.numberOfDocuments) documents)"' 2>/dev/null || true
        echo ""
    fi

    success "Restore complete."
}

# ---------------------------------------------------------------------------
# Subcommand: snapshot-info
# ---------------------------------------------------------------------------
cmd_snapshot_info() {
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage_snapshot_info; exit 0 ;;
        esac
    done

    require_docker
    require_curl

    echo ""
    echo -e "${BOLD}Snapshot Configuration${NC}"
    echo -e "${BOLD}──────────────────────${NC}"

    # Check if Meilisearch is running and get config
    if curl -sf "${MEILI_URL}/health" &>/dev/null; then
        success "Meilisearch is running at ${MEILI_URL}."

        # Try to get version info
        VERSION_RESP=$(meili_curl GET "/version" 2>/dev/null || echo "{}")
        PKG_VERSION=$(echo "$VERSION_RESP" | jq -r '.pkgVersion // "unknown"' 2>/dev/null || echo "unknown")
        echo -e "  ${BOLD}Version:${NC}      ${PKG_VERSION}"
    else
        warn "Meilisearch is not reachable at ${MEILI_URL}."
    fi

    echo ""

    # Check container for snapshot configuration
    check_container_exists

    # Look for snapshot-related environment variables
    info "Container environment:"
    SNAPSHOT_ENABLED=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null \
        | grep -i 'MEILI_SCHEDULE_SNAPSHOT' | head -1 || echo "")
    SNAPSHOT_DIR=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null \
        | grep -i 'MEILI_SNAPSHOT_DIR' | head -1 || echo "")

    if [[ -n "$SNAPSHOT_ENABLED" ]]; then
        echo -e "  ${BOLD}Schedule:${NC}     ${SNAPSHOT_ENABLED}"
    else
        echo -e "  ${BOLD}Schedule:${NC}     ${YELLOW}Not configured${NC} (set MEILI_SCHEDULE_SNAPSHOT=true)"
    fi

    if [[ -n "$SNAPSHOT_DIR" ]]; then
        echo -e "  ${BOLD}Directory:${NC}    ${SNAPSHOT_DIR}"
    else
        echo -e "  ${BOLD}Directory:${NC}    /meili_data/snapshots (default)"
    fi

    echo ""

    # List snapshot files in the container
    info "Snapshot files in container:"
    SNAP_FILES=$(docker exec "${CONTAINER_NAME}" sh -c 'find /meili_data/snapshots -type f 2>/dev/null || true' 2>/dev/null || echo "")

    if [[ -z "$SNAP_FILES" ]]; then
        echo -e "  ${YELLOW}No snapshot files found.${NC}"
        echo ""
        echo -e "  ${BOLD}To enable scheduled snapshots, restart with:${NC}"
        echo "    docker run ... -e MEILI_SCHEDULE_SNAPSHOT=true getmeili/meilisearch"
    else
        echo "$SNAP_FILES" | while IFS= read -r snap; do
            [[ -z "$snap" ]] && continue
            # Get file size
            SIZE=$(docker exec "${CONTAINER_NAME}" sh -c "du -h '${snap}' 2>/dev/null | cut -f1" 2>/dev/null || echo "?")
            MTIME=$(docker exec "${CONTAINER_NAME}" sh -c "stat -c '%y' '${snap}' 2>/dev/null | cut -d. -f1" 2>/dev/null || echo "?")
            echo -e "  ${GREEN}●${NC} ${snap}  (${SIZE}, ${MTIME})"
        done
    fi

    echo ""

    # List dump files too
    info "Dump files in container:"
    DUMP_FILES=$(docker exec "${CONTAINER_NAME}" sh -c 'ls /meili_data/dumps/*.dump 2>/dev/null || true' 2>/dev/null || echo "")

    if [[ -z "$DUMP_FILES" ]]; then
        echo -e "  ${YELLOW}No dump files found.${NC}"
    else
        echo "$DUMP_FILES" | while IFS= read -r dump; do
            [[ -z "$dump" ]] && continue
            SIZE=$(docker exec "${CONTAINER_NAME}" sh -c "du -h '${dump}' 2>/dev/null | cut -f1" 2>/dev/null || echo "?")
            echo -e "  ${GREEN}●${NC} ${dump}  (${SIZE})"
        done
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    usage_main
    exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
    dump-create)    cmd_dump_create "$@" ;;
    dump-download)  cmd_dump_download "$@" ;;
    dump-restore)   cmd_dump_restore "$@" ;;
    snapshot-info)  cmd_snapshot_info "$@" ;;
    -h|--help)      usage_main; exit 0 ;;
    *)              die "Unknown subcommand: ${SUBCOMMAND}. Use -h for help." ;;
esac
