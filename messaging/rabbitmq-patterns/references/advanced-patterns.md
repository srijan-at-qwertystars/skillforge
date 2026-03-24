# Advanced RabbitMQ Patterns

## Table of Contents

- [Dead Letter Exchanges with Retry Chains](#dead-letter-exchanges-with-retry-chains)
- [Priority Queues](#priority-queues)
- [Delayed Message Exchange Plugin](#delayed-message-exchange-plugin)
- [Consistent Hash Exchange](#consistent-hash-exchange)
- [RPC over RabbitMQ](#rpc-over-rabbitmq)
- [Saga Pattern with RabbitMQ](#saga-pattern-with-rabbitmq)
- [Competing Consumers](#competing-consumers)
- [Message Deduplication](#message-deduplication)
- [Header-Based Routing](#header-based-routing)
- [Alternate Exchanges](#alternate-exchanges)
- [Sender Confirms with Batching](#sender-confirms-with-batching)

---

## Dead Letter Exchanges with Retry Chains

### Concept

Dead letter exchanges (DLX) receive messages that are rejected, expired, or overflow from a queue. By chaining multiple DLX-backed queues with escalating TTLs, you build exponential backoff retry logic entirely within RabbitMQ — no application-side delay logic required.

### How Messages Become Dead-Lettered

A message is dead-lettered when any of the following occurs:

1. **Consumer rejects/nacks** with `requeue=False`
2. **Per-message TTL expires** (`expiration` property)
3. **Queue-level TTL expires** (`x-message-ttl` argument)
4. **Queue length limit exceeded** (`x-max-length` or `x-max-length-bytes`) with `x-overflow: reject-publish-dlx` or default drop-head behavior
5. **Delivery limit reached** (quorum queues with `x-delivery-limit`)

### Exponential Backoff Retry Chain

Architecture: source queue → retry-1s → retry-5s → retry-30s → retry-300s → dead-letter (parking lot)

```python
import pika
import json
import math

def setup_retry_chain(channel, source_exchange, source_queue, routing_key):
    """Set up exponential backoff retry chain with 4 levels."""

    retry_levels = [
        ('retry.1s',   1000),    # 1 second
        ('retry.5s',   5000),    # 5 seconds
        ('retry.30s',  30000),   # 30 seconds
        ('retry.300s', 300000),  # 5 minutes
    ]

    # Final dead letter queue (parking lot for manual inspection)
    channel.exchange_declare(exchange='dlx.final', exchange_type='direct', durable=True)
    channel.queue_declare(queue='dead-letters.parking', durable=True, arguments={
        'x-queue-type': 'quorum'
    })
    channel.queue_bind(exchange='dlx.final', queue='dead-letters.parking',
                       routing_key=routing_key)

    # Build retry chain in reverse so each level DLXes to the source
    for level_name, ttl in retry_levels:
        retry_exchange = f'dlx.{level_name}'
        retry_queue = f'{source_queue}.{level_name}'

        channel.exchange_declare(exchange=retry_exchange, exchange_type='direct', durable=True)
        channel.queue_declare(queue=retry_queue, durable=True, arguments={
            'x-message-ttl': ttl,
            'x-dead-letter-exchange': source_exchange,
            'x-dead-letter-routing-key': routing_key,
            'x-queue-type': 'quorum'
        })
        channel.queue_bind(exchange=retry_exchange, queue=retry_queue,
                           routing_key=routing_key)

    # Source queue DLXes to first retry level
    channel.exchange_declare(exchange=source_exchange, exchange_type='direct', durable=True)
    channel.queue_declare(queue=source_queue, durable=True, arguments={
        'x-queue-type': 'quorum',
        'x-dead-letter-exchange': 'dlx.retry.1s',
        'x-dead-letter-routing-key': routing_key,
        'x-delivery-limit': 20
    })
    channel.queue_bind(exchange=source_exchange, queue=source_queue,
                       routing_key=routing_key)


def get_death_count(properties):
    """Extract total death count from x-death header."""
    if not properties.headers or 'x-death' not in properties.headers:
        return 0
    return sum(entry.get('count', 0) for entry in properties.headers['x-death'])


def on_message_with_retry(ch, method, properties, body):
    """Consumer that routes to appropriate retry level based on death count."""
    death_count = get_death_count(properties)
    max_retries = 15

    try:
        process_message(json.loads(body))
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except TransientError:
        if death_count >= max_retries:
            # Exhausted all retries — send to parking lot
            ch.basic_publish(
                exchange='dlx.final',
                routing_key=method.routing_key,
                body=body,
                properties=pika.BasicProperties(
                    delivery_mode=2,
                    headers={**(properties.headers or {}),
                             'x-final-rejection-reason': 'max-retries-exceeded',
                             'x-total-attempts': death_count + 1}
                )
            )
            ch.basic_ack(delivery_tag=method.delivery_tag)
        else:
            # Select retry level based on death count (exponential)
            retry_exchange = select_retry_level(death_count)
            ch.basic_publish(
                exchange=retry_exchange,
                routing_key=method.routing_key,
                body=body,
                properties=properties
            )
            ch.basic_ack(delivery_tag=method.delivery_tag)
    except PermanentError:
        # Non-retryable — straight to parking lot
        ch.basic_publish(exchange='dlx.final', routing_key=method.routing_key,
                         body=body, properties=properties)
        ch.basic_ack(delivery_tag=method.delivery_tag)


def select_retry_level(death_count):
    """Exponential backoff: escalate retry level based on failure count."""
    if death_count < 3:
        return 'dlx.retry.1s'
    elif death_count < 6:
        return 'dlx.retry.5s'
    elif death_count < 10:
        return 'dlx.retry.30s'
    else:
        return 'dlx.retry.300s'
```

### x-death Header Structure

RabbitMQ automatically appends `x-death` headers on dead-lettering. The header is a list of tables:

```json
[
  {
    "count": 3,
    "reason": "rejected",
    "queue": "order.processing",
    "time": 1700000000,
    "exchange": "orders",
    "routing-keys": ["order.created"]
  }
]
```

Fields: `count` (cumulative per queue+reason), `reason` (`rejected`, `expired`, `maxlen`, `delivery_limit`), `queue`, `time`, `exchange`, `routing-keys`, `original-expiration` (if TTL-expired).

---

## Priority Queues

### Setup

Classic queues support message priority (quorum queues do not). Declare the queue with `x-max-priority` to enable.

```python
# Priority range 0-10 (keep small — each level uses separate internal queue)
channel.queue_declare(queue='tasks.prioritized', durable=True, arguments={
    'x-max-priority': 10
})

# Publish with priority
channel.basic_publish(
    exchange='',
    routing_key='tasks.prioritized',
    body=json.dumps(task),
    properties=pika.BasicProperties(
        delivery_mode=2,
        priority=7  # Higher = delivered first
    )
)
```

### Priority Best Practices

- **Keep max-priority small** (5-10). Each priority level creates an internal sub-queue. High values waste memory.
- **Priority only works when messages accumulate.** If consumers keep up, priority has no effect (messages are delivered immediately).
- **Unset priority defaults to 0** (lowest). Explicitly set priority on every message.
- **Not available on quorum queues.** Use classic queues for priority workloads.
- **Consumer prefetch interacts with priority.** Lower prefetch gives the broker more opportunities to reorder by priority.

### Priority with Competing Consumers

```python
# Low prefetch ensures broker can prioritize effectively
channel.basic_qos(prefetch_count=1)

def on_priority_message(ch, method, properties, body):
    task = json.loads(body)
    print(f"Processing priority={properties.priority} task={task['id']}")
    process(task)
    ch.basic_ack(delivery_tag=method.delivery_tag)

channel.basic_consume(queue='tasks.prioritized',
                      on_message_callback=on_priority_message)
```

---

## Delayed Message Exchange Plugin

### Overview

The `rabbitmq_delayed_message_exchange` plugin adds native support for delayed message delivery without TTL/DLX workarounds. Messages are stored in a Mnesia table on the node and published to the target exchange after the delay expires.

### Installation

```bash
# Download the plugin matching your RabbitMQ version
rabbitmq-plugins enable rabbitmq_delayed_message_exchange
```

### Usage

```python
# Declare a delayed exchange (wraps another exchange type)
channel.exchange_declare(
    exchange='delayed.tasks',
    exchange_type='x-delayed-message',
    durable=True,
    arguments={'x-delayed-type': 'direct'}  # Underlying exchange type
)

channel.queue_declare(queue='scheduled.tasks', durable=True)
channel.queue_bind(exchange='delayed.tasks', queue='scheduled.tasks',
                   routing_key='execute')

# Publish with delay in milliseconds
channel.basic_publish(
    exchange='delayed.tasks',
    routing_key='execute',
    body=json.dumps({'task': 'send_reminder', 'user_id': 42}),
    properties=pika.BasicProperties(
        delivery_mode=2,
        headers={'x-delay': 60000}  # Deliver after 60 seconds
    )
)
```

### Limitations and Caveats

- **Not replicated.** Delayed messages are stored per-node in Mnesia. Node failure loses pending delayed messages.
- **Performance at scale.** Millions of delayed messages degrade performance. Use an external scheduler (e.g., cron + publish) for very large volumes.
- **Max delay.** The maximum delay is 2^32 - 1 milliseconds (~49.7 days).
- **Cluster behavior.** The delay timer runs on the node where the message was published. If that node goes down before the delay expires, the message is lost.
- **Monitoring.** Delayed messages don't appear in queue metrics until delivered. Use the management UI plugin tab to see pending delayed messages.

### Alternative: TTL/DLX Delay (No Plugin)

If you can't install the plugin, use TTL queues as delay buffers:

```python
# Delay queue — messages sit here for the TTL then route to the target
channel.queue_declare(queue='delay.60s', durable=True, arguments={
    'x-message-ttl': 60000,
    'x-dead-letter-exchange': 'tasks',
    'x-dead-letter-routing-key': 'execute'
})

# Publish to the delay queue
channel.basic_publish(exchange='', routing_key='delay.60s',
                      body=json.dumps(task),
                      properties=pika.BasicProperties(delivery_mode=2))
```

Drawback: you need a separate queue per distinct delay duration.

---

## Consistent Hash Exchange

### Overview

The `rabbitmq_consistent_hash_exchange` plugin distributes messages across queues based on a hash of the routing key (or a message header/property). This provides sticky partitioning — messages with the same key always route to the same queue — enabling ordered processing per partition.

### Setup

```bash
rabbitmq-plugins enable rabbitmq_consistent_hash_exchange
```

```python
# Declare consistent hash exchange
channel.exchange_declare(
    exchange='events.partitioned',
    exchange_type='x-consistent-hash',
    durable=True
)

# Bind queues with weight (routing key = weight as string)
for i in range(4):
    queue_name = f'events.partition.{i}'
    channel.queue_declare(queue=queue_name, durable=True, arguments={
        'x-queue-type': 'quorum'
    })
    # Weight "10" — equal distribution across 4 queues
    channel.queue_bind(exchange='events.partitioned', queue=queue_name,
                       routing_key='10')

# Publish — routing key is used as hash input
channel.basic_publish(
    exchange='events.partitioned',
    routing_key='user-12345',  # Messages for same user → same partition
    body=json.dumps(event)
)
```

### Hash on Header Instead of Routing Key

```python
channel.exchange_declare(
    exchange='events.header-hash',
    exchange_type='x-consistent-hash',
    durable=True,
    arguments={'hash-header': 'tenant-id'}  # Hash on header value
)

channel.basic_publish(
    exchange='events.header-hash',
    routing_key='ignored',  # Routing key ignored when hash-header is set
    body=json.dumps(event),
    properties=pika.BasicProperties(
        headers={'tenant-id': 'tenant-42'}
    )
)
```

### Use Cases

- **Per-user ordering**: Hash on user ID ensures all events for a user go to the same consumer.
- **Per-tenant isolation**: Hash on tenant ID for multi-tenant workloads.
- **Sharded processing**: Distribute work across N consumers with affinity.

### Rebalancing

Adding/removing queues triggers consistent hash ring rebalancing. Only a fraction of keys are remapped (unlike modulo hashing). Expect brief reordering during rebalance.

---

## RPC over RabbitMQ

### Request-Reply Pattern

Use a dedicated reply queue per client, `correlation_id` for matching, and `reply_to` for the callback queue.

```python
# === RPC Client ===
import uuid

class RpcClient:
    def __init__(self, channel, exchange='rpc', routing_key='rpc.server'):
        self.channel = channel
        self.exchange = exchange
        self.routing_key = routing_key
        self.pending = {}

        # Exclusive auto-delete reply queue
        result = channel.queue_declare(queue='', exclusive=True)
        self.reply_queue = result.method.queue
        channel.basic_consume(queue=self.reply_queue,
                              on_message_callback=self._on_reply, auto_ack=True)

    def call(self, request, timeout=30):
        corr_id = str(uuid.uuid4())
        future = {'result': None, 'event': threading.Event()}
        self.pending[corr_id] = future

        self.channel.basic_publish(
            exchange=self.exchange,
            routing_key=self.routing_key,
            body=json.dumps(request),
            properties=pika.BasicProperties(
                reply_to=self.reply_queue,
                correlation_id=corr_id,
                expiration=str(timeout * 1000),
                content_type='application/json'
            )
        )

        if not future['event'].wait(timeout):
            del self.pending[corr_id]
            raise TimeoutError(f'RPC call timed out after {timeout}s')

        return future['result']

    def _on_reply(self, ch, method, properties, body):
        corr_id = properties.correlation_id
        if corr_id in self.pending:
            self.pending[corr_id]['result'] = json.loads(body)
            self.pending[corr_id]['event'].set()


# === RPC Server ===
def rpc_server(channel):
    channel.queue_declare(queue='rpc.requests', durable=True)
    channel.basic_qos(prefetch_count=10)

    def on_request(ch, method, properties, body):
        request = json.loads(body)
        try:
            result = process_request(request)
            response = {'status': 'ok', 'result': result}
        except Exception as e:
            response = {'status': 'error', 'message': str(e)}

        ch.basic_publish(
            exchange='',
            routing_key=properties.reply_to,
            body=json.dumps(response),
            properties=pika.BasicProperties(
                correlation_id=properties.correlation_id,
                content_type='application/json'
            )
        )
        ch.basic_ack(delivery_tag=method.delivery_tag)

    channel.basic_consume(queue='rpc.requests', on_message_callback=on_request)
    channel.start_consuming()
```

### RPC Best Practices

- **Always set expiration** on RPC requests. Orphaned requests accumulate in the server queue.
- **Use exclusive reply queues** (auto-delete) to avoid queue leaks when clients disconnect.
- **Consider Direct Reply-to** (`reply_to='amq.rabbitmq.reply-to'`) for lower overhead — no queue declaration needed. The reply is delivered directly to the waiting consumer.
- **Don't use RPC for fire-and-forget.** Use one-way messaging instead.
- **Handle server unavailability.** Implement client-side timeouts and circuit breakers.

### Direct Reply-to (Pseudo-Queue)

```python
# Client uses the special pseudo-queue — no queue declaration needed
channel.basic_publish(
    exchange='',
    routing_key='rpc.requests',
    body=json.dumps(request),
    properties=pika.BasicProperties(
        reply_to='amq.rabbitmq.reply-to',
        correlation_id=str(uuid.uuid4())
    )
)
```

---

## Saga Pattern with RabbitMQ

### Overview

The saga pattern coordinates distributed transactions across microservices using a sequence of local transactions with compensating actions. RabbitMQ serves as the message bus carrying saga commands and events.

### Choreography-Based Saga

Each service listens for events and publishes the next event or a compensation event on failure. No central coordinator.

```
OrderService → order.created → PaymentService → payment.charged → InventoryService
                                    ↓ (failure)
                              payment.failed → OrderService (compensate: cancel order)
```

```python
# Payment service — choreography participant
def handle_order_created(ch, method, properties, body):
    order = json.loads(body)
    try:
        charge_result = charge_payment(order['user_id'], order['total'])
        ch.basic_publish(
            exchange='saga.events',
            routing_key='payment.charged',
            body=json.dumps({
                'saga_id': order['saga_id'],
                'order_id': order['id'],
                'payment_id': charge_result['id']
            }),
            properties=pika.BasicProperties(delivery_mode=2)
        )
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except PaymentError as e:
        ch.basic_publish(
            exchange='saga.events',
            routing_key='payment.failed',
            body=json.dumps({
                'saga_id': order['saga_id'],
                'order_id': order['id'],
                'reason': str(e)
            }),
            properties=pika.BasicProperties(delivery_mode=2)
        )
        ch.basic_ack(delivery_tag=method.delivery_tag)
```

### Orchestration-Based Saga

A central saga orchestrator sends commands and tracks state. More complex but easier to reason about.

```python
class SagaOrchestrator:
    """Saga orchestrator that manages step execution and compensation."""

    def __init__(self, channel, saga_id):
        self.channel = channel
        self.saga_id = saga_id
        self.steps = []
        self.completed_steps = []

    def add_step(self, command_exchange, command_key, compensate_exchange, compensate_key):
        self.steps.append({
            'command': (command_exchange, command_key),
            'compensate': (compensate_exchange, compensate_key)
        })

    def execute(self, context):
        for i, step in enumerate(self.steps):
            exchange, key = step['command']
            self.channel.basic_publish(
                exchange=exchange,
                routing_key=key,
                body=json.dumps({
                    'saga_id': self.saga_id,
                    'step': i,
                    'context': context
                }),
                properties=pika.BasicProperties(
                    delivery_mode=2,
                    reply_to='saga.replies',
                    correlation_id=f'{self.saga_id}:{i}'
                )
            )
            self.completed_steps.append(step)

    def compensate(self, failed_step, context):
        """Compensate all completed steps in reverse order."""
        for step in reversed(self.completed_steps[:failed_step]):
            exchange, key = step['compensate']
            self.channel.basic_publish(
                exchange=exchange,
                routing_key=key,
                body=json.dumps({
                    'saga_id': self.saga_id,
                    'context': context
                }),
                properties=pika.BasicProperties(delivery_mode=2)
            )
```

### Saga Considerations

- **Idempotency is critical.** Every saga step and compensation must be idempotent since messages may be delivered more than once.
- **Timeout handling.** Use per-message TTL on saga commands. If a step times out, trigger compensation.
- **State persistence.** The orchestrator should persist saga state (e.g., in a database) to survive restarts.
- **Poison messages.** Use DLQ for saga messages that fail repeatedly. Alert operators for manual intervention.

---

## Competing Consumers

### Pattern

Multiple consumers share a single queue for horizontal scaling. RabbitMQ distributes messages round-robin. Use prefetch to control work distribution.

```python
# Worker process (run N instances)
channel.basic_qos(prefetch_count=5)

def worker(ch, method, properties, body):
    task = json.loads(body)
    result = process_task(task)
    ch.basic_ack(delivery_tag=method.delivery_tag)

channel.basic_consume(queue='tasks', on_message_callback=worker)
channel.start_consuming()
```

### Fair Dispatch vs Round-Robin

By default, RabbitMQ dispatches round-robin regardless of consumer busyness. This leads to uneven load when tasks take variable time.

**Fair dispatch**: Set `prefetch_count` to limit unacknowledged messages per consumer. A busy consumer won't receive new messages until it acks, so messages flow to idle consumers.

```python
# Fair dispatch — each consumer gets at most 1 unacked message
channel.basic_qos(prefetch_count=1)
```

### Single Active Consumer

For ordered processing with failover, use single-active-consumer on quorum queues:

```python
channel.queue_declare(queue='ordered.tasks', durable=True, arguments={
    'x-queue-type': 'quorum',
    'x-single-active-consumer': True
})
# Multiple consumers can subscribe, but only one receives messages.
# If the active consumer disconnects, the next one takes over.
```

### Consumer Scaling Guidelines

| Queue Depth Trend | Action |
|-------------------|--------|
| Steady near zero  | Right-sized — no change needed |
| Growing slowly    | Add 1-2 consumers |
| Growing fast      | Add consumers + investigate processing bottlenecks |
| Always zero       | Over-provisioned — reduce consumers to save resources |

---

## Message Deduplication

### Problem

Network issues, publisher retries, and consumer redeliveries can produce duplicate messages. RabbitMQ does not deduplicate natively.

### Application-Level Deduplication

```python
import redis

redis_client = redis.Redis()
DEDUP_TTL = 86400  # 24 hours

def on_message_dedup(ch, method, properties, body):
    msg_id = properties.message_id
    if not msg_id:
        ch.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
        return

    # Check and set atomically
    dedup_key = f'dedup:{msg_id}'
    if not redis_client.set(dedup_key, '1', nx=True, ex=DEDUP_TTL):
        # Duplicate — ack and discard
        ch.basic_ack(delivery_tag=method.delivery_tag)
        return

    try:
        process(json.loads(body))
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception:
        redis_client.delete(dedup_key)  # Allow retry
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
```

### Deduplication Plugin

The `rabbitmq-message-deduplication` community plugin adds broker-level deduplication:

```python
# Declare exchange with deduplication
channel.exchange_declare(
    exchange='dedup.exchange',
    exchange_type='x-message-deduplication',
    durable=True,
    arguments={
        'x-cache-size': 1000000,    # Max entries in dedup cache
        'x-cache-ttl': 60000,       # TTL for cache entries (ms)
        'x-cache-persistence': 'disk'
    }
)

# Publish with dedup header
channel.basic_publish(
    exchange='dedup.exchange',
    routing_key='tasks',
    body=json.dumps(task),
    properties=pika.BasicProperties(
        headers={'x-deduplication-header': f'task-{task["id"]}'}
    )
)
```

### Idempotent Consumer Pattern

The most robust approach — make processing idempotent regardless of duplicates:

```python
def idempotent_process_order(order):
    """Process order idempotently using database constraints."""
    try:
        db.execute("""
            INSERT INTO processed_orders (order_id, status, processed_at)
            VALUES (%s, 'processed', NOW())
            ON CONFLICT (order_id) DO NOTHING
        """, (order['id'],))

        if db.rowcount == 0:
            return  # Already processed — idempotent no-op

        fulfill_order(order)
    except Exception:
        db.rollback()
        raise
```

---

## Header-Based Routing

### Headers Exchange

Route messages based on header key-value pairs instead of routing keys. Supports `x-match: all` (all headers must match) or `x-match: any` (any header matches).

```python
channel.exchange_declare(exchange='events.headers', exchange_type='headers', durable=True)

# Bind with header matching
channel.queue_declare(queue='us.critical.events', durable=True)
channel.queue_bind(
    exchange='events.headers',
    queue='us.critical.events',
    routing_key='',  # Ignored for headers exchange
    arguments={
        'x-match': 'all',
        'region': 'us',
        'severity': 'critical'
    }
)

# Bind with any-match
channel.queue_declare(queue='alert.events', durable=True)
channel.queue_bind(
    exchange='events.headers',
    queue='alert.events',
    routing_key='',
    arguments={
        'x-match': 'any',
        'severity': 'critical',
        'alert': 'true'
    }
)

# Publish with headers
channel.basic_publish(
    exchange='events.headers',
    routing_key='',
    body=json.dumps(event),
    properties=pika.BasicProperties(
        headers={
            'region': 'us',
            'severity': 'critical',
            'service': 'payment'
        }
    )
)
```

### When to Use Headers vs Topic

| Criteria | Headers Exchange | Topic Exchange |
|----------|-----------------|----------------|
| Routing dimensions | Multi-dimensional (multiple independent attributes) | Single-dimensional (dot-separated hierarchy) |
| Flexibility | Arbitrary key-value pairs | Fixed routing key structure |
| Performance | Slower (header inspection) | Faster (string matching) |
| Typical use | Complex filtering (region + severity + type) | Hierarchical events (`order.created.us`) |

### Headers with Enumerated Values

```python
# Route to different queues based on content type and priority
bindings = [
    ('queue.pdf.high',   {'x-match': 'all', 'content-type': 'pdf', 'priority': 'high'}),
    ('queue.pdf.low',    {'x-match': 'all', 'content-type': 'pdf', 'priority': 'low'}),
    ('queue.image.any',  {'x-match': 'all', 'content-type': 'image'}),
]

for queue_name, headers in bindings:
    channel.queue_declare(queue=queue_name, durable=True)
    channel.queue_bind(exchange='events.headers', queue=queue_name,
                       routing_key='', arguments=headers)
```

---

## Alternate Exchanges

### Concept

An alternate exchange (AE) captures messages that are unroutable from the primary exchange (no matching bindings). This prevents silent message loss.

```python
# Step 1: Declare the alternate exchange and its capture queue
channel.exchange_declare(exchange='unrouted', exchange_type='fanout', durable=True)
channel.queue_declare(queue='unrouted.messages', durable=True, arguments={
    'x-queue-type': 'quorum'
})
channel.queue_bind(exchange='unrouted', queue='unrouted.messages')

# Step 2: Declare the primary exchange with alternate-exchange argument
channel.exchange_declare(
    exchange='orders',
    exchange_type='topic',
    durable=True,
    arguments={'alternate-exchange': 'unrouted'}
)
```

### Alternate Exchange vs Mandatory Flag

| Feature | Alternate Exchange | Mandatory Flag |
|---------|-------------------|----------------|
| Handling | Broker routes to AE automatically | Broker returns `basic.return` to publisher |
| Publisher awareness | Publisher unaware | Publisher must handle returns |
| Message persistence | Messages stored in AE queue | Publisher must re-publish |
| Cluster-safe | Yes | Yes |

Use alternate exchanges for operational safety (catch unroutable messages for debugging). Use mandatory flag when the publisher needs to know about routing failures.

### Chaining Alternate Exchanges

You can chain multiple levels — each exchange can have its own alternate exchange. The chain terminates when a message finds a matching binding or the last AE has no bindings (message is dropped).

---

## Sender Confirms with Batching

### Individual Confirms (Simple, Slow)

```python
channel.confirm_delivery()

for msg in messages:
    channel.basic_publish(
        exchange='events', routing_key='event.created',
        body=json.dumps(msg),
        properties=pika.BasicProperties(delivery_mode=2)
    )
# Each publish waits for confirm — high latency
```

### Batch Confirms (Balanced)

Publish a batch, then wait for all confirms at once. Better throughput than individual confirms.

```python
channel.confirm_delivery()

batch_size = 100
for i, msg in enumerate(messages):
    channel.basic_publish(
        exchange='events', routing_key='event.created',
        body=json.dumps(msg),
        properties=pika.BasicProperties(delivery_mode=2)
    )

    if (i + 1) % batch_size == 0:
        channel.get_waiting_message_count()  # Process pending confirms
        # With pika, confirms are handled synchronously per-publish
        # For true batching, use async confirms
```

### Async Confirms (Maximum Throughput)

```javascript
// Node.js amqplib — async publisher confirms
const amqplib = require('amqplib');

async function publishWithAsyncConfirms(messages) {
  const conn = await amqplib.connect('amqp://localhost');
  const ch = await conn.createConfirmChannel();

  const pending = new Map();
  let deliveryTag = 0;

  // Track confirms and nacks
  ch.on('ack', (tag, multiple) => {
    if (multiple) {
      for (const [key] of pending) {
        if (key <= tag) pending.delete(key);
      }
    } else {
      pending.delete(tag);
    }
  });

  ch.on('nack', (tag, multiple) => {
    // Re-publish nacked messages
    const nacked = [];
    if (multiple) {
      for (const [key, msg] of pending) {
        if (key <= tag) { nacked.push(msg); pending.delete(key); }
      }
    } else {
      nacked.push(pending.get(tag));
      pending.delete(tag);
    }
    nacked.forEach(msg => republish(ch, msg));
  });

  // Fire-and-forget publishes (confirms arrive asynchronously)
  for (const msg of messages) {
    deliveryTag++;
    pending.set(deliveryTag, msg);
    ch.publish('events', 'event.created', Buffer.from(JSON.stringify(msg)),
               { persistent: true });
  }

  // Wait for all confirms
  await ch.waitForConfirms();
}
```

### Confirm Performance Comparison

| Strategy | Throughput | Latency | Complexity |
|----------|-----------|---------|------------|
| Individual sync | ~500 msg/s | High | Low |
| Batch sync (100) | ~5,000 msg/s | Medium | Medium |
| Async confirms | ~50,000 msg/s | Low | High |
| No confirms (fire-and-forget) | ~100,000 msg/s | Lowest | Lowest |

Choose based on your reliability requirements. Financial transactions warrant individual confirms. Log events may tolerate fire-and-forget.
