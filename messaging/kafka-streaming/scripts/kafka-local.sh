#!/usr/bin/env bash
# =============================================================================
# kafka-local.sh — Start a local Kafka cluster with KRaft (no ZooKeeper) using Docker.
#
# Usage:
#   ./kafka-local.sh [start|stop|status] [topic1 topic2 ...]
#
# Examples:
#   ./kafka-local.sh start                    # Start Kafka, create default topics
#   ./kafka-local.sh start orders events      # Start Kafka, create specified topics
#   ./kafka-local.sh stop                     # Stop and remove containers
#   ./kafka-local.sh status                   # Show container and topic status
#
# Requirements: docker
# =============================================================================

set -euo pipefail

CONTAINER_NAME="kafka-kraft-local"
KAFKA_IMAGE="apache/kafka:3.9.0"
KAFKA_PORT="${KAFKA_PORT:-9092}"
CONTROLLER_PORT="9093"

DEFAULT_TOPICS=("test-topic" "test-events")

usage() {
    echo "Usage: $0 [start|stop|status] [topic1 topic2 ...]"
    echo ""
    echo "Commands:"
    echo "  start   Start local Kafka broker with KRaft (default)"
    echo "  stop    Stop and remove the Kafka container"
    echo "  status  Show container status and list topics"
    echo ""
    echo "Arguments:"
    echo "  topic1 topic2 ...   Optional topic names to create (default: test-topic test-events)"
    echo ""
    echo "Environment:"
    echo "  KAFKA_PORT   Host port for Kafka (default: 9092)"
    exit 1
}

wait_for_kafka() {
    echo "Waiting for Kafka to be ready..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if docker exec "$CONTAINER_NAME" \
            /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list &>/dev/null; then
            echo "Kafka is ready."
            return 0
        fi
        retries=$((retries - 1))
        sleep 2
    done
    echo "ERROR: Kafka failed to start within 60 seconds."
    docker logs "$CONTAINER_NAME" --tail 30
    exit 1
}

start_kafka() {
    local topics=("${@}")
    if [ ${#topics[@]} -eq 0 ]; then
        topics=("${DEFAULT_TOPICS[@]}")
    fi

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Kafka is already running (container: $CONTAINER_NAME)"
    else
        # Remove stopped container if exists
        docker rm -f "$CONTAINER_NAME" &>/dev/null || true

        echo "Starting Kafka with KRaft on port $KAFKA_PORT..."
        docker run -d \
            --name "$CONTAINER_NAME" \
            -p "${KAFKA_PORT}:9092" \
            -e KAFKA_NODE_ID=1 \
            -e KAFKA_PROCESS_ROLES=broker,controller \
            -e KAFKA_LISTENERS="PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:${CONTROLLER_PORT}" \
            -e KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://localhost:${KAFKA_PORT}" \
            -e KAFKA_CONTROLLER_QUORUM_VOTERS="1@localhost:${CONTROLLER_PORT}" \
            -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
            -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT" \
            -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
            -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
            -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
            -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
            "$KAFKA_IMAGE"

        wait_for_kafka
    fi

    echo ""
    echo "Creating topics..."
    for topic in "${topics[@]}"; do
        if docker exec "$CONTAINER_NAME" \
            /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
            --describe --topic "$topic" &>/dev/null; then
            echo "  Topic '$topic' already exists."
        else
            docker exec "$CONTAINER_NAME" \
                /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
                --create --topic "$topic" --partitions 3 --replication-factor 1
            echo "  Created topic '$topic' (3 partitions, RF=1)."
        fi
    done

    echo ""
    echo "Producing test messages..."
    for topic in "${topics[@]}"; do
        for i in 1 2 3; do
            echo "key-${i}:test-message-${i}-$(date -u +%Y%m%dT%H%M%SZ)" | \
                docker exec -i "$CONTAINER_NAME" \
                /opt/kafka/bin/kafka-console-producer.sh \
                --bootstrap-server localhost:9092 \
                --topic "$topic" \
                --property "parse.key=true" \
                --property "key.separator=:"
        done
        echo "  Produced 3 test messages to '$topic'."
    done

    echo ""
    echo "Kafka is running at localhost:${KAFKA_PORT}"
    echo "Stop with: $0 stop"
}

stop_kafka() {
    echo "Stopping Kafka..."
    docker rm -f "$CONTAINER_NAME" &>/dev/null && echo "Kafka stopped." || echo "Kafka is not running."
}

show_status() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Kafka is RUNNING (container: $CONTAINER_NAME)"
        echo ""
        echo "Topics:"
        docker exec "$CONTAINER_NAME" \
            /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
        echo ""
        echo "Topic details:"
        docker exec "$CONTAINER_NAME" \
            /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe
    else
        echo "Kafka is NOT running."
    fi
}

# --- Main ---
ACTION="${1:-start}"
shift || true

case "$ACTION" in
    start)   start_kafka "$@" ;;
    stop)    stop_kafka ;;
    status)  show_status ;;
    -h|--help|help) usage ;;
    *)       echo "Unknown action: $ACTION"; usage ;;
esac
