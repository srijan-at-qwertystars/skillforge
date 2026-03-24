# NATS JetStream Patterns — Deep-Dive Reference

## Table of Contents
- [1. Stream Configuration Deep Dive](#1-stream-configuration-deep-dive)
- [2. Consumer Types](#2-consumer-types)
- [3. Exactly-Once Semantics](#3-exactly-once-semantics)
- [4. Flow Control](#4-flow-control)
- [5. Stream Mirroring and Sourcing](#5-stream-mirroring-and-sourcing)
- [6. Subject Transforms](#6-subject-transforms)
- [7. Stream Templates (Deprecated)](#7-stream-templates-deprecated)
- [8. Republishing](#8-republishing)
- [9. Advanced Patterns](#9-advanced-patterns)

---

## 1. Stream Configuration Deep Dive

### Retention Policies
**LimitsPolicy (default)** — messages kept until stream limits (max age/bytes/msgs) are hit. Consumers do not affect retention. Use for event logs and replay.
**InterestPolicy** — messages removed once acked by *all* defined consumers. If no consumers exist, messages are dropped. Always create consumers before publishing.
**WorkQueuePolicy** — messages removed once acked by *any* consumer. Each message delivered to exactly one consumer. Use for task distribution.
```bash
nats stream add ORDERS --subjects="orders.>" --retention=limits --max-age=30d
nats stream add NOTIFICATIONS --subjects="notify.>" --retention=interest
nats stream add TASKS --subjects="tasks.>" --retention=work --max-deliver=5
```

### Storage Types
| Property   | File                            | Memory                         |
|------------|---------------------------------|--------------------------------|
| Durability | Survives restarts               | Lost on restart                |
| Throughput | ~200K msgs/s (SSD)             | ~1M+ msgs/s                    |
| Use case   | Production events, audit        | Caches, ephemeral rate data    |

### Replicas: R1/R3/R5 Trade-offs
| Replicas | Fault Tolerance      | Latency  | Use Case                      |
|----------|----------------------|----------|-------------------------------|
| R1       | None                 | Lowest   | Dev, non-critical ephemeral   |
| R3       | Survives 1 node loss | Moderate | Production default            |
| R5       | Survives 2 node loss | Higher   | Critical financial/compliance |

R3 is the production default. Use R5 only with regulatory requirements on 5+ node clusters.

### Limits: Max Age, Bytes, Msgs, Msg Size, Consumers
```bash
nats stream add TELEMETRY --subjects="telemetry.>" \
  --max-age=7d --max-bytes=50GiB --max-msgs=100000000 \
  --max-msg-size=64KiB --max-consumers=50
# Per-subject limits prevent hot subjects from dominating:
nats stream add SENSORS --subjects="sensor.>" --max-msgs-per-subject=1000
```

### Discard Policies
**DiscardOld (default)** — oldest messages evicted for new ones. **DiscardNew** — new publishes rejected when full; producer receives error. Combine `discard_new_per_subject` with `max_msgs_per_subject=1` for a latest-value-per-subject store (similar to KV).

### Duplicate Detection Window
Controls how long the server tracks `Nats-Msg-Id` headers. Default 2m. Set to 2–5x publisher retry timeout.
```bash
nats stream add ORDERS --subjects="orders.>" --dupe-window=5m
```

### Allow/Deny Subject Lists
Configured at the account/user level in server config:
```hcl
accounts { PROD { jetstream: enabled
  users: [{ user: "svc-writer", permissions: {
    publish: { allow: ["events.orders.>"] }
    subscribe: { deny: ["events.internal.>"] }
}}]}}
```

### Stream Placement
```bash
nats stream add REGIONAL_EU --subjects="eu.>" --placement-cluster=eu-west-1
nats stream add GPU_RESULTS --subjects="ml.results.>" --placement-tags=gpu,high-mem
```
Server tags: `jetstream { tags: ["eu-west", "ssd", "high-mem"] }`

---

## 2. Consumer Types

### Push vs Pull Consumers
```go
// Push — server delivers to a subject
sub, _ := js.SubscribeSync("orders.>",
    nats.Durable("processor"), nats.DeliverSubject("deliver.orders"))
// Pull — client fetches batches on demand
sub, _ := js.PullSubscribe("orders.>", "processor")
msgs, _ := sub.Fetch(100, nats.MaxWait(5*time.Second))
```

| Aspect           | Push                         | Pull                           |
|------------------|------------------------------|--------------------------------|
| Delivery control | Server-driven                | Client-driven                  |
| Backpressure     | max_ack_pending, rate_limit  | Natural — fetch when ready     |
| Scaling          | Queue groups on deliver subj | Multiple pull subscribers      |

**Prefer pull consumers for new designs.** Simpler scaling and natural backpressure.

### Durable vs Ephemeral Consumers
**Durable** — server persists ack state across disconnects/restarts via `durable_name`. **Ephemeral** — auto-cleaned after `inactive_threshold` (default 5s) when no subscriptions remain.

### Consumer Configuration Options
```json
{ "durable_name": "processor", "ack_policy": "explicit", "ack_wait": "30s",
  "max_deliver": 5, "max_ack_pending": 1000, "idle_heartbeat": "15s",
  "flow_control": true, "filter_subject": "orders.us.>", "replay_policy": "instant" }
```
- **ack_policy**: `none` | `all` (cumulative) | `explicit` (individual). Always `explicit` in prod.
- **ack_wait**: Time before unacked message redelivers. Processing time + buffer.
- **max_deliver**: Redelivery cap. Terminal after this (see DLQ in §9.3).
- **max_ack_pending**: In-flight concurrency limit — primary throughput/safety knob.
- **idle_heartbeat/flow_control**: Push only. Heartbeats detect stale connections; flow control prevents overflow.
- **replay_policy**: `instant` (fast) or `original` (publish-rate replay).

### Ordered Consumers
Client-side abstraction: ephemeral, `ack_none`, `max_deliver=1`, auto-recreate on gaps. Guarantees ordered delivery across reconnects. Single subscriber only — not for workload distribution.
```go
sub, _ := js.Subscribe("sensors.>", handler, nats.OrderedConsumer())
```

### Consumer Groups / Queue Groups
Multiple clients pulling from the same durable consumer share workload:
```go
sub1, _ := js.PullSubscribe("tasks.>", "worker-pool") // Worker 1
sub2, _ := js.PullSubscribe("tasks.>", "worker-pool") // Worker 2 — shared
```
For push consumers, use `deliver_group`:
```bash
nats consumer add TASKS push-workers --deliver=tasks.deliver --deliver-group=workers
```

### Filter Subjects
```bash
nats consumer add ORDERS us-proc --pull --filter="orders.us.>"
nats consumer add ORDERS priority --pull --filter="orders.us.priority.>,orders.eu.priority.>"  # 2.10+
```

### Deliver Policies
| Policy               | Behavior                    | CLI Flag                              |
|----------------------|-----------------------------|---------------------------------------|
| `all`                | From beginning              | `--deliver=all`                       |
| `last`               | Last message only           | `--deliver=last`                      |
| `last_per_subject`   | Last msg per subject        | `--deliver=last-per-subject`          |
| `new`                | Only future messages        | `--deliver=new`                       |
| `by_start_sequence`  | From specific sequence      | `--start-seq=5000`                    |
| `by_start_time`      | From specific timestamp     | `--start-time="2024-01-15T00:00:00Z"` |

---

## 3. Exactly-Once Semantics

### Message Deduplication via Nats-Msg-Id
Publishers set the `Nats-Msg-Id` header. Server tracks IDs within the dedup window and ignores duplicates.
```go
msg := &nats.Msg{Subject: "orders.new", Data: orderJSON, Header: nats.Header{}}
msg.Header.Set("Nats-Msg-Id", fmt.Sprintf("order-%s-%d", orderID, version))
ack, _ := js.PublishMsg(msg)
if ack.Duplicate { log.Info("duplicate, already stored", "seq", ack.Sequence) }
```
Use short deterministic IDs (`{entity}-{version}`) over UUIDs to reduce dedup memory.

### Dedup Window Configuration
```bash
nats stream add PAYMENTS --subjects="payments.>" --dupe-window=10m
```
Memory scales with `unique_ids x id_size`. 1M msgs/min with 36-byte UUIDs ≈ 36 MB per minute of window.

### Double Ack Pattern
Combine publisher dedup with consumer idempotency:
```go
func processWithDoubleAck(msg *nats.Msg) error {
    msgID := msg.Header.Get("Nats-Msg-Id")
    if alreadyProcessed(msgID) { msg.Ack(); return nil }
    tx, _ := db.Begin()
    if err := processOrder(tx, msg.Data); err != nil {
        msg.Nak(); tx.Rollback(); return err
    }
    markProcessed(tx, msgID) // same transaction as business logic
    tx.Commit()
    msg.Ack() // if ack fails, redelivery hits idempotency check
    return nil
}
```

### Idempotent Consumer Design
Use upserts, not inserts. Store `Nats-Msg-Id` alongside business data. Gate side effects (emails, webhooks) on a "sent" flag.
```sql
INSERT INTO orders (id, status, amount, nats_msg_id) VALUES ($1,$2,$3,$4)
ON CONFLICT (id) DO UPDATE SET status=EXCLUDED.status, amount=EXCLUDED.amount
WHERE orders.nats_msg_id != EXCLUDED.nats_msg_id;
```

---

## 4. Flow Control

### Max Ack Pending
Primary concurrency control. Low (1–10): strict ordering, low throughput. Medium (100–1000): balanced default. High (5000+): max throughput, more in-flight risk on crash.

### Rate Limiting on Push Consumers
```json
{ "durable_name": "slow-consumer", "deliver_subject": "deliver.slow", "rate_limit_bps": 1048576 }
```
Caps delivery at 1 MB/s — for constrained networks or rate-limited downstream APIs.

### Heartbeat-Based Flow Control
Push consumers only. Enable together:
```bash
nats consumer add EVENTS realtime --deliver=events.rt --heartbeat=10s --flow-control
```
Server sends `Status: 100` heartbeats when idle. Flow control messages require client response before further delivery.

### Backpressure Handling
**Pull** — natural; client fetches only when ready. **Push** — `max_ack_pending` pauses delivery at limit. **Producer** — `discard: new` rejects publishes when stream is full:
```go
if _, err := js.Publish("orders.new", data); err != nil {
    log.Warn("stream at capacity, backing off"); time.Sleep(backoff)
}
```

---

## 5. Stream Mirroring and Sourcing

### Mirror Streams (Read Replicas)
A mirror is a 1:1 read-only copy. Publishes to the mirror are rejected. Ideal for regional read replicas.
```bash
nats stream add ORDERS_MIRROR --mirror=ORDERS --storage=file --replicas=1
```

### Source Streams (Aggregation)
Aggregate multiple streams into one. Unlike mirrors, multiple sources are allowed.
```bash
nats stream add ALL_ORDERS --source=ORDERS_US --source=ORDERS_EU --source=ORDERS_APAC
```

### Cross-Cluster Mirroring
Use the `external` block for the remote cluster's JetStream API prefix:
```json
{ "name": "ORDERS_DR", "mirror": { "name": "ORDERS",
    "external": { "api": "$JS.us-east.API", "deliver": "mirror.deliver.ORDERS" } }}
```
Requires gateways or leaf nodes connecting the clusters.

### Subject Transforms on Mirrors/Sources
```json
{ "name": "ORDERS_ARCHIVE", "sources": [{
    "name": "ORDERS_US",
    "subject_transforms": [{ "src": "orders.us.>", "dest": "archive.us.orders.>" }]
}]}
```

### Filtering on Sources
```json
{ "name": "PRIORITY_ORDERS", "sources": [
    { "name": "ORDERS", "filter_subject": "orders.*.priority.>" }
]}
```

---

## 6. Subject Transforms

### Stream-Level Subject Transforms
Rewrite subjects before storage:
```json
{ "name": "EVENTS", "subjects": ["events.>"],
  "subject_transform": { "src": "events.>", "dest": "v2.events.>" } }
```
A publish to `events.order.created` is stored as `v2.events.order.created`.

### Source/Mirror Subject Transforms
Applied during replication (see §5.4). Useful for namespace isolation across environments.

### Republishing Transformed Subjects
Combine transforms with republish to expose remapped data on Core NATS:
```json
{ "republish": { "src": "orders.>", "dest": "notify.orders.>", "headers_only": false } }
```

### Use Cases: Multi-Tenancy, Versioning
**Multi-tenancy** — map tenant publishes into a shared stream:
```json
{ "subject_transform": { "src": "tenant.*.events.>", "dest": "events.{{wildcard(1)}}.>" } }
```
**API versioning** — aggregate versioned subjects into canonical form:
```json
{ "sources": [
    { "name": "API_V1", "subject_transforms": [{ "src": "v1.orders.>", "dest": "orders.>" }] },
    { "name": "API_V2", "subject_transforms": [{ "src": "v2.orders.>", "dest": "orders.>" }] }
]}
```

---

## 7. Stream Templates (Deprecated)

### What They Were and Why Deprecated
Stream templates (removed in NATS Server 2.10) auto-created streams when messages matched a subject pattern. Publishing to `device.abc123.telemetry` would spawn `DEVICE_TMPL_abc123`.

**Why deprecated:** no lifecycle management (streams accumulated endlessly), no config propagation on updates, thousands of auto-created streams overwhelmed tooling, subject overlap conflicts.

### Modern Alternatives
- **Wildcard subjects** in a single stream with per-subject limits (`--max-msgs-per-subject=10000`)
- **Subject transforms** to route varied inputs into canonical structure
- **Application-managed streams** created programmatically at provisioning time

---

## 8. Republishing

### Server-Side Republish Configuration
Copies stream messages onto Core NATS subjects in real time, server-side, zero client overhead.
```bash
nats stream add ORDERS --subjects="orders.>" \
  --republish-source="orders.>" --republish-dest="stream.notify.orders.>"
```
Set `headers_only: true` for lightweight notification triggers without payload.

### Use Cases: Audit Logs, Change Data Capture
**Audit:** republish KV changes for non-JetStream consumers:
```json
{ "republish": { "src": "$KV.USERS.>", "dest": "audit.kv.users.>" } }
```
**CDC:** external connectors (webhooks, Kafka bridge) subscribe to `cdc.inventory.>` via plain NATS without JetStream consumer overhead.

### Headers on Republished Messages
| Header               | Description                              |
|----------------------|------------------------------------------|
| `Nats-Stream`        | Source stream name                        |
| `Nats-Sequence`      | Stream sequence number                   |
| `Nats-Last-Sequence` | Previous sequence for same subject        |
| `Nats-Subject`       | Original subject (if transformed)         |

---

## 9. Advanced Patterns

### 9.1 Events from KV and Object Store Changes
KV buckets and Object Stores are JetStream streams (`KV_{BUCKET}`, `OBJ_{STORE}`). Consume directly:
```go
watcher, _ := kv.WatchAll()
for entry := range watcher.Updates() {
    if entry == nil { continue }
    fmt.Printf("key=%s op=%s rev=%d\n", entry.Key(), entry.Operation(), entry.Revision())
}
```
Or as a raw consumer: `nats consumer add KV_CONFIG watcher --pull --deliver=new --filter='$KV.CONFIG.>'`

### 9.2 Stream-to-Stream Pipelines
```
[RAW] --consumer--> [processor] --publish--> [ENRICHED] --source--> [AGGREGATED]
```
```go
rawSub, _ := js.PullSubscribe("raw.events.>", "enricher")
for {
    msgs, _ := rawSub.Fetch(50, nats.MaxWait(5*time.Second))
    for _, msg := range msgs {
        pubMsg := &nats.Msg{
            Subject: strings.Replace(msg.Subject, "raw.", "enriched.", 1),
            Data: enrich(msg.Data), Header: nats.Header{},
        }
        pubMsg.Header.Set("Nats-Msg-Id", "e-"+msg.Header.Get("Nats-Msg-Id"))
        js.PublishMsg(pubMsg); msg.Ack()
    }
}
```
For zero-code aggregation: `nats stream add AGG --source=ENRICHED_A --source=ENRICHED_B`

### 9.3 Dead Letter Queues
JetStream has no built-in DLQ. Two approaches:

**Advisory-based** — capture max-delivery advisory events:
```bash
nats consumer add ORDERS processor --pull --max-deliver=5
nats stream add DLQ --subjects='$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.>'
```
Consume the DLQ stream, extract `stream_seq` from advisory JSON, fetch original via `js.GetMsg()`.

**Term-based (NATS 2.10+)** — publish to DLQ from the consumer, then terminate:
```go
meta, _ := msg.Metadata()
if meta.NumDelivered > 3 {
    js.Publish("dlq.orders", msg.Data,
        nats.MsgId(fmt.Sprintf("dlq-%d", meta.Sequence.Stream)))
    msg.Term(); return  // stop redelivery
}
if err := process(msg); err != nil {
    msg.NakWithDelay(time.Duration(meta.NumDelivered) * 5 * time.Second); return
}
msg.Ack()
```

### 9.4 Windowed Aggregation Patterns
JetStream has no native windowing. Build tumbling windows with ephemeral consumers:
```go
ticker := time.NewTicker(1 * time.Minute)
for range ticker.C {
    end := time.Now().Truncate(time.Minute)
    start := end.Add(-1 * time.Minute)
    ci, _ := js.AddConsumer("METRICS", &nats.ConsumerConfig{
        FilterSubject: "metrics.cpu.>", AckPolicy: nats.AckExplicitPolicy,
        DeliverPolicy: nats.DeliverByStartTimePolicy, OptStartTime: &start,
        InactiveThreshold: 30 * time.Second,
    })
    sub, _ := js.PullSubscribe("metrics.cpu.>", ci.Name)
    var values []float64
    for {
        msgs, _ := sub.Fetch(500, nats.MaxWait(2*time.Second))
        if len(msgs) == 0 { break }
        for _, m := range msgs {
            meta, _ := m.Metadata()
            if meta.Timestamp.After(end) { break }
            values = append(values, parseMetric(m.Data)); m.Ack()
        }
    }
    js.Publish(fmt.Sprintf("metrics.agg.%d", end.Unix()), marshalAgg(aggregate(values)))
}
```
For sliding windows, checkpoint the last processed sequence in a KV bucket and create ephemeral consumers from that point on each tick. Pairs naturally with stream-to-stream pipelines.
