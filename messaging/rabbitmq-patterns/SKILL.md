---
name: rabbitmq-patterns
description: >
  Guide for RabbitMQ messaging patterns using AMQP 0-9-1. Use when: implementing RabbitMQ producers/consumers, configuring exchanges (direct, fanout, topic, headers), setting up dead letter queues, publisher confirms, consumer acknowledgments, prefetch/QoS tuning, quorum queues, RabbitMQ streams, clustering for high availability, RabbitMQ in Docker/Kubernetes, Shovel/Federation plugins, TLS/security/vhosts, or monitoring via management API. Do NOT use when: working with Apache Kafka for log streaming or event sourcing, NATS for lightweight pub/sub, AWS SQS/SNS, Google Pub/Sub, Azure Service Bus, Redis Streams, general message queue theory without RabbitMQ specifics, or ZeroMQ/nanomsg for broker-less messaging.
---

# RabbitMQ Messaging Patterns

## AMQP 0-9-1 Model

### Connections and Channels
Open one TCP connection per application instance. Multiplex work over channels (lightweight virtual connections). Use one channel per thread. Never share channels across threads.

```python
# Python (pika) — connection and channel setup
import pika

credentials = pika.PlainCredentials('user', 'secret')
params = pika.ConnectionParameters(
    host='rabbitmq.example.com', port=5672,
    virtual_host='/production', credentials=credentials,
    heartbeat=60, blocked_connection_timeout=300
)
connection = pika.BlockingConnection(params)
channel = connection.channel()
```

### Exchanges
Four exchange types route messages from producers to queues via bindings:

| Type | Routing Logic | Use Case |
|------|--------------|----------|
| `direct` | Exact routing key match | Task routing by key |
| `fanout` | Broadcast to all bound queues | Event notifications |
| `topic` | Wildcard pattern (`*` one word, `#` zero-or-more) | Hierarchical event filtering |
| `headers` | Match on message headers (x-match: all/any) | Complex multi-attribute routing |

```python
# Declare exchanges
channel.exchange_declare(exchange='orders', exchange_type='topic', durable=True)
channel.exchange_declare(exchange='events', exchange_type='fanout', durable=True)

# Alternate exchange catches unroutable messages
channel.exchange_declare(exchange='unrouted', exchange_type='fanout', durable=True)
channel.exchange_declare(
    exchange='orders', exchange_type='topic', durable=True,
    arguments={'alternate-exchange': 'unrouted'}
)
```

### Queues and Bindings
Declare queues as durable for production. Bind queues to exchanges with routing keys.

```python
# Classic durable queue
channel.queue_declare(queue='order.processing', durable=True, arguments={
    'x-message-ttl': 86400000,          # 24h TTL
    'x-max-length': 100000,             # max 100k messages
    'x-overflow': 'reject-publish',     # backpressure on full
    'x-dead-letter-exchange': 'dlx',
    'x-dead-letter-routing-key': 'order.failed'
})

# Bind with topic pattern
channel.queue_bind(exchange='orders', queue='order.processing',
                   routing_key='order.created.*')
```

## Queue Types

### Quorum Queues (Recommended for HA)
Raft-based replicated queues. Use for all durable queues requiring fault tolerance. Replace deprecated classic mirrored queues.

```python
channel.queue_declare(queue='payments', durable=True, arguments={
    'x-queue-type': 'quorum',
    'x-quorum-initial-group-size': 3,   # replicate across 3 nodes
    'x-delivery-limit': 5,             # max redeliveries before dead-lettering
    'x-dead-letter-exchange': 'dlx',
    'x-dead-letter-strategy': 'at-least-once'
})
```

Quorum queue constraints: no exclusive queues, no non-durable mode, no priority, no global QoS. Always durable, always replicated.

### Streams (RabbitMQ 3.9+)
Append-only log structure for high-throughput fan-out and replay. Non-destructive reads — multiple consumers read independently without removing messages.

```python
# Declare a stream
channel.queue_declare(queue='events.log', durable=True, arguments={
    'x-queue-type': 'stream',
    'x-max-length-bytes': 5_000_000_000,  # 5GB retention
    'x-max-age': '7D',                    # 7-day retention
    'x-stream-max-segment-size-bytes': 100_000_000
})

# Consume from stream — must set QoS and offset
channel.basic_qos(prefetch_count=100)
channel.basic_consume(queue='events.log', on_message_callback=handler,
                      arguments={'x-stream-offset': 'first'})
# Offset options: 'first', 'last', 'next', timestamp, numeric offset
```

Use streams when: multiple consumers need the same data, replay is required, ordering matters. Use quorum queues when: competing consumers must each get unique messages.

## Publishing

### Publisher Confirms
Enable confirm mode for reliable publishing. Track delivery tags and handle nacks.

```python
channel.confirm_delivery()

try:
    channel.basic_publish(
        exchange='orders', routing_key='order.created.us',
        body=json.dumps(order),
        properties=pika.BasicProperties(
            delivery_mode=2,          # persistent
            content_type='application/json',
            message_id=str(uuid4()),
            timestamp=int(time.time()),
            headers={'version': '1.0'}
        ),
        mandatory=True   # return if unroutable
    )
except pika.exceptions.UnroutableError:
    handle_unroutable(order)
except pika.exceptions.NackError:
    handle_nack(order)
```

### Message Properties Reference
| Property | Purpose |
|----------|---------|
| `delivery_mode=2` | Persist to disk |
| `content_type` | MIME type for deserialization |
| `message_id` | Idempotency key |
| `correlation_id` | Request-reply correlation |
| `reply_to` | Callback queue name |
| `expiration` | Per-message TTL (ms string) |
| `priority` | 0-255 (requires x-max-priority on queue) |
| `timestamp` | Unix epoch seconds |
| `headers` | Custom key-value metadata |

## Consuming

### Consumer Setup with Manual Acks
Always use manual acknowledgments in production. Set prefetch to control concurrency.

```python
channel.basic_qos(prefetch_count=10)  # per-consumer limit

def on_message(ch, method, properties, body):
    try:
        result = process(json.loads(body))
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except TransientError:
        # Requeue for retry
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
    except PermanentError:
        # Reject to DLQ (requeue=False)
        ch.basic_reject(delivery_tag=method.delivery_tag, requeue=False)

channel.basic_consume(queue='order.processing',
                      on_message_callback=on_message, auto_ack=False)
channel.start_consuming()
```

### Prefetch Tuning
- `prefetch_count=1`: Maximum fairness, lowest throughput. Use for slow/expensive tasks.
- `prefetch_count=10-50`: Balance throughput and fairness. Default starting point.
- `prefetch_count=100-500`: High throughput. Use when processing is fast and uniform.
- For streams, set prefetch ≥ 50 (streams require QoS to be set).

### Consumer Patterns
- **Competing consumers**: Multiple consumers on one queue for horizontal scaling.
- **Exclusive consumer**: Set `exclusive=True` for single-active-consumer semantics.
- **Single active consumer** (quorum queue): Set `x-single-active-consumer: true` on queue declaration for ordered processing with automatic failover.

## Dead Letter Queues (DLQ)

Configure DLX on the source queue. Messages route to DLQ on: reject/nack with `requeue=False`, TTL expiry, or queue length overflow.

```python
# DLX exchange and queue
channel.exchange_declare(exchange='dlx', exchange_type='direct', durable=True)
channel.queue_declare(queue='dead.letters', durable=True, arguments={
    'x-queue-type': 'quorum'
})
channel.queue_bind(exchange='dlx', queue='dead.letters',
                   routing_key='order.failed')

# Retry pattern: DLQ with TTL that republishes back to original exchange
channel.queue_declare(queue='retry.5min', durable=True, arguments={
    'x-message-ttl': 300000,              # 5 min delay
    'x-dead-letter-exchange': 'orders',   # back to source
    'x-dead-letter-routing-key': 'order.created.retry'
})
```

### Retry with Backoff
Implement escalating retry using chained TTL queues:
1. Source queue → reject → retry.1min (TTL 60s, DLX→source)
2. After N failures → retry.5min (TTL 300s, DLX→source)
3. After max retries → final DLQ for manual inspection

Track retry count via `x-death` header (automatically set by RabbitMQ on dead-lettering).

## Node.js (amqplib) Example

```javascript
const amqplib = require('amqplib');

async function setup() {
  const conn = await amqplib.connect('amqp://user:pass@rabbitmq:5672/prod');
  const ch = await conn.createConfirmChannel(); // confirm mode

  await ch.assertExchange('tasks', 'direct', { durable: true });
  await ch.assertQueue('task.process', {
    durable: true,
    arguments: { 'x-queue-type': 'quorum', 'x-delivery-limit': 3,
                 'x-dead-letter-exchange': 'dlx' }
  });
  await ch.bindQueue('task.process', 'tasks', 'process');

  // Publish with confirm
  ch.publish('tasks', 'process', Buffer.from(JSON.stringify(data)),
    { persistent: true, messageId: uuid() },
    (err) => { if (err) console.error('Nacked:', err); }
  );

  // Consume
  ch.prefetch(20);
  ch.consume('task.process', async (msg) => {
    try {
      await processTask(JSON.parse(msg.content.toString()));
      ch.ack(msg);
    } catch (e) {
      ch.nack(msg, false, false); // to DLQ
    }
  });
}
```

## Go (amqp091-go) Example

```go
conn, _ := amqp091.Dial("amqp://user:pass@rabbitmq:5672/prod")
ch, _ := conn.Channel()
ch.Confirm(false) // enable publisher confirms
confirms := ch.NotifyPublish(make(chan amqp091.Confirmation, 1))

ch.ExchangeDeclare("events", "topic", true, false, false, false, nil)
ch.QueueDeclare("event.handler", true, false, false, false, amqp091.Table{
    "x-queue-type": "quorum",
    "x-dead-letter-exchange": "dlx",
})
ch.QueueBind("event.handler", "event.#", "events", false, nil)
ch.Qos(25, 0, false) // prefetch 25

msgs, _ := ch.Consume("event.handler", "", false, false, false, false, nil)
for msg := range msgs {
    if err := handle(msg.Body); err != nil {
        msg.Nack(false, false) // to DLQ
    } else {
        msg.Ack(false)
    }
}
```

## Clustering and High Availability

### Cluster Setup
Deploy odd-number clusters (3 or 5 nodes). All nodes share the Erlang cookie.

```bash
# Join node to existing cluster
rabbitmqctl stop_app
rabbitmqctl reset
rabbitmqctl join_cluster rabbit@node1
rabbitmqctl start_app
rabbitmqctl cluster_status
```

### Topology Guidelines
- Use quorum queues (replicated across majority). Classic mirrored queues are deprecated.
- Place a TCP load balancer (HAProxy/Nginx) in front of the cluster.
- Distribute clients across all nodes. Quorum queue leader election is automatic.
- Set `cluster_partition_handling = pause_minority` for network partition safety.

## Security

### TLS Configuration (rabbitmq.conf)
```ini
listeners.tcp = none
listeners.ssl.default = 5671
ssl_options.cacertfile = /etc/rabbitmq/ssl/ca.pem
ssl_options.certfile   = /etc/rabbitmq/ssl/server.pem
ssl_options.keyfile    = /etc/rabbitmq/ssl/server-key.pem
ssl_options.verify     = verify_peer
ssl_options.fail_if_no_peer_cert = true
ssl_options.versions.1 = tlsv1.3
ssl_options.versions.2 = tlsv1.2
```

### Authentication and Authorization
- Delete default `guest` user. Create per-service accounts with minimal permissions.
- Use vhosts for tenant isolation. Each vhost has independent exchanges, queues, permissions.
- Set granular permissions: `configure`, `write`, `read` regex patterns per user per vhost.

```bash
rabbitmqctl add_vhost /payments
rabbitmqctl add_user payment_svc 'strong-password'
rabbitmqctl set_permissions -p /payments payment_svc "^payment\." "^payment\." "^payment\."
rabbitmqctl set_user_tags payment_svc monitoring
```

## Docker Deployment

```yaml
# docker-compose.yml
services:
  rabbitmq:
    image: rabbitmq:3.13-management-alpine
    hostname: rabbit1
    ports:
      - "5672:5672"    # AMQP
      - "15672:15672"  # Management UI
      - "5552:5552"    # Streams
    environment:
      RABBITMQ_DEFAULT_USER: admin
      RABBITMQ_DEFAULT_PASS: "${RABBITMQ_PASSWORD}"
      RABBITMQ_DEFAULT_VHOST: /production
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
      - ./rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro
      - ./definitions.json:/etc/rabbitmq/definitions.json:ro
    deploy:
      resources:
        limits: { memory: 2G }
volumes:
  rabbitmq_data:
```

## Kubernetes Deployment

Use the RabbitMQ Cluster Operator for production:

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: rabbitmq
spec:
  replicas: 3
  image: rabbitmq:3.13-management
  persistence:
    storageClassName: fast-ssd
    storage: 50Gi
  resources:
    requests: { cpu: "500m", memory: 1Gi }
    limits:   { cpu: "2", memory: 4Gi }
  rabbitmq:
    additionalConfig: |
      cluster_partition_handling = pause_minority
      default_vhost = /production
      vm_memory_high_watermark.relative = 0.7
      disk_free_limit.relative = 1.5
      queue_leader_locator = balanced
  tls:
    secretName: rabbitmq-tls
```

## Shovel and Federation

### Shovel
Transfer messages between brokers (local or remote). Use for migration, bridging, cross-DC replication.

```bash
rabbitmq-plugins enable rabbitmq_shovel rabbitmq_shovel_management
# Define dynamic shovel via management API
rabbitmqctl set_parameter shovel my-shovel \
  '{"src-protocol":"amqp091","src-uri":"amqp://source","src-queue":"orders",
    "dest-protocol":"amqp091","dest-uri":"amqp://dest","dest-queue":"orders"}'
```

### Federation
Loosely couple brokers across WAN. Upstream exchanges/queues subscribe to downstream.

```bash
rabbitmq-plugins enable rabbitmq_federation rabbitmq_federation_management
rabbitmqctl set_parameter federation-upstream dc2 \
  '{"uri":"amqp://user:pass@dc2-rabbit","expires":3600000}'
rabbitmqctl set_policy federate-orders "^orders$" \
  '{"federation-upstream-set":"all"}' --apply-to exchanges
```

## Monitoring

### Key Metrics to Track
- Queue depth, message rates (publish/deliver/ack per second)
- Consumer count and utilization, unacked message count
- Memory and disk usage, file descriptor count
- Erlang process count, connection/channel count
- Raft term and commit index (quorum queues)

### Management HTTP API
```bash
# Queue details
curl -u admin:pass http://rabbitmq:15672/api/queues/%2Fproduction/order.processing

# Cluster health
curl -u admin:pass http://rabbitmq:15672/api/health/checks/alarms

# Prometheus metrics (enable rabbitmq_prometheus plugin)
curl http://rabbitmq:15692/metrics
```

### Alarms and Flow Control
- Memory alarm triggers at `vm_memory_high_watermark` (default 0.4 of RAM). Publishers block.
- Disk alarm triggers at `disk_free_limit`. Publishers block.
- Flow control: per-connection throttling when broker is overloaded. Monitor via `rabbitmqctl list_connections` state column.

## Performance Tuning Checklist

1. Use quorum queues for durability; classic queues only for transient workloads.
2. Set `prefetch_count` appropriately — never use unlimited (0) in production.
3. Keep queues short. Target near-zero depth for latency-sensitive workloads.
4. Use lazy queues (`x-queue-mode: lazy`) for large backlogs to reduce memory pressure.
5. Batch publisher confirms (`wait_for_confirms()` after N publishes) for throughput.
6. Use persistent messages (`delivery_mode=2`) only when durability is required.
7. Set `heartbeat=60` to detect dead connections. Set `blocked_connection_timeout`.
8. Size Erlang VM: `RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="+P 1048576"` for high connection count.
9. Pin queue leaders across nodes: `queue_leader_locator = balanced`.
10. Monitor and alert on memory/disk watermarks before they trigger.
