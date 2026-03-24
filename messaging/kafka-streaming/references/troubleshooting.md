# Kafka Troubleshooting Guide

Diagnosis and resolution for common Kafka issues in production and development.

---

## Table of Contents

1. [Consumer Lag Diagnosis](#consumer-lag-diagnosis)
2. [Rebalancing Storms](#rebalancing-storms)
3. [Under-Replicated Partitions](#under-replicated-partitions)
4. [Broker Disk Full](#broker-disk-full)
5. [Offset Reset Confusion](#offset-reset-confusion)
6. [Message Ordering Guarantees](#message-ordering-guarantees)
7. [Consumer Timeout Tuning](#consumer-timeout-tuning)
8. [Producer Delivery Failures](#producer-delivery-failures)
9. [Schema Evolution Conflicts](#schema-evolution-conflicts)
10. [Connect Task Failures](#connect-task-failures)
11. [Monitoring with JMX/Prometheus](#monitoring-with-jmxprometheus)
12. [Log Compaction Gotchas](#log-compaction-gotchas)

---

## Consumer Lag Diagnosis

### Symptoms

- Processing delays increasing over time.
- Consumer group lag grows continuously (visible in `kafka-consumer-groups.sh --describe`).

### Check lag

```bash
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --describe --group my-consumer-group
```

Output columns: `TOPIC`, `PARTITION`, `CURRENT-OFFSET`, `LOG-END-OFFSET`, `LAG`.

### Common causes and fixes

| Cause | Fix |
|-------|-----|
| Slow processing per message | Profile and optimize processing logic; batch external calls |
| Too few consumers | Add instances (up to partition count) |
| Too few partitions | Increase partition count (cannot decrease) |
| Large message deserialization | Switch to more compact format; increase `fetch.max.bytes` |
| Uneven partition sizes (hot keys) | Improve key distribution; custom partitioner |
| GC pauses | Tune JVM heap and GC settings |
| Consumer rebalancing too frequently | See [Rebalancing Storms](#rebalancing-storms) |

### Monitoring

- **Burrow**: Evaluates lag trend (OK, WARNING, ERR) rather than raw numbers.
- **JMX metric**: `kafka.consumer:type=consumer-fetch-manager-metrics,client-id=*,name=records-lag-max`
- **Alert threshold**: Lag growing for >5 minutes, or absolute lag > N (tune per workload).

### Emergency: consumer is stuck

```bash
# Reset to latest (skip backlog)
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --group my-group --topic my-topic --reset-offsets --to-latest --execute

# Reset to specific timestamp
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --group my-group --topic my-topic --reset-offsets \
  --to-datetime "2024-01-15T10:00:00.000" --execute
```

**Warning**: Consumer group must be stopped before resetting offsets.

---

## Rebalancing Storms

### Symptoms

- Consumers frequently leaving and rejoining the group.
- Logs show repeated `Attempt to heartbeat failed since group is rebalancing`.
- Processing throughput drops to near-zero during storms.

### Causes

1. **`max.poll.interval.ms` exceeded**: Processing takes longer than the poll interval → consumer evicted.
2. **`session.timeout.ms` too low**: Heartbeat missed during GC pause or network blip.
3. **Frequent deployments**: Rolling restarts trigger cascading rebalances.
4. **Unstable consumers**: OOM crashes, container restarts.

### Fix 1: Static group membership

Assign a persistent `group.instance.id` per consumer. The broker doesn't trigger a rebalance when a known instance reconnects within `session.timeout.ms`:

```java
props.put(ConsumerConfig.GROUP_INSTANCE_ID_CONFIG, "consumer-pod-1");
props.put(ConsumerConfig.SESSION_TIMEOUT_MS_CONFIG, 300000); // 5 minutes for rolling deploys
```

### Fix 2: Cooperative rebalancing

```java
props.put(ConsumerConfig.PARTITION_ASSIGNMENT_STRATEGY_CONFIG,
    CooperativeStickyAssignor.class.getName());
```

Cooperative rebalancing only revokes partitions that need to move, instead of revoking all partitions from all consumers (eager protocol). Result: most consumers continue processing during rebalance.

### Fix 3: Tune timeouts

```properties
max.poll.interval.ms=600000      # 10 min — must exceed longest processing batch
max.poll.records=100              # reduce batch size if processing is slow
session.timeout.ms=45000          # default; increase for unstable networks
heartbeat.interval.ms=15000       # ~1/3 of session.timeout.ms
```

### Fix 4: KIP-848 server-side rebalancing (Kafka 4.0+)

New consumer group protocol where the broker manages partition assignment directly. Eliminates client-side rebalance coordination. Opt in:

```properties
group.protocol=consumer           # new protocol
```

---

## Under-Replicated Partitions

### Symptoms

- JMX metric `UnderReplicatedPartitions > 0`.
- `kafka-topics.sh --describe` shows ISR smaller than replication factor.

### Check

```bash
kafka-topics.sh --bootstrap-server broker:9092 \
  --describe --under-replicated-partitions
```

### Common causes

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| Broker down | Check broker logs, process status | Restart broker |
| Broker overloaded | High CPU, disk I/O, network | Add brokers, reduce load |
| Disk full | `df -h` on broker | Free space, increase retention |
| Network partition | Check connectivity between brokers | Fix network |
| Slow disk on follower | Disk latency metrics | Replace disk, move to SSD |
| `replica.lag.time.max.ms` too low | Follower can't catch up in time | Increase (default 30s) |

### Resolution

1. If broker is down: restart it. It will rejoin ISR after catching up.
2. If broker is overloaded: reassign partitions away from it.
3. If persistent: add brokers and rebalance partitions.

### Prevention

- Monitor `UnderReplicatedPartitions` and alert immediately (threshold: > 0 for > 5 minutes).
- Set `min.insync.replicas=2` with `replication.factor=3` — one replica can be down without blocking writes.
- Never set `min.insync.replicas >= replication.factor` — makes the topic unavailable if any replica fails.
- Use `unclean.leader.election.enable=false` (default) to prevent data loss.

---

## Broker Disk Full

### Symptoms

- Producers get `NotEnoughReplicasException` or `RecordTooLargeException`.
- Broker logs: `Log directory ... is offline`.
- Disk usage at 100%.

### Emergency response

```bash
# 1. Identify large topics
kafka-log-dirs.sh --bootstrap-server broker:9092 --describe | \
  jq '.brokers[].logDirs[].partitions[] | {topic: .topic, size: .size}' | \
  sort -t: -k2 -rn | head -20

# 2. Reduce retention for the largest topics
kafka-configs.sh --bootstrap-server broker:9092 \
  --alter --entity-type topics --entity-name big-topic \
  --add-config retention.ms=3600000  # 1 hour temporarily

# 3. Force log segment deletion
kafka-configs.sh --bootstrap-server broker:9092 \
  --alter --entity-type topics --entity-name big-topic \
  --add-config retention.bytes=1073741824  # 1GB cap
```

### Prevention

- **Alert at 70% disk usage**, critical at 85%.
- Set `log.retention.check.interval.ms=300000` (5 min) for faster cleanup.
- Configure `log.retention.bytes` per topic for bounded growth.
- Use `log.dirs` with multiple disk mounts and JBOD — Kafka balances across them.
- Monitor `kafka.log:type=LogFlushRateAndTimeMs` for disk performance degradation.

---

## Offset Reset Confusion

### The problem

`auto.offset.reset` only applies when **no committed offset exists** for the consumer group on that partition. It does NOT apply on every restart.

### Scenarios

| Scenario | Behavior |
|----------|----------|
| New group, `earliest` | Reads from beginning |
| New group, `latest` | Reads only new messages |
| Existing group, restarts | Resumes from last committed offset (ignores `auto.offset.reset`) |
| Existing group, topic deleted and recreated | `auto.offset.reset` applies (old offsets invalid) |
| Committed offset expired (`offsets.retention.minutes`) | `auto.offset.reset` applies |

### Common mistakes

- Setting `auto.offset.reset=latest` and wondering why replaying old data doesn't work → offset is already committed.
- Forgetting that `offsets.retention.minutes` (default 7 days, was 1 day pre-2.0) can expire offsets for inactive groups.
- Using `--to-earliest` to reset but not stopping consumers first → reset is overwritten immediately.

### Manual offset management

```bash
# Dry run first
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --group my-group --topic my-topic --reset-offsets --to-earliest --dry-run

# Execute (group must be stopped)
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --group my-group --topic my-topic --reset-offsets --to-earliest --execute

# Reset specific partition to specific offset
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --group my-group --topic my-topic:2 --reset-offsets --to-offset 1000 --execute
```

---

## Message Ordering Guarantees

### What Kafka guarantees

- **Within a partition**: Total order. Messages with the same key go to the same partition (via default partitioner).
- **Across partitions**: No ordering guarantee.
- **With idempotent producer**: Ordering maintained even with retries (`max.in.flight.requests.per.connection ≤ 5`).

### Common ordering bugs

| Bug | Cause | Fix |
|-----|-------|-----|
| Messages with same key on different partitions | Partition count changed | Don't change partition count; create new topic and migrate |
| Out-of-order within partition | Non-idempotent producer with retries + `max.in.flight > 1` | Enable idempotence |
| Processing order differs from produce order | Multiple consumer threads processing from same partition | Process partition records sequentially |
| Key changed mid-stream | Application changed key derivation logic | Ensure key derivation is stable |

### Partition count changes break ordering

When you increase partition count, keys may hash to different partitions. Existing data stays in old partitions; new data goes to new assignments. For ordering-sensitive topics:

1. Create a new topic with the desired partition count.
2. Migrate consumers to the new topic.
3. Use a bridge consumer to forward from old to new topic (re-keys all messages).

---

## Consumer Timeout Tuning

### Three timeout parameters

```
max.poll.interval.ms    ← time between poll() calls (processing time)
session.timeout.ms      ← heartbeat failure detection
heartbeat.interval.ms   ← how often heartbeat is sent
```

### Relationships

- `heartbeat.interval.ms` should be ≤ 1/3 of `session.timeout.ms`.
- `max.poll.interval.ms` must exceed your longest processing batch.
- `session.timeout.ms` must be within broker's `group.min.session.timeout.ms` and `group.max.session.timeout.ms`.

### Tuning guide

| Workload | `max.poll.interval.ms` | `max.poll.records` | `session.timeout.ms` |
|----------|----------------------|-------------------|---------------------|
| Fast processing (<1s/msg) | 300000 (default) | 500 | 30000 |
| Moderate (1-10s/msg) | 600000 | 50–100 | 45000 |
| Slow (10-60s/msg) | 900000 | 10–20 | 60000 |
| Very slow (>60s/msg) | 1800000 | 1–5 | 120000 |

### Diagnosis

If you see `Member ... has been removed from the group due to consumer poll timeout`:
1. Check what's slow in processing (DB calls, HTTP calls, computation).
2. Reduce `max.poll.records` to process fewer messages per batch.
3. Increase `max.poll.interval.ms` if processing legitimately takes longer.
4. Move heavy processing to a separate thread pool and commit offsets asynchronously.

---

## Producer Delivery Failures

### Common errors

| Error | Cause | Fix |
|-------|-------|-----|
| `TimeoutException` | Broker unreachable or slow | Check network, increase `delivery.timeout.ms` |
| `RecordTooLargeException` | Message > `max.request.size` | Increase `max.request.size` and broker's `message.max.bytes` |
| `NotEnoughReplicasException` | ISR < `min.insync.replicas` | Check broker health, reduce `min.insync.replicas` temporarily |
| `SerializationException` | Schema mismatch | Fix schema, check Schema Registry |
| `BufferExhaustedException` | `buffer.memory` full | Increase buffer or reduce send rate |
| `OutOfOrderSequenceException` | Idempotent producer state lost | Restart producer (new instance) |

### Delivery timeout chain

```
delivery.timeout.ms ≥ linger.ms + retry.backoff.ms * retries + request.timeout.ms
```

Default `delivery.timeout.ms=120000` (2 min). If exceeded, the `send()` callback receives a `TimeoutException`.

### Retry configuration

```java
props.put(ProducerConfig.RETRIES_CONFIG, Integer.MAX_VALUE);
props.put(ProducerConfig.RETRY_BACKOFF_MS_CONFIG, 100);
props.put(ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG, 120000);
props.put(ProducerConfig.REQUEST_TIMEOUT_MS_CONFIG, 30000);
```

### Callback-based error handling

```java
producer.send(record, (metadata, exception) -> {
    if (exception != null) {
        if (exception instanceof RetriableException) {
            log.warn("Retriable error, will retry: {}", exception.getMessage());
        } else {
            log.error("Fatal send error", exception);
            alerting.fire("kafka-send-failure", exception);
        }
    }
});
```

---

## Schema Evolution Conflicts

### Symptoms

- Consumers throw `SerializationException` after a schema change.
- Schema Registry rejects new schema registration: `409 Conflict`.

### Compatibility rules

| Mode | Add field | Remove field | Rename field |
|------|----------|-------------|-------------|
| BACKWARD | With default only | Yes | No (= remove + add) |
| FORWARD | Yes | With default only | No |
| FULL | With default only | With default only | No |

### Common mistakes

1. **Adding required field without default** (breaks BACKWARD): Old consumers can't read new data.
   ```json
   // BAD: breaks backward compatibility
   {"name": "email", "type": "string"}
   // GOOD: has default
   {"name": "email", "type": "string", "default": ""}
   ```

2. **Removing field without default** (breaks FORWARD): New consumers can't read old data.

3. **Changing field type**: Almost always breaks compatibility. Use union types instead:
   ```json
   {"name": "amount", "type": ["double", "string"]}
   ```

### Recovery

```bash
# Check compatibility before registering
curl -X POST http://schema-registry:8081/compatibility/subjects/orders-value/versions/latest \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"schema": "{...}"}'

# If stuck, temporarily set NONE (dangerous)
curl -X PUT http://schema-registry:8081/config/orders-value \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"compatibility": "NONE"}'

# Register the new schema, then restore
curl -X PUT http://schema-registry:8081/config/orders-value \
  -d '{"compatibility": "BACKWARD"}'
```

### Best practices

- Always set defaults on new fields.
- Use FULL compatibility for critical topics.
- Test compatibility in CI/CD before deploying schema changes.
- Version your schemas independently of application versions.

---

## Connect Task Failures

### Symptoms

- Connector status shows `FAILED` tasks.
- Data stops flowing through the connector.

### Diagnosis

```bash
# Check connector status
curl http://connect:8083/connectors/my-connector/status | jq

# Check task status
curl http://connect:8083/connectors/my-connector/tasks/0/status | jq

# Get task errors
curl http://connect:8083/connectors/my-connector/tasks/0/status | jq '.trace'
```

### Common failures

| Error | Cause | Fix |
|-------|-------|-----|
| `ConnectException: Failed to connect` | Source DB unreachable | Check connectivity, credentials |
| `DataException: Schema mismatch` | Schema change in source | Update converter config, check SR |
| `RetriableException` | Transient network error | Task usually auto-retries |
| `OutOfMemoryError` | Too many tasks, large messages | Reduce `tasks.max`, increase heap |
| `SchemaRegistryException` | SR unreachable | Check SR health, network |

### Restart failed tasks

```bash
# Restart specific task
curl -X POST http://connect:8083/connectors/my-connector/tasks/0/restart

# Restart entire connector
curl -X POST http://connect:8083/connectors/my-connector/restart

# Delete and recreate
curl -X DELETE http://connect:8083/connectors/my-connector
curl -X POST http://connect:8083/connectors -H "Content-Type: application/json" -d @config.json
```

### Error handling config

```json
{
  "errors.tolerance": "all",
  "errors.deadletterqueue.topic.name": "dlq-my-connector",
  "errors.deadletterqueue.context.headers.enable": true,
  "errors.log.enable": true,
  "errors.log.include.messages": true,
  "errors.retry.delay.max.ms": 60000,
  "errors.retry.timeout": 300000
}
```

---

## Monitoring with JMX/Prometheus

### JMX Exporter setup

Add to broker startup:

```bash
KAFKA_OPTS="-javaagent:/opt/jmx_exporter/jmx_prometheus_javaagent.jar=7071:/opt/jmx_exporter/kafka-broker.yml"
```

### Critical broker metrics

| Metric | Alert Threshold | Meaning |
|--------|----------------|---------|
| `UnderReplicatedPartitions` | > 0 for 5 min | Replicas falling behind |
| `ActiveControllerCount` | != 1 (exactly one broker) | No controller = cluster inoperable |
| `OfflinePartitionsCount` | > 0 | Partitions with no leader |
| `RequestHandlerAvgIdlePercent` | < 0.3 | Broker overloaded |
| `NetworkProcessorAvgIdlePercent` | < 0.3 | Network thread saturation |
| `MessagesInPerSec` | Baseline deviation > 50% | Unexpected traffic change |
| `BytesInPerSec` / `BytesOutPerSec` | Near network capacity | Network bottleneck |

### Critical consumer metrics

| Metric | Alert Threshold |
|--------|----------------|
| `records-lag-max` | Growing for > 5 min |
| `records-consumed-rate` | Drops to 0 |
| `commit-latency-avg` | > 500ms |
| `rebalance-rate-per-hour` | > 5 |

### Critical producer metrics

| Metric | Alert Threshold |
|--------|----------------|
| `record-error-rate` | > 0 |
| `record-send-rate` | Unexpected drop |
| `request-latency-avg` | > 100ms |
| `batch-size-avg` | Much smaller than `batch.size` (not batching efficiently) |
| `buffer-available-bytes` | < 10% of `buffer.memory` |

### Grafana dashboard essentials

1. Broker: Messages in/out rate, bytes in/out, request latency p99, under-replicated partitions.
2. Topics: Per-topic message rate, byte rate, partition count.
3. Consumer groups: Lag per partition, commit rate, rebalance count.
4. Connect: Task status, record rate, error rate.

### Prometheus recording rules

```yaml
groups:
  - name: kafka
    rules:
      - record: kafka:consumer_lag:sum_by_group
        expr: sum by (consumergroup) (kafka_consumergroup_lag)
      - alert: KafkaConsumerLagHigh
        expr: kafka:consumer_lag:sum_by_group > 10000
        for: 10m
        labels:
          severity: warning
```

---

## Log Compaction Gotchas

### How compaction works

For topics with `cleanup.policy=compact`, Kafka retains only the latest value per key. The log cleaner runs periodically and removes older duplicates.

### Common issues

1. **Null key messages**: Cannot be compacted (no key to deduplicate). They are retained until normal retention applies. Don't use compacted topics with null keys.

2. **Tombstones (null values)**: A message with a null value is a tombstone — it marks a key for deletion. After `delete.retention.ms` (default 24h), both the tombstone and the key are removed.

3. **Compaction lag**: Compaction doesn't happen immediately. `min.compaction.lag.ms` (default 0) controls minimum time before a message is eligible. `max.compaction.lag.ms` (default unlimited) guarantees compaction within this time.

4. **Active segment not compacted**: The current active segment is never compacted. If `segment.bytes` is large and write rate is low, old data may persist long after compaction should have removed it. Reduce `segment.bytes` or `segment.ms` for timely compaction.

5. **Log cleaner threads stalled**: If the log cleaner dies or stalls, compaction stops silently. Monitor `kafka.log:type=LogCleanerManager,name=max-dirty-ratio`. Alert if it stays at 1.0.

6. **Compaction + retention**: You can combine both: `cleanup.policy=compact,delete`. Compaction runs normally, but segments older than `retention.ms` are deleted entirely.

### Debugging compaction

```bash
# Check cleaner status
kafka-log-dirs.sh --bootstrap-server broker:9092 --describe

# Check topic configuration
kafka-configs.sh --bootstrap-server broker:9092 \
  --entity-type topics --entity-name my-topic --describe
```

### Key JMX metrics for compaction

- `kafka.log:type=LogCleaner,name=max-clean-time-secs` — if increasing, cleaner is struggling.
- `kafka.log:type=LogCleanerManager,name=max-dirty-ratio` — 1.0 means compaction isn't keeping up.
- `kafka.log:type=LogCleaner,name=cleaner-recopy-percent` — high values mean little deduplication happening.
