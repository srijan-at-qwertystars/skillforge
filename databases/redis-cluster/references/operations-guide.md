# Redis Cluster Operations Guide

Production runbook for Redis Cluster day-2 operations. Every command is concrete and copy-pasteable. Treat this as the single reference when performing maintenance, scaling, upgrades, or incident response on a Redis Cluster deployment.

---

## Table of Contents

- [Rolling Upgrades](#rolling-upgrades)
- [Capacity Planning](#capacity-planning)
- [Backup Strategies (RDB/AOF in Cluster)](#backup-strategies-rdbaof-in-cluster)
- [Adding Nodes](#adding-nodes)
- [Removing Nodes](#removing-nodes)
- [Rebalancing](#rebalancing)
- [Monitoring with redis-cli](#monitoring-with-redis-cli)
- [Prometheus/Grafana Dashboards](#prometheusgrafana-dashboards)
- [Alerting Thresholds](#alerting-thresholds)
- [Maintenance Windows](#maintenance-windows)

---

## Rolling Upgrades

### Pre-Upgrade Checklist

1. **Snapshot the current topology.** Save this output — you will need it for rollback.

```bash
redis-cli --cluster check <any-node-ip>:6379 > cluster-topology-$(date +%Y%m%d).txt
redis-cli -h <any-node-ip> -p 6379 CLUSTER NODES > cluster-nodes-$(date +%Y%m%d).txt
```

2. **Verify cluster health.** All slots must be covered, no nodes in `fail` or `pfail` state.

```bash
redis-cli -h <any-node-ip> -p 6379 CLUSTER INFO | grep -E 'cluster_state|cluster_slots'
# Expected: cluster_state:ok, cluster_slots_ok:16384, cluster_slots_fail:0
```

3. **Trigger an RDB backup on every node.**

```bash
for node in node1:6379 node2:6379 node3:6379 node4:6379 node5:6379 node6:6379; do
  host=${node%:*}; port=${node#*:}
  redis-cli -h "$host" -p "$port" BGSAVE
done
```

4. **Record current Redis versions across all nodes.**

```bash
for node in node1:6379 node2:6379 node3:6379; do
  host=${node%:*}; port=${node#*:}
  echo -n "$node: "; redis-cli -h "$host" -p "$port" INFO server | grep redis_version
done
```

### Step-by-Step Upgrade Procedure

The golden rule: **upgrade replicas first, then failover primaries and upgrade them**.

1. **Upgrade each replica one at a time.**

```bash
# On the replica host:
sudo systemctl stop redis
sudo yum install redis-7.2.4 -y   # or: sudo apt install redis-server=7:7.2.4-1
sudo systemctl start redis

# Verify the replica rejoined the cluster:
redis-cli -h <replica-ip> -p 6379 CLUSTER INFO | grep cluster_state
redis-cli -h <replica-ip> -p 6379 INFO server | grep redis_version
```

2. **Wait for replica to fully sync** before proceeding to the next one.

```bash
redis-cli -h <replica-ip> -p 6379 INFO replication | grep master_link_status
# Expected: master_link_status:up
```

3. **Failover each master to its upgraded replica, then upgrade the old master.**

```bash
# Trigger manual failover FROM the replica:
redis-cli -h <replica-ip> -p 6379 CLUSTER FAILOVER

# Confirm the replica is now the master:
redis-cli -h <replica-ip> -p 6379 CLUSTER NODES | grep myself
# Should show "master" in flags

# Now the old master is a replica — upgrade it:
sudo systemctl stop redis
sudo yum install redis-7.2.4 -y
sudo systemctl start redis
```

4. **Repeat step 3** for every master/replica pair.

5. **Final health check.**

```bash
redis-cli --cluster check <any-node-ip>:6379
```

### Version Compatibility During Rolling Upgrade

- Redis uses a binary-compatible cluster bus protocol across minor versions within the same major (e.g., 7.0.x ↔ 7.2.x).
- **Never mix major versions for more than the duration of a rolling upgrade.** Clusters running mixed Redis 6 + Redis 7 nodes long-term are unsupported.
- During the upgrade window, both versions can coexist because the cluster bus protocol version negotiates downward.

### Redis 6 → 7 Breaking Changes

| Area | Change | Action Required |
|------|--------|-----------------|
| ACLs | `AUTH` now requires username by default | Update client connection strings to include username |
| `COMMAND` output | Format changed | Update monitoring scripts that parse `COMMAND` output |
| Lua scripting | `redis.call()` error handling changed | Test all Lua scripts before upgrade |
| `CLUSTER FAILOVER` | `TAKEOVER` semantics tightened | Review any automation using `TAKEOVER` |
| `maxmemory-policy` | `allkeys-lfu` / `volatile-lfu` refined | Review eviction behavior if using LFU |
| Module API | Breaking ABI changes | Rebuild all modules against Redis 7 headers |

### Rollback Procedure

If a node fails after upgrade:

```bash
# Stop the failed node
sudo systemctl stop redis

# Downgrade the package
sudo yum downgrade redis-6.2.14 -y   # or apt equivalent

# Restore the pre-upgrade RDB if data is corrupted
cp /backup/dump-pre-upgrade.rdb /var/lib/redis/dump.rdb
sudo chown redis:redis /var/lib/redis/dump.rdb

# Start and rejoin
sudo systemctl start redis
redis-cli -h <node-ip> -p 6379 CLUSTER INFO
```

> **Warning:** If all masters were already upgraded and failover occurred, rolling back requires restoring the entire cluster from backup. This is why you upgrade one node at a time and verify at each step.

---

## Capacity Planning

### Memory Sizing Formula

```
Required memory per node =
  (working_set_size / num_masters)
  × 1.2          # fragmentation overhead
  × 2            # copy-on-write peak during BGSAVE fork
  + 256MB        # replication output buffer (default)
  + 128MB        # cluster bus buffers + overhead
```

**Example:** 60 GB working set, 3 masters:

```
(60 GB / 3) × 1.2 × 2 + 0.256 GB + 0.128 GB
= 20 × 1.2 × 2 + 0.384
= 48.384 GB per node
→ Provision 64 GB RAM nodes (leaves headroom)
```

Set `maxmemory` conservatively:

```bash
# Leave room for fragmentation + COW. Set maxmemory to ~60-70% of physical RAM.
redis-cli -h <node-ip> -p 6379 CONFIG SET maxmemory 40gb
redis-cli -h <node-ip> -p 6379 CONFIG REWRITE
```

### CPU Planning

- Redis command processing is **single-threaded**. A single fast core matters more than many cores.
- Redis 6+ supports **IO threads** for network read/write (not command execution):

```
# redis.conf — enable 4 IO threads for network
io-threads 4
io-threads-do-reads yes
```

- Rule of thumb: 1 dedicated core for the main thread + 1 core per IO thread + 1 core for BGSAVE forks.
- For a node with `io-threads 4`: provision at least 6 vCPUs.

### Network Bandwidth

Estimate per node:

| Component | Estimate |
|-----------|----------|
| Client traffic | Measure with `INFO stats` → `instantaneous_input_kbps` / `instantaneous_output_kbps` |
| Replication traffic | Roughly equals write throughput × number of replicas per master |
| Cluster gossip | ~1 KB/s per node in cluster (negligible in small clusters) |
| Full resync | Entire RDB transfer — can spike to hundreds of MB/s |

> **Warning:** Place replicas in the same availability zone as their masters when possible to reduce cross-AZ replication bandwidth costs.

### Slot Distribution for Uneven Workloads

If some hash slots are hotter than others, use weighted rebalance:

```bash
# Assign weight 2 to node <id1> (gets 2x the slots) and weight 1 to others:
redis-cli --cluster rebalance <any-node>:6379 \
  --cluster-weight <node-id1>=2 <node-id2>=1 <node-id3>=1
```

### Scale Out vs Scale Up

| Factor | Scale Out (add nodes) | Scale Up (bigger instances) |
|--------|----------------------|----------------------------|
| Memory limit hit | ✅ Distributes data | ✅ More RAM per node |
| CPU bottleneck | ✅ Distributes commands | ❌ Still single-threaded |
| Network bottleneck | ✅ More NICs | ❌ Same NIC |
| Operational complexity | Higher | Lower |
| Cost at scale | Usually cheaper | Gets expensive fast |

**Recommendation:** Scale up until you hit single-thread CPU limits or ~64 GB `maxmemory`, then scale out.

---

## Backup Strategies (RDB/AOF in Cluster)

### Key Principle

Each node in a Redis Cluster is an independent Redis instance for backup purposes. There is no cluster-level backup command. You must back up every node individually.

### RDB Snapshots

```bash
# Trigger RDB save (non-blocking):
redis-cli -h <node-ip> -p 6379 BGSAVE

# Monitor save progress:
redis-cli -h <node-ip> -p 6379 LASTSAVE
redis-cli -h <node-ip> -p 6379 INFO persistence | grep rdb_
```

**Pros:** Compact, fast to restore, minimal performance impact.
**Cons:** Point-in-time only — data between snapshots is lost.

Schedule via `redis.conf`:

```
# Save if at least 1 key changed in 3600 seconds
save 3600 1
# Save if at least 100 keys changed in 300 seconds
save 300 100
# Save if at least 10000 keys changed in 60 seconds
save 60 10000
```

### AOF Persistence

```
# redis.conf
appendonly yes
appendfsync everysec         # good balance of safety and performance
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
```

**Pros:** Near-zero data loss (at most 1 second with `everysec`).
**Cons:** Larger files, slower restart, AOF rewrite can cause latency spikes.

### Backup from Replicas

> **Best practice:** Always run backups from replicas. BGSAVE triggers a `fork()` which doubles memory usage momentarily (copy-on-write). On masters, this competes with client request memory.

```bash
# On each replica:
redis-cli -h <replica-ip> -p 6379 BGSAVE
# Then copy the RDB:
scp <replica-ip>:/var/lib/redis/dump.rdb /backup/node-<id>-$(date +%Y%m%d%H%M).rdb
```

### Point-in-Time Recovery

Combine RDB + AOF for point-in-time recovery:

1. Restore the latest RDB snapshot.
2. Replay AOF from the snapshot timestamp forward.
3. Redis does this automatically on startup if both files are present and `appendonly yes` is set.

### Disaster Recovery: Full Cluster Restore

1. Provision new nodes with the same `cluster-config-file` names.
2. Copy each node's RDB to the corresponding new node.
3. Copy each node's `nodes.conf` to preserve slot assignments and node IDs.
4. Start all nodes. They will re-form the cluster using `nodes.conf`.

```bash
# For each node:
cp /backup/node-<id>/dump.rdb /var/lib/redis/dump.rdb
cp /backup/node-<id>/nodes.conf /var/lib/redis/nodes.conf
chown redis:redis /var/lib/redis/{dump.rdb,nodes.conf}
systemctl start redis
```

> **Warning:** All nodes must be restored together. You cannot restore a single master's backup into a running cluster — the slot ownership and node IDs will conflict.

### Automated Backup Script

```bash
#!/usr/bin/env bash
# redis-cluster-backup.sh — Run via cron: 0 */6 * * * /opt/scripts/redis-cluster-backup.sh
set -euo pipefail

BACKUP_DIR="/backup/redis/$(date +%Y%m%d_%H%M%S)"
NODES="replica1:6379 replica2:6379 replica3:6379"
RETENTION_DAYS=7

mkdir -p "$BACKUP_DIR"

for node in $NODES; do
  host="${node%:*}"
  port="${node#*:}"
  echo "[$(date)] Backing up $node ..."
  redis-cli -h "$host" -p "$port" BGSAVE
  sleep 5  # wait for BGSAVE to complete on small datasets
  # Poll until save finishes
  while [ "$(redis-cli -h "$host" -p "$port" INFO persistence | grep rdb_bgsave_in_progress | tr -d '\r' | cut -d: -f2)" = "1" ]; do
    sleep 2
  done
  scp "${host}:/var/lib/redis/dump.rdb" "${BACKUP_DIR}/${host}-dump.rdb"
  scp "${host}:/var/lib/redis/nodes.conf" "${BACKUP_DIR}/${host}-nodes.conf"
  echo "[$(date)] Backup of $node complete."
done

# Cleanup old backups
find /backup/redis -maxdepth 1 -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} +

echo "[$(date)] All backups complete. Stored in $BACKUP_DIR"
```

---

## Adding Nodes

### Adding a New Master

```bash
# Syntax: redis-cli --cluster add-node <new-node>:<port> <existing-node>:<port>
redis-cli --cluster add-node 10.0.1.10:6379 10.0.1.1:6379
```

After adding, the new master has **zero slots**. You must rebalance.

### Adding a New Replica

```bash
# First, get the master's node ID:
redis-cli -h 10.0.1.1 -p 6379 CLUSTER NODES | grep master

# Add replica targeting a specific master:
redis-cli --cluster add-node 10.0.1.11:6379 10.0.1.1:6379 \
  --cluster-slave \
  --cluster-master-id <master-node-id>
```

### Post-Add: Rebalance Slots

```bash
# Distribute slots evenly across all masters including the new one:
redis-cli --cluster rebalance 10.0.1.1:6379 --cluster-use-empty-masters
```

### Verification After Adding

```bash
# 1. Confirm the node appears in cluster topology:
redis-cli -h 10.0.1.1 -p 6379 CLUSTER NODES | grep 10.0.1.10

# 2. Confirm slot assignment (for masters):
redis-cli --cluster check 10.0.1.1:6379

# 3. Confirm replication status (for replicas):
redis-cli -h 10.0.1.11 -p 6379 INFO replication | grep master_link_status
# Expected: master_link_status:up
```

### Common Mistakes

| Mistake | Consequence | Prevention |
|---------|-------------|------------|
| Forgetting to rebalance after adding a master | New node sits idle with 0 slots, wasting resources | Always run `--cluster rebalance` immediately after adding |
| Wrong `--cluster-master-id` | Replica attaches to wrong master, skewing HA | Double-check ID with `CLUSTER NODES` before adding |
| Adding node with `cluster-enabled no` | Node refuses to join | Verify `cluster-enabled yes` in redis.conf before adding |
| Mismatched `cluster-config-file` path | Two nodes sharing a path corrupt each other | Use unique filenames per instance: `nodes-6379.conf` |

---

## Removing Nodes

### Removing a Replica

Replicas hold no slots, so removal is straightforward:

```bash
# Get the replica's node ID:
redis-cli -h 10.0.1.1 -p 6379 CLUSTER NODES | grep 10.0.1.11

# Remove it:
redis-cli --cluster del-node 10.0.1.1:6379 <replica-node-id>
```

### Removing a Master

> **Warning:** Never delete a master that still owns slots. You will lose data.

1. **Reshard all slots away from the master being removed.**

```bash
# Move all slots from the target master to another master:
redis-cli --cluster reshard 10.0.1.1:6379 \
  --cluster-from <node-id-to-remove> \
  --cluster-to <destination-node-id> \
  --cluster-slots 16384 \
  --cluster-yes
```

2. **Verify the node has zero slots.**

```bash
redis-cli -h 10.0.1.1 -p 6379 CLUSTER NODES | grep <node-id-to-remove>
# Slot range should be empty
```

3. **Delete the empty master.**

```bash
redis-cli --cluster del-node 10.0.1.1:6379 <node-id-to-remove>
```

### Handling Removal During Active Traffic

- Resharding is online — clients continue operating.
- Keys being migrated will temporarily return `ASK` redirections. All standard Redis clients handle this.
- Use `--cluster-pipeline 10` during reshard to batch key migrations and reduce overhead:

```bash
redis-cli --cluster reshard 10.0.1.1:6379 \
  --cluster-from <node-id-to-remove> \
  --cluster-to <destination-node-id> \
  --cluster-slots 16384 \
  --cluster-pipeline 10 \
  --cluster-yes
```

### Graceful vs Forced Removal

| Method | When to Use |
|--------|-------------|
| Graceful (reshard → del-node) | Normal operations. Zero data loss. |
| Forced (`CLUSTER FORGET` on all nodes) | Node is dead and won't come back. Run `CLUSTER FORGET <dead-node-id>` on every remaining node within 60 seconds (before gossip re-adds it). |

```bash
# Forced removal of a dead node:
DEAD_ID="<dead-node-id>"
for node in node1:6379 node2:6379 node3:6379 node4:6379 node5:6379; do
  host=${node%:*}; port=${node#*:}
  redis-cli -h "$host" -p "$port" CLUSTER FORGET "$DEAD_ID"
done
```

> **Warning:** `CLUSTER FORGET` must be sent to every node in the cluster within 60 seconds. After 60 seconds, gossip protocol re-introduces forgotten nodes.

---

## Rebalancing

### How `redis-cli --cluster rebalance` Works

The rebalance command calculates the ideal number of slots per master (16384 / num_masters) and generates a migration plan to move slots from over-allocated nodes to under-allocated nodes.

```bash
redis-cli --cluster rebalance 10.0.1.1:6379
```

### Key Options

| Flag | Purpose | Example |
|------|---------|---------|
| `--cluster-weight <id>=<weight>` | Assign relative weight to nodes | `--cluster-weight abc123=2 def456=1` |
| `--cluster-use-empty-masters` | Include masters with 0 slots in distribution | Always use when adding new masters |
| `--cluster-threshold <N>` | Only rebalance if imbalance exceeds N% | `--cluster-threshold 2` (default: 2%) |
| `--cluster-pipeline <N>` | Number of keys to migrate in each batch | `--cluster-pipeline 10` |
| `--cluster-simulate` | Dry run — show plan without executing | Use this first to review the plan |

### Example: Weighted Rebalance

```bash
# Give node abc123 twice the slots (handles more traffic):
redis-cli --cluster rebalance 10.0.1.1:6379 \
  --cluster-weight abc123=2 def456=1 ghi789=1 \
  --cluster-use-empty-masters
```

### Monitoring Rebalance Progress

```bash
# In another terminal, watch slot migration:
watch -n 2 'redis-cli -h 10.0.1.1 -p 6379 CLUSTER NODES | awk "{print \$1, \$3, \$NF}"'
```

### Safe Rebalancing During Production Traffic

- Rebalancing is online. Clients experience `ASK` redirections for migrating keys (handled transparently by clients).
- Use `--cluster-pipeline 10` (not higher) to limit migration batch size and avoid latency spikes.
- Monitor latency during rebalance:

```bash
redis-cli -h 10.0.1.1 -p 6379 --latency-history -i 5
```

- If latency spikes above your SLO, stop rebalance with `Ctrl+C`. Partial rebalance is safe — the cluster remains consistent.

---

## Monitoring with redis-cli

### CLUSTER INFO

```bash
redis-cli -h <node-ip> -p 6379 CLUSTER INFO
```

Key fields:

| Field | Healthy Value | Meaning |
|-------|---------------|---------|
| `cluster_state` | `ok` | All slots covered |
| `cluster_slots_ok` | `16384` | Number of slots assigned |
| `cluster_slots_pfail` | `0` | Slots on possibly-failed nodes |
| `cluster_slots_fail` | `0` | Slots on confirmed-failed nodes |
| `cluster_known_nodes` | Expected count | Total nodes in gossip |
| `cluster_size` | Expected masters | Number of masters serving slots |

### CLUSTER NODES

```bash
redis-cli -h <node-ip> -p 6379 CLUSTER NODES
```

Output format (space-delimited):
```
<node-id> <ip:port@bus-port> <flags> <master-id|--> <ping-sent> <pong-recv> <config-epoch> <link-state> <slot-ranges>
```

Parse useful summaries:

```bash
# List all masters and their slot counts:
redis-cli -h <node-ip> -p 6379 CLUSTER NODES | grep master | \
  awk '{slots=0; for(i=9;i<=NF;i++){split($i,a,"-"); slots+=a[2]-a[1]+1} print $2, slots, "slots"}'

# Find any nodes not in "connected" state:
redis-cli -h <node-ip> -p 6379 CLUSTER NODES | grep -v connected
```

### Cluster Check

```bash
redis-cli --cluster check <any-node-ip>:6379
```

Validates:
- All 16384 slots are assigned.
- No slots are in migrating/importing state.
- All nodes are reachable.
- Replica configuration is correct.

### INFO Sections

```bash
# Memory usage:
redis-cli -h <node-ip> -p 6379 INFO memory | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'

# Command throughput:
redis-cli -h <node-ip> -p 6379 INFO stats | grep -E 'instantaneous_ops|total_commands|rejected_connections'

# Replication health:
redis-cli -h <node-ip> -p 6379 INFO replication | grep -E 'role|master_link_status|master_last_io|slave_repl_offset'

# Connected clients:
redis-cli -h <node-ip> -p 6379 INFO clients | grep -E 'connected_clients|blocked_clients|maxclients'

# Key distribution:
redis-cli -h <node-ip> -p 6379 INFO keyspace
```

### CLIENT LIST

```bash
# Connection analysis — find top consumers:
redis-cli -h <node-ip> -p 6379 CLIENT LIST | awk -F' ' '{for(i=1;i<=NF;i++) if($i ~ /^cmd=/) print $i}' | sort | uniq -c | sort -rn | head -20
```

### DBSIZE Per Node

```bash
# Check key distribution across all masters:
for node in master1:6379 master2:6379 master3:6379; do
  host=${node%:*}; port=${node#*:}
  echo -n "$node: "; redis-cli -h "$host" -p "$port" DBSIZE
done
```

### MEMORY DOCTOR

```bash
redis-cli -h <node-ip> -p 6379 MEMORY DOCTOR
# Returns a human-readable diagnosis of memory issues, e.g.:
# "Sam, I have a few reports for you. High fragmentation detected..."
```

---

## Prometheus/Grafana Dashboards

### Redis Exporter Setup

Use [oliver006/redis_exporter](https://github.com/oliver006/redis_exporter):

```bash
# Run one exporter per Redis node, or use multi-target mode:
docker run -d --name redis-exporter \
  -p 9121:9121 \
  -e REDIS_ADDR=redis://10.0.1.1:6379 \
  oliver006/redis_exporter:latest

# For cluster mode with multiple nodes, use file-based discovery:
cat > /etc/redis_exporter/targets.json <<'EOF'
[
  {"Addrs": ["10.0.1.1:6379"], "Labels": {"node": "redis-1"}},
  {"Addrs": ["10.0.1.2:6379"], "Labels": {"node": "redis-2"}},
  {"Addrs": ["10.0.1.3:6379"], "Labels": {"node": "redis-3"}}
]
EOF
```

### Key Prometheus Metrics

| Metric | Description | Alert On |
|--------|-------------|----------|
| `redis_cluster_state` | 1 = ok, 0 = fail | `== 0` |
| `redis_cluster_slots_ok` | Slots in ok state | `< 16384` |
| `redis_cluster_slots_fail` | Slots in fail state | `> 0` |
| `redis_memory_used_bytes` | Current memory usage | Near maxmemory |
| `redis_memory_max_bytes` | maxmemory config | - |
| `redis_connected_clients` | Current client connections | Near maxclients |
| `redis_blocked_clients` | Clients blocked on BLPOP etc. | Sustained > 0 |
| `redis_commands_processed_total` | Total command counter | Rate drop = possible issue |
| `redis_instantaneous_ops_per_sec` | Current ops/sec | Baseline deviation |
| `redis_replication_offset` | Replication byte offset | Lag between master/replica |
| `redis_connected_slaves` | Replicas connected | `< expected` |
| `redis_latest_fork_usec` | Last fork() duration | `> 500000` (500ms) |
| `redis_rdb_last_bgsave_status` | Last BGSAVE result | `!= 1` |

### Prometheus Scrape Config

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'redis-cluster'
    scrape_interval: 15s
    static_configs:
      - targets:
          - '10.0.1.1:9121'
          - '10.0.1.2:9121'
          - '10.0.1.3:9121'
          - '10.0.1.4:9121'
          - '10.0.1.5:9121'
          - '10.0.1.6:9121'
        labels:
          cluster: 'production-redis'
    # If using redis_exporter multi-target mode:
    # relabel_configs:
    #   - source_labels: [__address__]
    #     target_label: __param_target
    #   - target_label: __address__
    #     replacement: redis-exporter:9121
```

### Grafana Dashboard

Import the community dashboard for `oliver006/redis_exporter`:

- **Dashboard ID:** `763` (Redis Dashboard for Prometheus Redis Exporter)
- Import via Grafana UI: Dashboards → Import → Enter `763` → Select Prometheus data source

For a cluster-specific dashboard, add these panels:

```json
{
  "panels": [
    {
      "title": "Cluster State",
      "targets": [{"expr": "redis_cluster_state", "legendFormat": "{{instance}}"}],
      "type": "stat",
      "thresholds": {"steps": [{"color": "red", "value": 0}, {"color": "green", "value": 1}]}
    },
    {
      "title": "Memory Usage %",
      "targets": [{"expr": "redis_memory_used_bytes / redis_memory_max_bytes * 100", "legendFormat": "{{instance}}"}],
      "type": "gauge",
      "thresholds": {"steps": [{"color": "green", "value": 0}, {"color": "yellow", "value": 75}, {"color": "red", "value": 90}]}
    },
    {
      "title": "Ops/sec by Node",
      "targets": [{"expr": "redis_instantaneous_ops_per_sec", "legendFormat": "{{instance}}"}],
      "type": "timeseries"
    },
    {
      "title": "Replication Lag (bytes)",
      "targets": [{"expr": "redis_replication_offset{role='master'} - on(instance) group_right redis_replication_offset{role='slave'}", "legendFormat": "{{instance}}"}],
      "type": "timeseries"
    }
  ]
}
```

---

## Alerting Thresholds

### Critical Alerts (Page Immediately)

These indicate data loss risk or service outage:

| Condition | Metric / Check | Impact |
|-----------|----------------|--------|
| Cluster broken | `redis_cluster_state == 0` | Clients receiving CLUSTERDOWN errors |
| Slots failing | `redis_cluster_slots_fail > 0` | Subset of keyspace unreachable |
| Replication broken | `redis_master_link_status{status="down"}` | No failover available — single point of failure |
| Memory critical | `redis_memory_used_bytes / redis_memory_max_bytes > 0.90` | Eviction or OOM imminent |

### Warning Alerts (Investigate Within Hours)

| Condition | Metric / Check | Impact |
|-----------|----------------|--------|
| Memory high | `used / max > 0.75` | Approaching eviction threshold |
| Clients high | `connected_clients / maxclients > 0.70` | Connection exhaustion risk |
| Replication lag | `master_offset - replica_offset > 10MB` or `lag > 10s` | Stale reads from replicas |
| High fragmentation | `redis_mem_fragmentation_ratio > 1.5` | Wasted memory; may need restart |
| Rejected connections | `redis_rejected_connections_total` increasing | maxclients reached |

### Prometheus Alerting Rules

```yaml
# redis-alerts.yml
groups:
  - name: redis-cluster-critical
    rules:
      - alert: RedisClusterDown
        expr: redis_cluster_state == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "Redis Cluster is down on {{ $labels.instance }}"
          description: "cluster_state is not ok. Clients are receiving CLUSTERDOWN errors."
          runbook: "Check CLUSTER INFO on all nodes. Look for failed nodes with CLUSTER NODES."

      - alert: RedisClusterSlotsFailing
        expr: redis_cluster_slots_fail > 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "{{ $value }} slots in fail state on {{ $labels.instance }}"
          description: "Hash slots are unreachable. A master is down with no replica to failover."

      - alert: RedisReplicationBroken
        expr: redis_master_link_status{status="down"} == 1
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Replication link down on {{ $labels.instance }}"
          description: "Replica cannot reach its master. No automatic failover protection."

      - alert: RedisMemoryCritical
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Redis memory above 90% on {{ $labels.instance }}"
          description: "Current usage: {{ $value | humanizePercentage }}. Eviction or OOM risk."

  - name: redis-cluster-warning
    rules:
      - alert: RedisMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.75
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Redis memory above 75% on {{ $labels.instance }}"

      - alert: RedisClientsHigh
        expr: redis_connected_clients / redis_config_maxclients > 0.70
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Redis client connections above 70% of maxclients on {{ $labels.instance }}"

      - alert: RedisHighFragmentation
        expr: redis_mem_fragmentation_ratio > 1.5
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Redis memory fragmentation ratio {{ $value }} on {{ $labels.instance }}"
          description: "Consider restarting the node during a maintenance window."

      - alert: RedisRejectedConnections
        expr: increase(redis_rejected_connections_total[5m]) > 0
        labels:
          severity: warning
        annotations:
          summary: "Redis rejecting connections on {{ $labels.instance }}"
          description: "maxclients limit reached. Increase maxclients or investigate connection leaks."

      - alert: RedisReplicationLag
        expr: redis_replication_delay > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis replication lag > 10 seconds on {{ $labels.instance }}"
```

### PagerDuty / Slack Integration

In Alertmanager config:

```yaml
# alertmanager.yml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'cluster']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'slack-warnings'
  routes:
    - match:
        severity: critical
      receiver: 'pagerduty-critical'

receivers:
  - name: 'pagerduty-critical'
    pagerduty_configs:
      - service_key: '<your-pagerduty-integration-key>'
        description: '{{ .CommonAnnotations.summary }}'

  - name: 'slack-warnings'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/T00/B00/XXXXX'
        channel: '#redis-alerts'
        title: '{{ .CommonAnnotations.summary }}'
        text: '{{ .CommonAnnotations.description }}'
        send_resolved: true
```

---

## Maintenance Windows

### Scheduling

- **Identify low-traffic periods** by reviewing `redis_instantaneous_ops_per_sec` over 7+ days in Grafana.
- Typical windows: weekends 02:00–06:00 local time, or region-specific troughs.
- Avoid scheduling during batch job windows or end-of-month processing.

### Pre-Maintenance Health Snapshot

Run this script before every maintenance window:

```bash
#!/usr/bin/env bash
# pre-maintenance-snapshot.sh
NODES="node1:6379 node2:6379 node3:6379 node4:6379 node5:6379 node6:6379"
OUTDIR="/tmp/redis-maint-$(date +%Y%m%d%H%M)"
mkdir -p "$OUTDIR"

for node in $NODES; do
  host="${node%:*}"; port="${node#*:}"
  redis-cli -h "$host" -p "$port" CLUSTER INFO   > "$OUTDIR/${host}-cluster-info.txt"
  redis-cli -h "$host" -p "$port" CLUSTER NODES  > "$OUTDIR/${host}-cluster-nodes.txt"
  redis-cli -h "$host" -p "$port" INFO ALL        > "$OUTDIR/${host}-info-all.txt"
  redis-cli -h "$host" -p "$port" DBSIZE         >> "$OUTDIR/dbsize-summary.txt"
  redis-cli -h "$host" -p "$port" CONFIG GET maxmemory >> "$OUTDIR/maxmemory-summary.txt"
done

echo "Snapshot saved to $OUTDIR"
```

### Communication Template

```
Subject: [Scheduled Maintenance] Redis Cluster — <DATE> <TIME> UTC

Team,

We will perform maintenance on the production Redis Cluster during the following window:

  Start: YYYY-MM-DD HH:MM UTC
  End:   YYYY-MM-DD HH:MM UTC (estimated)
  Impact: Minimal — rolling operation, no full outage expected.

Work planned:
  - <describe: upgrade / scaling / rebalance / patching>

Expected client impact:
  - Brief increase in redirections (ASK/MOVED) during slot migration.
  - Possible sub-second latency spikes during failovers.
  - No data loss expected.

Rollback plan:
  - <describe rollback steps>

Contact: <on-call engineer> via <Slack channel / phone>
```

### Post-Maintenance Validation Checklist

Run through every item before closing the maintenance window:

```bash
# 1. Cluster state is OK
redis-cli -h <any-node> -p 6379 CLUSTER INFO | grep cluster_state
# ✅ cluster_state:ok

# 2. All 16384 slots assigned
redis-cli --cluster check <any-node>:6379
# ✅ [OK] All 16384 slots covered

# 3. All nodes connected
redis-cli -h <any-node> -p 6379 CLUSTER NODES | grep -c connected
# ✅ Matches expected node count

# 4. No nodes in fail/pfail state
redis-cli -h <any-node> -p 6379 CLUSTER NODES | grep -E 'fail|pfail'
# ✅ No output

# 5. Replication healthy on all replicas
for replica in replica1:6379 replica2:6379 replica3:6379; do
  host=${replica%:*}; port=${replica#*:}
  echo -n "$replica: "
  redis-cli -h "$host" -p "$port" INFO replication | grep master_link_status
done
# ✅ All show master_link_status:up

# 6. Memory usage within bounds
for node in node1:6379 node2:6379 node3:6379; do
  host=${node%:*}; port=${node#*:}
  echo -n "$node: "
  redis-cli -h "$host" -p "$port" INFO memory | grep used_memory_human
done

# 7. Client connections restored
for node in node1:6379 node2:6379 node3:6379; do
  host=${node%:*}; port=${node#*:}
  echo -n "$node: "
  redis-cli -h "$host" -p "$port" INFO clients | grep connected_clients
done

# 8. Ops/sec back to baseline
for node in node1:6379 node2:6379 node3:6379; do
  host=${node%:*}; port=${node#*:}
  echo -n "$node: "
  redis-cli -h "$host" -p "$port" INFO stats | grep instantaneous_ops_per_sec
done
# ✅ Values match pre-maintenance baseline

# 9. Compare topology to pre-maintenance snapshot
diff <(sort /tmp/redis-maint-*/node1-cluster-nodes.txt) \
     <(redis-cli -h node1 -p 6379 CLUSTER NODES | sort)
```

> **Final step:** Post an all-clear message in the communication channel and close the maintenance ticket.
