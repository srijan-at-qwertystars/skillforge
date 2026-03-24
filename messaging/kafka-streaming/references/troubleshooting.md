# Apache Kafka Troubleshooting Guide

A comprehensive reference for diagnosing and resolving common Kafka operational issues in production environments.

---

## Table of Contents

1. [Consumer Lag](#1-consumer-lag)
2. [Rebalancing Storms](#2-rebalancing-storms)
3. [Stuck Consumers](#3-stuck-consumers)
4. [Broker Under-Replicated Partitions](#4-broker-under-replicated-partitions)
5. [ISR Shrinkage](#5-isr-shrinkage)
6. [Log Compaction Issues](#6-log-compaction-issues)
7. [Producer Timeout / Retry Storms](#7-producer-timeout--retry-storms)
8. [Memory Pressure / Buffer Pool Exhaustion](#8-memory-pressure--buffer-pool-exhaustion)
9. [Offset Reset Confusion](#9-offset-reset-confusion)
10. [Schema Registry Compatibility Errors](#10-schema-registry-compatibility-errors)
11. [Cluster Upgrade Procedures](#11-cluster-upgrade-procedures)

---

## 1. Consumer Lag

Consumer lag is the difference between the latest offset produced to a partition and the last committed offset for a consumer group. Persistent or growing lag means consumers cannot keep up with producers.

### Symptoms

- Messages take longer and longer to be processed after being produced.
- Monitoring dashboards show consumer group offset falling behind the log-end offset.
- End-to-end latency increases over time.
- Alerts fire on `records-lag-max` consumer metric.

### Root Causes

| Cause | Description |
|---|---|
| **Slow processing** | Each message takes too long to process (heavy computation, synchronous external calls, database writes). |
| **Insufficient consumers** | Fewer consumer instances than partitions, leaving some partitions unassigned or overloaded. |
| **GC pauses** | Long JVM garbage collection pauses freeze the consumer, preventing it from polling and processing. |
| **Network issues** | High latency or packet loss between consumers and brokers increases fetch times. |
| **Skewed partitions** | Non-uniform key distribution causes some partitions to receive disproportionate traffic. |
| **Large messages** | Oversized records slow deserialization and processing. |

### Diagnostic Commands

```bash
# Check consumer group lag for all partitions
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --describe --group <consumer-group>

# Example output columns:
# TOPIC  PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID  HOST  CLIENT-ID

# Monitor lag continuously (watch every 5 seconds)
watch -n 5 "kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --describe --group <consumer-group>"

# Check per-partition production rate (messages in per second)
kafka-run-class.sh kafka.tools.GetOffsetShell \
  --broker-list <broker>:9092 --topic <topic> --time -1

# List all consumer groups
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 --list

# Check JVM GC activity on consumer hosts
jstat -gcutil <consumer-pid> 1000

# Check consumer JMX metrics
# Key metrics: records-lag-max, records-consumed-rate, fetch-latency-avg
```

### Fixes

1. **Scale consumers horizontally**: Add more consumer instances to the group (up to the number of partitions).

   ```properties
   # A consumer group with N partitions should ideally have N consumers
   # Each consumer handles partition_count / consumer_count partitions
   ```

2. **Increase partitions** (if consumers already equal partitions and load is still too high):

   ```bash
   kafka-topics.sh --bootstrap-server <broker>:9092 \
     --alter --topic <topic> --partitions <new-count>
   ```

   > ⚠️ **Warning**: Increasing partitions changes key-based routing. Messages with the same key may land on different partitions after the change.

3. **Tune `max.poll.records`**: Reduce the batch size so each poll returns fewer records, reducing per-poll processing time.

   ```properties
   max.poll.records=100   # Default is 500; lower if processing is heavy
   ```

4. **Reduce processing time per record**:
   - Move heavy work to async threads or a separate processing pipeline.
   - Cache frequently accessed external data.
   - Use batch writes to databases instead of per-record writes.

5. **Tune GC**: Switch to G1GC or ZGC, increase heap size, or reduce allocation rate.

   ```bash
   # Recommended JVM flags for consumers
   -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -Xms4g -Xmx4g
   ```

6. **Tune fetch settings**:

   ```properties
   fetch.min.bytes=1          # Don't wait for large fetches if lag is high
   fetch.max.wait.ms=100      # Reduce broker-side wait time
   max.partition.fetch.bytes=1048576  # 1 MB per partition per fetch
   ```

---

## 2. Rebalancing Storms

A rebalancing storm occurs when consumer group rebalances trigger repeatedly in quick succession, causing prolonged periods where no messages are processed.

### Symptoms

- Frequent `Revoking previously assigned partitions` log entries.
- Consumer group state oscillates between `PreparingRebalance` and `Stable`.
- Throughput drops to near zero during rebalance cascades.
- `rebalance-latency-avg` and `rebalance-rate-per-hour` metrics spike.

### Root Causes

| Cause | Description |
|---|---|
| **Flapping consumers** | Consumers repeatedly joining and leaving the group (deployment issues, health check failures, OOM kills). |
| **Long processing time** | Processing between polls exceeds `max.poll.interval.ms`, causing the consumer to be kicked out. |
| **Session timeout too low** | `session.timeout.ms` is shorter than typical GC pauses or network hiccups, triggering false evictions. |
| **Heartbeat interval too high** | `heartbeat.interval.ms` is too close to `session.timeout.ms`, not giving enough margin. |
| **Eager rebalance protocol** | The default eager (stop-the-world) assignor revokes all partitions on every rebalance. |

### How to Diagnose

```bash
# Check consumer group state
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --describe --group <consumer-group> --state

# Look for frequent rebalance logs in consumer application
grep -i "rebalance\|revok\|assign\|JoinGroup\|SyncGroup" /var/log/app/consumer.log | tail -50

# Check how often the group coordinator changes
grep "GroupCoordinator" /var/log/app/consumer.log

# Monitor the group coordinator broker logs for rebalance triggers
grep "member.*failed\|Preparing to rebalance\|Stabilized group" \
  /var/log/kafka/server.log | tail -30

# Check consumer JMX: rebalance-rate-per-hour, last-rebalance-seconds-ago
```

### Fixes

1. **Use Cooperative Sticky Assignor** (Kafka 2.4+): Avoids stop-the-world rebalances by only migrating affected partitions.

   ```properties
   partition.assignment.strategy=org.apache.kafka.clients.consumer.CooperativeStickyAssignor
   ```

   > 📝 **Note**: All consumers in the group must use the same assignor. Roll this change out carefully during a deployment.

2. **Enable Static Group Membership** (Kafka 2.3+): Consumers get a persistent identity, so restarts don't trigger rebalances if they rejoin within `session.timeout.ms`.

   ```properties
   group.instance.id=consumer-host-01   # Unique per consumer instance
   session.timeout.ms=300000            # 5 minutes — gives time to restart
   ```

3. **Tune heartbeat, session, and poll intervals**:

   ```properties
   # Recommended relationship:
   # heartbeat.interval.ms < session.timeout.ms / 3
   # max.poll.interval.ms > maximum processing time per batch

   heartbeat.interval.ms=3000       # Default: 3000
   session.timeout.ms=45000         # Default: 45000 (increase from 10000 if needed)
   max.poll.interval.ms=600000      # Default: 300000 (increase if processing is slow)
   ```

4. **Reduce processing time per poll**:

   ```properties
   max.poll.records=50  # Smaller batches finish faster, staying within poll interval
   ```

5. **Graceful shutdown**: Ensure consumers call `consumer.close()` on shutdown so the coordinator can immediately reassign partitions without waiting for session timeout.

---

## 3. Stuck Consumers

A stuck consumer is one that has stopped making progress — it is not processing messages, not committing offsets, and may or may not still be sending heartbeats.

### Symptoms

- Consumer lag grows continuously for specific partitions.
- Consumer application appears healthy (process is running, heartbeats are sent) but no messages are processed.
- No new offset commits for the consumer group despite messages being produced.
- Thread dumps show threads in `BLOCKED` or `WAITING` state.

### Root Causes

| Cause | Description |
|---|---|
| **Deadlocks** | Application threads are deadlocked on shared resources (locks, database connections, thread pools). |
| **Infinite loops** | A processing bug causes the consumer to loop endlessly on a specific record (poison pill). |
| **Blocked I/O** | Synchronous calls to external services that hang indefinitely (no timeout configured). |
| **`max.poll.interval.ms` exceeded** | Processing takes longer than the poll interval, so the consumer is evicted but the application thread is still blocked. |
| **Paused partitions never resumed** | Application code called `consumer.pause()` and never called `consumer.resume()`. |

### Diagnosis

```bash
# Check if consumer is still part of the group
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --describe --group <consumer-group>
# Look for partitions with no CONSUMER-ID assigned, or lag growing

# Take a thread dump of the stuck consumer process
jstack <consumer-pid> > /tmp/thread-dump.txt

# Look for blocked/waiting threads
grep -A 5 "BLOCKED\|WAITING\|deadlock" /tmp/thread-dump.txt

# Check if the consumer is still polling (look for poll loop activity)
grep "poll\|commit\|fetch" /var/log/app/consumer.log | tail -20

# Monitor consumer metrics via JMX
# Key metrics: last-poll-seconds-ago, records-consumed-rate (should be > 0)

# Check for poison pill messages — inspect the problematic offset
kafka-console-consumer.sh --bootstrap-server <broker>:9092 \
  --topic <topic> --partition <partition> --offset <stuck-offset> --max-messages 1
```

### Recovery

1. **Kill and restart** the stuck consumer process. If using static group membership, it will reclaim its partitions without a rebalance.

2. **Skip poison pill messages** by manually advancing the offset:

   ```bash
   # Reset offset to skip past the problematic message
   kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
     --group <consumer-group> --topic <topic>:<partition> \
     --reset-offsets --to-offset <next-offset> --execute
   ```

3. **Add processing timeouts**: Wrap all external calls in timeouts to prevent indefinite blocking.

   ```java
   // Example: timeout on processing
   Future<?> future = executor.submit(() -> processRecord(record));
   try {
       future.get(30, TimeUnit.SECONDS);
   } catch (TimeoutException e) {
       future.cancel(true);
       log.error("Processing timed out for offset {}", record.offset());
   }
   ```

4. **Implement a dead-letter queue (DLQ)**: Route records that fail processing N times to a separate topic for later investigation.

5. **Add monitoring for consumer liveness**: Track `last-poll-seconds-ago` and alert if it exceeds a threshold.

---

## 4. Broker Under-Replicated Partitions

The `UnderReplicatedPartitions` metric indicates partitions where one or more replicas are not keeping up with the leader. This is one of the most critical Kafka health indicators.

### What It Means

Each Kafka partition has a leader and zero or more follower replicas. Followers continuously fetch from the leader to stay in sync. When a follower falls behind, the partition is "under-replicated," meaning data redundancy is reduced and the cluster is at risk of data loss if the leader also fails.

### Symptoms

- `UnderReplicatedPartitions` JMX metric is greater than zero.
- `kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions`
- Alerts fire for under-replicated partitions.
- `kafka-topics.sh --describe` shows ISR lists shorter than the replication factor.

### Root Causes

| Cause | Description |
|---|---|
| **Disk failure** | A broker's disk is slow or failing, preventing it from writing replicated data fast enough. |
| **Network partition** | Network issues between brokers prevent followers from fetching from leaders. |
| **Slow follower** | A broker is overloaded (CPU, memory, disk I/O), causing its replicas to fall behind. |
| **Broker down** | A broker has crashed or been stopped, so all its replicas are offline. |
| **Unbalanced cluster** | One broker hosts disproportionately many leader partitions, saturating its resources. |
| **Log divergence** | A follower's log has diverged (e.g., due to unclean leader election), requiring truncation and re-fetch. |

### Diagnostic Commands

```bash
# Check under-replicated partitions across the cluster
kafka-topics.sh --bootstrap-server <broker>:9092 \
  --describe --under-replicated-partitions

# Check specific topic replication status
kafka-topics.sh --bootstrap-server <broker>:9092 \
  --describe --topic <topic>

# Example output:
# Topic: orders  Partition: 3  Leader: 1  Replicas: 1,2,3  Isr: 1,2
#                                                          ^ Broker 3 not in ISR

# Check broker liveness
kafka-broker-api-versions.sh --bootstrap-server <broker>:9092

# Check disk I/O on affected broker
iostat -xz 1 5

# Check network connectivity between brokers
ping <other-broker>
traceroute <other-broker>

# Check broker logs for replication errors
grep -i "replica\|fetch\|lag\|under.replicated\|ISR" \
  /var/log/kafka/server.log | tail -50

# JMX metrics to check
# kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions
# kafka.server:type=ReplicaFetcherManager,name=MaxLag,clientId=Replica
# kafka.server:type=BrokerTopicMetrics,name=FailedFetchRequestsPerSec
```

### Remediation

1. **Restart the affected broker** if it is overloaded or in a bad state:

   ```bash
   # Controlled shutdown (preferred)
   kafka-server-stop.sh

   # Verify the broker has fully stopped, then restart
   kafka-server-start.sh -daemon /etc/kafka/server.properties
   ```

2. **Replace failed disks**: If disk I/O is the issue, replace the disk and let the broker re-replicate.

3. **Rebalance partition leadership** across brokers:

   ```bash
   # Trigger preferred leader election
   kafka-leader-election.sh --bootstrap-server <broker>:9092 \
     --election-type preferred --all-topic-partitions
   ```

4. **Reassign partitions** away from overloaded brokers:

   ```bash
   # Generate a reassignment plan
   kafka-reassign-partitions.sh --bootstrap-server <broker>:9092 \
     --topics-to-move-json-file topics.json \
     --broker-list "1,2,3,4" --generate

   # Execute the reassignment
   kafka-reassign-partitions.sh --bootstrap-server <broker>:9092 \
     --reassignment-json-file reassignment.json --execute

   # Verify progress
   kafka-reassign-partitions.sh --bootstrap-server <broker>:9092 \
     --reassignment-json-file reassignment.json --verify
   ```

5. **Tune replication throughput**:

   ```properties
   # On follower brokers — increase fetch throughput
   num.replica.fetchers=4                     # Default: 1
   replica.fetch.max.bytes=10485760           # 10 MB
   replica.socket.receive.buffer.bytes=65536
   ```

---

## 5. ISR Shrinkage

### What is ISR?

The **In-Sync Replica (ISR)** set is the subset of a partition's replicas that are fully caught up with the leader. Only ISR members are eligible to become the new leader if the current leader fails. Kafka only acknowledges a produce request with `acks=all` once all ISR members have written the record.

### Why Replicas Fall Out of ISR

A follower is removed from the ISR if it has not fetched from the leader within `replica.lag.time.max.ms` (default: 30000ms / 30 seconds). This can happen due to:

| Cause | Description |
|---|---|
| **Slow disk I/O** | The follower cannot write data fast enough to keep up with the leader. |
| **GC pauses on follower** | Long garbage collection pauses freeze the fetcher thread. |
| **Network congestion** | High latency or packet loss between leader and follower. |
| **Broker overload** | The follower broker is handling too many partitions or too much traffic. |
| **Leader producing too fast** | A sudden burst of production outpaces the follower's ability to replicate. |
| **`replica.lag.time.max.ms` too low** | The configured threshold is too aggressive for the environment. |

### How to Monitor

```bash
# Check ISR for all partitions of a topic
kafka-topics.sh --bootstrap-server <broker>:9092 \
  --describe --topic <topic>

# Find partitions where ISR < replication factor
kafka-topics.sh --bootstrap-server <broker>:9092 \
  --describe --under-replicated-partitions

# JMX metrics to monitor:
# kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions   → should be 0
# kafka.server:type=ReplicaManager,name=UnderMinIsrPartitionCount   → should be 0
# kafka.server:type=ReplicaManager,name=IsrShrinksPerSec            → should be near 0
# kafka.server:type=ReplicaManager,name=IsrExpandsPerSec            → spikes after recovery
# kafka.server:type=ReplicaFetcherManager,name=MaxLag               → replication lag in messages

# Check if min.insync.replicas is being violated
# If ISR size < min.insync.replicas, producers with acks=all will get NotEnoughReplicasException
grep "min.insync.replicas" /etc/kafka/server.properties
```

### How to Fix

1. **Increase `replica.lag.time.max.ms`** to tolerate temporary slowdowns:

   ```properties
   # Broker config
   replica.lag.time.max.ms=45000   # Default: 30000; increase if ISR flaps frequently
   ```

2. **Add more replica fetcher threads** to speed up replication:

   ```properties
   num.replica.fetchers=4   # Default: 1
   ```

3. **Tune broker JVM for lower GC pauses**:

   ```bash
   # In kafka-server-start.sh or via KAFKA_HEAP_OPTS
   export KAFKA_HEAP_OPTS="-Xms6g -Xmx6g"
   export KAFKA_JVM_PERFORMANCE_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=20 \
     -XX:InitiatingHeapOccupancyPercent=35 -XX:+ExplicitGCInvokesConcurrent"
   ```

4. **Reduce disk I/O pressure**:
   - Use dedicated disks for Kafka log directories.
   - Spread partitions across multiple `log.dirs`.
   - Use SSDs for high-throughput topics.

5. **Set `min.insync.replicas` appropriately** to maintain durability guarantees:

   ```properties
   # Topic-level or broker-level config
   # For replication.factor=3, min.insync.replicas=2 is a common choice
   min.insync.replicas=2
   ```

   > ⚠️ **Warning**: If ISR shrinks below `min.insync.replicas` and `acks=all`, producers will fail with `NotEnoughReplicasException`. This is a safety mechanism — do not lower `min.insync.replicas` to 1 unless you accept potential data loss.

---

## 6. Log Compaction Issues

Log compaction retains the latest value for each key in a topic, discarding older duplicates. It is essential for changelog topics, KTable state stores, and similar use cases.

### Common Problems

#### 6.1 Compaction Not Running

**Symptoms**: Topic grows unboundedly; duplicate keys are not being removed.

**Causes and Fixes**:

```properties
# Ensure cleanup.policy is set to compact (or compact,delete)
# Check topic config:
kafka-configs.sh --bootstrap-server <broker>:9092 \
  --entity-type topics --entity-name <topic> --describe

# If cleanup.policy is "delete", change it:
kafka-configs.sh --bootstrap-server <broker>:9092 \
  --entity-type topics --entity-name <topic> \
  --alter --add-config cleanup.policy=compact
```

**Check compaction threads**:

```properties
# Broker config — ensure enough compaction threads
log.cleaner.threads=2          # Default: 1; increase for high-throughput clusters
log.cleaner.dedupe.buffer.size=134217728   # 128 MB; increase if compaction is slow
log.cleaner.enable=true        # Must be true (default)
```

#### 6.2 Tombstone Handling

Tombstones (records with a null value) mark a key for deletion. They must be retained long enough for downstream consumers to read them before being removed.

```properties
# How long tombstones are retained after compaction
delete.retention.ms=86400000   # Default: 24 hours
# Increase if downstream consumers may be offline for extended periods
```

> 📝 **Note**: If tombstones are removed before a consumer reads them, the consumer will never know the key was deleted and may retain stale data.

#### 6.3 `min.cleanable.dirty.ratio`

This setting controls when compaction kicks in. A lower value triggers compaction sooner but uses more I/O.

```properties
# Compaction starts when dirty (uncompacted) / total log ratio exceeds this
min.cleanable.dirty.ratio=0.5   # Default: 0.5
# Lower to 0.1 for more aggressive compaction (more I/O)
# Raise to 0.8 for less frequent compaction (less I/O)
```

#### 6.4 `segment.ms` and Active Segment

**The active (most recent) segment is never compacted.** Compaction only operates on closed (rolled) segments.

```properties
# Force segment roll after this time, even if segment is not full
segment.ms=3600000       # Default: 7 days (604800000); reduce if compaction is urgent
segment.bytes=1073741824 # Default: 1 GB; reduce if topics are low-throughput
```

> ⚠️ **Common pitfall**: With a 7-day default `segment.ms` and a low-throughput topic, the active segment may never roll, so compaction never runs. Set `segment.ms` to a lower value (e.g., 1 hour) for compacted topics.

#### 6.5 Debugging Compaction

```bash
# Check the cleaner log for errors
grep -i "cleaner\|compaction\|LogCleaner" /var/log/kafka/log-cleaner.log | tail -30

# JMX metrics for compaction:
# kafka.log:type=LogCleanerManager,name=uncleanable-partitions-count  → should be 0
# kafka.log:type=LogCleaner,name=cleaner-recopy-percent               → compaction efficiency
# kafka.log:type=LogCleaner,name=max-clean-time-secs                  → time spent compacting

# Check if the cleaner is disabled due to errors
grep "ERROR\|FATAL\|CleanerError" /var/log/kafka/log-cleaner.log

# If the cleaner thread has died, restart the broker to reset it.

# Verify compaction is working by checking topic size over time
kafka-log-dirs.sh --bootstrap-server <broker>:9092 \
  --topic-list <topic> --describe
```

---

## 7. Producer Timeout / Retry Storms

When producers cannot deliver messages, they may enter retry loops that amplify load on brokers and cause cascading failures.

### Key Configuration Parameters

| Parameter | Default | Description |
|---|---|---|
| `delivery.timeout.ms` | 120000 (2 min) | Upper bound on time to report success or failure after `send()` is called. |
| `request.timeout.ms` | 30000 (30 sec) | Time to wait for a response from the broker for a single request. |
| `retries` | 2147483647 | Number of retry attempts (effectively infinite by default). |
| `retry.backoff.ms` | 100 | Initial wait between retries. |
| `retry.backoff.max.ms` | 1000 | Maximum wait between retries (exponential backoff cap). |
| `max.in.flight.requests.per.connection` | 5 | Max unacknowledged requests per broker connection. |

### How Timeouts Interact

```
delivery.timeout.ms >= request.timeout.ms + retry_attempts × retry.backoff.ms
```

The producer retries until either the message is acknowledged or `delivery.timeout.ms` is exceeded. After `delivery.timeout.ms`, the `send()` callback receives a `TimeoutException`.

### Symptoms

- `record-error-rate` metric spikes.
- Producer logs show repeated `TimeoutException`, `NetworkException`, or `NotLeaderOrFollowerException`.
- Broker request queues grow (high `RequestQueueSize`).
- Message ordering is violated (if `max.in.flight.requests.per.connection > 1` without idempotence).

### Diagnostic Commands

```bash
# Check broker request handler utilization
# JMX: kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent
# If < 0.3, brokers are overloaded

# Check producer metrics via JMX:
# record-send-rate, record-error-rate, record-retry-rate
# request-latency-avg, request-latency-max
# buffer-available-bytes, buffer-exhausted-rate

# Check broker logs for request timeouts
grep "RequestTimeout\|Timeout\|expired" /var/log/kafka/server.log | tail -20

# Check network connectivity to brokers
nc -zv <broker> 9092
```

### Fixes and Best Practices

1. **Set `delivery.timeout.ms` based on your SLA**:

   ```properties
   # If you need to know within 30 seconds whether a message was delivered:
   delivery.timeout.ms=30000
   request.timeout.ms=10000
   ```

2. **Enable idempotent producer** to prevent duplicates on retry:

   ```properties
   enable.idempotence=true
   # This automatically sets:
   #   acks=all
   #   retries=Integer.MAX_VALUE
   #   max.in.flight.requests.per.connection=5 (safe with idempotence)
   ```

3. **For strict ordering without idempotence**:

   ```properties
   max.in.flight.requests.per.connection=1
   # This ensures retries don't reorder messages, but reduces throughput
   ```

4. **Implement backoff strategies in application code**:

   ```properties
   retry.backoff.ms=100
   retry.backoff.max.ms=5000
   # Producer uses exponential backoff between retry.backoff.ms and retry.backoff.max.ms
   ```

5. **Handle send failures in callbacks**:

   ```java
   producer.send(record, (metadata, exception) -> {
       if (exception instanceof RetriableException) {
           // Already retried up to delivery.timeout.ms — log and alert
           log.error("Retriable failure after exhausting retries", exception);
       } else if (exception != null) {
           // Non-retriable error (serialization, authorization, etc.)
           log.error("Non-retriable producer error", exception);
           deadLetterQueue.send(record);
       }
   });
   ```

6. **Tune broker-side to reduce timeouts**:

   ```properties
   # Broker config
   num.io.threads=8            # Default: 8; increase for high-throughput
   num.network.threads=3       # Default: 3; increase for many connections
   queued.max.requests=500     # Default: 500; increase cautiously
   ```

---

## 8. Memory Pressure / Buffer Pool Exhaustion

The Kafka producer buffers records in memory before sending them to the broker. If the buffer fills up, the producer blocks or throws exceptions.

### Key Configuration

| Parameter | Default | Description |
|---|---|---|
| `buffer.memory` | 33554432 (32 MB) | Total memory available for buffering unsent records. |
| `max.block.ms` | 60000 (60 sec) | How long `send()` and `partitionsFor()` will block when the buffer is full. |
| `batch.size` | 16384 (16 KB) | Maximum size of a batch of records sent to a single partition. |
| `linger.ms` | 0 | Time to wait for additional records before sending a batch. |

### Symptoms

- Producer throws `BufferExhaustedException` or `TimeoutException` from `send()`.
- Producer logs: `Failed to allocate memory within the configured max blocking time`.
- Application threads block on `send()` calls, causing upstream latency.
- `buffer-available-bytes` JMX metric drops to zero.
- `buffer-exhausted-rate` JMX metric spikes.

### Diagnosis

```bash
# Key JMX metrics to monitor:
# kafka.producer:type=producer-metrics,client-id=<id>
#   buffer-total-bytes         → total buffer.memory
#   buffer-available-bytes     → remaining free buffer space
#   buffer-exhausted-rate      → rate of buffer exhaustion events (should be 0)
#   bufferpool-wait-time-total → cumulative time threads spent waiting for buffer space
#   record-queue-time-avg      → average time records spend in the buffer
#   batch-size-avg             → average batch size in bytes
#   waiting-threads            → number of threads blocked waiting for buffer

# Check producer heap usage
jstat -gcutil <producer-pid> 1000

# Check if the issue is broker-side (slow acks)
# Look at request-latency-avg — if high, the bottleneck is the broker, not the producer
```

### Fixes

1. **Increase `buffer.memory`**:

   ```properties
   buffer.memory=67108864   # 64 MB (double the default)
   # Ensure the JVM has enough heap for this plus application memory
   ```

2. **Increase `max.block.ms`** to tolerate temporary broker slowdowns:

   ```properties
   max.block.ms=120000   # 2 minutes
   ```

3. **Improve batching efficiency** to drain the buffer faster:

   ```properties
   batch.size=65536     # 64 KB (larger batches = fewer requests = faster drain)
   linger.ms=10         # Wait 10ms for more records to fill the batch
   compression.type=lz4 # Compress batches to fit more data per request
   ```

4. **Add backpressure in the application**: If the producer cannot keep up, slow down the source.

   ```java
   // Check buffer availability before sending
   Metric bufferAvailable = producer.metrics().get(
       new MetricName("buffer-available-bytes", "producer-metrics", "", tags));
   if ((double) bufferAvailable.metricValue() < THRESHOLD) {
       // Slow down or pause the source
       Thread.sleep(100);
   }
   ```

5. **Reduce message size**: Large messages fill the buffer quickly. Consider:
   - Compressing payloads before producing.
   - Using a claim-check pattern (store the payload externally, produce only a reference).

6. **Ensure brokers are healthy**: If brokers are slow to acknowledge, the buffer fills up because batches sit waiting for responses. Fix broker-side issues first.

---

## 9. Offset Reset Confusion

`auto.offset.reset` determines where a consumer starts reading when there is no committed offset for a partition. Misunderstanding this setting causes consumers to either skip messages or reprocess everything.

### How `auto.offset.reset` Works

| Value | Behavior |
|---|---|
| `earliest` | Start from the beginning of the partition (offset 0 or the earliest available offset). |
| `latest` | Start from the end of the partition (only consume new messages produced after this point). |
| `none` | Throw an exception if no committed offset is found. |

### When It Triggers

`auto.offset.reset` is used **only** when:

1. **New consumer group**: The consumer group has never committed an offset for the topic/partition.
2. **Expired offsets**: The consumer group's committed offsets have been deleted because they exceeded `offsets.retention.minutes`.

> ⚠️ It does **NOT** trigger on every consumer restart. If the consumer group has valid committed offsets, it resumes from the last committed offset regardless of `auto.offset.reset`.

### `offsets.retention.minutes`

```properties
# Broker config — how long to retain committed offsets after a consumer group becomes empty
offsets.retention.minutes=10080   # Default: 10080 (7 days)
# In Kafka < 2.0, the default was 1440 (24 hours) — a common source of surprises
```

**Scenario**: A consumer group stops consuming for 8 days. When it restarts, committed offsets have been deleted. `auto.offset.reset` kicks in. If set to `latest`, all messages produced during those 8 days are skipped permanently.

### Common Mistakes

| Mistake | Consequence |
|---|---|
| Setting `auto.offset.reset=latest` for a processing pipeline | Messages produced before the consumer first starts are never processed. |
| Assuming `auto.offset.reset` triggers on every restart | Offsets are committed; the setting is irrelevant on normal restarts. |
| Short `offsets.retention.minutes` with infrequent consumers | Offsets expire, and `auto.offset.reset` triggers unexpectedly. |
| Not committing offsets (manual commit mode, but forgetting to call `commitSync/commitAsync`) | Every restart triggers `auto.offset.reset`. |
| Changing `group.id` without realizing it creates a "new" group | `auto.offset.reset` triggers for the new group. |

### How to Debug

```bash
# Check current committed offsets for a consumer group
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --describe --group <consumer-group>

# If CURRENT-OFFSET shows "-" for a partition, no offset is committed

# Check broker's offsets.retention.minutes
kafka-configs.sh --bootstrap-server <broker>:9092 \
  --entity-type brokers --entity-default --describe | grep offsets.retention

# Manually reset offsets if needed
# Reset to earliest:
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --group <consumer-group> --topic <topic> \
  --reset-offsets --to-earliest --execute

# Reset to a specific timestamp:
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --group <consumer-group> --topic <topic> \
  --reset-offsets --to-datetime "2024-01-15T00:00:00.000" --execute

# Reset to a specific offset:
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --group <consumer-group> --topic <topic>:<partition> \
  --reset-offsets --to-offset <offset> --execute

# Dry run (preview without executing):
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --group <consumer-group> --topic <topic> \
  --reset-offsets --to-earliest --dry-run
```

### Best Practices

- Use `auto.offset.reset=earliest` for data processing pipelines where every message matters.
- Use `auto.offset.reset=latest` for real-time monitoring/alerting where historical data is irrelevant.
- Set `offsets.retention.minutes` to at least 2× your maximum expected consumer downtime.
- Always commit offsets reliably — prefer `commitSync()` in critical pipelines.
- Monitor for consumer groups with no active members that may have their offsets expire.

---

## 10. Schema Registry Compatibility Errors

The Confluent Schema Registry enforces schema compatibility rules to prevent breaking changes that would cause deserialization failures for consumers.

### Compatibility Modes

| Mode | Allowed Changes | Use Case |
|---|---|---|
| **BACKWARD** (default) | New schema can read data written by the old schema. Can delete fields, add optional fields. | Consumers are upgraded before producers. |
| **BACKWARD_TRANSITIVE** | New schema can read data from all previous schemas. | Same as BACKWARD, across all versions. |
| **FORWARD** | Old schema can read data written by the new schema. Can add fields, delete optional fields. | Producers are upgraded before consumers. |
| **FORWARD_TRANSITIVE** | Old schema can read data from all future schemas. | Same as FORWARD, across all versions. |
| **FULL** | Both BACKWARD and FORWARD compatible. Can add/delete optional fields only. | Independent producer/consumer upgrades. |
| **FULL_TRANSITIVE** | FULL compatibility across all versions. | Most restrictive; highest safety. |
| **NONE** | No compatibility checks. Any change is allowed. | Development/testing only. |

### Common Compatibility Violations

| Violation | Breaks Which Mode? | Example |
|---|---|---|
| Removing a required field | FORWARD, FULL | Removing `user_id` from an Avro schema. |
| Adding a required field (no default) | BACKWARD, FULL | Adding `email` without a default value. |
| Changing a field type | All modes | Changing `age` from `int` to `string`. |
| Renaming a field | All modes | Renaming `userName` to `user_name`. |
| Changing enum values | Depends on direction | Removing an enum value breaks FORWARD. |

### How to Debug

```bash
# Test compatibility before registering a new schema
curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"schema": "{\"type\":\"record\",\"name\":\"User\",\"fields\":[...]}"}' \
  http://<schema-registry>:8081/compatibility/subjects/<subject>/versions/latest

# Response: {"is_compatible": false}

# Check current compatibility level for a subject
curl http://<schema-registry>:8081/config/<subject>

# Check global compatibility level
curl http://<schema-registry>:8081/config

# List all versions of a subject
curl http://<schema-registry>:8081/subjects/<subject>/versions

# Get a specific schema version
curl http://<schema-registry>:8081/subjects/<subject>/versions/<version>

# Compare two schema versions manually
curl http://<schema-registry>:8081/subjects/<subject>/versions/1
curl http://<schema-registry>:8081/subjects/<subject>/versions/2
```

### How to Change Compatibility

```bash
# Change compatibility for a specific subject
curl -X PUT -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"compatibility": "BACKWARD"}' \
  http://<schema-registry>:8081/config/<subject>

# Change global default compatibility
curl -X PUT -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"compatibility": "FULL"}' \
  http://<schema-registry>:8081/config

# Delete subject-level compatibility (fall back to global)
curl -X DELETE http://<schema-registry>:8081/config/<subject>
```

### Best Practices

- **Start with BACKWARD compatibility** — it is the most common and forgiving mode.
- **Always add default values** to new fields so old consumers can deserialize new data.
- **Never remove required fields** — deprecate them instead (set to optional with a default).
- **Use schema evolution guidelines**:
  - Avro: Add fields with defaults; remove only optional fields.
  - Protobuf: Never reuse field numbers; use `reserved` for removed fields.
  - JSON Schema: Use `additionalProperties: true` for forward compatibility.
- **Test compatibility in CI/CD** before deploying new schemas:

  ```bash
  # In CI pipeline — fail the build if schema is incompatible
  curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    --data @new-schema.json \
    http://<schema-registry>:8081/compatibility/subjects/<subject>/versions/latest
  # Returns 200 if compatible, 409 if not
  ```

- **Temporarily changing to NONE**: Only do this as a last resort. Set it back immediately after the breaking change is registered. Communicate the window to all consumers.

---

## 11. Cluster Upgrade Procedures

Upgrading a Kafka cluster requires careful planning to avoid downtime, data loss, or client compatibility issues.

### Pre-Upgrade Checks

```bash
# 1. Verify cluster health — no under-replicated partitions
kafka-topics.sh --bootstrap-server <broker>:9092 \
  --describe --under-replicated-partitions
# Must return empty output

# 2. Check current broker versions
kafka-broker-api-versions.sh --bootstrap-server <broker>:9092

# 3. Verify all consumer groups are healthy
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --describe --all-groups --state

# 4. Check disk space (upgrades may change log format, requiring extra space)
df -h /var/kafka-logs

# 5. Backup critical configs
cp /etc/kafka/server.properties /etc/kafka/server.properties.bak

# 6. Review the release notes and migration guide for the target version
# Pay special attention to deprecated configs and breaking changes

# 7. Test the upgrade in a staging environment first
```

### Rolling Upgrade Steps (ZooKeeper-based)

A rolling upgrade replaces one broker at a time without cluster downtime.

**Step 1: Set inter-broker protocol and log format versions**

Before upgrading any broker, add these to **all** brokers' configs (using the current version numbers):

```properties
# In server.properties on ALL brokers before starting the upgrade
# Set to the CURRENT version, not the target version
inter.broker.protocol.version=3.5   # Current running version
log.message.format.version=3.5      # Current running version
```

> 📝 These settings ensure that upgraded brokers communicate using the old protocol, maintaining compatibility with not-yet-upgraded brokers.

**Step 2: Rolling binary upgrade**

For each broker, one at a time:

```bash
# a. Stop the broker gracefully
kafka-server-stop.sh

# b. Wait for partition leadership to migrate (controlled shutdown)
# Check logs for "controlled shutdown complete"

# c. Install the new Kafka version binaries
# (package manager, tarball, container image — depends on deployment method)

# d. Keep the same server.properties (with old protocol/format versions)

# e. Start the broker with new binaries
kafka-server-start.sh -daemon /etc/kafka/server.properties

# f. Wait for the broker to fully rejoin and catch up
kafka-topics.sh --bootstrap-server <broker>:9092 \
  --describe --under-replicated-partitions
# Wait until this returns empty output before proceeding to the next broker
```

**Step 3: Bump the inter-broker protocol version**

After ALL brokers are running the new binary:

```properties
# Update on all brokers:
inter.broker.protocol.version=3.6   # Target version
```

Then perform another rolling restart.

**Step 4: Bump the log message format version**

After confirming the cluster is stable with the new protocol:

```properties
# Update on all brokers:
log.message.format.version=3.6   # Target version
```

Then perform a final rolling restart.

> ⚠️ **Important**: Only bump one version parameter per rolling restart cycle. Going too fast risks incompatibility.

### `inter.broker.protocol.version`

Controls the protocol used for inter-broker communication (replication, controller requests, etc.).

- Must be set to the **old** version during the rolling binary upgrade.
- Can be bumped to the **new** version only after all brokers are running the new binary.
- If not set, it defaults to the broker's binary version, which can break compatibility with old brokers.

### `log.message.format.version`

Controls the on-disk message format (record batch version).

- Must be set to the **old** version during upgrade to avoid expensive down-conversion.
- Bump only after `inter.broker.protocol.version` has been upgraded.
- Affects how messages are written to disk — older consumers may need message format conversion.

> 📝 In Kafka 3.0+, `log.message.format.version` is deprecated in favor of `inter.broker.protocol.version` alone. Both are subsumed by the `inter.broker.protocol.version` in recent versions.

### KRaft Migration (ZooKeeper to KRaft)

KRaft (Kafka Raft) replaces ZooKeeper for metadata management. Migration is available starting in Kafka 3.3 and considered production-ready in Kafka 3.5+.

**Migration Steps**:

1. **Verify prerequisites**:
   - Source cluster must be running Kafka 3.3+ (ideally 3.5+).
   - All brokers must be configured with `inter.broker.protocol.version=3.3` or higher.
   - Review the [KRaft migration guide](https://kafka.apache.org/documentation/#kraft_migration) for your version.

2. **Deploy KRaft controllers**:

   ```properties
   # controller.properties
   process.roles=controller
   node.id=100   # Must not conflict with existing broker IDs
   controller.quorum.voters=100@controller1:9093,101@controller2:9093,102@controller3:9093
   controller.listener.names=CONTROLLER
   listeners=CONTROLLER://controller1:9093
   ```

3. **Enable migration mode on brokers**:

   ```properties
   # Add to existing broker server.properties
   controller.quorum.voters=100@controller1:9093,101@controller2:9093,102@controller3:9093
   controller.listener.names=CONTROLLER
   # The broker still connects to ZooKeeper during migration
   zookeeper.connect=zk1:2181,zk2:2181,zk3:2181
   ```

4. **Start KRaft controllers** — they will begin syncing metadata from ZooKeeper.

5. **Rolling restart brokers** with the updated configuration.

6. **Verify migration** — all metadata should be served by KRaft controllers.

7. **Finalize migration** — remove `zookeeper.connect` from broker configs and do a final rolling restart.

8. **Decommission ZooKeeper** after confirming the cluster is stable.

### Client Compatibility

| Client Version | Broker Version | Compatibility |
|---|---|---|
| Older client | Newer broker | ✅ Generally supported (brokers do down-conversion if needed). |
| Newer client | Older broker | ⚠️ May work but unsupported features will fail. |
| Much older client (0.10.x) | Modern broker (3.x) | ❌ Likely broken; test thoroughly. |

**Best practices**:
- Upgrade brokers first, then upgrade clients.
- Test client compatibility in staging before production.
- Check `ApiVersions` responses to verify feature compatibility:

  ```bash
  kafka-broker-api-versions.sh --bootstrap-server <broker>:9092
  ```

### Post-Upgrade Verification

```bash
# 1. Verify all brokers are running the new version
kafka-broker-api-versions.sh --bootstrap-server <broker>:9092

# 2. Check for under-replicated partitions
kafka-topics.sh --bootstrap-server <broker>:9092 \
  --describe --under-replicated-partitions

# 3. Verify all consumer groups are active and consuming
kafka-consumer-groups.sh --bootstrap-server <broker>:9092 \
  --describe --all-groups

# 4. Produce and consume test messages
echo "upgrade-test" | kafka-console-producer.sh \
  --bootstrap-server <broker>:9092 --topic <test-topic>

kafka-console-consumer.sh --bootstrap-server <broker>:9092 \
  --topic <test-topic> --from-beginning --max-messages 1

# 5. Check broker logs for errors
grep -i "ERROR\|WARN\|FATAL" /var/log/kafka/server.log | tail -20

# 6. Monitor cluster metrics for 24-48 hours before considering the upgrade complete
```

---

## Quick Reference: Key Metrics to Monitor

| Metric | Location | Healthy Value |
|---|---|---|
| `UnderReplicatedPartitions` | Broker JMX | 0 |
| `IsrShrinksPerSec` | Broker JMX | Near 0 |
| `ActiveControllerCount` | Broker JMX | 1 across cluster |
| `OfflinePartitionsCount` | Controller JMX | 0 |
| `RequestHandlerAvgIdlePercent` | Broker JMX | > 0.3 |
| `NetworkProcessorAvgIdlePercent` | Broker JMX | > 0.3 |
| `records-lag-max` | Consumer JMX | Low / decreasing |
| `record-error-rate` | Producer JMX | 0 |
| `buffer-available-bytes` | Producer JMX | > 25% of total |
| `rebalance-rate-per-hour` | Consumer JMX | Low and stable |

---

## Quick Reference: Emergency Runbook

| Scenario | Immediate Action |
|---|---|
| All consumers stopped processing | Check consumer group state, look for rebalancing storm, check broker health |
| Producer errors spiking | Check broker `RequestHandlerAvgIdlePercent`, check network, check disk I/O |
| Under-replicated partitions | Identify affected brokers, check disk/network/CPU, restart if needed |
| Broker OOM | Increase heap, check for log segment accumulation, review topic retention |
| Consumer lag growing unbounded | Scale consumers, check for stuck consumers, reduce `max.poll.records` |
| Schema Registry 409 errors | Check compatibility mode, test schema, add default values to new fields |
| Offset reset unexpectedly | Check `offsets.retention.minutes`, verify `group.id`, check offset commits |
