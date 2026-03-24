#!/usr/bin/env bash
# ============================================================================
# setup-selenium-grid.sh — Set up Selenium Grid 4 via Docker Compose
#
# Usage:
#   ./setup-selenium-grid.sh [MODE] [OPTIONS]
#
# Modes:
#   standalone   Single container with Chrome (default)
#   hub-node     Hub + separate browser nodes (Chrome, Firefox, Edge)
#   full-grid    Full grid with video recording and VNC debug access
#
# Options:
#   --chrome-nodes N    Number of Chrome nodes (default: 1)
#   --firefox-nodes N   Number of Firefox nodes (default: 1)
#   --edge-nodes N      Number of Edge nodes (default: 0)
#   --port PORT         Hub port (default: 4444)
#   --video             Enable video recording (auto-enabled in full-grid)
#   --vnc               Use debug images with VNC access
#   --down              Tear down the running grid
#   --status            Show grid status
#   --help              Show this help
#
# Examples:
#   ./setup-selenium-grid.sh standalone
#   ./setup-selenium-grid.sh hub-node --chrome-nodes 3 --firefox-nodes 2
#   ./setup-selenium-grid.sh full-grid --vnc --video
#   ./setup-selenium-grid.sh --down
#   ./setup-selenium-grid.sh --status
# ============================================================================

set -euo pipefail

MODE="${1:-standalone}"
CHROME_NODES=1
FIREFOX_NODES=1
EDGE_NODES=0
PORT=4444
VIDEO=false
VNC=false
PROJECT_NAME="selenium-grid"
COMPOSE_FILE="/tmp/${PROJECT_NAME}-docker-compose.yml"

# Parse arguments
shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --chrome-nodes)  CHROME_NODES="$2"; shift 2 ;;
        --firefox-nodes) FIREFOX_NODES="$2"; shift 2 ;;
        --edge-nodes)    EDGE_NODES="$2"; shift 2 ;;
        --port)          PORT="$2"; shift 2 ;;
        --video)         VIDEO=true; shift ;;
        --vnc)           VNC=true; shift ;;
        --down)
            echo "Tearing down Selenium Grid..."
            docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down -v 2>/dev/null || true
            echo "Grid stopped."
            exit 0
            ;;
        --status)
            echo "Grid status at http://localhost:${PORT}:"
            curl -s "http://localhost:${PORT}/status" | python3 -m json.tool 2>/dev/null || echo "Grid not reachable"
            exit 0
            ;;
        --help)
            head -25 "$0" | tail -23
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required"; exit 1; }
command -v docker compose >/dev/null 2>&1 || { echo "Error: docker compose is required"; exit 1; }

SELENIUM_VERSION="4"
CHROME_IMAGE="selenium/node-chrome:${SELENIUM_VERSION}"
FIREFOX_IMAGE="selenium/node-firefox:${SELENIUM_VERSION}"
EDGE_IMAGE="selenium/node-edge:${SELENIUM_VERSION}"

if [[ "$VNC" == "true" ]]; then
    CHROME_IMAGE="selenium/node-chrome:${SELENIUM_VERSION}-debug"
    FIREFOX_IMAGE="selenium/node-firefox:${SELENIUM_VERSION}-debug"
    EDGE_IMAGE="selenium/node-edge:${SELENIUM_VERSION}-debug"
fi

generate_standalone() {
    cat > "$COMPOSE_FILE" <<YAML
version: "3"
services:
  standalone-chrome:
    image: selenium/standalone-chrome:${SELENIUM_VERSION}
    ports:
      - "${PORT}:4444"
      - "7900:7900"
    shm_size: "2g"
    environment:
      - SE_NODE_MAX_SESSIONS=4
      - SE_NODE_OVERRIDE_MAX_SESSIONS=true
      - SE_VNC_NO_PASSWORD=true
YAML
}

generate_hub_node() {
    cat > "$COMPOSE_FILE" <<YAML
version: "3"
services:
  hub:
    image: selenium/hub:${SELENIUM_VERSION}
    ports:
      - "${PORT}:4444"
    environment:
      - SE_SESSION_REQUEST_TIMEOUT=300
      - SE_NEW_SESSION_WAIT_TIMEOUT=600

YAML

    local vnc_port=7901
    for i in $(seq 1 "$CHROME_NODES"); do
        cat >> "$COMPOSE_FILE" <<YAML
  chrome-${i}:
    image: ${CHROME_IMAGE}
    depends_on:
      - hub
    shm_size: "2g"
    environment:
      - SE_EVENT_BUS_HOST=hub
      - SE_EVENT_BUS_PUBLISH_PORT=4442
      - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
      - SE_NODE_MAX_SESSIONS=2
YAML
        if [[ "$VNC" == "true" ]]; then
            echo "    ports:" >> "$COMPOSE_FILE"
            echo "      - \"${vnc_port}:7900\"" >> "$COMPOSE_FILE"
            echo "      - SE_VNC_NO_PASSWORD=true" >> "$COMPOSE_FILE"
            vnc_port=$((vnc_port + 1))
        fi
        echo "" >> "$COMPOSE_FILE"
    done

    for i in $(seq 1 "$FIREFOX_NODES"); do
        cat >> "$COMPOSE_FILE" <<YAML
  firefox-${i}:
    image: ${FIREFOX_IMAGE}
    depends_on:
      - hub
    shm_size: "2g"
    environment:
      - SE_EVENT_BUS_HOST=hub
      - SE_EVENT_BUS_PUBLISH_PORT=4442
      - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
      - SE_NODE_MAX_SESSIONS=2

YAML
    done

    for i in $(seq 1 "$EDGE_NODES"); do
        cat >> "$COMPOSE_FILE" <<YAML
  edge-${i}:
    image: ${EDGE_IMAGE}
    depends_on:
      - hub
    shm_size: "2g"
    environment:
      - SE_EVENT_BUS_HOST=hub
      - SE_EVENT_BUS_PUBLISH_PORT=4442
      - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
      - SE_NODE_MAX_SESSIONS=2

YAML
    done
}

generate_full_grid() {
    VIDEO=true
    cat > "$COMPOSE_FILE" <<YAML
version: "3"
services:
  hub:
    image: selenium/hub:${SELENIUM_VERSION}
    ports:
      - "${PORT}:4444"
    environment:
      - SE_SESSION_REQUEST_TIMEOUT=300

  chrome:
    image: selenium/node-chrome:${SELENIUM_VERSION}
    depends_on:
      - hub
    shm_size: "2g"
    environment:
      - SE_EVENT_BUS_HOST=hub
      - SE_EVENT_BUS_PUBLISH_PORT=4442
      - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
      - SE_NODE_MAX_SESSIONS=4
      - SE_NODE_OVERRIDE_MAX_SESSIONS=true

  firefox:
    image: selenium/node-firefox:${SELENIUM_VERSION}
    depends_on:
      - hub
    shm_size: "2g"
    environment:
      - SE_EVENT_BUS_HOST=hub
      - SE_EVENT_BUS_PUBLISH_PORT=4442
      - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
      - SE_NODE_MAX_SESSIONS=4

  edge:
    image: selenium/node-edge:${SELENIUM_VERSION}
    depends_on:
      - hub
    shm_size: "2g"
    environment:
      - SE_EVENT_BUS_HOST=hub
      - SE_EVENT_BUS_PUBLISH_PORT=4442
      - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
      - SE_NODE_MAX_SESSIONS=4

  chrome-video:
    image: selenium/video:ffmpeg-6.1-20240402
    depends_on:
      - chrome
    volumes:
      - ./videos:/videos
    environment:
      - DISPLAY_CONTAINER_NAME=chrome
      - SE_VIDEO_FILE_NAME=chrome_video.mp4

  firefox-video:
    image: selenium/video:ffmpeg-6.1-20240402
    depends_on:
      - firefox
    volumes:
      - ./videos:/videos
    environment:
      - DISPLAY_CONTAINER_NAME=firefox
      - SE_VIDEO_FILE_NAME=firefox_video.mp4
YAML
}

echo "Setting up Selenium Grid in '${MODE}' mode..."

case "$MODE" in
    standalone)  generate_standalone ;;
    hub-node)    generate_hub_node ;;
    full-grid)   generate_full_grid ;;
    *)           echo "Unknown mode: $MODE (use standalone, hub-node, or full-grid)"; exit 1 ;;
esac

echo "Generated compose file: $COMPOSE_FILE"
echo ""

# Tear down any existing grid
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down -v 2>/dev/null || true

# Start the grid
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d

echo ""
echo "Waiting for Grid to be ready..."
for i in $(seq 1 60); do
    if curl -s "http://localhost:${PORT}/status" 2>/dev/null | grep -q '"ready":true'; then
        echo "Selenium Grid is ready!"
        echo ""
        echo "  Grid URL:    http://localhost:${PORT}"
        echo "  Grid UI:     http://localhost:${PORT}/ui"
        if [[ "$VNC" == "true" ]]; then
            echo "  VNC Viewer:  http://localhost:7901 (noVNC)"
        fi
        if [[ "$VIDEO" == "true" ]]; then
            echo "  Videos:      ./videos/"
        fi
        echo ""
        echo "  Tear down:   $0 --down"
        exit 0
    fi
    sleep 2
done

echo "Warning: Grid did not become ready within 120 seconds."
echo "Check containers: docker compose -p $PROJECT_NAME -f $COMPOSE_FILE logs"
exit 1
