#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-meilisearch.sh
# Sets up Meilisearch with Docker, creates API keys, configures an initial
# index with sample movie data.
# =============================================================================

# ---------------------------------------------------------------------------
# Color output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Configurable variables (override via environment)
# ---------------------------------------------------------------------------
MEILI_VERSION="${MEILI_VERSION:-v1.12}"
MEILI_PORT="${MEILI_PORT:-7700}"
MEILI_MASTER_KEY="${MEILI_MASTER_KEY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-meilisearch}"
VOLUME_NAME="${VOLUME_NAME:-meilisearch-data}"

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") [-h|--help]

Set up a Meilisearch instance via Docker with sample data.

${BOLD}Environment variables (all optional):${NC}
  MEILI_VERSION      Meilisearch image tag       (default: v1.12)
  MEILI_PORT         Host port to expose          (default: 7700)
  MEILI_MASTER_KEY   Master key for auth          (default: auto-generated)
  CONTAINER_NAME     Docker container name        (default: meilisearch)
  VOLUME_NAME        Docker volume for data       (default: meilisearch-data)

${BOLD}Examples:${NC}
  $(basename "$0")
  MEILI_PORT=7701 MEILI_MASTER_KEY=my-secret $(basename "$0")
EOF
}

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $arg. Use -h for help." ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    die "Docker is not installed or not in PATH. Please install Docker first."
fi

if ! docker info &>/dev/null; then
    die "Docker daemon is not running. Please start Docker and try again."
fi

if ! command -v curl &>/dev/null; then
    die "curl is required but not found. Please install curl."
fi

if ! command -v jq &>/dev/null; then
    warn "jq is not installed – JSON output will not be pretty-printed."
    JQ_CMD="cat"
else
    JQ_CMD="jq ."
fi

# Generate a master key if one was not provided
if [[ -z "$MEILI_MASTER_KEY" ]]; then
    MEILI_MASTER_KEY="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
    info "Generated random master key: ${BOLD}${MEILI_MASTER_KEY}${NC}"
fi

MEILI_URL="http://localhost:${MEILI_PORT}"

# ---------------------------------------------------------------------------
# Helper: authenticated curl wrapper
# ---------------------------------------------------------------------------
meili_curl() {
    local method="$1"; shift
    local endpoint="$1"; shift
    curl -s -X "$method" \
        "${MEILI_URL}${endpoint}" \
        -H "Authorization: Bearer ${MEILI_MASTER_KEY}" \
        -H "Content-Type: application/json" \
        "$@"
}

# ---------------------------------------------------------------------------
# Step 1: Pull and start Meilisearch container
# ---------------------------------------------------------------------------
info "Pulling Meilisearch image (getmeili/meilisearch:${MEILI_VERSION})..."
docker pull "getmeili/meilisearch:${MEILI_VERSION}" || die "Failed to pull Meilisearch image."

# Remove any pre-existing container with the same name
if docker ps -a --format '{{.Names}}' | grep -qw "${CONTAINER_NAME}"; then
    warn "Removing existing container '${CONTAINER_NAME}'..."
    docker rm -f "${CONTAINER_NAME}" &>/dev/null || true
fi

info "Starting Meilisearch container..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${MEILI_PORT}:7700" \
    -v "${VOLUME_NAME}:/meili_data" \
    -e "MEILI_ENV=production" \
    -e "MEILI_MASTER_KEY=${MEILI_MASTER_KEY}" \
    --health-cmd="curl -sf http://localhost:7700/health || exit 1" \
    --health-interval=5s \
    --health-timeout=3s \
    --health-retries=10 \
    "getmeili/meilisearch:${MEILI_VERSION}" \
    || die "Failed to start Meilisearch container."

success "Container '${CONTAINER_NAME}' started."

# ---------------------------------------------------------------------------
# Step 2: Wait for Meilisearch to be healthy
# ---------------------------------------------------------------------------
info "Waiting for Meilisearch to become healthy..."
MAX_RETRIES=30
RETRY_INTERVAL=2
for (( i=1; i<=MAX_RETRIES; i++ )); do
    if curl -sf "${MEILI_URL}/health" &>/dev/null; then
        success "Meilisearch is healthy (attempt ${i}/${MAX_RETRIES})."
        break
    fi
    if (( i == MAX_RETRIES )); then
        die "Meilisearch did not become healthy after $((MAX_RETRIES * RETRY_INTERVAL))s."
    fi
    sleep "$RETRY_INTERVAL"
done

# ---------------------------------------------------------------------------
# Step 3: Create API keys
# ---------------------------------------------------------------------------
info "Creating API keys..."

SEARCH_KEY_RESPONSE=$(meili_curl POST "/keys" -d '{
    "description": "Search-only API key",
    "actions": ["search"],
    "indexes": ["*"],
    "expiresAt": null
}')
SEARCH_API_KEY=$(echo "$SEARCH_KEY_RESPONSE" | jq -r '.key // empty' 2>/dev/null || echo "")

ADMIN_KEY_RESPONSE=$(meili_curl POST "/keys" -d '{
    "description": "Admin API key",
    "actions": ["*"],
    "indexes": ["*"],
    "expiresAt": null
}')
ADMIN_API_KEY=$(echo "$ADMIN_KEY_RESPONSE" | jq -r '.key // empty' 2>/dev/null || echo "")

if [[ -z "$SEARCH_API_KEY" || -z "$ADMIN_API_KEY" ]]; then
    warn "Could not parse created API keys. Check manually via GET /keys."
else
    success "API keys created."
fi

# ---------------------------------------------------------------------------
# Step 4: Create the "movies" index
# ---------------------------------------------------------------------------
info "Creating 'movies' index with primary key 'id'..."
CREATE_INDEX_RESP=$(meili_curl POST "/indexes" -d '{
    "uid": "movies",
    "primaryKey": "id"
}')
CREATE_TASK_UID=$(echo "$CREATE_INDEX_RESP" | jq -r '.taskUid // empty' 2>/dev/null || echo "")
info "Index creation task UID: ${CREATE_TASK_UID:-unknown}"

# Wait for index creation to finish
if [[ -n "$CREATE_TASK_UID" ]]; then
    for (( i=1; i<=20; i++ )); do
        STATUS=$(meili_curl GET "/tasks/${CREATE_TASK_UID}" | jq -r '.status' 2>/dev/null || echo "")
        if [[ "$STATUS" == "succeeded" ]]; then
            success "Index 'movies' created."
            break
        elif [[ "$STATUS" == "failed" ]]; then
            die "Index creation failed. Check GET /tasks/${CREATE_TASK_UID} for details."
        fi
        sleep 1
    done
fi

# ---------------------------------------------------------------------------
# Step 5: Configure index settings
# ---------------------------------------------------------------------------
info "Configuring index settings..."
meili_curl PATCH "/indexes/movies/settings" -d '{
    "searchableAttributes": [
        "title",
        "description",
        "genre"
    ],
    "filterableAttributes": [
        "genre",
        "year",
        "rating",
        "_geo"
    ],
    "sortableAttributes": [
        "year",
        "rating",
        "title"
    ],
    "rankingRules": [
        "words",
        "typo",
        "proximity",
        "attribute",
        "sort",
        "exactness",
        "year:desc",
        "rating:desc"
    ]
}' >/dev/null

success "Index settings configured."

# ---------------------------------------------------------------------------
# Step 6: Add sample movie documents
# ---------------------------------------------------------------------------
info "Adding sample movie documents..."
ADD_DOCS_RESP=$(meili_curl POST "/indexes/movies/documents" -d '[
    {
        "id": 1,
        "title": "Inception",
        "genre": "Sci-Fi",
        "year": 2010,
        "rating": 8.8,
        "description": "A thief who steals corporate secrets through dream-sharing technology is given the task of planting an idea into the mind of a C.E.O.",
        "_geo": { "lat": 34.0522, "lng": -118.2437 }
    },
    {
        "id": 2,
        "title": "The Shawshank Redemption",
        "genre": "Drama",
        "year": 1994,
        "rating": 9.3,
        "description": "Two imprisoned men bond over a number of years, finding solace and eventual redemption through acts of common decency.",
        "_geo": { "lat": 40.3573, "lng": -82.9816 }
    },
    {
        "id": 3,
        "title": "Pulp Fiction",
        "genre": "Crime",
        "year": 1994,
        "rating": 8.9,
        "description": "The lives of two mob hitmen, a boxer, a gangster and his wife intertwine in four tales of violence and redemption.",
        "_geo": { "lat": 34.0522, "lng": -118.2437 }
    },
    {
        "id": 4,
        "title": "The Dark Knight",
        "genre": "Action",
        "year": 2008,
        "rating": 9.0,
        "description": "When the menace known as the Joker wreaks havoc on Gotham, Batman must accept one of the greatest psychological tests of his ability to fight injustice.",
        "_geo": { "lat": 41.8781, "lng": -87.6298 }
    },
    {
        "id": 5,
        "title": "Spirited Away",
        "genre": "Animation",
        "year": 2001,
        "rating": 8.6,
        "description": "During her family'\''s move to the suburbs, a sullen 10-year-old girl wanders into a world ruled by gods, witches, and spirits.",
        "_geo": { "lat": 35.6762, "lng": 139.6503 }
    },
    {
        "id": 6,
        "title": "Interstellar",
        "genre": "Sci-Fi",
        "year": 2014,
        "rating": 8.7,
        "description": "A team of explorers travel through a wormhole in space in an attempt to ensure humanity'\''s survival.",
        "_geo": { "lat": 34.0522, "lng": -118.2437 }
    },
    {
        "id": 7,
        "title": "Parasite",
        "genre": "Thriller",
        "year": 2019,
        "rating": 8.5,
        "description": "Greed and class discrimination threaten the newly formed symbiotic relationship between the wealthy Park family and the destitute Kim clan.",
        "_geo": { "lat": 37.5665, "lng": 126.9780 }
    },
    {
        "id": 8,
        "title": "The Grand Budapest Hotel",
        "genre": "Comedy",
        "year": 2014,
        "rating": 8.1,
        "description": "A writer encounters the owner of an aging high-class hotel who tells the tale of his early years serving as a lobby boy.",
        "_geo": { "lat": 50.9375, "lng": 14.1370 }
    }
]')

DOCS_TASK_UID=$(echo "$ADD_DOCS_RESP" | jq -r '.taskUid // empty' 2>/dev/null || echo "")
info "Document indexing task UID: ${DOCS_TASK_UID:-unknown}"

# ---------------------------------------------------------------------------
# Step 7: Wait for indexing to complete
# ---------------------------------------------------------------------------
if [[ -n "$DOCS_TASK_UID" ]]; then
    info "Waiting for indexing to complete..."
    for (( i=1; i<=30; i++ )); do
        TASK_INFO=$(meili_curl GET "/tasks/${DOCS_TASK_UID}")
        STATUS=$(echo "$TASK_INFO" | jq -r '.status' 2>/dev/null || echo "")
        if [[ "$STATUS" == "succeeded" ]]; then
            INDEXED_COUNT=$(echo "$TASK_INFO" | jq -r '.details.indexedDocuments // "unknown"' 2>/dev/null || echo "unknown")
            success "Indexing complete – ${INDEXED_COUNT} documents indexed."
            break
        elif [[ "$STATUS" == "failed" ]]; then
            ERROR_MSG=$(echo "$TASK_INFO" | jq -r '.error.message // "unknown error"' 2>/dev/null || echo "unknown")
            die "Indexing failed: ${ERROR_MSG}"
        fi
        sleep 1
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║           Meilisearch Setup Complete!                        ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Dashboard:${NC}       ${MEILI_URL}"
echo -e "  ${BOLD}Health check:${NC}    ${MEILI_URL}/health"
echo -e "  ${BOLD}Version:${NC}         ${MEILI_VERSION}"
echo -e "  ${BOLD}Container:${NC}       ${CONTAINER_NAME}"
echo ""
echo -e "  ${BOLD}Master Key:${NC}      ${MEILI_MASTER_KEY}"
echo -e "  ${BOLD}Search API Key:${NC}  ${SEARCH_API_KEY:-<check GET /keys>}"
echo -e "  ${BOLD}Admin API Key:${NC}   ${ADMIN_API_KEY:-<check GET /keys>}"
echo ""
echo -e "  ${BOLD}Sample index:${NC}    movies (8 documents)"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Try a search:"
echo "     curl '${MEILI_URL}/indexes/movies/search' \\"
echo "       -H 'Authorization: Bearer ${SEARCH_API_KEY:-<SEARCH_KEY>}' \\"
echo "       -d '{\"q\": \"sci-fi space\"}'"
echo ""
echo "  2. Open the mini-dashboard:"
echo "     ${MEILI_URL}"
echo ""
echo "  3. Bulk import data:"
echo "     ./bulk-import.sh -f data.json -i my-index -k '${ADMIN_API_KEY:-<ADMIN_KEY>}'"
echo ""
