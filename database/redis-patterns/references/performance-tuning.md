# Redis Performance Tuning Guide

Production performance optimization covering client-side techniques, Redis server
configuration, memory optimization, persistence impact, and OS/kernel tuning.

---

## Table of Contents

1. [Client-Side Optimization](#client-side-optimization)
   - [Pipelining vs MULTI](#pipelining-vs-multi)
   - [Connection Pooling](#connection-pooling)
   - [Connection Multiplexing](#connection-multiplexing)
2. [Memory Optimization](#memory-optimization)
   - [Encoding Thresholds](#encoding-thresholds)
   - [Data Structure Selection](#data-structure-selection)
   - [Key Design for Memory Efficiency](#key-design-for-memory-efficiency)
   - [Memory Reclamation](#memory-reclamation)
3. [Maxmemory Policy Selection](#maxmemory-policy-selection)
4. [Persistence Impact on Latency](#persistence-impact-on-latency)
   - [RDB Impact](#rdb-impact)
   - [AOF Impact](#aof-impact)
   - [Persistence Tuning Matrix](#persistence-tuning-matrix)
5. [fork() Overhead](#fork-overhead)
6. [I/O Threads (Multi-Threading)](#io-threads-multi-threading)
7. [TCP and Network Tuning](#tcp-and-network-tuning)
8. [Kernel and OS Tuning](#kernel-and-os-tuning)
   - [vm.overcommit_memory](#vmovercommit_memory)
   - [Transparent Huge Pages](#transparent-huge-pages)
   - [File Descriptors](#file-descriptors)
   - [CPU Affinity](#cpu-affinity)
9. [Benchmarking](#benchmarking)
10. [Performance Checklist](#performance-checklist)

---

## Client-Side Optimization

### Pipelining vs MULTI

Both batch multiple commands, but serve different purposes:

| Aspect        | Pipelining                          | MULTI/EXEC                        |
|---------------|-------------------------------------|-----------------------------------|
| Purpose       | Reduce network round-trips         | Atomic execution                  |
| Atomicity     | No — commands interleave with others | Yes — all-or-nothing execution   |
| Performance   | 5-10x throughput improvement        | Similar to pipeline + overhead    |
| Use case      | Bulk reads/writes                   | Transactions requiring atomicity  |
| Combined      | `pipeline(transaction=True)` = both | Pipeline wrapping MULTI/EXEC     |

**Pipelining example (Python):**
```python
# WITHOUT pipelining: 1000 round-trips
for i in range(1000):
    redis.set(f"key:{i}", f"value:{i}")

# WITH pipelining: 1 round-trip
pipe = redis.pipeline(transaction=False)
for i in range(1000):
    pipe.set(f"key:{i}", f"value:{i}")
pipe.execute()
```

**Pipeline sizing guidelines:**
- Batch 100-1000 commands per pipeline (sweet spot for most workloads)
- Very large pipelines (10K+) increase memory usage on both client and server
- For reads, pipeline results are returned in order as a list
- Don't pipeline blocking commands (`BRPOP`, `BLPOP`, `SUBSCRIBE`)

**Combined pipeline + transaction:**
```python
pipe = redis.pipeline(transaction=True)   # wraps commands in MULTI/EXEC
pipe.decrby("account:A", 100)
pipe.incrby("account:B", 100)
results = pipe.execute()                  # atomic, single round-trip
```

### Connection Pooling

Connection establishment is expensive (~1-3ms TCP + TLS handshake). Pools reuse
connections across requests.

**Python (redis-py):**
```python
import redis

pool = redis.ConnectionPool(
    host='redis-primary',
    port=6379,
    max_connections=50,           # max pool size
    socket_timeout=5,             # read timeout
    socket_connect_timeout=2,     # connection timeout
    retry_on_timeout=True,
    health_check_interval=30,     # periodic PING
)
r = redis.Redis(connection_pool=pool)
```

**Java (Jedis):**
```java
JedisPoolConfig config = new JedisPoolConfig();
config.setMaxTotal(50);              // max connections
config.setMaxIdle(10);               // max idle connections
config.setMinIdle(5);                // min idle (pre-warmed)
config.setTestOnBorrow(true);        // validate before use
config.setTestWhileIdle(true);       // validate idle connections
config.setMaxWait(Duration.ofSeconds(2));

JedisPool pool = new JedisPool(config, "redis-primary", 6379);
try (Jedis jedis = pool.getResource()) {
    jedis.set("key", "value");
}
```

**Pool sizing formula:**
```
max_connections = (num_app_threads * avg_redis_calls_per_request) / avg_redis_call_duration_ms
```

Typical range: 10-50 connections per application instance. Total across all instances
must stay under Redis `maxclients` (default: 10000).

### Connection Multiplexing

Event-driven clients (Lettuce, node-redis, go-redis) multiplex commands over a single
connection, eliminating pool management.

```javascript
// Node.js — single multiplexed connection handles thousands of concurrent commands
const client = createClient({ url: 'redis://redis-primary:6379' });
await client.connect();
// All concurrent requests share this connection
```

**Trade-offs:**
- Lower connection count, simpler management
- Cannot use blocking commands on shared connection
- Head-of-line blocking if one command is slow
- Best for high-concurrency, low-latency workloads

---

## Memory Optimization

### Encoding Thresholds

Redis automatically selects compact encodings for small data structures. These are
dramatically more memory-efficient than their full representations.

| Data Structure | Compact Encoding | Threshold Config                        | Default |
|----------------|------------------|-----------------------------------------|---------|
| Hash           | listpack         | `hash-max-listpack-entries`             | 128     |
|                |                  | `hash-max-listpack-value`               | 64      |
| List           | listpack         | `list-max-listpack-size`                | -2      |
| Set            | listpack         | `set-max-listpack-entries`              | 128     |
| Set (integers) | intset           | `set-max-intset-entries`                | 512     |
| Sorted Set     | listpack         | `zset-max-listpack-entries`             | 128     |
|                |                  | `zset-max-listpack-value`               | 64      |

> **Note:** In Redis 7+, `ziplist` was replaced by `listpack`. Config names changed from
> `*-ziplist-*` to `*-listpack-*`. Older Redis versions use `hash-max-ziplist-entries`, etc.

**Check current encoding:**
```redis
OBJECT ENCODING mykey
# "listpack"   → compact (good)
# "hashtable"  → full representation (more memory)
# "skiplist"   → full sorted set
# "quicklist"  → list internal format
# "intset"     → integer set (very compact)
```

**Tuning for memory efficiency:**
```redis
# If your hashes always have < 256 fields with values < 128 bytes:
CONFIG SET hash-max-listpack-entries 256
CONFIG SET hash-max-listpack-value 128

# If your sets contain integers < 1024 elements:
CONFIG SET set-max-intset-entries 1024

# Trade-off: Higher thresholds = more memory savings, but O(N) operations on listpacks
# vs O(1) on hashtables. Keep entries < 512 for acceptable CPU overhead.
```

### Data Structure Selection

Choose structures that minimize memory for your access pattern:

**Small objects → Hash of hashes:**
```python
# INEFFICIENT: 1 key per field (40+ bytes overhead per key)
redis.set("user:1001:name", "Alice")
redis.set("user:1001:email", "alice@x.com")
redis.set("user:1001:plan", "pro")
# ~160 bytes for 3 fields

# EFFICIENT: Single hash (listpack encoding)
redis.hset("user:1001", mapping={"name": "Alice", "email": "alice@x.com", "plan": "pro"})
# ~90 bytes for 3 fields (with listpack encoding)
```

**Bulk small values → Hash bucketing:**
```python
# Store millions of small key-value pairs efficiently
# Instead of: SET obj:000001 "data" ... SET obj:999999 "data"
# Bucket into hashes of ~100 entries each:
def hset_bucketed(obj_id, value):
    bucket = int(obj_id) // 100
    redis.hset(f"bucket:{bucket}", obj_id, value)

def hget_bucketed(obj_id):
    bucket = int(obj_id) // 100
    return redis.hget(f"bucket:{bucket}", obj_id)
# Saves 50-80% memory via listpack encoding
```

**Bitmaps for boolean flags:**
```python
# Instead of: SET user:1001:feature_x 1 (40+ bytes)
# Use bitmap: 1 bit per user
redis.setbit("feature:x:enabled", 1001, 1)
redis.getbit("feature:x:enabled", 1001)
# 125KB covers 1M users vs ~40MB with string keys
```

### Key Design for Memory Efficiency

- Shorter key names save memory at scale: `u:1001:n` vs `user:1001:name`
- Use numeric IDs instead of UUIDs when possible (saves ~20 bytes/key)
- Expire keys aggressively — don't cache what you don't need
- Avoid storing redundant data across keys

```redis
# Check key overhead
DEBUG OBJECT mykey
# Value at: 0x7f... refcount:1 encoding:embstr serializedlength:12 lru:... type:string
# Small strings (≤44 bytes) use embstr encoding (single allocation)
# Larger strings use raw encoding (two allocations)
```

### Memory Reclamation

```redis
# Async deletion (non-blocking)
UNLINK key1 key2 key3

# Enable lazy freeing globally
CONFIG SET lazyfree-lazy-expire yes          # async expire
CONFIG SET lazyfree-lazy-server-del yes      # async implicit DEL
CONFIG SET lazyfree-lazy-user-del yes        # DEL behaves like UNLINK
CONFIG SET lazyfree-lazy-user-flush yes      # FLUSHDB/FLUSHALL async by default

# Active defragmentation
CONFIG SET activedefrag yes

# Purge jemalloc dirty pages
MEMORY PURGE
```

---

## Maxmemory Policy Selection

Choose based on your workload pattern:

| Workload                        | Recommended Policy   | Reason                                |
|---------------------------------|---------------------|---------------------------------------|
| General cache                   | `allkeys-lru`       | Evict least-recently-used globally    |
| Cache with popularity bias      | `allkeys-lfu`       | Keep frequently accessed keys         |
| Mixed cache + persistent keys   | `volatile-lru`      | Only evict keys with TTL set          |
| Session store                   | `volatile-lru`      | Sessions have TTL; persistent = safe  |
| Primary database                | `noeviction`        | Never lose data; return errors        |
| Short-lived analytics keys      | `volatile-ttl`      | Evict soonest-to-expire first         |

**LFU tuning:**
```redis
# Logarithmic frequency counter — higher factor = slower growth
CONFIG SET lfu-log-factor 10       # default 10

# Decay period — minutes between counter halving
CONFIG SET lfu-decay-time 1        # default 1

# Higher sampling = more accurate eviction (slight CPU cost)
CONFIG SET maxmemory-samples 10    # default 5
```

---

## Persistence Impact on Latency

### RDB Impact

RDB snapshots use `fork()` to create a consistent point-in-time dump.

**Latency sources:**
- `fork()` itself: ~10-20ms per GB of dataset (page table copy)
- Copy-on-Write (CoW): write-heavy workloads cause page copies, increasing memory
- Disk I/O: RDB write competes for disk bandwidth

**Mitigation:**
```redis
# Reduce save frequency
CONFIG SET save "3600 1 300 100"     # less frequent saves

# Disable RDB entirely (if using AOF)
CONFIG SET save ""

# Schedule saves during off-peak hours via BGSAVE cron
```

### AOF Impact

**`appendfsync` modes and their impact:**

| Mode        | Durability        | Latency Impact                          |
|-------------|-------------------|-----------------------------------------|
| `always`    | Every write fsync | 2-5x latency increase, ~50% throughput  |
| `everysec`  | fsync per second  | Minimal (background thread), ~1s loss   |
| `no`        | OS decides        | Zero impact, 30s+ possible data loss    |

**AOF rewrite latency:**
```redis
# Prevent fsync during rewrite (reduces spikes, brief durability gap)
CONFIG SET no-appendfsync-on-rewrite yes

# Control rewrite trigger thresholds
CONFIG SET auto-aof-rewrite-percentage 100   # trigger at 2x baseline size
CONFIG SET auto-aof-rewrite-min-size 128mb   # minimum before auto-rewrite
```

### Persistence Tuning Matrix

| Use Case           | RDB         | AOF             | Notes                               |
|--------------------|-------------|-----------------|-------------------------------------|
| Pure cache         | Disabled    | Disabled        | Maximum throughput, no durability   |
| Cache + warm start | RDB only    | Disabled        | Fast restart, minutes of data loss  |
| Primary DB         | Backup only | everysec+hybrid | Balance of durability and speed     |
| Critical data      | Backup only | always+hybrid   | Maximum durability, lower throughput|

---

## fork() Overhead

Every `BGSAVE`, `BGREWRITEAOF`, and full resync triggers `fork()`.

**Measuring fork time:**
```redis
# Check last fork duration
INFO persistence
# rdb_last_bgsave_time_sec: 5
# rdb_last_cow_size: 268435456    # 256MB CoW

LATENCY HISTORY fork
# Shows all fork latency spikes
```

**Overhead by dataset size:**
| Dataset Size | Typical fork() Time | CoW Worst Case |
|-------------|--------------------:|----------------|
| 1 GB        | 10-20ms            | +1 GB          |
| 5 GB        | 50-100ms           | +5 GB          |
| 10 GB       | 100-200ms          | +10 GB         |
| 25 GB       | 250-500ms          | +25 GB         |
| 50 GB+      | 500ms-1s+          | Consider split |

**Reducing fork impact:**
1. Keep datasets < 25GB per instance (shard if larger)
2. Enable `vm.overcommit_memory = 1`
3. Disable Transparent Huge Pages
4. Use diskless replication (`repl-diskless-sync yes`)
5. Schedule persistence during low-traffic windows
6. Consider no RDB if AOF provides sufficient durability

---

## I/O Threads (Multi-Threading)

Redis 6+ allows multi-threaded network I/O while keeping command execution single-threaded.

**When to enable:**
- High connection counts (1000+)
- High throughput (100K+ ops/sec)
- CPU is not the bottleneck (check with `top` — Redis should be < 90% on one core)
- Network I/O is the bottleneck (many small commands)

**Configuration:**
```
# redis.conf
io-threads 4                    # number of I/O threads (including main)
io-threads-do-reads yes         # also multithread reads (not just writes)
```

**Thread count guidelines:**
| CPU Cores | Recommended io-threads |
|-----------|:----------------------:|
| 2-4       | Do not enable          |
| 4-8       | 2-4                    |
| 8-16      | 4-6                    |
| 16+       | 6-8                    |

**What IS multi-threaded:**
- Socket reads (with `io-threads-do-reads yes`)
- Socket writes (response writing)
- Protocol parsing

**What is NOT multi-threaded:**
- Command execution (always single-threaded)
- Data structure operations
- Lua/Function execution
- Persistence (fork-based, separate process)

**Verification:**
```bash
# Check if I/O threads are active
redis-cli INFO server | grep io_threads
# io_threads_active:1   (0 = not active, 1 = active)
```

---

## TCP and Network Tuning

### Redis Configuration

```redis
# TCP backlog (pending connection queue)
CONFIG SET tcp-backlog 511           # default 511, increase for burst connections
# Must also increase kernel: net.core.somaxconn

# TCP keepalive (detect dead connections)
CONFIG SET tcp-keepalive 60          # seconds between keepalive probes

# Bind to specific interfaces
# bind 127.0.0.1 10.0.0.1           # production: bind to internal IPs only

# Disable Nagle's algorithm (redis does this by default)
# TCP_NODELAY is enabled — low latency for small packets
```

### Client-Side Network Tuning

```python
# Python: socket tuning
pool = redis.ConnectionPool(
    host='redis-primary',
    port=6379,
    socket_timeout=5,                # read timeout
    socket_connect_timeout=2,        # connect timeout
    socket_keepalive=True,           # enable TCP keepalive
    socket_keepalive_options={
        socket.TCP_KEEPIDLE: 60,     # idle time before probes
        socket.TCP_KEEPINTVL: 15,    # interval between probes
        socket.TCP_KEEPCNT: 3,       # probes before marking dead
    },
    retry_on_timeout=True,
)
```

---

## Kernel and OS Tuning

### vm.overcommit_memory

**Critical for Redis persistence.** Without this, `fork()` can fail with OOM when the
system doesn't have enough free memory to theoretically cover both parent and child.

```bash
# Set immediately
echo 1 > /proc/sys/vm/overcommit_memory

# Persist across reboots
echo "vm.overcommit_memory=1" >> /etc/sysctl.conf
sysctl -p
```

**Values:**
- `0` (default): Heuristic overcommit — kernel may refuse fork() even with CoW
- `1` (recommended): Always overcommit — fork() always succeeds
- `2`: Don't overcommit — strict, never use for Redis

### Transparent Huge Pages

THP causes latency spikes during `fork()` and CoW operations. **Always disable for Redis.**

```bash
# Disable immediately
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# Persist via systemd service or rc.local
cat > /etc/systemd/system/disable-thp.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages
Before=redis-server.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=multi-user.target
EOF
systemctl enable disable-thp
```

**Redis warns on startup if THP is enabled:**
```
WARNING you have Transparent Huge Pages (THP) support enabled in your kernel.
This will create latency and memory usage issues with Redis.
```

### File Descriptors

Redis needs one file descriptor per client connection plus internal usage.

```bash
# Check current limit
ulimit -n

# Set for Redis user in /etc/security/limits.conf:
redis soft nofile 65536
redis hard nofile 65536

# Or in systemd service override:
# /etc/systemd/system/redis-server.service.d/override.conf
[Service]
LimitNOFILE=65536
```

**Additional kernel tuning:**
```bash
# /etc/sysctl.conf additions for Redis servers

# TCP backlog queue
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Connection tracking (if using NAT/firewall)
net.netfilter.nf_conntrack_max = 262144

# Memory
vm.overcommit_memory = 1
vm.swappiness = 1              # minimize swap usage (don't set to 0)

# Network buffer sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216

# Apply changes
sysctl -p
```

### CPU Affinity

Pin Redis to specific CPU cores to avoid context switching and NUMA effects:

```bash
# Pin Redis to cores 0-1
taskset -cp 0-1 $(pgrep redis-server)

# Or in systemd service:
# [Service]
# CPUAffinity=0 1

# For NUMA systems, keep Redis on one NUMA node
numactl --cpunodebind=0 --membind=0 redis-server /etc/redis/redis.conf
```

---

## Benchmarking

Use `redis-benchmark` to establish baselines and validate tuning changes.

```bash
# Default benchmark (100K requests, 50 clients)
redis-benchmark -h localhost -p 6379

# Specific operations with pipeline
redis-benchmark -t set,get,lpush,zadd -n 1000000 -P 16 -c 100 -q

# Custom pipeline comparison
redis-benchmark -t set -n 100000 -P 1 -q    # no pipeline
redis-benchmark -t set -n 100000 -P 16 -q   # pipeline 16
redis-benchmark -t set -n 100000 -P 64 -q   # pipeline 64

# With specific key size and value size
redis-benchmark -t set -n 100000 -d 1024 -r 100000 -q

# Cluster mode
redis-benchmark -h node1 -p 6379 --cluster -t set,get -n 100000 -q
```

**Interpreting results:**
- Compare pipeline vs non-pipeline throughput (expect 5-10x improvement)
- Check p50/p99 latencies, not just throughput
- Run during representative load conditions
- Test with realistic key/value sizes

---

## Performance Checklist

### Client-Side
- [ ] Connection pooling enabled with appropriate pool size
- [ ] Pipelining used for batch operations (100-1000 commands)
- [ ] MULTI/EXEC used only when atomicity is required
- [ ] Blocking commands on dedicated connections
- [ ] Client-side caching enabled for hot keys (RESP3)
- [ ] Retry logic with exponential backoff

### Server Configuration
- [ ] `maxmemory` set with appropriate eviction policy
- [ ] `maxmemory-samples` set to 10 for accurate eviction
- [ ] `io-threads` enabled if high connection count (Redis 6+)
- [ ] `tcp-backlog` matches kernel `somaxconn`
- [ ] `tcp-keepalive` set to 60
- [ ] `timeout` configured to close idle connections
- [ ] `lazyfree-lazy-*` options enabled for async cleanup

### Memory
- [ ] Encoding thresholds tuned for data profile
- [ ] Hash bucketing used for millions of small values
- [ ] TTLs set on all cache keys
- [ ] Active defragmentation enabled for long-running instances
- [ ] Key names are concise
- [ ] `UNLINK` used instead of `DEL` for large keys

### Persistence
- [ ] `appendfsync everysec` (not `always` unless required)
- [ ] `no-appendfsync-on-rewrite yes` to reduce rewrite spikes
- [ ] RDB frequency appropriate for dataset size
- [ ] `aof-use-rdb-preamble yes` for faster recovery
- [ ] Persistence disabled entirely for pure cache workloads

### Operating System
- [ ] `vm.overcommit_memory = 1`
- [ ] Transparent Huge Pages disabled
- [ ] File descriptor limits raised (65536+)
- [ ] `net.core.somaxconn` matches `tcp-backlog`
- [ ] `vm.swappiness = 1`
- [ ] Redis pinned to CPU cores (if dedicated server)
- [ ] NUMA awareness configured (if applicable)
