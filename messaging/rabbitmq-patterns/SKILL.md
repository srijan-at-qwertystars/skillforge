---
name: rabbitmq-patterns
description: >
  Guide for RabbitMQ messaging patterns using AMQP 0-9-1 and 1.0. Use when building message queuing systems, AMQP-based architectures, pub/sub messaging, work queues, RPC over messaging, dead letter exchanges, fan-out routing, topic-based routing, quorum queues, RabbitMQ streams, or priority queues. Covers connections, channels, exchanges, bindings, publisher confirms, consumer acks, clustering, TLS security, and monitoring. Do NOT use for Apache Kafka or event streaming platforms, Redis pub/sub, AWS SQS/SNS managed queues, simple in-process queues or channels (use language-native constructs), or real-time WebSocket communication (use socket.io or ws). Not suitable for event sourcing/log-based architectures where Kafka is the better fit.
---

# RabbitMQ Messaging Patterns

## Installation and Docker Setup

Run RabbitMQ with the management plugin via Docker:

```bash
# Single node with management UI
docker run -d --name rabbitmq \
  -p 5672:5672 -p 15672:15672 \
  -e RABBITMQ_DEFAULT_USER=admin \
  -e RABBITMQ_DEFAULT_PASS=secret \
  rabbitmq:4.0-management

# Docker Compose for development
cat <<'EOF' > docker-compose.yml
services:
  rabbitmq:
    image: rabbitmq:4.0-management
    ports:
      - "5672:5672"
      - "15672:15672"
      - "5552:5552"   # streams port
    environment:
      RABBITMQ_DEFAULT_USER: admin
      RABBITMQ_DEFAULT_PASS: secret
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
volumes:
  rabbitmq_data:
EOF
docker compose up -d
```

Install on Linux directly:

```bash
# Ubuntu/Debian (Erlang + RabbitMQ from Cloudsmith)
sudo apt-get install -y erlang-base rabbitmq-server
sudo rabbitmq-plugins enable rabbitmq_management
sudo systemctl start rabbitmq-server
```

Access management UI at `http://localhost:15672` (admin/secret).

## Core Concepts

**Connection**: TCP connection from client to broker. Expensive to create — reuse across the application lifecycle. One connection per application process is typical.

**Channel**: Lightweight virtual connection multiplexed over a single TCP connection. Use one channel per thread/coroutine. Never share channels across threads.

**Exchange**: Receives messages from producers and routes them to queues based on bindings and routing keys. Messages are never stored in exchanges.

**Queue**: Buffer that stores messages until consumed. Declare queues as durable for persistence across broker restarts.

**Binding**: Rule linking an exchange to a queue with an optional routing key or header match.

**Virtual Host (vhost)**: Logical grouping providing namespace isolation for exchanges, queues, and permissions. Use separate vhosts per application or environment.

## Exchange Types

### Direct Exchange
Route messages by exact routing key match. Default exchange (`""`) routes to queue matching the routing key name.

```python
# Producer
channel.exchange_declare(exchange='orders', exchange_type='direct', durable=True)
channel.basic_publish(exchange='orders', routing_key='order.created',
                      body=json.dumps(order), properties=pika.BasicProperties(delivery_mode=2))

# Consumer
channel.queue_declare(queue='order-processor', durable=True)
channel.queue_bind(exchange='orders', queue='order-processor', routing_key='order.created')
```

### Fanout Exchange
Broadcast to all bound queues. Routing key is ignored. Use for event broadcasting.

```python
channel.exchange_declare(exchange='events', exchange_type='fanout', durable=True)
channel.basic_publish(exchange='events', routing_key='', body=json.dumps(event))
# Every bound queue receives a copy
```

### Topic Exchange
Route by routing key pattern with wildcards: `*` matches one word, `#` matches zero or more words.

```python
channel.exchange_declare(exchange='logs', exchange_type='topic', durable=True)
# Bind: queue receives all error logs
channel.queue_bind(exchange='logs', queue='errors', routing_key='*.error.#')
# Publish: routing_key='payment.error.timeout' matches the binding
```

### Headers Exchange
Route by message header attributes instead of routing key. Set `x-match` to `all` (every header must match) or `any` (at least one).

```python
channel.queue_bind(exchange='processing', queue='pdf-queue',
    arguments={'x-match': 'all', 'format': 'pdf', 'type': 'report'})
```

## Message Patterns

### Work Queues (Competing Consumers)
Distribute tasks among multiple workers. Set `prefetch_count` to control load per consumer.

```python
channel.basic_qos(prefetch_count=10)
channel.basic_consume(queue='tasks', on_message_callback=process_task)
```

Set prefetch to 1 for expensive tasks (fair dispatch). Set 10–50 for lightweight tasks.

### Publish/Subscribe
Use fanout exchange. Each subscriber gets its own exclusive queue.

```python
result = channel.queue_declare(queue='', exclusive=True)
channel.queue_bind(exchange='events', queue=result.method.queue)
```

### Routing
Use direct exchange with multiple bindings per queue to filter by severity/type.

### Topics
Use topic exchange for flexible multi-criteria routing. Pattern: `<facility>.<severity>.<component>`.

### RPC Over Messaging
Use `reply_to` and `correlation_id` properties. Client creates an exclusive callback queue.

```python
# Client
corr_id = str(uuid.uuid4())
channel.basic_publish(exchange='', routing_key='rpc_queue',
    properties=pika.BasicProperties(reply_to=callback_queue, correlation_id=corr_id),
    body=json.dumps(request))

# Server
channel.basic_publish(exchange='', routing_key=props.reply_to,
    properties=pika.BasicProperties(correlation_id=props.correlation_id),
    body=json.dumps(result))
channel.basic_ack(delivery_tag=method.delivery_tag)
```

Set `expiration` on RPC messages to prevent stale requests accumulating.

## Reliability

### Publisher Confirms
Enable on the channel to get broker acknowledgment that messages were persisted.

```python
channel.confirm_delivery()
try:
    channel.basic_publish(exchange='orders', routing_key='new',
        body=data, properties=pika.BasicProperties(delivery_mode=2),
        mandatory=True)
except pika.exceptions.UnroutableError:
    handle_unroutable()
```

For Node.js (amqplib), use `channel.waitForConfirms()` or the confirm channel wrapper.

### Consumer Acknowledgments
Always use manual acks. Ack after successful processing, nack/reject on failure.

```python
def callback(ch, method, properties, body):
    try:
        process(body)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception:
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
```

Set `requeue=False` to route failed messages to a dead letter exchange instead of looping.

### Dead Letter Exchanges (DLX)
Route rejected, expired, or max-length-exceeded messages to a DLX for analysis or retry.

```python
# Declare main queue with DLX
channel.queue_declare(queue='orders', durable=True, arguments={
    'x-dead-letter-exchange': 'dlx',
    'x-dead-letter-routing-key': 'orders.dead',
    'x-message-ttl': 60000,          # optional: 60s TTL
    'x-max-length': 100000           # optional: max queue depth
})

# DLX setup
channel.exchange_declare(exchange='dlx', exchange_type='direct', durable=True)
channel.queue_declare(queue='orders-dlq', durable=True)
channel.queue_bind(exchange='dlx', queue='orders-dlq', routing_key='orders.dead')
```

Implement retry with increasing delays by chaining TTL queues back to the original exchange.

## Quorum Queues vs Classic Queues

Use quorum queues for replicated, highly available workloads. Use classic queues only for non-replicated, transient, or high-throughput ephemeral data.

| Feature | Quorum Queue | Classic Queue |
|---|---|---|
| Replication | Raft-based, across nodes | None (CQv2) or removed mirroring |
| Data safety | Consistent, survives node loss | Single-node persistence only |
| Poison message handling | Built-in delivery limit (default 20 in 4.0) | Manual via DLX |
| Priority | 2-level in 4.0 (normal/high) | Up to 255 levels |
| Performance | Optimized for safety | Higher throughput for transient msgs |

Declare a quorum queue:

```python
channel.queue_declare(queue='critical-orders', durable=True, arguments={
    'x-queue-type': 'quorum',
    'x-delivery-limit': 5,
    'x-dead-letter-exchange': 'dlx',
    'x-dead-letter-strategy': 'at-least-once'
})
```

In RabbitMQ 4.0, classic mirrored queues are removed. Migrate all mirrored queues to quorum queues.

## RabbitMQ Streams

Streams provide a persistent, replicated, append-only log. Use for fan-out to many consumers, replay from offset, and large backlogs. Enable the stream plugin:

```bash
rabbitmq-plugins enable rabbitmq_stream
```

Declare and consume a stream:

```python
# Declare stream
channel.queue_declare(queue='events-stream', durable=True, arguments={
    'x-queue-type': 'stream',
    'x-max-length-bytes': 5_000_000_000,   # 5GB retention
    'x-max-age': '7D'                       # 7-day retention
})

# Consume from offset
channel.basic_consume(queue='events-stream', on_message_callback=handler,
    arguments={'x-stream-offset': 'first'})  # or 'last', 'next', timestamp, offset int
```

RabbitMQ 3.13+ supports stream filtering — consumers specify a filter to receive only matching messages, reducing bandwidth. Streams are not a Kafka replacement. Use them when you need replay + RabbitMQ's routing model.

## Priority Queues and TTL

Declare a priority queue (classic queues only for full range; quorum queues: 2 levels in 4.0):

```python
channel.queue_declare(queue='tasks', durable=True,
    arguments={'x-max-priority': 10})
channel.basic_publish(exchange='', routing_key='tasks', body=data,
    properties=pika.BasicProperties(priority=5))
```

Set per-message or per-queue TTL:

```python
# Per-message TTL (milliseconds)
props = pika.BasicProperties(expiration='30000')
# Per-queue TTL
channel.queue_declare(queue='temp', arguments={'x-message-ttl': 60000})
```

Expired messages route to DLX if configured.

## Client Libraries

### Node.js — amqplib

```javascript
const amqp = require('amqplib');
const conn = await amqp.connect('amqp://admin:secret@localhost');
const ch = await conn.createConfirmChannel();
await ch.assertQueue('tasks', { durable: true, arguments: { 'x-queue-type': 'quorum' } });
ch.sendToQueue('tasks', Buffer.from(JSON.stringify(payload)), { persistent: true });
await ch.waitForConfirms();
ch.consume('tasks', (msg) => { process(msg.content); ch.ack(msg); }, { prefetch: 10 });
```

### Python — pika

```python
import pika
conn = pika.BlockingConnection(pika.ConnectionParameters('localhost',
    credentials=pika.PlainCredentials('admin', 'secret')))
ch = conn.channel()
ch.confirm_delivery()
ch.queue_declare(queue='tasks', durable=True)
ch.basic_publish(exchange='', routing_key='tasks', body=data,
    properties=pika.BasicProperties(delivery_mode=2))
```

### Go — amqp091-go

```go
conn, _ := amqp091.Dial("amqp://admin:secret@localhost:5672/")
ch, _ := conn.Channel()
ch.Confirm(false)
ch.QueueDeclare("tasks", true, false, false, false, amqp091.Table{"x-queue-type": "quorum"})
ch.PublishWithContext(ctx, "", "tasks", false, false, amqp091.Publishing{
    DeliveryMode: amqp091.Persistent, Body: []byte(data),
})
```

### Java — RabbitMQ Java Client

```java
ConnectionFactory factory = new ConnectionFactory();
factory.setUri("amqp://admin:secret@localhost");
Connection conn = factory.newConnection();
Channel ch = conn.createChannel();
ch.confirmSelect();
ch.queueDeclare("tasks", true, false, false, Map.of("x-queue-type", "quorum"));
ch.basicPublish("", "tasks", MessageProperties.PERSISTENT_TEXT_PLAIN, data);
ch.waitForConfirmsOrDie(5000);
```

## Management Plugin and HTTP API

```bash
# List queues
curl -u admin:secret http://localhost:15672/api/queues

# Publish a test message
curl -u admin:secret -X POST http://localhost:15672/api/exchanges/%2F/amq.default/publish \
  -H 'Content-Type: application/json' \
  -d '{"properties":{},"routing_key":"tasks","payload":"test","payload_encoding":"string"}'

# Get queue details
curl -u admin:secret http://localhost:15672/api/queues/%2F/tasks
```

Use `rabbitmqadmin` CLI for scripting queue/exchange/binding management.

## Clustering and High Availability

Set up a 3-node cluster (minimum for quorum queues):

```bash
# On node2 and node3:
rabbitmqctl stop_app
rabbitmqctl join_cluster rabbit@node1
rabbitmqctl start_app
rabbitmqctl cluster_status
```

Ensure `.erlang.cookie` is identical across all nodes. Use consistent DNS or `/etc/hosts`. In 4.0, Khepri replaces Mnesia as the metadata store, improving partition tolerance.

Set quorum queue replication factor via policy:

```bash
rabbitmqctl set_policy ha-quorum "^critical\." \
  '{"queue-type":"quorum","x-quorum-initial-group-size":3}' --apply-to queues
```

## Monitoring and Alerting

Expose Prometheus metrics:

```bash
rabbitmq-plugins enable rabbitmq_prometheus
# Metrics at http://localhost:15692/metrics
```

Key metrics to monitor:
- `rabbitmq_queue_messages` — queue depth (alert if growing)
- `rabbitmq_queue_consumers` — consumer count (alert if zero)
- `rabbitmq_channel_messages_unacked` — unacked messages (alert if high)
- `rabbitmq_node_mem_used` / `rabbitmq_node_disk_free` — resource alarms

Set resource alarms in `rabbitmq.conf`:

```ini
vm_memory_high_watermark.relative = 0.7
disk_free_limit.absolute = 2GB
```

## Security

### TLS Configuration

```ini
# rabbitmq.conf
listeners.ssl.default = 5671
ssl_options.cacertfile = /certs/ca.pem
ssl_options.certfile = /certs/server.pem
ssl_options.keyfile = /certs/server-key.pem
ssl_options.verify = verify_peer
ssl_options.fail_if_no_peer_cert = true
```

### Authentication and Authorization

```bash
# Create user with limited permissions
rabbitmqctl add_user app_service strong_password
rabbitmqctl set_permissions -p /production app_service "^app\." "^app\." "^app\."
# Pattern: configure, write, read regex for resources
rabbitmqctl delete_user guest  # Remove default user in production
```

Use vhosts to isolate applications: `rabbitmqctl add_vhost /production`.

## Common Pitfalls and Troubleshooting

**Connection churn**: Reuse connections. Creating a new connection per publish kills performance. Use connection pooling.

**Channel leaks**: Close channels after use. One channel per thread, not per message.

**Unbounded queues**: Always set `x-max-length` or `x-max-length-bytes` with DLX for overflow.

**Missing acks**: Unacked messages pile up. Set `consumer_timeout` (default 30min in 3.12+) to detect stuck consumers.

**No prefetch limit**: Without `basic_qos`, RabbitMQ pushes all messages to one consumer. Always set prefetch.

**Publishing without confirms**: Messages silently drop if broker rejects them. Enable publisher confirms.

**Memory alarms**: Publishers block when memory exceeds watermark. Monitor and tune `vm_memory_high_watermark`.

**Network partitions**: Use `cluster_partition_handling = pause_minority`. Khepri in 4.0 improves this.

**Slow consumers**: Monitor `messages_unacked`. Scale horizontally or use streams for high fan-out.
