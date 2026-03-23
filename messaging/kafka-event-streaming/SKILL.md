---
name: kafka-event-streaming
description: |
  Use when user works with Apache Kafka, asks about producers, consumers, consumer groups, partitioning, exactly-once semantics, Kafka Streams, Kafka Connect, topic design, or message serialization (Avro, Protobuf).
  Do NOT use for RabbitMQ, AWS SQS/SNS, Redis pub/sub, or general message queue concepts not Kafka-specific.
---

# Apache Kafka Event Streaming

## Topic Design

### Naming Convention

Use a structured naming scheme: `<domain>.<entity>.<event-type>`.

```
orders.purchase.created
payments.invoice.completed
inventory.stock.updated
```

Avoid dots in individual segments. Use hyphens within segments if needed.

### Partitioning Strategy

- Set partition count based on target consumer parallelism. Each partition maps to at most one consumer in a group.
- Use a meaningful key (user ID, order ID, device ID) to co-locate related events on the same partition for ordering guarantees.
- Plan partition count upfront — increasing partitions later breaks key-based ordering for existing data.
- Start with `num.partitions = 3 × expected consumer count` for headroom.
- Avoid exceeding ~4,000 partitions per broker (impacts leader election and memory).

### Replication Factor

- Set `replication.factor=3` for production. Minimum `min.insync.replicas=2`.
- Never set replication factor higher than the broker count.

```properties
# Topic creation
kafka-topics.sh --create --topic orders.purchase.created \
  --partitions 12 --replication-factor 3 \
  --config min.insync.replicas=2
```

### Retention

- Use time-based retention (`retention.ms`) for event streams — default 7 days.
- Use size-based retention (`retention.bytes`) when disk is the constraint.
- Use `cleanup.policy=compact` for changelog/state topics where only the latest value per key matters.
- Use `cleanup.policy=compact,delete` to compact and also expire old segments.

```properties
retention.ms=604800000          # 7 days
retention.bytes=-1              # unlimited
cleanup.policy=delete           # or compact
```

## Producer Patterns

### Acknowledgment and Durability

```java
Properties props = new Properties();
props.put("bootstrap.servers", "broker1:9092,broker2:9092");
props.put("acks", "all");                              // wait for all ISR
props.put("enable.idempotence", true);                 // deduplicate retries
props.put("max.in.flight.requests.per.connection", 5); // safe with idempotence
props.put("retries", Integer.MAX_VALUE);               // retry indefinitely
props.put("delivery.timeout.ms", 120000);              // overall send timeout
```

| `acks` | Durability | Latency | Use Case |
|--------|-----------|---------|----------|
| `0` | None | Lowest | Metrics, logs (loss acceptable) |
| `1` | Leader only | Low | General use, moderate durability |
| `all` | All ISR | Higher | Financial, critical data |

### Batching and Compression

```properties
batch.size=65536          # 64 KB per partition batch
linger.ms=5               # wait up to 5ms to fill batch
compression.type=lz4      # lz4 for speed, zstd for ratio
buffer.memory=67108864    # 64 MB total buffer
```

- Use `lz4` for low-latency workloads. Use `zstd` for best compression ratio.
- Increase `linger.ms` (5–100ms) for throughput; keep low (0–5ms) for latency.

### Partitioner

- **Default (key hash):** Murmur2 hash of key mod partition count. Deterministic ordering per key.
- **Sticky partitioner (null key):** Batches messages to the same partition until batch is full, then rotates. Improves throughput over round-robin.
- **Custom partitioner:** Implement `org.apache.kafka.clients.producer.Partitioner` for domain-specific routing.

```java
public class RegionPartitioner implements Partitioner {
    public int partition(String topic, Object key, byte[] keyBytes,
                         Object value, byte[] valueBytes, Cluster cluster) {
        String region = extractRegion((String) key);
        int numPartitions = cluster.partitionCountForTopic(topic);
        return Math.abs(region.hashCode()) % numPartitions;
    }
}
```

## Consumer Patterns

### Consumer Groups

- Each partition is assigned to exactly one consumer in a group. Consumers > partitions means idle consumers.
- Use separate consumer groups for independent downstream systems reading the same topic.
- Set `group.id` to a stable, descriptive name: `order-service-processor`.

### Offset Management

```java
props.put("enable.auto.commit", false);  // manual commit for control
props.put("auto.offset.reset", "earliest"); // or "latest"
```

- **Auto commit:** Simple but risks duplicates on crash (commit before processing completes).
- **Manual sync commit:** `consumer.commitSync()` after processing. Blocks but safe.
- **Manual async commit:** `consumer.commitAsync()` for throughput. Use sync on shutdown.

```java
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    for (ConsumerRecord<String, String> record : records) {
        process(record);
    }
    consumer.commitSync(); // commit after successful processing
}
```

### Rebalancing

- **Eager (stop-the-world):** All partitions revoked, then reassigned. Causes processing pause.
- **Cooperative (incremental):** Only affected partitions move. Preferred for production.

```properties
partition.assignment.strategy=org.apache.kafka.clients.consumer.CooperativeStickyAssignor
```

- Use `ConsumerRebalanceListener` to flush state and commit offsets before partitions are revoked.
- Set `session.timeout.ms=45000` and `heartbeat.interval.ms=15000` to avoid spurious rebalances.
- Use `group.instance.id` for static membership to reduce rebalance frequency during rolling deploys.

### Tuning

```properties
max.poll.records=500             # records per poll
max.poll.interval.ms=300000      # max time between polls before rebalance
fetch.min.bytes=1024             # minimum fetch size
fetch.max.wait.ms=500            # max wait for fetch.min.bytes
```

## Exactly-Once Semantics (EOS)

### Idempotent Producer

Enable `enable.idempotence=true`. The broker assigns a Producer ID (PID) and tracks sequence numbers per partition to deduplicate retries. This prevents duplicates within a single producer session.

### Transactional API

Use transactions for atomic writes across multiple partitions and topics, and to commit consumer offsets atomically with produced records.

```java
props.put("transactional.id", "order-processor-1"); // stable across restarts
KafkaProducer<String, String> producer = new KafkaProducer<>(props);
producer.initTransactions();

try {
    producer.beginTransaction();

    for (ConsumerRecord<String, String> record : records) {
        ProducerRecord<String, String> output = transform(record);
        producer.send(output);
    }

    // commit consumer offsets within the transaction
    producer.sendOffsetsToTransaction(offsets, consumerGroupMetadata);
    producer.commitTransaction();
} catch (ProducerFencedException | OutOfOrderSequenceException e) {
    producer.close(); // fatal — cannot recover
} catch (KafkaException e) {
    producer.abortTransaction(); // retry the batch
}
```

### Consumer Isolation

Set consumers to `isolation.level=read_committed` to skip uncommitted/aborted transactional messages.

### EOS Limitations

- Covers Kafka-to-Kafka pipelines. External sinks require idempotent writes or the outbox pattern.
- Transactions add latency (~10-50ms per commit). Size transaction batches appropriately.
- Each `transactional.id` must be unique per producer instance.

## Serialization

### Avro + Schema Registry

```java
props.put("key.serializer", "io.confluent.kafka.serializers.KafkaAvroSerializer");
props.put("value.serializer", "io.confluent.kafka.serializers.KafkaAvroSerializer");
props.put("schema.registry.url", "http://schema-registry:8081");
```

- Register schemas in Schema Registry. Set compatibility to `BACKWARD` (default) for safe evolution.
- Add fields with defaults. Never remove required fields or change types.
- Use `subject.name.strategy=TopicRecordNameStrategy` for multiple event types per topic.

### Protobuf

```java
props.put("value.serializer", "io.confluent.kafka.serializers.protobuf.KafkaProtobufSerializer");
props.put("value.deserializer", "io.confluent.kafka.serializers.protobuf.KafkaProtobufDeserializer");
```

- Prefer Protobuf for polyglot environments. Smaller wire size than Avro for nested structures.
- Use field numbers for backward/forward compatibility. Never reuse deleted field numbers.

### JSON Schema

- Use `JsonSchemaSerializer` / `JsonSchemaDeserializer` with Schema Registry for schema validation.
- JSON is human-readable but larger on the wire. Use for debugging or low-throughput topics.
- Avoid raw JSON without schema — no contract enforcement, no evolution guarantees.

## Kafka Streams

### KStream vs KTable

- **KStream:** Unbounded stream of immutable events. Each record is an independent fact. Use for event processing, filtering, mapping.
- **KTable:** Changelog stream keyed by record key. Latest value per key. Use for aggregations, stateful lookups, and joins.

```java
StreamsBuilder builder = new StreamsBuilder();

KStream<String, Order> orders = builder.stream("orders",
    Consumed.with(Serdes.String(), orderSerde));

KTable<String, Customer> customers = builder.table("customers",
    Consumed.with(Serdes.String(), customerSerde));

// Enrich orders with customer data
KStream<String, EnrichedOrder> enriched = orders.join(customers,
    (order, customer) -> new EnrichedOrder(order, customer));

enriched.to("enriched-orders", Produced.with(Serdes.String(), enrichedSerde));
```

### Windowing

| Window Type | Behavior | Use Case |
|-------------|----------|----------|
| Tumbling | Fixed, non-overlapping | Hourly aggregations |
| Hopping | Fixed, overlapping | Rolling 5-min avg, every 1 min |
| Sliding | Event-triggered | "Events within 10min of each other" |
| Session | Gap-based | User activity sessions |

```java
KTable<Windowed<String>, Long> counts = orders
    .groupByKey()
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(5)))
    .count(Materialized.as("order-counts-store"));
```

Set grace periods for late-arriving data: `TimeWindows.ofSizeAndGrace(Duration.ofMinutes(5), Duration.ofSeconds(30))`.

### State Stores

- Backed by RocksDB locally + changelog topics in Kafka for fault tolerance.
- Name stores explicitly with `Materialized.as("store-name")` for interactive queries.
- Monitor RocksDB memory usage. Tune `rocksdb.config.setter` for large state.
- State rebuilds from changelog on restart. Keep changelog topics compacted.

### Interactive Queries

```java
ReadOnlyKeyValueStore<String, Long> store =
    streams.store(StoreQueryParameters.fromNameAndType(
        "order-counts-store", QueryableStoreTypes.keyValueStore()));
Long count = store.get("customer-123");
```

## Kafka Connect

### Source and Sink Connectors

```json
{
  "name": "postgres-source",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres",
    "database.port": "5432",
    "database.dbname": "orders",
    "table.include.list": "public.orders",
    "topic.prefix": "cdc",
    "plugin.name": "pgoutput"
  }
}
```

- Use Debezium for CDC (change data capture) from databases.
- Set `tasks.max` to match the number of partitions or tables for parallelism.

### Single Message Transforms (SMTs)

```json
"transforms": "unwrap,route",
"transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
"transforms.route.type": "org.apache.kafka.connect.transforms.RegexRouter",
"transforms.route.regex": "cdc\\.public\\.(.*)",
"transforms.route.replacement": "$1.events"
```

Keep transforms lightweight. Offload complex transformations to Kafka Streams or ksqlDB.

### Dead Letter Queue (Connect)

```json
"errors.tolerance": "all",
"errors.deadletterqueue.topic.name": "connect-dlq",
"errors.deadletterqueue.context.headers.enable": true,
"errors.deadletterqueue.topic.replication.factor": 3,
"errors.log.enable": true,
"errors.log.include.messages": true
```

Monitor DLQ topic size. Alert when messages appear. Build a consumer to inspect and replay failed records.

## Error Handling

### Producer Retries

- Set `retries=MAX_INT` with `delivery.timeout.ms` as the overall deadline.
- Use `retry.backoff.ms=100` for exponential backoff (handled internally).
- Idempotent producers make retries safe against duplicates.

### Consumer Error Strategies

```
1. Retry in-place    → re-process the record N times with backoff
2. Dead letter topic → produce failed record to DLT, commit offset, continue
3. Pause partition   → pause consumption of the failing partition, alert, resume after fix
```

### Dead Letter Topics (Application-Level)

```java
try {
    process(record);
} catch (DeserializationException e) {
    // Poison pill — cannot deserialize. Send raw bytes to DLT.
    producer.send(new ProducerRecord<>("orders.dlt",
        record.key(), record.value()));
} catch (TransientException e) {
    // Retry with backoff
    retry(record, 3, Duration.ofSeconds(1));
} catch (Exception e) {
    producer.send(new ProducerRecord<>("orders.dlt",
        record.key(), record.value()));
}
consumer.commitSync();
```

### Poison Pill Handling

- Use `ErrorHandlingDeserializer` wrapper to catch deserialization failures without crashing the consumer.

```properties
value.deserializer=org.apache.kafka.common.serialization.ErrorHandlingDeserializer
value.deserializer.inner=io.confluent.kafka.serializers.KafkaAvroDeserializer
```

- Log the bad record, send to DLT, and continue processing.

## Monitoring

### Key Metrics

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| Consumer lag (records) | `records-lag-max` | > 10,000 sustained 5 min |
| Under-replicated partitions | `UnderReplicatedPartitions` | > 0 |
| ISR shrink rate | `IsrShrinksPerSec` | > 0 sustained |
| Request latency (p99) | `RequestLatencyMs` | > 100ms |
| Active controller count | `ActiveControllerCount` | != 1 |
| Offline partitions | `OfflinePartitionsCount` | > 0 |
| Log flush latency | `LogFlushRateAndTimeMs` | p99 > 500ms |
| Network handler idle | `NetworkProcessorAvgIdlePercent` | < 0.3 |

### Consumer Lag Monitoring

```bash
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --describe --group order-service-processor
```

- Use Burrow or kafka_exporter + Prometheus + Grafana for continuous lag tracking.
- Alert on sustained lag, not spikes. Set time-based SLAs (e.g., lag < 30 seconds).

### Broker Health

- Monitor disk I/O, CPU, and JVM heap usage per broker.
- Track `UnderMinIsrPartitionCount` — indicates risk of data loss.
- Watch `LeaderElectionRateAndTimeMs` for cluster instability.

## Operational Patterns

### Topic Compaction

- Use `cleanup.policy=compact` for state topics (user profiles, config, CDC snapshots).
- Set `min.compaction.lag.ms` to keep recent duplicates available for consumers that need history.
- Set `delete.retention.ms` to control how long tombstones (null-value records) are retained.

```properties
cleanup.policy=compact
min.cleanable.dirty.ratio=0.5
min.compaction.lag.ms=3600000    # 1 hour
delete.retention.ms=86400000    # 1 day
```

### Partition Reassignment

```bash
# Generate reassignment plan
kafka-reassign-partitions.sh --bootstrap-server broker:9092 \
  --generate --topics-to-move-json-file topics.json \
  --broker-list "1,2,3,4"

# Execute with throttle to limit replication bandwidth
kafka-reassign-partitions.sh --bootstrap-server broker:9092 \
  --execute --reassignment-json-file plan.json \
  --throttle 50000000   # 50 MB/s
```

- Always throttle reassignment to avoid broker overload.
- Verify completion with `--verify` before removing throttle.
- Prefer Cruise Control or Confluent Auto Data Balancer for automated rebalancing.

### Rolling Upgrades

1. Update broker config, restart one broker at a time.
2. Wait for all replicas to rejoin ISR before proceeding to the next broker.
3. Set `inter.broker.protocol.version` and `log.message.format.version` to the old version during the upgrade.
4. After all brokers are upgraded, bump protocol and message format versions.
5. Monitor `UnderReplicatedPartitions` — must be 0 before moving to the next broker.

## Common Anti-Patterns

### Too Many Partitions

- Each partition consumes memory, file handles, and increases leader election time.
- More partitions = longer recovery time after broker failure.
- Rule of thumb: aim for partitions that each sustain ≥1 MB/s throughput.

### Large Messages

- Default `max.message.bytes` is 1 MB. Increasing it degrades broker and consumer performance.
- Store large payloads in object storage (S3, GCS). Put the reference URL in the Kafka message.
- If unavoidable, enable compression and increase `replica.fetch.max.bytes` and `fetch.message.max.bytes` on brokers and consumers.

### Missing Keys

- Null keys use the sticky partitioner — no ordering guarantee across batches.
- Always set a meaningful key when ordering matters. Choose keys with even cardinality to avoid hot partitions.

### Other Anti-Patterns

- **Using Kafka as a database:** Kafka is an append-only log, not a query engine. Use KTables or external stores for lookups.
- **Polling without backpressure:** Always set `max.poll.records` and `max.poll.interval.ms` to prevent consumer eviction.
- **Ignoring schema evolution:** Changing schemas without registry enforcement breaks downstream consumers silently.
- **Single consumer group for all services:** Use separate groups so each service tracks its own offsets independently.
- **Over-relying on auto-commit:** Leads to message loss or duplication. Prefer manual commit for critical workloads.
