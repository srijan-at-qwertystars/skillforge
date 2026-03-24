# Redis Operations Guide

## Table of Contents

- [Deployment Topologies](#deployment-topologies)
  - [Standalone](#standalone)
  - [Sentinel (High Availability)](#sentinel-high-availability)
  - [Cluster (Horizontal Scaling)](#cluster-horizontal-scaling)
  - [Topology Decision Matrix](#topology-decision-matrix)
- [Capacity Planning](#capacity-planning)
- [Memory Estimation](#memory-estimation)
- [CONFIG Tuning](#config-tuning)
- [Monitoring](#monitoring)
  - [INFO Command](#info-command)
  - [SLOWLOG](#slowlog)
  - [LATENCY Monitoring](#latency-monitoring)
  - [redis-cli --stat](#redis-cli---stat)
  - [Prometheus Exporter](#prometheus-exporter)
- [Backup Strategies](#backup-strategies)
  - [RDB Snapshots](#rdb-snapshots)
  - [AOF Backups](#aof-backups)
  - [Replication-Based Backup](#replication-based-backup)
- [Upgrades](#upgrades)
- [Security Hardening](#security-hardening)
  - [ACLs](#acls)
  - [TLS](#tls)
  - [Network Security](#network-security)
  - [Command Restrictions](#command-restrictions)
- [Docker and Kubernetes Patterns](#docker-and-kubernetes-patterns)

---

## Deployment Topologies

### Standalone

Single Redis instance. Simplest to operate.

```
┌──────────────┐
│   App Pool   │──────▶│ Redis Primary │
└──────────────┘       └───────────────┘
```

- **When**: Dev/staging, small datasets (<25GB), latency-insensitive workloads
- **Availability**: None — single point of failure
- **Scaling**: Vertical only (bigger machine)
- **Persistence**: RDB + AOF on the single instance

### Sentinel (High Availability)

Primary with replicas, monitored by Sentinel quorum for automatic failover.

```
┌──────────────┐       ┌────────────────┐
│   App Pool   │──────▶│ Redis Primary  │───repl──▶│ Replica 1 │
└──────────────┘       └────────────────┘           │ Replica 2 │
        │                      ▲                    └───────────┘
        │              ┌───────┴────────┐
        └─────────────▶│  Sentinel x3   │ (discover primary)
                       └────────────────┘
```

- **When**: Production HA needed, dataset fits one machine, write volume fits one primary
- **Availability**: Automatic failover (10-30s detection + promotion)
- **Scaling**: Read replicas for read scaling. Writes only on primary.
- **Minimum**: 1 primary + 2 replicas + 3 Sentinels (across 3 failure domains)

### Cluster (Horizontal Scaling)

Data sharded across multiple primaries by hash slot. Each primary has replicas.

```
┌──────────────┐
│   App Pool   │──▶ Cluster-aware client
└──────────────┘
        │
   ┌────┴─────┬────────────┐
   ▼          ▼            ▼
┌──────┐  ┌──────┐  ┌──────┐
│Shard1│  │Shard2│  │Shard3│   (primaries, 16384 slots split)
│+repl │  │+repl │  │+repl │   (each has 1+ replica)
└──────┘  └──────┘  └──────┘
```

- **When**: Dataset exceeds single-machine memory, need write scalability
- **Availability**: Built-in (replicas auto-promote within shard)
- **Scaling**: Add shards to increase capacity. Resharding online.
- **Minimum**: 3 primaries + 3 replicas (6 nodes)
- **Caveats**: Multi-key operations require same hash slot (use `{hash tags}`)

### Topology Decision Matrix

| Requirement | Standalone | Sentinel | Cluster |
|------------|-----------|----------|---------|
| Dataset < 25GB | ✅ | ✅ | Overkill |
| Dataset > 25GB | ❌ | ❌ (single node) | ✅ |
| Auto-failover | ❌ | ✅ | ✅ |
| Write scaling | ❌ | ❌ | ✅ |
| Read scaling | ❌ | ✅ (replicas) | ✅ |
| Multi-key ops | ✅ | ✅ | Hash tag only |
| Operational complexity | Low | Medium | High |
| Minimum nodes | 1 | 6 (1+2+3) | 6 (3+3) |

---

## Capacity Planning

### Key Metrics to Size

1. **Peak memory usage**: max dataset size + overhead (~20% for fragmentation + metadata)
2. **Peak connections**: concurrent clients × connection pool size per app instance
3. **Peak ops/sec**: benchmark with realistic payload and command mix
4. **Network bandwidth**: `(avg_value_size × ops_per_sec × 2)` for reads (request + response)
5. **Persistence overhead**: RDB fork needs ~2× memory briefly; AOF rewrite similar

### Sizing Rules of Thumb

```
Max memory per instance: 25GB (for reasonable fork times)
maxmemory = available_RAM × 0.70   (leave room for fork, OS, buffers)
Connections: maxclients = 10000 (each connection ~10KB overhead)
Network: 1Gbps ≈ ~100K ops/sec with 1KB values
CPU: single core handles ~100K simple ops/sec (GET/SET)
```

### Cluster Sizing

```
shards_needed = ceil(total_dataset_size / max_memory_per_shard)
total_nodes = shards_needed × (1 + replicas_per_shard)

Example: 100GB dataset, 25GB per shard, 1 replica each:
  shards = ceil(100/25) = 4 primaries
  total = 4 × 2 = 8 nodes
  slots per shard = 16384 / 4 = 4096
```

---

## Memory Estimation

### Per-Key Overhead

Every key has metadata overhead beyond the value itself:

| Component | Approximate Size |
|-----------|-----------------|
| Key dict entry | ~70 bytes |
| Expiry dict entry (if TTL set) | ~40 bytes |
| RedisObject header | 16 bytes |
| SDS string (small key name) | len + 9 bytes |

A key with a small string value (e.g., 10 bytes) uses ~140 bytes total.

### Estimating by Data Structure

```python
# Rough estimation formulas (jemalloc, 64-bit)

# String: ~90 + len(key) + len(value) bytes
# With TTL: add ~40 bytes

# Hash (listpack, <128 fields, values <64 bytes):
#   ~90 + len(key) + sum(len(field) + len(value) + 2) for all fields
# Hash (hashtable, large): ~90 + len(key) + num_fields × (70 + len(field) + len(value))

# Sorted Set (listpack, <128 members):
#   similar to hash listpack
# Sorted Set (skiplist, large): ~90 + len(key) + num_members × (90 + len(member))

# Set (listpack or intset for integers):
#   Intset: ~90 + len(key) + num_members × 8
#   Hashtable: ~90 + len(key) + num_members × (70 + len(member))

# List (listpack): ~90 + len(key) + sum(len(element) + 11)
# List (quicklist): similar but with node overhead per ziplist
```

### Practical Estimation

```bash
# Best approach: load sample data and measure
redis-cli DBSIZE
redis-cli INFO memory | grep used_memory_human

# Per-key measurement
redis-cli MEMORY USAGE <key> SAMPLES 5

# Extrapolate
# avg_key_memory = used_memory / dbsize
# total_estimate = avg_key_memory × expected_total_keys
```

---

## CONFIG Tuning

### Critical Production Settings

```conf
# Memory
maxmemory 4gb                          # MUST set — prevent OOM kill
maxmemory-policy allkeys-lfu           # or allkeys-lru for caches

# Networking
bind 0.0.0.0                           # or specific IPs
protected-mode yes                     # reject external if no auth
tcp-backlog 511                        # raise for high connection rate: 511 → 2048
tcp-keepalive 300                      # detect dead connections
timeout 0                             # 0=never close idle (set >0 if connection leaks)

# Performance
hz 10                                  # server tick rate (10=default, up to 100 for latency)
dynamic-hz yes                         # auto-adjust hz based on load
io-threads 4                           # I/O threads for network (Redis 6+, 0=disabled)
io-threads-do-reads yes                # also thread reads (not just writes)

# Persistence
save 3600 1 300 100 60 10000           # RDB save points
appendonly yes                         # enable AOF
appendfsync everysec                   # good balance
no-appendfsync-on-rewrite yes          # prevent fsync during rewrite
aof-use-rdb-preamble yes               # hybrid persistence
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# Replication
repl-backlog-size 256mb                # prevent full resync on short disconnects
repl-backlog-ttl 3600
min-replicas-to-write 1               # prevent split-brain writes
min-replicas-max-lag 10
replica-lazy-flush yes                 # async flush on full resync

# Slow log
slowlog-log-slower-than 10000          # 10ms threshold
slowlog-max-len 128                    # keep last 128 slow commands

# Latency monitoring
latency-monitor-threshold 50           # track events >50ms

# Encoding thresholds (memory optimization)
hash-max-listpack-entries 128
hash-max-listpack-value 64
list-max-listpack-size -2              # 8KB per node
zset-max-listpack-entries 128
zset-max-listpack-value 64
set-max-intset-entries 512
set-max-listpack-entries 128

# Lazy free (async delete for large keys)
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
lazyfree-lazy-user-del yes
lazyfree-lazy-user-flush yes

# Active defragmentation (jemalloc only)
activedefrag yes
active-defrag-ignore-bytes 100mb
active-defrag-threshold-lower 10
active-defrag-threshold-upper 100
active-defrag-cycle-min 1
active-defrag-cycle-max 25
```

### OS Tuning (Linux)

```bash
# /etc/sysctl.conf
vm.overcommit_memory = 1          # required for fork() during BGSAVE
vm.swappiness = 0                 # avoid swapping Redis memory
net.core.somaxconn = 65535        # match tcp-backlog
net.ipv4.tcp_max_syn_backlog = 65535

# Disable Transparent Huge Pages
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
# Make persistent: add to /etc/rc.local or systemd unit

# File descriptors
ulimit -n 65535    # for maxclients + internal FDs
# /etc/security/limits.conf:
# redis soft nofile 65535
# redis hard nofile 65535
```

---

## Monitoring

### INFO Command

```redis
-- Sections: server, clients, memory, persistence, stats, replication, cpu, modules, keyspace
INFO                    -- all sections
INFO memory             -- just memory
INFO stats              -- command statistics
INFO replication        -- replication status

-- Key metrics to watch:
INFO memory
-- used_memory_human          → actual memory used
-- used_memory_rss_human      → RSS from OS
-- mem_fragmentation_ratio    → target 1.0-1.5
-- maxmemory_human            → configured limit

INFO stats
-- instantaneous_ops_per_sec  → current throughput
-- total_commands_processed   → total commands (for rate)
-- keyspace_hits/misses       → cache hit ratio
-- evicted_keys               → evictions (should be 0 or low for non-cache)
-- expired_keys               → expirations

INFO clients
-- connected_clients          → current connections
-- blocked_clients            → clients in blocking commands
-- maxclients                 → connection limit

INFO persistence
-- rdb_last_bgsave_status     → ok/err
-- aof_last_bgrewriteaof_status → ok/err
-- rdb_last_save_time         → Unix timestamp of last save

INFO replication
-- role                       → master or slave
-- connected_slaves           → replica count
-- master_repl_offset         → replication position
```

### SLOWLOG

```redis
SLOWLOG GET 25                          -- last 25 slow commands
SLOWLOG LEN                             -- total entries
SLOWLOG RESET                           -- clear

-- Each entry: [id, timestamp, duration_us, [command, args...], client_ip, client_name]
-- Example output:
-- 1) 1) (integer) 14                   -- entry ID
--    2) (integer) 1705334400           -- Unix timestamp
--    3) (integer) 15230               -- duration: 15.23ms
--    4) 1) "KEYS"                     -- command
--       2) "user:*"                   -- args
--    5) "10.0.0.5:43210"             -- client
--    6) "web-app"                     -- client name

CONFIG SET slowlog-log-slower-than 5000   -- lower threshold to 5ms
CONFIG SET slowlog-max-len 256            -- keep more entries
```

### LATENCY Monitoring

```redis
CONFIG SET latency-monitor-threshold 50   -- track events taking >50ms

LATENCY LATEST                            -- most recent event per type
-- fork, aof-fsync-always, aof-write, rdb-unlink, expire-cycle, eviction-cycle, command

LATENCY HISTORY <event-name>              -- time series of an event type
LATENCY HISTORY fork
LATENCY HISTORY command

LATENCY GRAPH <event-name>               -- ASCII graph
LATENCY GRAPH fork

LATENCY RESET                            -- clear all latency data
```

### redis-cli --stat

```bash
# Real-time stats dashboard (updates every second)
redis-cli --stat
# Output: keys, mem, clients, blocked, requests, connections

redis-cli --stat -i 5                   # update every 5 seconds

# Other useful one-liners
redis-cli --bigkeys                     # scan for large keys
redis-cli --memkeys                     # scan for memory-heavy keys
redis-cli --hotkeys                     # scan for frequently accessed keys (needs LFU)
redis-cli --latency                     # continuous latency measurement
redis-cli --latency-history -i 10       # latency over time
redis-cli --latency-dist                # latency distribution (spectrum)
redis-cli --intrinsic-latency 5         # baseline system latency (5s test)
```

### Prometheus Exporter

Use [oliver006/redis_exporter](https://github.com/oliver006/redis_exporter) — the standard Prometheus exporter for Redis.

```yaml
# docker-compose addition
redis-exporter:
  image: oliver006/redis_exporter:latest
  ports:
    - "9121:9121"
  environment:
    REDIS_ADDR: "redis://redis:6379"
    REDIS_PASSWORD: "${REDIS_PASSWORD}"
  command:
    - "--include-system-metrics"
    - "--check-keys=queue:*"        # monitor specific key patterns
    - "--check-single-keys=config:app"

# prometheus.yml scrape config
scrape_configs:
  - job_name: redis
    static_configs:
      - targets: ['redis-exporter:9121']
```

**Key Prometheus Metrics to Alert On**:

```yaml
# Alert rules (Prometheus alerting)
groups:
  - name: redis
    rules:
      - alert: RedisDown
        expr: redis_up == 0
        for: 1m

      - alert: RedisMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
        for: 5m

      - alert: RedisHighFragmentation
        expr: redis_mem_fragmentation_ratio > 1.5
        for: 10m

      - alert: RedisRejectedConnections
        expr: increase(redis_rejected_connections_total[5m]) > 0

      - alert: RedisReplicationBroken
        expr: redis_connected_slaves < 1
        for: 1m

      - alert: RedisTooManyConnections
        expr: redis_connected_clients / redis_config_maxclients > 0.8
        for: 5m

      - alert: RedisHighEvictionRate
        expr: rate(redis_evicted_keys_total[5m]) > 100

      - alert: RedisSlowlogGrowing
        expr: increase(redis_slowlog_length[5m]) > 10
```

---

## Backup Strategies

### RDB Snapshots

```bash
# Trigger manual snapshot
redis-cli BGSAVE
# Check status
redis-cli LASTSAVE   # Unix timestamp of last successful save

# Copy RDB file
BACKUP_DIR="/backups/redis/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"
RDB_PATH=$(redis-cli CONFIG GET dir | tail -1)/$(redis-cli CONFIG GET dbfilename | tail -1)
cp "$RDB_PATH" "$BACKUP_DIR/dump-$(date +%H%M%S).rdb"

# Verify RDB integrity
redis-check-rdb "$BACKUP_DIR/dump-*.rdb"

# Restore: stop Redis, replace dump.rdb, restart
```

**Schedule**: Cron job for regular backups. Copy to remote storage (S3, GCS).

```bash
# crontab example
0 */6 * * * /opt/redis/scripts/backup-rdb.sh >> /var/log/redis-backup.log 2>&1
```

### AOF Backups

```bash
# Trigger AOF rewrite (compaction) before backup
redis-cli BGREWRITEAOF
# Wait for completion
while [ "$(redis-cli INFO persistence | grep aof_rewrite_in_progress | tr -d '\r' | cut -d: -f2)" = "1" ]; do
  sleep 1
done
# Copy AOF file
cp /var/lib/redis/appendonly.aof "$BACKUP_DIR/"

# Verify AOF integrity
redis-check-aof /var/lib/redis/appendonly.aof
# Fix if corrupted (truncates at first error):
redis-check-aof --fix /var/lib/redis/appendonly.aof
```

### Replication-Based Backup

Safest approach — backup from replica to avoid impacting primary.

```bash
# On replica:
redis-cli -h replica BGSAVE
# Copy RDB from replica
scp replica:/var/lib/redis/dump.rdb "$BACKUP_DIR/"

# Or: spin up a temporary replica just for backups
redis-server --port 6380 --replicaof primary-host 6379 --dbfilename backup.rdb
# Wait for sync, then stop the temporary replica
```

---

## Upgrades

### Rolling Upgrade (Zero Downtime)

For Sentinel and Cluster deployments:

1. **Upgrade replicas first** (one at a time):
   ```bash
   # On each replica:
   redis-cli SHUTDOWN NOSAVE
   # Install new Redis version
   redis-server /etc/redis/redis.conf
   # Verify replication resumes:
   redis-cli INFO replication | grep master_link_status  # should be "up"
   ```

2. **Failover the primary**:
   ```bash
   # Sentinel:
   redis-cli -p 26379 SENTINEL failover mymaster
   # Cluster:
   redis-cli -h replica CLUSTER FAILOVER
   ```

3. **Upgrade the old primary** (now a replica):
   ```bash
   redis-cli SHUTDOWN NOSAVE
   # Install new Redis version
   redis-server /etc/redis/redis.conf
   ```

4. **Verify**:
   ```bash
   redis-cli INFO server | grep redis_version
   redis-cli INFO replication
   redis-cli CLUSTER INFO  # for Cluster
   ```

### Version Compatibility
- Redis replication is forward-compatible: newer replicas can replicate from older primaries
- RDB format is backward-compatible within major versions
- Always read release notes for breaking changes
- Test upgrades in staging with production-like data

---

## Security Hardening

### ACLs

Redis 6.0+ introduced fine-grained Access Control Lists.

```redis
-- Create users with specific permissions
ACL SETUSER app-readonly on >secure-password-here ~cache:* ~session:* &* +get +mget +hgetall +info +ping -@dangerous
-- on: enable user
-- >password: set password
-- ~pattern: allowed key patterns
-- &channel: allowed pub/sub channels
-- +command: allowed commands
-- -@category: deny command category

ACL SETUSER app-readwrite on >another-password ~app:* +@read +@write +@set +@sortedset -@admin -@dangerous

ACL SETUSER admin on >admin-password ~* &* +@all

-- Disable default user (important!)
ACL SETUSER default off

-- View/manage ACLs
ACL LIST                    -- list all users and rules
ACL GETUSER app-readonly    -- user details
ACL WHOAMI                  -- current user
ACL CAT                     -- list command categories
ACL CAT dangerous           -- commands in "dangerous" category
ACL LOG 10                  -- last 10 auth failures or ACL violations
ACL SAVE                    -- persist to ACL file

-- ACL file (/etc/redis/users.acl)
-- user app-readonly on >password ~cache:* +get +mget +hgetall
-- user default off
```

### TLS

```conf
# redis.conf - TLS configuration
tls-port 6380                          # TLS port (0 to disable non-TLS)
port 0                                 # disable non-TLS port

tls-cert-file /etc/redis/tls/redis.crt
tls-key-file /etc/redis/tls/redis.key
tls-ca-cert-file /etc/redis/tls/ca.crt

tls-auth-clients optional             # "yes" = require client certs
tls-protocols "TLSv1.2 TLSv1.3"       # minimum TLS version
tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256

# Replication over TLS
tls-replication yes

# Cluster bus over TLS
tls-cluster yes
```

```bash
# Connect with TLS
redis-cli --tls --cert /etc/redis/tls/client.crt --key /etc/redis/tls/client.key \
  --cacert /etc/redis/tls/ca.crt -h redis.example.com -p 6380
```

### Network Security

```conf
# redis.conf
bind 10.0.0.1 127.0.0.1               # bind to specific interfaces only
protected-mode yes                     # reject connections without auth from non-loopback

# Require authentication
requirepass <strong-password>          # legacy (pre-ACL) auth
# Or use ACLs (preferred for Redis 6+)
```

```bash
# Firewall rules (iptables)
iptables -A INPUT -p tcp --dport 6379 -s 10.0.0.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 6379 -j DROP

# Or with security groups / VPC (cloud):
# Allow port 6379 only from application subnet
```

### Command Restrictions

```conf
# redis.conf — rename dangerous commands
rename-command FLUSHDB ""              # disable completely
rename-command FLUSHALL ""
rename-command KEYS ""
rename-command DEBUG ""
rename-command CONFIG "CONFIG-b9a12f"  # rename to obscure name
rename-command SHUTDOWN "SHUTDOWN-x7k" # prevent accidental shutdown

# Or use ACLs (preferred):
ACL SETUSER app on >password ~* -@dangerous -FLUSHDB -FLUSHALL -KEYS -DEBUG
```

---

## Docker and Kubernetes Patterns

### Docker Single Instance

```bash
# Quick dev instance
docker run -d --name redis \
  -p 6379:6379 \
  -v redis-data:/data \
  redis:7-alpine \
  redis-server --appendonly yes --maxmemory 256mb

# With custom config
docker run -d --name redis \
  -p 6379:6379 \
  -v redis-data:/data \
  -v /path/to/redis.conf:/usr/local/etc/redis/redis.conf \
  redis:7-alpine \
  redis-server /usr/local/etc/redis/redis.conf
```

### Docker Redis Stack (with modules)

```bash
docker run -d --name redis-stack \
  -p 6379:6379 -p 8001:8001 \
  -v redis-data:/data \
  -e REDIS_ARGS="--maxmemory 512mb --appendonly yes" \
  redis/redis-stack:latest
# Port 8001 = RedisInsight UI
```

### Kubernetes StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
spec:
  serviceName: redis
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
          command: ["redis-server", "/etc/redis/redis.conf"]
          volumeMounts:
            - name: data
              mountPath: /data
            - name: config
              mountPath: /etc/redis
          resources:
            requests:
              memory: "1Gi"
              cpu: "500m"
            limits:
              memory: "2Gi"
              cpu: "1"
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 15
            periodSeconds: 20
      volumes:
        - name: config
          configMap:
            name: redis-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  clusterIP: None    # headless for StatefulSet
  ports:
    - port: 6379
  selector:
    app: redis
```

### Kubernetes Tips

- **StatefulSet** for persistent data (stable pod names, persistent volumes)
- **Never use Deployment** for Redis with persistence (PVCs won't rebind correctly)
- Set `resources.limits.memory` to `maxmemory × 1.5` (account for fork, buffers)
- Use **anti-affinity** rules to spread replicas across nodes
- For production, consider **Redis Operator** (e.g., Spotahome redis-operator, OpsTree redis-operator)
- Disable THP in the node's init container or DaemonSet
- Use `sysctls` security context for `net.core.somaxconn`

```yaml
# Anti-affinity example
spec:
  template:
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: redis
              topologyKey: kubernetes.io/hostname
```
