---
name: message-queue-patterns
description:
  positive: "Use when user works with message queues, asks about RabbitMQ, AWS SQS/SNS, NATS, BullMQ, exchanges, dead letter queues, message acknowledgment, or queue-based async processing."
  negative: "Do NOT use for Kafka event streaming (use kafka-event-streaming skill), WebSocket real-time messaging (use websocket-patterns skill), or gRPC."
---

# Message Queue Patterns

## Fundamentals

**Point-to-point**: One producer sends a message to a queue; exactly one consumer receives it. Use for task distribution.

**Pub/sub**: Producer publishes to a topic/exchange; all subscribed consumers receive a copy. Use for event broadcasting.

**Core components**:
- **Producer** — publishes messages to an exchange, topic, or queue.
- **Consumer** — subscribes to and processes messages.
- **Queue** — ordered buffer holding messages until consumed.
- **Exchange** (RabbitMQ) — routes messages to queues via bindings and routing keys.
- **Topic/Subject** (NATS, SNS) — named channel for pub/sub routing.

---

## RabbitMQ

### Exchange Types

| Exchange  | Routing Logic                        | Use Case                    |
|-----------|--------------------------------------|-----------------------------|
| direct    | Exact routing key match              | Task routing by type        |
| topic     | Wildcard pattern (`*.log.#`)         | Log routing, filtering      |
| fanout    | Broadcast to all bound queues        | Event notification          |
| headers   | Match on message header attributes   | Complex multi-attribute routing |

### Core Concepts

- **Bindings** connect exchanges to queues with optional routing keys.
- **vhosts** provide namespace isolation (multi-tenant, env separation).
- **Quorum queues** replace classic mirrored queues — use for HA. Require odd-number clusters (≥3 nodes).
- **Lazy queues** page messages to disk — use for large backlogs with latency tolerance.

### RabbitMQ Connection (Node.js)

```typescript
import amqp from 'amqplib';

const conn = await amqp.connect('amqp://user:pass@localhost:5672/my-vhost');
const ch = await conn.createChannel();

// Declare a quorum queue
await ch.assertQueue('orders', {
  durable: true,
  arguments: { 'x-queue-type': 'quorum' },
});

// Declare a direct exchange with binding
await ch.assertExchange('order-events', 'direct', { durable: true });
await ch.bindQueue('orders', 'order-events', 'order.created');

// Publish
ch.publish('order-events', 'order.created', Buffer.from(JSON.stringify({
  orderId: '123', amount: 49.99,
})), { persistent: true, contentType: 'application/json' });
```

### RabbitMQ Patterns

**Work queues** — multiple consumers share a queue; set `prefetchCount` to balance load:

```typescript
ch.prefetch(10); // each consumer gets max 10 unacked messages
ch.consume('orders', async (msg) => {
  await processOrder(JSON.parse(msg.content.toString()));
  ch.ack(msg);
}, { noAck: false });
```

**Publish/subscribe** — fanout exchange broadcasts to all bound queues.

**Routing** — direct/topic exchange routes messages by key pattern.

**RPC over queues** — use `replyTo` and `correlationId` headers; create exclusive callback queue per client.

**Priority queues** — set `x-max-priority` on queue declaration; publish with `priority` property:

```typescript
await ch.assertQueue('urgent-tasks', {
  durable: true,
  arguments: { 'x-max-priority': 10 },
});
ch.sendToQueue('urgent-tasks', payload, { priority: 8 });
```

### RabbitMQ Clustering

- Deploy ≥3 nodes with identical Erlang cookies.
- Use quorum queues for replicated, consistent messaging.
- Only metadata (users, vhosts, exchanges, bindings) replicates by default — not messages.
- Monitor via Management UI or Prometheus exporter.

---

## AWS SQS

### Standard vs FIFO

| Feature            | Standard                    | FIFO                              |
|--------------------|-----------------------------|-----------------------------------|
| Ordering           | Best-effort                 | Strict per message group          |
| Deduplication      | None                        | 5-min window via dedup ID         |
| Throughput         | Nearly unlimited            | 300 msg/s (3,000 with batching)   |
| Delivery           | At-least-once (may dupe)    | Exactly-once delivery             |

### Key Configuration

```typescript
import { SQSClient, SendMessageCommand, ReceiveMessageCommand, DeleteMessageCommand } from '@aws-sdk/client-sqs';

const sqs = new SQSClient({ region: 'us-east-1' });

// Send to FIFO queue
await sqs.send(new SendMessageCommand({
  QueueUrl: 'https://sqs.us-east-1.amazonaws.com/123456/orders.fifo',
  MessageBody: JSON.stringify({ orderId: 'abc' }),
  MessageGroupId: 'customer-123',          // groups enforce ordering
  MessageDeduplicationId: 'order-abc-v1',  // prevents duplicates
}));

// Receive with long polling
const resp = await sqs.send(new ReceiveMessageCommand({
  QueueUrl: queueUrl,
  MaxNumberOfMessages: 10,
  WaitTimeSeconds: 20,           // long polling — reduces empty responses and cost
  VisibilityTimeout: 120,        // 2 min to process before redelivery
}));

// Delete after successful processing
for (const msg of resp.Messages ?? []) {
  await processMessage(msg);
  await sqs.send(new DeleteMessageCommand({
    QueueUrl: queueUrl, ReceiptHandle: msg.ReceiptHandle,
  }));
}
```

### Visibility Timeout

- Set longer than max processing time + buffer (e.g., 6× average + 20%).
- Extend dynamically with `ChangeMessageVisibility` for variable-duration tasks.
- Message reappears if not deleted before timeout — design consumers to be idempotent.

### SQS DLQ Setup (CloudFormation)

```yaml
Resources:
  OrdersQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: orders.fifo
      FifoQueue: true
      ContentBasedDeduplication: true
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt OrdersDLQ.Arn
        maxReceiveCount: 3
  OrdersDLQ:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: orders-dlq.fifo
      FifoQueue: true
```

---

## AWS SNS + SQS Fan-Out

Route one event to multiple consumers via SNS topic → multiple SQS subscriptions:

```yaml
Resources:
  OrderTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: order-events.fifo
      FifoTopic: true

  InventorySubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref OrderTopic
      Protocol: sqs
      Endpoint: !GetAtt InventoryQueue.Arn
      FilterPolicy:
        eventType: ["order.created", "order.updated"]

  NotificationSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref OrderTopic
      Protocol: sqs
      Endpoint: !GetAtt NotificationQueue.Arn
      FilterPolicy:
        eventType: ["order.created"]
```

- **Filter policies** route by message attributes — avoid processing irrelevant messages.
- FIFO topics preserve ordering and deduplication across fan-out.

---

## NATS and JetStream

### Core Concepts

- **Subjects** — hierarchical dot-separated names (`orders.created`, `orders.>`).
- **Streams** — persistent append-only logs storing messages matching subject filters.
- **Consumers** — track delivery/ack state independently per stream.

### Stream and Consumer Setup

```typescript
import { connect, AckPolicy, DeliverPolicy } from 'nats';

const nc = await connect({ servers: 'nats://localhost:4222' });
const jsm = await nc.jetstreamManager();

// Create a stream
await jsm.streams.add({
  name: 'ORDERS',
  subjects: ['orders.>'],
  retention: 'limits',         // limits | interest | workqueue
  max_msgs: 1_000_000,
  max_age: 7 * 24 * 60 * 60 * 1_000_000_000, // 7 days in nanoseconds
  storage: 'file',            // file | memory
  num_replicas: 3,
});

// Create a durable pull consumer
await jsm.consumers.add('ORDERS', {
  durable_name: 'order-processor',
  ack_policy: AckPolicy.Explicit,
  deliver_policy: DeliverPolicy.All,
  filter_subject: 'orders.created',
  max_deliver: 5,              // max redelivery attempts
});

// Pull and process messages
const js = nc.jetstream();
const consumer = await js.consumers.get('ORDERS', 'order-processor');
const iter = await consumer.fetch({ max_messages: 10 });
for await (const msg of iter) {
  await processOrder(msg.json());
  msg.ack();
}
```

### Consumer Types

| Type            | Persistence | Best For                          |
|-----------------|-------------|-----------------------------------|
| Durable pull    | Yes         | Batch processing, scaling workers |
| Durable push    | Yes         | Real-time with catch-up on reconnect |
| Ephemeral push  | No          | Debugging, ad-hoc replay          |

- Prefer **durable pull consumers** for production — supports backpressure and horizontal scaling.
- **Work queue retention** delivers each message to exactly one consumer in a group.
- **Key-Value store** — built on JetStream; use for lightweight config or state without an external DB.

---

## BullMQ (Node.js)

Redis-backed job queue for background processing.

### Queue, Worker, and Scheduler

```typescript
import { Queue, Worker, QueueScheduler } from 'bullmq';

const connection = { host: 'localhost', port: 6379 };

const queue = new Queue('emails', { connection });

// Add jobs
await queue.add('welcome-email', { userId: 42 }, {
  attempts: 3,
  backoff: { type: 'exponential', delay: 2000 },
  priority: 1,                  // lower = higher priority
  removeOnComplete: { count: 1000 },
  removeOnFail: { age: 7 * 24 * 3600 },
});

// Delayed and recurring jobs
await queue.add('reminder', { userId: 42 }, { delay: 30 * 60 * 1000 });
await queue.add('daily-report', {}, { repeat: { cron: '0 9 * * *' } });

// Worker with rate limiting
const worker = new Worker('emails', async (job) => {
  await sendEmail(job.data);
}, {
  connection,
  concurrency: 5,
  limiter: { max: 100, duration: 60_000 }, // 100 jobs/min
});

worker.on('failed', (job, err) => {
  console.error(`Job ${job?.id} failed: ${err.message}`);
});
```

### BullMQ Patterns

- **Sandboxed processors** — run job handlers in separate processes for isolation.
- **FlowProducer** — define parent/child job dependency graphs.
- **Events** — listen on `completed`, `failed`, `stalled` for monitoring.
- **Bull Board** — web dashboard for inspecting and retrying jobs.

---

## Message Acknowledgment

| Mechanism   | Behavior                                           | When to Use                    |
|-------------|----------------------------------------------------|---------------------------------|
| `ack`       | Confirm successful processing; remove from queue   | Default for processed messages  |
| `nack`      | Reject and requeue for redelivery                  | Transient failures              |
| `reject`    | Reject without requeue (send to DLQ if configured) | Poison/malformed messages       |
| `prefetch`  | Limit unacked messages per consumer                | Flow control (start with 10–50) |

### Rules

- Never use `autoAck` / `noAck` in production — messages are lost on crash.
- Set prefetch to bound memory; too high starves other consumers, too low underutilizes throughput.
- Ack only after processing completes (not before).
- On unrecoverable errors, `reject` to DLQ — do not infinitely retry.

---

## Dead Letter Queues (DLQ)

### Setup Pattern

1. Configure `maxReceiveCount` / `max_deliver` on the source queue.
2. Point failed messages to a dedicated DLQ.
3. Monitor DLQ depth — alert when `> 0`.
4. Implement redrive (replay DLQ → source) for transient failures.

### Retry Strategy

```
Attempt 1 → fail → wait 1s
Attempt 2 → fail → wait 4s    (exponential backoff)
Attempt 3 → fail → wait 16s
Attempt 4 → fail → move to DLQ
```

### Poison Message Handling

- Log full message payload and error on DLQ entry.
- Classify: malformed data → fix producer schema. Transient error → redrive after fix.
- Set TTL on DLQ messages (e.g., 14 days) to prevent unbounded growth.
- Connect DLQ alerts to incident management (PagerDuty, OpsGenie).

### RabbitMQ DLQ Config

```typescript
await ch.assertQueue('orders', {
  durable: true,
  arguments: {
    'x-dead-letter-exchange': 'dlx',
    'x-dead-letter-routing-key': 'orders.dead',
    'x-message-ttl': 30000,     // optional: auto-DLQ after 30s unprocessed
  },
});
await ch.assertExchange('dlx', 'direct', { durable: true });
await ch.assertQueue('orders-dlq', { durable: true });
await ch.bindQueue('orders-dlq', 'dlx', 'orders.dead');
```

---

## Delivery Semantics

### At-Least-Once (Default for Most Brokers)

- Broker retries until consumer acks. Consumers must be **idempotent**.
- Store processed message IDs in a persistent dedup table with TTL.

### Exactly-Once (Effectively)

Achieve via application-level patterns — no broker guarantees it end-to-end.

**Idempotent consumer**:

```typescript
async function handleMessage(msg: Message) {
  const msgId = msg.properties.messageId;
  const exists = await db.query('SELECT 1 FROM processed_messages WHERE id = $1', [msgId]);
  if (exists.rows.length > 0) return; // skip duplicate

  await db.transaction(async (tx) => {
    await tx.query('INSERT INTO processed_messages (id, processed_at) VALUES ($1, NOW())', [msgId]);
    await tx.query('UPDATE orders SET status = $1 WHERE id = $2', ['confirmed', msg.body.orderId]);
  });
  ch.ack(msg);
}
```

**Transactional outbox pattern**:

```typescript
// In the same DB transaction: update state + write outbox record
await db.transaction(async (tx) => {
  await tx.query('UPDATE orders SET status = $1 WHERE id = $2', ['shipped', orderId]);
  await tx.query('INSERT INTO outbox (id, topic, payload) VALUES ($1, $2, $3)',
    [uuid(), 'order.shipped', JSON.stringify({ orderId })]);
});

// Separate poller/CDC publishes outbox rows to the message queue
```

---

## Message Serialization

| Format   | Schema Evolution | Human-Readable | Performance | Best For                     |
|----------|------------------|----------------|-------------|------------------------------|
| JSON     | Manual           | Yes            | Moderate    | APIs, debugging, small teams |
| Protobuf | Built-in         | No             | Fast        | High-throughput services     |
| Avro     | Schema registry  | No             | Fast        | Data pipelines, analytics    |

### Versioning Rules

- Add fields as optional — never remove or rename without a migration.
- Include a `version` field or schema ID in message headers.
- Use a schema registry (Confluent, Apicurio) for Avro/Protobuf in multi-team orgs.
- Test backward and forward compatibility before deploying schema changes.

---

## Monitoring

### Key Metrics

| Metric               | Alert Threshold                  | Action                        |
|----------------------|----------------------------------|-------------------------------|
| Queue depth          | > 10× normal steady state        | Scale consumers or investigate |
| Consumer lag         | Growing over 5+ minutes          | Add consumers, check errors   |
| Message age          | Oldest msg > SLA target          | Investigate stuck consumers   |
| DLQ depth            | > 0                              | Triage poison messages        |
| Publish rate         | Sudden drop or spike             | Check producer health         |
| Ack rate             | Below publish rate sustained     | Consumer bottleneck           |

---

## Scaling Patterns

### Competing Consumers

Multiple consumers read from the same queue. Broker delivers each message to one consumer.

- Scale horizontally by adding consumer instances.
- Set prefetch/concurrency to match processing capacity.
- Use autoscaling based on queue depth (SQS + Lambda, K8s KEDA).

### Partitioning

- SQS FIFO: use `MessageGroupId` for parallel processing across groups while preserving order within each group.
- NATS: split into multiple subjects/streams for throughput.
- RabbitMQ: use consistent-hash exchange or shard queues across nodes.

### Consumer Groups

- NATS JetStream: work queue retention mode delivers each message to one consumer in the group.
- BullMQ: multiple workers on the same queue name form an implicit consumer group.

---

## Anti-Patterns

| Anti-Pattern                | Problem                                         | Fix                                        |
|-----------------------------|--------------------------------------------------|--------------------------------------------|
| Unbounded queues            | OOM, disk exhaustion, cascading failure          | Set max-length, TTL, and backpressure      |
| Missing DLQ                 | Poison messages block processing forever         | Always configure DLQ with alerting         |
| Large messages (>256KB)     | Broker memory pressure, slow throughput          | Store payload in S3/blob; send reference   |
| autoAck / noAck             | Messages lost on consumer crash                  | Use manual ack after processing            |
| Tight coupling to broker    | Cannot swap brokers; testing is painful          | Abstract behind a messaging interface      |
| No idempotency              | Duplicates cause double-charges, double-sends    | Dedup table + idempotency keys             |
| Retry without backoff       | Thundering herd on transient failures            | Exponential backoff with jitter            |
| Single consumer, no scaling | Queue depth grows unbounded under load           | Competing consumers + autoscaling          |
| Synchronous over queues     | Defeats async purpose; adds latency              | Use HTTP/gRPC for sync; queues for async   |
| No monitoring               | Silent failures, undetected message loss         | Alert on queue depth, DLQ, consumer lag    |

<!-- tested: pass -->
