# Redis Cluster Setup Guide

Step-by-step guide to deploying a production Redis Cluster with 6 nodes
(3 masters + 3 replicas) for high availability and horizontal scaling.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Architecture Overview](#architecture-overview)
3. [Node Configuration](#node-configuration)
4. [Starting the Nodes](#starting-the-nodes)
5. [Creating the Cluster](#creating-the-cluster)
6. [Verifying the Cluster](#verifying-the-cluster)
7. [Client Configuration](#client-configuration)
8. [Operations](#operations)
9. [Adding and Removing Nodes](#adding-and-removing-nodes)
10. [Monitoring](#monitoring)
11. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **6 hosts/VMs/containers** (minimum for production — 3 masters + 3 replicas)
- Redis 7.x+ installed on all nodes
- Ports open: **6379** (client) and **16379** (cluster bus = port + 10000)
- Network connectivity between all nodes (low latency, < 1ms recommended)
- Identical Redis versions across all nodes

**Hardware per node (minimum production):**
- 2+ CPU cores
- 4+ GB RAM (adjust for dataset size)
- SSD storage for persistence
- Dedicated network interface

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Redis Cluster                         │
│                                                          │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐           │
│  │ Master 1 │    │ Master 2 │    │ Master 3 │           │
│  │ node1    │    │ node2    │    │ node3    │           │
│  │ :6379    │    │ :6379    │    │ :6379    │           │
│  │ Slots    │    │ Slots    │    │ Slots    │           │
│  │ 0-5460   │    │ 5461-10922│   │10923-16383│          │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘           │
│       │               │               │                  │
│  ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐           │
│  │ Replica 1│    │ Replica 2│    │ Replica 3│           │
│  │ node4    │    │ node5    │    │ node6    │           │
│  │ :6379    │    │ :6379    │    │ :6379    │           │
│  └──────────┘    └──────────┘    └──────────┘           │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## Node Configuration

Create a configuration file for each node. The key cluster-specific settings are:

```bash
# /etc/redis/redis-cluster.conf — per-node configuration

# Basic settings
port 6379
bind 0.0.0.0
protected-mode no
daemonize yes
pidfile /var/run/redis/redis-cluster.pid
logfile /var/log/redis/redis-cluster.log
dir /var/lib/redis

# [REQUIRED] Enable cluster mode
cluster-enabled yes

# Cluster config file (auto-managed by Redis — unique per node)
cluster-config-file nodes-6379.conf

# Node timeout (ms) — how long before a node is considered failing
cluster-node-timeout 15000

# Cluster announce settings (required for NAT/Docker/K8s)
# cluster-announce-ip 10.0.0.1
# cluster-announce-port 6379
# cluster-announce-bus-port 16379

# Memory
maxmemory 4gb
maxmemory-policy allkeys-lru
maxmemory-samples 10

# Persistence
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes

# Security
# requirepass YOUR_CLUSTER_PASSWORD
# masterauth YOUR_CLUSTER_PASSWORD   # same password for replication

# Performance
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
lazyfree-lazy-user-del yes

# Replica settings
replica-serve-stale-data yes
replica-read-only yes
repl-backlog-size 256mb
repl-diskless-sync yes

# Cluster-specific tuning
# cluster-migration-barrier 1       # min replicas a master keeps before migration
# cluster-require-full-coverage yes  # require all slots covered for cluster to work
# cluster-allow-reads-when-down no   # serve reads during partial failure
# cluster-allow-pubsubshard-when-down yes
```

**Important:** Each node must have a unique `cluster-config-file` name if running
multiple instances on the same host.

## Starting the Nodes

### On each node:

```bash
# Start Redis with cluster configuration
redis-server /etc/redis/redis-cluster.conf

# Verify each node is running
redis-cli -h <node-ip> -p 6379 PING
redis-cli -h <node-ip> -p 6379 INFO server | grep redis_mode
# Should output: redis_mode:cluster
```

### Using systemd:

```bash
# Create systemd service override for cluster mode
sudo systemctl edit redis-server
# Add:
# [Service]
# ExecStart=
# ExecStart=/usr/bin/redis-server /etc/redis/redis-cluster.conf

sudo systemctl start redis-server
sudo systemctl enable redis-server
```

### Using Docker Compose (development/testing):

```yaml
# docker-compose.yml
version: '3.8'
services:
  redis-node-1:
    image: redis:7-alpine
    command: redis-server --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000 --appendonly yes --port 6379
    ports: ["6379:6379"]
    volumes: ["redis-data-1:/data"]
  redis-node-2:
    image: redis:7-alpine
    command: redis-server --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000 --appendonly yes --port 6379
    ports: ["6380:6379"]
    volumes: ["redis-data-2:/data"]
  redis-node-3:
    image: redis:7-alpine
    command: redis-server --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000 --appendonly yes --port 6379
    ports: ["6381:6379"]
    volumes: ["redis-data-3:/data"]
  redis-node-4:
    image: redis:7-alpine
    command: redis-server --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000 --appendonly yes --port 6379
    ports: ["6382:6379"]
    volumes: ["redis-data-4:/data"]
  redis-node-5:
    image: redis:7-alpine
    command: redis-server --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000 --appendonly yes --port 6379
    ports: ["6383:6379"]
    volumes: ["redis-data-5:/data"]
  redis-node-6:
    image: redis:7-alpine
    command: redis-server --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000 --appendonly yes --port 6379
    ports: ["6384:6379"]
    volumes: ["redis-data-6:/data"]

volumes:
  redis-data-1:
  redis-data-2:
  redis-data-3:
  redis-data-4:
  redis-data-5:
  redis-data-6:
```

## Creating the Cluster

Once all 6 nodes are running, create the cluster:

```bash
# Create cluster with 3 masters and 3 replicas (1 replica per master)
redis-cli --cluster create \
    10.0.0.1:6379 \
    10.0.0.2:6379 \
    10.0.0.3:6379 \
    10.0.0.4:6379 \
    10.0.0.5:6379 \
    10.0.0.6:6379 \
    --cluster-replicas 1

# If using authentication:
redis-cli --cluster create \
    10.0.0.1:6379 \
    10.0.0.2:6379 \
    10.0.0.3:6379 \
    10.0.0.4:6379 \
    10.0.0.5:6379 \
    10.0.0.6:6379 \
    --cluster-replicas 1 \
    -a YOUR_CLUSTER_PASSWORD
```

**Output will show:**
```
>>> Performing hash slots allocation on 6 nodes...
Master[0] -> Slots 0 - 5460
Master[1] -> Slots 5461 - 10922
Master[2] -> Slots 10923 - 16383
Adding replica 10.0.0.5:6379 to 10.0.0.1:6379
Adding replica 10.0.0.6:6379 to 10.0.0.2:6379
Adding replica 10.0.0.4:6379 to 10.0.0.3:6379
...
Can I set the above configuration? (type 'yes' to accept): yes
```

Type `yes` to confirm.

## Verifying the Cluster

```bash
# Check cluster health
redis-cli --cluster check 10.0.0.1:6379

# Cluster info
redis-cli -h 10.0.0.1 -p 6379 CLUSTER INFO

# Expected output:
# cluster_state:ok
# cluster_slots_assigned:16384
# cluster_slots_ok:16384
# cluster_slots_pfail:0
# cluster_slots_fail:0
# cluster_known_nodes:6
# cluster_size:3

# View all nodes
redis-cli -h 10.0.0.1 -p 6379 CLUSTER NODES

# Test read/write
redis-cli -c -h 10.0.0.1 -p 6379 SET test:key "hello"
redis-cli -c -h 10.0.0.1 -p 6379 GET test:key
# Note: -c flag enables cluster mode (auto-redirect on MOVED errors)

# Test hash tag colocating
redis-cli -c -h 10.0.0.1 -p 6379 MSET "{user:1}:name" "Alice" "{user:1}:email" "a@x.com"
redis-cli -c -h 10.0.0.1 -p 6379 MGET "{user:1}:name" "{user:1}:email"
```

## Client Configuration

### Python (redis-py)

```python
from redis.cluster import RedisCluster

rc = RedisCluster(
    startup_nodes=[
        {"host": "10.0.0.1", "port": 6379},
        {"host": "10.0.0.2", "port": 6379},
        {"host": "10.0.0.3", "port": 6379},
    ],
    # password="YOUR_PASSWORD",
    decode_responses=True,
    read_from_replicas=True,     # load-balance reads to replicas
    retry_on_timeout=True,
)

rc.set("key", "value")
print(rc.get("key"))
```

### Node.js (ioredis)

```javascript
const Redis = require('ioredis');
const cluster = new Redis.Cluster([
  { host: '10.0.0.1', port: 6379 },
  { host: '10.0.0.2', port: 6379 },
  { host: '10.0.0.3', port: 6379 },
], {
  // password: 'YOUR_PASSWORD',
  scaleReads: 'slave',           // read from replicas
  redisOptions: {
    connectTimeout: 5000,
    maxRetriesPerRequest: 3,
  },
});
```

### Java (Jedis)

```java
Set<HostAndPort> nodes = new HashSet<>();
nodes.add(new HostAndPort("10.0.0.1", 6379));
nodes.add(new HostAndPort("10.0.0.2", 6379));
nodes.add(new HostAndPort("10.0.0.3", 6379));

JedisCluster jc = new JedisCluster(nodes, 5000, 5000, 3, "YOUR_PASSWORD",
    new GenericObjectPoolConfig<>());
jc.set("key", "value");
```

## Operations

### Manual Failover

```bash
# Graceful failover (run on the REPLICA you want to promote)
redis-cli -h 10.0.0.4 -p 6379 CLUSTER FAILOVER

# Force failover (when master is unreachable)
redis-cli -h 10.0.0.4 -p 6379 CLUSTER FAILOVER FORCE

# Takeover (no master agreement needed — use as last resort)
redis-cli -h 10.0.0.4 -p 6379 CLUSTER FAILOVER TAKEOVER
```

### Resharding (Moving Slots)

```bash
# Interactive resharding
redis-cli --cluster reshard 10.0.0.1:6379

# Non-interactive: move 1000 slots from source to target
redis-cli --cluster reshard 10.0.0.1:6379 \
    --cluster-from <source-node-id> \
    --cluster-to <target-node-id> \
    --cluster-slots 1000 \
    --cluster-yes
```

### Rebalancing

```bash
# Rebalance slots evenly across masters
redis-cli --cluster rebalance 10.0.0.1:6379

# Include empty masters in rebalancing
redis-cli --cluster rebalance 10.0.0.1:6379 --cluster-use-empty-masters

# Set weight per node (node-id=weight)
redis-cli --cluster rebalance 10.0.0.1:6379 \
    --cluster-weight <node-id-1>=2 <node-id-2>=1 <node-id-3>=1
```

## Adding and Removing Nodes

### Add a New Master

```bash
# Add node as master
redis-cli --cluster add-node 10.0.0.7:6379 10.0.0.1:6379

# Then reshard slots to the new master
redis-cli --cluster reshard 10.0.0.1:6379
```

### Add a New Replica

```bash
# Add as replica of a specific master
redis-cli --cluster add-node 10.0.0.8:6379 10.0.0.1:6379 \
    --cluster-slave \
    --cluster-master-id <master-node-id>
```

### Remove a Node

```bash
# 1. If master: reshard all slots away first
redis-cli --cluster reshard 10.0.0.1:6379 \
    --cluster-from <node-to-remove-id> \
    --cluster-to <target-node-id> \
    --cluster-slots <all-slots> \
    --cluster-yes

# 2. Remove the node
redis-cli --cluster del-node 10.0.0.1:6379 <node-to-remove-id>
```

## Monitoring

### Key Metrics to Watch

```bash
# Cluster state (must be "ok")
redis-cli -h <node> CLUSTER INFO | grep cluster_state

# Slot coverage (must be 16384)
redis-cli -h <node> CLUSTER INFO | grep cluster_slots_ok

# Node health
redis-cli --cluster check <any-node>:6379

# Per-node memory
for node in 10.0.0.{1..6}; do
    echo -n "$node: "
    redis-cli -h $node INFO memory | grep used_memory_human
done

# Replication lag per node
for node in 10.0.0.{1..6}; do
    echo "=== $node ==="
    redis-cli -h $node INFO replication | grep -E "role|master_link_status|lag"
done
```

### Prometheus/Grafana

Use [redis_exporter](https://github.com/oliver006/redis_exporter) for metrics:

```bash
# Run exporter pointing to cluster
redis_exporter --redis.addr=redis://10.0.0.1:6379 \
    --redis.password=YOUR_PASSWORD \
    --is-cluster
```

## Troubleshooting

### Cluster State: FAIL

```bash
# Check which slots are failing
redis-cli --cluster check <node>:6379

# Fix slot assignment
redis-cli --cluster fix <node>:6379

# If node is permanently lost, reset and re-add
redis-cli -h <new-node> CLUSTER RESET HARD
```

### MOVED / ASK Redirections

- **MOVED:** Client's slot map is stale → refresh slot cache
- **ASK:** Slot is being migrated → temporarily redirect

Cluster-aware clients handle both automatically. If using `redis-cli`, always use `-c` flag.

### Uneven Slot Distribution

```bash
# Check distribution
redis-cli --cluster info <node>:6379

# Rebalance
redis-cli --cluster rebalance <node>:6379 --cluster-use-empty-masters
```

### Node Won't Join Cluster

```bash
# Verify cluster mode is enabled
redis-cli -h <node> INFO server | grep redis_mode
# Must show: redis_mode:cluster

# Reset the node
redis-cli -h <node> CLUSTER RESET SOFT

# Check for conflicting cluster-config-file
ls -la /var/lib/redis/nodes-*.conf
```
