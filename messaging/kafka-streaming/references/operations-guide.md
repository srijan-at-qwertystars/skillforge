# Kafka Operations Guide

Production operations reference: cluster sizing, configuration tuning, upgrades, monitoring, DR, and multi-datacenter deployment.

---

## Table of Contents

1. [Cluster Sizing](#cluster-sizing)
2. [Partition Count Strategy](#partition-count-strategy)
3. [Replication Factor Selection](#replication-factor-selection)
4. [Broker Configuration Tuning](#broker-configuration-tuning)
5. [Rolling Upgrades](#rolling-upgrades)
6. [Partition Reassignment](#partition-reassignment)
7. [Preferred Leader Election](#preferred-leader-election)
8. [Monitoring and Alerting](#monitoring-and-alerting)
9. [Backup and DR Strategies](#backup-and-dr-strategies)
10. [Multi-Datacenter with MirrorMaker 2](#multi-datacenter-with-mirrormaker-2)
11. [KRaft Migration from ZooKeeper](#kraft-migration-from-zookeeper)

---

## Cluster Sizing

### Broker count formula

```
Required brokers = max(
    total_disk_needed / disk_per_broker,
    total_throughput_needed / throughput_per_broker,
    total_partitions * replication_factor / max_partitions_per_broker
)
```

### Disk sizing

```
disk_per_broker = (daily_ingest_bytes × retention_days × replication_factor) / broker_count
                  + 20% headroom for compaction, index files, OS
```

### Throughput benchmarks (per broker, modern hardware)

| Hardware | Write throughput | Read throughput |
|----------|-----------------|-----------------|
| HDD (JBOD, 12 disks) | 300-600 MB/s | 400-800 MB/s |
| NVMe SSD | 800-1500 MB/s | 1000-2000 MB/s |
| Cloud (gp3 EBS) | 200-500 MB/s | 300-700 MB/s |

### Memory

- Broker heap: 6-8 GB is usually sufficient. More heap ≠ better.
- Page cache: The real performance driver. Allocate as much RAM as possible for OS page cache.
- Rule: Total RAM = JVM heap (6-8GB) + page cache (at least = active segment size across all partitions).

### CPU

- 8-16 cores for most workloads. Kafka is I/O-bound more than CPU-bound.
- Compression/decompression is CPU-intensive — more cores for `zstd` or `gzip`.
- SSL/TLS adds ~30% CPU overhead.

### Network

- 10 Gbps minimum for production.
- Replication traffic = ingest rate × (replication_factor - 1).
- Ensure inter-broker bandwidth > 2× ingest rate.

### Reference cluster sizes

| Workload | Brokers | Partitions | Throughput |
|----------|---------|------------|------------|
| Small (startup) | 3 | 50-200 | <100 MB/s |
| Medium (scale-up) | 5-10 | 200-2000 | 100-500 MB/s |
| Large (enterprise) | 15-50 | 2000-20000 | 500 MB/s - 5 GB/s |
| Very large (tech co) | 50-200+ | 20000+ | 5+ GB/s |

---

## Partition Count Strategy

### Guidelines

- **Start with**: `max(expected_throughput / per_partition_throughput, expected_max_consumers)`.
- **Per-partition throughput**: ~10-50 MB/s depending on message size and hardware.
- **Cannot decrease** partition count without recreating the topic.
- **Overhead per partition**: ~10KB memory on broker, one file handle per segment.

### Sizing table

| Expected throughput | Message size | Suggested partitions |
|--------------------|--------------|--------------------|
| < 10 MB/s | Any | 6-12 |
| 10-50 MB/s | < 1KB | 12-24 |
| 50-200 MB/s | < 1KB | 24-64 |
| 200 MB/s - 1 GB/s | Any | 64-256 |
| > 1 GB/s | Any | 256+ |

### Key rules

1. Partition count = maximum consumer parallelism within one group.
2. More partitions = more open file handles, more memory, longer leader elections.
3. For ordering-sensitive topics, partition count is effectively permanent — key routing changes on increase.
4. KRaft clusters handle 1.5M+ partitions (vs. ~200K with ZooKeeper).
5. Avoid topics with thousands of partitions unless necessary — use fewer partitions with better key distribution.

### Compacted topics

For compacted topics (KTables), partition count affects:
- Compaction parallelism (each partition compacted independently).
- Interactive query distribution (state sharded by partition).
- Keep partition count reasonable (< 100) for compacted topics unless throughput demands more.

---

## Replication Factor Selection

| Environment | Replication Factor | `min.insync.replicas` | Fault Tolerance |
|-------------|-------------------|----------------------|-----------------|
| Development | 1 | 1 | None |
| Staging | 2 | 1 | 1 broker |
| Production | 3 | 2 | 1 broker (with `acks=all`) |
| Critical prod | 3 | 2 | 1 broker |
| Multi-AZ | 3 (rack-aware) | 2 | 1 AZ failure |

### Rack-aware replication

```properties
# Broker config — set per broker to its AZ/rack
broker.rack=us-east-1a
```

Kafka distributes replicas across racks. With `replication.factor=3` and 3 AZs, each AZ has one replica.

### Rule: Never set `min.insync.replicas >= replication.factor`

This makes the topic unavailable when any single replica is down. Always: `min.insync.replicas < replication.factor`.

---

## Broker Configuration Tuning

### Storage

```properties
# Retention
log.retention.hours=168                    # 7 days default
log.retention.bytes=-1                     # unlimited by size (default)
log.segment.bytes=1073741824               # 1GB segments
log.segment.ms=604800000                   # 7 days max segment age
log.retention.check.interval.ms=300000     # check every 5 min

# Log directories — JBOD: multiple dirs for parallelism
log.dirs=/data/kafka-logs-1,/data/kafka-logs-2,/data/kafka-logs-3

# Compaction
log.cleaner.enable=true
log.cleaner.threads=2                      # increase for many compacted topics
log.cleaner.dedupe.buffer.size=134217728   # 128MB dedup buffer
min.compaction.lag.ms=0
```

### Message size

```properties
# Broker
message.max.bytes=10485760                 # 10MB max per message (default 1MB)
replica.fetch.max.bytes=10485880           # must be >= message.max.bytes
log.message.timestamp.type=CreateTime      # or LogAppendTime for retry topics

# Topic-level override
max.message.bytes=10485760                 # per-topic
```

**When increasing message size**, also update:
- Producer: `max.request.size`
- Consumer: `max.partition.fetch.bytes`, `fetch.max.bytes`
- Broker: `replica.fetch.max.bytes`

### Network and threads

```properties
num.network.threads=8                      # handles network I/O; ~CPU cores / 2
num.io.threads=16                          # handles disk I/O; ~CPU cores or 2× disk count
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600         # 100MB max request
queued.max.requests=500
```

### Replication

```properties
num.replica.fetchers=4                     # parallel replication threads
replica.fetch.max.bytes=10485880
replica.lag.time.max.ms=30000              # remove from ISR if behind > 30s
default.replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false       # prevent data loss
```

### KRaft-specific

```properties
# Controller quorum
controller.quorum.voters=1@controller1:9093,2@controller2:9093,3@controller3:9093
controller.quorum.election.timeout.ms=1000
controller.quorum.fetch.timeout.ms=2000
controller.quorum.election.backoff.max.ms=1000

# Metadata
metadata.log.dir=/data/kraft-metadata
metadata.max.retention.bytes=104857600     # 100MB metadata log
```

---

## Rolling Upgrades

### Pre-upgrade checklist

1. Verify no under-replicated partitions: `kafka-topics.sh --describe --under-replicated-partitions`
2. Ensure `min.insync.replicas < replication.factor` for all topics.
3. Back up broker configs.
4. Read release notes for breaking changes.

### Upgrade procedure (KRaft cluster)

```bash
# Step 1: Upgrade controllers first (one at a time)
# On each controller:
sudo systemctl stop kafka
# Install new binaries
sudo systemctl start kafka
# Wait for controller to rejoin quorum
kafka-metadata.sh --snapshot /data/kraft-metadata/__cluster_metadata-0/00000000000000000000.log --cluster-id <id>

# Step 2: Upgrade brokers (one at a time)
# On each broker:
sudo systemctl stop kafka
# Install new binaries
sudo systemctl start kafka
# Wait for broker to rejoin and ISR to stabilize
kafka-topics.sh --bootstrap-server broker:9092 --describe --under-replicated-partitions
# Proceed to next broker only when no under-replicated partitions
```

### Feature flag upgrades (inter.broker.protocol)

For major version upgrades:

```properties
# Phase 1: Upgrade all brokers with old protocol
inter.broker.protocol.version=3.8
log.message.format.version=3.8

# Phase 2: After ALL brokers upgraded, bump to new version
inter.broker.protocol.version=3.9
log.message.format.version=3.9
# Rolling restart again
```

### Rollback

If issues arise, stop the upgraded broker and reinstall the previous version. Kafka is backward compatible for protocol versions.

---

## Partition Reassignment

### When to reassign

- Adding new brokers (they start with zero partitions).
- Removing a broker (drain partitions first).
- Rebalancing after uneven growth.
- Moving partitions off a slow/full disk.

### Using kafka-reassign-partitions.sh

```bash
# Step 1: Generate reassignment plan
cat > topics.json <<EOF
{"topics": [{"topic": "orders"}, {"topic": "events"}], "version": 1}
EOF

kafka-reassign-partitions.sh --bootstrap-server broker:9092 \
  --topics-to-move-json-file topics.json \
  --broker-list "1,2,3,4,5" \
  --generate > reassignment.json

# Step 2: Review the proposed plan in reassignment.json, edit if needed

# Step 3: Execute with throttle
kafka-reassign-partitions.sh --bootstrap-server broker:9092 \
  --reassignment-json-file reassignment.json \
  --throttle 50000000 \
  --execute

# Step 4: Monitor progress
kafka-reassign-partitions.sh --bootstrap-server broker:9092 \
  --reassignment-json-file reassignment.json \
  --verify

# Step 5: Remove throttle after completion
kafka-reassign-partitions.sh --bootstrap-server broker:9092 \
  --reassignment-json-file reassignment.json \
  --verify  # automatically removes throttle on completion
```

### Throttle guidance

| Cluster size | Recommended throttle |
|-------------|---------------------|
| Small (3-5 brokers) | 20-50 MB/s |
| Medium (5-15 brokers) | 50-100 MB/s |
| Large (15+ brokers) | 100-200 MB/s |

Set throttle low enough to avoid impacting production traffic. Monitor `BytesInPerSec` and `BytesOutPerSec` during reassignment.

### Cruise Control (automated)

LinkedIn's Cruise Control automates rebalancing. It continuously monitors partition distribution and proposes/executes rebalancing plans. Recommended for clusters > 10 brokers.

---

## Preferred Leader Election

### Why it matters

After broker restarts, the leader for a partition may not be the "preferred" replica (first in the replica list). This causes uneven load.

### Trigger preferred leader election

```bash
# All topics
kafka-leader-election.sh --bootstrap-server broker:9092 \
  --election-type preferred --all-topic-partitions

# Specific topic
kafka-leader-election.sh --bootstrap-server broker:9092 \
  --election-type preferred \
  --topic orders --partition 0
```

### Auto leader balancing

```properties
# Broker config
auto.leader.rebalance.enable=true                # default: true
leader.imbalance.check.interval.seconds=300      # check every 5 min
leader.imbalance.per.broker.percentage=10         # trigger if >10% imbalanced
```

### Unclean leader election

```properties
unclean.leader.election.enable=false   # default: false — KEEP IT OFF
```

If enabled and all ISR replicas are down, an out-of-sync replica becomes leader — causing data loss. Only enable if availability > consistency (rare).

---

## Monitoring and Alerting

### Essential monitoring stack

```
Kafka (JMX) → Prometheus JMX Exporter → Prometheus → Grafana
                                                    → Alertmanager
```

### Alert thresholds

| Metric | Warning | Critical |
|--------|---------|----------|
| `UnderReplicatedPartitions` | > 0 for 2 min | > 0 for 10 min |
| `OfflinePartitionsCount` | - | > 0 |
| `ActiveControllerCount` (cluster-wide) | - | != 1 |
| Consumer lag (per group) | Growing > 5 min | Growing > 15 min |
| Disk usage | > 70% | > 85% |
| Request handler idle % | < 0.5 | < 0.3 |
| Network handler idle % | < 0.5 | < 0.3 |
| `RequestQueueSize` | > 100 | > 500 |
| Producer `record-error-rate` | > 0 | > 0 sustained |
| ISR shrink rate | > 0/min sustained | - |

### Consumer lag monitoring

```bash
# Built-in CLI
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --describe --group my-group

# All groups
kafka-consumer-groups.sh --bootstrap-server broker:9092 --list
```

For automated monitoring, use **Burrow** (evaluates lag trend over time) or export `consumer_lag` via JMX/Prometheus.

### Health check script

```bash
#!/bin/bash
# Quick cluster health check
BOOTSTRAP="broker:9092"

echo "=== Broker count ==="
kafka-broker-api-versions.sh --bootstrap-server $BOOTSTRAP 2>/dev/null | grep -c "^[^ ]"

echo "=== Under-replicated partitions ==="
kafka-topics.sh --bootstrap-server $BOOTSTRAP --describe --under-replicated-partitions

echo "=== Offline partitions ==="
kafka-topics.sh --bootstrap-server $BOOTSTRAP --describe --unavailable-partitions

echo "=== Consumer group lag ==="
for group in $(kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP --list); do
  echo "--- $group ---"
  kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP --describe --group "$group" 2>/dev/null | tail -n +2
done
```

---

## Backup and DR Strategies

### What to back up

| Component | Backup Method | Frequency |
|-----------|--------------|-----------|
| Broker configs | Version control (git) | On every change |
| Topic configs | `kafka-configs.sh --describe` → git | Daily |
| Schema Registry | SR API export | On every schema change |
| Connect configs | REST API export | On every change |
| ACLs | `kafka-acls.sh --list` → git | Daily |
| Consumer offsets | `kafka-consumer-groups.sh --describe` | Before maintenance |
| KRaft metadata | Snapshot via `kafka-metadata.sh` | Daily |

### Topic data backup

Option A: **MirrorMaker 2** to a standby cluster (recommended for DR).

Option B: **Tiered storage** (KIP-405, Kafka 3.6+) — offload cold segments to S3/GCS:

```properties
# Broker
remote.log.storage.system.enable=true
remote.log.storage.manager.class.name=org.apache.kafka.server.log.remote.storage.impl.S3RemoteStorageManager
```

Option C: **Consumer-based backup** — consumer writes to S3/HDFS (e.g., Secor, Connect S3 Sink).

### RTO/RPO targets

| Strategy | RPO | RTO | Cost |
|----------|-----|-----|------|
| Multi-AZ same region | ~0 (synchronous) | Minutes | Medium |
| Active-passive MirrorMaker 2 | Seconds-minutes | Minutes-hours | Medium |
| Active-active MirrorMaker 2 | Seconds | Minutes | High |
| Cold backup (S3) | Hours | Hours | Low |

---

## Multi-Datacenter with MirrorMaker 2

### Architecture patterns

**Active-passive**: One primary cluster handles all writes. MM2 replicates to standby. Failover = redirect producers to standby.

**Active-active**: Both clusters handle writes for their region. MM2 replicates bidirectionally. Requires conflict resolution strategy (last-writer-wins, region-prefixed topics).

### MirrorMaker 2 configuration

```properties
# mm2.properties
clusters = dc1, dc2
dc1.bootstrap.servers = dc1-broker1:9092,dc1-broker2:9092
dc2.bootstrap.servers = dc2-broker1:9092,dc2-broker2:9092

# Replicate dc1 → dc2
dc1->dc2.enabled = true
dc1->dc2.topics = orders, events, users
dc1->dc2.groups = .*
dc1->dc2.emit.heartbeats.enabled = true
dc1->dc2.emit.checkpoints.enabled = true
dc1->dc2.sync.group.offsets.enabled = true

# Topic naming: dc1.orders in dc2
replication.policy.class = org.apache.kafka.connect.mirror.DefaultReplicationPolicy
replication.policy.separator = .

# Bidirectional (active-active)
dc2->dc1.enabled = true
dc2->dc1.topics = orders, events, users
```

### Run MirrorMaker 2

```bash
# Dedicated MM2 mode
connect-mirror-maker.sh mm2.properties

# Or as Kafka Connect connectors
# Deploy MirrorSourceConnector, MirrorCheckpointConnector, MirrorHeartbeatConnector
```

### Failover procedure (active-passive)

1. Stop MM2 replication.
2. Verify standby cluster has caught up (check checkpoint offsets).
3. Run consumer offset sync: `kafka-consumer-groups.sh --bootstrap-server dc2:9092 --reset-offsets --from-file checkpoints.csv --execute`
4. Redirect producers and consumers to standby cluster.
5. Verify traffic flowing on standby.

### Monitoring MM2

- **Replication lag**: `MirrorSourceConnector` metric `replication-latency-ms-avg`.
- **Checkpoint lag**: `MirrorCheckpointConnector` metric.
- **Heartbeat**: Monitor `heartbeats` topic in target cluster.

---

## KRaft Migration from ZooKeeper

KRaft (Kafka Raft) replaces ZooKeeper for metadata management. ZooKeeper support was removed in Kafka 4.0. Migrate before upgrading to 4.0.

### Migration steps (Kafka 3.x)

#### Phase 1: Deploy KRaft controllers alongside ZooKeeper

```properties
# New controller nodes (kraft-controller.properties)
process.roles=controller
node.id=100  # unique, non-overlapping with broker IDs
controller.quorum.voters=100@ctrl1:9093,101@ctrl2:9093,102@ctrl3:9093
controller.listener.names=CONTROLLER
listeners=CONTROLLER://0.0.0.0:9093
```

Start controllers. They form a quorum but don't manage metadata yet.

#### Phase 2: Migrate metadata

```bash
# On one controller, migrate ZooKeeper metadata to KRaft
kafka-metadata.sh --zk-connect zk1:2181 --migrate --controller-quorum-voters 100@ctrl1:9093,101@ctrl2:9093,102@ctrl3:9093
```

#### Phase 3: Switch brokers to KRaft

```properties
# Update broker configs (one at a time, rolling restart)
# Remove ZooKeeper config
# zookeeper.connect=zk1:2181  ← REMOVE

# Add KRaft config
controller.quorum.voters=100@ctrl1:9093,101@ctrl2:9093,102@ctrl3:9093
controller.listener.names=CONTROLLER
```

Rolling restart brokers one at a time. After each restart:
1. Verify broker registers with KRaft controllers.
2. Check no under-replicated partitions.
3. Proceed to next broker.

#### Phase 4: Decommission ZooKeeper

After all brokers are on KRaft:
1. Verify cluster fully operational.
2. Remove `zookeeper.connect` from all configs.
3. Shut down ZooKeeper ensemble.
4. Clean up ZooKeeper data directories.

### Verification

```bash
# Check cluster metadata
kafka-metadata.sh --snapshot /data/kraft-metadata/__cluster_metadata-0/*.log --cluster-id <id>

# Verify all brokers registered
kafka-broker-api-versions.sh --bootstrap-server broker:9092

# Verify topic metadata
kafka-topics.sh --bootstrap-server broker:9092 --describe
```

### Rollback

If issues arise during migration, brokers can be rolled back to ZooKeeper mode by restoring the original config and restarting. The ZooKeeper ensemble must still be running.

### Post-migration benefits

- No ZooKeeper dependency — simpler operations.
- Faster controller failover (seconds vs. minutes).
- Support for 1.5M+ partitions.
- Single security model (no separate ZK auth).
- Simpler deployment and monitoring.
