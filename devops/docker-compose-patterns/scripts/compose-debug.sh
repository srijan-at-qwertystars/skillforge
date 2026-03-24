#!/usr/bin/env bash
# compose-debug.sh — Debug container networking, port mapping, and healthcheck status
#
# Usage:
#   ./compose-debug.sh                    # debug all services in current compose project
#   ./compose-debug.sh api db             # debug specific services
#   ./compose-debug.sh --network          # focus on network debugging
#   ./compose-debug.sh --health           # focus on healthcheck status
#   ./compose-debug.sh --ports            # focus on port mapping
#   ./compose-debug.sh -f compose.prod.yaml  # use specific compose file
#
# Requires: docker CLI

set -euo pipefail

COMPOSE_FILE=""
SERVICES=()
MODE="all"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)    COMPOSE_FILE="$2"; shift 2 ;;
        --network)    MODE="network"; shift ;;
        --health)     MODE="health"; shift ;;
        --ports)      MODE="ports"; shift ;;
        -h|--help)    head -12 "$0" | tail -10; exit 0 ;;
        -*)           echo "Unknown option: $1"; exit 1 ;;
        *)            SERVICES+=("$1"); shift ;;
    esac
done

COMPOSE_ARGS=()
if [[ -n "$COMPOSE_FILE" ]]; then
    COMPOSE_ARGS+=(-f "$COMPOSE_FILE")
fi

header() { echo -e "\n${CYAN}══ $1 ══${NC}"; }
subheader() { echo -e "${CYAN}── $1 ──${NC}"; }

# --- Get project name and services ---
PROJECT=$(docker compose "${COMPOSE_ARGS[@]}" config --format json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || \
    basename "$(pwd)")

if [[ ${#SERVICES[@]} -eq 0 ]]; then
    mapfile -t SERVICES < <(docker compose "${COMPOSE_ARGS[@]}" config --services 2>/dev/null)
fi

echo "═══════════════════════════════════════════"
echo " Compose Debug — Project: ${PROJECT}"
echo " Services: ${SERVICES[*]}"
echo "═══════════════════════════════════════════"

# ──────────────────────────────────────────────
# SERVICE STATUS
# ──────────────────────────────────────────────
if [[ "$MODE" == "all" ]]; then
    header "Service Status"
    docker compose "${COMPOSE_ARGS[@]}" ps -a --format "table {{.Name}}\t{{.Status}}\t{{.State}}\t{{.Ports}}" 2>/dev/null || \
        docker compose "${COMPOSE_ARGS[@]}" ps -a 2>/dev/null
fi

# ──────────────────────────────────────────────
# HEALTHCHECK STATUS
# ──────────────────────────────────────────────
if [[ "$MODE" == "all" || "$MODE" == "health" ]]; then
    header "Healthcheck Status"
    for svc in "${SERVICES[@]}"; do
        CONTAINER=$(docker compose "${COMPOSE_ARGS[@]}" ps -q "$svc" 2>/dev/null || true)
        if [[ -z "$CONTAINER" ]]; then
            echo -e "  ${RED}✗ $svc — not running${NC}"
            continue
        fi

        HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "$CONTAINER" 2>/dev/null || echo "unknown")
        case "$HEALTH" in
            healthy)        echo -e "  ${GREEN}✓ $svc — healthy${NC}" ;;
            unhealthy)      echo -e "  ${RED}✗ $svc — unhealthy${NC}" ;;
            starting)       echo -e "  ${YELLOW}⧗ $svc — starting${NC}" ;;
            "no healthcheck") echo -e "  ${YELLOW}○ $svc — no healthcheck configured${NC}" ;;
            *)              echo -e "  ${YELLOW}? $svc — $HEALTH${NC}" ;;
        esac

        # Show last healthcheck log if unhealthy
        if [[ "$HEALTH" == "unhealthy" || "$HEALTH" == "starting" ]]; then
            LAST_LOG=$(docker inspect --format='{{range $i, $log := .State.Health.Log}}{{if eq $i 0}}Exit={{$log.ExitCode}} Output={{$log.Output}}{{end}}{{end}}' "$CONTAINER" 2>/dev/null || true)
            if [[ -n "$LAST_LOG" ]]; then
                echo "    Last check: $LAST_LOG"
            fi
        fi
    done
fi

# ──────────────────────────────────────────────
# PORT MAPPINGS
# ──────────────────────────────────────────────
if [[ "$MODE" == "all" || "$MODE" == "ports" ]]; then
    header "Port Mappings"
    for svc in "${SERVICES[@]}"; do
        CONTAINER=$(docker compose "${COMPOSE_ARGS[@]}" ps -q "$svc" 2>/dev/null || true)
        if [[ -z "$CONTAINER" ]]; then
            echo -e "  ${YELLOW}$svc — not running${NC}"
            continue
        fi
        PORTS=$(docker port "$CONTAINER" 2>/dev/null || true)
        if [[ -n "$PORTS" ]]; then
            subheader "$svc"
            echo "$PORTS" | while read -r line; do
                echo "    $line"
            done
        else
            echo -e "  ${YELLOW}$svc — no ports mapped${NC}"
        fi
    done

    # Check for port conflicts
    subheader "Port Conflict Check"
    USED_PORTS=$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' | \
        grep -oE '0\.0\.0\.0:[0-9]+' | sort | uniq -d)
    if [[ -n "$USED_PORTS" ]]; then
        echo -e "  ${RED}Duplicate host port bindings:${NC}"
        echo "$USED_PORTS" | while read -r p; do echo "    $p"; done
    else
        echo -e "  ${GREEN}No port conflicts detected${NC}"
    fi
fi

# ──────────────────────────────────────────────
# NETWORK DEBUGGING
# ──────────────────────────────────────────────
if [[ "$MODE" == "all" || "$MODE" == "network" ]]; then
    header "Network Configuration"

    # List project networks
    subheader "Project Networks"
    docker network ls --filter "label=com.docker.compose.project=${PROJECT}" \
        --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}" 2>/dev/null || \
        docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}" 2>/dev/null

    # Per-service network details
    subheader "Container Network Details"
    for svc in "${SERVICES[@]}"; do
        CONTAINER=$(docker compose "${COMPOSE_ARGS[@]}" ps -q "$svc" 2>/dev/null || true)
        if [[ -z "$CONTAINER" ]]; then continue; fi

        NETWORKS=$(docker inspect --format='{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}: {{$conf.IPAddress}} {{end}}' "$CONTAINER" 2>/dev/null || true)
        echo -e "  ${GREEN}$svc${NC}: $NETWORKS"
    done

    # DNS resolution test
    subheader "DNS Resolution Test"
    FIRST_CONTAINER=$(docker compose "${COMPOSE_ARGS[@]}" ps -q 2>/dev/null | head -1)
    if [[ -n "$FIRST_CONTAINER" ]]; then
        for svc in "${SERVICES[@]}"; do
            RESULT=$(docker exec "$FIRST_CONTAINER" sh -c "getent hosts $svc 2>/dev/null || nslookup $svc 2>/dev/null | grep -A1 'Name:'" 2>/dev/null || true)
            if [[ -n "$RESULT" ]]; then
                echo -e "  ${GREEN}✓ $svc${NC} → $(echo "$RESULT" | head -1)"
            else
                echo -e "  ${RED}✗ $svc — DNS resolution failed${NC}"
            fi
        done
    else
        echo -e "  ${YELLOW}No running containers to test from${NC}"
    fi

    # Connectivity test
    subheader "Inter-Container Connectivity"
    if [[ -n "$FIRST_CONTAINER" && ${#SERVICES[@]} -gt 1 ]]; then
        SRC_SVC="${SERVICES[0]}"
        for target_svc in "${SERVICES[@]:1}"; do
            # Try to detect exposed ports
            TARGET_CONTAINER=$(docker compose "${COMPOSE_ARGS[@]}" ps -q "$target_svc" 2>/dev/null || true)
            if [[ -z "$TARGET_CONTAINER" ]]; then continue; fi

            TARGET_PORT=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} {{end}}' "$TARGET_CONTAINER" 2>/dev/null | \
                grep -oE '[0-9]+' | head -1 || true)
            if [[ -n "$TARGET_PORT" ]]; then
                if docker exec "$FIRST_CONTAINER" sh -c "nc -z -w2 $target_svc $TARGET_PORT" 2>/dev/null; then
                    echo -e "  ${GREEN}✓ $SRC_SVC → $target_svc:$TARGET_PORT${NC}"
                else
                    echo -e "  ${RED}✗ $SRC_SVC → $target_svc:$TARGET_PORT — connection failed${NC}"
                fi
            fi
        done
    fi
fi

# ──────────────────────────────────────────────
# RESOURCE USAGE
# ──────────────────────────────────────────────
if [[ "$MODE" == "all" ]]; then
    header "Resource Usage"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" \
        $(docker compose "${COMPOSE_ARGS[@]}" ps -q 2>/dev/null | tr '\n' ' ') 2>/dev/null || \
        echo -e "  ${YELLOW}No running containers${NC}"
fi

# ──────────────────────────────────────────────
# RECENT LOGS (errors only)
# ──────────────────────────────────────────────
if [[ "$MODE" == "all" ]]; then
    header "Recent Errors (last 20 lines)"
    for svc in "${SERVICES[@]}"; do
        ERRORS=$(docker compose "${COMPOSE_ARGS[@]}" logs --tail=100 "$svc" 2>/dev/null | \
            grep -iE '(error|fatal|panic|exception|fail|critical)' | tail -5 || true)
        if [[ -n "$ERRORS" ]]; then
            subheader "$svc"
            echo "$ERRORS"
        fi
    done
fi

echo ""
echo "═══════════════════════════════════════════"
echo -e "${GREEN} Debug complete${NC}"
echo "═══════════════════════════════════════════"
