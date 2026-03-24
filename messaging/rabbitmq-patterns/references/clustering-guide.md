# RabbitMQ Clustering and High Availability Guide

## Table of Contents

- [Quorum Queues and Raft Consensus](#quorum-queues-and-raft-consensus)
- [Classic Mirrored Queues Deprecation](#classic-mirrored-queues-deprecation)
- [Cluster Formation](#cluster-formation)
- [Peer Discovery](#peer-discovery)
- [Rolling Upgrades](#rolling-upgrades)
- [Cluster Sizing](#cluster-sizing)
- [Cross-Datacenter with Federation and Shovel](#cross-datacenter-with-federation-and-shovel)
- [Stream Replication](#stream-replication)

---

## Quorum Queues and Raft Consensus

### Overview

Quorum queues are the recommended replicated queue type for RabbitMQ 3.8+. They use the Raft consensus algorithm to replicate messages across an odd number of nodes, providing strong consistency and automatic leader election.

### Raft Consensus Mechanics

1. **Leader election**: One node holds the leader replica for each quorum queue. All publishes and consumes go through the leader.
2. **Log replication**: The leader appends messages to its Raft log and replicates to followers. A message is committed (safe) once a majority (quorum) acknowledge.
3. **Quorum requirement**: For N replicas, `floor(N/2) + 1` must be available. A 3-replica queue tolerates 1 failure; 5-replica tolerates 2.
4. **Automatic failover**: If the leader fails, followers elect a new leader. No manual intervention needed.

### Declaration and Configuration

```python
channel.queue_declare(queue='orders.processing', durable=True, arguments={
    'x-queue-type': 'quorum',
    'x-quorum-initial-group-size': 3,     # Replicate across 3 nodes
    'x-delivery-limit': 5,                # Max redeliveries before DLX
    'x-dead-letter-exchange': 'dlx',
    'x-dead-letter-strategy': 'at-least-once',
    'x-max-in-memory-length': 1000,       # Limit in-memory messages (rest on disk)
    'x-max-length': 500000,               # Max queue depth
    'x-overflow': 'reject-publish',       # Backpressure strategy
})
```

### Key Properties

| Property | Value | Notes |
|----------|-------|-------|
| Durability | Always durable | Cannot be non-durable or transient |
| Exclusivity | Never exclusive | Cannot be exclusive |
| Auto-delete | Never | Cannot auto-delete |
| Priority | Not supported | Use classic queues for priority |
| Global QoS | Not supported | Per-consumer QoS only |
| Poison message handling | Built-in (`x-delivery-limit`) | Automatic dead-lettering after N redeliveries |
| Message TTL | Supported (3.10+) | Per-queue and per-message TTL |
| Dead-lettering | At-least-once or at-most-once | `x-dead-letter-strategy` controls guarantee |

### Leader Placement and Balancing

```ini
# rabbitmq.conf — Control leader placement strategy
queue_leader_locator = balanced
# Options:
#   client-local  — leader on the node the declaring connection uses (default pre-3.12)
#   balanced      — distribute leaders across nodes evenly (recommended)
```

```bash
# Check leader distribution
rabbitmqctl list_queues name type leader --formatter=json | \
  python3 -c "
import sys, json
from collections import Counter
qs = [q for q in json.load(sys.stdin) if q.get('type') == 'quorum']
leaders = Counter(q['leader'] for q in qs)
print('Leader distribution:')
for node, count in leaders.most_common():
    print(f'  {node}: {count} queues')
"

# Rebalance leaders manually
rabbitmq-queues rebalance quorum
```

### Raft Log and Disk Usage

Quorum queues persist the Raft log to disk (WAL — Write-Ahead Log). Segments are periodically compacted.

```bash
# Check quorum queue disk usage
du -sh /var/lib/rabbitmq/mnesia/rabbit@$(hostname)/quorum/

# Per-queue Raft state
rabbitmqctl list_queues name type messages leader followers online \
  --filter 'type=quorum'
```

**Tuning compaction:**

```ini
# rabbitmq.conf
# Raft WAL max batch size (bytes) — larger = more throughput, more memory
# raft.wal_max_batch_size = 4096

# Segment max entries before compaction
# raft.segment_max_entries = 32768
```

### Quorum Queue Performance Characteristics

- **Publish latency**: Higher than classic queues (Raft replication overhead). Expect 1-5ms per publish with 3 replicas on low-latency network.
- **Throughput**: ~30-50k msg/s per queue (varies by message size, persistence, network).
- **Memory**: In-memory index + configurable in-memory message buffer. Use `x-max-in-memory-length` to bound memory.
- **Disk I/O**: Significant. Use SSDs for quorum queue nodes. HDD will bottleneck.

---

## Classic Mirrored Queues Deprecation

### Timeline

- **RabbitMQ 3.8**: Quorum queues introduced as the replacement
- **RabbitMQ 3.9**: Quorum queues gain feature parity for most use cases
- **RabbitMQ 3.13**: Classic mirrored queues deprecated with warnings
- **RabbitMQ 4.0**: Classic mirrored queues removed entirely

### Migration Path

1. **Identify mirrored queues:**
   ```bash
   rabbitmqctl list_queues name type arguments --filter 'type=classic' | \
     grep -i "ha-mode"
   ```

2. **Remove ha-* policies:**
   ```bash
   # List HA policies
   rabbitmqctl list_policies | grep "ha-"
   # Delete each one
   rabbitmqctl clear_policy ha-all
   ```

3. **Recreate as quorum queues:**
   ```python
   # New declaration — change x-queue-type
   channel.queue_declare(queue='orders', durable=True, arguments={
       'x-queue-type': 'quorum',             # Was 'classic' with ha-mode policy
       'x-quorum-initial-group-size': 3       # Replaces ha-params: 3
   })
   ```

4. **Migration strategy for live systems:**
   - Declare new quorum queue with a temporary name
   - Use Shovel to move messages from old classic mirrored queue to new quorum queue
   - Update consumers to read from new queue
   - Update producers to write to new queue
   - Delete old mirrored queue and rename new queue (or update bindings)

### Feature Differences

| Feature | Classic Mirrored | Quorum Queue |
|---------|-----------------|--------------|
| Replication | Async (data loss on leader failure) | Raft consensus (no data loss) |
| Performance | Higher throughput (no consensus) | Lower throughput, higher safety |
| Priority | Supported | Not supported |
| Lazy mode | Supported | Built-in (configurable in-memory limit) |
| Non-durable | Supported | Not supported |
| Exclusive | Supported | Not supported |
| Poison message handling | None | Built-in delivery limit |

---

## Cluster Formation

### Prerequisites

- All nodes must run the **same Erlang/OTP major version** and **same RabbitMQ version**
- All nodes must share the **same Erlang cookie** (`/var/lib/rabbitmq/.erlang.cookie`)
- Nodes must be able to resolve each other's hostnames (DNS or `/etc/hosts`)
- Required ports: 4369 (epmd), 25672 (distribution), 35672-35682 (CLI tools)

### Manual Cluster Formation

```bash
# On node1 — start normally (becomes the seed node)
rabbitmq-server -detached
rabbitmqctl await_startup

# On node2 — join node1's cluster
rabbitmq-server -detached
rabbitmqctl await_startup
rabbitmqctl stop_app
rabbitmqctl reset
rabbitmqctl join_cluster rabbit@node1
rabbitmqctl start_app

# On node3 — join cluster
rabbitmq-server -detached
rabbitmqctl await_startup
rabbitmqctl stop_app
rabbitmqctl reset
rabbitmqctl join_cluster rabbit@node1
rabbitmqctl start_app

# Verify on any node
rabbitmqctl cluster_status
```

### Erlang Cookie

All nodes in a cluster must share the same cookie. The cookie is a plaintext file:

```bash
# Copy cookie from node1 to other nodes
scp /var/lib/rabbitmq/.erlang.cookie node2:/var/lib/rabbitmq/.erlang.cookie
scp /var/lib/rabbitmq/.erlang.cookie node3:/var/lib/rabbitmq/.erlang.cookie

# Fix permissions (must be 400, owned by rabbitmq)
chmod 400 /var/lib/rabbitmq/.erlang.cookie
chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie
```

In Docker:
```yaml
environment:
  RABBITMQ_ERLANG_COOKIE: "a-secure-shared-secret"
```

### Node Types

```bash
# Join as a RAM node (metadata in RAM only — not recommended for most setups)
rabbitmqctl join_cluster rabbit@node1 --ram

# Change node type
rabbitmqctl stop_app
rabbitmqctl change_cluster_node_type disc  # or ram
rabbitmqctl start_app
```

**Disc nodes** (default): Store metadata to disk. At least one disc node required. All nodes should be disc in production.

**RAM nodes**: Store metadata in RAM only. Faster for clusters with very frequent topology changes. Not recommended — the performance difference is negligible in modern setups.

---

## Peer Discovery

### Overview

Peer discovery automates cluster formation by allowing nodes to find each other at boot time instead of manual `join_cluster` commands.

### DNS-Based Discovery

```ini
# rabbitmq.conf
cluster_formation.peer_discovery_backend = dns
cluster_formation.dns.hostname = rabbitmq.service.consul  # Or any DNS name
cluster_formation.node_type = disc
cluster_formation.dns.query_type = A   # A record (hostname) or SRV record
```

### AWS (EC2) Discovery

```ini
cluster_formation.peer_discovery_backend = aws
cluster_formation.aws.region = us-east-1
cluster_formation.aws.use_autoscaling_group = true
# OR filter by tags:
# cluster_formation.aws.instance_tags.service = rabbitmq
# cluster_formation.aws.instance_tags.environment = production
```

### Kubernetes Discovery

```ini
cluster_formation.peer_discovery_backend = k8s
cluster_formation.k8s.host = kubernetes.default.svc.cluster.local
cluster_formation.k8s.address_type = hostname
cluster_formation.k8s.service_name = rabbitmq-headless
cluster_formation.k8s.hostname_suffix = .rabbitmq-headless.default.svc.cluster.local
```

For Kubernetes, prefer the **RabbitMQ Cluster Operator** which handles peer discovery, scaling, and upgrades automatically.

### Consul Discovery

```ini
cluster_formation.peer_discovery_backend = consul
cluster_formation.consul.host = consul.service.consul
cluster_formation.consul.svc = rabbitmq
cluster_formation.consul.svc_addr_auto = true
```

### Etcd Discovery

```ini
cluster_formation.peer_discovery_backend = etcd
cluster_formation.etcd.endpoints = etcd1:2379,etcd2:2379,etcd3:2379
cluster_formation.etcd.key_prefix = /rabbitmq/discovery
cluster_formation.etcd.cluster_name = production
```

### Common Peer Discovery Settings

```ini
# How long to wait for other nodes during initial cluster formation
cluster_formation.discovery_retry_limit = 10
cluster_formation.discovery_retry_interval = 500

# Randomized startup delay to avoid race conditions
cluster_formation.randomized_startup_delay_range.min = 0
cluster_formation.randomized_startup_delay_range.max = 60

# Target cluster size hint (for locking during formation)
cluster_formation.target_cluster_size_hint = 3
```

---

## Rolling Upgrades

### Prerequisites

- Test the upgrade in a staging environment first
- Back up definitions: `rabbitmqctl export_definitions /tmp/definitions.json`
- Check the release notes for breaking changes and required migration steps
- Verify version compatibility — nodes can temporarily run mixed versions during rolling upgrade

### Procedure

```bash
# 1. Check current version on all nodes
rabbitmqctl eval 'rabbit_misc:version().'

# 2. Export definitions (backup)
rabbitmqctl export_definitions /tmp/definitions-backup.json

# 3. Drain a node (stop accepting new connections, let existing ones drain)
rabbitmqctl close_all_connections "Upgrading node"

# 4. Stop the node
rabbitmqctl stop_app

# 5. Upgrade the package
# Debian/Ubuntu:
apt-get update && apt-get install rabbitmq-server=<new-version>
# RHEL/CentOS:
yum update rabbitmq-server-<new-version>
# Docker: update image tag in compose/k8s manifest

# 6. Start the node
rabbitmqctl start_app

# 7. Wait for the node to sync
rabbitmqctl await_startup
rabbitmqctl cluster_status

# 8. Verify quorum queue health (leaders should rebalance)
rabbitmq-queues check_if_node_is_quorum_critical

# 9. Repeat for next node
```

### Version Compatibility Rules

- **Patch versions** (3.13.1 → 3.13.2): Always compatible for rolling upgrade
- **Minor versions** (3.12.x → 3.13.x): Usually compatible. Check release notes.
- **Major versions** (3.x → 4.x): May require full cluster shutdown. Check migration guide.
- **Erlang upgrades**: Can be done alongside RabbitMQ upgrades. Check compatibility matrix.

### Feature Flags

RabbitMQ uses feature flags to gate new functionality that requires all nodes to be upgraded:

```bash
# List feature flags
rabbitmqctl list_feature_flags

# Enable a feature flag (after all nodes are upgraded)
rabbitmqctl enable_feature_flag <flag_name>

# Enable all stable feature flags
rabbitmqctl enable_feature_flag all
```

### Rollback

Rolling back is complex — Raft logs and Mnesia schema changes may not be backward-compatible. Best practices:
1. Always back up definitions before upgrade
2. Test in staging first
3. If rollback is needed, restore from definitions backup on a fresh cluster

---

## Cluster Sizing

### Node Count Guidelines

| Cluster Size | Quorum | Fault Tolerance | Use Case |
|:---:|:---:|:---:|---|
| 1 | N/A | None | Development, testing |
| 3 | 2 | 1 node failure | **Standard production** |
| 5 | 3 | 2 node failures | High availability, critical workloads |
| 7 | 4 | 3 node failures | Rarely needed, higher write latency |

**Always use odd numbers** to avoid split-brain ambiguity.

### Resource Sizing Per Node

| Workload | CPU | RAM | Disk | Network |
|----------|-----|-----|------|---------|
| Low (< 5k msg/s) | 2 cores | 4 GB | 50 GB SSD | 1 Gbps |
| Medium (5-20k msg/s) | 4 cores | 8 GB | 100 GB SSD | 1 Gbps |
| High (20-100k msg/s) | 8 cores | 16 GB | 500 GB NVMe | 10 Gbps |
| Very High (100k+ msg/s) | 16 cores | 32 GB | 1 TB NVMe | 10 Gbps |

### Memory Sizing

```ini
# rabbitmq.conf
# Set watermark relative to total RAM
vm_memory_high_watermark.relative = 0.6

# Or absolute (recommended for containers)
# vm_memory_high_watermark.absolute = 4GB

# Paging threshold (start offloading to disk)
vm_memory_high_watermark_paging_ratio = 0.75
```

**Rule of thumb**: RabbitMQ needs ~1 GB baseline + memory for message buffers + connection overhead (~100 KB per connection).

### Disk Sizing

```ini
# Disk free limit — publishers block if free space drops below this
disk_free_limit.relative = 1.5   # 1.5x total RAM

# For quorum queues: plan for Raft log storage
# Each message writes to WAL + segment files
# Budget: 2-3x message data size for quorum queue disk usage
```

**SSD is strongly recommended** for quorum queues. HDD will bottleneck on Raft log writes.

### Connection and Channel Limits

```bash
# Check file descriptor limit (each connection uses 2 FDs)
rabbitmqctl status | grep file_descriptors

# Increase FD limit
# /etc/systemd/system/rabbitmq-server.service.d/limits.conf
# [Service]
# LimitNOFILE=65536
```

**Planning**: 1 connection per application instance, multiple channels per connection. Budget ~100 KB RAM per connection, ~20 KB per channel.

### Anti-Patterns

- **Single large node instead of cluster** — no fault tolerance, scaling ceiling
- **Too many nodes (>7)** — Raft consensus latency increases with cluster size
- **Mixing workloads** — run separate clusters for different workload profiles
- **Cross-AZ/region clustering** — high latency kills Raft performance. Use Federation/Shovel instead.

---

## Cross-Datacenter with Federation and Shovel

### Federation

Federation links brokers across datacenters with eventual consistency. Upstream exchanges/queues replicate to downstream.

#### Architecture

```
DC1 (Primary)                    DC2 (Secondary)
┌─────────────────┐              ┌─────────────────┐
│ Exchange: orders │ ──────────> │ Exchange: orders │ (federated)
│ Queue: payments  │ ──────────> │ Queue: payments  │ (federated)
└─────────────────┘              └─────────────────┘
```

#### Setup

```bash
# Enable plugins on downstream (DC2)
rabbitmq-plugins enable rabbitmq_federation rabbitmq_federation_management

# Define upstream (DC1 connection info, configured on DC2)
rabbitmqctl set_parameter federation-upstream dc1 \
  '{
    "uri": "amqp://federation_user:pass@dc1-rabbit.example.com:5672/%2Fproduction",
    "expires": 3600000,
    "message-ttl": 86400000,
    "ack-mode": "on-confirm",
    "trust-user-id": false,
    "max-hops": 1
  }'

# Create federation policy (apply to exchanges matching pattern)
rabbitmqctl set_policy federate-orders "^orders" \
  '{"federation-upstream-set": "all"}' \
  --apply-to exchanges --priority 10

# Federate specific queues
rabbitmqctl set_policy federate-payments "^payments$" \
  '{"federation-upstream-set": "all"}' \
  --apply-to queues --priority 10
```

#### Federation Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `uri` | AMQP URI of the upstream broker | Required |
| `expires` | Upstream queue TTL (ms) — auto-cleanup | None |
| `message-ttl` | Max age of federated messages (ms) | None |
| `ack-mode` | `on-confirm`, `on-publish`, `no-ack` | `on-confirm` |
| `max-hops` | Prevent message loops in multi-DC setups | 1 |
| `prefetch-count` | Federation link prefetch | 1000 |
| `reconnect-delay` | Delay between reconnection attempts (s) | 5 |

#### Bidirectional Federation

```bash
# On DC1: federate from DC2
rabbitmqctl set_parameter federation-upstream dc2 \
  '{"uri": "amqp://federation_user:pass@dc2-rabbit:5672/%2Fproduction", "max-hops": 1}'

# On DC2: federate from DC1
rabbitmqctl set_parameter federation-upstream dc1 \
  '{"uri": "amqp://federation_user:pass@dc1-rabbit:5672/%2Fproduction", "max-hops": 1}'

# max-hops=1 prevents infinite loops
```

### Shovel

Shovel moves messages from a source to a destination. More explicit control than Federation.

#### Static Shovel (Config File)

```ini
# rabbitmq.conf (advanced.config for complex shovels)
# Prefer dynamic shovels via API for production
```

#### Dynamic Shovel (Recommended)

```bash
rabbitmq-plugins enable rabbitmq_shovel rabbitmq_shovel_management

# One-way message transfer
rabbitmqctl set_parameter shovel orders-to-dc2 \
  '{
    "src-protocol": "amqp091",
    "src-uri": "amqp://user:pass@localhost",
    "src-queue": "orders",
    "dest-protocol": "amqp091",
    "dest-uri": "amqp://user:pass@dc2-rabbit:5672/%2Fproduction",
    "dest-queue": "orders",
    "ack-mode": "on-confirm",
    "src-prefetch-count": 1000,
    "reconnect-delay": 5
  }'

# Check shovel status
rabbitmqctl shovel_status
```

### Federation vs Shovel

| Aspect | Federation | Shovel |
|--------|-----------|--------|
| Direction | Pull (downstream fetches from upstream) | Push (source pushes to destination) |
| Topology | Exchange/queue-level replication | Point-to-point message transfer |
| Setup | Policy-based (pattern matching) | Explicit source→destination |
| Bidirectional | Yes (with max-hops) | Need two shovels |
| Use case | Multi-DC active-active | Migration, bridging, aggregation |
| Protocol | AMQP only | AMQP, AMQP 1.0 |

### Active-Active Multi-DC Pattern

```
DC1 ←──Federation──→ DC2
 │                     │
 ├── Local producers   ├── Local producers
 ├── Local consumers   ├── Local consumers
 └── Quorum queues     └── Quorum queues
     (local cluster)       (local cluster)

- Each DC has its own independent cluster
- Federation replicates exchanges bidirectionally
- max-hops=1 prevents loops
- Consumers in each DC process local + federated messages
- Caveat: no deduplication — same message may be processed in both DCs
```

---

## Stream Replication

### Overview

RabbitMQ Streams (3.9+) are an append-only log data structure designed for high-throughput, fan-out, and replay workloads. In a cluster, streams replicate across nodes for fault tolerance.

### Stream Replication Architecture

```
Node1 (Leader)     Node2 (Follower)   Node3 (Follower)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ Segment 1    │──>│ Segment 1    │──>│ Segment 1    │
│ Segment 2    │──>│ Segment 2    │──>│ Segment 2    │
│ Segment 3    │──>│ Segment 3    │   │ (catching up) │
└──────────────┘   └──────────────┘   └──────────────┘
```

- Leader handles all writes and coordinates replication
- Followers can serve reads (consumer connects to any node)
- Replication is synchronous for committed data — a message is committed once a quorum of replicas confirm

### Declaration

```python
# Via AMQP (basic)
channel.queue_declare(queue='events.stream', durable=True, arguments={
    'x-queue-type': 'stream',
    'x-max-length-bytes': 10_000_000_000,        # 10 GB retention
    'x-max-age': '7D',                           # 7-day retention
    'x-stream-max-segment-size-bytes': 500_000_000,  # 500 MB segments
    'x-initial-cluster-size': 3                   # Replicate across 3 nodes
})
```

### Stream Protocol (Native, Higher Performance)

For maximum throughput, use the native stream protocol (port 5552) instead of AMQP:

```python
# Python — rstream library (native stream protocol)
# pip install rstream

import asyncio
from rstream import Producer, Consumer, AMQPMessage, amqp_decoder

async def produce():
    async with Producer('localhost', username='admin', password='pass') as producer:
        await producer.create_stream('events', exists_ok=True, arguments={
            'max-length-bytes': 10_000_000_000,
            'max-age': '7D'
        })

        for i in range(100000):
            await producer.send('events', AMQPMessage(body=f'event-{i}'.encode()))

async def consume():
    consumer = Consumer('localhost', username='admin', password='pass')
    await consumer.start()

    async def on_message(msg, message_context):
        print(f'Offset {message_context.offset}: {msg.body}')

    await consumer.subscribe('events', on_message, decoder=amqp_decoder,
                             offset_specification=OffsetType.FIRST)
    await consumer.run()
```

### Stream vs Quorum Queue

| Feature | Stream | Quorum Queue |
|---------|--------|-------------|
| Data structure | Append-only log | FIFO queue |
| Consumption | Non-destructive (fan-out) | Destructive (competing consumers) |
| Replay | Yes (from any offset) | No (once consumed, gone) |
| Ordering | Total order guaranteed | FIFO per queue |
| Throughput | Very high (100k+ msg/s) | Moderate (30-50k msg/s) |
| Retention | Time/size-based | Until consumed |
| Use case | Event sourcing, audit logs, fan-out | Task distribution, request processing |

### Super Streams (Partitioned Streams)

Super streams partition data across multiple stream queues for scalability:

```bash
# Create a super stream with 3 partitions (via rabbitmq-streams CLI)
rabbitmq-streams add_super_stream events --partitions 3

# This creates:
#   events-0  (partition 0)
#   events-1  (partition 1)
#   events-2  (partition 2)
# Bound to exchange "events" with consistent hash routing
```

```python
# Produce to super stream — messages routed by routing key hash
async with Producer('localhost', username='admin', password='pass') as producer:
    await producer.send_wait(
        'events',  # Super stream name
        AMQPMessage(body=b'event data'),
        routing_key='user-123'  # Determines partition
    )
```

### Monitoring Streams

```bash
# List streams with replication info
rabbitmqctl list_queues name type leader followers online \
  --filter 'type=stream'

# Stream-specific metrics via API
curl -s -u admin:pass http://localhost:15672/api/queues/%2F/events.stream | \
  python3 -c "
import sys, json
q = json.load(sys.stdin)
print(f\"Leader: {q.get('leader')}\")
print(f\"Followers: {q.get('members', [])}\")
print(f\"Messages: {q.get('messages', 0)}\")
print(f\"Segments: {q.get('segments', 'N/A')}\")
"

# Enable Prometheus metrics for streams
# Streams metrics are exported alongside other queue metrics on :15692/metrics
```

### Stream Performance Tuning

```ini
# rabbitmq.conf — Stream-specific tuning

# TCP buffer sizes for stream protocol
# stream.tcp.listener.port = 5552
# stream.tcp.listener.backlog = 128

# Stream replication chunk size
# stream.replication.chunk_size = 1048576

# Flush interval for stream writes (ms) — lower = more durable, higher = more throughput
# stream.flush_interval = 50
```

**Tips:**
- Use SSD/NVMe storage — streams are I/O intensive
- Set `x-stream-max-segment-size-bytes` to 500 MB - 1 GB for optimal compaction
- Use the native stream protocol (port 5552) for 5-10x throughput vs AMQP
- Consumers can connect to follower nodes to offload the leader
- Monitor segment count — too many small segments indicate misconfigured segment size
