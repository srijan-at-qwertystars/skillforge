# Advanced Kafka Patterns

Dense reference for advanced Kafka Streams, exactly-once semantics, event sourcing, CQRS, and related patterns.

---

## Table of Contents

1. [Exactly-Once Semantics (EOS)](#exactly-once-semantics-eos)
2. [Transactional Producer/Consumer](#transactional-producerconsumer)
3. [Kafka Streams Topology Design](#kafka-streams-topology-design)
4. [Windowing](#windowing)
5. [State Store Management](#state-store-management)
6. [Interactive Queries](#interactive-queries)
7. [KTable Foreign Key Joins](#ktable-foreign-key-joins)
8. [Punctuators](#punctuators)
9. [Error Handling in Streams](#error-handling-in-streams)
10. [Dead Letter Topics](#dead-letter-topics)
11. [Retry Topics with Exponential Backoff](#retry-topics-with-exponential-backoff)
12. [Event Sourcing with Kafka](#event-sourcing-with-kafka)
13. [CQRS Implementation](#cqrs-implementation)
14. [Outbox Pattern with Debezium](#outbox-pattern-with-debezium)

---

## Exactly-Once Semantics (EOS)

EOS in Kafka means each message is processed exactly once across the consume-transform-produce cycle. It does **not** extend to external systems.

### How it works

1. **Idempotent producer**: Sequence numbers per partition detect duplicates at the broker. Enabled via `enable.idempotence=true` (default since Kafka 3.0).
2. **Transactional producer**: Groups produces and offset commits into atomic transactions. Requires `transactional.id`.
3. **Consumer `isolation.level=read_committed`**: Consumer only sees committed transactional messages.

### EOS in Kafka Streams

```java
props.put(StreamsConfig.PROCESSING_GUARANTEE_CONFIG, StreamsConfig.EXACTLY_ONCE_V2);
```

`EXACTLY_ONCE_V2` (KIP-447) uses a single transaction per task across all partitions, reducing overhead vs. the deprecated v1. Requires broker version ≥ 2.5.

### Limitations

- EOS adds latency (~50-100ms per transaction commit).
- External sinks (DB, HTTP) must implement their own idempotency.
- `transactional.id` must be stable across restarts; use `<app-id>-<task-id>` pattern.
- Transaction timeout (`transaction.timeout.ms`, default 60s) must exceed maximum processing time.

### When NOT to use EOS

- High-throughput, loss-tolerant workloads (metrics, logs) — overhead isn't justified.
- When downstream systems already deduplicate (e.g., upsert to DB by primary key).

---

## Transactional Producer/Consumer

### Producer setup

```java
Properties props = new Properties();
props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "broker:9092");
props.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, "order-tx-01");
props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
props.put(ProducerConfig.ACKS_CONFIG, "all");

KafkaProducer<String, String> producer = new KafkaProducer<>(props);
producer.initTransactions();
```

### Consume-transform-produce loop

```java
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    if (records.isEmpty()) continue;

    producer.beginTransaction();
    try {
        for (ConsumerRecord<String, String> record : records) {
            String output = transform(record.value());
            producer.send(new ProducerRecord<>("output-topic", record.key(), output));
        }
        // Commit offsets within the transaction
        producer.sendOffsetsToTransaction(
            currentOffsets(records),
            consumer.groupMetadata()
        );
        producer.commitTransaction();
    } catch (ProducerFencedException | OutOfOrderSequenceException e) {
        // Fatal — another instance has same transactional.id
        producer.close();
        throw e;
    } catch (KafkaException e) {
        producer.abortTransaction();
    }
}
```

### Key rules

- `transactional.id` must be unique per producer instance; reuse across restarts to fence zombies.
- Call `initTransactions()` exactly once before any transaction.
- `sendOffsetsToTransaction()` atomically commits consumer offsets with produced messages.
- Set `consumer.isolation.level=read_committed` on downstream consumers.

---

## Kafka Streams Topology Design

### Topology structure

A topology is a DAG of source → processor → sink nodes. Design principles:

1. **Sub-topologies**: Kafka Streams splits the topology at repartition boundaries. Each sub-topology scales independently.
2. **Co-partitioning**: Joins require that both input topics have the same partition count and partitioning strategy. Use `through()` or `repartition()` to fix mismatches.
3. **Avoid unnecessary repartitions**: `groupByKey()` doesn't repartition; `groupBy()` always does. Prefer `groupByKey()` when the key is already correct.

### Processor API (low-level)

```java
builder.addSource("source", "input-topic");
builder.addProcessor("process", () -> new AbstractProcessor<String, String>() {
    private KeyValueStore<String, Long> store;

    @Override
    public void init(ProcessorContext context) {
        super.init(context);
        store = context.getStateStore("counts");
        // Schedule punctuator for periodic flushes
        context.schedule(Duration.ofSeconds(30), PunctuationType.WALL_CLOCK_TIME,
            timestamp -> flushAggregates(store));
    }

    @Override
    public void process(String key, String value) {
        Long count = store.get(key);
        store.put(key, (count == null ? 0 : count) + 1);
        context().forward(key, store.get(key));
    }
}, "counts-store");
builder.addSink("sink", "output-topic", "process");
```

### Naming strategy

Always name processors, state stores, and repartition topics explicitly to avoid topology-breaking changes on code refactors:

```java
orders.groupByKey(Grouped.as("orders-by-key"))
      .count(Named.as("order-count"), Materialized.as("order-count-store"));
```

---

## Windowing

### Window types

| Window Type | Behavior | Use Case |
|------------|----------|----------|
| **Tumbling** | Fixed-size, non-overlapping | Hourly aggregations |
| **Hopping** | Fixed-size, overlapping by advance interval | Smoothed metrics |
| **Sliding** | Fixed-size, triggered on event arrival | Distinct count in last N minutes |
| **Session** | Dynamic, gap-based (closes after inactivity) | User session tracking |

### Tumbling window

```java
KTable<Windowed<String>, Long> counts = stream
    .groupByKey()
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(5)))
    .count(Materialized.as("tumbling-counts"));
```

### Hopping window

```java
// 10-minute windows advancing every 2 minutes → 5 overlapping windows per event
.windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(10))
    .advanceBy(Duration.ofMinutes(2)))
```

### Sliding window

```java
// Emits result when events are within the window size of each other
.windowedBy(SlidingWindows.ofTimeDifferenceWithNoGrace(Duration.ofMinutes(5)))
```

### Session window

```java
// Sessions close after 30 minutes of inactivity
.windowedBy(SessionWindows.ofInactivityGapWithNoGrace(Duration.ofMinutes(30)))
```

### Grace period

Controls how long late records are accepted after window close:

```java
TimeWindows.ofSizeAndGrace(Duration.ofMinutes(5), Duration.ofMinutes(1))
```

After the grace period, late records are dropped. Handle dropped records via `ProductionExceptionHandler` or by logging.

### Suppress

Hold back window results until the window closes:

```java
counts.suppress(Suppressed.untilWindowCloses(BufferConfig.unbounded()))
      .toStream()
      .foreach((key, value) -> emit(key, value));
```

Without suppress, you get intermediate results per-event — useful for real-time dashboards but not for accurate final counts.

---

## State Store Management

### Store types

| Store | Backing | Use Case |
|-------|---------|----------|
| **RocksDB** | Disk + memory cache | Default, handles large state |
| **In-memory** | Heap only | Small state, fast access |
| **Custom** | Any `StateStore` impl | Specialized needs |

### RocksDB tuning

```java
props.put(StreamsConfig.ROCKSDB_CONFIG_SETTER_CLASS_CONFIG, CustomRocksDBConfig.class);

public class CustomRocksDBConfig implements RocksDBConfigSetter {
    @Override
    public void setConfig(String storeName, Options options, Map<String, Object> configs) {
        BlockBasedTableConfig tableConfig = (BlockBasedTableConfig) options.tableFormatConfig();
        tableConfig.setBlockCacheSize(64 * 1024 * 1024L); // 64MB block cache
        tableConfig.setBlockSize(16 * 1024);               // 16KB blocks
        options.setTableFormatConfig(tableConfig);
        options.setMaxWriteBufferNumber(3);
        options.setWriteBufferSize(16 * 1024 * 1024);      // 16MB write buffer
    }
}
```

### In-memory store

```java
Materialized.<String, Long, KeyValueStore<Bytes, byte[]>>as("my-store")
    .withLoggingEnabled(Map.of())  // changelog still enabled for fault tolerance
    .withCachingEnabled()
    .withKeySerde(Serdes.String())
    .withValueSerde(Serdes.Long())
    // Force in-memory
    .withStoreType(BuiltInDurableStoreType.IN_MEMORY);
```

### Changelog topics

Every state store has a corresponding changelog topic (`<app-id>-<store-name>-changelog`). Configuration:

- `cleanup.policy=compact` — only latest value per key retained.
- Partition count matches the store's input topic.
- Replication factor controlled by `StreamsConfig.REPLICATION_FACTOR_CONFIG`.
- Standby replicas (`num.standby.replicas`) pre-load changelog for faster failover.

### State store sizing

- Monitor RocksDB metrics: `rocksdb-state-id`, block cache hit ratio, memtable flushes.
- Rule of thumb: Allocate 2× expected state size for RocksDB overhead.
- Set `state.dir` to fast SSD storage.
- For very large state: consider using a GlobalKTable backed by a compacted topic instead of per-instance state.

---

## Interactive Queries

Query local state stores from the Streams application, enabling it to serve as a lightweight query service.

### Basic query

```java
ReadOnlyKeyValueStore<String, Long> store = streams.store(
    StoreQueryParameters.fromNameAndType("order-counts", QueryableStoreTypes.keyValueStore())
);
Long count = store.get("customer-123");
```

### Range queries

```java
KeyValueIterator<String, Long> range = store.range("A", "D");
while (range.hasNext()) {
    KeyValue<String, Long> entry = range.next();
    // process entry
}
range.close(); // always close iterators
```

### Windowed store queries

```java
ReadOnlyWindowStore<String, Long> windowStore = streams.store(
    StoreQueryParameters.fromNameAndType("windowed-counts",
        QueryableStoreTypes.windowStore())
);
WindowStoreIterator<Long> iter = windowStore.fetch("key",
    Instant.now().minus(Duration.ofHours(1)), Instant.now());
```

### Cross-instance queries

Each instance only has state for its assigned partitions. For full dataset queries:

1. Use `StreamsMetadata` to discover which instance owns a key:
   ```java
   StreamsMetadata meta = streams.queryMetadataForKey("store", key, Serdes.String().serializer());
   HostInfo host = meta.hostInfo();
   ```
2. If local, query directly. If remote, forward HTTP request to the owning instance.
3. Set `application.server` to expose instance host/port:
   ```java
   props.put(StreamsConfig.APPLICATION_SERVER_CONFIG, "host1:8080");
   ```

---

## KTable Foreign Key Joins

Join two KTables where the join key differs from the primary key. Available since Kafka Streams 2.4.

```java
KTable<String, Order> orders = builder.table("orders");       // key: orderId
KTable<String, Customer> customers = builder.table("customers"); // key: customerId

// Join orders to customers using order.customerId as the foreign key
KTable<String, EnrichedOrder> enriched = orders.join(
    customers,
    order -> order.getCustomerId(),  // foreign key extractor
    (order, customer) -> new EnrichedOrder(order, customer),
    TableJoined.as("order-customer-fk-join")
);
```

### How it works internally

1. Orders are repartitioned by the foreign key (customerId).
2. A subscription store tracks which order keys map to which foreign keys.
3. When a customer record changes, the subscription store identifies affected orders and re-emits joined results.

### Constraints

- Left table records with null foreign keys are dropped.
- The foreign key extractor must return a non-null value for the join to match.
- Both tables must use the same `StreamsConfig`.

---

## Punctuators

Punctuators fire periodic callbacks in the Processor API. Two types:

### STREAM_TIME

Advances only when new records arrive. Safe for deterministic, replayable processing.

```java
context.schedule(Duration.ofSeconds(30), PunctuationType.STREAM_TIME, timestamp -> {
    KeyValueIterator<String, Aggregate> iter = store.all();
    while (iter.hasNext()) {
        KeyValue<String, Aggregate> entry = iter.next();
        if (entry.value.isComplete()) {
            context.forward(entry.key, entry.value);
            store.delete(entry.key);
        }
    }
    iter.close();
});
```

### WALL_CLOCK_TIME

Fires based on system clock. Useful for timeouts, heartbeats, periodic flushes regardless of input volume.

```java
context.schedule(Duration.ofMinutes(1), PunctuationType.WALL_CLOCK_TIME, timestamp -> {
    emitMetrics();
});
```

### Pitfalls

- STREAM_TIME punctuators stall if input stops — no records = no time advancement.
- WALL_CLOCK_TIME may fire during rebalancing — check state store availability.
- Punctuators run on the stream thread — long operations block processing.
- Close iterators in punctuator callbacks to avoid memory leaks.

---

## Error Handling in Streams

### Deserialization errors

```java
props.put(StreamsConfig.DEFAULT_DESERIALIZATION_EXCEPTION_HANDLER_CLASS_CONFIG,
    LogAndContinueExceptionHandler.class); // skip bad records
```

Custom handler:

```java
public class DlqDeserializationHandler implements DeserializationExceptionHandler {
    @Override
    public DeserializationHandlerResponse handle(ProcessorContext context,
            ConsumerRecord<byte[], byte[]> record, Exception exception) {
        // Send to DLQ, log, alert
        sendToDlq(record, exception);
        return DeserializationHandlerResponse.CONTINUE;
    }
}
```

### Production errors

```java
props.put(StreamsConfig.DEFAULT_PRODUCTION_EXCEPTION_HANDLER_CLASS_CONFIG,
    DefaultProductionExceptionHandler.class); // default: FAIL

// Custom: retry transient errors, fail on permanent
public class RetryProductionHandler implements ProductionExceptionHandler {
    @Override
    public ProductionExceptionHandlerResponse handle(ProducerRecord<byte[], byte[]> record,
            Exception exception) {
        if (isTransient(exception)) return ProductionExceptionHandlerResponse.CONTINUE;
        return ProductionExceptionHandlerResponse.FAIL;
    }
}
```

### Uncaught exceptions

```java
streams.setUncaughtExceptionHandler(exception -> {
    log.error("Stream thread failed", exception);
    if (isRecoverable(exception)) {
        return StreamThreadExceptionResponse.REPLACE_THREAD;
    }
    return StreamThreadExceptionResponse.SHUTDOWN_APPLICATION;
});
```

Options: `REPLACE_THREAD` (restart thread), `SHUTDOWN_CLIENT` (stop this instance), `SHUTDOWN_APPLICATION` (stop all instances).

---

## Dead Letter Topics

Route unprocessable messages to a DLQ for manual inspection without blocking the pipeline.

### Kafka Connect DLQ

```json
{
  "errors.tolerance": "all",
  "errors.deadletterqueue.topic.name": "dlq-connector-name",
  "errors.deadletterqueue.topic.replication.factor": 3,
  "errors.deadletterqueue.context.headers.enable": true
}
```

Headers include: original topic, partition, offset, error class, error message, connector name, task ID.

### Consumer-side DLQ pattern

```python
def process_with_dlq(consumer, producer, dlq_topic):
    while True:
        msg = consumer.poll(1.0)
        if msg is None or msg.error():
            continue
        try:
            process(msg)
            consumer.commit(asynchronous=False)
        except Exception as e:
            headers = [
                ("original-topic", msg.topic().encode()),
                ("original-partition", str(msg.partition()).encode()),
                ("original-offset", str(msg.offset()).encode()),
                ("error", str(e).encode()),
                ("timestamp", str(time.time()).encode()),
            ]
            producer.produce(dlq_topic, key=msg.key(), value=msg.value(), headers=headers)
            producer.flush()
            consumer.commit(asynchronous=False)
```

### DLQ topic configuration

```
cleanup.policy=delete
retention.ms=2592000000   # 30 days
```

Monitor DLQ topic lag and message count — non-zero means something needs attention.

---

## Retry Topics with Exponential Backoff

Implement graduated retry with increasing delays before routing to DLQ.

### Topic structure

```
orders                    → main consumer
orders-retry-1  (1 min)   → retry consumer 1
orders-retry-2  (10 min)  → retry consumer 2
orders-retry-3  (60 min)  → retry consumer 3
orders-dlq                → dead letter (manual)
```

### Implementation

```java
public class RetryRouter {
    private static final List<RetryLevel> LEVELS = List.of(
        new RetryLevel("orders-retry-1", Duration.ofMinutes(1)),
        new RetryLevel("orders-retry-2", Duration.ofMinutes(10)),
        new RetryLevel("orders-retry-3", Duration.ofMinutes(60))
    );

    public void routeToRetry(ConsumerRecord<String, String> record, Exception e) {
        int currentRetry = getRetryCount(record);
        if (currentRetry >= LEVELS.size()) {
            sendToDlq(record, e);
            return;
        }
        RetryLevel level = LEVELS.get(currentRetry);
        Headers headers = new RecordHeaders(record.headers().toArray());
        headers.add("retry-count", String.valueOf(currentRetry + 1).getBytes());
        headers.add("original-timestamp", String.valueOf(record.timestamp()).getBytes());
        producer.send(new ProducerRecord<>(level.topic, null, record.key(), record.value(), headers));
    }
}
```

### Delay enforcement

Option A: **Pause/resume consumer** — poll, check timestamp, pause partition if too early, resume when delay elapsed.

Option B: **Kafka consumer `pause()`/`resume()`**:

```java
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(500));
    for (TopicPartition tp : records.partitions()) {
        for (ConsumerRecord<String, String> record : records.records(tp)) {
            long elapsed = System.currentTimeMillis() - record.timestamp();
            if (elapsed < requiredDelay.toMillis()) {
                consumer.pause(Set.of(tp));
                scheduler.schedule(() -> consumer.resume(Set.of(tp)),
                    requiredDelay.toMillis() - elapsed, TimeUnit.MILLISECONDS);
            } else {
                process(record);
            }
        }
    }
}
```

---

## Event Sourcing with Kafka

### Core concept

All state changes are stored as an immutable, ordered sequence of events in a Kafka topic. Current state is derived by replaying events.

### Topic design

```
user-events (compacted: NO, retention: forever or very long)
  key: userId
  value: { "type": "UserCreated", "data": {...}, "timestamp": "..." }
         { "type": "EmailChanged", "data": {"newEmail": "..."}, "timestamp": "..." }
```

### Snapshot optimization

For entities with many events, periodically write snapshot events:

```
key: userId
value: { "type": "Snapshot", "version": 42, "state": {full current state} }
```

Replay from latest snapshot + subsequent events. Use a compacted snapshot topic alongside the raw event log:

```
user-events     → cleanup.policy=delete, retention=forever  (full event history)
user-snapshots  → cleanup.policy=compact                     (latest snapshot per key)
```

### Projections

Consumers build read-optimized views from the event stream:

```java
KStream<String, UserEvent> events = builder.stream("user-events");
KTable<String, UserProfile> profiles = events
    .groupByKey()
    .aggregate(
        UserProfile::new,
        (key, event, profile) -> profile.apply(event),
        Materialized.as("user-profiles")
    );
```

### Rules

- Events are immutable — never update or delete.
- Event schema must be evolvable (use FULL compatibility in Schema Registry).
- Include enough context in each event to be self-describing.
- Use a correlation ID across related events for tracing.

---

## CQRS Implementation

### Architecture with Kafka

```
                   ┌──────────┐
  Command ──────► │ Command   │ ──► command-topic ──► Command Handler
                   │ Gateway   │                        │
                   └──────────┘                        ▼
                                                  Write Model (DB)
                                                       │
                                                  domain-events topic
                                                       │
                                       ┌───────────────┼───────────────┐
                                       ▼               ▼               ▼
                                  Read Model 1    Read Model 2    Read Model 3
                                  (Elasticsearch) (Redis cache)   (Analytics DB)
```

### Command handling

```java
// Command topic consumer
KStream<String, Command> commands = builder.stream("commands");
commands.foreach((key, cmd) -> {
    try {
        DomainEvent event = commandHandler.handle(cmd);
        eventProducer.send(new ProducerRecord<>("domain-events", key, event));
    } catch (ValidationException e) {
        rejectProducer.send(new ProducerRecord<>("command-rejections", key, e.toEvent()));
    }
});
```

### Read model projection

```java
KStream<String, DomainEvent> events = builder.stream("domain-events");
events.foreach((key, event) -> {
    switch (event.getType()) {
        case "OrderCreated" -> elasticsearchClient.index(event);
        case "OrderShipped" -> elasticsearchClient.update(event);
        case "OrderCancelled" -> elasticsearchClient.delete(event);
    }
});
```

### Consistency

- Write side: strongly consistent (single writer per aggregate via partition key).
- Read side: eventually consistent (consumer lag = staleness).
- Monitor consumer lag on read-model consumers to measure consistency delay.

---

## Outbox Pattern with Debezium

### Problem

Writing to DB + publishing to Kafka isn't atomic. The outbox pattern solves this by writing events to a DB table in the same transaction.

### Outbox table schema

```sql
CREATE TABLE outbox (
    id            UUID PRIMARY KEY,
    aggregate_type VARCHAR(255) NOT NULL,
    aggregate_id   VARCHAR(255) NOT NULL,
    event_type     VARCHAR(255) NOT NULL,
    payload        JSONB NOT NULL,
    created_at     TIMESTAMP DEFAULT NOW()
);
```

### Application code

```python
def create_order(db_session, order_data):
    order = Order(**order_data)
    db_session.add(order)

    outbox_event = OutboxEvent(
        aggregate_type="Order",
        aggregate_id=str(order.id),
        event_type="OrderCreated",
        payload=order.to_event_payload()
    )
    db_session.add(outbox_event)
    db_session.commit()  # single atomic transaction
```

### Debezium connector config

```json
{
  "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
  "database.hostname": "postgres",
  "database.port": "5432",
  "database.user": "debezium",
  "database.dbname": "orders",
  "table.include.list": "public.outbox",
  "transforms": "outbox",
  "transforms.outbox.type": "io.debezium.transforms.outbox.EventRouter",
  "transforms.outbox.table.fields.additional.placement": "event_type:header",
  "transforms.outbox.route.by.field": "aggregate_type",
  "transforms.outbox.route.topic.replacement": "${routedByValue}-events"
}
```

The `EventRouter` SMT:
- Routes to topic based on `aggregate_type` → `Order-events`
- Sets message key to `aggregate_id`
- Extracts `payload` as the message value
- Optionally adds `event_type` as a header

### Cleanup

Debezium reads the WAL, so outbox rows can be deleted after capture:

```sql
DELETE FROM outbox WHERE created_at < NOW() - INTERVAL '1 hour';
```

Or use a compacted outbox topic with `log.cleanup.policy=compact` if the outbox table grows too large.
