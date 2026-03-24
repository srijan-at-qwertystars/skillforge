#!/usr/bin/env bash
#
# setup-vault.sh — Docker-based Vault setup for dev and prod environments
#
# Usage:
#   ./setup-vault.sh dev              # Dev mode: single container, in-memory, auto-unsealed
#   ./setup-vault.sh prod             # Prod mode: HA cluster with Raft, requires init/unseal
#   ./setup-vault.sh dev --configure  # Dev mode + enable engines, create policies, seed secrets
#   ./setup-vault.sh teardown         # Stop and remove all Vault containers/volumes
#
# Prerequisites:
#   - Docker (and docker compose) installed
#   - jq installed
#   - Ports 8200, 8201, 8202 available (prod mode uses all three)
#
# Environment Variables:
#   VAULT_VERSION     — Vault Docker image tag (default: 1.18.3)
#   VAULT_PORT        — Primary Vault port (default: 8200)
#   VAULT_DEV_TOKEN   — Dev mode root token (default: dev-root-token)

set -euo pipefail

VAULT_VERSION="${VAULT_VERSION:-1.18.3}"
VAULT_PORT="${VAULT_PORT:-8200}"
VAULT_DEV_TOKEN="${VAULT_DEV_TOKEN:-dev-root-token}"
VAULT_IMAGE="hashicorp/vault:${VAULT_VERSION}"
VAULT_DATA_DIR="/tmp/vault-setup-data"
MODE="${1:-}"
CONFIGURE=false

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configure) CONFIGURE=true; shift ;;
    --help|-h) head -16 "$0" | tail -14; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log()  { echo -e "\033[1;32m[SETUP]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; exit 1; }

wait_for_vault() {
  local addr="$1" max_wait="${2:-30}"
  log "Waiting for Vault at ${addr}..."
  for i in $(seq 1 "$max_wait"); do
    if curl -sf "${addr}/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200" &>/dev/null; then
      return 0
    fi
    sleep 1
  done
  err "Vault not ready after ${max_wait}s at ${addr}"
}

command -v docker >/dev/null 2>&1 || err "docker is required"
command -v jq >/dev/null 2>&1 || err "jq is required"

# --- Dev Mode ---
setup_dev() {
  log "Starting Vault dev server (in-memory, auto-unsealed)..."

  docker run -d \
    --name vault-dev \
    --cap-add IPC_LOCK \
    -p "${VAULT_PORT}:8200" \
    -e "VAULT_DEV_ROOT_TOKEN_ID=${VAULT_DEV_TOKEN}" \
    -e "VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200" \
    -e "VAULT_ADDR=http://127.0.0.1:8200" \
    "${VAULT_IMAGE}" server -dev

  wait_for_vault "http://127.0.0.1:${VAULT_PORT}"

  export VAULT_ADDR="http://127.0.0.1:${VAULT_PORT}"
  export VAULT_TOKEN="${VAULT_DEV_TOKEN}"

  log "Dev server running on ${VAULT_ADDR}"
  log "Root token: ${VAULT_DEV_TOKEN}"

  if $CONFIGURE; then configure_vault; fi
}

# --- Prod Mode (HA with Raft) ---
setup_prod() {
  log "Starting Vault HA cluster with Raft storage (3 nodes)..."

  mkdir -p "${VAULT_DATA_DIR}"/{vault-1,vault-2,vault-3}/{data,logs}

  for i in 1 2 3; do
    local port=$((VAULT_PORT + i - 1))
    cat > "${VAULT_DATA_DIR}/vault-${i}/config.hcl" << HCLEOF
ui            = true
disable_mlock = true
log_level     = "info"

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-${i}"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

api_addr     = "http://vault-${i}:8200"
cluster_addr = "http://vault-${i}:8201"

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
HCLEOF
  done

  docker network create vault-ha-net 2>/dev/null || true

  for i in 1 2 3; do
    local port=$((VAULT_PORT + i - 1))
    docker run -d \
      --name "vault-${i}" \
      --hostname "vault-${i}" \
      --network vault-ha-net \
      --cap-add IPC_LOCK \
      -p "${port}:8200" \
      -v "${VAULT_DATA_DIR}/vault-${i}/config.hcl:/vault/config/vault.hcl:ro" \
      -v "${VAULT_DATA_DIR}/vault-${i}/data:/vault/data" \
      -v "${VAULT_DATA_DIR}/vault-${i}/logs:/vault/logs" \
      -e "VAULT_ADDR=http://127.0.0.1:8200" \
      "${VAULT_IMAGE}" server -config=/vault/config/vault.hcl
  done

  wait_for_vault "http://127.0.0.1:${VAULT_PORT}" 45

  export VAULT_ADDR="http://127.0.0.1:${VAULT_PORT}"

  # Initialize
  log "Initializing Vault cluster..."
  INIT_OUTPUT=$(curl -sf "${VAULT_ADDR}/v1/sys/init" -X PUT \
    -d '{"secret_shares":5,"secret_threshold":3}')

  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
  mapfile -t KEY_ARRAY < <(echo "$INIT_OUTPUT" | jq -r '.keys_base64[]')

  log "Root token: ${ROOT_TOKEN}"
  for idx in "${!KEY_ARRAY[@]}"; do
    log "  Unseal key $((idx+1)): ${KEY_ARRAY[$idx]}"
  done

  echo "$INIT_OUTPUT" | jq . > "${VAULT_DATA_DIR}/init-output.json"
  log "Init output saved to ${VAULT_DATA_DIR}/init-output.json"

  # Unseal node 1
  log "Unsealing vault-1..."
  for k in 0 1 2; do
    curl -sf "${VAULT_ADDR}/v1/sys/unseal" -X PUT \
      -d "{\"key\":\"${KEY_ARRAY[$k]}\"}" > /dev/null
  done

  sleep 2
  export VAULT_TOKEN="${ROOT_TOKEN}"

  # Join and unseal nodes 2 and 3
  for i in 2 3; do
    local port=$((VAULT_PORT + i - 1))
    local addr="http://127.0.0.1:${port}"
    log "Joining vault-${i} to cluster..."
    curl -sf "${addr}/v1/sys/raft/join" -X PUT \
      -d '{"leader_api_addr":"http://vault-1:8200"}' > /dev/null || true
    sleep 1
    log "Unsealing vault-${i}..."
    for k in 0 1 2; do
      curl -sf "${addr}/v1/sys/unseal" -X PUT \
        -d "{\"key\":\"${KEY_ARRAY[$k]}\"}" > /dev/null
    done
  done

  sleep 3

  log "Cluster status:"
  curl -sf -H "X-Vault-Token: ${ROOT_TOKEN}" \
    "${VAULT_ADDR}/v1/sys/raft/configuration" | \
    jq '.data.config.servers[] | {node_id, address, leader}'

  if $CONFIGURE; then configure_vault; fi

  echo ""
  echo "============================================="
  echo "  Vault HA Cluster Ready (Raft Storage)"
  echo "============================================="
  echo "  Node 1: http://127.0.0.1:${VAULT_PORT}"
  echo "  Node 2: http://127.0.0.1:$((VAULT_PORT+1))"
  echo "  Node 3: http://127.0.0.1:$((VAULT_PORT+2))"
  echo "  UI:     http://127.0.0.1:${VAULT_PORT}/ui"
  echo "  Root:   ${ROOT_TOKEN}"
  echo "  Init:   ${VAULT_DATA_DIR}/init-output.json"
  echo "============================================="
}

# --- Configure Vault ---
configure_vault() {
  log "Configuring Vault..."

  local H=(-H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json")

  # Enable secrets engines
  log "Enabling secrets engines..."
  curl -sf "${VAULT_ADDR}/v1/sys/mounts/secret" "${H[@]}" -X POST \
    -d '{"type":"kv","options":{"version":"2"}}' 2>/dev/null || true
  curl -sf "${VAULT_ADDR}/v1/sys/mounts/transit" "${H[@]}" -X POST \
    -d '{"type":"transit"}' 2>/dev/null || true
  curl -sf "${VAULT_ADDR}/v1/sys/mounts/pki" "${H[@]}" -X POST \
    -d '{"type":"pki","config":{"max_lease_ttl":"87600h"}}' 2>/dev/null || true
  curl -sf "${VAULT_ADDR}/v1/sys/mounts/database" "${H[@]}" -X POST \
    -d '{"type":"database"}' 2>/dev/null || true

  # Transit keys
  log "Creating Transit keys..."
  curl -sf "${VAULT_ADDR}/v1/transit/keys/app-key" "${H[@]}" -X POST -d '{}' 2>/dev/null || true

  # Root CA
  log "Generating root CA..."
  curl -sf "${VAULT_ADDR}/v1/pki/root/generate/internal" "${H[@]}" -X POST \
    -d '{"common_name":"Vault Root CA","ttl":"87600h"}' > /dev/null 2>/dev/null || true

  # Enable auth methods
  log "Enabling auth methods..."
  curl -sf "${VAULT_ADDR}/v1/sys/auth/approle" "${H[@]}" -X POST \
    -d '{"type":"approle"}' 2>/dev/null || true

  # Create policies
  log "Creating policies..."
  curl -sf "${VAULT_ADDR}/v1/sys/policies/acl/admin" "${H[@]}" -X PUT \
    -d '{"policy":"path \"*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\",\"sudo\"] }"}' || true
  curl -sf "${VAULT_ADDR}/v1/sys/policies/acl/readonly" "${H[@]}" -X PUT \
    -d '{"policy":"path \"secret/data/*\" { capabilities = [\"read\",\"list\"] }\npath \"secret/metadata/*\" { capabilities = [\"list\",\"read\"] }"}' || true
  curl -sf "${VAULT_ADDR}/v1/sys/policies/acl/app-policy" "${H[@]}" -X PUT \
    -d '{"policy":"path \"secret/data/myapp/*\" { capabilities = [\"read\",\"list\"] }\npath \"transit/encrypt/app-key\" { capabilities = [\"update\"] }\npath \"transit/decrypt/app-key\" { capabilities = [\"update\"] }"}' || true
  curl -sf "${VAULT_ADDR}/v1/sys/policies/acl/ci-cd-policy" "${H[@]}" -X PUT \
    -d '{"policy":"path \"secret/data/ci/*\" { capabilities = [\"read\"] }\npath \"secret/metadata/ci/*\" { capabilities = [\"list\"] }"}' || true

  # Seed sample secrets
  log "Seeding sample secrets..."
  curl -sf "${VAULT_ADDR}/v1/secret/data/myapp/config" "${H[@]}" -X POST \
    -d '{"data":{"db_host":"localhost","db_port":"5432","api_key":"sample-key-12345","environment":"dev"}}' || true

  # Enable audit
  log "Enabling audit..."
  curl -sf "${VAULT_ADDR}/v1/sys/audit/file" "${H[@]}" -X PUT \
    -d '{"type":"file","options":{"file_path":"/vault/logs/audit.log"}}' 2>/dev/null || true

  log "Configuration complete!"
}

# --- Teardown ---
teardown() {
  log "Tearing down Vault containers..."
  for name in vault-dev vault-1 vault-2 vault-3; do
    docker rm -f "$name" 2>/dev/null && log "Removed ${name}" || true
  done
  docker network rm vault-ha-net 2>/dev/null || true
  if [[ -d "${VAULT_DATA_DIR}" ]]; then
    warn "Data at ${VAULT_DATA_DIR} preserved. Remove manually if desired."
  fi
  log "Teardown complete."
}

# --- Main ---
case "${MODE}" in
  dev)      setup_dev ;;
  prod)     setup_prod ;;
  teardown) teardown ;;
  *)
    echo "Usage: $0 {dev|prod|teardown} [--configure]"
    echo ""
    echo "  dev       Start single-node dev server (in-memory)"
    echo "  prod      Start 3-node HA cluster with Raft storage"
    echo "  teardown  Stop and remove all Vault containers"
    echo "  --configure  Enable engines, create policies, seed secrets"
    exit 1
    ;;
esac
