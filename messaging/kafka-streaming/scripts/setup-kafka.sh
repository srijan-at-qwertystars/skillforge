#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-kafka.sh — Docker-based Kafka cluster setup (KRaft or ZooKeeper mode)
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ASSETS_DIR="${SCRIPT_DIR}/../assets"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.kafka.yml"

# Defaults
MODE="kraft"
TEARDOWN=false
KAFKA_CONTAINER="kafka"
KAFKA_PORT=9092
BOOTSTRAP_SERVER="localhost:${KAFKA_PORT}"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging helpers ──────────────────────────────────────────────────────────
info()    { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
header()  { printf "\n${BOLD}── %s ──${NC}\n" "$*"; }

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") [OPTIONS]

Docker-based Apache Kafka setup script.

${BOLD}Options:${NC}
  --kraft            Use KRaft mode (default, no ZooKeeper)
  --zookeeper        Use ZooKeeper mode instead of KRaft
  --teardown         Stop and remove all Kafka containers/volumes
  -h, --help         Show this help message

${BOLD}Examples:${NC}
  $(basename "$0")               # Start Kafka in KRaft mode
  $(basename "$0") --zookeeper   # Start Kafka with ZooKeeper
  $(basename "$0") --teardown    # Tear down the cluster

EOF
}

# ── Parse arguments ──────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kraft)      MODE="kraft";    shift ;;
            --zookeeper)  MODE="zookeeper"; shift ;;
            --teardown)   TEARDOWN=true;   shift ;;
            -h|--help)    usage; exit 0 ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ── Generate KRaft docker-compose ────────────────────────────────────────────
generate_kraft_compose() {
    info "Generating KRaft-mode docker-compose file"
    cat > "${COMPOSE_FILE}" <<'YAML'
version: "3.9"
services:
  kafka:
    image: apache/kafka:3.7.0
    container_name: kafka
    hostname: kafka
    ports:
      - "9092:9092"
      - "9093:9093"
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_LOG_DIRS: /tmp/kraft-combined-logs
      CLUSTER_ID: MkU3OEVBNTcwNTJENDM2Qk
    healthcheck:
      test: ["CMD-SHELL", "/opt/kafka/bin/kafka-metadata.sh status -snapshot /tmp/kraft-combined-logs/__cluster_metadata-0/00000000000000000000.log 2>/dev/null || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 10
      start_period: 30s
YAML
}

# ── Generate ZooKeeper docker-compose ────────────────────────────────────────
generate_zookeeper_compose() {
    info "Generating ZooKeeper-mode docker-compose file"
    cat > "${COMPOSE_FILE}" <<'YAML'
version: "3.9"
services:
  zookeeper:
    image: confluentinc/cp-zookeeper:7.6.0
    container_name: zookeeper
    hostname: zookeeper
    ports:
      - "2181:2181"
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    healthcheck:
      test: ["CMD", "echo", "ruok", "|", "nc", "localhost", "2181"]
      interval: 10s
      timeout: 5s
      retries: 5

  kafka:
    image: confluentinc/cp-kafka:7.6.0
    container_name: kafka
    hostname: kafka
    depends_on:
      zookeeper:
        condition: service_healthy
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
    healthcheck:
      test: ["CMD-SHELL", "kafka-broker-api-versions --bootstrap-server localhost:9092 > /dev/null 2>&1"]
      interval: 10s
      timeout: 10s
      retries: 10
      start_period: 30s
YAML
}

# ── Generate or locate compose file ─────────────────────────────────────────
prepare_compose_file() {
    # Check for an existing compose file in assets/
    local assets_compose="${ASSETS_DIR}/docker-compose.kafka.yml"
    if [[ -f "${assets_compose}" ]]; then
        info "Found existing compose file in assets/ — copying"
        cp "${assets_compose}" "${COMPOSE_FILE}"
        return
    fi

    # Otherwise generate one dynamically
    case "${MODE}" in
        kraft)      generate_kraft_compose ;;
        zookeeper)  generate_zookeeper_compose ;;
    esac
}

# ── Start the cluster ────────────────────────────────────────────────────────
start_cluster() {
    header "Starting Kafka cluster (${MODE} mode)"
    docker compose -f "${COMPOSE_FILE}" up -d
    success "Containers started"
}

# ── Wait for Kafka to become healthy ────────────────────────────────────────
wait_for_kafka() {
    header "Waiting for Kafka to be healthy"

    local max_attempts=30
    local attempt=1

    while [[ ${attempt} -le ${max_attempts} ]]; do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "${KAFKA_CONTAINER}" 2>/dev/null || echo "not_found")

        case "${status}" in
            healthy)
                success "Kafka is healthy (attempt ${attempt}/${max_attempts})"
                return 0
                ;;
            not_found)
                error "Container '${KAFKA_CONTAINER}' not found"
                exit 1
                ;;
            *)
                info "Status: ${status} — retrying in 5s (${attempt}/${max_attempts})"
                sleep 5
                ;;
        esac
        ((attempt++))
    done

    error "Kafka did not become healthy after ${max_attempts} attempts"
    exit 1
}

# ── Helper: run kafka CLI inside the container ───────────────────────────────
kafka_exec() {
    docker exec "${KAFKA_CONTAINER}" "$@"
}

# ── Create sample topics ────────────────────────────────────────────────────
create_topics() {
    header "Creating sample topics"

    local kafka_topics_cmd
    kafka_topics_cmd=$(docker exec "${KAFKA_CONTAINER}" sh -c \
        'if [ -f /opt/kafka/bin/kafka-topics.sh ]; then echo /opt/kafka/bin/kafka-topics.sh; else echo kafka-topics; fi')

    # test-topic: 3 partitions, RF 1
    info "Creating topic: test-topic (3 partitions, RF=1)"
    kafka_exec ${kafka_topics_cmd} \
        --bootstrap-server localhost:9092 \
        --create --if-not-exists \
        --topic test-topic \
        --partitions 3 \
        --replication-factor 1 && success "test-topic created"

    # orders: 6 partitions, RF 1
    info "Creating topic: orders (6 partitions, RF=1)"
    kafka_exec ${kafka_topics_cmd} \
        --bootstrap-server localhost:9092 \
        --create --if-not-exists \
        --topic orders \
        --partitions 6 \
        --replication-factor 1 && success "orders created"

    # user-events: 3 partitions, RF 1, compacted
    info "Creating topic: user-events (3 partitions, RF=1, compacted)"
    kafka_exec ${kafka_topics_cmd} \
        --bootstrap-server localhost:9092 \
        --create --if-not-exists \
        --topic user-events \
        --partitions 3 \
        --replication-factor 1 \
        --config cleanup.policy=compact && success "user-events created"

    info "Listing topics:"
    kafka_exec ${kafka_topics_cmd} \
        --bootstrap-server localhost:9092 \
        --list
}

# ── Produce test messages ────────────────────────────────────────────────────
produce_test_messages() {
    header "Producing test messages to test-topic"

    local kafka_console_producer
    kafka_console_producer=$(docker exec "${KAFKA_CONTAINER}" sh -c \
        'if [ -f /opt/kafka/bin/kafka-console-producer.sh ]; then echo /opt/kafka/bin/kafka-console-producer.sh; else echo kafka-console-producer; fi')

    for i in $(seq 1 5); do
        echo "test-message-${i} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    done | kafka_exec ${kafka_console_producer} \
        --bootstrap-server localhost:9092 \
        --topic test-topic

    success "Produced 5 test messages"
}

# ── Consume test messages ────────────────────────────────────────────────────
consume_test_messages() {
    header "Consuming messages from test-topic"

    local kafka_console_consumer
    kafka_console_consumer=$(docker exec "${KAFKA_CONTAINER}" sh -c \
        'if [ -f /opt/kafka/bin/kafka-console-consumer.sh ]; then echo /opt/kafka/bin/kafka-console-consumer.sh; else echo kafka-console-consumer; fi')

    info "Reading messages (from beginning, timeout 10s):"
    kafka_exec ${kafka_console_consumer} \
        --bootstrap-server localhost:9092 \
        --topic test-topic \
        --from-beginning \
        --timeout-ms 10000 || true

    success "Consumption complete"
}

# ── Teardown ─────────────────────────────────────────────────────────────────
teardown() {
    header "Tearing down Kafka cluster"

    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        warn "No compose file found at ${COMPOSE_FILE} — nothing to tear down"
        exit 0
    fi

    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
    rm -f "${COMPOSE_FILE}"
    success "Cluster removed and compose file cleaned up"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    if [[ "${TEARDOWN}" == true ]]; then
        teardown
        exit 0
    fi

    # Preflight checks
    if ! command -v docker &>/dev/null; then
        error "docker is not installed or not in PATH"
        exit 1
    fi
    if ! docker compose version &>/dev/null; then
        error "docker compose plugin is not available"
        exit 1
    fi

    prepare_compose_file
    start_cluster
    wait_for_kafka
    create_topics
    produce_test_messages
    consume_test_messages

    header "Setup complete"
    success "Kafka is running at ${BOOTSTRAP_SERVER}"
    info "Tear down later with: $(basename "$0") --teardown"
}

main "$@"
