# Advanced Kafka Patterns — Deep-Dive Reference

A comprehensive, practical guide to advanced Apache Kafka patterns covering exactly-once semantics, stream processing, event-driven architectures, and architectural decision-making.

---

## Table of Contents

1. [Exactly-Once Semantics (EOS)](#1-exactly-once-semantics-eos)
2. [Transactional Producers](#2-transactional-producers)
3. [Idempotent Consumers](#3-idempotent-consumers)
4. [Kafka Streams Interactive Queries](#4-kafka-streams-interactive-queries)
5. [KTable-KTable Joins](#5-ktable-ktable-joins)
6. [Session Windows](#6-session-windows)
7. [Tumbling vs Hopping Windows](#7-tumbling-vs-hopping-windows)
8. [GlobalKTable](#8-globalktable)
9. [Processor API vs DSL](#9-processor-api-vs-dsl)
10. [Dead Letter Queues](#10-dead-letter-queues)
11. [Event Sourcing with Kafka](#11-event-sourcing-with-kafka)
12. [CQRS Patterns](#12-cqrs-patterns)
13. [Compacted Topics for State](#13-compacted-topics-for-state)
14. [Kafka vs Alternatives Decision Matrix](#14-kafka-vs-alternatives-decision-matrix)

---

## 1. Exactly-Once Semantics (EOS)

### Overview

Exactly-once semantics (EOS) guarantees that each record is processed exactly once, even in the presence of failures. Kafka achieves EOS through three cooperating mechanisms:

| Layer | Mechanism | Guarantees |
|---|---|---|
| Producer | Idempotent producer | No duplicate writes within a single partition |
| Producer | Transactional producer | Atomic writes across multiple partitions |
| Consumer | `read_committed` isolation | Only reads committed (non-aborted) records |

### Full EOS Pipeline

#### Step 1: Idempotent Producer

The idempotent producer assigns a Producer ID (PID) and sequence number to every record. The broker deduplicates records with the same PID + sequence for a given partition.

```java
Properties props = new Properties();
props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());

// Enable idempotence — this is the foundation of EOS
props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");

// Idempotence requires these settings (auto-configured when enable.idempotence=true):
// acks=all, retries=Integer.MAX_VALUE, max.in.flight.requests.per.connection<=5
props.put(ProducerConfig.ACKS_CONFIG, "all");
props.put(ProducerConfig.RETRIES_CONFIG, Integer.MAX_VALUE);
props.put(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 5);

KafkaProducer<String, String> producer = new KafkaProducer<>(props);
```

> **Key insight:** Idempotence alone only prevents duplicates within a single producer session and partition. For cross-partition atomicity, you need transactions.

#### Step 2: Transactional Producer

```java
Properties props = new Properties();
props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");

// Transactional ID must be unique per producer instance and stable across restarts
props.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, "order-processing-txn-1");

KafkaProducer<String, String> producer = new KafkaProducer<>(props);

// Must be called once before any transactional operations
producer.initTransactions();

try {
    producer.beginTransaction();

    // Write to multiple topics/partitions atomically
    producer.send(new ProducerRecord<>("orders", "key1", "order-created"));
    producer.send(new ProducerRecord<>("inventory", "sku-42", "reserved"));
    producer.send(new ProducerRecord<>("audit-log", "key1", "order-key1-created"));

    producer.commitTransaction();
} catch (ProducerFencedException | OutOfOrderSequenceException | AuthorizationException e) {
    // Fatal errors — cannot recover, must close producer
    producer.close();
} catch (KafkaException e) {
    // Abort and retry
    producer.abortTransaction();
}
```

#### Step 3: Read-Committed Consumer

```java
Properties consumerProps = new Properties();
consumerProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
consumerProps.put(ConsumerConfig.GROUP_ID_CONFIG, "order-consumer-group");
consumerProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
consumerProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());

// Only read records from committed transactions
consumerProps.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");

// Disable auto-commit — offsets are committed as part of the transaction
consumerProps.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");

KafkaConsumer<String, String> consumer = new KafkaConsumer<>(consumerProps);
consumer.subscribe(Collections.singletonList("orders"));
```

#### Complete Consume-Transform-Produce Loop

```java
// Producer side
Properties prodProps = new Properties();
prodProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
prodProps.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, "consume-transform-produce-1");
prodProps.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");
prodProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
prodProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());

KafkaProducer<String, String> producer = new KafkaProducer<>(prodProps);
producer.initTransactions();

// Consumer side
Properties consProps = new Properties();
consProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
consProps.put(ConsumerConfig.GROUP_ID_CONFIG, "eos-group");
consProps.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");
consProps.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
consProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
consProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());

KafkaConsumer<String, String> consumer = new KafkaConsumer<>(consProps);
consumer.subscribe(Collections.singletonList("input-topic"));

while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    if (records.isEmpty()) continue;

    producer.beginTransaction();
    try {
        for (ConsumerRecord<String, String> record : records) {
            // Transform
            String transformed = record.value().toUpperCase();
            producer.send(new ProducerRecord<>("output-topic", record.key(), transformed));
        }

        // Commit consumer offsets as part of the transaction
        Map<TopicPartition, OffsetAndMetadata> offsets = new HashMap<>();
        for (TopicPartition partition : records.partitions()) {
            List<ConsumerRecord<String, String>> partRecords = records.records(partition);
            long lastOffset = partRecords.get(partRecords.size() - 1).offset();
            offsets.put(partition, new OffsetAndMetadata(lastOffset + 1));
        }
        producer.sendOffsetsToTransaction(offsets, consumer.groupMetadata());
        producer.commitTransaction();
    } catch (Exception e) {
        producer.abortTransaction();
    }
}
```

### Best Practices for EOS

- **`transactional.id` must be stable** across restarts but unique per producer instance. Use a naming scheme like `app-name-partition-N`.
- **Performance impact:** EOS adds ~3-5% overhead. Transaction markers consume offset space.
- **`transaction.timeout.ms`:** Default is 60s. Set it lower than `max.poll.interval.ms` to avoid consumer rebalances during long transactions.
- **Kafka Streams simplifies EOS:** Set `processing.guarantee=exactly_once_v2` (KIP-447) for automatic EOS in streams apps.

---

## 2. Transactional Producers

### Transaction Lifecycle

```
initTransactions() → [beginTransaction() → send() / sendOffsetsToTransaction() → commitTransaction() | abortTransaction()]*
```

### API Deep-Dive

#### `initTransactions()`

Called once per producer lifetime. Performs two critical actions:
1. Registers the `transactional.id` with the transaction coordinator.
2. **Fences zombie producers** — any prior producer with the same `transactional.id` is fenced off (receives `ProducerFencedException`).

```java
KafkaProducer<String, String> producer = new KafkaProducer<>(props);

// Blocks until the transaction coordinator acknowledges registration.
// Aborts any pending transactions from a previous instance with the same transactional.id.
producer.initTransactions();
```

#### `beginTransaction()`

Signals the start of a new atomic unit of work. No records are visible to `read_committed` consumers until `commitTransaction()`.

```java
producer.beginTransaction();
// All sends after this are part of the transaction
```

#### `sendOffsetsToTransaction()`

Atomically commits consumer offsets as part of the transaction. This is the key to consume-transform-produce EOS.

```java
Map<TopicPartition, OffsetAndMetadata> offsets = Map.of(
    new TopicPartition("input-topic", 0), new OffsetAndMetadata(42L),
    new TopicPartition("input-topic", 1), new OffsetAndMetadata(108L)
);

// The consumer group metadata links offsets to the correct consumer group
producer.sendOffsetsToTransaction(offsets, consumer.groupMetadata());
```

#### `commitTransaction()`

Makes all records and offset commits in the current transaction visible atomically.

```java
producer.commitTransaction();
// All records are now visible to read_committed consumers
```

#### `abortTransaction()`

Discards all records in the current transaction. Consumers with `read_committed` will never see them.

```java
try {
    producer.beginTransaction();
    producer.send(new ProducerRecord<>("topic", "key", "value"));
    // Something goes wrong...
    throw new RuntimeException("Processing failure");
} catch (RuntimeException e) {
    producer.abortTransaction();
    // Transaction markers written, records discarded
}
```

### Complete Transactional Producer Example

```java
public class TransactionalOrderProcessor {
    private final KafkaProducer<String, String> producer;
    private final KafkaConsumer<String, String> consumer;

    public TransactionalOrderProcessor() {
        Properties prodProps = new Properties();
        prodProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "broker1:9092,broker2:9092");
        prodProps.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, "order-processor-0");
        prodProps.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
        prodProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        prodProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        // Reduce transaction timeout for faster failure detection
        prodProps.put(ProducerConfig.TRANSACTION_TIMEOUT_CONFIG, 30_000);

        this.producer = new KafkaProducer<>(prodProps);
        this.producer.initTransactions();

        Properties consProps = new Properties();
        consProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "broker1:9092,broker2:9092");
        consProps.put(ConsumerConfig.GROUP_ID_CONFIG, "order-processors");
        consProps.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");
        consProps.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);
        consProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        consProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        consProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);

        this.consumer = new KafkaConsumer<>(consProps);
        this.consumer.subscribe(List.of("raw-orders"));
    }

    public void run() {
        while (true) {
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(200));
            if (records.isEmpty()) continue;

            producer.beginTransaction();
            try {
                Map<TopicPartition, OffsetAndMetadata> offsets = new HashMap<>();
                for (ConsumerRecord<String, String> record : records) {
                    // Business logic: validate, enrich, route
                    Order order = Order.fromJson(record.value());
                    if (order.isValid()) {
                        producer.send(new ProducerRecord<>("validated-orders",
                            order.getId(), order.toJson()));
                        producer.send(new ProducerRecord<>("inventory-reservations",
                            order.getSkuId(), order.reservationJson()));
                    } else {
                        producer.send(new ProducerRecord<>("rejected-orders",
                            order.getId(), order.toJson()));
                    }
                }

                // Collect offsets for all partitions we consumed from
                for (TopicPartition partition : records.partitions()) {
                    List<ConsumerRecord<String, String>> partRecords = records.records(partition);
                    long lastOffset = partRecords.get(partRecords.size() - 1).offset();
                    offsets.put(partition, new OffsetAndMetadata(lastOffset + 1));
                }

                producer.sendOffsetsToTransaction(offsets, consumer.groupMetadata());
                producer.commitTransaction();
            } catch (ProducerFencedException e) {
                // Another instance with the same transactional.id took over — shut down
                log.error("Fenced by newer producer instance", e);
                producer.close();
                consumer.close();
                throw e;
            } catch (KafkaException e) {
                log.warn("Transaction failed, aborting", e);
                producer.abortTransaction();
            }
        }
    }
}
```

### Error Handling Matrix

| Exception | Recoverable? | Action |
|---|---|---|
| `ProducerFencedException` | No | Close producer, shut down |
| `OutOfOrderSequenceException` | No | Close producer, shut down |
| `AuthorizationException` | No | Close producer, fix ACLs |
| `KafkaException` (generic) | Yes | Abort transaction, retry |
| `TimeoutException` | Yes | Abort transaction, retry |

---

## 3. Idempotent Consumers

Even with EOS on the producer side, consumer processing might not be idempotent if it involves external systems (databases, APIs, caches). Here are strategies to achieve end-to-end idempotent processing.

### Strategy 1: Idempotent DB Writes (Upsert)

Use database upsert (INSERT ... ON CONFLICT) to make writes naturally idempotent.

```java
public class UpsertConsumer {
    private final DataSource dataSource;

    public void processRecord(ConsumerRecord<String, String> record) {
        Order order = Order.fromJson(record.value());

        String sql = """
            INSERT INTO orders (order_id, customer_id, amount, status, updated_at)
            VALUES (?, ?, ?, ?, NOW())
            ON CONFLICT (order_id)
            DO UPDATE SET
                customer_id = EXCLUDED.customer_id,
                amount = EXCLUDED.amount,
                status = EXCLUDED.status,
                updated_at = NOW()
            """;

        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, order.getId());
            ps.setString(2, order.getCustomerId());
            ps.setBigDecimal(3, order.getAmount());
            ps.setString(4, order.getStatus());
            ps.executeUpdate();
        }
    }
}
```

### Strategy 2: Deduplication Table

Track processed message IDs in a separate dedup table, checking before processing.

```sql
CREATE TABLE processed_messages (
    message_id  VARCHAR(255) PRIMARY KEY,
    topic       VARCHAR(255) NOT NULL,
    partition   INT NOT NULL,
    offset_val  BIGINT NOT NULL,
    processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- TTL index: auto-expire old entries
    INDEX idx_processed_at (processed_at)
);
```

```java
public class DedupConsumer {
    private final DataSource dataSource;

    public void processRecord(ConsumerRecord<String, String> record) throws SQLException {
        String messageId = extractMessageId(record); // from header or key

        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            try {
                // Check-and-insert in a single atomic operation
                String checkSql = """
                    INSERT INTO processed_messages (message_id, topic, partition, offset_val)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT (message_id) DO NOTHING
                    """;
                PreparedStatement checkPs = conn.prepareStatement(checkSql);
                checkPs.setString(1, messageId);
                checkPs.setString(2, record.topic());
                checkPs.setInt(3, record.partition());
                checkPs.setLong(4, record.offset());
                int inserted = checkPs.executeUpdate();

                if (inserted == 0) {
                    // Already processed — skip
                    conn.rollback();
                    return;
                }

                // Process the record (business logic)
                processBusinessLogic(record, conn);

                conn.commit();
            } catch (Exception e) {
                conn.rollback();
                throw e;
            }
        }
    }

    private String extractMessageId(ConsumerRecord<String, String> record) {
        // Option 1: From record header
        Header idHeader = record.headers().lastHeader("message-id");
        if (idHeader != null) return new String(idHeader.value());

        // Option 2: Composite key from topic-partition-offset
        return record.topic() + "-" + record.partition() + "-" + record.offset();
    }
}
```

### Strategy 3: Consumer-Side Offset Tracking in External Store

Store consumed offsets alongside business data in the same transactional store, bypassing Kafka's `__consumer_offsets` topic entirely.

```java
public class ExternalOffsetConsumer {
    private final DataSource dataSource;
    private final KafkaConsumer<String, String> consumer;

    public void run() {
        // On startup, seek to the last committed offset from the DB
        consumer.subscribe(List.of("events"), new ConsumerRebalanceListener() {
            @Override
            public void onPartitionsAssigned(Collection<TopicPartition> partitions) {
                for (TopicPartition tp : partitions) {
                    long offset = getOffsetFromDB(tp);
                    if (offset >= 0) {
                        consumer.seek(tp, offset + 1);
                    } else {
                        consumer.seekToBeginning(Collections.singleton(tp));
                    }
                }
            }

            @Override
            public void onPartitionsRevoked(Collection<TopicPartition> partitions) {
                // Commit any pending work
            }
        });

        while (true) {
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
            for (ConsumerRecord<String, String> record : records) {
                processAndStoreOffset(record);
            }
        }
    }

    private void processAndStoreOffset(ConsumerRecord<String, String> record) {
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            try {
                // Business logic write
                String bizSql = "INSERT INTO events (id, data) VALUES (?, ?)";
                PreparedStatement bizPs = conn.prepareStatement(bizSql);
                bizPs.setString(1, record.key());
                bizPs.setString(2, record.value());
                bizPs.executeUpdate();

                // Store offset in the same transaction
                String offsetSql = """
                    INSERT INTO kafka_offsets (topic, partition_id, committed_offset)
                    VALUES (?, ?, ?)
                    ON CONFLICT (topic, partition_id)
                    DO UPDATE SET committed_offset = EXCLUDED.committed_offset
                    """;
                PreparedStatement offsetPs = conn.prepareStatement(offsetSql);
                offsetPs.setString(1, record.topic());
                offsetPs.setInt(2, record.partition());
                offsetPs.setLong(3, record.offset());
                offsetPs.executeUpdate();

                conn.commit();
            } catch (Exception e) {
                conn.rollback();
                throw e;
            }
        } catch (SQLException e) {
            throw new RuntimeException("Failed to process record", e);
        }
    }

    private long getOffsetFromDB(TopicPartition tp) {
        try (Connection conn = dataSource.getConnection()) {
            String sql = "SELECT committed_offset FROM kafka_offsets WHERE topic = ? AND partition_id = ?";
            PreparedStatement ps = conn.prepareStatement(sql);
            ps.setString(1, tp.topic());
            ps.setInt(2, tp.partition());
            ResultSet rs = ps.executeQuery();
            return rs.next() ? rs.getLong("committed_offset") : -1;
        } catch (SQLException e) {
            throw new RuntimeException(e);
        }
    }
}
```

### Comparison of Strategies

| Strategy | Complexity | Performance | Use When |
|---|---|---|---|
| Upsert | Low | High | Writes are naturally idempotent (key-based) |
| Dedup Table | Medium | Medium | Need explicit dedup with TTL cleanup |
| External Offset | High | Medium | Require exactly-once with external DB |

---

## 4. Kafka Streams Interactive Queries

Interactive queries let you query the local state stores of a running Kafka Streams application without consuming from the output topic.

### Querying Local State Stores

```java
// Build the topology
StreamsBuilder builder = new StreamsBuilder();
KTable<String, Long> wordCounts = builder
    .stream("text-input", Consumed.with(Serdes.String(), Serdes.String()))
    .flatMapValues(value -> Arrays.asList(value.toLowerCase().split("\\W+")))
    .groupBy((key, value) -> value, Grouped.with(Serdes.String(), Serdes.String()))
    .count(Materialized.<String, Long, KeyValueStore<Bytes, byte[]>>as("word-count-store")
        .withKeySerde(Serdes.String())
        .withValueSerde(Serdes.Long()));

Properties props = new Properties();
props.put(StreamsConfig.APPLICATION_ID_CONFIG, "word-count-app");
props.put(StreamsConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
// Required for interactive queries across instances
props.put(StreamsConfig.APPLICATION_SERVER_CONFIG, "localhost:8080");

KafkaStreams streams = new KafkaStreams(builder.build(), props);
streams.start();
```

### StoreQueryParameters and ReadOnlyKeyValueStore

```java
// Query a specific key from the local store
StoreQueryParameters<ReadOnlyKeyValueStore<String, Long>> storeParams =
    StoreQueryParameters.fromNameAndType(
        "word-count-store",
        QueryableStoreTypes.keyValueStore()
    );

ReadOnlyKeyValueStore<String, Long> store = streams.store(storeParams);

// Single key lookup
Long count = store.get("kafka");

// Range scan
KeyValueIterator<String, Long> range = store.range("a", "z");
while (range.hasNext()) {
    KeyValue<String, Long> entry = range.next();
    System.out.printf("%s: %d%n", entry.key, entry.value);
}
range.close();

// Approximate number of entries
long approxCount = store.approximateNumEntries();

// Iterate all entries
KeyValueIterator<String, Long> all = store.all();
// ...
all.close();
```

### ReadOnlyWindowStore

```java
// For windowed aggregations
KTable<Windowed<String>, Long> windowedCounts = builder
    .stream("events", Consumed.with(Serdes.String(), Serdes.String()))
    .groupByKey()
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(5)))
    .count(Materialized.as("windowed-count-store"));

// Query the window store
StoreQueryParameters<ReadOnlyWindowStore<String, Long>> windowParams =
    StoreQueryParameters.fromNameAndType(
        "windowed-count-store",
        QueryableStoreTypes.windowStore()
    );

ReadOnlyWindowStore<String, Long> windowStore = streams.store(windowParams);

// Fetch all windows for a key within a time range
Instant from = Instant.now().minus(Duration.ofHours(1));
Instant to = Instant.now();
WindowStoreIterator<Long> windowIter = windowStore.fetch("user-123", from, to);
while (windowIter.hasNext()) {
    KeyValue<Long, Long> windowEntry = windowIter.next();
    Instant windowStart = Instant.ofEpochMilli(windowEntry.key);
    Long windowCount = windowEntry.value;
    System.out.printf("Window [%s]: %d%n", windowStart, windowCount);
}
windowIter.close();
```

### Full REST Endpoint Example (Javalin)

```java
import io.javalin.Javalin;
import io.javalin.http.Context;

public class InteractiveQueryServer {
    private final KafkaStreams streams;
    private final Javalin app;

    public InteractiveQueryServer(KafkaStreams streams, int port) {
        this.streams = streams;
        this.app = Javalin.create().start(port);

        // Single key lookup
        app.get("/api/words/{word}", this::getWordCount);

        // All entries
        app.get("/api/words", this::getAllWordCounts);

        // Metadata: which instance hosts a given key
        app.get("/api/instances/{storeName}/{key}", this::getHostForKey);

        // Windowed query
        app.get("/api/windows/{key}", this::getWindowedCounts);
    }

    private void getWordCount(Context ctx) {
        String word = ctx.pathParam("word");

        // Check if this instance owns the key
        KeyQueryMetadata metadata = streams.queryMetadataForKey(
            "word-count-store", word, Serdes.String().serializer());

        if (metadata.equals(KeyQueryMetadata.NOT_AVAILABLE)) {
            ctx.status(503).result("Store not available (rebalancing?)");
            return;
        }

        HostInfo activeHost = metadata.activeHost();
        String thisHost = "localhost"; // from APPLICATION_SERVER_CONFIG
        int thisPort = 8080;

        if (activeHost.host().equals(thisHost) && activeHost.port() == thisPort) {
            // Key is local — query directly
            ReadOnlyKeyValueStore<String, Long> store = streams.store(
                StoreQueryParameters.fromNameAndType(
                    "word-count-store", QueryableStoreTypes.keyValueStore()));
            Long count = store.get(word);
            ctx.json(Map.of("word", word, "count", count != null ? count : 0));
        } else {
            // Key is on another instance — proxy the request
            String remoteUrl = String.format("http://%s:%d/api/words/%s",
                activeHost.host(), activeHost.port(), word);
            // Use HTTP client to fetch from remote instance
            ctx.redirect(remoteUrl);
        }
    }

    private void getAllWordCounts(Context ctx) {
        ReadOnlyKeyValueStore<String, Long> store = streams.store(
            StoreQueryParameters.fromNameAndType(
                "word-count-store", QueryableStoreTypes.keyValueStore()));

        Map<String, Long> results = new HashMap<>();
        try (KeyValueIterator<String, Long> iter = store.all()) {
            while (iter.hasNext()) {
                KeyValue<String, Long> entry = iter.next();
                results.put(entry.key, entry.value);
            }
        }
        ctx.json(results);
    }

    private void getHostForKey(Context ctx) {
        String storeName = ctx.pathParam("storeName");
        String key = ctx.pathParam("key");

        KeyQueryMetadata metadata = streams.queryMetadataForKey(
            storeName, key, Serdes.String().serializer());

        ctx.json(Map.of(
            "activeHost", metadata.activeHost().host() + ":" + metadata.activeHost().port(),
            "standbyHosts", metadata.standbyHosts().stream()
                .map(h -> h.host() + ":" + h.port())
                .collect(Collectors.toList())
        ));
    }

    private void getWindowedCounts(Context ctx) {
        String key = ctx.pathParam("key");
        long fromMs = ctx.queryParamAsClass("from", Long.class).getOrDefault(
            Instant.now().minus(Duration.ofHours(1)).toEpochMilli());
        long toMs = ctx.queryParamAsClass("to", Long.class).getOrDefault(
            Instant.now().toEpochMilli());

        ReadOnlyWindowStore<String, Long> store = streams.store(
            StoreQueryParameters.fromNameAndType(
                "windowed-count-store", QueryableStoreTypes.windowStore()));

        List<Map<String, Object>> windows = new ArrayList<>();
        try (WindowStoreIterator<Long> iter =
                 store.fetch(key, Instant.ofEpochMilli(fromMs), Instant.ofEpochMilli(toMs))) {
            while (iter.hasNext()) {
                KeyValue<Long, Long> entry = iter.next();
                windows.add(Map.of(
                    "windowStart", Instant.ofEpochMilli(entry.key).toString(),
                    "count", entry.value
                ));
            }
        }
        ctx.json(Map.of("key", key, "windows", windows));
    }
}
```

### Best Practices

- **Always close iterators** — use try-with-resources to avoid resource leaks.
- **Handle `InvalidStateStoreException`** — occurs during rebalancing; retry with backoff.
- **Set `APPLICATION_SERVER_CONFIG`** — required for cross-instance query routing.
- **Use standby replicas** (`num.standby.replicas`) for faster failover and local reads.

---

## 5. KTable-KTable Joins

### Foreign Key Joins

Foreign key joins (introduced in Kafka Streams 2.4) allow joining two KTables where the join key of the left table differs from its primary key.

```java
StreamsBuilder builder = new StreamsBuilder();

// Orders keyed by orderId
KTable<String, Order> orders = builder.table("orders",
    Consumed.with(Serdes.String(), orderSerde),
    Materialized.as("orders-store"));

// Customers keyed by customerId
KTable<String, Customer> customers = builder.table("customers",
    Consumed.with(Serdes.String(), customerSerde),
    Materialized.as("customers-store"));

// Foreign key join: Order.customerId → Customer.customerId
KTable<String, EnrichedOrder> enrichedOrders = orders.join(
    customers,
    order -> order.getCustomerId(),  // Foreign key extractor
    (order, customer) -> new EnrichedOrder(order, customer),  // Value joiner
    Materialized.<String, EnrichedOrder, KeyValueStore<Bytes, byte[]>>as("enriched-orders")
        .withKeySerde(Serdes.String())
        .withValueSerde(enrichedOrderSerde)
);
```

### Inner Join

Both sides must have a matching key. If either side is missing or tombstoned, the result is removed.

```java
KTable<String, UserProfile> profiles = builder.table("user-profiles");
KTable<String, UserPreferences> preferences = builder.table("user-preferences");

// Inner join: only users with BOTH profile and preferences
KTable<String, CombinedUser> combined = profiles.join(
    preferences,
    (profile, prefs) -> new CombinedUser(profile, prefs)
);
```

### Left Join

All records from the left table are preserved. If no match exists on the right, the right value is `null`.

```java
// Left join: all profiles, preferences may be null
KTable<String, CombinedUser> combined = profiles.leftJoin(
    preferences,
    (profile, prefs) -> new CombinedUser(profile, prefs) // prefs can be null
);
```

### Outer Join

Records from both tables are preserved. Either side can be `null`.

```java
// Outer join: all profiles and all preferences
KTable<String, CombinedUser> combined = profiles.outerJoin(
    preferences,
    (profile, prefs) -> new CombinedUser(profile, prefs)
    // Either profile or prefs can be null, but not both
);
```

### Join Semantics Table

| Join Type | Left Record Exists | Right Record Exists | Result |
|---|---|---|---|
| Inner | Yes | Yes | Joined record emitted |
| Inner | Yes | No | No output / tombstone |
| Left | Yes | Yes | Joined record emitted |
| Left | Yes | No | Left value + null right |
| Outer | Yes | No | Left value + null right |
| Outer | No | Yes | Null left + right value |

### Important Considerations

- **KTable-KTable joins are non-windowed** — they represent current state, not time-bounded data.
- **Both tables must be co-partitioned** (same number of partitions, same key) unless using foreign key joins.
- **Updates on either side trigger a new join result.**
- **Foreign key joins** do not require co-partitioning — Kafka Streams handles the repartitioning internally.

---

## 6. Session Windows

### Definition

Session windows group events for the same key into sessions based on a configurable **inactivity gap**. Unlike fixed-size windows, session windows have dynamic sizes and boundaries.

```
Key: user-A

Events:   |--E1--E2-----E3--|-------gap(5min)-------|--E4--E5--|
          |   Session 1     |                       | Session 2|
          [t0        t0+3m]                         [t0+12m  t0+14m]
```

### Code Example

```java
StreamsBuilder builder = new StreamsBuilder();

KStream<String, String> clicks = builder.stream("user-clicks",
    Consumed.with(Serdes.String(), Serdes.String()));

// Session window with 5-minute inactivity gap
KTable<Windowed<String>, Long> sessionCounts = clicks
    .groupByKey(Grouped.with(Serdes.String(), Serdes.String()))
    .windowedBy(SessionWindows.ofInactivityGapWithNoGrace(Duration.ofMinutes(5)))
    .count(Materialized.as("session-counts-store"));

// With grace period for late-arriving events
KTable<Windowed<String>, Long> sessionCountsWithGrace = clicks
    .groupByKey()
    .windowedBy(
        SessionWindows
            .ofInactivityGapAndGrace(Duration.ofMinutes(5), Duration.ofMinutes(2))
    )
    .count();

// Process session results
sessionCounts.toStream()
    .foreach((windowedKey, count) -> {
        String userId = windowedKey.key();
        Window window = windowedKey.window();
        Instant start = Instant.ofEpochMilli(window.start());
        Instant end = Instant.ofEpochMilli(window.end());
        Duration sessionLength = Duration.between(start, end);
        System.out.printf("User %s session [%s → %s] (%s): %d clicks%n",
            userId, start, end, sessionLength, count);
    });
```

### Merge Behavior

When a new event arrives within the inactivity gap of an existing session, the sessions merge:

```
Before new event E3:
  Session A: [t0, t1]  count=2
  Session B: [t3, t4]  count=3

New event E3 at t2 (where t1 < t2 < t3 and t2-t1 < gap and t3-t2 < gap):
  Merged Session: [t0, t4]  count=6  (2 + 3 + 1 new event)
```

The merge creates a single session spanning both original sessions plus the new event. The old sessions are tombstoned and the merged session is emitted.

### Late Arrivals and Grace Periods

```java
// Events arriving after the grace period are dropped
SessionWindows.ofInactivityGapAndGrace(
    Duration.ofMinutes(5),   // inactivity gap
    Duration.ofMinutes(10)   // grace period — accept late events up to 10 min
);
```

- **Without grace period:** Late events that would extend or merge a closed session are dropped.
- **With grace period:** Late events are accepted if they arrive within the grace window after the session would normally close.
- The grace period extends from the end of the session window.

### Use Cases

- **User session analytics:** Group clickstream events into browsing sessions.
- **Fraud detection:** Identify bursts of suspicious activity separated by quiet periods.
- **IoT device telemetry:** Group device readings into active/idle cycles.

---

## 7. Tumbling vs Hopping Windows

### Tumbling Windows

Fixed-size, non-overlapping, gap-free windows. Every event belongs to exactly one window.

```
Time:    |  0-5  |  5-10  | 10-15 | 15-20 |
Events:  |E1 E2  |E3      |E4 E5  |       |
Windows: [  W1  ] [  W2  ] [  W3  ] [  W4  ]
```

```java
StreamsBuilder builder = new StreamsBuilder();

KStream<String, Double> transactions = builder.stream("transactions",
    Consumed.with(Serdes.String(), Serdes.Double()));

// 5-minute tumbling window: total transaction amount per user
KTable<Windowed<String>, Double> windowedTotals = transactions
    .groupByKey(Grouped.with(Serdes.String(), Serdes.Double()))
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(5)))
    .reduce(Double::sum, Materialized.as("tumbling-totals"));

// With grace period for late arrivals
KTable<Windowed<String>, Double> windowedTotalsWithGrace = transactions
    .groupByKey(Grouped.with(Serdes.String(), Serdes.Double()))
    .windowedBy(
        TimeWindows
            .ofSizeAndGrace(Duration.ofMinutes(5), Duration.ofMinutes(1))
    )
    .reduce(Double::sum);
```

### Hopping Windows

Fixed-size, overlapping windows that advance by a configurable hop interval. Events can belong to multiple windows.

```
Window size: 10min, Hop: 5min

Time:    |  0     5    10    15    20  |
Window1: [0-----------10]
Window2:       [5-----------15]
Window3:             [10----------20]

Event at t=7 is in Window1 AND Window2.
```

```java
// 10-minute windows, advancing every 2 minutes (5 overlapping windows at any time)
KTable<Windowed<String>, Double> hoppingTotals = transactions
    .groupByKey(Grouped.with(Serdes.String(), Serdes.Double()))
    .windowedBy(
        TimeWindows
            .ofSizeWithNoGrace(Duration.ofMinutes(10))
            .advanceBy(Duration.ofMinutes(2))
    )
    .reduce(Double::sum, Materialized.as("hopping-totals"));
```

### Comparison

| Aspect | Tumbling | Hopping |
|---|---|---|
| Overlap | No | Yes — events belong to multiple windows |
| Size | Fixed | Fixed |
| Advance | Size = advance | Advance < size |
| Memory | Lower | Higher (more active windows) |
| Use case | Periodic aggregation (hourly reports) | Sliding metrics (moving averages) |
| Result count | 1 per window per key | Multiple per event per key |

### Using `suppress()` for Final Results

By default, windowed aggregations emit updates on every input event. Use `suppress()` to emit only the **final result** when the window closes.

```java
KTable<Windowed<String>, Long> finalCounts = builder
    .stream("events", Consumed.with(Serdes.String(), Serdes.String()))
    .groupByKey()
    .windowedBy(TimeWindows.ofSizeAndGrace(Duration.ofMinutes(5), Duration.ofMinutes(1)))
    .count()
    .suppress(
        Suppressed.untilWindowCloses(Suppressed.BufferConfig.unbounded())
    );

// Only emits once per window — after the window closes + grace period expires
finalCounts.toStream()
    .map((windowedKey, count) -> KeyValue.pair(windowedKey.key(), count))
    .to("final-counts", Produced.with(Serdes.String(), Serdes.Long()));
```

#### Buffer Configurations for `suppress()`

```java
// Unbounded buffer — never drops, may use significant memory
Suppressed.BufferConfig.unbounded()

// Bounded buffer with max bytes — shuts down if exceeded
Suppressed.BufferConfig.maxBytes(1_000_000L)

// Bounded buffer with max records
Suppressed.BufferConfig.maxRecords(10_000L)

// Emit early if buffer fills up (lossy but prevents OOM)
Suppressed.BufferConfig.maxBytes(1_000_000L).emitEarlyWhenFull()
```

---

## 8. GlobalKTable

### Overview

A `GlobalKTable` is a fully replicated table — every instance of the Kafka Streams application has a **complete copy** of all partitions. This is in contrast to a regular `KTable`, where each instance only has data for its assigned partitions.

### When to Use

| Use Case | Why GlobalKTable |
|---|---|
| Small reference/lookup data | Dimension tables, config, currency rates |
| Non-key-based joins | Join on fields other than the partition key |
| Broadcast data | All instances need the full dataset |
| Avoiding repartitioning | Join without matching partition counts |

### Code Example

```java
StreamsBuilder builder = new StreamsBuilder();

// GlobalKTable: fully replicated on every instance
GlobalKTable<String, String> countryCodes = builder.globalTable(
    "country-codes",
    Consumed.with(Serdes.String(), Serdes.String()),
    Materialized.<String, String, KeyValueStore<Bytes, byte[]>>as("country-codes-store")
        .withKeySerde(Serdes.String())
        .withValueSerde(Serdes.String())
);

// Regular stream
KStream<String, Order> orders = builder.stream("orders",
    Consumed.with(Serdes.String(), orderSerde));

// Join stream with GlobalKTable — no co-partitioning required
KStream<String, EnrichedOrder> enriched = orders.join(
    countryCodes,
    (orderId, order) -> order.getCountryCode(),  // Key mapper: extract lookup key
    (order, countryName) -> new EnrichedOrder(order, countryName)  // Value joiner
);
```

### Non-Key-Based Joins (Broadcast Join)

The key advantage of `GlobalKTable` is joining on arbitrary fields, not just the stream's key:

```java
// Products keyed by productId
GlobalKTable<String, Product> products = builder.globalTable("products");

// Orders keyed by orderId but containing productId
KStream<String, OrderItem> orderItems = builder.stream("order-items");

// Join on productId (not the stream key orderId)
KStream<String, EnrichedOrderItem> enriched = orderItems.join(
    products,
    (orderId, orderItem) -> orderItem.getProductId(),  // Map to the GlobalKTable key
    (orderItem, product) -> new EnrichedOrderItem(orderItem, product)
);
```

### Limitations

| Limitation | Details |
|---|---|
| **Memory** | Full data replicated on every instance — topic must be small enough |
| **No windowed operations** | Cannot be windowed |
| **Bootstrap time** | Must read the entire topic on startup |
| **No automatic repartitioning** | Reads directly from the topic |
| **Join types** | Only inner join and left join with KStream (no outer join) |
| **No foreign key joins** | FK joins only available for KTable-KTable |

### GlobalKTable vs KTable

| Feature | KTable | GlobalKTable |
|---|---|---|
| Partitioned | Yes (each instance has a subset) | No (every instance has everything) |
| Co-partitioning required for joins | Yes | No |
| Memory per instance | Data / N instances | Full data |
| Supports windowed ops | Yes | No |
| Appropriate data size | Any | Small to medium |

---

## 9. Processor API vs DSL

### When to Use Which

| Criteria | DSL | Processor API |
|---|---|---|
| Complexity | Simple to moderate | Complex, custom logic |
| Learning curve | Low | High |
| Periodic actions | Not supported | `Punctuator` support |
| State access | Implicit (via `Materialized`) | Direct (`ProcessorContext`) |
| Control flow | Declarative | Imperative |
| Forwarding | Automatic | Manual (`forward()`) |
| Testing | `TopologyTestDriver` | `TopologyTestDriver` |

### DSL Approach

```java
StreamsBuilder builder = new StreamsBuilder();

builder.stream("input", Consumed.with(Serdes.String(), Serdes.String()))
    .filter((key, value) -> value != null && !value.isEmpty())
    .mapValues(value -> value.toUpperCase())
    .groupByKey()
    .count(Materialized.as("count-store"))
    .toStream()
    .to("output", Produced.with(Serdes.String(), Serdes.Long()));
```

### Processor API Approach

#### The Processor Interface

```java
public class EnrichmentProcessor implements Processor<String, String, String, EnrichedEvent> {
    private ProcessorContext<String, EnrichedEvent> context;
    private KeyValueStore<String, String> lookupStore;

    @Override
    public void init(ProcessorContext<String, EnrichedEvent> context) {
        this.context = context;

        // Access state stores registered with the topology
        this.lookupStore = context.getStateStore("lookup-store");

        // Schedule a periodic punctuation (wall-clock time)
        context.schedule(
            Duration.ofMinutes(1),
            PunctuationType.WALL_CLOCK_TIME,
            this::enforceExpiration
        );
    }

    @Override
    public void process(Record<String, String> record) {
        String key = record.key();
        String value = record.value();

        // Custom processing logic
        String enrichmentData = lookupStore.get(key);
        if (enrichmentData != null) {
            EnrichedEvent enriched = new EnrichedEvent(value, enrichmentData);
            // Manually forward to downstream processors/sinks
            context.forward(record.withValue(enriched));
        } else {
            // Route to dead letter topic
            context.forward(
                record.withValue(new EnrichedEvent(value, "UNKNOWN")),
                "dlq-sink"  // Named child node
            );
        }
    }

    private void enforceExpiration(long timestamp) {
        // Called every minute — scan and evict stale entries
        try (KeyValueIterator<String, String> iter = lookupStore.all()) {
            while (iter.hasNext()) {
                KeyValue<String, String> entry = iter.next();
                if (isExpired(entry.value, timestamp)) {
                    lookupStore.delete(entry.key);
                }
            }
        }
    }

    @Override
    public void close() {
        // Cleanup resources
    }
}
```

#### Punctuator

Punctuators enable periodic execution within a processor, useful for time-based eviction, batch flushing, or heartbeats.

```java
// Two types of punctuation:
// STREAM_TIME: advances with event timestamps (data-driven)
context.schedule(Duration.ofSeconds(30), PunctuationType.STREAM_TIME, timestamp -> {
    // Only fires when new events arrive and advance stream time
    flushBatch(timestamp);
});

// WALL_CLOCK_TIME: advances with system clock (time-driven)
context.schedule(Duration.ofMinutes(1), PunctuationType.WALL_CLOCK_TIME, timestamp -> {
    // Fires regardless of incoming data
    emitHeartbeat(timestamp);
});
```

#### ProcessorContext

Key methods on `ProcessorContext`:

```java
context.forward(record);                      // Forward to all downstream nodes
context.forward(record, "child-name");        // Forward to a specific child node
context.getStateStore("store-name");          // Access a state store
context.schedule(interval, type, callback);   // Register punctuator
context.commit();                             // Request a commit
context.recordMetadata();                     // Access record metadata (topic, partition, offset)
context.currentStreamTimeMs();                // Current stream time
context.currentSystemTimeMs();                // Current wall-clock time
```

#### Full Topology with Processor API

```java
Topology topology = new Topology();

// Add source
topology.addSource("source", Serdes.String().deserializer(),
    Serdes.String().deserializer(), "input-topic");

// Add processor with state store
StoreBuilder<KeyValueStore<String, String>> storeBuilder =
    Stores.keyValueStoreBuilder(
        Stores.persistentKeyValueStore("lookup-store"),
        Serdes.String(), Serdes.String()
    );

topology.addProcessor("enrichment-processor",
    () -> new EnrichmentProcessor(), "source");
topology.addStateStore(storeBuilder, "enrichment-processor");

// Add sinks
topology.addSink("output-sink", "enriched-output",
    Serdes.String().serializer(), enrichedEventSerializer,
    "enrichment-processor");
topology.addSink("dlq-sink", "dead-letters",
    Serdes.String().serializer(), enrichedEventSerializer,
    "enrichment-processor");

KafkaStreams streams = new KafkaStreams(topology, props);
streams.start();
```

### Mixing DSL and Processor API

You can use `process()` within the DSL to embed custom processor logic:

```java
StreamsBuilder builder = new StreamsBuilder();

StoreBuilder<KeyValueStore<String, Long>> storeBuilder =
    Stores.keyValueStoreBuilder(
        Stores.persistentKeyValueStore("rate-limit-store"),
        Serdes.String(), Serdes.Long()
    );
builder.addStateStore(storeBuilder);

builder.stream("requests", Consumed.with(Serdes.String(), Serdes.String()))
    .filter((key, value) -> value != null)
    // Switch to Processor API mid-pipeline
    .process(() -> new RateLimitProcessor(), "rate-limit-store")
    .to("approved-requests");
```

---

## 10. Dead Letter Queues

### Overview

Dead Letter Queues (DLQ) provide a mechanism to capture records that cannot be processed, preventing a single bad record from blocking the entire pipeline.

### DeserializationExceptionHandler

Handles records that fail to deserialize (corrupt data, schema mismatches).

```java
public class DlqDeserializationHandler implements DeserializationExceptionHandler {
    private KafkaProducer<byte[], byte[]> dlqProducer;

    @Override
    public void configure(Map<String, ?> configs) {
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG,
            configs.get(StreamsConfig.BOOTSTRAP_SERVERS_CONFIG));
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, ByteArraySerializer.class);
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, ByteArraySerializer.class);
        this.dlqProducer = new KafkaProducer<>(props);
    }

    @Override
    public DeserializationHandlerResponse handle(
            ProcessorContext context,
            ConsumerRecord<byte[], byte[]> record,
            Exception exception) {

        // Route the raw bytes to DLQ with error metadata in headers
        ProducerRecord<byte[], byte[]> dlqRecord =
            new ProducerRecord<>("dlq-deserialization-errors", record.key(), record.value());

        dlqRecord.headers().add("error.message",
            exception.getMessage().getBytes(StandardCharsets.UTF_8));
        dlqRecord.headers().add("error.source.topic",
            record.topic().getBytes(StandardCharsets.UTF_8));
        dlqRecord.headers().add("error.source.partition",
            String.valueOf(record.partition()).getBytes(StandardCharsets.UTF_8));
        dlqRecord.headers().add("error.source.offset",
            String.valueOf(record.offset()).getBytes(StandardCharsets.UTF_8));
        dlqRecord.headers().add("error.timestamp",
            Instant.now().toString().getBytes(StandardCharsets.UTF_8));

        dlqProducer.send(dlqRecord);

        // CONTINUE = skip the bad record, FAIL = throw and shut down
        return DeserializationHandlerResponse.CONTINUE;
    }
}

// Register the handler
Properties props = new Properties();
props.put(StreamsConfig.DEFAULT_DESERIALIZATION_EXCEPTION_HANDLER_CLASS_CONFIG,
    DlqDeserializationHandler.class.getName());
```

### ProductionExceptionHandler

Handles records that fail during serialization or production to the output topic.

```java
public class DlqProductionHandler implements ProductionExceptionHandler {
    @Override
    public ProductionExceptionHandlerResponse handle(
            ProducerRecord<byte[], byte[]> record,
            Exception exception) {

        log.error("Failed to produce record to {}: {}",
            record.topic(), exception.getMessage());

        // Could route to a separate DLQ here, or just log and continue
        // CONTINUE = skip the record, FAIL = shut down the streams app
        if (exception instanceof RecordTooLargeException) {
            return ProductionExceptionHandlerResponse.CONTINUE;
        }
        return ProductionExceptionHandlerResponse.FAIL;
    }

    @Override
    public void configure(Map<String, ?> configs) {}
}

// Register the handler
props.put(StreamsConfig.DEFAULT_PRODUCTION_EXCEPTION_HANDLER_CLASS_CONFIG,
    DlqProductionHandler.class.getName());
```

### Manual DLQ Routing in Processing Logic

For business logic failures (valid records that cannot be processed):

```java
public class OrderProcessorWithDlq implements Processor<String, Order, String, ProcessedOrder> {
    private ProcessorContext<String, ProcessedOrder> context;
    private static final String DLQ_TOPIC = "order-processing-dlq";

    // Separate producer for DLQ writes (not part of the Streams topology)
    private KafkaProducer<String, String> dlqProducer;

    @Override
    public void init(ProcessorContext<String, ProcessedOrder> context) {
        this.context = context;
        Properties dlqProps = new Properties();
        dlqProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
        dlqProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        dlqProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        this.dlqProducer = new KafkaProducer<>(dlqProps);
    }

    @Override
    public void process(Record<String, Order> record) {
        try {
            Order order = record.value();
            validateOrder(order);
            ProcessedOrder result = processOrder(order);
            context.forward(record.withValue(result));
        } catch (ValidationException e) {
            // Business rule violation — route to DLQ
            sendToDlq(record, e, "VALIDATION_ERROR");
        } catch (ExternalServiceException e) {
            // External system failure — route to DLQ for retry
            sendToDlq(record, e, "EXTERNAL_SERVICE_ERROR");
        } catch (Exception e) {
            // Unexpected error
            sendToDlq(record, e, "UNKNOWN_ERROR");
        }
    }

    private void sendToDlq(Record<String, Order> record, Exception e, String errorType) {
        ProducerRecord<String, String> dlqRecord = new ProducerRecord<>(
            DLQ_TOPIC, record.key(), record.value().toJson());

        dlqRecord.headers()
            .add("error.type", errorType.getBytes(StandardCharsets.UTF_8))
            .add("error.message", e.getMessage().getBytes(StandardCharsets.UTF_8))
            .add("error.stacktrace",
                ExceptionUtils.getStackTrace(e).getBytes(StandardCharsets.UTF_8))
            .add("original.timestamp",
                String.valueOf(record.timestamp()).getBytes(StandardCharsets.UTF_8));

        dlqProducer.send(dlqRecord, (metadata, sendException) -> {
            if (sendException != null) {
                log.error("Failed to write to DLQ!", sendException);
            }
        });
    }

    @Override
    public void close() {
        if (dlqProducer != null) dlqProducer.close();
    }
}
```

### DLQ with DSL (Branch-Based)

```java
StreamsBuilder builder = new StreamsBuilder();

KStream<String, Order> orders = builder.stream("orders",
    Consumed.with(Serdes.String(), orderSerde));

// Split stream based on processing result
Map<String, KStream<String, Order>> branches = orders
    .split(Named.as("order-"))
    .branch((key, order) -> order.isValid() && order.hasInventory(),
        Branched.as("valid"))
    .branch((key, order) -> !order.isValid(),
        Branched.as("invalid"))
    .defaultBranch(Branched.as("other"));

// Route valid orders to processing
branches.get("order-valid")
    .mapValues(order -> processOrder(order))
    .to("processed-orders");

// Route invalid orders to DLQ
branches.get("order-invalid")
    .mapValues(order -> createDlqEnvelope(order, "VALIDATION_FAILED"))
    .to("order-dlq");

// Route unhandled cases to DLQ
branches.get("order-other")
    .mapValues(order -> createDlqEnvelope(order, "UNHANDLED_CASE"))
    .to("order-dlq");
```

---

## 11. Event Sourcing with Kafka

### Core Concepts

Event sourcing stores every state change as an immutable event in an append-only log. Kafka's append-only, immutable, ordered log is a natural fit.

```
Traditional: Store current state → UPDATE orders SET status='shipped' WHERE id=123
Event Sourcing: Store events → OrderCreated, PaymentReceived, OrderShipped, OrderDelivered
```

### Event Store Design

```java
// Event base class
public abstract class DomainEvent {
    private final String eventId;
    private final String aggregateId;
    private final Instant timestamp;
    private final int version;
    private final String eventType;

    protected DomainEvent(String aggregateId, int version) {
        this.eventId = UUID.randomUUID().toString();
        this.aggregateId = aggregateId;
        this.timestamp = Instant.now();
        this.version = version;
        this.eventType = this.getClass().getSimpleName();
    }
}

// Concrete events
public class OrderCreated extends DomainEvent {
    private final String customerId;
    private final List<LineItem> items;
    private final BigDecimal totalAmount;

    public OrderCreated(String orderId, String customerId,
                        List<LineItem> items, BigDecimal totalAmount, int version) {
        super(orderId, version);
        this.customerId = customerId;
        this.items = items;
        this.totalAmount = totalAmount;
    }
}

public class OrderShipped extends DomainEvent {
    private final String trackingNumber;
    private final String carrier;

    public OrderShipped(String orderId, String trackingNumber,
                        String carrier, int version) {
        super(orderId, version);
        this.trackingNumber = trackingNumber;
        this.carrier = carrier;
    }
}
```

### Kafka Topic as Event Store

```java
// Topic configuration for event store
NewTopic eventStoreTopic = new NewTopic("order-events", 12, (short) 3);
eventStoreTopic.configs(Map.of(
    "retention.ms", "-1",              // Infinite retention
    "cleanup.policy", "delete",        // Pure append-only log
    "min.insync.replicas", "2",        // Durability
    "message.timestamp.type", "CreateTime"
));

// Publishing events
public class KafkaEventStore {
    private final KafkaProducer<String, DomainEvent> producer;

    public void appendEvent(DomainEvent event) {
        ProducerRecord<String, DomainEvent> record = new ProducerRecord<>(
            "order-events",
            event.getAggregateId(),  // Key = aggregate ID for ordering
            event
        );
        record.headers().add("event-type",
            event.getEventType().getBytes(StandardCharsets.UTF_8));
        record.headers().add("event-version",
            String.valueOf(event.getVersion()).getBytes(StandardCharsets.UTF_8));

        producer.send(record).get();  // Synchronous for consistency
    }
}
```

### Aggregate Reconstruction

Replay all events for an aggregate to rebuild its current state:

```java
public class OrderAggregate {
    private String orderId;
    private String status;
    private String customerId;
    private BigDecimal totalAmount;
    private String trackingNumber;
    private int version;

    // Reconstruct from event history
    public static OrderAggregate fromEvents(List<DomainEvent> events) {
        OrderAggregate aggregate = new OrderAggregate();
        for (DomainEvent event : events) {
            aggregate.apply(event);
        }
        return aggregate;
    }

    private void apply(DomainEvent event) {
        this.version = event.getVersion();
        if (event instanceof OrderCreated e) {
            this.orderId = e.getAggregateId();
            this.customerId = e.getCustomerId();
            this.totalAmount = e.getTotalAmount();
            this.status = "CREATED";
        } else if (event instanceof PaymentReceived e) {
            this.status = "PAID";
        } else if (event instanceof OrderShipped e) {
            this.trackingNumber = e.getTrackingNumber();
            this.status = "SHIPPED";
        } else if (event instanceof OrderDelivered e) {
            this.status = "DELIVERED";
        }
    }

    // Command handler with event generation
    public List<DomainEvent> ship(String trackingNumber, String carrier) {
        if (!"PAID".equals(this.status)) {
            throw new IllegalStateException("Cannot ship order in status: " + status);
        }
        OrderShipped event = new OrderShipped(orderId, trackingNumber, carrier, version + 1);
        apply(event);
        return List.of(event);
    }
}
```

### Snapshots

For aggregates with many events, periodically store snapshots to avoid replaying the full history:

```java
public class SnapshotStore {
    private final KafkaProducer<String, OrderSnapshot> producer;

    public void saveSnapshot(OrderAggregate aggregate) {
        OrderSnapshot snapshot = new OrderSnapshot(
            aggregate.getOrderId(),
            aggregate.getStatus(),
            aggregate.getCustomerId(),
            aggregate.getTotalAmount(),
            aggregate.getTrackingNumber(),
            aggregate.getVersion()
        );
        // Write to a compacted snapshot topic
        producer.send(new ProducerRecord<>("order-snapshots",
            aggregate.getOrderId(), snapshot));
    }

    public OrderAggregate loadAggregate(String orderId,
                                         KafkaConsumer<String, DomainEvent> eventConsumer) {
        // 1. Load latest snapshot (from compacted topic)
        OrderSnapshot snapshot = loadLatestSnapshot(orderId);

        // 2. Replay events AFTER the snapshot version
        OrderAggregate aggregate;
        if (snapshot != null) {
            aggregate = OrderAggregate.fromSnapshot(snapshot);
            List<DomainEvent> recentEvents = loadEventsSince(orderId, snapshot.getVersion());
            for (DomainEvent event : recentEvents) {
                aggregate.apply(event);
            }
        } else {
            List<DomainEvent> allEvents = loadAllEvents(orderId);
            aggregate = OrderAggregate.fromEvents(allEvents);
        }

        // 3. Optionally save a new snapshot if many events were replayed
        return aggregate;
    }
}
```

### Compacted Topics as State

Use log compaction to maintain a materialized view of the latest state per key:

```java
// Compacted topic for current order state (materialized view)
NewTopic orderStateTopic = new NewTopic("order-current-state", 12, (short) 3);
orderStateTopic.configs(Map.of(
    "cleanup.policy", "compact",
    "min.cleanable.dirty.ratio", "0.5",
    "segment.ms", "86400000"  // 24 hours
));

// Kafka Streams: project event stream into compacted state topic
StreamsBuilder builder = new StreamsBuilder();
builder.stream("order-events", Consumed.with(Serdes.String(), eventSerde))
    .groupByKey()
    .aggregate(
        OrderState::new,
        (orderId, event, currentState) -> currentState.applyEvent(event),
        Materialized.<String, OrderState, KeyValueStore<Bytes, byte[]>>as("order-state-store")
            .withKeySerde(Serdes.String())
            .withValueSerde(orderStateSerde)
    )
    .toStream()
    .to("order-current-state", Produced.with(Serdes.String(), orderStateSerde));
```

---

## 12. CQRS Patterns

### Core Concept

Command Query Responsibility Segregation (CQRS) separates the write model (commands) from the read model (queries). Kafka serves as the event bus connecting them.

```
                  ┌──────────────┐
  Commands ──────>│ Write Model  │──── Events ────> Kafka ────> Read Model ──── Queries
                  │ (Aggregates) │                              (Materialized  
                  └──────────────┘                               Views)
```

### Command Side

```java
// Command handler
public class OrderCommandHandler {
    private final KafkaEventStore eventStore;

    public void handle(CreateOrderCommand cmd) {
        // Validate command
        if (cmd.getItems().isEmpty()) {
            throw new ValidationException("Order must have at least one item");
        }

        // Generate events
        OrderCreated event = new OrderCreated(
            UUID.randomUUID().toString(),
            cmd.getCustomerId(),
            cmd.getItems(),
            cmd.calculateTotal(),
            1
        );

        // Persist events to Kafka
        eventStore.appendEvent(event);
    }

    public void handle(ShipOrderCommand cmd) {
        // Load aggregate from event store
        OrderAggregate order = eventStore.loadAggregate(cmd.getOrderId());

        // Business logic generates events
        List<DomainEvent> events = order.ship(cmd.getTrackingNumber(), cmd.getCarrier());

        // Persist new events
        for (DomainEvent event : events) {
            eventStore.appendEvent(event);
        }
    }
}
```

### Query Side: Materialized Views with KTable

```java
StreamsBuilder builder = new StreamsBuilder();

// Consume events from the event store
KStream<String, DomainEvent> events = builder.stream("order-events",
    Consumed.with(Serdes.String(), eventSerde));

// Materialized view 1: Order status lookup
KTable<String, OrderStatusView> orderStatus = events
    .groupByKey()
    .aggregate(
        OrderStatusView::new,
        (orderId, event, view) -> view.apply(event),
        Materialized.as("order-status-store")
    );

// Materialized view 2: Orders by customer (re-keyed)
KTable<String, CustomerOrdersView> customerOrders = events
    .filter((key, event) -> event instanceof OrderCreated)
    .selectKey((orderId, event) -> ((OrderCreated) event).getCustomerId())
    .groupByKey(Grouped.with(Serdes.String(), eventSerde))
    .aggregate(
        CustomerOrdersView::new,
        (customerId, event, view) -> view.addOrder((OrderCreated) event),
        Materialized.as("customer-orders-store")
    );

// Materialized view 3: Revenue per day
KTable<Windowed<String>, BigDecimal> dailyRevenue = events
    .filter((key, event) -> event instanceof PaymentReceived)
    .selectKey((key, event) -> "revenue")
    .groupByKey(Grouped.with(Serdes.String(), eventSerde))
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofDays(1)))
    .aggregate(
        () -> BigDecimal.ZERO,
        (key, event, total) -> total.add(((PaymentReceived) event).getAmount()),
        Materialized.as("daily-revenue-store")
    );
```

### Exposing Query Views via REST

```java
public class QueryService {
    private final KafkaStreams streams;

    // GET /orders/{orderId}/status
    public OrderStatusView getOrderStatus(String orderId) {
        ReadOnlyKeyValueStore<String, OrderStatusView> store = streams.store(
            StoreQueryParameters.fromNameAndType(
                "order-status-store", QueryableStoreTypes.keyValueStore()));
        return store.get(orderId);
    }

    // GET /customers/{customerId}/orders
    public CustomerOrdersView getCustomerOrders(String customerId) {
        ReadOnlyKeyValueStore<String, CustomerOrdersView> store = streams.store(
            StoreQueryParameters.fromNameAndType(
                "customer-orders-store", QueryableStoreTypes.keyValueStore()));
        return store.get(customerId);
    }
}
```

### CQRS Best Practices

- **Eventual consistency:** Query models are eventually consistent with the command side. Design UIs to handle this.
- **Separate topics per view** if different views need different partitioning.
- **Idempotent projections:** Event handlers that build views must be idempotent (handle replays).
- **Schema evolution:** Use a schema registry (Avro/Protobuf) to handle event schema changes.
- **Rebuild views:** You can always rebuild a materialized view by resetting the consumer group offset.

---

## 13. Compacted Topics for State

### How Log Compaction Works

Log compaction retains the **latest value for each key**, removing older records with the same key. Unlike time-based retention, compaction never removes the last record for any key.

```
Before compaction:
  Offset 0: {key=A, value=1}
  Offset 1: {key=B, value=2}
  Offset 2: {key=A, value=3}   ← supersedes offset 0
  Offset 3: {key=C, value=4}
  Offset 4: {key=B, value=null} ← tombstone (delete key B)
  Offset 5: {key=A, value=5}   ← supersedes offset 2

After compaction:
  Offset 3: {key=C, value=4}
  Offset 4: {key=B, value=null} ← tombstone retained temporarily
  Offset 5: {key=A, value=5}
```

### Tombstones

A tombstone is a record with a `null` value. It signals deletion of a key:

```java
// Write a tombstone to delete key "user-42"
producer.send(new ProducerRecord<>("user-state", "user-42", null));
```

- Tombstones are retained for `delete.retention.ms` (default 24 hours) after compaction.
- After `delete.retention.ms`, the tombstone itself is removed.
- Consumers that start reading before the tombstone is removed will see the deletion.

### Configuration Parameters

```bash
# Topic-level configs for compaction
kafka-topics.sh --create --topic user-profiles \
  --partitions 12 \
  --replication-factor 3 \
  --config cleanup.policy=compact \
  --config min.cleanable.dirty.ratio=0.5 \
  --config segment.ms=86400000 \
  --config delete.retention.ms=86400000 \
  --config min.compaction.lag.ms=0 \
  --config max.compaction.lag.ms=604800000
```

| Parameter | Default | Description |
|---|---|---|
| `cleanup.policy` | `delete` | Set to `compact` for log compaction, or `compact,delete` for both |
| `min.cleanable.dirty.ratio` | `0.5` | Ratio of dirty (uncompacted) to total log size. Lower = more aggressive compaction |
| `segment.ms` | `604800000` (7d) | Time before a segment is eligible for compaction. Active segment is never compacted |
| `delete.retention.ms` | `86400000` (24h) | How long tombstones are retained after compaction |
| `min.compaction.lag.ms` | `0` | Minimum time before a message is eligible for compaction |
| `max.compaction.lag.ms` | `∞` | Maximum time before compaction is forced (guarantees freshness) |

### Use Cases

#### 1. User Profile Cache

```java
// Topic: user-profiles (compacted)
// Key: userId, Value: serialized UserProfile
NewTopic topic = new NewTopic("user-profiles", 12, (short) 3);
topic.configs(Map.of(
    "cleanup.policy", "compact",
    "min.cleanable.dirty.ratio", "0.3",   // Compact aggressively
    "segment.ms", "3600000"               // Roll segments hourly
));
```

#### 2. Configuration Distribution

```java
// Distribute config changes to all services
// Topic: app-config (compacted)
producer.send(new ProducerRecord<>("app-config", "feature.flags",
    "{\"dark_mode\": true, \"beta_feature\": false}"));

// Consumers replay the full topic on startup to build local config
consumer.seekToBeginning(consumer.assignment());
```

#### 3. Changelog Topics (Kafka Streams Internal)

Kafka Streams uses compacted changelog topics to back up state stores. If a streams instance fails, the new instance rebuilds state by replaying the changelog.

### Compact + Delete Policy

You can combine compaction with time-based retention:

```bash
# Compact within the retention window, then delete old segments entirely
--config cleanup.policy=compact,delete \
--config retention.ms=604800000  # 7 days
```

This keeps the latest value for each key within the retention window, then deletes everything older.

---

## 14. Kafka vs Alternatives Decision Matrix

### Comparison Table

| Feature | Apache Kafka | RabbitMQ | Apache Pulsar | AWS Kinesis | Google Pub/Sub | Redis Streams | NATS JetStream |
|---|---|---|---|---|---|---|---|
| **Throughput** | Very High (millions/sec) | Moderate (10K-50K/sec) | Very High (millions/sec) | High (1MB/sec/shard) | High (auto-scaled) | Very High (in-memory) | High (millions/sec) |
| **Latency** | Low (2-10ms) | Very Low (<1ms) | Low (5-10ms) | Moderate (70-200ms) | Moderate (50-100ms) | Ultra Low (<1ms) | Very Low (1-2ms) |
| **Ordering** | Per-partition | Per-queue | Per-partition | Per-shard | Per-key (ordering key) | Per-stream | Per-stream |
| **Persistence** | Disk (log-based) | Optional (disk/memory) | Disk (BookKeeper) | Managed (72h default) | Managed (7d default) | Memory + optional AOF/RDB | Disk (file-based) |
| **Replay** | Full replay (offset-based) | No (consumed = gone) | Full replay | Up to retention period | Seek by time | Full replay (offset-based) | Full replay |
| **Exactly-Once** | Yes (EOS) | No (at-most/at-least) | Yes (transactions) | No (at-least-once) | Yes (with Dataflow) | No (at-least-once) | No (at-least-once) |
| **Stream Processing** | Kafka Streams, ksqlDB | No built-in | Pulsar Functions | Kinesis Analytics | Dataflow | No built-in | No built-in |
| **Schema Registry** | Confluent Schema Registry | No built-in | Built-in | Glue Schema Registry | No built-in | No | No |
| **Multi-Tenancy** | Limited (topics/ACLs) | Vhosts | Native (tenants/namespaces) | Account-level | Project-level | Databases | Accounts |
| **Geo-Replication** | MirrorMaker 2 / Confluent Replicator | Federation / Shovel | Built-in (native) | Cross-region via Lambda | Global topics | Redis Cluster | Leaf nodes |
| **Operational Complexity** | High (ZK/KRaft, brokers, schema registry) | Low-Medium | High (ZK, BookKeeper, brokers) | None (managed) | None (managed) | Low | Low-Medium |
| **Managed Offerings** | Confluent Cloud, MSK, Aiven | CloudAMQP, AmazonMQ | StreamNative | AWS Kinesis | GCP native | Redis Cloud, ElastiCache | Synadia Cloud |
| **Consumer Model** | Pull-based | Push-based | Pull + Push | Pull-based (GetRecords) | Push (subscriber) | Pull (XREAD) | Pull + Push |
| **Max Message Size** | 1MB default (configurable) | 128MB+ | 5MB default (configurable) | 1MB | 10MB | 512MB (configurable) | 1MB default |
| **License** | Apache 2.0 | MPL 2.0 | Apache 2.0 | Proprietary | Proprietary | BSD 3 (source-available since v7.4) | Apache 2.0 |
| **Primary Language** | Java/Scala | Erlang | Java | N/A | N/A | C | Go |

### When to Choose Each

#### Choose **Kafka** when:
- You need high-throughput, ordered event streaming
- You require exactly-once semantics end-to-end
- You need stream processing (Kafka Streams / ksqlDB)
- You need long-term event storage and replay
- You're building event-driven microservices at scale

#### Choose **RabbitMQ** when:
- You need traditional message queuing (task distribution)
- Low latency point-to-point messaging is critical
- You need complex routing (exchanges, bindings, headers)
- Operational simplicity matters more than throughput
- You need message acknowledgment and dead-letter exchanges out of the box

#### Choose **Pulsar** when:
- You need native multi-tenancy
- You need built-in geo-replication
- You want tiered storage (hot/warm/cold) for cost optimization
- You need both streaming and queuing in one system
- You want Kafka-compatible API with more features

#### Choose **AWS Kinesis** when:
- You're fully committed to the AWS ecosystem
- You want zero operational overhead (fully managed)
- Your throughput needs are moderate (shard-based scaling)
- You need tight integration with Lambda, Firehose, Analytics

#### Choose **Google Pub/Sub** when:
- You're in the GCP ecosystem
- You need serverless, auto-scaling messaging
- You want global message ordering with ordering keys
- You want tight Dataflow integration for stream processing

#### Choose **Redis Streams** when:
- You need ultra-low latency
- Data fits in memory
- You already run Redis in your stack
- You need simple, lightweight streaming
- You can tolerate potential data loss (memory-first)

#### Choose **NATS JetStream** when:
- You need lightweight, edge-friendly messaging
- You want simple operations (single binary)
- You need request-reply patterns alongside streaming
- You're building IoT or edge computing systems
- You want a modern, Go-native solution

### Decision Flowchart

```
Start
  │
  ├── Need exactly-once semantics?
  │     ├── Yes → Kafka or Pulsar
  │     └── No ──┐
  │              │
  ├── Need replay/event sourcing?
  │     ├── Yes → Kafka, Pulsar, or NATS JetStream
  │     └── No ──┐
  │              │
  ├── Need stream processing built-in?
  │     ├── Yes → Kafka (Kafka Streams) or Pulsar (Pulsar Functions)
  │     └── No ──┐
  │              │
  ├── Latency < 1ms critical?
  │     ├── Yes → Redis Streams or RabbitMQ or NATS
  │     └── No ──┐
  │              │
  ├── Want managed / zero-ops?
  │     ├── AWS → Kinesis
  │     ├── GCP → Pub/Sub
  │     └── Any → Confluent Cloud
  │
  └── Simple task queue / work distribution?
        ├── Yes → RabbitMQ
        └── No → Kafka (general-purpose default)
```

---

## Appendix: Quick Reference

### Kafka Streams Configuration Cheat Sheet

```properties
# Application identity
application.id=my-streams-app
bootstrap.servers=broker1:9092,broker2:9092

# Exactly-once processing (v2 is recommended for Kafka 2.5+)
processing.guarantee=exactly_once_v2

# State store directory
state.dir=/var/kafka-streams

# Number of stream threads per instance
num.stream.threads=4

# Standby replicas for faster failover
num.standby.replicas=1

# Interactive queries endpoint
application.server=localhost:8080

# Commit interval (lower = less reprocessing on failure, more overhead)
commit.interval.ms=100

# Cache size per thread (higher = more batching, fewer intermediate results)
statestore.cache.max.bytes.buffering=10485760

# Deserialization error handling
default.deserialization.exception.handler=com.example.DlqDeserializationHandler

# Production error handling
default.production.exception.handler=com.example.DlqProductionHandler
```

### Common Producer Configuration

```properties
bootstrap.servers=broker1:9092,broker2:9092
acks=all
enable.idempotence=true
transactional.id=my-app-txn-0
retries=2147483647
max.in.flight.requests.per.connection=5
compression.type=lz4
batch.size=16384
linger.ms=5
buffer.memory=33554432
```

### Common Consumer Configuration

```properties
bootstrap.servers=broker1:9092,broker2:9092
group.id=my-consumer-group
isolation.level=read_committed
enable.auto.commit=false
auto.offset.reset=earliest
max.poll.records=500
max.poll.interval.ms=300000
session.timeout.ms=45000
heartbeat.interval.ms=15000
fetch.min.bytes=1
fetch.max.wait.ms=500
```

---

*This document is a living reference. Update it as Kafka versions evolve and new patterns emerge.*
