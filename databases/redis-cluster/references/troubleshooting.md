# Redis Cluster Troubleshooting Guide

A dense, actionable reference for diagnosing and resolving Redis Cluster issues in production. Every section includes symptoms, diagnosis commands, root cause analysis, fixes, and prevention strategies.

---

## Table of Contents

- [Split-Brain Scenarios](#split-brain-scenarios)
- [Slot Migration Failures](#slot-migration-failures)
- [Node Join/Leave Issues](#node-joinleave-issues)
- [Memory Fragmentation](#memory-fragmentation)
- [Client Redirect Storms](#client-redirect-storms)
- [Cluster State Inconsistency](#cluster-state-inconsistency)
- [Replication Buffer Overflow](#replication-buffer-overflow)
- [Slow Log Analysis](#slow-log-analysis)
- [Latency Diagnosis](#latency-diagnosis)
- [Network Partition Recovery](#network-partition-recovery)

---

## Split-Brain Scenarios

A split-brain occurs when two or more nodes believe they are the master for the same hash slot range. This causes data divergence — clients connected to different partitions write conflicting data.

### Symptoms

- Clients reading stale or inconsistent data depending on which node they connect to.
- `CLUSTER NODES` output from different nodes shows different masters for the same slots.
- Application-level anomalies: counters going backward, overwritten values, duplicate records.

### Diagnosis

Run `CLUSTER NODES` from every master node and compare slot ownership:

```bash
# Collect slot maps from all nodes
for port in 7000 7001 7002 7003 7004 7005; do
  echo "=== Node on port $port ==="
  redis-cli -p $port CLUSTER NODES | grep master | awk '{print $1, $2, $3, $NF}'
done
```

Look for conflicting output — two nodes both claiming `master` with overlapping slot ranges:

```
# Node A's view:
a1b2c3d4 127.0.0.1:7000@17000 myself,master - 0-5460

# Node B's view (from another partition):
e5f6g7h8 127.0.0.1:7003@17003 myself,master - 0-5460
```

Check each node's config epoch to determine which claim is "newer":

```bash
redis-cli -p 7000 CLUSTER INFO | grep cluster_current_epoch
redis-cli -p 7003 CLUSTER INFO | grep cluster_current_epoch
```

The node with the higher config epoch won the most recent election. However, during a true split-brain both sides may have incremented independently.

### Root Cause

1. A network partition separates the cluster into two groups.
2. The minority partition (containing the old master) continues accepting writes if `min-replicas-to-write` is not configured.
3. The majority partition promotes a replica to master via failover.
4. When the partition heals, two nodes own the same slots.

### Resolution

**Step 1: Identify the authoritative master.** The node in the majority partition with the higher config epoch is typically authoritative.

**Step 2: Demote the stale master.** Connect to the stale master and force it to become a replica:

```bash
# On the stale master — force it to replicate the authoritative master
redis-cli -p 7000 CLUSTER FAILOVER TAKEOVER
# If that doesn't work, use CLUSTER RESET on the stale node:
redis-cli -p 7000 CLUSTER RESET SOFT
# Then re-add it as a replica:
redis-cli -p 7000 CLUSTER REPLICATE <authoritative-master-node-id>
```

**Step 3: Verify convergence.** After intervention, check from every node:

```bash
redis-cli -p 7000 CLUSTER NODES | grep master
redis-cli -p 7003 CLUSTER NODES | grep master
# Slot ranges must not overlap between masters
```

**Step 4: Data reconciliation.** Redis does not merge data automatically. After the stale master becomes a replica, it discards its data and syncs from the authoritative master. Writes that went to the stale master during the partition are **permanently lost** unless you exported them beforehand.

To salvage data from the stale master before demoting it:

```bash
# Dump all keys from the stale master before resetting
redis-cli -p 7000 --rdb /tmp/stale-master-dump.rdb
# Or selectively export keys:
redis-cli -p 7000 --scan --pattern '*' | while read key; do
  redis-cli -p 7000 DUMP "$key" | redis-cli -p 7003 RESTORE "$key" 0 -
done
```

### Prevention

```
# redis.conf — require at least 1 connected replica before accepting writes
min-replicas-to-write 1
min-replicas-max-lag 10

# Set a reasonable node timeout (default 15000ms)
cluster-node-timeout 15000
```

- Deploy nodes across multiple availability zones but ensure the majority can always reach each other.
- Monitor network connectivity between all cluster bus ports (default: data port + 10000).
- Alert on `cluster_state:fail` from `CLUSTER INFO` on any node.

---

## Slot Migration Failures

Slot migration moves keys between nodes during resharding. A failure leaves slots stuck in an intermediate `MIGRATING` or `IMPORTING` state, which disrupts normal operations on those slots.

### Symptoms

- Clients receive `-ASK` redirections for keys in the affected slots indefinitely.
- `CLUSTER NODES` shows slots with `[<slot>->-<node-id>]` (migrating) or `[<slot>-<-<node-id>]` (importing) annotations.
- `CLUSTER INFO` may report `cluster_state:ok` even though specific slots are broken.

### Diagnosis

```bash
# Find stuck migrating/importing slots
redis-cli -p 7000 CLUSTER NODES | grep -E '\[.*->-|.*-<-'
```

Example output showing a stuck migration of slot 1234:

```
a1b2c3d4 127.0.0.1:7000@17000 myself,master - 0-5460 [1234->-e5f6g7h8]
e5f6g7h8 127.0.0.1:7001@17001 master - 5461-10922 [1234-<-a1b2c3d4]
```

Check which keys remain in the slot on the source node:

```bash
redis-cli -p 7000 CLUSTER COUNTKEYSINSLOT 1234
redis-cli -p 7000 CLUSTER GETKEYSINSLOT 1234 100
```

And on the target:

```bash
redis-cli -p 7001 CLUSTER COUNTKEYSINSLOT 1234
```

### Root Cause

- Network timeout during `MIGRATE` command — especially with large keys (>1MB).
- Source or target node crashed mid-migration.
- `redis-cli --cluster reshard` was interrupted (Ctrl+C, OOM kill, SSH disconnect).
- A large key blocks the `MIGRATE` command beyond the timeout, causing it to fail.

### Resolution

**Option A: Let the tool fix it automatically.**

```bash
redis-cli --cluster fix 127.0.0.1:7000
```

This scans for stuck migrating/importing states and attempts to complete or roll back each migration. It moves remaining keys and then clears the slot state.

**Option B: Manual fix — clear the stuck state.**

If `--cluster fix` doesn't resolve it, manually stabilize:

```bash
# On the SOURCE node — clear migrating state
redis-cli -p 7000 CLUSTER SETSLOT 1234 STABLE

# On the TARGET node — clear importing state
redis-cli -p 7001 CLUSTER SETSLOT 1234 STABLE
```

After clearing, verify slot ownership:

```bash
redis-cli -p 7000 CLUSTER NODES | grep -E '1234'
```

If keys ended up split between source and target, migrate the remaining keys manually:

```bash
# Get keys still on source for the slot
redis-cli -p 7000 CLUSTER GETKEYSINSLOT 1234 100

# Migrate each key to the target (timeout in ms)
redis-cli -p 7000 MIGRATE 127.0.0.1 7001 "" 0 5000 KEYS key1 key2 key3
```

**Option C: Handle large key blocking migration.**

If a single large key (hash, set, sorted set with millions of elements) is timing out during `MIGRATE`:

```bash
# Check the size of the key
redis-cli -p 7000 MEMORY USAGE mylargekey

# Increase the migration timeout
redis-cli -p 7000 MIGRATE 127.0.0.1 7001 mylargekey 0 60000
```

If the key is too large, consider deleting it, migrating with `COPY`+`REPLACE`, or restructuring the data.

### Prevention

- Avoid very large keys (>10MB). Use hash partitioning or split across multiple keys.
- Run resharding during low-traffic periods.
- Use `--cluster-pipeline` to batch key migrations for efficiency.
- Monitor resharding operations — don't run them in detached tmux sessions without logging.

---

## Node Join/Leave Issues

Adding and removing nodes from a running cluster can fail in subtle ways, leaving the cluster in an inconsistent state.

### Symptoms — Node Stuck in Handshake

```bash
redis-cli -p 7000 CLUSTER NODES
# Output shows:
# f8a2b3c4 127.0.0.1:7006@17006 handshake - 0 0 0 connected
```

The node stays in `handshake` indefinitely and never transitions to a normal state.

### Diagnosis

```bash
# Verify the new node is reachable on both the data port AND the bus port
nc -zv 127.0.0.1 7006    # data port
nc -zv 127.0.0.1 17006   # cluster bus port (data port + 10000)

# Check firewall rules
iptables -L -n | grep -E '7006|17006'

# Verify the node's own cluster config
redis-cli -p 7006 CLUSTER INFO
redis-cli -p 7006 CLUSTER MYID
```

**Root cause:** The cluster bus port (data port + 10000) is blocked by a firewall or security group. The initial `CLUSTER MEET` uses the data port, but subsequent gossip uses the bus port.

**Fix:** Open the bus port in all firewalls/security groups between all cluster nodes.

### Symptoms — CLUSTER MEET Succeeds but Node Doesn't Appear

```bash
redis-cli -p 7000 CLUSTER MEET 192.168.1.100 7006
# Returns OK, but the node never appears in CLUSTER NODES
```

**Diagnosis:**

```bash
# Check what address the new node advertises
redis-cli -p 7006 CLUSTER NODES
# Look at the "myself" line — is the IP what you expect?
# If behind NAT, the node might advertise a private IP
```

**Root cause:** IP/port mismatch. The new node announces a different IP (e.g., a Docker internal IP or 127.0.0.1) than what other nodes can reach.

**Fix:** Set `cluster-announce-ip`, `cluster-announce-port`, and `cluster-announce-bus-port` in the new node's config:

```
cluster-announce-ip 192.168.1.100
cluster-announce-port 7006
cluster-announce-bus-port 17006
```

Restart the node and re-issue `CLUSTER MEET`.

### Symptoms — Removing a Node That Still Owns Slots

```bash
redis-cli --cluster del-node 127.0.0.1:7000 <node-id>
# Error: Node still holds hash slots, cannot remove
```

**Fix:** Reshard all slots away before removing:

```bash
# Move all slots from the node being removed to another master
redis-cli --cluster reshard 127.0.0.1:7000 \
  --cluster-from <departing-node-id> \
  --cluster-to <target-node-id> \
  --cluster-slots 5461 \
  --cluster-yes
# Then remove
redis-cli --cluster del-node 127.0.0.1:7000 <departing-node-id>
```

### Symptoms — Ghost Nodes

Nodes that were removed or crashed still appear in `CLUSTER NODES` output.

**Root cause:** `CLUSTER FORGET` was sent to some nodes but not all, and gossip re-propagated the forgotten node's info.

**Fix:** `CLUSTER FORGET` must be sent to **every** node in the cluster within a 60-second window (before the next gossip cycle re-introduces the node):

```bash
# Get the node ID to forget
GHOST_ID="f8a2b3c4..."

# Send FORGET to all other nodes within 60 seconds
for port in 7000 7001 7002 7003 7004 7005; do
  redis-cli -p $port CLUSTER FORGET $GHOST_ID
done
```

If the ghost node is actually still running, shut it down first or it will rejoin via gossip.

### Prevention

- Always verify bus port connectivity before `CLUSTER MEET`.
- Set `cluster-announce-*` in containerized or NAT environments.
- Script `CLUSTER FORGET` to hit all nodes atomically.
- Maintain an inventory of expected cluster nodes and alert on unexpected members.

---

## Memory Fragmentation

Memory fragmentation occurs when Redis's allocator (jemalloc) cannot efficiently reuse freed memory, causing the RSS (resident set size) to grow well beyond the actual data size.

### Symptoms

- Redis `used_memory` is stable but `used_memory_rss` keeps growing.
- The OS reports high memory usage even though key count is steady.
- OOM killer targets Redis despite apparently adequate memory.

### Diagnosis

```bash
redis-cli -p 7000 INFO memory
```

Key metrics:

```
used_memory:1073741824           # 1GB — memory allocated by Redis
used_memory_rss:2147483648       # 2GB — memory reported by OS
mem_fragmentation_ratio:2.00     # RSS / used_memory
mem_fragmentation_bytes:1073741824
mem_allocator:jemalloc-5.2.1
```

| `mem_fragmentation_ratio` | Meaning |
|--------------------------|---------|
| 1.0 – 1.5 | Healthy. Normal overhead. |
| > 1.5 | High fragmentation. RSS significantly exceeds data size. |
| > 2.0 | Critical. Investigate immediately. |
| < 1.0 | Redis is swapping to disk. **Emergency.** |

Check fragmentation across all cluster nodes — it varies per node based on workload:

```bash
for port in 7000 7001 7002 7003 7004 7005; do
  echo -n "Port $port: "
  redis-cli -p $port INFO memory | grep mem_fragmentation_ratio
done
```

### Root Cause

- Frequent creation and deletion of small keys with varied sizes.
- Mixed value sizes (e.g., 64-byte strings alongside 10KB hashes).
- Large keys deleted, leaving holes in memory that can't be reused for smaller allocations.
- Long-running instance without restart.

### Resolution

**Option A: Online defragmentation (preferred — no downtime).**

```bash
# One-time purge of jemalloc dirty pages
redis-cli -p 7000 MEMORY PURGE

# Enable active defragmentation
redis-cli -p 7000 CONFIG SET activedefrag yes
```

Tune active defrag to balance CPU usage:

```bash
# Start defragging when fragmentation exceeds 10%
redis-cli -p 7000 CONFIG SET active-defrag-threshold-lower 10

# Use max CPU effort when fragmentation exceeds 30%
redis-cli -p 7000 CONFIG SET active-defrag-threshold-upper 30

# CPU effort range (percentage of main thread CPU)
redis-cli -p 7000 CONFIG SET active-defrag-cycle-min 1
redis-cli -p 7000 CONFIG SET active-defrag-cycle-max 25

# Max size of keys to defrag inline (larger ones use async)
redis-cli -p 7000 CONFIG SET active-defrag-max-scan-fields 1000
```

**Option B: Rolling restart (guaranteed fix but brief downtime per node).**

Restart one node at a time. After restart, jemalloc starts fresh with zero fragmentation.

```bash
# For a replica node — safe to restart directly
redis-cli -p 7005 SHUTDOWN NOSAVE
# Wait for it to come back up and re-sync

# For a master — failover first to avoid slot coverage loss
redis-cli -p 7003 CLUSTER FAILOVER
# Wait for the node to become a replica, then restart
redis-cli -p 7003 SHUTDOWN NOSAVE
```

### When to Restart vs. When to Defrag

| Scenario | Action |
|----------|--------|
| `mem_fragmentation_ratio` 1.5–2.0 | Enable active defrag, monitor |
| `mem_fragmentation_ratio` > 2.0 | Try `MEMORY PURGE` + active defrag; if no improvement in 30 min, rolling restart |
| `mem_fragmentation_ratio` < 1.0 | **Swap detected.** Add RAM or reduce data set immediately. Restart only after fixing root cause. |

### Prevention

- Enable `activedefrag yes` in config by default.
- Use consistent value sizes where possible.
- Avoid very large keys that leave big holes when deleted.
- Monitor `mem_fragmentation_ratio` with alerts at 1.5 and 2.0 thresholds.

---

## Client Redirect Storms

In a healthy cluster, clients cache the slot-to-node mapping and rarely encounter redirections. A redirect storm happens when clients receive a massive volume of `MOVED` and `ASK` errors, causing high latency, increased CPU, and degraded throughput.

### Symptoms

- Client-side error logs flooded with `MOVED` or `ASK` responses.
- Client CPU usage spikes — each redirect requires a new connection and retry.
- Application latency increases by 2–10x.
- `CLUSTER INFO` shows high `cluster_stats_messages_sent` and `cluster_stats_messages_received`.

### Diagnosis

```bash
# Check for recent topology changes
redis-cli -p 7000 CLUSTER INFO | grep -E 'cluster_current_epoch|cluster_stats_messages'
```

```
cluster_current_epoch:12
cluster_stats_messages_sent:584920
cluster_stats_messages_received:584918
```

A rapidly incrementing `cluster_current_epoch` indicates frequent failovers or reconfigurations.

Monitor redirections client-side. Most Redis client libraries expose redirect counters. For ad-hoc testing:

```bash
# Use MONITOR on a node to see incoming commands (brief window only — impacts performance)
redis-cli -p 7000 MONITOR | head -100
# Look for patterns: same client repeatedly hitting wrong node
```

Check if resharding is in progress:

```bash
redis-cli -p 7000 CLUSTER NODES | grep -E '\[.*->-|.*-<-'
```

### Root Cause

**Cause 1: Stale client slot map.** After a failover or topology change, clients using a cached slot map send commands to the old master. Each command returns a `MOVED` error pointing to the new master. If the client doesn't refresh its slot map, every command triggers a redirect.

**Cause 2: Resharding generating ASK redirections.** During resharding, keys in migrating slots trigger `ASK` redirections for every access. If many hot keys are in the slots being migrated, the redirect volume explodes.

### Resolution

**For stale slot maps:**

```bash
# Verify cluster is stable — no ongoing failovers
redis-cli -p 7000 CLUSTER INFO | grep cluster_state
# Should show: cluster_state:ok
```

Client-side fix — configure automatic topology refresh:

```java
// Lettuce (Java) — refresh topology every 15 seconds
ClusterTopologyRefreshOptions topologyRefresh = ClusterTopologyRefreshOptions.builder()
    .enablePeriodicRefresh(Duration.ofSeconds(15))
    .enableAllAdaptiveRefreshTriggers()
    .build();
```

```python
# redis-py — enable read-from-replicas with auto-refresh
from redis.cluster import RedisCluster
rc = RedisCluster(host='127.0.0.1', port=7000, reinitialize_steps=25)
# reinitialize_steps: refresh slot map every N redirect errors
```

**For resharding ASK storms:**

Slow down the resharding operation:

```bash
# Reduce pipeline size (fewer keys moved per batch)
redis-cli --cluster reshard 127.0.0.1:7000 \
  --cluster-pipeline 10 \
  --cluster-slots 100
# Move fewer slots at a time, pausing between batches
```

If hot keys are in the migrating slots, consider migrating those specific slots during off-peak hours.

### Prevention

- Configure clients to refresh topology on any `MOVED` response (most libraries support this).
- Set periodic topology refresh intervals (10–30 seconds).
- During resharding, monitor redirect rates and pause if they spike.
- Avoid resharding during peak traffic windows.
- Use `READONLY` mode on replicas to distribute read traffic and reduce redirects.

---

## Cluster State Inconsistency

When nodes disagree on the cluster topology — who owns which slots, what the current epoch is, or which nodes exist — the cluster enters an inconsistent state that can degrade to `cluster_state:fail`.

### Symptoms

- `CLUSTER INFO` returns `cluster_state:fail` on one or more nodes.
- Different nodes report different values for `cluster_current_epoch`.
- `CLUSTER NODES` output differs between nodes (beyond normal propagation delay).
- Clients receive `-CLUSTERDOWN The cluster is down` errors.

### Diagnosis

```bash
# Compare cluster state across all nodes
for port in 7000 7001 7002 7003 7004 7005; do
  echo "=== Port $port ==="
  redis-cli -p $port CLUSTER INFO | grep -E 'cluster_state|cluster_current_epoch|cluster_slots_ok|cluster_slots_fail'
done
```

Expected output for a healthy cluster:

```
cluster_state:ok
cluster_current_epoch:6
cluster_slots_ok:16384
cluster_slots_fail:0
```

If epochs diverge:

```
=== Port 7000 ===
cluster_current_epoch:6

=== Port 7003 ===
cluster_current_epoch:9
```

This means node 7003 has seen elections or reconfigurations that 7000 hasn't — possibly due to a recent partition.

Check which slots are uncovered:

```bash
redis-cli --cluster check 127.0.0.1:7000
```

This reports any slots without an assigned master.

### Root Cause

- Network partition caused independent elections, incrementing epochs differently.
- Manual `CLUSTER FAILOVER` or `CLUSTER RESET` commands issued incorrectly.
- `nodes.conf` file corruption (disk full, crash during write).
- Clock skew affecting timeout calculations (less common but possible).

### Resolution

**Fix 1: Let gossip converge.** After a partition heals, wait 2–3× `cluster-node-timeout` for gossip to propagate. Check `CLUSTER INFO` again — epochs should converge.

**Fix 2: Run the automated fixer.**

```bash
redis-cli --cluster fix 127.0.0.1:7000
redis-cli --cluster check 127.0.0.1:7000
```

**Fix 3: Manually bump a lagging node's epoch.**

```bash
# On the node with the lower epoch:
redis-cli -p 7000 CLUSTER SET-CONFIG-EPOCH 9
# The epoch value must be unique across all nodes
```

**Fix 4: Recover from `nodes.conf` corruption.**

If a node starts with a corrupt `nodes.conf`, it may disagree with the rest of the cluster.

```bash
# Stop the affected node
redis-cli -p 7000 SHUTDOWN NOSAVE

# Delete or rename the corrupt nodes.conf
mv /var/lib/redis/7000/nodes.conf /var/lib/redis/7000/nodes.conf.bak

# Restart Redis — it will start as an empty standalone node
redis-server /etc/redis/7000.conf

# Re-add it to the cluster
redis-cli -p 7001 CLUSTER MEET 127.0.0.1 7000

# If it was a replica, re-attach it
redis-cli -p 7000 CLUSTER REPLICATE <master-node-id>
```

**Fix 5: Last resort — `CLUSTER RESET HARD`.**

```bash
# WARNING: This wipes the node's cluster state AND data
redis-cli -p 7000 CLUSTER RESET HARD
# Then re-add and resync
redis-cli -p 7001 CLUSTER MEET 127.0.0.1 7000
redis-cli -p 7000 CLUSTER REPLICATE <master-node-id>
```

### Prevention

- Ensure disk has adequate free space for `nodes.conf` writes.
- Back up `nodes.conf` periodically.
- Avoid manual epoch manipulation unless you fully understand the implications.
- Monitor `cluster_current_epoch` consistency across nodes.

---

## Replication Buffer Overflow

When a master generates writes faster than a replica can consume them, the replication output buffer overflows. The master disconnects the replica, forcing a full resync — which generates even more traffic, creating a vicious loop.

### Symptoms

- Replica perpetually in `loading` state — never finishes syncing.
- `INFO replication` on the master shows replicas disconnecting and reconnecting.
- High network bandwidth between master and replica.
- Logs show: `Client id=XXX addr=... laddr=... fd=... name= ... scheduled to be closed ASAP for overcoming of output buffer limits`.

### Diagnosis

```bash
# On the master — check replication status
redis-cli -p 7000 INFO replication
```

```
role:master
connected_slaves:1
slave0:ip=127.0.0.1,port=7003,state=online,offset=1234567,lag=2
master_repl_offset:2345678
repl_backlog_active:1
repl_backlog_size:1048576
repl_backlog_first_byte_offset:1000000
repl_backlog_histlen:1345678
```

Key warning signs:
- `slave0:state=wait_bgsave` or `state=send_bulk` for extended periods.
- Large gap between `master_repl_offset` and `slave0:offset` (replica is falling behind).
- `lag` value continuously increasing.

Check the current output buffer limits:

```bash
redis-cli -p 7000 CONFIG GET client-output-buffer-limit
```

Default for replicas: `256mb 64mb 60` — meaning: hard limit 256MB, soft limit 64MB sustained for 60 seconds.

Check the backlog size:

```bash
redis-cli -p 7000 CONFIG GET repl-backlog-size
# Default: 1mb — often too small for production
```

### Root Cause

- Write throughput exceeds the replica's ability to process and acknowledge data.
- Resharding generates burst write traffic (key migrations) that fills the replication buffer.
- Slow replica (disk I/O bottleneck, CPU contention, network congestion).
- `repl-backlog-size` too small — any brief replica disconnect forces a full resync instead of partial.

### Resolution

**Fix 1: Increase the replication backlog.**

```bash
# Set backlog to 256MB (adjust based on write throughput)
redis-cli -p 7000 CONFIG SET repl-backlog-size 268435456
```

Rule of thumb: `repl-backlog-size` should hold at least 60 seconds of write traffic. If your master does 10MB/s of writes, set it to at least 600MB.

**Fix 2: Increase output buffer limits for replicas.**

```bash
redis-cli -p 7000 CONFIG SET client-output-buffer-limit "replica 512mb 128mb 120"
```

**Fix 3: Reduce write throughput during operations.**

If resharding is causing the buffer overflow:

```bash
# Pause resharding, let replicas catch up, then resume
# Use --cluster-pipeline with a small value to slow migration
redis-cli --cluster reshard 127.0.0.1:7000 --cluster-pipeline 5
```

**Fix 4: Address replica bottlenecks.**

```bash
# Check replica disk I/O
redis-cli -p 7003 INFO persistence | grep -E 'rdb_last_bgsave|aof_last_rewrite'

# If AOF rewrite is causing I/O contention:
redis-cli -p 7003 CONFIG SET no-appendfsync-on-rewrite yes

# Consider disabling persistence on replicas if masters have it
redis-cli -p 7003 CONFIG SET save ""
```

### Prevention

- Set `repl-backlog-size` to at least 100MB in production (256MB+ recommended).
- Set generous `client-output-buffer-limit replica` values: `512mb 256mb 120`.
- Monitor replication lag per node: alert when `lag` exceeds 5 seconds.
- Schedule resharding and bulk operations during low-write periods.
- Ensure replicas have equivalent hardware to masters (especially disk I/O).

---

## Slow Log Analysis

The Redis slow log records commands that exceed a configured execution time threshold. In a cluster, you must aggregate slow logs across all nodes to get a complete picture.

### Symptoms

- Intermittent latency spikes reported by the application.
- Specific commands consistently slow.
- Latency spikes correlate with specific nodes.

### Diagnosis

```bash
# Get the last 25 slow log entries from a single node
redis-cli -p 7000 SLOWLOG GET 25
```

Example output:

```
1) 1) (integer) 142            # Entry ID
   2) (integer) 1697012345     # Unix timestamp
   3) (integer) 50234          # Duration in microseconds (50ms)
   4) 1) "KEYS"               # Command and arguments
      2) "session:*"
   5) "127.0.0.1:52340"       # Client address
   6) ""                       # Client name
```

Check the current slow log threshold:

```bash
redis-cli -p 7000 CONFIG GET slowlog-log-slower-than
# Default: 10000 (10ms). Value in microseconds. -1 disables, 0 logs everything.
```

**Aggregate slow logs across all cluster nodes:**

```bash
#!/bin/bash
# Collect slow logs from all nodes, sorted by duration
for port in 7000 7001 7002 7003 7004 7005; do
  redis-cli -p $port SLOWLOG GET 50 | while IFS= read -r line; do
    echo "[port:$port] $line"
  done
done
```

A more structured approach using `redis-cli` raw mode:

```bash
for port in 7000 7001 7002 7003 7004 7005; do
  echo "=== Slowlog for port $port ==="
  redis-cli -p $port SLOWLOG GET 10
  echo ""
done
```

### Cluster-Specific Slow Operations

Certain commands are inherently slow in a cluster context:

| Command | Typical Duration | Cause |
|---------|-----------------|-------|
| `MIGRATE` | 10ms–10s+ | Moves key between nodes; serializes, transfers, deserializes |
| `CLUSTER SETSLOT` | 1–50ms | Updates slot assignment; triggers config propagation |
| `CLUSTER NODES` | 1–10ms | Serializes full node table (grows with cluster size) |
| `KEYS *` | 100ms–30s+ | Full keyspace scan — **never use in production** |
| `FLUSHDB` | Variable | Blocks while deleting all keys (use `FLUSHDB ASYNC`) |

### Configuration Per Environment

```bash
# Development — log everything slower than 1ms
redis-cli CONFIG SET slowlog-log-slower-than 1000

# Staging — log everything slower than 5ms
redis-cli CONFIG SET slowlog-log-slower-than 5000

# Production — log everything slower than 10ms (default)
redis-cli CONFIG SET slowlog-log-slower-than 10000

# Increase slow log buffer size (default 128 entries)
redis-cli CONFIG SET slowlog-max-len 512
```

### Prevention

- Replace `KEYS` with `SCAN` in application code.
- Avoid `FLUSHDB` / `FLUSHALL` without `ASYNC`.
- Break large `MGET`/`MSET` operations into smaller batches.
- Monitor slow log length: if it fills up quickly, the threshold may be too low or there's a real problem.

---

## Latency Diagnosis

Latency in Redis Cluster has two components: intrinsic (Redis processing time) and extrinsic (network, client, OS). Distinguishing between them is critical for effective troubleshooting.

### Symptoms

- Application-level P99 latency exceeds SLA.
- Latency spikes at regular intervals (suggests background operations).
- Latency varies by node (suggests node-specific issues).

### Diagnosis — Built-in Tools

**Baseline latency measurement:**

```bash
# Continuous latency test (Ctrl+C to stop)
redis-cli -p 7000 --latency
# Output: min: 0, max: 3, avg: 0.42 (1523 samples)

# Latency history — shows changes over time (default 15s intervals)
redis-cli -p 7000 --latency-history --latency-history-interval 5

# Latency distribution — visual spectrum
redis-cli -p 7000 --latency-dist
```

**Intrinsic latency measurement (OS + hardware baseline):**

```bash
# Measure the inherent latency of the system (100 seconds)
redis-cli --intrinsic-latency 100
# Output: Max latency so far: 547 microseconds
# This is the minimum latency Redis can achieve on this hardware
```

**Redis latency monitoring subsystem:**

```bash
# Enable latency monitoring (log events exceeding 100ms)
redis-cli -p 7000 CONFIG SET latency-monitor-threshold 100

# View latest latency events
redis-cli -p 7000 LATENCY LATEST
```

Example output:

```
1) 1) "fork"                 # Event type
   2) (integer) 1697012345   # Timestamp
   3) (integer) 203          # Latest duration (ms)
   4) (integer) 450          # Max duration ever (ms)
```

```bash
# View history for a specific event type
redis-cli -p 7000 LATENCY HISTORY fork

# Reset latency data after addressing an issue
redis-cli -p 7000 LATENCY RESET
```

### Common Latency Event Types

| Event | Cause |
|-------|-------|
| `fork` | RDB save or AOF rewrite triggered `fork()`. Large datasets = slow fork. |
| `active-defrag-cycle` | Active defragmentation consuming CPU. |
| `aof-fsync-always` | AOF configured with `appendfsync always` — fsync on every write. |
| `expire-cycle` | Expiring many keys at once (lazy + active expiration). |
| `eviction-cycle` | `maxmemory` reached, evicting keys. |
| `command` | A single slow command blocking the event loop. |

### Diagnosis — Network Latency Between Cluster Nodes

```bash
# Measure RTT between nodes using the cluster bus
# From node A, ping node B
redis-cli -p 7000 --latency -h <node-b-ip> -p 7001

# More thorough: measure from every node to every other node
for src in 7000 7001 7002; do
  for dst in 7000 7001 7002; do
    if [ "$src" != "$dst" ]; then
      echo -n "Port $src -> $dst: "
      redis-cli -p $src -h 127.0.0.1 --latency | head -1
    fi
  done
done
```

Cross-AZ or cross-region latency > 1ms can significantly impact cluster operations, especially during failover and slot migration.

### Resolution

**Fork latency (RDB/AOF):**

```bash
# Disable RDB persistence if not needed
redis-cli -p 7000 CONFIG SET save ""

# Use AOF with appendfsync everysec instead of always
redis-cli -p 7000 CONFIG SET appendfsync everysec

# Enable jemalloc background threads to reduce fork overhead
redis-cli -p 7000 CONFIG SET jemalloc-bg-thread yes
```

**Active defrag latency:**

```bash
# Reduce max CPU cycle to limit impact
redis-cli -p 7000 CONFIG SET active-defrag-cycle-max 10
```

**Key eviction latency:**

```bash
# Switch to a less expensive eviction policy
redis-cli -p 7000 CONFIG SET maxmemory-policy allkeys-lru

# Increase maxmemory to reduce eviction frequency
redis-cli -p 7000 CONFIG SET maxmemory 8gb
```

### Prevention

- Set `latency-monitor-threshold 50` in production (50ms).
- Alert on latency events via monitoring (Prometheus + Grafana or Datadog).
- Use `appendfsync everysec` instead of `always`.
- Schedule RDB saves during off-peak hours or disable on replicas.
- Keep datasets sized so that `fork()` completes in < 100ms.

---

## Network Partition Recovery

Network partitions are the most dangerous failure mode for Redis Cluster. Understanding the recovery process is essential for minimizing data loss and downtime.

### Cluster Behavior During Partition

When a partition occurs, the cluster splits into two or more groups:

**Majority side (quorum):**
- Detects minority nodes as `PFAIL` after `cluster-node-timeout / 2`.
- Promotes `PFAIL` to `FAIL` after majority agreement.
- If a master is on the minority side, a replica on the majority side is elected as new master.
- Continues serving all slots that have masters on the majority side.

**Minority side (no quorum):**
- Cannot promote `PFAIL` to `FAIL` (needs majority agreement).
- Masters on this side continue serving reads/writes for `cluster-node-timeout` milliseconds.
- After `cluster-node-timeout`, masters stop accepting writes (they detect they can't reach enough nodes).
- If `min-replicas-to-write` is set, writes stop even sooner.

### Timeline — PFAIL → FAIL → Recovery

```
T+0s          Partition occurs
T+7.5s        Nodes on both sides flag unreachable peers as PFAIL
              (cluster-node-timeout / 2 = 15000 / 2 = 7500ms)
T+15s         Majority side reaches consensus: PFAIL → FAIL
T+15s–T+25s   Replica election on majority side (if master was lost)
T+25s         New master begins serving slots
...
T+???         Partition heals
T+???+15s     Gossip converges, old master recognizes new master
T+???+30s     Old master becomes replica of new master, starts syncing
```

### Diagnosis During Partition

From the majority side:

```bash
redis-cli -p 7000 CLUSTER NODES | grep fail
# e5f6g7h8 127.0.0.1:7003@17003 master,fail - 1697012345 1697012330 3 connected 0-5460
```

From the minority side:

```bash
redis-cli -p 7003 CLUSTER INFO
# cluster_state:fail
# cluster_slots_ok:5461
# cluster_slots_pfail:10923
# cluster_slots_fail:0   (can't promote to FAIL without quorum)
```

### After Partition Heals

**Step 1: Verify gossip convergence.**

```bash
# All nodes should show the same topology
for port in 7000 7001 7002 7003 7004 7005; do
  echo "=== Port $port ==="
  redis-cli -p $port CLUSTER INFO | grep -E 'cluster_state|cluster_known_nodes|cluster_size'
done
```

All nodes should report `cluster_state:ok` and the same `cluster_known_nodes` count.

**Step 2: Verify slot coverage.**

```bash
redis-cli --cluster check 127.0.0.1:7000
```

All 16384 slots must be covered. If any are uncovered, run:

```bash
redis-cli --cluster fix 127.0.0.1:7000
```

**Step 3: Verify replication status.**

```bash
for port in 7000 7001 7002 7003 7004 7005; do
  echo "=== Port $port ==="
  redis-cli -p $port INFO replication | grep -E 'role|master_link_status|master_repl_offset'
done
```

All replicas should show `master_link_status:up`. If a replica shows `master_link_status:down`, check network connectivity and buffer limits.

**Step 4: Check for data loss.**

Writes that went to the old master on the minority side after the partition started — and before it stopped accepting writes — are **lost**. The old master discards its data when it syncs from the new master.

Estimate the data loss window:

```
Data loss window = min(cluster-node-timeout, time_until_partition_detected_by_client)
```

With default `cluster-node-timeout` of 15 seconds, up to 15 seconds of writes can be lost.

### Post-Partition Checklist

```
[ ] All nodes report cluster_state:ok
[ ] All 16384 slots are covered (redis-cli --cluster check)
[ ] All replicas have master_link_status:up
[ ] Replication offsets are converging (gap decreasing)
[ ] No nodes stuck in FAIL or PFAIL state
[ ] Application error rates have returned to baseline
[ ] No split-brain: each slot has exactly one master
[ ] Review slow log for partition-related latency events
[ ] Review application logs for data inconsistencies
[ ] Document the incident: timeline, root cause, data loss estimate
```

### Prevention

- Configure `min-replicas-to-write 1` to stop the minority side from accepting writes.
- Use `cluster-node-timeout 15000` (15 seconds) — low enough to detect failures quickly, high enough to avoid false positives.
- Deploy across availability zones with redundant network paths.
- Monitor inter-node latency and alert on packet loss.
- Maintain at least one replica per master so the majority side can always elect a new master.
- Test partition scenarios regularly using network fault injection tools (e.g., `tc netem`, Toxiproxy, Chaos Monkey).
