---
name: redis-cluster
description: >
  Use when working with Redis Cluster, Redis Sentinel, Redis replication,
  Redis high availability, Redis scaling, Redis failover, Redis partitioning,
  Redis hash slots, Redis resharding, Redis cluster configuration, Redis
  cluster client setup, MOVED/ASK redirections, cross-slot errors, Redis
  gossip protocol, or Redis cluster monitoring and diagnostics.
  Do NOT use for single Redis instance basics, Redis data structures tutorial,
  Memcached, DynamoDB, general caching patterns, Redis Streams tutorial,
  Redis pub/sub basics, or standalone Redis CLI usage.
---

# Redis Cluster

## Architecture

Redis Cluster partitions the keyspace into **16,384 hash slots** across multiple master nodes. Each master owns a subset of slots and may have one or more replicas.

### Hash Slot Assignment

Slot for a key: `HASH_SLOT = CRC16(key) mod 16384`. Every node knows the full slot-to-node mapping. Clients cache this mapping and route commands directly.

### Gossip Protocol

Nodes communicate over a **cluster bus** on port `client_port + 10000` (e.g., 16379). Every node sends periodic PING/PONG messages carrying:
- Node IDs, addresses, flags, epoch
- Slot ownership bitmap
- Failure suspicions (PFAIL → FAIL promotion by quorum)

A node is marked FAIL when a majority of masters agree it is unreachable within `cluster-node-timeout`.

### Minimum Topology

- **3 masters** minimum for quorum-based failover.
- **1 replica per master** minimum for HA. Prefer 2 replicas for critical workloads.
- Distribute masters and replicas across distinct failure domains (racks, AZs).

---

## Sentinel vs Cluster Mode

| Aspect | Sentinel | Cluster |
|---|---|---|
| Sharding | None — single dataset | Hash-slot partitioning across N masters |
| Scaling | Vertical only (read replicas) | Horizontal — add/remove shards live |
| Failover | External Sentinel process promotes replica | Built-in — replica auto-promoted per slot group |
| Multi-key ops | Unrestricted | Same-slot only (use hash tags) |
| Client requirement | Standard client | Cluster-aware client required |
| Use when | Dataset fits one node, <100 GB | Dataset exceeds one node, high throughput needed |

**Rule:** Never combine Sentinel and Cluster in the same topology.

---

## Setup and Configuration

### Node Configuration (redis.conf)

```conf
port 7000
cluster-enabled yes
cluster-config-file nodes-7000.conf
cluster-node-timeout 5000
appendonly yes
# Require all slots covered to serve traffic (default yes):
cluster-require-full-coverage yes
# Allow replicas to serve stale reads during failover:
replica-serve-stale-data yes
# Cluster bus port (auto = port + 10000):
# cluster-port 17000
```

Repeat for each node, changing port. Open both client port AND bus port between all nodes.

### Create Cluster

```bash
# 6 nodes: 3 masters + 3 replicas (--cluster-replicas 1)
redis-cli --cluster create \
  192.168.1.1:7000 192.168.1.2:7000 192.168.1.3:7000 \
  192.168.1.4:7000 192.168.1.5:7000 192.168.1.6:7000 \
  --cluster-replicas 1
```

Output:
```
>>> Performing hash slots allocation on 6 nodes...
Master[0] -> Slots 0 - 5460
Master[1] -> Slots 5461 - 10922
Master[2] -> Slots 10923 - 16383
...
[OK] All 16384 slots covered.
```

### Verify

```bash
redis-cli -c -p 7000 CLUSTER INFO
# cluster_state:ok
# cluster_slots_assigned:16384
# cluster_slots_ok:16384
# cluster_known_nodes:6
# cluster_size:3

redis-cli -c -p 7000 CLUSTER NODES
# <id> 192.168.1.1:7000@17000 myself,master - 0 0 1 connected 0-5460
# <id> 192.168.1.4:7000@17000 slave <master-id> 0 0 1 connected
# ...
```

---

## Replication and Failover

### How Failover Works

1. Replica detects master PFAIL (no PONG within `cluster-node-timeout`).
2. Replica requests votes from other masters via `FAILOVER_AUTH_REQUEST`.
3. Majority of masters grant vote → replica wins election.
4. Winning replica executes `CLUSTER FAILOVER` internally, takes over master's slots.
5. New topology propagated via gossip within seconds.

### Manual Failover

```bash
# Connect to the REPLICA you want to promote:
redis-cli -p 7001 CLUSTER FAILOVER
# OK
# The replica becomes master; old master becomes replica.
```

Options: `CLUSTER FAILOVER FORCE` (skip data sync) or `CLUSTER FAILOVER TAKEOVER` (skip vote, emergency only).

### Replica Migration

Set `cluster-migration-barrier 1` (default). If a master loses all replicas, an orphan replica from a master with excess replicas migrates automatically.

---

## Hash Tags for Multi-Key Operations

Enclose the shared portion in `{}` braces. Only the substring inside the first `{...}` is hashed.

```bash
# These keys all hash to the same slot (hashing "user:1000"):
SET {user:1000}:name "Alice"
SET {user:1000}:email "alice@example.com"
SET {user:1000}:prefs '{"theme":"dark"}'

# Multi-key operation succeeds because same slot:
MGET {user:1000}:name {user:1000}:email
# 1) "Alice"
# 2) "alice@example.com"

# WITHOUT hash tags — FAILS:
MGET user:1000:name user:1000:email
# (error) CROSSSLOT Keys in request don't hash to the same slot
```

### Hash Tag Rules

- First `{` to first `}` is extracted. Empty `{}` → full key is hashed.
- Use consistent tag patterns: `{entity:id}:field`.
- **Beware hotspots**: if all keys share one tag, one node handles all traffic. Distribute tags across entities.

### Lua Scripts and Transactions

All keys in `EVAL`/`EVALSHA` and `MULTI`/`EXEC` **must** hash to the same slot. Pass related keys via hash tags.

```bash
# Lua script — all keys must share a slot:
EVAL "return redis.call('GET', KEYS[1]) .. redis.call('GET', KEYS[2])" \
  2 {user:1}:name {user:1}:email
# "Alicealice@example.com"
```

---

## Resharding and Scaling

### Add a New Node

```bash
# Add as empty master:
redis-cli --cluster add-node 192.168.1.7:7000 192.168.1.1:7000

# Add as replica of a specific master:
redis-cli --cluster add-node 192.168.1.8:7000 192.168.1.1:7000 \
  --cluster-slave --cluster-master-id <master-node-id>
```

### Reshard Slots

```bash
# Move 1000 slots from source to new node:
redis-cli --cluster reshard 192.168.1.1:7000 \
  --cluster-from <source-node-id> \
  --cluster-to <target-node-id> \
  --cluster-slots 1000 \
  --cluster-yes

# Or rebalance automatically across all masters:
redis-cli --cluster rebalance 192.168.1.1:7000 --cluster-use-empty-masters
```

During resharding, clients may receive **ASK** redirections for migrating slots. Cluster-aware clients handle this transparently.

### Remove a Node

1. Reshard all slots away from the node first.
2. Then: `redis-cli --cluster del-node 192.168.1.1:7000 <node-id>`

### Fix Broken State

```bash
redis-cli --cluster fix 192.168.1.1:7000
# Repairs open slots, stuck migrations, uncovered slots.
```

---

## Client-Side Configuration

### MOVED Redirection

Permanent redirect — the slot lives on a different node. Client must update its slot map and retry.

```
> GET mykey
(error) MOVED 3999 192.168.1.2:7000
# Client updates: slot 3999 → 192.168.1.2:7000, retries GET mykey there.
```

### ASK Redirection

Temporary redirect during slot migration. Client sends `ASKING` then retries the command on the target node. Do NOT update the slot map.

```
> GET mykey
(error) ASK 3999 192.168.1.3:7000
# Client: connect to 192.168.1.3:7000, send ASKING, then GET mykey.
```

### Client Library Configuration

**Python (redis-py):**
```python
from redis.cluster import RedisCluster

rc = RedisCluster(
    startup_nodes=[{"host": "192.168.1.1", "port": 7000}],
    decode_responses=True,
    skip_full_coverage_check=False,
    retry_on_timeout=True,
)
rc.set("{user:1}:name", "Alice")
print(rc.get("{user:1}:name"))  # "Alice"
```

**Node.js (ioredis):**
```javascript
const Redis = require("ioredis");
const cluster = new Redis.Cluster([
  { host: "192.168.1.1", port: 7000 },
  { host: "192.168.1.2", port: 7000 },
], {
  redisOptions: { password: "secret" },
  scaleReads: "slave",          // read from replicas
  natMap: {},                    // for NAT/Docker port mapping
  retryDelayOnFailover: 300,
  retryDelayOnClusterDown: 1000,
});
```

**Java (Jedis):**
```java
Set<HostAndPort> nodes = new HashSet<>();
nodes.add(new HostAndPort("192.168.1.1", 7000));
nodes.add(new HostAndPort("192.168.1.2", 7000));
JedisCluster jc = new JedisCluster(nodes, 5000, 5000, 3, "password",
    new GenericObjectPoolConfig<>());
jc.set("{user:1}:name", "Alice");
```

### Topology Refresh

Most clients cache the slot map. Force periodic refresh to handle topology changes:
- **ioredis**: `clusterRetryStrategy`, auto-refresh on MOVED
- **Lettuce**: `topologyRefreshOptions.enablePeriodicRefresh(Duration.ofSeconds(30))`
- **redis-py**: automatic on MOVED/ASK

---

## Persistence in Cluster Mode

Each node persists independently. Configure per-node:

### RDB Snapshots

```conf
save 900 1       # snapshot if ≥1 write in 900s
save 300 10      # snapshot if ≥10 writes in 300s
save 60 10000    # snapshot if ≥10000 writes in 60s
dbfilename dump-7000.rdb
dir /var/lib/redis/7000/
```

### AOF (Append Only File)

```conf
appendonly yes
appendfilename "appendonly-7000.aof"
appendfsync everysec          # balance durability/performance
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-use-rdb-preamble yes      # hybrid AOF for faster restart
```

**Recommendation:** Use AOF with `aof-use-rdb-preamble yes` for production clusters. RDB alone risks data loss between snapshots.

---

## Monitoring and Diagnostics

### Essential Commands

```bash
# Cluster health:
redis-cli -c -p 7000 CLUSTER INFO

# Node topology:
redis-cli -c -p 7000 CLUSTER NODES

# Slot distribution:
redis-cli --cluster check 192.168.1.1:7000

# Per-node memory:
redis-cli -p 7000 INFO memory
# used_memory_human:1.2G
# maxmemory_human:4G

# Slow queries:
redis-cli -p 7000 SLOWLOG GET 10

# Client connections per node:
redis-cli -p 7000 INFO clients
# connected_clients:142

# Keyspace stats:
redis-cli -p 7000 INFO keyspace
# db0:keys=1543210,expires=320100,avg_ttl=86400000
```

### Key Metrics to Alert On

| Metric | Source | Alert threshold |
|---|---|---|
| `cluster_state` | CLUSTER INFO | != ok |
| `cluster_slots_fail` | CLUSTER INFO | > 0 |
| `connected_clients` | INFO clients | > 80% of maxclients |
| `used_memory` | INFO memory | > 80% of maxmemory |
| `instantaneous_ops_per_sec` | INFO stats | deviation > 50% from baseline |
| `rejected_connections` | INFO stats | > 0 |
| `master_link_status` | INFO replication (replicas) | != up |
| Replication offset lag | CLUSTER NODES | replica offset diverging |

### Latency Diagnostics

```bash
redis-cli -p 7000 --latency-history -i 5
# min: 0, max: 3, avg: 0.45 (100 samples) -- 5.00 seconds range

redis-cli -p 7000 LATENCY LATEST
redis-cli -p 7000 LATENCY HISTORY event-name
```

---

## Common Pitfalls

### 1. Cross-Slot Errors
**Cause:** Multi-key command with keys in different slots.
**Fix:** Use hash tags `{tag}:key` to colocate related keys.

### 2. Hotspot Nodes
**Cause:** Poor key distribution or single popular hash tag.
**Fix:** Spread hash tags across entities. Monitor per-node ops/sec. Rebalance slots.

### 3. Large Keys (Big Keys)
**Cause:** Single key > 10 MB blocks cluster operations and resharding.
**Fix:** Break into smaller keys. Use `redis-cli --bigkeys` to find offenders.

```bash
redis-cli -p 7000 --bigkeys
# Biggest string: user:megalist — 45.2 MB
# Biggest hash: session:abc — 12340 fields
```

### 4. Cluster Bus Port Blocked
**Cause:** Firewall blocks port+10000. Nodes can't gossip.
**Fix:** Open both ports. Verify with `CLUSTER NODES` — nodes stuck in `handshake` state means bus port blocked.

### 5. Docker/NAT Issues
**Cause:** Cluster announces internal IPs that clients can't reach.
**Fix:** Set `cluster-announce-ip`, `cluster-announce-port`, `cluster-announce-bus-port` in redis.conf.

```conf
cluster-announce-ip 203.0.113.10
cluster-announce-port 7000
cluster-announce-bus-port 17000
```

### 6. Full Coverage Requirement
**Cause:** `cluster-require-full-coverage yes` (default). If any slot is uncovered, entire cluster rejects writes.
**Fix:** For availability over consistency, set to `no`. Cluster serves requests for covered slots even if some slots are down.

### 7. Stale Client Topology
**Cause:** Client caches slot map, doesn't refresh after failover/reshard.
**Fix:** Enable topology refresh. Handle MOVED errors as triggers to refresh.

### 8. Memory Limit Without Eviction Policy
**Cause:** Node hits maxmemory, rejects writes, breaks replication.
**Fix:** Set `maxmemory-policy` (e.g., `allkeys-lru`). Monitor memory per node. Reshard to distribute load.

### 9. Unbalanced Slot Distribution
**Cause:** Manual slot assignment or adding nodes without rebalancing.
**Fix:** `redis-cli --cluster rebalance <host>:<port>` — redistributes slots evenly.

### 10. Replica Divergence During Network Partition
**Cause:** Split-brain — clients write to old master while new master is elected.
**Fix:** Set `min-replicas-to-write 1` and `min-replicas-max-lag 10` to stop accepting writes when replicas are unreachable.

---

## References

In-depth guides for advanced usage, troubleshooting, and operations:

| Document | Path | Covers |
|---|---|---|
| **Advanced Patterns** | `references/advanced-patterns.md` | Cluster-aware Lua scripting, cross-slot transactions with hash tags, sharded pub/sub (Redis 7+), Streams in cluster mode, client-side caching with RESP3 tracking, cluster-aware connection pooling, standalone→cluster migration, ACL management |
| **Troubleshooting** | `references/troubleshooting.md` | Split-brain recovery, slot migration failures, node join/leave issues, memory fragmentation, redirect storms, cluster state inconsistency, replication buffer overflow, slow log analysis, latency diagnosis, network partition recovery |
| **Operations Guide** | `references/operations-guide.md` | Rolling upgrades, capacity planning, backup strategies (RDB/AOF), adding/removing nodes, rebalancing, monitoring with redis-cli, Prometheus/Grafana dashboards, alerting thresholds, maintenance windows |

---

## Scripts

Executable helper scripts for cluster lifecycle management:

| Script | Path | Purpose |
|---|---|---|
| **Setup Cluster** | `scripts/setup-cluster.sh` | Bootstrap a Redis cluster (Docker or bare-metal). Supports configurable masters/replicas, production mode with AUTH, and cleanup. |
| **Health Check** | `scripts/health-check.sh` | Comprehensive cluster health check: node states, slot coverage, replication, memory, latency, persistence. JSON output option. |
| **Resharding** | `scripts/resharding.sh` | Automated slot migration with progress tracking, batch control, dry-run mode, audit logging, and rollback capability. |

Usage examples:

```bash
# Bootstrap a 6-node dev cluster with Docker:
./scripts/setup-cluster.sh --mode docker --masters 3 --replicas 1

# Check cluster health:
./scripts/health-check.sh 127.0.0.1:7001 --verbose

# Migrate 1000 slots between nodes:
./scripts/resharding.sh --host 127.0.0.1:7001 \
  --from <source-id> --to <target-id> --slots 1000

# Clean up dev cluster:
./scripts/setup-cluster.sh --cleanup --mode docker
```

---

## Assets

Production-ready templates and configurations:

| Asset | Path | Purpose |
|---|---|---|
| **Docker Compose** | `assets/docker-compose.yaml` | 6-node Redis Cluster (3 masters + 3 replicas) with health checks, volumes, and auto-initialization. |
| **Cluster Config** | `assets/redis-cluster.conf` | Production `redis.conf` template with cluster, memory, persistence, security, replication, and performance settings. |
| **Sentinel Config** | `assets/sentinel.conf` | Production Sentinel configuration template. **Note:** Sentinel is for non-cluster HA only — do NOT combine with Redis Cluster. |

```bash
# Quick start with Docker Compose:
cd assets/
docker compose up -d
# Cluster auto-initializes via the redis-cluster-init service.

# For bare-metal, copy and customize the config template:
cp assets/redis-cluster.conf /etc/redis/redis-7000.conf
# Edit: port, cluster-announce-ip, requirepass, maxmemory
```
