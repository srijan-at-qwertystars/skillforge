# Advanced RabbitMQ Patterns

## Table of Contents

- [Saga / Choreography with RabbitMQ](#saga--choreography-with-rabbitmq)
- [Consistent Hashing Exchange](#consistent-hashing-exchange)
- [Delayed Message Exchange Plugin](#delayed-message-exchange-plugin)
- [Message Deduplication](#message-deduplication)
- [Exactly-Once Processing Strategies](#exactly-once-processing-strategies)
- [Consumer Concurrency Tuning](#consumer-concurrency-tuning)
- [Prefetch Optimization](#prefetch-optimization)
- [Shovel and Federation](#shovel-and-federation)
- [Lazy Queues vs Quorum Queues Decision Matrix](#lazy-queues-vs-quorum-queues-decision-matrix)
- [RabbitMQ Streams for Log-Style Workloads](#rabbitmq-streams-for-log-style-workloads)

---

## Saga / Choreography with RabbitMQ

### Overview

The saga pattern coordinates distributed transactions across microservices without a centralized orchestrator (choreography) or with one (orchestration). RabbitMQ provides the messaging backbone for both styles.

### Choreography Pattern

Each service listens for events and publishes the next step. No central coordinator exists — services react to domain events.

```
OrderService --[order.created]--> PaymentService
PaymentService --[payment.completed]--> InventoryService
InventoryService --[inventory.reserved]--> ShippingService
```

#### Exchange and Queue Topology

```python
# Each service declares its own exchange for outbound events
channel.exchange_declare(exchange='order-events', exchange_type='topic', durable=True)
channel.exchange_declare(exchange='payment-events', exchange_type='topic', durable=True)
channel.exchange_declare(exchange='inventory-events', exchange_type='topic', durable=True)

# PaymentService subscribes to order events
channel.queue_declare(queue='payment.order-listener', durable=True,
    arguments={'x-queue-type': 'quorum'})
channel.queue_bind(exchange='order-events', queue='payment.order-listener',
    routing_key='order.created')
```

#### Compensating Transactions

When a step fails, publish a compensation event to undo prior steps:

```python
def handle_payment_failed(ch, method, properties, body):
    event = json.loads(body)
    # Publish compensation event
    ch.basic_publish(
        exchange='payment-events',
        routing_key='payment.failed',
        body=json.dumps({
            'order_id': event['order_id'],
            'reason': 'insufficient_funds',
            'compensate': True
        }),
        properties=pika.BasicProperties(delivery_mode=2)
    )
    ch.basic_ack(delivery_tag=method.delivery_tag)
```

### Orchestration Pattern

A central saga orchestrator sends commands and listens for replies:

```python
# Orchestrator sends commands via direct exchange
channel.basic_publish(exchange='saga-commands', routing_key='payment.process',
    body=json.dumps({'saga_id': saga_id, 'order_id': order_id, 'amount': 99.99}),
    properties=pika.BasicProperties(
        reply_to='saga-replies',
        correlation_id=saga_id,
        delivery_mode=2
    ))

# Orchestrator listens for replies
channel.basic_consume(queue='saga-replies', on_message_callback=handle_saga_reply)
```

### Best Practices

- Use `correlation_id` to track the saga across services
- Store saga state in a database (not in messages) for recovery
- Set message TTLs on saga commands to prevent stale sagas
- Implement idempotent handlers — messages may be delivered more than once
- Use quorum queues for saga queues to prevent message loss
- Add a `saga_timeout` mechanism to detect and compensate stuck sagas

---

## Consistent Hashing Exchange

### Overview

The `x-consistent-hash` exchange type distributes messages across bound queues using consistent hashing on the routing key (or message header). This provides sticky routing: the same routing key always maps to the same queue, enabling ordered processing per key while distributing load.

### Installation

```bash
rabbitmq-plugins enable rabbitmq_consistent_hash_exchange
```

### Setup

```python
# Declare consistent hash exchange
channel.exchange_declare(
    exchange='order-partitioned',
    exchange_type='x-consistent-hash',
    durable=True
)

# Bind queues with weight (routing key = weight as string)
for i in range(4):
    queue_name = f'order-partition-{i}'
    channel.queue_declare(queue=queue_name, durable=True,
        arguments={'x-queue-type': 'quorum'})
    channel.queue_bind(
        exchange='order-partitioned',
        queue=queue_name,
        routing_key='100'  # weight: higher = more messages
    )
```

### Publishing

```python
# Messages with the same routing key always go to the same queue
channel.basic_publish(
    exchange='order-partitioned',
    routing_key=str(customer_id),  # hash key
    body=json.dumps(order)
)
```

### Hashing on Headers

To hash on a header instead of routing key:

```python
channel.exchange_declare(
    exchange='header-partitioned',
    exchange_type='x-consistent-hash',
    durable=True,
    arguments={'hash-header': 'tenant-id'}
)
```

### Use Cases

- Per-customer ordering guarantees without single-queue bottleneck
- Partitioning workloads across consumer groups
- Sharding by tenant in multi-tenant systems
- Session-affinity routing

### Caveats

- Adding/removing queues causes key redistribution (some keys move to new queues)
- Not suitable when strict global ordering is required
- Monitor queue depth skew — hash distribution is statistical, not perfectly even

---

## Delayed Message Exchange Plugin

### Overview

The `rabbitmq_delayed_message_exchange` plugin enables scheduling messages for future delivery. Messages are held by the exchange (not a queue) and delivered after the specified delay.

### Installation

```bash
# Download the plugin .ez file for your RabbitMQ version
# Place in /usr/lib/rabbitmq/plugins/
rabbitmq-plugins enable rabbitmq_delayed_message_exchange
```

### Setup

```python
# Declare delayed exchange — wraps another exchange type
channel.exchange_declare(
    exchange='delayed',
    exchange_type='x-delayed-message',
    durable=True,
    arguments={'x-delayed-type': 'direct'}  # underlying routing type
)

channel.queue_declare(queue='scheduled-tasks', durable=True,
    arguments={'x-queue-type': 'quorum'})
channel.queue_bind(exchange='delayed', queue='scheduled-tasks',
    routing_key='task.scheduled')
```

### Publishing with Delay

```python
# Delay in milliseconds via x-delay header
channel.basic_publish(
    exchange='delayed',
    routing_key='task.scheduled',
    body=json.dumps({'task': 'send_reminder', 'user_id': 123}),
    properties=pika.BasicProperties(
        headers={'x-delay': 300000},  # 5-minute delay
        delivery_mode=2
    )
)
```

### Retry with Exponential Backoff

```python
def retry_with_backoff(channel, message, attempt, max_attempts=5):
    if attempt >= max_attempts:
        # Route to DLQ
        channel.basic_publish(exchange='dlx', routing_key='failed',
            body=message)
        return

    delay_ms = min(1000 * (2 ** attempt), 60000)  # max 60s
    channel.basic_publish(
        exchange='delayed',
        routing_key='task.retry',
        body=message,
        properties=pika.BasicProperties(
            headers={'x-delay': delay_ms, 'x-retry-attempt': attempt + 1},
            delivery_mode=2
        )
    )
```

### Alternative: TTL Queue Chain

If you cannot use the plugin, chain TTL queues for fixed delays:

```python
# Retry queue with TTL that DLXs back to the work exchange
channel.queue_declare(queue='retry-30s', durable=True, arguments={
    'x-message-ttl': 30000,
    'x-dead-letter-exchange': 'work-exchange',
    'x-dead-letter-routing-key': 'task.retry',
    'x-queue-type': 'quorum'
})
```

### Limitations

- Delayed messages are stored in Mnesia (node-local) — not replicated across cluster in older versions
- Maximum delay is ~49 days (2^32 ms)
- High volumes of delayed messages increase memory and disk usage on the node
- Plugin must be installed on every node in the cluster

---

## Message Deduplication

### Overview

RabbitMQ does not provide built-in exactly-once delivery. Duplicate messages can occur due to publisher retries, network issues, or consumer redelivery. Deduplication must be implemented at the application level.

### Strategy 1: Idempotency Keys in Consumer

```python
import redis

r = redis.Redis()

def deduplicated_handler(ch, method, properties, body):
    msg_id = properties.message_id
    if not msg_id:
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
        return

    # Atomic check-and-set with TTL
    if not r.set(f'dedup:{msg_id}', '1', nx=True, ex=86400):
        # Already processed — ack and discard
        ch.basic_ack(delivery_tag=method.delivery_tag)
        return

    try:
        process(body)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception:
        r.delete(f'dedup:{msg_id}')  # allow retry
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
```

### Strategy 2: Database Unique Constraint

```python
def deduplicated_handler(ch, method, properties, body):
    msg = json.loads(body)
    try:
        with db.transaction():
            # Unique constraint on message_id prevents duplicates
            db.execute(
                "INSERT INTO processed_messages (message_id, processed_at) VALUES (%s, NOW())",
                [properties.message_id]
            )
            process(msg)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except UniqueViolation:
        ch.basic_ack(delivery_tag=method.delivery_tag)  # already processed
    except Exception:
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
```

### Strategy 3: RabbitMQ Deduplication Plugin

The community `rabbitmq-message-deduplication` plugin provides exchange-level and queue-level deduplication:

```python
# Declare deduplication exchange
channel.exchange_declare(
    exchange='dedup-exchange',
    exchange_type='x-message-deduplication',
    durable=True,
    arguments={
        'x-cache-size': 1000000,
        'x-cache-ttl': 60000,  # 60s dedup window
        'x-cache-persistence': 'disk'
    }
)

# Publish with deduplication header
channel.basic_publish(
    exchange='dedup-exchange',
    routing_key='orders',
    body=json.dumps(order),
    properties=pika.BasicProperties(
        headers={'x-deduplication-header': order_id}
    )
)
```

### Publisher-Side Deduplication

Always set `message_id` on published messages:

```python
channel.basic_publish(
    exchange='orders',
    routing_key='new',
    body=json.dumps(order),
    properties=pika.BasicProperties(
        message_id=f'{order_id}-{uuid.uuid4()}',
        delivery_mode=2
    )
)
```

---

## Exactly-Once Processing Strategies

True exactly-once is impossible in distributed systems. Instead, aim for **effectively-once** via idempotent consumers.

### Pattern: Transactional Outbox

1. Write the business event and outbox record in a single database transaction
2. A separate process reads the outbox and publishes to RabbitMQ
3. Consumer processes idempotently using the event's unique ID

```python
# Producer side — single transaction
with db.transaction():
    db.execute("INSERT INTO orders (...) VALUES (...)")
    db.execute("""INSERT INTO outbox (id, exchange, routing_key, payload, published)
                  VALUES (%s, 'orders', 'order.created', %s, FALSE)""",
               [event_id, json.dumps(order)])

# Outbox publisher (separate process)
def publish_outbox():
    rows = db.query("SELECT * FROM outbox WHERE published = FALSE ORDER BY id LIMIT 100")
    for row in rows:
        channel.basic_publish(exchange=row.exchange, routing_key=row.routing_key,
            body=row.payload,
            properties=pika.BasicProperties(message_id=row.id, delivery_mode=2))
        db.execute("UPDATE outbox SET published = TRUE WHERE id = %s", [row.id])
```

### Pattern: Claim Check

For large messages, store the payload externally and send only a reference:

```python
# Publisher
blob_id = s3.put_object(Bucket='messages', Key=msg_id, Body=large_payload)
channel.basic_publish(exchange='data', routing_key='large',
    body=json.dumps({'claim_check': msg_id, 'bucket': 'messages'}),
    properties=pika.BasicProperties(delivery_mode=2))

# Consumer
msg = json.loads(body)
payload = s3.get_object(Bucket=msg['bucket'], Key=msg['claim_check'])
```

### Pattern: Idempotent Consumer with Version Tracking

```python
def handle_order_update(ch, method, properties, body):
    event = json.loads(body)
    result = db.execute(
        """UPDATE orders SET status = %s, version = %s
           WHERE id = %s AND version < %s""",
        [event['status'], event['version'], event['order_id'], event['version']]
    )
    if result.rowcount == 0:
        pass  # stale or duplicate — safe to ignore
    ch.basic_ack(delivery_tag=method.delivery_tag)
```

---

## Consumer Concurrency Tuning

### Single-Threaded Consumers (Python/pika)

pika's `BlockingConnection` is single-threaded. Scale by running multiple processes:

```bash
# Run N consumer processes
for i in $(seq 1 $NUM_WORKERS); do
    python consumer.py &
done
```

### Multi-Threaded Consumers (Java)

```java
// Java client — configure concurrent consumers
channel.basicQos(25);  // prefetch per consumer
ExecutorService executor = Executors.newFixedThreadPool(10);
for (int i = 0; i < 10; i++) {
    Channel ch = conn.createChannel();
    ch.basicQos(25);
    ch.basicConsume("tasks", false, new WorkerConsumer(ch));
}
```

### Spring AMQP Concurrency

```yaml
spring:
  rabbitmq:
    listener:
      simple:
        concurrency: 5        # minimum consumers
        max-concurrency: 20   # scale up under load
        prefetch: 25
        acknowledge-mode: manual
```

### Node.js Concurrency

```javascript
// amqplib — single channel, single consumer, use prefetch to batch
const ch = await conn.createChannel();
await ch.prefetch(50);
ch.consume('tasks', async (msg) => {
    await processAsync(msg);
    ch.ack(msg);
});
// Scale with cluster module or multiple processes
```

### Guidelines

| Workload Type | Recommended Approach |
|---|---|
| CPU-bound processing | Multiple processes, prefetch 1–5 |
| I/O-bound (DB, API calls) | Async consumers, prefetch 20–50 |
| Mixed workloads | Thread pool with moderate prefetch 10–25 |
| Very fast processing | Single consumer, high prefetch 50–100 |

---

## Prefetch Optimization

### How Prefetch Works

`basic.qos(prefetch_count=N)` limits unacknowledged messages per consumer. The broker stops sending messages to a consumer until it acks some of the N outstanding messages.

### Tuning Guidelines

```
prefetch = (average_processing_time × target_throughput) + buffer
```

| Scenario | Prefetch | Rationale |
|---|---|---|
| Fast tasks (<1ms) | 100–500 | Keep consumer busy, reduce round-trips |
| Moderate tasks (1–100ms) | 10–50 | Balance throughput and fairness |
| Slow tasks (100ms–1s) | 1–5 | Prevent one consumer hoarding work |
| Variable-duration tasks | 1 | Fair dispatch (strict round-robin) |
| Batch processing | Match batch size | Ack entire batch at once |

### Global vs Per-Consumer Prefetch

```python
# Per-consumer (default in most clients) — recommended
channel.basic_qos(prefetch_count=25, global_qos=False)

# Global — shared across all consumers on the channel
channel.basic_qos(prefetch_count=100, global_qos=True)
```

### Monitoring Prefetch Effectiveness

Watch these metrics:
- `messages_unacked`: should stay near prefetch × consumer_count
- Consumer utilization in management UI: should be near 100%
- Queue depth trend: should be stable or decreasing
- If `messages_ready` grows while `messages_unacked` is at limit → add consumers

---

## Shovel and Federation

### Shovel

Shovels move messages between brokers (same or different clusters). Use for cross-datacenter replication or migration.

```bash
# Dynamic shovel via management API
curl -u admin:secret -X PUT \
  http://localhost:15672/api/parameters/shovel/%2F/my-shovel \
  -H 'Content-Type: application/json' \
  -d '{
    "value": {
      "src-protocol": "amqp091",
      "src-uri": "amqp://source-broker",
      "src-queue": "source-queue",
      "dest-protocol": "amqp091",
      "dest-uri": "amqp://dest-broker",
      "dest-exchange": "dest-exchange",
      "dest-exchange-key": "migrated",
      "ack-mode": "on-confirm",
      "reconnect-delay": 5
    }
  }'
```

### Federation

Federation replicates exchanges or queues across brokers. Upstream messages are transparently forwarded to downstream consumers.

```bash
# Enable federation plugin
rabbitmq-plugins enable rabbitmq_federation rabbitmq_federation_management

# Define upstream
curl -u admin:secret -X PUT \
  http://localhost:15672/api/parameters/federation-upstream/%2F/dc-west \
  -H 'Content-Type: application/json' \
  -d '{
    "value": {
      "uri": "amqp://admin:secret@west-broker",
      "ack-mode": "on-confirm",
      "trust-user-id": false
    }
  }'

# Apply federation policy to exchanges matching pattern
curl -u admin:secret -X PUT \
  http://localhost:15672/api/policies/%2F/federate-events \
  -H 'Content-Type: application/json' \
  -d '{
    "pattern": "^events\\.",
    "definition": {"federation-upstream-set": "all"},
    "apply-to": "exchanges"
  }'
```

### Shovel vs Federation

| Feature | Shovel | Federation |
|---|---|---|
| Direction | Explicit point-to-point | Automatic upstream → downstream |
| Topology | Manual source/dest config | Policy-based, pattern matching |
| Use case | Migration, DR failover | Multi-site, geo-distributed apps |
| Message flow | Moves messages (consumed from source) | Copies messages (upstream retains) |
| Complexity | Simple, single link | More setup, but more flexible |

---

## Lazy Queues vs Quorum Queues Decision Matrix

### Lazy Queues (Classic v2)

Lazy queues write messages to disk as early as possible, minimizing RAM usage. In RabbitMQ 3.12+, classic queues v2 (CQv2) are always lazy — the `x-queue-mode: lazy` argument is a no-op.

### Decision Matrix

| Criteria | Quorum Queue | Classic Queue (CQv2 / Lazy) |
|---|---|---|
| **Data safety** | ✅ Raft replication across nodes | ❌ Single-node, no replication |
| **High availability** | ✅ Survives node failures | ❌ Queue unavailable if node down |
| **Memory efficiency** | Moderate (in-memory index) | ✅ Minimal RAM, disk-first |
| **Throughput** | Good (optimized in 4.0) | Higher for non-replicated workloads |
| **Message ordering** | ✅ Strict FIFO | ✅ Strict FIFO |
| **Priority support** | 2 levels (4.0) | Up to 255 levels |
| **Poison message handling** | ✅ Built-in delivery limit | ❌ Manual via DLX |
| **Non-durable messages** | ❌ Not supported | ✅ Supported |
| **Single Active Consumer** | ✅ Supported | ✅ Supported |
| **Cluster requirement** | 3+ nodes recommended | Single node OK |
| **Use when** | Production, critical data | Dev/test, transient data, high-prio |

### Streams vs Queues

| Criteria | Stream | Quorum Queue | Classic Queue |
|---|---|---|---|
| Consumer model | Non-destructive read | Destructive (consume & ack) | Destructive |
| Replay | ✅ From any offset | ❌ | ❌ |
| Fan-out | ✅ Efficient (single copy) | ❌ Copy per consumer | ❌ Copy per consumer |
| Throughput | Very high (append-only) | Good | Higher for transient |
| Ordering | ✅ Append-only log | ✅ FIFO | ✅ FIFO |
| Use when | Audit log, replay, many consumers | Work queue, task distribution | Ephemeral, dev/test |

---

## RabbitMQ Streams for Log-Style Workloads

### When to Use Streams

- Multiple consumers need to read the same data independently
- Consumers need to replay from a specific point in time or offset
- High-throughput append-only ingestion (100K+ msg/s)
- Time-based retention is preferred over consume-and-delete
- Audit logging, event sourcing read models, CDC fan-out

### Stream Architecture

Streams are a replicated, append-only log stored on disk. Consumers track their own offset — messages are never deleted by consumption.

### Advanced Stream Configuration

```python
channel.queue_declare(queue='audit-stream', durable=True, arguments={
    'x-queue-type': 'stream',
    'x-max-length-bytes': 50_000_000_000,  # 50GB retention
    'x-max-age': '30D',                     # 30-day retention
    'x-stream-max-segment-size-bytes': 500_000_000,  # 500MB segments
    'x-initial-cluster-size': 3              # replication factor
})
```

### Stream Consumers with Offset Tracking

```python
# Consume from specific offset
channel.basic_consume(queue='audit-stream', on_message_callback=handler,
    arguments={
        'x-stream-offset': 12345  # exact offset
    })

# Consume from timestamp
channel.basic_consume(queue='audit-stream', on_message_callback=handler,
    arguments={
        'x-stream-offset': datetime(2024, 1, 1, tzinfo=timezone.utc)
    })
```

### Native Stream Protocol (High Performance)

For maximum throughput, use the native stream protocol (port 5552) instead of AMQP:

```java
// Java stream client
Environment environment = Environment.builder()
    .host("localhost").port(5552)
    .username("admin").password("secret")
    .build();

Producer producer = environment.producerBuilder()
    .stream("audit-stream")
    .batchSize(100)
    .build();

Consumer consumer = environment.consumerBuilder()
    .stream("audit-stream")
    .offset(OffsetSpecification.first())
    .messageHandler((context, message) -> {
        process(message.getBodyAsBinary());
    })
    .build();
```

### Stream Filtering (3.13+)

Reduce consumer bandwidth by filtering at the broker:

```java
Producer producer = environment.producerBuilder()
    .stream("events")
    .filterValueExtractor(msg -> msg.getApplicationProperties().get("region").toString())
    .build();

Consumer consumer = environment.consumerBuilder()
    .stream("events")
    .filter()
        .values("us-east-1", "us-west-2")
        .postFilter(msg -> true)  // client-side secondary filter
    .builder()
    .messageHandler(handler)
    .build();
```

### Super Streams (Partitioned Streams)

Super streams partition a logical stream across multiple stream queues for horizontal scaling:

```bash
# Create super stream with 3 partitions via CLI
rabbitmq-streams add_super_stream invoices --partitions 3

# Or with explicit routing keys
rabbitmq-streams add_super_stream invoices \
  --routing-keys us,eu,apac
```

```java
Producer producer = environment.producerBuilder()
    .superStream("invoices")
    .routing(msg -> msg.getProperties().getMessageIdAsString())  // hash-based routing
    .producerBuilder()
    .build();
```

### Performance Considerations

- Streams achieve highest throughput with the native protocol (5552) and batched publishing
- AMQP-based stream consumption is convenient but slower than native protocol
- Use `x-stream-max-segment-size-bytes` to control segment file sizes for efficient GC
- Sub-entry batching groups multiple messages into a single log entry for throughput
- Monitor `rabbitmq_stream_segments` and disk usage — streams retain data by time/size policy
