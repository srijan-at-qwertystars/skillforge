#!/usr/bin/env bash
#
# setup-rabbitmq.sh — Docker-based RabbitMQ setup with management plugin
# Creates vhost, user, and sample exchanges/queues for development
#
set -euo pipefail

# Configuration (override via environment variables)
RABBITMQ_CONTAINER="${RABBITMQ_CONTAINER:-rabbitmq-dev}"
RABBITMQ_IMAGE="${RABBITMQ_IMAGE:-rabbitmq:4.0-management}"
RABBITMQ_ADMIN_USER="${RABBITMQ_ADMIN_USER:-admin}"
RABBITMQ_ADMIN_PASS="${RABBITMQ_ADMIN_PASS:-admin_secret}"
RABBITMQ_APP_USER="${RABBITMQ_APP_USER:-app_service}"
RABBITMQ_APP_PASS="${RABBITMQ_APP_PASS:-app_secret}"
RABBITMQ_VHOST="${RABBITMQ_VHOST:-development}"
RABBITMQ_PORT="${RABBITMQ_PORT:-5672}"
RABBITMQ_MGMT_PORT="${RABBITMQ_MGMT_PORT:-15672}"
RABBITMQ_STREAM_PORT="${RABBITMQ_STREAM_PORT:-5552}"
API_URL="http://localhost:${RABBITMQ_MGMT_PORT}/api"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

wait_for_rabbitmq() {
    local max_attempts=30
    local attempt=0
    info "Waiting for RabbitMQ management API..."
    while ! curl -sf -u "${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASS}" \
        "${API_URL}/overview" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            error "RabbitMQ did not become ready in time"
        fi
        sleep 2
    done
    ok "RabbitMQ is ready"
}

api_put() {
    local path="$1"
    local data="${2:-{}}"
    curl -sf -u "${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASS}" \
        -X PUT "${API_URL}${path}" \
        -H 'Content-Type: application/json' \
        -d "${data}" > /dev/null 2>&1
}

api_post() {
    local path="$1"
    local data="$2"
    curl -sf -u "${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASS}" \
        -X POST "${API_URL}${path}" \
        -H 'Content-Type: application/json' \
        -d "${data}" > /dev/null 2>&1
}

# Step 1: Start RabbitMQ container
info "Starting RabbitMQ container: ${RABBITMQ_CONTAINER}"
if docker ps -a --format '{{.Names}}' | grep -q "^${RABBITMQ_CONTAINER}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${RABBITMQ_CONTAINER}$"; then
        warn "Container '${RABBITMQ_CONTAINER}' already running"
    else
        info "Starting existing container '${RABBITMQ_CONTAINER}'"
        docker start "${RABBITMQ_CONTAINER}"
    fi
else
    docker run -d \
        --name "${RABBITMQ_CONTAINER}" \
        --hostname rabbitmq-dev \
        -p "${RABBITMQ_PORT}:5672" \
        -p "${RABBITMQ_MGMT_PORT}:15672" \
        -p "${RABBITMQ_STREAM_PORT}:5552" \
        -e RABBITMQ_DEFAULT_USER="${RABBITMQ_ADMIN_USER}" \
        -e RABBITMQ_DEFAULT_PASS="${RABBITMQ_ADMIN_PASS}" \
        -v rabbitmq-dev-data:/var/lib/rabbitmq \
        "${RABBITMQ_IMAGE}"
    ok "Container started"
fi

wait_for_rabbitmq

# Step 2: Enable additional plugins
info "Enabling plugins..."
docker exec "${RABBITMQ_CONTAINER}" rabbitmq-plugins enable \
    rabbitmq_stream \
    rabbitmq_prometheus \
    --quiet 2>/dev/null || true
ok "Plugins enabled"

# Step 3: Create vhost
info "Creating vhost: ${RABBITMQ_VHOST}"
api_put "/vhosts/${RABBITMQ_VHOST}" "{\"description\":\"Development vhost\",\"default_queue_type\":\"quorum\"}"
ok "Vhost created"

# Step 4: Create application user
info "Creating app user: ${RABBITMQ_APP_USER}"
api_put "/users/${RABBITMQ_APP_USER}" "{\"password\":\"${RABBITMQ_APP_PASS}\",\"tags\":\"management\"}"
api_put "/permissions/${RABBITMQ_VHOST}/${RABBITMQ_APP_USER}" \
    "{\"configure\":\".*\",\"write\":\".*\",\"read\":\".*\"}"
ok "App user created with full permissions on ${RABBITMQ_VHOST}"

# Step 5: Create sample exchanges
VHOST_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${RABBITMQ_VHOST}', safe=''))" 2>/dev/null || echo "${RABBITMQ_VHOST}")

info "Creating sample exchanges..."
api_put "/exchanges/${VHOST_ENCODED}/orders" \
    '{"type":"topic","durable":true,"arguments":{}}'
api_put "/exchanges/${VHOST_ENCODED}/events" \
    '{"type":"fanout","durable":true,"arguments":{}}'
api_put "/exchanges/${VHOST_ENCODED}/dlx" \
    '{"type":"direct","durable":true,"arguments":{}}'
api_put "/exchanges/${VHOST_ENCODED}/notifications" \
    '{"type":"headers","durable":true,"arguments":{}}'
ok "Exchanges created: orders (topic), events (fanout), dlx (direct), notifications (headers)"

# Step 6: Create sample queues
info "Creating sample queues..."
api_put "/queues/${VHOST_ENCODED}/order-processor" \
    '{"durable":true,"arguments":{"x-queue-type":"quorum","x-delivery-limit":5,"x-dead-letter-exchange":"dlx","x-dead-letter-routing-key":"order-processor.dead"}}'
api_put "/queues/${VHOST_ENCODED}/order-analytics" \
    '{"durable":true,"arguments":{"x-queue-type":"quorum"}}'
api_put "/queues/${VHOST_ENCODED}/event-listener" \
    '{"durable":true,"arguments":{"x-queue-type":"quorum","x-max-length":100000}}'
api_put "/queues/${VHOST_ENCODED}/dlq" \
    '{"durable":true,"arguments":{"x-queue-type":"quorum","x-message-ttl":604800000}}'
api_put "/queues/${VHOST_ENCODED}/notifications-email" \
    '{"durable":true,"arguments":{"x-queue-type":"quorum"}}'
ok "Queues created: order-processor, order-analytics, event-listener, dlq, notifications-email"

# Step 7: Create bindings
info "Creating bindings..."
api_post "/bindings/${VHOST_ENCODED}/e/orders/q/order-processor" \
    '{"routing_key":"order.#","arguments":{}}'
api_post "/bindings/${VHOST_ENCODED}/e/orders/q/order-analytics" \
    '{"routing_key":"order.#","arguments":{}}'
api_post "/bindings/${VHOST_ENCODED}/e/events/q/event-listener" \
    '{"routing_key":"","arguments":{}}'
api_post "/bindings/${VHOST_ENCODED}/e/dlx/q/dlq" \
    '{"routing_key":"#","arguments":{}}'
api_post "/bindings/${VHOST_ENCODED}/e/notifications/q/notifications-email" \
    '{"routing_key":"","arguments":{"x-match":"any","channel":"email"}}'
ok "Bindings created"

# Step 8: Set policies
info "Setting policies..."
api_put "/policies/${VHOST_ENCODED}/default-ttl" \
    '{"pattern":"^(?!amq\\.).*","definition":{"message-ttl":86400000},"priority":0,"apply-to":"queues"}'
ok "Policies set"

# Summary
echo ""
echo "=========================================="
echo " RabbitMQ Development Environment Ready"
echo "=========================================="
echo ""
echo " AMQP:       amqp://localhost:${RABBITMQ_PORT}"
echo " Management: http://localhost:${RABBITMQ_MGMT_PORT}"
echo " Streams:    localhost:${RABBITMQ_STREAM_PORT}"
echo " Prometheus: http://localhost:15692/metrics"
echo ""
echo " Admin user: ${RABBITMQ_ADMIN_USER} / ${RABBITMQ_ADMIN_PASS}"
echo " App user:   ${RABBITMQ_APP_USER} / ${RABBITMQ_APP_PASS}"
echo " Vhost:      ${RABBITMQ_VHOST}"
echo ""
echo " Exchanges:  orders (topic), events (fanout),"
echo "             dlx (direct), notifications (headers)"
echo " Queues:     order-processor, order-analytics,"
echo "             event-listener, dlq, notifications-email"
echo "=========================================="
