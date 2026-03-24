#!/usr/bin/env bash
# =============================================================================
# consumer-lag-check.sh — Check consumer lag for all consumer groups or a specific group.
#
# Usage:
#   ./consumer-lag-check.sh [group-name]
#
# Examples:
#   ./consumer-lag-check.sh                       # Show lag for all consumer groups
#   ./consumer-lag-check.sh payment-processor     # Show lag for specific group
#   BOOTSTRAP=broker1:9092 ./consumer-lag-check.sh  # Custom bootstrap server
#
# Environment:
#   BOOTSTRAP          Bootstrap server (default: localhost:9092)
#   COMMAND_CONFIG     Path to client properties file for auth (optional)
#   LAG_THRESHOLD      Lag threshold for warnings (default: 1000)
#
# Requirements: kafka-consumer-groups.sh in PATH or Kafka installed
# =============================================================================

set -euo pipefail

BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
COMMAND_CONFIG="${COMMAND_CONFIG:-}"
LAG_THRESHOLD="${LAG_THRESHOLD:-1000}"
GROUP_NAME="${1:-}"

# Build base command with optional auth config
build_cmd() {
    local cmd="kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP"
    if [ -n "$COMMAND_CONFIG" ]; then
        cmd="$cmd --command-config $COMMAND_CONFIG"
    fi
    echo "$cmd"
}

BASE_CMD=$(build_cmd)

check_group_lag() {
    local group="$1"
    echo "=== Consumer Group: $group ==="

    local output
    output=$($BASE_CMD --describe --group "$group" 2>/dev/null) || {
        echo "  ERROR: Could not describe group '$group'"
        echo ""
        return 1
    }

    # Print header and data
    echo "$output"

    # Check for high lag
    local has_warning=false
    while IFS= read -r line; do
        local lag
        lag=$(echo "$line" | awk '{print $6}' 2>/dev/null) || continue
        if [[ "$lag" =~ ^[0-9]+$ ]] && [ "$lag" -gt "$LAG_THRESHOLD" ]; then
            local topic partition
            topic=$(echo "$line" | awk '{print $2}')
            partition=$(echo "$line" | awk '{print $3}')
            if [ "$has_warning" = false ]; then
                echo ""
                echo "  ⚠  HIGH LAG DETECTED (threshold: $LAG_THRESHOLD):"
                has_warning=true
            fi
            echo "    - $topic partition $partition: lag=$lag"
        fi
    done <<< "$output"

    if [ "$has_warning" = false ]; then
        echo "  ✓ All partitions within lag threshold ($LAG_THRESHOLD)"
    fi
    echo ""
}

summarize_all() {
    echo "=========================================="
    echo " Consumer Lag Report"
    echo " Bootstrap: $BOOTSTRAP"
    echo " Threshold: $LAG_THRESHOLD"
    echo " Time:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "=========================================="
    echo ""

    local groups
    groups=$($BASE_CMD --list 2>/dev/null) || {
        echo "ERROR: Could not list consumer groups. Check bootstrap server: $BOOTSTRAP"
        exit 1
    }

    if [ -z "$groups" ]; then
        echo "No consumer groups found."
        exit 0
    fi

    local total=0
    local warnings=0
    while IFS= read -r group; do
        [ -z "$group" ] && continue
        total=$((total + 1))

        local output
        output=$($BASE_CMD --describe --group "$group" 2>/dev/null) || continue

        local max_lag=0
        while IFS= read -r line; do
            local lag
            lag=$(echo "$line" | awk '{print $6}' 2>/dev/null) || continue
            if [[ "$lag" =~ ^[0-9]+$ ]] && [ "$lag" -gt "$max_lag" ]; then
                max_lag=$lag
            fi
        done <<< "$output"

        local status="✓"
        if [ "$max_lag" -gt "$LAG_THRESHOLD" ]; then
            status="⚠"
            warnings=$((warnings + 1))
        fi

        printf "  %s %-40s max_lag=%s\n" "$status" "$group" "$max_lag"
    done <<< "$groups"

    echo ""
    echo "Summary: $total groups checked, $warnings with high lag"
    echo ""

    # Show details for groups with warnings
    if [ "$warnings" -gt 0 ]; then
        echo "=========================================="
        echo " Details for groups with high lag"
        echo "=========================================="
        echo ""
        while IFS= read -r group; do
            [ -z "$group" ] && continue
            local output
            output=$($BASE_CMD --describe --group "$group" 2>/dev/null) || continue

            local max_lag=0
            while IFS= read -r line; do
                local lag
                lag=$(echo "$line" | awk '{print $6}' 2>/dev/null) || continue
                if [[ "$lag" =~ ^[0-9]+$ ]] && [ "$lag" -gt "$max_lag" ]; then
                    max_lag=$lag
                fi
            done <<< "$output"

            if [ "$max_lag" -gt "$LAG_THRESHOLD" ]; then
                check_group_lag "$group"
            fi
        done <<< "$groups"
    fi
}

# --- Main ---
if [ -n "$GROUP_NAME" ]; then
    check_group_lag "$GROUP_NAME"
else
    summarize_all
fi
