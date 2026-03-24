#!/usr/bin/env bash
# =============================================================================
# topic-management.sh — Create, describe, alter, and delete Kafka topics.
#
# Usage:
#   ./topic-management.sh <action> <topic-name> [options]
#
# Actions:
#   create    Create a new topic
#   describe  Show topic details (partitions, replicas, config)
#   alter     Alter topic configuration
#   delete    Delete a topic
#   list      List all topics
#
# Examples:
#   ./topic-management.sh create orders -p 12 -r 3
#   ./topic-management.sh create events -p 6 -r 3 --config retention.ms=86400000
#   ./topic-management.sh describe orders
#   ./topic-management.sh alter orders --config retention.ms=604800000
#   ./topic-management.sh alter orders --partitions 24
#   ./topic-management.sh delete orders
#   ./topic-management.sh list
#
# Environment:
#   BOOTSTRAP       Bootstrap server (default: localhost:9092)
#   COMMAND_CONFIG  Path to client properties file for auth (optional)
#
# Requirements: kafka-topics.sh and kafka-configs.sh in PATH
# =============================================================================

set -euo pipefail

BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
COMMAND_CONFIG="${COMMAND_CONFIG:-}"

# Defaults for create
PARTITIONS=6
REPLICATION_FACTOR=1
TOPIC_CONFIGS=()

usage() {
    echo "Usage: $0 <action> <topic-name> [options]"
    echo ""
    echo "Actions:"
    echo "  create    Create a new topic"
    echo "  describe  Show topic details"
    echo "  alter     Alter topic configuration"
    echo "  delete    Delete a topic"
    echo "  list      List all topics"
    echo ""
    echo "Options for 'create':"
    echo "  -p, --partitions N       Number of partitions (default: 6)"
    echo "  -r, --replication-factor N  Replication factor (default: 1)"
    echo "  --config KEY=VALUE       Topic config (repeatable)"
    echo ""
    echo "Options for 'alter':"
    echo "  --partitions N           Increase partition count"
    echo "  --config KEY=VALUE       Set/update topic config (repeatable)"
    echo "  --delete-config KEY      Remove topic config override"
    echo ""
    echo "Environment:"
    echo "  BOOTSTRAP=$BOOTSTRAP"
    exit 1
}

base_topics_cmd() {
    local cmd="kafka-topics.sh --bootstrap-server $BOOTSTRAP"
    if [ -n "$COMMAND_CONFIG" ]; then
        cmd="$cmd --command-config $COMMAND_CONFIG"
    fi
    echo "$cmd"
}

base_configs_cmd() {
    local cmd="kafka-configs.sh --bootstrap-server $BOOTSTRAP"
    if [ -n "$COMMAND_CONFIG" ]; then
        cmd="$cmd --command-config $COMMAND_CONFIG"
    fi
    echo "$cmd"
}

do_create() {
    local topic="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--partitions)      PARTITIONS="$2"; shift 2 ;;
            -r|--replication-factor) REPLICATION_FACTOR="$2"; shift 2 ;;
            --config)             TOPIC_CONFIGS+=("$2"); shift 2 ;;
            *)                    echo "Unknown option: $1"; usage ;;
        esac
    done

    local cmd
    cmd="$(base_topics_cmd) --create --topic $topic --partitions $PARTITIONS --replication-factor $REPLICATION_FACTOR"

    for cfg in "${TOPIC_CONFIGS[@]+"${TOPIC_CONFIGS[@]}"}"; do
        cmd="$cmd --config $cfg"
    done

    echo "Creating topic '$topic' (partitions=$PARTITIONS, RF=$REPLICATION_FACTOR)..."
    eval "$cmd"
    echo "Topic '$topic' created successfully."
    echo ""
    eval "$(base_topics_cmd) --describe --topic $topic"
}

do_describe() {
    local topic="$1"
    echo "=== Topic: $topic ==="
    eval "$(base_topics_cmd) --describe --topic $topic"
    echo ""
    echo "=== Configuration ==="
    eval "$(base_configs_cmd) --entity-type topics --entity-name $topic --describe"
}

do_alter() {
    local topic="$1"
    shift

    local new_partitions=""
    local configs_to_set=()
    local configs_to_delete=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --partitions)     new_partitions="$2"; shift 2 ;;
            --config)         configs_to_set+=("$2"); shift 2 ;;
            --delete-config)  configs_to_delete+=("$2"); shift 2 ;;
            *)                echo "Unknown option: $1"; usage ;;
        esac
    done

    if [ -n "$new_partitions" ]; then
        echo "Increasing partition count for '$topic' to $new_partitions..."
        eval "$(base_topics_cmd) --alter --topic $topic --partitions $new_partitions"
        echo "Partition count updated."
    fi

    for cfg in "${configs_to_set[@]+"${configs_to_set[@]}"}"; do
        echo "Setting config '$cfg' on topic '$topic'..."
        eval "$(base_configs_cmd) --entity-type topics --entity-name $topic --alter --add-config $cfg"
    done

    for cfg in "${configs_to_delete[@]+"${configs_to_delete[@]}"}"; do
        echo "Removing config '$cfg' from topic '$topic'..."
        eval "$(base_configs_cmd) --entity-type topics --entity-name $topic --alter --delete-config $cfg"
    done

    echo ""
    echo "Current state:"
    do_describe "$topic"
}

do_delete() {
    local topic="$1"
    echo "Deleting topic '$topic'..."
    read -r -p "Are you sure? This cannot be undone. [y/N] " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY])
            eval "$(base_topics_cmd) --delete --topic $topic"
            echo "Topic '$topic' deleted."
            ;;
        *)
            echo "Cancelled."
            ;;
    esac
}

do_list() {
    echo "Topics on $BOOTSTRAP:"
    echo ""
    eval "$(base_topics_cmd) --list"
}

# --- Main ---
ACTION="${1:-}"
TOPIC="${2:-}"

[ -z "$ACTION" ] && usage

case "$ACTION" in
    list)
        do_list
        ;;
    create|describe|alter|delete)
        [ -z "$TOPIC" ] && { echo "ERROR: Topic name required."; usage; }
        shift 2
        case "$ACTION" in
            create)   do_create "$TOPIC" "$@" ;;
            describe) do_describe "$TOPIC" ;;
            alter)    do_alter "$TOPIC" "$@" ;;
            delete)   do_delete "$TOPIC" ;;
        esac
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown action: $ACTION"
        usage
        ;;
esac
