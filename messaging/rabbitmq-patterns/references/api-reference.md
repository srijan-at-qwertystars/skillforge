# RabbitMQ Management HTTP API Reference

Base URL: `http://localhost:15672/api`
Default credentials: `guest:guest` (local only) or your configured admin user.
All endpoints return JSON. URL-encode vhost `/` as `%2F`.

---

## Overview / Health Checks

### Cluster Overview

```bash
curl -s -u admin:secret http://localhost:15672/api/overview | jq .
```

Returns cluster name, RabbitMQ/Erlang versions, message rates, queue/connection/channel totals, and node info.

### Health Check (Basic)

```bash
# Simple aliveness test — declares a test queue, publishes, consumes, and cleans up
curl -s -u admin:secret http://localhost:15672/api/aliveness-test/%2F
# Response: {"status":"ok"}
```

### Health Checks (Detailed — 3.8+)

```bash
# Node health check
curl -s -u admin:secret http://localhost:15672/api/health/checks/node-is-quorum-critical

# Check for alarms
curl -s -u admin:secret http://localhost:15672/api/health/checks/alarms

# Check virtual hosts
curl -s -u admin:secret http://localhost:15672/api/health/checks/virtual-hosts

# Check port listener
curl -s -u admin:secret http://localhost:15672/api/health/checks/port-listener/5672

# Check protocol (amqp, mqtt, stomp)
curl -s -u admin:secret http://localhost:15672/api/health/checks/protocol-listener/amqp
```

---

## Nodes

### List All Nodes

```bash
curl -s -u admin:secret http://localhost:15672/api/nodes | jq '.[].name'
```

### Get Node Details

```bash
curl -s -u admin:secret http://localhost:15672/api/nodes/rabbit@hostname | jq '{
  name, running, mem_used, disk_free, fd_used, fd_total, proc_used, proc_total,
  uptime, run_queue
}'
```

### Node Memory Breakdown

```bash
curl -s -u admin:secret http://localhost:15672/api/nodes/rabbit@hostname/memory | jq .
```

---

## Exchanges

### List All Exchanges

```bash
curl -s -u admin:secret http://localhost:15672/api/exchanges | jq '.[].name'

# Filter by vhost
curl -s -u admin:secret http://localhost:15672/api/exchanges/%2F | jq '.[] | {name, type, durable}'
```

### Get Exchange Details

```bash
curl -s -u admin:secret http://localhost:15672/api/exchanges/%2F/orders | jq .
```

### Create Exchange

```bash
curl -s -u admin:secret -X PUT http://localhost:15672/api/exchanges/%2F/orders \
  -H 'Content-Type: application/json' \
  -d '{
    "type": "topic",
    "durable": true,
    "auto_delete": false,
    "arguments": {}
  }'
```

### Delete Exchange

```bash
curl -s -u admin:secret -X DELETE http://localhost:15672/api/exchanges/%2F/orders
# With if-unused flag
curl -s -u admin:secret -X DELETE "http://localhost:15672/api/exchanges/%2F/orders?if-unused=true"
```

### Publish Message to Exchange

```bash
curl -s -u admin:secret -X POST http://localhost:15672/api/exchanges/%2F/orders/publish \
  -H 'Content-Type: application/json' \
  -d '{
    "routing_key": "order.created",
    "payload": "{\"order_id\": 123, \"amount\": 99.99}",
    "payload_encoding": "string",
    "properties": {
      "delivery_mode": 2,
      "content_type": "application/json",
      "headers": {"x-source": "api-test"}
    }
  }'
# Response: {"routed": true}
```

---

## Queues

### List All Queues

```bash
curl -s -u admin:secret http://localhost:15672/api/queues | \
  jq '.[] | {name, vhost, type, messages, consumers, state}'

# Filter by vhost
curl -s -u admin:secret http://localhost:15672/api/queues/%2F | \
  jq '.[] | {name, messages_ready, messages_unacknowledged, consumers}'
```

### Get Queue Details

```bash
curl -s -u admin:secret http://localhost:15672/api/queues/%2F/order-processor | jq '{
  name, type, state, messages, messages_ready, messages_unacknowledged,
  consumers, consumer_utilisation, memory, message_bytes
}'
```

### Create Queue

```bash
# Classic queue
curl -s -u admin:secret -X PUT http://localhost:15672/api/queues/%2F/my-queue \
  -H 'Content-Type: application/json' \
  -d '{
    "durable": true,
    "auto_delete": false,
    "arguments": {
      "x-max-length": 100000,
      "x-message-ttl": 86400000,
      "x-dead-letter-exchange": "dlx"
    }
  }'

# Quorum queue
curl -s -u admin:secret -X PUT http://localhost:15672/api/queues/%2F/critical-queue \
  -H 'Content-Type: application/json' \
  -d '{
    "durable": true,
    "arguments": {
      "x-queue-type": "quorum",
      "x-delivery-limit": 5,
      "x-dead-letter-exchange": "dlx"
    }
  }'

# Stream
curl -s -u admin:secret -X PUT http://localhost:15672/api/queues/%2F/event-stream \
  -H 'Content-Type: application/json' \
  -d '{
    "durable": true,
    "arguments": {
      "x-queue-type": "stream",
      "x-max-length-bytes": 5000000000,
      "x-max-age": "7D"
    }
  }'
```

### Delete Queue

```bash
curl -s -u admin:secret -X DELETE http://localhost:15672/api/queues/%2F/my-queue
# With guards
curl -s -u admin:secret -X DELETE "http://localhost:15672/api/queues/%2F/my-queue?if-empty=true&if-unused=true"
```

### Purge Queue

```bash
curl -s -u admin:secret -X DELETE http://localhost:15672/api/queues/%2F/my-queue/contents
```

### Get Messages (Peek)

```bash
curl -s -u admin:secret -X POST http://localhost:15672/api/queues/%2F/my-queue/get \
  -H 'Content-Type: application/json' \
  -d '{
    "count": 5,
    "ackmode": "ack_requeue_true",
    "encoding": "auto"
  }'
# ackmode options: ack_requeue_true (peek), ack_requeue_false (consume)
```

---

## Bindings

### List All Bindings

```bash
curl -s -u admin:secret http://localhost:15672/api/bindings/%2F | \
  jq '.[] | {source, destination, destination_type, routing_key}'
```

### List Bindings for a Queue

```bash
curl -s -u admin:secret http://localhost:15672/api/queues/%2F/order-processor/bindings | jq .
```

### List Bindings for an Exchange (Source)

```bash
curl -s -u admin:secret http://localhost:15672/api/exchanges/%2F/orders/bindings/source | jq .
```

### Create Binding

```bash
# Exchange → Queue
curl -s -u admin:secret -X POST http://localhost:15672/api/bindings/%2F/e/orders/q/order-processor \
  -H 'Content-Type: application/json' \
  -d '{
    "routing_key": "order.created",
    "arguments": {}
  }'

# Exchange → Exchange
curl -s -u admin:secret -X POST http://localhost:15672/api/bindings/%2F/e/orders/e/order-archive \
  -H 'Content-Type: application/json' \
  -d '{
    "routing_key": "#",
    "arguments": {}
  }'
```

### Delete Binding

```bash
# Need the properties_key from listing bindings (usually the routing key or ~)
curl -s -u admin:secret -X DELETE \
  http://localhost:15672/api/bindings/%2F/e/orders/q/order-processor/order.created
```

---

## Connections

### List All Connections

```bash
curl -s -u admin:secret http://localhost:15672/api/connections | \
  jq '.[] | {name, user, state, channels, peer_host, peer_port, ssl}'
```

### Get Connection Details

```bash
curl -s -u admin:secret http://localhost:15672/api/connections/CONNECTION_NAME | jq '{
  name, user, state, channels, recv_oct, send_oct, connected_at
}'
```

### Close a Connection

```bash
curl -s -u admin:secret -X DELETE http://localhost:15672/api/connections/CONNECTION_NAME \
  -H 'X-Reason: administrative-close'
```

---

## Channels

### List All Channels

```bash
curl -s -u admin:secret http://localhost:15672/api/channels | \
  jq '.[] | {name, connection_details, consumer_count, messages_unacknowledged, prefetch_count}'
```

### Get Channel Details

```bash
curl -s -u admin:secret http://localhost:15672/api/channels/CHANNEL_NAME | jq .
```

---

## Users

### List All Users

```bash
curl -s -u admin:secret http://localhost:15672/api/users | jq '.[] | {name, tags}'
```

### Get User Details

```bash
curl -s -u admin:secret http://localhost:15672/api/users/admin | jq .
```

### Create User

```bash
curl -s -u admin:secret -X PUT http://localhost:15672/api/users/app-service \
  -H 'Content-Type: application/json' \
  -d '{
    "password": "strong_password_here",
    "tags": ""
  }'
# tags: "administrator", "monitoring", "management", "policymaker", or ""
```

### Delete User

```bash
curl -s -u admin:secret -X DELETE http://localhost:15672/api/users/app-service
```

### Set User Permissions

```bash
curl -s -u admin:secret -X PUT http://localhost:15672/api/permissions/%2F/app-service \
  -H 'Content-Type: application/json' \
  -d '{
    "configure": "^app\\.",
    "write": "^app\\.",
    "read": "^(app\\.|events\\.)"
  }'
```

### List User Permissions

```bash
curl -s -u admin:secret http://localhost:15672/api/users/app-service/permissions | jq .
```

---

## Virtual Hosts

### List All Vhosts

```bash
curl -s -u admin:secret http://localhost:15672/api/vhosts | jq '.[] | {name, messages, tracing}'
```

### Create Vhost

```bash
curl -s -u admin:secret -X PUT http://localhost:15672/api/vhosts/production \
  -H 'Content-Type: application/json' \
  -d '{
    "description": "Production environment",
    "tags": "production",
    "default_queue_type": "quorum"
  }'
```

### Delete Vhost

```bash
curl -s -u admin:secret -X DELETE http://localhost:15672/api/vhosts/staging
```

### Set Vhost Limits

```bash
curl -s -u admin:secret -X PUT http://localhost:15672/api/vhost-limits/production/max-queues \
  -H 'Content-Type: application/json' \
  -d '{"value": 1000}'

curl -s -u admin:secret -X PUT http://localhost:15672/api/vhost-limits/production/max-connections \
  -H 'Content-Type: application/json' \
  -d '{"value": 500}'
```

---

## Policies

### List All Policies

```bash
curl -s -u admin:secret http://localhost:15672/api/policies | jq .
# By vhost
curl -s -u admin:secret http://localhost:15672/api/policies/%2F | jq .
```

### Create/Update Policy

```bash
# HA policy for quorum queues
curl -s -u admin:secret -X PUT http://localhost:15672/api/policies/%2F/quorum-default \
  -H 'Content-Type: application/json' \
  -d '{
    "pattern": "^(?!amq\\.).*",
    "definition": {
      "queue-type": "quorum",
      "delivery-limit": 5,
      "dead-letter-exchange": "dlx"
    },
    "priority": 0,
    "apply-to": "queues"
  }'

# TTL policy
curl -s -u admin:secret -X PUT http://localhost:15672/api/policies/%2F/ttl-default \
  -H 'Content-Type: application/json' \
  -d '{
    "pattern": "^temp\\.",
    "definition": {
      "message-ttl": 3600000,
      "max-length": 50000,
      "overflow": "reject-publish"
    },
    "priority": 1,
    "apply-to": "queues"
  }'
```

### Delete Policy

```bash
curl -s -u admin:secret -X DELETE http://localhost:15672/api/policies/%2F/old-policy
```

---

## Definitions (Export/Import)

### Export All Definitions

```bash
# Full cluster definitions (exchanges, queues, bindings, users, vhosts, policies)
curl -s -u admin:secret http://localhost:15672/api/definitions | jq . > definitions.json

# Per-vhost export
curl -s -u admin:secret http://localhost:15672/api/definitions/%2F | jq . > vhost-definitions.json
```

### Import Definitions

```bash
curl -s -u admin:secret -X POST http://localhost:15672/api/definitions \
  -H 'Content-Type: application/json' \
  -d @definitions.json
```

---

## Parameters (Shovels, Federation)

### List Parameters

```bash
curl -s -u admin:secret http://localhost:15672/api/parameters | jq .
# By component
curl -s -u admin:secret http://localhost:15672/api/parameters/shovel/%2F | jq .
curl -s -u admin:secret http://localhost:15672/api/parameters/federation-upstream/%2F | jq .
```

### Create Shovel

```bash
curl -s -u admin:secret -X PUT \
  http://localhost:15672/api/parameters/shovel/%2F/my-shovel \
  -H 'Content-Type: application/json' \
  -d '{
    "value": {
      "src-protocol": "amqp091",
      "src-uri": "amqp://source-host",
      "src-queue": "source-queue",
      "dest-protocol": "amqp091",
      "dest-uri": "amqp://dest-host",
      "dest-exchange": "dest-exchange",
      "ack-mode": "on-confirm"
    }
  }'
```

---

## Pagination and Filtering

Most list endpoints support pagination and filtering:

```bash
# Pagination
curl -s -u admin:secret "http://localhost:15672/api/queues/%2F?page=1&page_size=100"

# Column filtering (reduce response size)
curl -s -u admin:secret "http://localhost:15672/api/queues/%2F?columns=name,messages,consumers"

# Name filtering (regex)
curl -s -u admin:secret "http://localhost:15672/api/queues/%2F?name=order&use_regex=true"

# Sorting
curl -s -u admin:secret "http://localhost:15672/api/queues/%2F?sort=messages&sort_reverse=true"
```

---

## Common Response Codes

| Code | Meaning |
|---|---|
| 200 | Success (GET) |
| 201 | Created (PUT for new resources) |
| 204 | No Content (PUT for existing, DELETE) |
| 400 | Bad request (invalid JSON or arguments) |
| 401 | Unauthorized (bad credentials) |
| 404 | Resource not found |
| 405 | Method not allowed |
| 409 | Conflict (e.g., resource already exists with different properties) |

---

## Rate Limiting and Best Practices

- Management API is intended for monitoring and administration, not high-throughput messaging
- Default rate limit: 100 requests/second per connection
- Use `columns` parameter to reduce payload size
- Prefer the Prometheus endpoint (`/metrics` on port 15692) for monitoring dashboards
- Cache overview data — don't poll `/api/overview` more than once per 5 seconds
- For bulk operations, use definitions import instead of individual API calls
