#!/usr/bin/env bash
set -euo pipefail

# setup-rabbitmq-cluster.sh — Sets up a 3-node RabbitMQ cluster with Docker Compose
# Usage: ./setup-rabbitmq-cluster.sh [--dir <output-dir>] [--start]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../.cluster-setup"
START_CLUSTER=false
RABBITMQ_IMAGE="rabbitmq:3.13-management-alpine"
ERLANG_COOKIE="$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
ADMIN_USER="admin"
ADMIN_PASS="changeme-$(head -c 8 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sets up a 3-node RabbitMQ cluster using Docker Compose.

Options:
  --dir <path>    Output directory for generated files (default: ../.cluster-setup)
  --start         Start the cluster after generating files
  --image <img>   RabbitMQ Docker image (default: ${RABBITMQ_IMAGE})
  --password <p>  Admin password (default: auto-generated)
  -h, --help      Show this help message

Generated files:
  docker-compose.yml    3-node cluster + HAProxy load balancer
  rabbitmq.conf         Shared RabbitMQ configuration
  haproxy.cfg           HAProxy config for AMQP + management UI
  enabled_plugins       Plugin list (management, prometheus)
  init-cluster.sh       Post-start initialization script

EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)       OUTPUT_DIR="$2"; shift 2 ;;
        --start)     START_CLUSTER=true; shift ;;
        --image)     RABBITMQ_IMAGE="$2"; shift 2 ;;
        --password)  ADMIN_PASS="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

echo "==> Creating cluster config in: ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# --- rabbitmq.conf ---
cat > "${OUTPUT_DIR}/rabbitmq.conf" <<'RMQCONF'
## Clustering
cluster_formation.peer_discovery_backend = classic_config
cluster_formation.classic_config.nodes.1 = rabbit@rabbit1
cluster_formation.classic_config.nodes.2 = rabbit@rabbit2
cluster_formation.classic_config.nodes.3 = rabbit@rabbit3
cluster_partition_handling = pause_minority

## Defaults
default_vhost = /
default_user = admin
default_permissions.configure = .*
default_permissions.read = .*
default_permissions.write = .*

## Resource limits
vm_memory_high_watermark.relative = 0.7
vm_memory_high_watermark_paging_ratio = 0.75
disk_free_limit.relative = 1.5

## Networking
heartbeat = 60
channel_max = 2047

## Queue defaults
queue_leader_locator = balanced

## Consumer timeout (30 min)
consumer_timeout = 1800000

## Management / Prometheus
management.rates_mode = basic
prometheus.return_per_object_metrics = false

## Logging
log.console = true
log.console.level = info
RMQCONF

# --- enabled_plugins ---
cat > "${OUTPUT_DIR}/enabled_plugins" <<'PLUGINS'
[rabbitmq_management,rabbitmq_prometheus,rabbitmq_shovel,rabbitmq_shovel_management,rabbitmq_federation,rabbitmq_federation_management].
PLUGINS

# --- haproxy.cfg ---
cat > "${OUTPUT_DIR}/haproxy.cfg" <<'HAPROXY'
global
    log stdout format raw local0
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  120s
    timeout server  120s

# AMQP load balancing (round-robin)
frontend amqp_front
    bind *:5672
    default_backend amqp_back

backend amqp_back
    balance roundrobin
    option  tcp-check
    server rabbit1 rabbit1:5672 check inter 5s rise 2 fall 3
    server rabbit2 rabbit2:5672 check inter 5s rise 2 fall 3
    server rabbit3 rabbit3:5672 check inter 5s rise 2 fall 3

# Management UI (round-robin)
frontend mgmt_front
    bind *:15672
    default_backend mgmt_back

backend mgmt_back
    balance roundrobin
    option  tcp-check
    server rabbit1 rabbit1:15672 check inter 5s rise 2 fall 3
    server rabbit2 rabbit2:15672 check inter 5s rise 2 fall 3
    server rabbit3 rabbit3:15672 check inter 5s rise 2 fall 3

# HAProxy stats
listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
HAPROXY

# --- docker-compose.yml ---
cat > "${OUTPUT_DIR}/docker-compose.yml" <<COMPOSE
version: "3.9"

x-rabbitmq-common: &rabbitmq-common
  image: ${RABBITMQ_IMAGE}
  restart: unless-stopped
  environment:
    RABBITMQ_ERLANG_COOKIE: "${ERLANG_COOKIE}"
    RABBITMQ_DEFAULT_USER: "${ADMIN_USER}"
    RABBITMQ_DEFAULT_PASS: "${ADMIN_PASS}"
  volumes:
    - ./rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro
    - ./enabled_plugins:/etc/rabbitmq/enabled_plugins:ro
  networks:
    - rabbitmq-cluster
  deploy:
    resources:
      limits:
        memory: 2G
  healthcheck:
    test: ["CMD", "rabbitmq-diagnostics", "check_running"]
    interval: 15s
    timeout: 10s
    retries: 5
    start_period: 30s

services:
  rabbit1:
    <<: *rabbitmq-common
    hostname: rabbit1
    container_name: rabbit1
    ports:
      - "5672"
      - "15672"
      - "15692"
    volumes:
      - rabbit1-data:/var/lib/rabbitmq
      - ./rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro
      - ./enabled_plugins:/etc/rabbitmq/enabled_plugins:ro

  rabbit2:
    <<: *rabbitmq-common
    hostname: rabbit2
    container_name: rabbit2
    depends_on:
      rabbit1:
        condition: service_healthy
    ports:
      - "5672"
      - "15672"
      - "15692"
    volumes:
      - rabbit2-data:/var/lib/rabbitmq
      - ./rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro
      - ./enabled_plugins:/etc/rabbitmq/enabled_plugins:ro

  rabbit3:
    <<: *rabbitmq-common
    hostname: rabbit3
    container_name: rabbit3
    depends_on:
      rabbit1:
        condition: service_healthy
    ports:
      - "5672"
      - "15672"
      - "15692"
    volumes:
      - rabbit3-data:/var/lib/rabbitmq
      - ./rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro
      - ./enabled_plugins:/etc/rabbitmq/enabled_plugins:ro

  haproxy:
    image: haproxy:2.9-alpine
    container_name: rabbitmq-haproxy
    restart: unless-stopped
    depends_on:
      rabbit1:
        condition: service_healthy
      rabbit2:
        condition: service_healthy
      rabbit3:
        condition: service_healthy
    ports:
      - "5672:5672"     # AMQP
      - "15672:15672"   # Management UI
      - "8404:8404"     # HAProxy stats
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      - rabbitmq-cluster

volumes:
  rabbit1-data:
  rabbit2-data:
  rabbit3-data:

networks:
  rabbitmq-cluster:
    driver: bridge
COMPOSE

# --- init-cluster.sh ---
cat > "${OUTPUT_DIR}/init-cluster.sh" <<'INITSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Wait for all nodes to be healthy
echo "==> Waiting for cluster nodes to be ready..."
for node in rabbit1 rabbit2 rabbit3; do
    until docker exec "$node" rabbitmq-diagnostics check_running 2>/dev/null; do
        echo "    Waiting for $node..."
        sleep 5
    done
    echo "    $node is running."
done

# Verify cluster formation
echo ""
echo "==> Cluster status:"
docker exec rabbit1 rabbitmqctl cluster_status

# Create test vhost, exchange, and queue
echo ""
echo "==> Creating test resources..."

docker exec rabbit1 rabbitmqctl add_vhost /test 2>/dev/null || true
docker exec rabbit1 rabbitmqctl set_permissions -p /test admin ".*" ".*" ".*"

docker exec rabbit1 rabbitmqadmin -u admin -p "${RABBITMQ_DEFAULT_PASS:-changeme}" \
    declare exchange name=test.exchange type=topic durable=true -V /test 2>/dev/null || \
    echo "    (rabbitmqadmin not available — create test exchange via management UI)"

docker exec rabbit1 rabbitmqadmin -u admin -p "${RABBITMQ_DEFAULT_PASS:-changeme}" \
    declare queue name=test.queue durable=true \
    'arguments={"x-queue-type":"quorum"}' -V /test 2>/dev/null || \
    echo "    (rabbitmqadmin not available — create test queue via management UI)"

docker exec rabbit1 rabbitmqadmin -u admin -p "${RABBITMQ_DEFAULT_PASS:-changeme}" \
    declare binding source=test.exchange destination=test.queue \
    routing_key="test.#" -V /test 2>/dev/null || \
    echo "    (rabbitmqadmin not available — create test binding via management UI)"

# Rebalance quorum queue leaders
echo ""
echo "==> Rebalancing quorum queue leaders..."
docker exec rabbit1 rabbitmq-queues rebalance quorum 2>/dev/null || true

echo ""
echo "==> Cluster setup complete!"
echo "    AMQP:       amqp://localhost:5672"
echo "    Management: http://localhost:15672"
echo "    HAProxy:    http://localhost:8404/stats"
echo "    User:       admin"
INITSCRIPT
chmod +x "${OUTPUT_DIR}/init-cluster.sh"

echo ""
echo "==> Generated files:"
ls -la "${OUTPUT_DIR}/"
echo ""
echo "==> Credentials:"
echo "    User:     ${ADMIN_USER}"
echo "    Password: ${ADMIN_PASS}"
echo "    Cookie:   ${ERLANG_COOKIE}"
echo ""

if [[ "${START_CLUSTER}" == "true" ]]; then
    echo "==> Starting cluster..."
    cd "${OUTPUT_DIR}"
    docker compose up -d
    echo ""
    echo "==> Waiting for cluster to form..."
    sleep 30
    bash init-cluster.sh
else
    echo "==> To start the cluster:"
    echo "    cd ${OUTPUT_DIR}"
    echo "    docker compose up -d"
    echo "    # Wait ~30s for nodes to form cluster, then:"
    echo "    bash init-cluster.sh"
fi
