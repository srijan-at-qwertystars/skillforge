---
name: kafka-streaming
description: >
  Guide for Apache Kafka event streaming: brokers, topics, partitions, replication,
  producers (acks, idempotency, batching), consumers (groups, offsets, rebalancing),
  Kafka Streams (KStream, KTable, windowing, joins, state stores), Kafka Connect
  (source/sink connectors, transforms), Schema Registry (Avro, Protobuf, JSON Schema),
  topic design, security (SASL, TLS, ACLs), monitoring (JMX, consumer lag), and
  Docker/local setup. Use when building event-driven architectures, streaming pipelines,
  real-time analytics, CDC, or log aggregation with Kafka. Do NOT use for RabbitMQ/AMQP
  message queuing, Redis pub/sub, simple in-process queues, AWS SQS/SNS, Google Pub/Sub,
  Azure Service Bus, MQTT/IoT protocols, or synchronous request-reply patterns.
---

# Apache Kafka Streaming

## Core Concepts

### Cluster Architecture
- A Kafka **cluster** consists of one or more **brokers** (servers). Kafka 3.x+ supports KRaft mode (no ZooKeeper).
- Each broker stores partitions and serves client requests. One broker acts as the **controller**.
- Use KRaft mode for new deployments. Set `process.roles=broker,controller` for combined mode or split roles in production.

### Topics, Partitions, and Replication
- A **topic** is a named, append-only log divided into **partitions**.
- Each partition is an ordered, immutable sequence of records, each assigned a sequential **offset**.
- Partitions enable parallelism: more partitions = more consumer concurrency.
- **Replication factor** (typically 3) determines how many broker copies exist per partition.
- One replica is the **leader** (handles reads/writes); others are **followers** (ISR = in-sync replicas).
- Set `min.insync.replicas=2` with `acks=all` for durability without sacrificing too much throughput.

### Records
- A record consists of: **key** (optional, used for partitioning), **value** (payload), **timestamp**, and **headers**.
- Keys determine partition assignment via consistent hashing. Same key → same partition → ordered processing.

## Producer Patterns

### Configuration Essentials
```properties
# Durability: wait for all ISR replicas
acks=all
# Prevent duplicates on retry
enable.idempotence=true
# Throughput tuning
batch.size=65536
linger.ms=5
compression.type=lz4
# Retry handling
retries=2147483647
delivery.timeout.ms=120000
max.in.flight.requests.per.connection=5
```

### Partitioning Strategy
- Default: hash(key) % num_partitions. Records with same key always go to same partition.
- Use custom partitioners only when business logic demands non-key-based routing.
- Null keys use sticky partitioning (round-robin per batch) in Kafka 3.x+.

### Idempotent and Transactional Producers
- Enable `enable.idempotence=true` (default in Kafka 3.x+) for exactly-once per partition.
- For cross-partition atomic writes, use transactions:
```java
producer.initTransactions();
try {
    producer.beginTransaction();
    producer.send(new ProducerRecord<>("orders", key, value));
    producer.send(new ProducerRecord<>("audit", key, auditEvent));
    producer.commitTransaction();
} catch (Exception e) {
    producer.abortTransaction();
}
```

### Compression and Batching
- Prefer `lz4` for speed or `zstd` for compression ratio. Set at producer level.
- Increase `batch.size` (default 16384) and `linger.ms` (default 0) for throughput.
- Trade-off: higher linger.ms = more latency, better batching.

## Consumer Patterns

### Consumer Groups
- Each consumer in a group reads from exclusive partitions. Max useful consumers = partition count.
- Kafka guarantees: one partition → one consumer per group at any time.
- Multiple consumer groups can independently read the same topic (fan-out pattern).

### Offset Management
```java
// Auto-commit (at-least-once, simpler)
props.put("enable.auto.commit", "true");
props.put("auto.commit.interval.ms", "5000");

// Manual commit (precise control)
props.put("enable.auto.commit", "false");
// After processing:
consumer.commitSync(Map.of(
    new TopicPartition("orders", 0),
    new OffsetAndMetadata(lastOffset + 1)
));
```
- `auto.offset.reset`: `earliest` (replay all) or `latest` (new messages only).
- Store offsets in Kafka (`__consumer_offsets` topic) by default. External stores possible for exactly-once with external systems.

### Rebalancing
- Triggered by: consumer join/leave, topic partition change, or heartbeat timeout.
- Use **cooperative sticky assignor** to minimize stop-the-world rebalances:
```properties
partition.assignment.strategy=org.apache.kafka.clients.consumer.CooperativeStickyAssignor
```
- Tune `session.timeout.ms` (default 45s), `heartbeat.interval.ms` (default 3s), `max.poll.interval.ms` (default 5min).
- Use **static group membership** (`group.instance.id`) for stable consumers to avoid rebalance on restart.

### Exactly-Once Semantics (EOS)
- Requires: idempotent producer + transactional producer + `read_committed` isolation on consumer.
- Set `isolation.level=read_committed` on consumers to skip uncommitted transactional records.

## Kafka Streams

### Topology Basics
- A Kafka Streams app defines a **topology**: a DAG of stream processors.
```java
StreamsBuilder builder = new StreamsBuilder();
KStream<String, String> source = builder.stream("input-topic");
source.filter((k, v) -> v != null)
      .mapValues(v -> v.toUpperCase())
      .to("output-topic");
KafkaStreams streams = new KafkaStreams(builder.build(), props);
streams.start();
```

### KStream vs KTable
- **KStream**: unbounded stream of events. Each record is independent. Use for event-by-event processing.
- **KTable**: changelog stream. Latest value per key. Use for stateful lookups and aggregations.
- Convert between them: `stream.toTable()` and `table.toStream()`.
```java
KTable<String, Long> wordCounts = source
    .flatMapValues(v -> Arrays.asList(v.split("\\s+")))
    .groupBy((k, word) -> word)
    .count();
```

### Windowing
- **Tumbling**: fixed, non-overlapping. `TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(5))`
- **Hopping**: fixed, overlapping. `TimeWindows.ofSizeAndGrace(Duration.ofMinutes(5), Duration.ofMinutes(1))`
- **Sliding**: for joins. `SlidingWindows.ofTimeDifferenceWithNoGrace(Duration.ofMinutes(10))`
- **Session**: activity-based, gap-driven. `SessionWindows.ofInactivityGapWithNoGrace(Duration.ofMinutes(30))`
- Always configure grace periods for late-arriving data.

### Joins
| Join Type | Windowed? | Use Case |
|-----------|-----------|----------|
| KStream-KStream | Yes (required) | Correlate events within time window |
| KStream-KTable | No | Enrich stream with latest lookup value |
| KStream-GlobalKTable | No | Enrich regardless of partitioning |
| KTable-KTable | No | Combine two evolving state tables |

### State Stores
- Backed by RocksDB locally + changelog topics in Kafka for fault tolerance.
- Enable **interactive queries** to expose state via REST:
```java
ReadOnlyKeyValueStore<String, Long> store =
    streams.store(StoreQueryParameters.fromNameAndType(
        "counts-store", QueryableStoreTypes.keyValueStore()));
Long count = store.get("someKey");
```
- Set `state.dir` for persistent storage location. Clean up with `streams.cleanUp()` only during development.

## Kafka Connect

### Architecture
- **Workers** run connectors in standalone or distributed mode. Use distributed for production.
- **Source connectors** pull data into Kafka (e.g., JDBC, Debezium CDC, file).
- **Sink connectors** push data from Kafka to external systems (e.g., Elasticsearch, S3, JDBC).

### Connector Configuration Example
```json
{
  "name": "postgres-source",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "db-host",
    "database.port": "5432",
    "database.user": "kafka_connect",
    "database.dbname": "mydb",
    "topic.prefix": "cdc",
    "plugin.name": "pgoutput",
    "transforms": "route",
    "transforms.route.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.route.regex": "cdc\\.public\\.(.*)",
    "transforms.route.replacement": "db.$1"
  }
}
```

### Single Message Transforms (SMTs)
- Apply lightweight per-record transformations: rename fields, route topics, mask data, insert metadata.
- Common SMTs: `ExtractField`, `ReplaceField`, `TimestampConverter`, `RegexRouter`, `InsertField`.

### Converters
- Define serialization format: `JsonConverter`, `AvroConverter`, `ProtobufConverter`, `StringConverter`.
- Set `key.converter` and `value.converter` independently. Pair schema-aware converters with Schema Registry.

## Schema Registry

### Schema Formats
- **Avro**: compact binary, strong evolution support. Default choice for Kafka-centric systems.
- **Protobuf**: cross-language, gRPC-compatible. Use for polyglot environments.
- **JSON Schema**: human-readable. Use for REST/web integrations or quick prototyping.

### Subject Naming and Compatibility
- Default subject strategy: `<topic>-key`, `<topic>-value`.
- Use `TopicRecordNameStrategy` for multiple event types per topic.
- `BACKWARD` (default): new schema can read old data. Add optional fields only.
- `FORWARD`: old schema can read new data. `FULL`: both directions. `NONE`: no checks.
```bash
curl -X PUT -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"compatibility":"BACKWARD"}' \
  http://localhost:8081/config/orders-value
```

### Schema Evolution Rules
- Avro: add fields with defaults, use union types (`["null", "string"]`), never reuse field names.
- Protobuf: never reuse field numbers, add fields only, mark removed fields as `reserved`.

## Topic Design

### Naming Conventions
- Use dot-separated hierarchy: `<domain>.<entity>.<event>` (e.g., `payments.orders.created`).
- Avoid special characters. Use lowercase. Be consistent across the organization.

### Partition Count
- Start with `max(expected_throughput_MB / 10, expected_consumer_count)`.
- Can only increase partitions, never decrease. Over-partition slightly rather than under-partition.
- Typical range: 6–50 partitions per topic for most workloads.

### Retention and Cleanup
```properties
retention.ms=604800000
retention.bytes=1073741824
# For event streams:
cleanup.policy=delete
# For changelog/state/lookup tables:
cleanup.policy=compact
min.cleanable.dirty.ratio=0.5
```

## Security

### Authentication
- **SASL/SCRAM**: username/password. Good for most deployments.
- **SASL/OAUTHBEARER**: OAuth2/OIDC token-based. Modern preferred approach.
- **mTLS**: mutual TLS with client certificates. Strongest transport-level auth.

### Encryption and ACLs
```properties
listeners=SASL_SSL://0.0.0.0:9093
ssl.keystore.location=/certs/kafka.server.keystore.jks
ssl.truststore.location=/certs/kafka.server.truststore.jks
security.inter.broker.protocol=SASL_SSL
```
```bash
kafka-acls.sh --bootstrap-server localhost:9093 \
  --add --allow-principal User:producer-app \
  --operation Write --topic orders
kafka-acls.sh --bootstrap-server localhost:9093 \
  --add --allow-principal User:consumer-app \
  --operation Read --topic orders --group order-processors
```

## Monitoring

### Key JMX Metrics
| Metric | Alert When |
|--------|-----------|
| `UnderReplicatedPartitions` | > 0 |
| `RequestHandlerAvgIdlePercent` | < 0.3 |
| `MessagesInPerSec` | Baseline deviation > 50% |
| `records-lag-max` (consumer) | Growing consistently |
| `TotalTimeMs` (Produce p99) | > 100ms |

### Consumer Lag Monitoring
```bash
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group my-consumer-group
```
- Use Burrow, Kafka Lag Exporter, or Prometheus + Grafana for continuous monitoring.

## Docker / Local Setup (KRaft Mode)

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
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      CLUSTER_ID: MkU3OEVBNTcwNTJENDM2Qk
  schema-registry:
    image: confluentinc/cp-schema-registry:7.7.0
    ports: ["8081:8081"]
    environment:
      SCHEMA_REGISTRY_HOST_NAME: schema-registry
      SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS: kafka:9092
    depends_on: [kafka]
```

## Client Libraries

### Java
```java
Properties props = new Properties();
props.put("bootstrap.servers", "localhost:9092");
props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
props.put("acks", "all");
KafkaProducer<String, String> producer = new KafkaProducer<>(props);
producer.send(new ProducerRecord<>("topic", "key", "value"),
    (meta, ex) -> { if (ex != null) ex.printStackTrace(); });
```

### Node.js (kafkajs)
```javascript
const { Kafka } = require('kafkajs');
const kafka = new Kafka({ clientId: 'my-app', brokers: ['localhost:9092'] });
const producer = kafka.producer({ idempotent: true });
await producer.connect();
await producer.send({
  topic: 'orders',
  messages: [{ key: 'order-1', value: JSON.stringify({ amount: 99.99 }) }],
});
```

### Python (confluent-kafka)
```python
from confluent_kafka import Producer, Consumer
producer = Producer({'bootstrap.servers': 'localhost:9092', 'acks': 'all'})
producer.produce('orders', key='order-1', value='{"amount": 99.99}')
producer.flush()

consumer = Consumer({
    'bootstrap.servers': 'localhost:9092', 'group.id': 'processors',
    'auto.offset.reset': 'earliest', 'enable.auto.commit': False,
})
consumer.subscribe(['orders'])
msg = consumer.poll(1.0)
if msg and not msg.error():
    print(f"{msg.key()}: {msg.value()}")
    consumer.commit(message=msg)
```

### Go (confluent-kafka-go)
```go
import "github.com/confluentinc/confluent-kafka-go/v2/kafka"
p, _ := kafka.NewProducer(&kafka.ConfigMap{"bootstrap.servers": "localhost:9092", "acks": "all"})
topic := "orders"
p.Produce(&kafka.Message{
    TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
    Key: []byte("order-1"), Value: []byte(`{"amount":99.99}`),
}, nil)
p.Flush(5000)
```

## Common Pitfalls and Troubleshooting

### Pitfalls
- **Too few partitions**: limits consumer parallelism. Cannot decrease later.
- **Large messages**: default `max.message.bytes` is 1MB. Use claim-check pattern for large payloads.
- **Rebalance storms**: tune `session.timeout.ms`, use static membership, adopt cooperative assignor.
- **Commit before processing**: causes data loss. Always commit after successful processing.
- **No consumer lag monitoring**: silent processing delays. Always alert on growing lag.
- **Schema-less production topics**: leads to deserialization failures. Enforce Schema Registry.
- **Ignoring `max.poll.interval.ms`**: slow processing triggers rebalance. Increase or reduce `max.poll.records`.

### Troubleshooting
1. **Connection refused**: verify `advertised.listeners` matches client-accessible hostname/port.
2. **Leader not available**: topic not created or ISR empty. Check broker logs.
3. **Consumer not receiving**: verify group.id, subscription, `auto.offset.reset`, partition assignment.
4. **Duplicates**: enable idempotent producer; implement idempotent consumer processing.
5. **High latency**: check `linger.ms`, `batch.size`, compression, network, broker disk I/O.
6. **Schema compatibility error**: verify Schema Registry compatibility mode and schema changes.
