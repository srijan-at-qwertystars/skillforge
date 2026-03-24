#!/usr/bin/env bash
#
# setup-consul-dev.sh — Sets up a Consul dev agent with sample services, KV data, and ACLs.
#
# Usage:
#   ./setup-consul-dev.sh                  # Start dev agent with sample data
#   ./setup-consul-dev.sh --acl            # Start with ACLs enabled
#   ./setup-consul-dev.sh --cleanup        # Stop agent and remove data
#
# Prerequisites:
#   - consul binary in PATH
#   - curl, jq
#
# The dev agent runs in the background. Use --cleanup to stop it.

set -euo pipefail

CONSUL_DATA_DIR="${CONSUL_DATA_DIR:-/tmp/consul-dev-data}"
CONSUL_LOG="${CONSUL_LOG:-/tmp/consul-dev.log}"
CONSUL_PID_FILE="${CONSUL_PID_FILE:-/tmp/consul-dev.pid}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
ENABLE_ACL=false

usage() {
  echo "Usage: $0 [--acl] [--cleanup] [--help]"
  echo ""
  echo "Options:"
  echo "  --acl       Enable ACL system with default-deny policy"
  echo "  --cleanup   Stop the dev agent and remove data"
  echo "  --help      Show this help message"
  exit 0
}

cleanup() {
  echo "==> Stopping Consul dev agent..."
  if [[ -f "$CONSUL_PID_FILE" ]]; then
    kill "$(cat "$CONSUL_PID_FILE")" 2>/dev/null || true
    rm -f "$CONSUL_PID_FILE"
  fi
  rm -rf "$CONSUL_DATA_DIR"
  rm -f "$CONSUL_LOG"
  echo "==> Cleanup complete."
  exit 0
}

wait_for_consul() {
  echo "==> Waiting for Consul to be ready..."
  local retries=30
  while ! curl -sf "${CONSUL_HTTP_ADDR}/v1/status/leader" > /dev/null 2>&1; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      echo "ERROR: Consul did not become ready in time."
      echo "Check logs: $CONSUL_LOG"
      exit 1
    fi
    sleep 1
  done
  echo "==> Consul is ready."
}

start_agent() {
  echo "==> Starting Consul dev agent..."
  mkdir -p "$CONSUL_DATA_DIR"

  local extra_args=()
  if [[ "$ENABLE_ACL" == "true" ]]; then
    extra_args+=(-hcl 'acl { enabled = true, default_policy = "deny", tokens { initial_management = "root-token-dev-only" } }')
  fi

  nohup consul agent -dev \
    -data-dir="$CONSUL_DATA_DIR" \
    -client="0.0.0.0" \
    -log-level=info \
    "${extra_args[@]}" \
    > "$CONSUL_LOG" 2>&1 &

  echo $! > "$CONSUL_PID_FILE"
  echo "==> Consul PID: $(cat "$CONSUL_PID_FILE")"
}

register_sample_services() {
  echo "==> Registering sample services..."

  local token_header=()
  if [[ "$ENABLE_ACL" == "true" ]]; then
    token_header=(-H "X-Consul-Token: root-token-dev-only")
  fi

  # Web frontend service
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/agent/service/register" \
    "${token_header[@]}" \
    -d '{
      "ID": "web-1",
      "Name": "web",
      "Tags": ["primary", "v2"],
      "Port": 8080,
      "Address": "127.0.0.1",
      "Meta": {"version": "2.1.0", "env": "dev"},
      "Check": {
        "Name": "Web HTTP Check",
        "HTTP": "http://127.0.0.1:8080/health",
        "Interval": "30s",
        "Timeout": "5s",
        "DeregisterCriticalServiceAfter": "5m"
      }
    }'
  echo "    Registered: web-1 (port 8080)"

  # API backend service
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/agent/service/register" \
    "${token_header[@]}" \
    -d '{
      "ID": "api-1",
      "Name": "api",
      "Tags": ["v1", "rest"],
      "Port": 9090,
      "Address": "127.0.0.1",
      "Meta": {"version": "1.5.0", "env": "dev"},
      "Check": {
        "Name": "API TCP Check",
        "TCP": "127.0.0.1:9090",
        "Interval": "15s",
        "Timeout": "3s"
      }
    }'
  echo "    Registered: api-1 (port 9090)"

  # Database service
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/agent/service/register" \
    "${token_header[@]}" \
    -d '{
      "ID": "postgres-1",
      "Name": "postgres",
      "Tags": ["primary"],
      "Port": 5432,
      "Address": "127.0.0.1",
      "Meta": {"version": "15.4", "env": "dev"},
      "Check": {
        "Name": "Postgres TCP Check",
        "TCP": "127.0.0.1:5432",
        "Interval": "10s",
        "Timeout": "3s"
      }
    }'
  echo "    Registered: postgres-1 (port 5432)"

  # Redis cache service
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/agent/service/register" \
    "${token_header[@]}" \
    -d '{
      "ID": "redis-1",
      "Name": "redis",
      "Tags": ["cache"],
      "Port": 6379,
      "Address": "127.0.0.1",
      "Meta": {"version": "7.2", "env": "dev"}
    }'
  echo "    Registered: redis-1 (port 6379)"
}

populate_kv_data() {
  echo "==> Populating KV store with sample data..."

  local token_header=()
  if [[ "$ENABLE_ACL" == "true" ]]; then
    token_header=(-H "X-Consul-Token: root-token-dev-only")
  fi

  # Application configuration
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/global/log-level" \
    "${token_header[@]}" -d 'info'
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/global/environment" \
    "${token_header[@]}" -d 'development'

  # Database configuration
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/database/host" \
    "${token_header[@]}" -d '127.0.0.1'
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/database/port" \
    "${token_header[@]}" -d '5432'
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/database/name" \
    "${token_header[@]}" -d 'myapp'
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/database/max-connections" \
    "${token_header[@]}" -d '20'

  # Redis configuration
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/redis/host" \
    "${token_header[@]}" -d '127.0.0.1'
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/redis/port" \
    "${token_header[@]}" -d '6379'
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/redis/ttl" \
    "${token_header[@]}" -d '3600'

  # Feature flags
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/features/new-dashboard" \
    "${token_header[@]}" -d 'true'
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/kv/config/features/dark-mode" \
    "${token_header[@]}" -d 'false'

  echo "    KV data populated under config/"
}

setup_acl_policies() {
  if [[ "$ENABLE_ACL" != "true" ]]; then
    return
  fi

  echo "==> Setting up ACL policies and tokens..."

  local token_header=(-H "X-Consul-Token: root-token-dev-only")

  # Agent policy
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/acl/policy" \
    "${token_header[@]}" \
    -d '{
      "Name": "agent-policy",
      "Description": "Agent policy for node registration and service discovery",
      "Rules": "node_prefix \"\" { policy = \"write\" }\nservice_prefix \"\" { policy = \"read\" }"
    }'

  # Web service policy
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/acl/policy" \
    "${token_header[@]}" \
    -d '{
      "Name": "web-policy",
      "Description": "Web service read/write and config read",
      "Rules": "service \"web\" { policy = \"write\" }\nservice_prefix \"\" { policy = \"read\" }\nnode_prefix \"\" { policy = \"read\" }\nkey_prefix \"config/\" { policy = \"read\" }"
    }'

  # Read-only policy
  curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/acl/policy" \
    "${token_header[@]}" \
    -d '{
      "Name": "read-only",
      "Description": "Read-only access to services and KV",
      "Rules": "service_prefix \"\" { policy = \"read\" }\nnode_prefix \"\" { policy = \"read\" }\nkey_prefix \"\" { policy = \"read\" }"
    }'

  # Create tokens
  WEB_TOKEN=$(curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/acl/token" \
    "${token_header[@]}" \
    -d '{"Description": "Web service token", "Policies": [{"Name": "web-policy"}]}' \
    | jq -r '.SecretID')

  READONLY_TOKEN=$(curl -sf -X PUT "${CONSUL_HTTP_ADDR}/v1/acl/token" \
    "${token_header[@]}" \
    -d '{"Description": "Read-only token", "Policies": [{"Name": "read-only"}]}' \
    | jq -r '.SecretID')

  echo "    ACL policies created: agent-policy, web-policy, read-only"
  echo "    Management token: root-token-dev-only"
  echo "    Web service token: ${WEB_TOKEN}"
  echo "    Read-only token:   ${READONLY_TOKEN}"
}

print_summary() {
  echo ""
  echo "======================================"
  echo "  Consul Dev Environment Ready"
  echo "======================================"
  echo ""
  echo "  UI:    ${CONSUL_HTTP_ADDR}/ui"
  echo "  API:   ${CONSUL_HTTP_ADDR}/v1/"
  echo "  DNS:   dig @127.0.0.1 -p 8600 web.service.consul"
  echo "  Logs:  tail -f ${CONSUL_LOG}"
  echo "  PID:   $(cat "$CONSUL_PID_FILE")"
  echo ""
  echo "  Services: web, api, postgres, redis"
  echo "  KV Path:  config/"
  if [[ "$ENABLE_ACL" == "true" ]]; then
    echo ""
    echo "  ACLs:     ENABLED (default deny)"
    echo "  Token:    root-token-dev-only"
    echo "  Usage:    export CONSUL_HTTP_TOKEN=root-token-dev-only"
  fi
  echo ""
  echo "  Cleanup:  $0 --cleanup"
  echo "======================================"
}

# --- Main ---

for arg in "$@"; do
  case "$arg" in
    --acl)     ENABLE_ACL=true ;;
    --cleanup) cleanup ;;
    --help)    usage ;;
    *)         echo "Unknown option: $arg"; usage ;;
  esac
done

# Check prerequisites
for cmd in consul curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not found in PATH."
    exit 1
  fi
done

# Check if already running
if [[ -f "$CONSUL_PID_FILE" ]] && kill -0 "$(cat "$CONSUL_PID_FILE")" 2>/dev/null; then
  echo "Consul dev agent is already running (PID: $(cat "$CONSUL_PID_FILE"))."
  echo "Run '$0 --cleanup' first to restart."
  exit 1
fi

start_agent
wait_for_consul
register_sample_services
populate_kv_data
setup_acl_policies
print_summary
