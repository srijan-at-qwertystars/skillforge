#!/usr/bin/env bash
#
# service-register.sh — Registers a service with health check in Consul from CLI args.
#
# Usage:
#   ./service-register.sh -n web -p 8080                             # Basic registration
#   ./service-register.sh -n api -p 9090 -a 10.0.1.5                 # With address
#   ./service-register.sh -n web -p 8080 -c http -P /health          # HTTP health check
#   ./service-register.sh -n db -p 5432 -c tcp                       # TCP health check
#   ./service-register.sh -n app -p 3000 -c ttl -I 30s               # TTL health check
#   ./service-register.sh -n web -p 8080 -g primary,v2 -m version=2.1 # Tags and metadata
#   ./service-register.sh -n web-1 --deregister                       # Deregister a service
#
# Options:
#   -n NAME       Service name (required)
#   -p PORT       Service port (required for registration)
#   -a ADDR       Service address (default: 127.0.0.1)
#   -i ID         Service ID (default: NAME)
#   -g TAGS       Comma-separated tags (e.g., "primary,v2")
#   -m META       Comma-separated key=value metadata (e.g., "version=2.1,env=prod")
#   -c CHECK      Health check type: http, tcp, grpc, ttl (default: none)
#   -P PATH       Health check HTTP path (default: /health)
#   -I INTERVAL   Health check interval (default: 10s)
#   -T TIMEOUT    Health check timeout (default: 5s)
#   -t TOKEN      Consul ACL token (or set CONSUL_HTTP_TOKEN)
#   -A ADDR       Consul HTTP address (default: http://127.0.0.1:8500)
#   --deregister  Deregister the service (requires -n or -i)
#   -h            Show help
#
# Prerequisites:
#   - curl, jq

set -euo pipefail

# Defaults
SERVICE_NAME=""
SERVICE_PORT=""
SERVICE_ADDR="127.0.0.1"
SERVICE_ID=""
TAGS=""
META=""
CHECK_TYPE=""
CHECK_PATH="/health"
CHECK_INTERVAL="10s"
CHECK_TIMEOUT="5s"
CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
TOKEN="${CONSUL_HTTP_TOKEN:-}"
DEREGISTER=false

usage() {
  echo "Usage: $0 -n NAME -p PORT [OPTIONS]"
  echo ""
  echo "Register a service with Consul, optionally with health checks."
  echo ""
  echo "Required:"
  echo "  -n NAME       Service name"
  echo "  -p PORT       Service port"
  echo ""
  echo "Optional:"
  echo "  -a ADDR       Service address (default: 127.0.0.1)"
  echo "  -i ID         Service ID (default: same as name)"
  echo "  -g TAGS       Comma-separated tags"
  echo "  -m META       Comma-separated key=value metadata"
  echo "  -c CHECK      Health check type: http, tcp, grpc, ttl"
  echo "  -P PATH       HTTP check path (default: /health)"
  echo "  -I INTERVAL   Check interval (default: 10s)"
  echo "  -T TIMEOUT    Check timeout (default: 5s)"
  echo "  -t TOKEN      Consul ACL token"
  echo "  -A ADDR       Consul address (default: http://127.0.0.1:8500)"
  echo "  --deregister  Deregister the service"
  echo "  -h            Show help"
  exit 0
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) SERVICE_NAME="$2"; shift 2 ;;
    -p) SERVICE_PORT="$2"; shift 2 ;;
    -a) SERVICE_ADDR="$2"; shift 2 ;;
    -i) SERVICE_ID="$2"; shift 2 ;;
    -g) TAGS="$2"; shift 2 ;;
    -m) META="$2"; shift 2 ;;
    -c) CHECK_TYPE="$2"; shift 2 ;;
    -P) CHECK_PATH="$2"; shift 2 ;;
    -I) CHECK_INTERVAL="$2"; shift 2 ;;
    -T) CHECK_TIMEOUT="$2"; shift 2 ;;
    -t) TOKEN="$2"; shift 2 ;;
    -A) CONSUL_ADDR="$2"; shift 2 ;;
    --deregister) DEREGISTER=true; shift ;;
    -h|--help) usage ;;
    *)  die "Unknown option: $1" ;;
  esac
done

# Validate
command -v curl &>/dev/null || die "'curl' not found in PATH"
command -v jq &>/dev/null || die "'jq' not found in PATH"
[[ -n "$SERVICE_NAME" ]] || die "Service name (-n) is required"

# Set service ID
SERVICE_ID="${SERVICE_ID:-$SERVICE_NAME}"

# Build headers
CURL_OPTS=(-sf)
if [[ -n "$TOKEN" ]]; then
  CURL_OPTS+=(-H "X-Consul-Token: ${TOKEN}")
fi

# Handle deregistration
if [[ "$DEREGISTER" == "true" ]]; then
  echo "Deregistering service: ${SERVICE_ID}"
  HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X PUT \
    "${CURL_OPTS[@]}" \
    "${CONSUL_ADDR}/v1/agent/service/deregister/${SERVICE_ID}" 2>/dev/null || echo "000")

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "Service '${SERVICE_ID}' deregistered successfully."
  else
    die "Failed to deregister service '${SERVICE_ID}' (HTTP ${HTTP_CODE})"
  fi
  exit 0
fi

# Port is required for registration
[[ -n "$SERVICE_PORT" ]] || die "Service port (-p) is required for registration"

# Build JSON payload
JSON=$(jq -n \
  --arg id "$SERVICE_ID" \
  --arg name "$SERVICE_NAME" \
  --arg addr "$SERVICE_ADDR" \
  --argjson port "$SERVICE_PORT" \
  '{
    "ID": $id,
    "Name": $name,
    "Address": $addr,
    "Port": $port
  }')

# Add tags
if [[ -n "$TAGS" ]]; then
  TAGS_JSON=$(echo "$TAGS" | tr ',' '\n' | jq -R . | jq -s .)
  JSON=$(echo "$JSON" | jq --argjson tags "$TAGS_JSON" '. + {Tags: $tags}')
fi

# Add metadata
if [[ -n "$META" ]]; then
  META_JSON="{}"
  IFS=',' read -ra PAIRS <<< "$META"
  for pair in "${PAIRS[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    META_JSON=$(echo "$META_JSON" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
  done
  JSON=$(echo "$JSON" | jq --argjson meta "$META_JSON" '. + {Meta: $meta}')
fi

# Add health check
if [[ -n "$CHECK_TYPE" ]]; then
  case "$CHECK_TYPE" in
    http)
      CHECK_JSON=$(jq -n \
        --arg http "http://${SERVICE_ADDR}:${SERVICE_PORT}${CHECK_PATH}" \
        --arg interval "$CHECK_INTERVAL" \
        --arg timeout "$CHECK_TIMEOUT" \
        '{
          "Name": "HTTP Check",
          "HTTP": $http,
          "Interval": $interval,
          "Timeout": $timeout,
          "DeregisterCriticalServiceAfter": "5m"
        }')
      ;;
    tcp)
      CHECK_JSON=$(jq -n \
        --arg tcp "${SERVICE_ADDR}:${SERVICE_PORT}" \
        --arg interval "$CHECK_INTERVAL" \
        --arg timeout "$CHECK_TIMEOUT" \
        '{
          "Name": "TCP Check",
          "TCP": $tcp,
          "Interval": $interval,
          "Timeout": $timeout,
          "DeregisterCriticalServiceAfter": "5m"
        }')
      ;;
    grpc)
      CHECK_JSON=$(jq -n \
        --arg grpc "${SERVICE_ADDR}:${SERVICE_PORT}" \
        --arg interval "$CHECK_INTERVAL" \
        --arg timeout "$CHECK_TIMEOUT" \
        '{
          "Name": "gRPC Check",
          "GRPC": $grpc,
          "GRPCUseTLS": false,
          "Interval": $interval,
          "Timeout": $timeout
        }')
      ;;
    ttl)
      CHECK_JSON=$(jq -n \
        --arg ttl "$CHECK_INTERVAL" \
        '{
          "Name": "TTL Check",
          "TTL": $ttl,
          "DeregisterCriticalServiceAfter": "10m"
        }')
      ;;
    *)
      die "Unknown check type: $CHECK_TYPE (use: http, tcp, grpc, ttl)"
      ;;
  esac
  JSON=$(echo "$JSON" | jq --argjson check "$CHECK_JSON" '. + {Check: $check}')
fi

# Register service
echo "Registering service with Consul..."
echo "$JSON" | jq . 2>/dev/null  # Display payload

HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X PUT \
  "${CURL_OPTS[@]}" \
  "${CONSUL_ADDR}/v1/agent/service/register" \
  -d "$JSON" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  echo ""
  echo "Service '${SERVICE_NAME}' (ID: ${SERVICE_ID}) registered successfully."
  echo ""
  echo "Verify:"
  echo "  curl ${CONSUL_ADDR}/v1/agent/service/${SERVICE_ID}"
  echo "  dig @127.0.0.1 -p 8600 ${SERVICE_NAME}.service.consul SRV"
else
  die "Registration failed (HTTP ${HTTP_CODE}). Check Consul agent at ${CONSUL_ADDR}."
fi
