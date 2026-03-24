# Redis Troubleshooting Guide

## Table of Contents

- [Memory Pressure and Eviction](#memory-pressure-and-eviction)
- [Slow Commands](#slow-commands)
- [Connection Pool Exhaustion](#connection-pool-exhaustion)
- [Replication Lag](#replication-lag)
- [Cluster Slot Migration Issues](#cluster-slot-migration-issues)
- [AOF Rewrite Failures](#aof-rewrite-failures)
- [Hot Keys](#hot-keys)
- [Big Keys Detection and Remediation](#big-keys-detection-and-remediation)
- [Latency Spikes](#latency-spikes)
  - [Fork Latency](#fork-latency)
  - [AOF Fsync Stalls](#aof-fsync-stalls)
  - [Swapping](#swapping)
- [Client Output Buffer Overflow](#client-output-buffer-overflow)
- [Sentinel Failover Problems](#sentinel-failover-problems)
- [Split-Brain](#split-brain)
- [Memory Fragmentation](#memory-fragmentation)

---

## Memory Pressure and Eviction

### Symptoms
- `OOM command not allowed` errors
- High eviction rate in `INFO stats` (`evicted_keys`)
- `used_memory` approaching or exceeding `maxmemory`

### Diagnosis

```bash
redis-cli INFO memory | grep -E "used_memory_human|maxmemory_human|mem_fragmentation|used_memory_peak"
redis-cli INFO stats | grep evicted_keys
redis-cli INFO keyspace   # total keys per DB
redis-cli DBSIZE
```

### Common Causes and Fixes

**No maxmemory set**: Redis grows unbounded until OS kills it.
```redis
CONFIG SET maxmemory 4gb
CONFIG SET maxmemory-policy allkeys-lru
CONFIG REWRITE   -- persist to redis.conf
```

**Wrong eviction policy**: `noeviction` rejects writes instead of evicting.
- Cache workload → `allkeys-lru` or `allkeys-lfu`
- Mixed (some keys must persist) → `volatile-lru` (only evicts keys with TTL)

**Missing TTLs**: Keys accumulate without expiry.
```bash
# Find keys without TTL (sample check)
redis-cli --scan --pattern '*' | head -100 | while read key; do
  ttl=$(redis-cli TTL "$key")
  [ "$ttl" = "-1" ] && echo "NO TTL: $key"
done
```

**Large keys consuming disproportionate memory**:
```bash
redis-cli --memkeys --memkeys-samples 100  # find largest keys by memory
redis-cli MEMORY USAGE <key>
```

**Inefficient encoding**: Large hashes/lists switch from compact (listpack) to full encoding.
```redis
-- Tune thresholds to keep compact encoding longer
CONFIG SET hash-max-listpack-entries 128    -- default 128
CONFIG SET hash-max-listpack-value 64       -- default 64
CONFIG SET list-max-listpack-size -2        -- default -2 (8KB)
```

---

## Slow Commands

### Symptoms
- Increased latency visible in `SLOWLOG`
- Other clients timing out during slow command execution
- High `instantaneous_ops_per_sec` drops in `INFO stats`

### Diagnosis

```redis
SLOWLOG GET 25            -- last 25 slow commands
SLOWLOG LEN               -- total slow commands logged
SLOWLOG RESET             -- clear log
CONFIG GET slowlog-log-slower-than   -- threshold in microseconds (default 10000 = 10ms)
CONFIG SET slowlog-log-slower-than 5000   -- lower to 5ms for debugging
```

### Common Offenders and Fixes

**KEYS pattern** — Scans entire keyspace, O(N). NEVER use in production.
```redis
-- Replace with:
SCAN 0 MATCH "user:*" COUNT 100 TYPE string
```

**SMEMBERS / HGETALL on large collections** — O(N) on the collection size.
```redis
-- Replace with cursor-based scan:
SSCAN large_set 0 COUNT 100    -- iterate in batches
HSCAN large_hash 0 COUNT 100
```

**SORT on large lists/sets** — O(N+M*log(M)). Use sorted sets instead.

**DEL on large keys** — Blocks server while freeing memory.
```redis
-- Replace with async delete:
UNLINK large_key    -- O(1) in main thread, background free
```

**LRANGE / ZRANGE with large ranges** — O(N). Paginate:
```redis
LRANGE list 0 99       -- first 100, not LRANGE list 0 -1
ZRANGEBYSCORE zset min max LIMIT 0 100
```

**Aggregate commands on large datasets** (SUNION, SINTER, ZUNIONSTORE):
```redis
-- Do incrementally or in Lua with batching
-- Or pre-compute and cache results
```

### Prevention

```redis
-- Rename dangerous commands in production
rename-command KEYS ""
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command DEBUG ""
```

---

## Connection Pool Exhaustion

### Symptoms
- `ERR max number of clients reached`
- Application connection timeouts
- `connected_clients` in INFO near `maxclients`

### Diagnosis

```redis
INFO clients
-- connected_clients: current connections
-- blocked_clients: clients in blocking commands
-- maxclients (CONFIG GET maxclients)

CLIENT LIST    -- all connected clients with age, idle time, flags
CLIENT LIST TYPE normal    -- only normal (non-pub/sub, non-replica) clients
CLIENT LIST ID 1 2 3      -- specific client IDs
```

```bash
# Connection leak detection: find idle connections
redis-cli CLIENT LIST | awk -F'[ =]' '{for(i=1;i<=NF;i++) if($i=="idle") print $(i+1)}' | sort -rn | head
```

### Common Causes and Fixes

**Connection leaks**: Application opens connections without closing.
```python
# Bad: new connection per request
def handle_request():
    r = redis.Redis()  # new connection!
    r.get("key")
    # connection never closed

# Good: connection pool
pool = redis.ConnectionPool(max_connections=50)
r = redis.Redis(connection_pool=pool)
```

**Pool too small**: Under high concurrency, all connections in use.
```python
# Tune pool size: match expected concurrency
pool = redis.ConnectionPool(
    max_connections=100,        # upper bound
    timeout=5,                  # wait 5s for available connection
    retry_on_timeout=True,
    health_check_interval=30,   # detect dead connections
)
```

**Blocking commands holding connections**: BRPOP, BLPOP, SUBSCRIBE hold connections.
```python
# Use separate pool for blocking operations
blocking_pool = redis.ConnectionPool(max_connections=10)
blocking_client = redis.Redis(connection_pool=blocking_pool)
```

**Server-side limit too low**:
```redis
CONFIG SET maxclients 10000    -- default is 10000
-- Also check OS limits: ulimit -n (file descriptors)
```

**Stale connections**: Detect and kill idle clients.
```redis
CONFIG SET timeout 300         -- close idle connections after 5 min (0 = disabled)
-- Or use tcp-keepalive to detect dead connections
CONFIG SET tcp-keepalive 60    -- send TCP keepalive every 60s
```

---

## Replication Lag

### Symptoms
- Stale reads from replicas
- `master_repl_offset` and `slave_repl_offset` diverging
- `master_link_status:down` on replica

### Diagnosis

```redis
-- On primary:
INFO replication
-- role:master
-- connected_slaves:2
-- slave0:ip=10.0.0.2,port=6379,state=online,offset=123456,lag=0

-- On replica:
INFO replication
-- role:slave
-- master_link_status:up
-- master_last_io_seconds_ago:0
-- slave_repl_offset:123456
-- slave_read_repl_offset:123456
```

```bash
# Monitor lag over time
watch -n 1 "redis-cli -h primary INFO replication | grep slave"
```

### Common Causes and Fixes

**Slow replica (overloaded, slow disk)**: Replica can't apply writes fast enough.
- Check replica CPU, disk I/O, network bandwidth
- Remove heavy read queries from lagged replicas
- Use `replica-lazy-flush yes` to speed up full resync

**Large RDB transfer during full resync**: Full resync transfers entire dataset.
```redis
-- Check if full resync is happening:
-- On replica: master_sync_in_progress:1
-- Mitigate: ensure repl-backlog-size is large enough to avoid full resyncs
CONFIG SET repl-backlog-size 256mb    -- default 1mb (too small for busy servers)
```

**Network issues**: Packet loss or latency between primary and replica.
```bash
# Test network
ping -c 100 <replica-ip> | tail -1  # check packet loss and latency
iperf3 -c <replica-ip>              # bandwidth test
```

**Write-heavy primary outpacing replica**: Replica falls behind during burst writes.
- Temporarily pause writes or reduce write volume
- Use `wait` command for synchronous replication when needed:
```redis
SET key value
WAIT 1 5000    -- wait for at least 1 replica to acknowledge, 5s timeout
```

---

## Cluster Slot Migration Issues

### Symptoms
- `-ASK` redirections during migration
- `-CLUSTERDOWN` errors (not all slots covered)
- Stuck migration (slot in migrating/importing state indefinitely)

### Diagnosis

```redis
CLUSTER INFO           -- cluster_state, cluster_slots_assigned
CLUSTER NODES          -- look for "migrating" or "importing" flags
CLUSTER SLOTS          -- slot assignments
CLUSTER COUNTKEYSINSLOT <slot>   -- keys remaining in slot
```

### Fixing Stuck Migrations

```bash
# Check which slots are in migrating/importing state
redis-cli -c CLUSTER NODES | grep -E "migrating|importing"

# Option 1: Complete the migration
redis-cli --cluster fix <any-node>:6379

# Option 2: Cancel the migration (reset slot state)
redis-cli -h <source-node> CLUSTER SETSLOT <slot> STABLE
redis-cli -h <target-node> CLUSTER SETSLOT <slot> STABLE

# Option 3: Force slot assignment
redis-cli --cluster reshard <node>:6379 \
  --cluster-from <source-id> --cluster-to <target-id> \
  --cluster-slots 1 --cluster-yes
```

### Prevention
- Migrate slots during low-traffic periods
- Use `--cluster-pipeline` to batch key migration
- Monitor migration progress with `CLUSTER COUNTKEYSINSLOT`
- Don't migrate too many slots simultaneously

---

## AOF Rewrite Failures

### Symptoms
- `aof_last_bgrewriteaof_status:err` in INFO
- Disk full errors in Redis log
- AOF file growing unbounded
- `Can't rewrite append only file in background: fork: Cannot allocate memory`

### Diagnosis

```redis
INFO persistence
-- aof_enabled:1
-- aof_rewrite_in_progress:0
-- aof_last_bgrewriteaof_status:ok/err
-- aof_current_size:12345678
-- aof_base_size:5000000
```

### Common Causes and Fixes

**Insufficient memory for fork()**: `fork()` requires enough virtual memory for a copy.
```bash
# Check and fix overcommit
cat /proc/sys/vm/overcommit_memory
# Set to 1 (always allow overcommit) for Redis
echo 1 > /proc/sys/vm/overcommit_memory
# Or persistent: sysctl vm.overcommit_memory=1
```

**Disk full**:
```bash
df -h $(dirname $(redis-cli CONFIG GET dir | tail -1))
# Free disk space or change AOF directory
```

**AOF growing too fast (many writes between rewrites)**:
```redis
CONFIG SET auto-aof-rewrite-percentage 100    -- trigger at 2x base size
CONFIG SET auto-aof-rewrite-min-size 64mb     -- minimum size before auto-rewrite
BGREWRITEAOF                                  -- trigger manual rewrite
```

**AOF corruption**:
```bash
# Check and fix AOF
redis-check-aof --fix appendonly.aof
# Backup before fixing!
```

---

## Hot Keys

### Symptoms
- Uneven CPU distribution in Cluster (one shard overloaded)
- Single-key latency spikes
- High `instantaneous_ops_per_sec` on specific node

### Detection

```bash
# Monitor hot keys in real-time (Redis 4.0+)
redis-cli --hotkeys
# Requires maxmemory-policy to be LFU-based (allkeys-lfu or volatile-lfu)

# Alternative: monitor command frequency
redis-cli MONITOR | head -1000 | awk '{print $4}' | sort | uniq -c | sort -rn | head
# WARNING: MONITOR is expensive — use briefly in production
```

```redis
-- Check access frequency (requires LFU policy)
OBJECT FREQ mykey    -- LFU frequency counter
OBJECT IDLETIME mykey   -- seconds since last access (LRU)
```

### Solutions

**Read-heavy hot key**: Replicate reads.
```python
# Read from replicas for hot keys
replica_client = redis.Redis(host='replica-host')
value = replica_client.get("hot:config:key")
```

**Write-heavy hot key**: Shard the key.
```python
import random
# Instead of one counter, use N shards
shard = random.randint(0, 15)
r.incr(f"counter:views:{{shard{shard}}}")

# Read: sum all shards
total = sum(int(r.get(f"counter:views:{{shard{i}}}") or 0) for i in range(16))
```

**Hot key in Cluster**: Use hash tags to move key, or add read replicas to the shard.

**Application-level caching**: Cache hot keys locally (L1 cache) with short TTL.
```python
from functools import lru_cache
import time

@lru_cache(maxsize=1000)
def get_config(key):
    return r.get(key)

# Invalidate periodically or via pub/sub
```

---

## Big Keys Detection and Remediation

Big keys cause: latency spikes (serialization, DEL blocking), memory spikes, replication issues, cluster rebalancing problems.

### Detection

```bash
# Built-in big key scan (samples random keys)
redis-cli --bigkeys
redis-cli --bigkeys -i 0.1   # with 100ms sleep between scans

# Memory-based scan (more accurate)
redis-cli --memkeys
redis-cli --memkeys-samples 100

# Custom scan for precision
redis-cli --scan --pattern '*' | while read key; do
  mem=$(redis-cli MEMORY USAGE "$key" SAMPLES 0)
  type=$(redis-cli TYPE "$key")
  [ "$mem" -gt 1048576 ] && echo "$mem $type $key"
done | sort -rn | head -20
```

### Thresholds (Rules of Thumb)

| Type | "Big" Threshold | Remediation |
|------|----------------|-------------|
| String | >1MB | Compress, chunk, or move to blob store |
| Hash | >5000 fields or >10MB | Split into sub-hashes |
| List | >10000 elements | Paginate, use multiple lists |
| Set | >10000 members | Partition by key prefix |
| Sorted Set | >10000 members | Partition by score range or key |
| Stream | >10000 entries | XTRIM aggressively |

### Remediation

```python
# Split large hash into sub-hashes
# Before: HSET user:1001 with 50000 fields
# After: HSET user:1001:chunk:0 ... user:1001:chunk:49

def split_hash(r, key, chunk_size=1000):
    cursor = 0
    chunk_num = 0
    chunk = {}
    while True:
        cursor, data = r.hscan(key, cursor, count=chunk_size)
        chunk.update(data)
        if len(chunk) >= chunk_size:
            r.hset(f"{key}:chunk:{chunk_num}", mapping=chunk)
            chunk = {}
            chunk_num += 1
        if cursor == 0:
            if chunk:
                r.hset(f"{key}:chunk:{chunk_num}", mapping=chunk)
            break

# Delete big keys safely
r.unlink("big_key")  # async delete, non-blocking
```

---

## Latency Spikes

### Fork Latency

`BGSAVE`, `BGREWRITEAOF`, and (on replicas) full resync trigger `fork()`. Large memory = slow fork.

```bash
# Measure fork time
redis-cli INFO stats | grep latest_fork_usec
# Values >100ms cause noticeable latency

# Check Transparent Huge Pages (THPages cause fork latency)
cat /sys/kernel/mm/transparent_hugepage/enabled
# Should show [never] — disable THP:
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

```redis
-- Monitor with LATENCY subsystem
LATENCY LATEST
LATENCY HISTORY fork
LATENCY HISTORY aof-rewrite
LATENCY RESET
CONFIG SET latency-monitor-threshold 50   -- track events >50ms
```

**Mitigations**:
- Disable THP (major impact)
- Perform BGSAVE on replicas, not primary
- Use smaller instances with less memory per shard
- Tune `save` config to reduce BGSAVE frequency

### AOF Fsync Stalls

With `appendfsync everysec`, a slow fsync blocks the main thread if previous fsync hasn't completed.

```bash
# Check disk I/O performance
iostat -x 1 5   # look at await, %util
# High await = slow disk = fsync stalls

# Check if Redis is waiting on fsync
redis-cli INFO persistence | grep aof_delayed_fsync
# Non-zero = fsync took >2s, Redis delayed next write
```

**Mitigations**:
- Use faster storage (NVMe SSD)
- `no-appendfsync-on-rewrite yes` — skip fsync during AOF rewrite
- Perform AOF on replicas
- Consider `appendfsync no` if some data loss is acceptable

### Swapping

Redis in swap = catastrophic latency (100-1000x slowdown).

```bash
# Check if Redis is swapping
redis-cli INFO server | grep process_id
cat /proc/<pid>/smaps | grep -i swap | awk '{sum+=$2} END {print sum "kB"}'
# Should be 0 or near 0

# Prevention
# 1. Set maxmemory below available RAM
# 2. Disable swap for Redis (or use vm.swappiness=0)
sysctl vm.swappiness=0
# 3. Or use cgroup memory limits
```

---

## Client Output Buffer Overflow

When a client can't consume output fast enough, Redis buffers it. If buffer exceeds limits, Redis disconnects the client.

### Symptoms
- Clients disconnected unexpectedly
- `client_recent_max_output_buffer` in INFO clients is large
- Log: `Client ... closed on overcoming of output buffer limits`

### Diagnosis

```redis
CONFIG GET client-output-buffer-limit
-- Returns: normal, replica, pubsub limits

CLIENT LIST   -- look at obl (output buffer length) and oll (output list length)
-- obl >0 or oll >0 means client has pending output
```

### Common Causes

**Pub/Sub subscriber too slow**:
```redis
-- Default limits: pubsub 32mb hard, 8mb/60s soft
-- Tune if legitimate high-volume pub/sub:
CONFIG SET client-output-buffer-limit "pubsub 64mb 16mb 120"
-- format: <class> <hard-limit> <soft-limit> <soft-seconds>
```

**Replica falling behind**:
```redis
-- Default: replica 256mb hard, 64mb/60s soft
CONFIG SET client-output-buffer-limit "replica 512mb 128mb 120"
```

**Large MONITOR output**: MONITOR generates output for every command.
```redis
-- Never leave MONITOR running in production
-- If you must, set aggressive timeout:
CONFIG SET client-output-buffer-limit "normal 256mb 64mb 60"
```

**Large response from single command** (HGETALL on huge hash, LRANGE 0 -1 on huge list):
- Break into smaller reads (HSCAN, LRANGE with pagination)

---

## Sentinel Failover Problems

### Symptoms
- Application can't connect after primary failure
- Sentinel log: `+failover-abort-no-good-slave`
- Multiple primaries visible (split-brain)

### Diagnosis

```bash
redis-cli -p 26379 SENTINEL masters              # list monitored primaries
redis-cli -p 26379 SENTINEL master mymaster       # primary details
redis-cli -p 26379 SENTINEL replicas mymaster     # replica list
redis-cli -p 26379 SENTINEL sentinels mymaster    # other sentinels
redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster  # current primary
redis-cli -p 26379 SENTINEL ckquorum mymaster     # check quorum reachable
redis-cli -p 26379 SENTINEL simulate-failure crash-after-election  # test
```

### Common Issues

**Quorum not met**: Not enough Sentinels agree primary is down.
- Ensure at least 3 Sentinels across different failure domains
- `down-after-milliseconds` too short → false positives

**No suitable replica**: All replicas are down, lagged, or filtered out.
```redis
-- Check replica priority (0 = never promote)
CONFIG SET replica-priority 100    -- on eligible replicas
-- Check min-replicas-to-write on primary
```

**Client not Sentinel-aware**: Application connects to IP directly instead of discovering via Sentinel.
```python
# Use Sentinel-aware connection
from redis.sentinel import Sentinel
sentinel = Sentinel([
    ('sentinel1', 26379),
    ('sentinel2', 26379),
    ('sentinel3', 26379),
], socket_timeout=0.5)
master = sentinel.master_for('mymaster', socket_timeout=0.5)
slave = sentinel.slave_for('mymaster', socket_timeout=0.5)
```

**DNS/IP issues after failover**: Old primary IP cached.
- Use Sentinel client libraries that re-resolve on disconnect
- Set short DNS TTL if using DNS names

---

## Split-Brain

### Symptoms
- Two nodes accepting writes simultaneously
- Data divergence after partition heals
- Clients writing to different primaries

### Prevention

```redis
-- On primary: require minimum replicas for writes
CONFIG SET min-replicas-to-write 1     -- at least 1 replica must be connected
CONFIG SET min-replicas-max-lag 10     -- replica lag must be <10s
-- If conditions not met, primary refuses writes → prevents isolated primary from accepting writes
```

**Sentinel quorum**: Set quorum to `ceil(N/2)` where N = number of Sentinels.
- 3 Sentinels → quorum 2
- 5 Sentinels → quorum 3

**Cluster**: `cluster-node-timeout` determines how long before a node is considered failed. Default 15s. A partitioned primary becomes read-only after `cluster-node-timeout` if it can't reach majority of masters.

### Recovery After Split-Brain

Data on the minority-side primary is lost when it rejoins as a replica:
1. Identify which node had the "correct" data (majority side)
2. The minority-side node will do a full resync and lose its writes
3. Review `SLOWLOG` and application logs for writes to the wrong node
4. Consider `WAIT` for critical writes to ensure replication before acknowledging

---

## Memory Fragmentation

### Symptoms
- `mem_fragmentation_ratio` > 1.5 in `INFO memory`
- `used_memory_rss` much higher than `used_memory`
- Memory doesn't decrease after deleting keys

### Diagnosis

```redis
INFO memory
-- mem_fragmentation_ratio:1.8   -- 1.0 = perfect, >1.5 = problematic, <1.0 = swapping
-- used_memory:4000000000        -- logical memory used
-- used_memory_rss:7200000000    -- physical memory from OS perspective
-- allocator_frag_ratio:1.3      -- allocator-level fragmentation
-- mem_allocator:jemalloc-5.3.0
```

### Causes
- High key churn (many creates + deletes of different sizes)
- Variable-size values (replacing short values with long ones)
- Expired keys leaving memory holes

### Fixes

**Active defragmentation (Redis 4.0+, jemalloc only)**:
```redis
CONFIG SET activedefrag yes
CONFIG SET active-defrag-enabled yes
CONFIG SET active-defrag-ignore-bytes 100mb      -- don't defrag if frag <100MB
CONFIG SET active-defrag-threshold-lower 10      -- start at 10% fragmentation
CONFIG SET active-defrag-threshold-upper 100     -- max effort at 100% fragmentation
CONFIG SET active-defrag-cycle-min 1             -- % CPU for defrag (min)
CONFIG SET active-defrag-cycle-max 25            -- % CPU for defrag (max)
```

**Restart with RDB**: If fragmentation is severe, restart Redis. It loads from RDB into fresh memory with optimal layout.

**Use jemalloc** (default in Redis builds): jemalloc handles fragmentation better than glibc malloc.

```bash
# Verify allocator
redis-cli INFO server | grep mem_allocator
# Should show jemalloc
```

**Prevention**:
- Use consistent value sizes when possible
- Avoid massive key churn patterns
- Enable active defrag proactively
- Monitor `mem_fragmentation_ratio` and alert at >1.5
