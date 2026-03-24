# Valkey/Redis Production Guide

## Table of Contents

- [Sizing and Capacity Planning](#sizing-and-capacity-planning)
- [Monitoring](#monitoring)
- [Backup Strategies](#backup-strategies)
- [Upgrade Procedures](#upgrade-procedures)
- [Security](#security)
- [Performance Tuning](#performance-tuning)
- [Docker and Kubernetes Deployment](#docker-and-kubernetes-deployment)

---

## Sizing and Capacity Planning

### Memory Estimation

Rule of thumb: allocate **2x the raw data size** for overhead (pointers, metadata, fragmentation).

```
Per-key overhead:
  - String key: ~90 bytes (key + value metadata + dictEntry)
  - Hash (ziplist, <128 entries): ~60 bytes + data
  - Hash (hashtable): ~90 bytes per field
  - Set (intset, all integers): ~16 bytes per member
  - Set (hashtable): ~80 bytes per member
  - Sorted set (ziplist): ~30 bytes per member
  - Sorted set (skiplist): ~100 bytes per member
  - Stream entry: ~100-200 bytes per entry
```

### Capacity Formula

```
total_memory = (num_keys × per_key_overhead) + (avg_value_size × num_keys)
maxmemory = total_memory × 1.3   (30% headroom for fragmentation + fork)
server_ram = maxmemory / 0.75    (25% reserved for OS + fork COW pages)
```

### Example Sizing

| Use Case | Keys | Avg Value | Estimated Memory | Recommended RAM |
|----------|------|-----------|------------------|-----------------|
| Session store | 1M | 500B | ~1.5 GB | 4 GB |
| Cache layer | 10M | 1 KB | ~20 GB | 32 GB |
| Leaderboard | 5M | 50B | ~1 GB | 2 GB |
| Rate limiter | 500K | 100B | ~200 MB | 1 GB |

### CPU Sizing

- Single-threaded command processing (Redis ≤7, Valkey <8)
- Valkey 8+ supports `io-threads` for multi-threaded I/O
- 1 core handles ~100K-200K ops/sec for simple commands
- Complex Lua scripts or large `SORT` reduce throughput significantly
- Budget additional cores for: background saves, AOF rewrite, cluster gossip

### Network Bandwidth

```
bandwidth = ops_per_sec × (avg_request_size + avg_response_size)
Example: 100K ops/sec × (200B + 500B) = ~70 MB/s = 560 Mbps
```

Ensure 1 Gbps+ NIC for production workloads.

---

## Monitoring

### Essential INFO Sections

```redis
INFO server         # version, uptime, config_file
INFO clients        # connected_clients, blocked_clients, maxclients
INFO memory         # used_memory, fragmentation_ratio, peak
INFO stats          # total_commands, keyspace_hits/misses, expired_keys, evicted_keys
INFO replication    # role, connected_slaves, repl_offset
INFO persistence    # rdb_last_save, aof_rewrite_in_progress
INFO keyspace       # db0:keys=1000,expires=500,avg_ttl=3600
INFO commandstats   # per-command call count, usec, rejected_calls
```

### Key Metrics to Alert On

| Metric | Warning | Critical | Source |
|--------|---------|----------|--------|
| `used_memory` / `maxmemory` | >75% | >90% | `INFO memory` |
| `mem_fragmentation_ratio` | >1.5 | >2.0 | `INFO memory` |
| `connected_clients` / `maxclients` | >75% | >90% | `INFO clients` |
| `evicted_keys` (rate) | >0 (for non-cache) | Increasing | `INFO stats` |
| Cache hit ratio | <90% | <80% | `keyspace_hits / (hits+misses)` |
| `master_link_status` | — | `down` | `INFO replication` (replica) |
| `rdb_last_save_time` age | >1h | >4h | `INFO persistence` |
| Latency p99 | >5ms | >20ms | `LATENCY LATEST` |
| `rejected_connections` | >0 | Increasing | `INFO stats` |
| `instantaneous_ops_per_sec` | — | Drop >50% | `INFO stats` |

### Latency Tracking

```redis
CONFIG SET latency-monitor-threshold 5   # log events >5ms
LATENCY LATEST                           # most recent spikes
LATENCY HISTORY event-name               # per-event history
LATENCY GRAPH event-name                 # ASCII graph

-- Events to watch: command, fast-command, fork, aof-write, rdb-save,
-- aof-rewrite, expire-cycle, eviction-cycle
```

### Using MONITOR Safely

```bash
# NEVER run MONITOR in production long-term (50% perf hit)
# For short debugging sessions only:
timeout 10 valkey-cli MONITOR | head -500 > /tmp/monitor.log
```

### Prometheus + Grafana

Use `redis_exporter` (works with Valkey). Key PromQL queries:

```promql
redis_memory_used_bytes / redis_memory_max_bytes                                    # memory util
rate(redis_keyspace_hits_total[5m]) / (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))  # hit ratio
histogram_quantile(0.99, rate(redis_commands_duration_seconds_bucket[5m]))           # p99 latency
```

---

## Backup Strategies

### Backup

```bash
valkey-cli BGSAVE && valkey-cli LASTSAVE    # trigger + verify
cp /var/lib/valkey/dump.rdb /backup/dump-$(date +%Y%m%d-%H%M%S).rdb
```

Automate: trigger `BGSAVE`, wait for `LASTSAVE` to change, copy RDB, `find -mtime +7 -delete` for retention. For AOF: copy `appendonlydir/`. Test restores weekly.

---

## Upgrade Procedures

### In-Place Upgrade (Single Instance)

1. **Backup**: `BGSAVE`, copy RDB file
2. **Check compatibility**: Review release notes for breaking changes
3. **Stop server**: `valkey-cli SHUTDOWN SAVE`
4. **Install new binary**: Package manager or binary swap
5. **Start server**: New binary loads existing RDB/AOF
6. **Verify**: `INFO server` for version, `DBSIZE` for data

### Rolling Upgrade (Cluster)

1. Upgrade replicas first (one at a time)
2. Failover each master to its upgraded replica: `CLUSTER FAILOVER`
3. Upgrade old masters (now replicas)
4. Verify cluster health: `CLUSTER INFO`, `CLUSTER NODES`

### Rolling Upgrade (Sentinel)

1. Upgrade Sentinel nodes one at a time
2. Upgrade replicas one at a time
3. Trigger manual failover: `SENTINEL FAILOVER mymaster`
4. Upgrade old master (now replica)

### Migrating Redis → Valkey

Valkey is a drop-in replacement for Redis ≤7.2.4. Migration steps:

1. **Assess compatibility**: Valkey 7.2.x matches Redis 7.2.4 commands
2. **Test in staging**: Run Valkey with a copy of production data
3. **Update config**: Rename `redis.conf` → `valkey.conf` (optional, both work)
4. **Swap binary**: Replace `redis-server` with `valkey-server`
5. **Update CLI tools**: `redis-cli` → `valkey-cli` (both work)
6. **Update client libraries** (optional): `redis-py` → `valkey-py`, etc.
7. **Update monitoring**: Adjust dashboards for Valkey metrics (mostly identical)

```bash
# Binary swap (systemd)
sudo systemctl stop redis
sudo cp /usr/local/bin/valkey-server /usr/local/bin/redis-server  # symlink approach
sudo systemctl start redis
# Or update the systemd unit file to use valkey-server directly
```

---

## Security

### Authentication (ACLs)

```redis
ACL SETUSER app-readonly on >strongpassword ~cache:* &* +@read
ACL SETUSER app-writer on >anotherpassword ~* &* +@all -@dangerous
ACL SETUSER admin on >adminpassword ~* &* +@all

# Namespace-scoped user
ACL SETUSER service-a on >pass ~service-a:* &* +@all -@dangerous
```

### TLS Encryption

```
tls-port 6380
port 0                              # disable non-TLS port
tls-cert-file /etc/valkey/tls/server.crt
tls-key-file /etc/valkey/tls/server.key
tls-ca-cert-file /etc/valkey/tls/ca.crt
tls-replication yes                 # replication over TLS
tls-cluster yes                     # cluster bus over TLS
```

### Network Security

```
# Bind to specific interfaces
bind 10.0.0.1 127.0.0.1

# Enable protected mode (reject external connections without auth)
protected-mode yes

# Rename dangerous commands (legacy approach — prefer ACLs)
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command DEBUG ""
rename-command CONFIG "CONFIG_b4d8f2a1"
```

### Security Checklist

- [ ] Set strong `requirepass` or use ACLs
- [ ] Bind to private interfaces only
- [ ] Enable `protected-mode yes`
- [ ] Use TLS for cross-network traffic
- [ ] Disable or rename dangerous commands
- [ ] Run as non-root user
- [ ] Use firewall rules to restrict port access
- [ ] Rotate passwords/certificates periodically
- [ ] Enable audit logging (if available)
- [ ] Regularly update to latest stable version

---

## Performance Tuning

### maxmemory-policy Selection

| Policy | Use Case |
|--------|----------|
| `allkeys-lru` | General-purpose cache (recommended default) |
| `allkeys-lfu` | Skewed access patterns (few hot keys) |
| `volatile-lru` | Mix of cache (with TTL) and persistent data (no TTL) |
| `volatile-ttl` | Evict soonest-expiring first |
| `noeviction` | Queues, persistent data — errors when full |

```redis
CONFIG SET maxmemory-policy allkeys-lru
CONFIG SET maxmemory-samples 10            # higher = more accurate LRU (default 5)
```

### TCP and Networking

Set `tcp-backlog 511`, `tcp-keepalive 60`. Ensure `net.core.somaxconn ≥ 511`.

### I/O Threads (Valkey 8+ / Redis 6+)

```
io-threads 4                       # cores minus 1 for main thread
io-threads-do-reads yes
```

2-3x throughput for network-bound workloads. No benefit for CPU-bound (Lua, complex commands).

### Lazy Freeing

Enable all: `lazyfree-lazy-eviction yes`, `lazyfree-lazy-expire yes`, `lazyfree-lazy-server-del yes`, `lazyfree-lazy-user-del yes`, `replica-lazy-flush yes`.

Verify jemalloc allocator: `INFO memory | grep mem_allocator`. Enable `jemalloc-bg-thread yes`.

### Pipeline and Connection Optimization

```
# Client output buffer limits
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 512mb 128mb 60
client-output-buffer-limit pubsub 32mb 8mb 60

# Close idle connections
timeout 300
```

### Persistence Tuning

Pure cache: `save ""`, `appendonly no`. With persistence: `aof-use-rdb-preamble yes`, `appendfsync everysec`, `no-appendfsync-on-rewrite yes`.

### Benchmarking

```bash
valkey-benchmark -h 127.0.0.1 -c 50 -n 100000 -t set,get -d 256 -P 16 --csv
# -c: connections, -n: requests, -d: value size, -P: pipeline depth
```

---

## Docker and Kubernetes Deployment

### Docker

See `assets/docker-compose.yml` for full standalone, Sentinel, and cluster Docker Compose configurations.

```dockerfile
FROM valkey/valkey:8-alpine
COPY valkey.conf /etc/valkey/valkey.conf
CMD ["valkey-server", "/etc/valkey/valkey.conf"]
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD valkey-cli ping | grep PONG || exit 1
```

### Kubernetes

Use a **StatefulSet** with 3 replicas, PVCs for data, readiness/liveness probes (`valkey-cli ping`). Set resource requests (memory: 1Gi, cpu: 500m) and limits (memory: 2Gi).

**Operators**: Spotahome Redis Operator, OpsTree Redis Operator, Bitnami Helm charts, Valkey Operator (emerging).

### Container Best Practices

1. Set `maxmemory` to 75% of container memory limit (K8s OOM-kills at limit)
2. Disable THP: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`
3. Set `vm.overcommit_memory=1` via sysctl or init container
4. Use local SSDs for persistence (avoid network storage for AOF)
5. Use pod anti-affinity to spread replicas across nodes
6. Always set memory limits; CPU limits optional (can cause throttling)
