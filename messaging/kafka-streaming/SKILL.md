---
name: kafka-streaming
description: >
  Use this skill when building Apache Kafka producers, consumers, Kafka Streams
  topologies, Kafka Connect pipelines, or Schema Registry integrations. TRIGGER
  when: code imports kafka clients (confluent-kafka, kafkajs, sarama, franz-go,
  org.apache.kafka), docker-compose references kafka/kraft/schema-registry images,
  user asks about topics/partitions/consumer-groups/offsets/brokers, event streaming
  architecture, or Kafka configuration tuning. Also trigger for Kafka-adjacent
  patterns: event sourcing with Kafka, CQRS over Kafka topics, transactional outbox
  to Kafka, dead letter topics, retry topics, exactly-once semantics, or Kafka
  monitoring/operations. DO NOT trigger for general message queues (RabbitMQ, SQS,
  Celery, Redis Pub/Sub), non-Kafka streaming (Pulsar, Kinesis, NATS), or basic
  pub/sub that does not mention Kafka. The celery-task-queues skill covers task
  queues — this skill covers Kafka specifically.
---

# Kafka Streaming

## Architecture Fundamentals

A Kafka cluster consists of **brokers** that store data in append-only **topics**. Each topic is split into **partitions** — the unit of parallelism. Each partition has a configurable number of **replicas** spread across brokers. One replica is the **leader** (handles reads/writes); others are **followers** in the **ISR** (in-sync replica set).

**KRaft mode** (Kafka 4.0+, default): Metadata managed by an internal Raft-based controller quorum — no ZooKeeper dependency. Use KRaft for all new deployments. ZooKeeper support was removed in Kafka 4.0.

**Consumer groups**: Each consumer in a group reads from a disjoint set of partitions. The group coordinator tracks **offsets** — the position of each consumer in each partition. Partition count = max parallelism within a single consumer group.

**Key sizing rules**:
- Partition count ≥ expected max consumer instances
- Replication factor = 3 for production (tolerates 1 broker failure with `min.insync.replicas=2`)
- KRaft clusters scale to 1.5M+ partitions (vs ~200K with ZooKeeper)

## Producer API

### Core Configuration

```java
Properties props = new Properties();
props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "broker1:9092,broker2:9092");
props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
props.put(ProducerConfig.ACKS_CONFIG, "all");
props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
props.put(ProducerConfig.RETRIES_CONFIG, Integer.MAX_VALUE);
props.put(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 5);
props.put(ProducerConfig.BATCH_SIZE_CONFIG, 32768);        // 32KB
props.put(ProducerConfig.LINGER_MS_CONFIG, 20);
props.put(ProducerConfig.COMPRESSION_TYPE_CONFIG, "lz4");  // or snappy, zstd
props.put(ProducerConfig.BUFFER_MEMORY_CONFIG, 67108864);  // 64MB
```

### Partitioning

Default: murmur2 hash of key → partition. Null key → sticky round-robin. Implement `Partitioner` for custom routing (tenant, region). Always set a key when ordering matters.

### Idempotent & Transactional Producer

Enable `enable.idempotence=true` to prevent duplicates on retries. For cross-partition atomicity:

```java
props.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, "order-service-tx");
KafkaProducer<String, String> producer = new KafkaProducer<>(props);
producer.initTransactions();
try {
    producer.beginTransaction();
    producer.send(new ProducerRecord<>("orders", key, value));
    producer.send(new ProducerRecord<>("audit-log", key, auditValue));
    producer.commitTransaction();
} catch (KafkaException e) {
    producer.abortTransaction();
}
```

### Acks Semantics

| `acks` | Durability | Throughput | Use Case |
|--------|-----------|------------|----------|
| `0`    | None      | Highest    | Metrics, logs (loss OK) |
| `1`    | Leader only | High     | Default for non-critical |
| `all`  | Full ISR  | Lower      | Financial, critical data |

## Consumer API

### Core Configuration

```java
Properties props = new Properties();
props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "broker1:9092");
props.put(ConsumerConfig.GROUP_ID_CONFIG, "payment-processor");
props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);
props.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, 500);
props.put(ConsumerConfig.SESSION_TIMEOUT_MS_CONFIG, 30000);
props.put(ConsumerConfig.HEARTBEAT_INTERVAL_MS_CONFIG, 10000);
props.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");
```

### Manual Offset Commit Pattern

```java
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    for (ConsumerRecord<String, String> record : records) {
        process(record);
    }
    consumer.commitSync(); // or commitAsync() for higher throughput
}
```

Use `commitSync()` for at-least-once. Use `commitAsync()` with callback for throughput; fall back to `commitSync()` on shutdown.

### Rebalancing

Kafka 4.0 introduces **KIP-848 server-side rebalancing** — broker assigns partitions directly, reducing rebalance latency. For older versions:

```java
props.put(ConsumerConfig.PARTITION_ASSIGNMENT_STRATEGY_CONFIG, CooperativeStickyAssignor.class.getName());
```

### Seek and Replay

```java
consumer.assign(List.of(new TopicPartition("events", 0)));
consumer.seekToBeginning(consumer.assignment());       // replay from start
consumer.seek(new TopicPartition("events", 0), 42L);  // seek to specific offset
```

## Kafka Streams

### KStream vs KTable

| Abstraction | Semantics | Use Case |
|-------------|-----------|----------|
| `KStream`   | Unbounded event stream (insert) | Clicks, logs, transactions |
| `KTable`    | Changelog / latest-value-per-key (upsert) | User profiles, inventory |
| `GlobalKTable` | Broadcast table replicated to all instances | Lookup/reference data |

### Topology Example

```java
StreamsBuilder builder = new StreamsBuilder();
KStream<String, Order> orders = builder.stream("orders");
KTable<String, Customer> customers = builder.table("customers");

// Stream-table join: enrich orders with customer data
KStream<String, EnrichedOrder> enriched = orders.join(
    customers,
    (order, customer) -> new EnrichedOrder(order, customer)
);

// Windowed aggregation: count orders per customer per hour
KTable<Windowed<String>, Long> hourlyCounts = orders
    .groupByKey()
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofHours(1)))
    .count(Materialized.as("hourly-order-counts"));

enriched.to("enriched-orders");
```

### Exactly-Once Semantics

```java
props.put(StreamsConfig.PROCESSING_GUARANTEE_CONFIG, StreamsConfig.EXACTLY_ONCE_V2);
```

Use `EXACTLY_ONCE_V2` (not deprecated v1). This wraps consume-process-produce in atomic transactions. EOS applies within Kafka only — external sinks need their own idempotency.

### State Stores

RocksDB-backed local state with changelog topics for fault tolerance. Query via Interactive Queries:

```java
ReadOnlyKeyValueStore<String, Long> store = streams.store(
    StoreQueryParameters.fromNameAndType("hourly-order-counts", QueryableStoreTypes.keyValueStore()));
```

## Kafka Connect

### Source Connector (DB → Kafka)

```json
{
  "name": "postgres-source",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "db-host", "database.port": "5432",
    "database.user": "replicator", "database.dbname": "orders_db",
    "table.include.list": "public.orders",
    "topic.prefix": "cdc", "plugin.name": "pgoutput",
    "key.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter.schema.registry.url": "http://schema-registry:8081",
    "value.converter": "io.confluent.connect.avro.AvroConverter",
    "value.converter.schema.registry.url": "http://schema-registry:8081"
  }
}
```

### Sink Connector (Kafka → Elasticsearch)

```json
{
  "name": "elasticsearch-sink",
  "config": {
    "connector.class": "io.confluent.connect.elasticsearch.ElasticsearchSinkConnector",
    "topics": "enriched-orders",
    "connection.url": "http://elasticsearch:9200",
    "key.ignore": "false",
    "errors.tolerance": "all",
    "errors.deadletterqueue.topic.name": "dlq-enriched-orders",
    "errors.deadletterqueue.context.headers.enable": "true"
  }
}
```

### SMTs (Single Message Transforms)

```json
"transforms": "route,unwrap",
"transforms.route.type": "org.apache.kafka.connect.transforms.RegexRouter",
"transforms.route.regex": "cdc\\.public\\.(.*)",
"transforms.route.replacement": "$1-events",
"transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState"
```

Set `errors.tolerance=all` + `errors.deadletterqueue.topic.name` for DLQ routing of failed records.

## Schema Registry

### Compatibility Modes

| Mode | Rule | Default |
|------|------|---------|
| `BACKWARD` | New schema can read old data | **Yes** |
| `FORWARD` | Old schema can read new data | No |
| `FULL` | Both backward and forward | No |
| `NONE` | No checks | No |

Set per-subject: `PUT /config/{subject} {"compatibility": "FULL"}`.

### Avro Producer with Schema Registry (Python)

```python
from confluent_kafka import SerializingProducer
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroSerializer

schema_str = '{"type":"record","name":"Order","fields":[{"name":"order_id","type":"string"},{"name":"amount","type":"double"},{"name":"currency","type":"string","default":"USD"}]}'
sr = SchemaRegistryClient({"url": "http://localhost:8081"})
producer = SerializingProducer({
    "bootstrap.servers": "localhost:9092",
    "value.serializer": AvroSerializer(sr, schema_str),
})
producer.produce("orders", value={"order_id": "A1", "amount": 99.99, "currency": "EUR"})
producer.flush()
```

Supported formats: **Avro**, **Protobuf**, **JSON Schema**. Prefer Avro for compact encoding. Use Protobuf when sharing `.proto` across polyglot services.

## Admin API

```java
AdminClient admin = AdminClient.create(props);
// Create topic
admin.createTopics(List.of(new NewTopic("events", 12, (short) 3)
    .configs(Map.of("retention.ms", "604800000")))).all().get();
// Consumer group lag
admin.listConsumerGroupOffsets("payment-processor")
    .partitionsToOffsetAndMetadata().get()
    .forEach((tp, oam) -> System.out.println(tp + " -> " + oam.offset()));
```

## Client Libraries

| Language | Library | Notes |
|----------|---------|-------|
| Java | `org.apache.kafka:kafka-clients` | Reference impl, full feature parity |
| Python | `confluent-kafka` | librdkafka-backed, high perf, Schema Registry support |
| Node.js | `kafkajs` | Pure JS, async/await, no native deps |
| Go | `github.com/twmb/franz-go` | Modern, full feature set, prefer for new projects |
| Go | `github.com/IBM/sarama` | Mature, large community, aging API |

### Python Consumer Example (confluent-kafka)

```python
from confluent_kafka import Consumer

consumer = Consumer({
    "bootstrap.servers": "localhost:9092",
    "group.id": "analytics",
    "auto.offset.reset": "earliest",
    "enable.auto.commit": False,
})
consumer.subscribe(["page-views"])

try:
    while True:
        msg = consumer.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            print(f"Error: {msg.error()}")
            continue
        print(f"key={msg.key()} value={msg.value().decode()}")
        consumer.commit(asynchronous=False)
finally:
    consumer.close()
```

### Node.js Producer (KafkaJS)

```javascript
const { Kafka } = require("kafkajs");
const kafka = new Kafka({ clientId: "order-service", brokers: ["localhost:9092"] });
const producer = kafka.producer({ idempotent: true });
await producer.connect();
await producer.send({
  topic: "orders",
  messages: [{ key: "order-1", value: JSON.stringify({ item: "widget", qty: 5 }) }],
});
await producer.disconnect();
```

## Configuration Tuning Reference

### Producer

| Parameter | Default | Tuning Guidance |
|-----------|---------|-----------------|
| `batch.size` | 16384 | 32KB–64KB for throughput |
| `linger.ms` | 0 | 5–20ms to fill batches |
| `compression.type` | none | `lz4` (speed) or `zstd` (ratio) |
| `acks` | all | `all` for durability, `1` for speed |
| `buffer.memory` | 32MB | Increase under high load |
| `max.in.flight.requests.per.connection` | 5 | ≤5 with idempotence |

### Consumer

| Parameter | Default | Tuning Guidance |
|-----------|---------|-----------------|
| `fetch.min.bytes` | 1 | 1KB–1MB for throughput |
| `fetch.max.wait.ms` | 500 | Balance with fetch.min.bytes |
| `max.poll.records` | 500 | Tune to processing capacity |
| `session.timeout.ms` | 45000 | 10–30s for faster failure detection |
| `max.poll.interval.ms` | 300000 | Must exceed longest processing time |

### Broker

| Parameter | Guidance |
|-----------|----------|
| `num.partitions` | Default for auto-created topics; set explicitly per topic |
| `default.replication.factor` | 3 for production |
| `min.insync.replicas` | 2 (with `acks=all`, tolerates 1 replica failure) |
| `log.retention.hours` | 168 (7 days) default; tune per use case |
| `log.segment.bytes` | 1GB default; smaller = faster cleanup |
| `num.io.threads` | Match to disk count |
| `num.network.threads` | Match to CPU cores / 2 |

## Monitoring

- **JMX metrics**: Expose via Prometheus JMX Exporter. Key metrics:
  - `kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec`
  - `kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions` (alert if > 0)
  - `kafka.consumer:type=consumer-fetch-manager-metrics,name=records-lag-max`
- **Consumer lag**: Use `kafka-consumer-groups.sh --describe` or **Burrow** for lag monitoring with evaluation rules.
- **AKHQ** (formerly KafkaHQ): Web UI for topic browsing, consumer group management, schema registry inspection.
- **Alert on**: Under-replicated partitions, consumer lag growth, request latency p99.

## Security

### SASL + TLS

```properties
# Broker
listeners=SASL_SSL://0.0.0.0:9093
security.inter.broker.protocol=SASL_SSL
sasl.mechanism.inter.broker.protocol=SCRAM-SHA-512
sasl.enabled.mechanisms=SCRAM-SHA-512
ssl.keystore.location=/certs/kafka.keystore.jks
ssl.truststore.location=/certs/kafka.truststore.jks
# Client
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required \
  username="app-user" password="secret";
```

### ACLs

```bash
kafka-acls.sh --bootstrap-server broker:9093 --command-config admin.properties \
  --add --allow-principal User:app-user \
  --operation Read --operation Write \
  --topic orders --group payment-processor
```

## Docker / Local Development (KRaft)

See `assets/docker-compose.yml` for a full dev environment (broker, Schema Registry, Connect, AKHQ). Quick single-broker:

```yaml
services:
  kafka:
    image: apache/kafka:3.9.0
    ports: ["9092:9092"]
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
```

## Common Patterns

### Event Sourcing
Store all state changes as immutable events in a compacted topic (`cleanup.policy=compact`). Rebuild state by replaying.

### CQRS
Produce commands to a topic. Consumer processes commands, updates write model, publishes domain events. Read-model consumers project into query stores (Elasticsearch, Redis).

### Transactional Outbox
Write events to an `outbox` table in the same DB transaction. Debezium CDC tails the outbox and publishes to Kafka — at-least-once without two-phase commit.

### Dead Letter + Retry Topics

```
main-topic → consumer → (on failure) → retry-topic-1 (delay 1m)
                                      → retry-topic-2 (delay 10m)
                                      → dead-letter-topic (manual inspection)
```

Implement with separate consumer groups per retry topic. Use `message.timestamp.type=LogAppendTime` on retry topics for delay-based consumption.

## Testing

### Testcontainers (Java)

```java
@Testcontainers
class KafkaIntegrationTest {
    @Container
    static KafkaContainer kafka = new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.7.1"));
    @Test
    void shouldProduceAndConsume() {
        Properties props = new Properties();
        props.put("bootstrap.servers", kafka.getBootstrapServers());
    }
}
```

Use `MockProducer`/`MockConsumer` for unit tests. Use `testcontainers` (`KafkaContainer`) for integration tests in Java and Python.

## Common Pitfalls

1. **No message key** → random partition assignment → no ordering guarantees.
2. **`auto.offset.reset=latest`** on new groups → silently drops existing messages.
3. **`max.poll.interval.ms` too low** → consumer evicted during long processing.
4. **Partition count too low** → parallelism bottleneck; cannot decrease later.
5. **`acks=1` with `min.insync.replicas=2`** → no effect; ISR check requires `acks=all`.
6. **Not closing producers/consumers** → resource leaks, hanging transactions.
7. **Replication factor = 1** → single broker failure loses data.
8. **Ignoring consumer lag** → processing delays cascade into outages.
9. **Large messages (>1MB)** → increase `max.message.bytes`, `max.request.size`, `fetch.max.bytes`.
10. **Schema changes without compatibility** → deserialization failures in production.

## Reference Guides

Deep-dive references for advanced usage, troubleshooting, and operations:

| Document | Path | Contents |
|----------|------|----------|
| **Advanced Patterns** | `references/advanced-patterns.md` | EOS internals, transactional produce-consume, Streams topology design, windowing (tumbling/hopping/sliding/session), state store management (RocksDB tuning, in-memory, changelog), interactive queries, KTable FK joins, punctuators, error handling, DLQ/retry patterns, event sourcing, CQRS, outbox pattern with Debezium |
| **Troubleshooting** | `references/troubleshooting.md` | Consumer lag diagnosis, rebalancing storms (static group membership, cooperative rebalancing), under-replicated partitions, broker disk full, offset reset confusion, ordering guarantees, timeout tuning, producer failures, schema evolution conflicts, Connect task failures, JMX/Prometheus monitoring, log compaction gotchas |
| **Operations Guide** | `references/operations-guide.md` | Cluster sizing (disk/CPU/memory/network), partition count strategy, replication factor selection, broker config tuning, rolling upgrades, partition reassignment with throttling, preferred leader election, monitoring/alerting thresholds, backup/DR strategies, multi-datacenter with MirrorMaker 2, KRaft migration from ZooKeeper |

## Scripts

Executable helper scripts in `scripts/`:

| Script | Usage | Description |
|--------|-------|-------------|
| `kafka-local.sh` | `./scripts/kafka-local.sh start [topic1 ...]` | Start local KRaft Kafka cluster via Docker, create topics, produce test messages |
| `consumer-lag-check.sh` | `./scripts/consumer-lag-check.sh [group]` | Check consumer lag for all groups or a specific group, with threshold warnings |
| `topic-management.sh` | `./scripts/topic-management.sh create orders -p 12 -r 3` | Create, describe, alter, delete topics with partition/RF options |

## Asset Templates

Ready-to-use templates and configs in `assets/`:

| Asset | Language/Format | Description |
|-------|----------------|-------------|
| `docker-compose.yml` | YAML | Full dev environment: KRaft broker, Schema Registry, Kafka Connect, AKHQ UI |
| `producer-template.py` | Python | Avro producer with Schema Registry, delivery callbacks, graceful shutdown |
| `consumer-template.py` | Python | Manual-commit consumer with DLQ routing, graceful shutdown, batch processing |
| `streams-template.java` | Java | Kafka Streams topology with windowed aggregation, RocksDB tuning, EOS, error handling, interactive queries |
