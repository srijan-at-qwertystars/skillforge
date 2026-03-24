# Advanced Redis Cluster Patterns

A dense, actionable reference for production Redis Cluster usage — Lua scripting, cross-slot transactions, pub/sub, streams, client-side caching, connection pooling, migration, and ACLs.

---

## Table of Contents

- [Cluster-Aware Lua Scripting](#cluster-aware-lua-scripting)
- [Cross-Slot Transactions with Hash Tags](#cross-slot-transactions-with-hash-tags)
- [Cluster-Safe Pub/Sub](#cluster-safe-pubsub)
- [Redis Streams in Cluster Mode](#redis-streams-in-cluster-mode)
- [Client-Side Caching with RESP3 Tracking](#client-side-caching-with-resp3-tracking)
- [Cluster-Aware Connection Pooling](#cluster-aware-connection-pooling)
- [Migration Strategies: Standalone → Cluster](#migration-strategies-standalone--cluster)
- [ACL in Cluster Mode](#acl-in-cluster-mode)

---

## Cluster-Aware Lua Scripting

### The Single-Slot Rule

Every key accessed inside a Lua script **must** hash to the same slot. Redis Cluster enforces this at execution time — if your script touches keys in different slots, the command fails with a `CROSSSLOT` error. There is no way to disable this check.

```bash
# This WILL fail — keys hash to different slots
redis-cli -c EVAL "return redis.call('GET', KEYS[1]) .. redis.call('GET', KEYS[2])" 2 user:100 user:200

# (error) CROSSSLOT Keys in request don't hash to the same slot
```

### Using Hash Tags for Colocation

Wrap the common portion of your keys in `{}` so Redis hashes only the content between the first `{` and the next `}`:

```bash
# Both keys hash based on "user:100" → same slot
SET {user:100}:name "Alice"
SET {user:100}:email "alice@example.com"

# Verify they share a slot
redis-cli CLUSTER KEYSLOT "{user:100}:name"    # → 5765
redis-cli CLUSTER KEYSLOT "{user:100}:email"   # → 5765
```

### EVALSHA vs EVAL in Cluster

`EVAL` sends the full script body every time. `EVALSHA` sends only the SHA1 hash. In a cluster, scripts are cached **per node** — a script loaded on node A does not exist on node B.

```bash
# Load the script on one node — returns the SHA
SCRIPT LOAD "return redis.call('SET', KEYS[1], ARGV[1])"
# → "a42059b..."

# EVALSHA works only on the node where SCRIPT LOAD ran.
# On another node: (error) NOSCRIPT No matching script

# Robust pattern: fall back to EVAL on NOSCRIPT
```

```python
import redis

def eval_with_fallback(client, script_body, keys, args):
    """EVALSHA with automatic EVAL fallback for cluster environments."""
    import hashlib
    sha = hashlib.sha1(script_body.encode()).hexdigest()
    try:
        return client.evalsha(sha, len(keys), *keys, *args)
    except redis.exceptions.NoScriptError:
        return client.eval(script_body, len(keys), *keys, *args)
```

**Gotcha:** After a failover or reshard, the new primary has no cached scripts. Your client must handle `NOSCRIPT` and re-send via `EVAL`. Never assume `EVALSHA` will succeed permanently.

### redis.call vs redis.pcall

`redis.call()` raises an error and aborts the script on failure. `redis.pcall()` catches the error and returns it as a Lua table, letting you handle it in-script.

```lua
-- redis.call: script aborts on error
local val = redis.call('GET', KEYS[1])

-- redis.pcall: error captured, script continues
local ok, val = pcall(function()
    return redis.call('HGET', KEYS[1], 'missing_field')
end)
-- Or directly:
local result = redis.pcall('HGET', KEYS[1], 'field')
```

In cluster context, `redis.call` failures trigger a cluster-level error response to the client. Use `redis.pcall` when you want to gracefully handle individual command failures within a multi-step script.

### Example: Atomic Rate Limiter with Hash Tags

```lua
-- rate_limiter.lua
-- KEYS[1] = {user:123}:ratelimit
-- ARGV[1] = max requests (e.g., 100)
-- ARGV[2] = window in seconds (e.g., 60)
-- Returns: {allowed (0/1), remaining, ttl}

local key = KEYS[1]
local max_requests = tonumber(ARGV[1])
local window = tonumber(ARGV[2])

local current = tonumber(redis.call('GET', key) or "0")

if current >= max_requests then
    local ttl = redis.call('TTL', key)
    return {0, 0, ttl}
end

local new_count = redis.call('INCR', key)
if new_count == 1 then
    redis.call('EXPIRE', key, window)
end

local remaining = max_requests - new_count
if remaining < 0 then remaining = 0 end
local ttl = redis.call('TTL', key)

return {1, remaining, ttl}
```

```bash
# All keys use {user:123} hash tag — safe in cluster
redis-cli -c EVAL "$(cat rate_limiter.lua)" 1 "{user:123}:ratelimit" 100 60
```

### Example: Conditional Set-and-Expire in Cluster

```lua
-- set_if_lower.lua
-- Atomically SET key to value only if new value < current value (or key missing).
-- Also resets the TTL.
-- KEYS[1] = {sensor:42}:reading
-- ARGV[1] = new value
-- ARGV[2] = TTL in seconds

local key = KEYS[1]
local new_val = tonumber(ARGV[1])
local ttl = tonumber(ARGV[2])

local current = redis.call('GET', key)
if current == false or tonumber(current) > new_val then
    redis.call('SET', key, new_val, 'EX', ttl)
    return 1
end
return 0
```

```bash
redis-cli -c EVAL "$(cat set_if_lower.lua)" 1 "{sensor:42}:reading" 23 300
```

### Best Practices

- Always pass keys via `KEYS[]`, never hardcode key names in Lua — the cluster needs to verify slot ownership.
- Pre-compute the SHA1 client-side to avoid a round trip for `SCRIPT LOAD`.
- Keep scripts short — long-running Lua blocks the Redis event loop on that node.
- Test scripts against `CLUSTER KEYSLOT` before deploying.

---

## Cross-Slot Transactions with Hash Tags

### MULTI/EXEC Same-Slot Constraint

`MULTI`/`EXEC` pipelines in cluster mode **require** all keys to hash to the same slot, identical to the Lua scripting constraint. A `CROSSSLOT` error is returned otherwise.

```bash
# Fails — different slots
MULTI
SET order:1001 "pending"
SET inventory:sku-99 "47"
EXEC
# → (error) CROSSSLOT
```

### Designing Hash Tag Schemas

Use the pattern `{entity:id}:field` to colocate all data for a logical entity:

```bash
# Order entity — all keys share slot via {order:1001}
SET   {order:1001}:status   "pending"
HSET  {order:1001}:items    sku-10 2 sku-22 1
SET   {order:1001}:total    "59.99"
ZADD  {order:1001}:timeline 1700000000 "created"
```

This lets you run `MULTI`/`EXEC` across all fields atomically:

```bash
MULTI
SET {order:1001}:status "shipped"
ZADD {order:1001}:timeline 1700003600 "shipped"
EXEC
```

### Trade-offs: Colocation vs Hotspotting

| Concern | Colocation (hash tags) | No hash tags |
|---|---|---|
| Atomicity | MULTI/EXEC and Lua scripts work | Only single-key atomicity |
| Data distribution | Risk of hot slots if one entity is huge | Even distribution |
| Scaling | Constrained — entity is pinned to one node | Full horizontal scaling |

**Hotspot detection:**

```bash
# Check slot distribution — look for skew
redis-cli --cluster info 127.0.0.1:7000 | grep -E "keys|slots"

# Find the biggest keys in a specific slot
redis-cli -c --scan --pattern '{order:*}:*' | head -100 | \
  xargs -I{} redis-cli -c MEMORY USAGE {} | sort -n -k1 | tail -20
```

### Monitoring and Mitigating Data Skew

```bash
# Per-node key count — significant variance indicates skew
for port in 7000 7001 7002 7003 7004 7005; do
    count=$(redis-cli -p $port DBSIZE | awk '{print $2}')
    echo "Node :$port → $count keys"
done

# Memory usage per node
for port in 7000 7001 7002 7003 7004 7005; do
    mem=$(redis-cli -p $port INFO memory | grep used_memory_human | cut -d: -f2 | tr -d '\r')
    echo "Node :$port → $mem"
done
```

**Mitigation strategies:**
1. Sub-partition large entities — `{order:1001:chunk0}`, `{order:1001:chunk1}`.
2. Use shorter TTLs on high-churn hash-tagged keys.
3. Reshard: manually move hot slots to dedicated, beefier nodes.

### Example: Multi-Field Atomic Update with Hash Tags

```python
import redis

rc = redis.RedisCluster(host="127.0.0.1", port=7000)

def update_user_profile(user_id, name, email, updated_at):
    """Atomically update multiple fields for a user."""
    pipe = rc.pipeline(transaction=True)
    base = f"{{user:{user_id}}}"
    pipe.hset(f"{base}:profile", mapping={"name": name, "email": email})
    pipe.set(f"{base}:updated_at", updated_at)
    pipe.zadd(f"{base}:audit", {f"profile_update:{updated_at}": updated_at})
    results = pipe.execute()
    return results

update_user_profile("500", "Alice", "alice@new.com", 1700000000)
```

### Example: Optimistic Locking (WATCH) in Cluster

`WATCH` works in cluster mode but watched keys and transaction keys **must** share a slot.

```python
import redis
import time

rc = redis.RedisCluster(host="127.0.0.1", port=7000)

def transfer_balance(user_id, from_field, to_field, amount):
    """Transfer balance between two sub-accounts using optimistic locking."""
    from_key = f"{{account:{user_id}}}:{from_field}"
    to_key = f"{{account:{user_id}}}:{to_field}"

    while True:
        try:
            pipe = rc.pipeline(transaction=True)
            pipe.watch(from_key, to_key)

            from_bal = float(pipe.get(from_key) or 0)
            to_bal = float(pipe.get(to_key) or 0)

            if from_bal < amount:
                pipe.unwatch()
                raise ValueError("Insufficient balance")

            pipe.multi()
            pipe.set(from_key, str(from_bal - amount))
            pipe.set(to_key, str(to_bal + amount))
            pipe.execute()
            return True

        except redis.WatchError:
            # Another client modified the key — retry
            time.sleep(0.01)
            continue
```

---

## Cluster-Safe Pub/Sub

### Regular Pub/Sub: Cluster-Wide Broadcast

In Redis Cluster, `PUBLISH` and `SUBSCRIBE` operate globally. A message published on any node is received by subscribers on **every** node. This is by design — pub/sub channels are not slot-mapped.

```bash
# On node A (subscriber)
SUBSCRIBE notifications

# On node B (publisher) — subscriber on node A still receives it
PUBLISH notifications "hello from node B"
```

**Implication:** Regular pub/sub doesn't scale with cluster size — every node processes every published message.

### Sharded Pub/Sub (Redis 7+)

Redis 7 introduced sharded pub/sub (`SSUBSCRIBE` / `SPUBLISH`). Channels are hashed to slots, so messages are only processed by the node owning that slot.

```bash
# Channel "events:{user:100}" hashes to a specific slot
SSUBSCRIBE "events:{user:100}"

# Publish to the same sharded channel — only reaches the slot owner
SPUBLISH "events:{user:100}" '{"action":"login","ts":1700000000}'
```

### When to Use Sharded vs Regular Pub/Sub

| Use Case | Regular | Sharded |
|---|---|---|
| System-wide announcements | ✅ | ❌ |
| Per-user event streams | ❌ (wasteful) | ✅ |
| High-throughput per-entity events | ❌ (bottleneck) | ✅ |
| Need pattern subscribe (`PSUBSCRIBE`) | ✅ | ❌ (not supported) |
| Redis < 7 | ✅ (only option) | ❌ |

### Pattern Subscribe Considerations

`PSUBSCRIBE` (e.g., `PSUBSCRIBE user:*`) works only with regular pub/sub. It runs on every node. On large clusters with high publish rates, pattern matching on every node creates CPU pressure.

```bash
# Works, but expensive at scale
PSUBSCRIBE "order:*"

# Better: use sharded pub/sub with explicit channels
SSUBSCRIBE "order:{shop:42}"
```

### Client Reconnection and Subscription Recovery

When a cluster node goes down or a failover occurs, subscriptions are **lost**. Clients must:

1. Detect the disconnect.
2. Re-resolve the cluster topology.
3. Re-subscribe on the correct node (especially for sharded pub/sub).

```python
import redis
import time

def resilient_subscribe(cluster_host, channel, handler):
    """Subscribe with automatic reconnection."""
    while True:
        try:
            rc = redis.RedisCluster(host=cluster_host, port=7000)
            pubsub = rc.pubsub()
            pubsub.subscribe(channel)

            for message in pubsub.listen():
                if message["type"] == "message":
                    handler(message["channel"], message["data"])

        except (redis.ConnectionError, redis.ClusterDownError) as e:
            print(f"Connection lost: {e}. Reconnecting in 2s...")
            time.sleep(2)
            continue
```

### Example: Sharded Pub/Sub for User-Scoped Events

```python
import redis
import json
import threading

rc = redis.RedisCluster(host="127.0.0.1", port=7000)

def publish_user_event(user_id, event_type, payload):
    """Publish an event scoped to a specific user via sharded pub/sub."""
    channel = f"events:{{user:{user_id}}}"
    message = json.dumps({
        "type": event_type,
        "user_id": user_id,
        "payload": payload,
        "ts": int(__import__('time').time())
    })
    # SPUBLISH routes to the node owning the channel's slot
    rc.spublish(channel, message)

def subscribe_user_events(user_id, callback):
    """Subscribe to a specific user's event channel (sharded)."""
    channel = f"events:{{user:{user_id}}}"
    pubsub = rc.pubsub()
    pubsub.ssubscribe(channel)

    def listener():
        for msg in pubsub.listen():
            if msg["type"] == "smessage":
                data = json.loads(msg["data"])
                callback(data)

    t = threading.Thread(target=listener, daemon=True)
    t.start()
    return pubsub  # return handle so caller can unsubscribe

# Usage
subscribe_user_events("100", lambda e: print(f"Event: {e}"))
publish_user_event("100", "page_view", {"url": "/dashboard"})
```

---

## Redis Streams in Cluster Mode

### Stream Key Slot Assignment

A stream is a single key. That key hashes to one slot, which lives on one node. All data in that stream, including all consumer groups, is on that single node. There is no built-in cross-node stream.

```bash
# This stream lives on whatever node owns its slot
XADD mystream "*" sensor_id 42 temp 22.5

# Check which slot and node
redis-cli CLUSTER KEYSLOT "mystream"
```

### XREADGROUP Across Multiple Streams

`XREADGROUP` can read from multiple streams, but in cluster mode, **all stream keys must be on the same slot** (same constraint as MULTI/EXEC). If they're on different slots, the client must issue separate commands per node.

```bash
# Works if both streams share a slot via hash tags
XREADGROUP GROUP mygroup consumer1 COUNT 10 BLOCK 5000 \
  STREAMS {app}:stream1 {app}:stream2 > >

# Fails if streams are on different slots
XREADGROUP GROUP mygroup consumer1 COUNT 10 \
  STREAMS stream-orders stream-payments > >
# → CROSSSLOT error
```

### Consumer Groups Are Per-Stream

Each consumer group is bound to one stream key (one node). There is no cluster-wide consumer group spanning multiple streams.

```bash
# Create consumer group on a specific stream
XGROUP CREATE {events}:orders mygroup 0 MKSTREAM
XGROUP CREATE {events}:payments mygroup 0 MKSTREAM
# These are two INDEPENDENT groups, even though they share the name "mygroup"
```

### Scaling Streams: Partitioning Strategies

**Strategy 1: Hash-tag partitioned streams**

Colocate related streams on the same node for cross-stream reads:

```bash
# All on one node — good for related data, bad for throughput scaling
XADD {service:auth}:events "*" action login user_id 100
XADD {service:auth}:errors "*" level error msg "timeout"
```

**Strategy 2: Multiple independent stream keys across nodes**

Spread the load by using different base keys (no shared hash tag):

```bash
# Each stream on a different node — scales writes
XADD events:partition:0 "*" data "..."
XADD events:partition:1 "*" data "..."
XADD events:partition:2 "*" data "..."
```

The client must fan out reads across all partitions.

### Example: Partitioned Event Stream with Consumer Groups

```python
import redis
import threading
import json
import hashlib

NUM_PARTITIONS = 6

rc = redis.RedisCluster(host="127.0.0.1", port=7000)

def partition_for_key(entity_id: str) -> int:
    """Deterministic partition assignment based on entity ID."""
    return int(hashlib.md5(entity_id.encode()).hexdigest(), 16) % NUM_PARTITIONS

def produce_event(entity_id: str, event_type: str, payload: dict):
    """Write an event to the correct partition stream."""
    partition = partition_for_key(entity_id)
    stream_key = f"events:partition:{partition}"
    data = {
        "entity_id": entity_id,
        "type": event_type,
        "payload": json.dumps(payload)
    }
    msg_id = rc.xadd(stream_key, data)
    return stream_key, msg_id

def ensure_consumer_groups(group_name: str):
    """Create consumer group on all partitions (idempotent)."""
    for i in range(NUM_PARTITIONS):
        stream_key = f"events:partition:{i}"
        try:
            rc.xgroup_create(stream_key, group_name, id="0", mkstream=True)
        except redis.ResponseError as e:
            if "BUSYGROUP" not in str(e):
                raise  # group already exists — safe to ignore

def consume_partition(partition: int, group: str, consumer: str, handler):
    """Consume from a single partition stream."""
    stream_key = f"events:partition:{partition}"
    while True:
        try:
            results = rc.xreadgroup(
                groupname=group,
                consumername=consumer,
                streams={stream_key: ">"},
                count=50,
                block=5000
            )
            if results:
                for stream, messages in results:
                    for msg_id, fields in messages:
                        handler(stream, msg_id, fields)
                        rc.xack(stream_key, group, msg_id)
        except redis.ConnectionError:
            import time
            time.sleep(1)

def start_consumer(group: str, consumer_id: str, handler):
    """Start consumer threads for all partitions."""
    ensure_consumer_groups(group)
    threads = []
    for i in range(NUM_PARTITIONS):
        t = threading.Thread(
            target=consume_partition,
            args=(i, group, f"{consumer_id}-{i}", handler),
            daemon=True
        )
        t.start()
        threads.append(t)
    return threads

# Usage
def handle_event(stream, msg_id, fields):
    print(f"[{stream}] {msg_id}: {fields}")

start_consumer("analytics", "worker-1", handle_event)
produce_event("user:42", "click", {"page": "/home"})
```

---

## Client-Side Caching with RESP3 Tracking

### How Server-Assisted Invalidation Works

With `CLIENT TRACKING ON`, the Redis server records which keys a client reads. When another client modifies a tracked key, the server pushes an invalidation notice to the tracking client.

```bash
# Enable tracking (RESP3 required for push notifications)
CLIENT TRACKING ON

# Client reads key — server now tracks it
GET user:100:name

# Another client modifies it
SET user:100:name "Bob"

# Original client receives invalidation push:
# > invalidate: ["user:100:name"]
```

### REDIRECT Mode for Cluster

In cluster mode, each node tracks keys independently. You can redirect invalidation messages to a dedicated connection using `REDIRECT`:

```bash
# Connection 1: get its client ID
CLIENT ID
# → 42

# Connection 2: enable tracking, redirect invalidations to conn 1
CLIENT TRACKING ON REDIRECT 42
```

This is useful when your application uses a single listener connection for invalidation events across the cluster.

### Broadcasting Mode vs Default Mode

**Default mode:** Server tracks exactly which keys each client has read. Memory overhead on the server proportional to tracked keys × clients.

**Broadcasting mode:** Server doesn't track per-client reads. Instead, it broadcasts invalidation for any modified key matching given prefixes. Lower server memory, but more invalidation traffic.

```bash
# Default — precise, higher server memory
CLIENT TRACKING ON

# Broadcasting — prefix-based, lower server memory
CLIENT TRACKING ON BCAST PREFIX user: PREFIX session:
```

### Handling MOVED Errors and Topology Changes

When a slot migrates, the new node has no tracking state for your client. You must:

1. Detect the `MOVED` response.
2. Re-establish tracking on the new node.
3. Invalidate all locally cached keys for that slot range.

**Gotcha:** There is no automatic re-tracking after a `MOVED` redirect. Your local cache for migrated keys becomes stale silently if you don't handle this.

### Connection Per Node for Tracking

In a cluster, you need tracking enabled on **each node** you read from. This means maintaining a tracking-enabled connection to every master node.

```python
# Pseudocode for cluster-wide tracking setup
for node in cluster.get_master_nodes():
    conn = create_connection(node.host, node.port)
    conn.execute("CLIENT TRACKING ON BCAST PREFIX user:")
    tracking_connections[node.id] = conn
```

### Example: Python Client-Side Cache with Invalidation

```python
import redis
import threading
from collections import defaultdict

class ClusterClientCache:
    """Client-side cache with server-assisted invalidation for Redis Cluster."""

    def __init__(self, host="127.0.0.1", port=7000):
        self.rc = redis.RedisCluster(
            host=host, port=port, protocol=3  # RESP3 required
        )
        self._cache = {}
        self._lock = threading.Lock()
        self._setup_invalidation()

    def _setup_invalidation(self):
        """Start a background listener for invalidation messages."""
        self._pubsub = self.rc.pubsub()
        # In RESP3, invalidation comes as push messages

        def invalidation_listener():
            while True:
                try:
                    # The actual implementation depends on the client library.
                    # redis-py with RESP3 delivers invalidations via push messages.
                    msg = self._pubsub.get_message(timeout=1.0)
                    if msg and msg.get("type") == "invalidate":
                        keys = msg.get("data", [])
                        with self._lock:
                            for key in keys:
                                self._cache.pop(key, None)
                except Exception:
                    import time
                    time.sleep(0.5)

        t = threading.Thread(target=invalidation_listener, daemon=True)
        t.start()

    def get(self, key):
        """Get a value, using local cache if available."""
        with self._lock:
            if key in self._cache:
                return self._cache[key]

        value = self.rc.get(key)
        with self._lock:
            self._cache[key] = value
        return value

    def invalidate_all(self):
        """Force-clear entire local cache (e.g., after topology change)."""
        with self._lock:
            self._cache.clear()

    def stats(self):
        with self._lock:
            return {"cached_keys": len(self._cache)}

# Usage
cache = ClusterClientCache()
val = cache.get("user:100:name")       # fetched from Redis, now cached
val = cache.get("user:100:name")       # served from local cache
# If another client modifies user:100:name, the server pushes an invalidation
# and our next .get() will fetch fresh data from Redis.
```

---

## Cluster-Aware Connection Pooling

### One Pool Per Node

A cluster-aware client must maintain a **separate connection pool for each master node**. A single shared pool doesn't work because each connection is to a specific node, and commands must be routed to the node owning the target key's slot.

```
Cluster Topology:
  Node A (slots 0-5460)      → Pool A: [conn1, conn2, ..., connN]
  Node B (slots 5461-10922)  → Pool B: [conn1, conn2, ..., connN]
  Node C (slots 10923-16383) → Pool C: [conn1, conn2, ..., connN]
```

### Pool Sizing Formula

```
connections_per_node = ceil(
    max_concurrent_requests_per_node / avg_requests_per_connection_per_second * avg_latency_seconds
)
```

Rule of thumb: start with `max_concurrent_requests / num_master_nodes`, capped at a reasonable upper bound (e.g., 50 per node). Monitor and adjust.

```python
# Example: 300 concurrent requests, 3 master nodes
# → 100 connections per node as an upper bound
# Start lower (e.g., 20) and increase based on connection wait times.
```

### Connection Lifecycle: Detecting MOVED

When a client receives a `MOVED` response, it means the slot has migrated. The pool must:

1. Update the slot-to-node mapping.
2. Redirect the request to the correct node.
3. Optionally refresh the full topology via `CLUSTER SLOTS` or `CLUSTER NODES`.

```python
def handle_moved(error_msg):
    """Parse MOVED response and update routing."""
    # MOVED 3999 127.0.0.1:7001
    parts = error_msg.split()
    slot = int(parts[1])
    host, port = parts[2].rsplit(":", 1)
    update_slot_mapping(slot, host, int(port))
    ensure_pool_exists(host, int(port))
```

### Health Checking Connections

Stale connections waste pool slots and cause latency spikes. Implement health checks:

```python
import redis
import time

class HealthCheckedPool:
    """Connection pool with periodic PING-based health checks."""

    def __init__(self, host, port, max_connections=20, check_interval=30):
        self.pool = redis.ConnectionPool(
            host=host, port=port,
            max_connections=max_connections,
            health_check_interval=check_interval  # redis-py built-in
        )
        self.client = redis.Redis(connection_pool=self.pool)

    def get_connection(self):
        """Get a connection — stale ones are automatically replaced."""
        return self.client
```

### Client Library Pooling Models Compared

| Feature | Lettuce (Java) | Jedis (Java) | redis-py |
|---|---|---|---|
| Pool per node | Automatic | Manual (`JedisCluster`) | Automatic (`RedisCluster`) |
| Topology refresh | Periodic + on error | On `MOVED` only | On `MOVED` + periodic |
| Connection type | Netty (async) | Blocking sockets | Blocking (sync) / async |
| Thread safety | Single connection, multiplexed | Pool-per-thread | Pool with locking |
| Default pool size | 1 (multiplexed) | 8 per node | 2^31 (unbounded!) |

**Gotcha (redis-py):** The default `max_connections` is effectively unlimited. Always set it explicitly:

```python
rc = redis.RedisCluster(
    host="127.0.0.1", port=7000,
    max_connections=50,                  # per node
    max_connections_per_node=True,       # enforce per-node limit
)
```

### Example: Custom Connection Pool with Topology Refresh

```python
import redis
import threading
import time

class ClusterPoolManager:
    """Manages per-node connection pools with periodic topology refresh."""

    def __init__(self, seed_host, seed_port, pool_size=20, refresh_interval=30):
        self.seed = (seed_host, seed_port)
        self.pool_size = pool_size
        self.refresh_interval = refresh_interval
        self.pools = {}           # node_id → redis.ConnectionPool
        self.slot_map = {}        # slot → (host, port)
        self._lock = threading.Lock()
        self._refresh_topology()
        self._start_refresh_loop()

    def _refresh_topology(self):
        """Query CLUSTER SLOTS and rebuild the slot → node mapping."""
        r = redis.Redis(host=self.seed[0], port=self.seed[1])
        slots = r.cluster("SLOTS")
        r.close()

        with self._lock:
            for slot_range in slots:
                start, end = int(slot_range[0]), int(slot_range[1])
                host = slot_range[2][0].decode() if isinstance(slot_range[2][0], bytes) else slot_range[2][0]
                port = int(slot_range[2][1])
                node_key = f"{host}:{port}"
                for slot in range(start, end + 1):
                    self.slot_map[slot] = node_key
                if node_key not in self.pools:
                    self.pools[node_key] = redis.ConnectionPool(
                        host=host, port=port,
                        max_connections=self.pool_size,
                        health_check_interval=15
                    )

    def _start_refresh_loop(self):
        def loop():
            while True:
                time.sleep(self.refresh_interval)
                try:
                    self._refresh_topology()
                except Exception as e:
                    print(f"Topology refresh failed: {e}")

        t = threading.Thread(target=loop, daemon=True)
        t.start()

    def get_client_for_key(self, key):
        """Return a Redis client connected to the node owning this key's slot."""
        slot = self._key_slot(key)
        with self._lock:
            node_key = self.slot_map.get(slot)
            pool = self.pools.get(node_key)
        if pool is None:
            self._refresh_topology()
            with self._lock:
                node_key = self.slot_map[slot]
                pool = self.pools[node_key]
        return redis.Redis(connection_pool=pool)

    @staticmethod
    def _key_slot(key):
        """Compute the CRC16 hash slot for a key (simplified)."""
        import binascii
        # Handle hash tags
        s = key.encode() if isinstance(key, str) else key
        start = s.find(b'{')
        if start != -1:
            end = s.find(b'}', start + 1)
            if end != -1 and end != start + 1:
                s = s[start + 1:end]
        return binascii.crc_hqx(s, 0) % 16384

# Usage
pool_mgr = ClusterPoolManager("127.0.0.1", 7000, pool_size=30)
client = pool_mgr.get_client_for_key("{user:100}:profile")
client.hset("{user:100}:profile", "name", "Alice")
```

---

## Migration Strategies: Standalone → Cluster

### Pre-Migration Audit

Before touching infrastructure, audit your codebase and data for cluster compatibility.

**1. Find multi-key commands:**

```bash
# Search application code for commands that span multiple keys
grep -rnE '(MGET|MSET|SDIFF|SINTER|SUNION|PFMERGE|RENAME|RPOPLPUSH|SMOVE|SORT.*STORE)' \
  --include='*.py' --include='*.js' --include='*.java' --include='*.go' src/

# Search for Lua scripts touching multiple KEYS
grep -rnE 'KEYS\[2\]|KEYS\[3\]' --include='*.lua' src/
```

**2. Find KEYS command usage (not cluster-safe at scale):**

```bash
grep -rnE '\.keys\(|KEYS \*|KEYS ' --include='*.py' --include='*.js' src/
# Replace with SCAN-based iteration
```

**3. Check for transaction usage:**

```bash
grep -rnE '(MULTI|EXEC|WATCH|pipeline|transaction)' \
  --include='*.py' --include='*.js' src/
```

### Add Hash Tags Before Migration

Refactor key naming to use hash tags **while still on standalone Redis**. This is safe — hash tags are ignored on standalone but essential for cluster.

```python
# Before: keys scattered across slots
OLD_KEYS = {
    "user:100:name": "Alice",
    "user:100:email": "alice@example.com",
    "user:100:prefs": '{"theme":"dark"}',
}

# After: hash-tagged keys — colocated in cluster, no-op in standalone
NEW_KEYS = {
    "{user:100}:name": "Alice",
    "{user:100}:email": "alice@example.com",
    "{user:100}:prefs": '{"theme":"dark"}',
}
```

Run a migration script to rename keys:

```python
import redis

r = redis.Redis(host="standalone-host", port=6379)

def migrate_keys(pattern, tag_extractor):
    """Rename keys to hash-tagged versions."""
    cursor = 0
    while True:
        cursor, keys = r.scan(cursor, match=pattern, count=500)
        for key in keys:
            key_str = key.decode()
            tag = tag_extractor(key_str)
            new_key = key_str.replace(tag + ":", "{" + tag + "}:")
            if key_str != new_key:
                r.rename(key_str, new_key)
                print(f"Renamed: {key_str} → {new_key}")
        if cursor == 0:
            break

# Example: rename user:*:* → {user:*}:*
migrate_keys("user:*", lambda k: k.split(":")[0] + ":" + k.split(":")[1])
```

### Dual-Write Period Strategy

Run both standalone and cluster in parallel during transition:

```
Phase 1: Standalone (primary) ← reads + writes
          Cluster (shadow)    ← writes only (via dual-write)

Phase 2: Cluster (primary)    ← reads + writes
          Standalone (shadow)  ← writes only (rollback safety net)

Phase 3: Cluster only          ← reads + writes
          Standalone            ← decommissioned
```

```python
class DualWriteClient:
    """Write to both standalone and cluster during migration."""

    def __init__(self, standalone, cluster, primary="standalone"):
        self.standalone = standalone
        self.cluster = cluster
        self.primary = primary

    def set(self, key, value, **kwargs):
        if self.primary == "standalone":
            result = self.standalone.set(key, value, **kwargs)
            try:
                self.cluster.set(key, value, **kwargs)
            except Exception as e:
                log.warning(f"Cluster shadow write failed: {e}")
            return result
        else:
            result = self.cluster.set(key, value, **kwargs)
            try:
                self.standalone.set(key, value, **kwargs)
            except Exception as e:
                log.warning(f"Standalone shadow write failed: {e}")
            return result

    def get(self, key):
        if self.primary == "standalone":
            return self.standalone.get(key)
        return self.cluster.get(key)
```

### Data Migration with redis-shake

```bash
# Install redis-shake
wget https://github.com/tair-opensource/RedisShake/releases/latest/download/redis-shake-linux-amd64.tar.gz
tar xzf redis-shake-linux-amd64.tar.gz

# Configure shake.toml
cat > shake.toml << 'EOF'
[source]
type = "standalone"
address = "127.0.0.1:6379"
password = ""

[target]
type = "cluster"
address = "127.0.0.1:7000"
password = ""

[advanced]
dir = "./data"
ncpu = 4
EOF

# Run migration
./redis-shake shake.toml
```

### Rollback Plan

Always have a rollback path:

```bash
#!/bin/bash
# rollback.sh — switch traffic back to standalone

# 1. Stop dual-writes by updating config
export REDIS_PRIMARY=standalone

# 2. Verify standalone has recent data
redis-cli -h standalone-host DBSIZE
redis-cli -h standalone-host GET "{user:1}:name"

# 3. Update application config and restart
sed -i 's/REDIS_MODE=cluster/REDIS_MODE=standalone/' /etc/app/config.env
systemctl restart app

# 4. Monitor error rates
echo "Watch dashboards for 15 minutes before confirming rollback."
```

### Post-Migration Validation Checklist

```bash
#!/bin/bash
# validate_cluster.sh — run after migration

CLUSTER_HOST="127.0.0.1"
CLUSTER_PORT=7000

echo "=== Cluster Health ==="
redis-cli -h $CLUSTER_HOST -p $CLUSTER_PORT CLUSTER INFO | grep -E "cluster_state|cluster_slots_ok|cluster_known_nodes"

echo ""
echo "=== Node Key Distribution ==="
redis-cli -h $CLUSTER_HOST -p $CLUSTER_PORT --cluster info $CLUSTER_HOST:$CLUSTER_PORT

echo ""
echo "=== Sample Data Verification ==="
# Spot-check known keys
for key in "{user:1}:name" "{user:1}:email" "{order:100}:status"; do
    val=$(redis-cli -c -h $CLUSTER_HOST -p $CLUSTER_PORT GET "$key")
    echo "  $key = $val"
done

echo ""
echo "=== Multi-Key Operation Test ==="
# Verify hash-tagged multi-key ops work
redis-cli -c -h $CLUSTER_HOST -p $CLUSTER_PORT MGET "{test}:a" "{test}:b" "{test}:c"

echo ""
echo "=== Latency Baseline ==="
redis-cli -c -h $CLUSTER_HOST -p $CLUSTER_PORT --latency-history -i 5 &
LATENCY_PID=$!
sleep 15
kill $LATENCY_PID 2>/dev/null

echo ""
echo "=== Check for CROSSSLOT Errors in Logs ==="
grep -c "CROSSSLOT" /var/log/redis/redis-cluster-*.log 2>/dev/null || echo "  No log files found — check application logs instead."

echo ""
echo "Validation complete."
```

---

## ACL in Cluster Mode

### ACLs Are NOT Automatically Replicated

This is a critical distinction from other cluster features. ACL rules set on one node **do not propagate** to other nodes. You must apply ACL changes to every node independently.

```bash
# Setting an ACL on node A does NOT affect nodes B or C
redis-cli -h node-a -p 7000 ACL SETUSER readonly on '>secret123' '~user:*' '+GET' '+MGET' '+HGETALL'

# This user doesn't exist on node B yet!
redis-cli -h node-b -p 7001 AUTH readonly secret123
# → (error) WRONGPASS or ERR AUTH user not found
```

### Per-Node ACL Files

Use ACL files to define users declaratively and load them on each node:

```conf
# /etc/redis/users.acl

# Admin — full access
user admin on >strongAdminPassword ~* &* +@all

# Application — read/write to app keys only
user appuser on >appPassword ~{app}:* ~{session}:* &* +@all -@dangerous

# Read-only analytics user
user analyst on >analystPassword ~* &* +@read -@write -@admin -@dangerous

# Pub/sub only user
user pubsub_worker on >workerPass ~* &events:* +SUBSCRIBE +PUBLISH +SSUBSCRIBE +SPUBLISH +PING

# Disable default user (security hardening)
user default off
```

```conf
# redis.conf on each node
aclfile /etc/redis/users.acl
```

### ACL LOAD on Each Node

After updating the ACL file, reload on every node:

```bash
# Reload ACLs on all nodes
for port in 7000 7001 7002 7003 7004 7005; do
    redis-cli -p $port -a adminPassword --user admin ACL LOAD
    echo "ACL loaded on :$port"
done
```

### Restricting Commands Per User

```bash
# Create a user that can only run read commands and specific write commands
redis-cli ACL SETUSER limited_writer on '>writerPass' \
    '~{orders}:*' \
    '+GET' '+SET' '+HSET' '+HGET' '+HGETALL' \
    '+EXPIRE' '+TTL' \
    '+PING' '+INFO' \
    '-FLUSHALL' '-FLUSHDB' '-DEBUG' '-CONFIG' '-SHUTDOWN'
```

Useful command categories for cluster:

```bash
# List all ACL categories
redis-cli ACL CAT

# Key categories for restriction:
# +@read      — all read commands
# +@write     — all write commands
# -@admin     — block admin commands (CONFIG, SHUTDOWN, etc.)
# -@dangerous — block FLUSHALL, FLUSHDB, DEBUG, KEYS, etc.
# +@pubsub    — pub/sub commands
# +@stream    — stream commands
```

### Channel ACLs with Pub/Sub

Redis 7+ supports restricting pub/sub channels per user with the `&` selector:

```bash
# User can only subscribe/publish to channels matching "events:{user:*}"
redis-cli ACL SETUSER event_consumer on '>eventPass' \
    '~*' \
    '&events:*' \
    '+SUBSCRIBE' '+PSUBSCRIBE' '+SSUBSCRIBE' \
    '+PUBLISH' '+SPUBLISH' \
    '+PING'

# This user cannot access channels outside the "events:" prefix
# Attempting SUBSCRIBE other:channel will be denied
```

### Example: Read-Only User Restricted to Key Patterns

```bash
# Create the user on one node
redis-cli -h 127.0.0.1 -p 7000 --user admin -a adminPass \
    ACL SETUSER dashboard_reader on \
    '>dashPass' \
    '~{metrics}:*' \
    '~{reports}:*' \
    '+GET' '+MGET' '+HGET' '+HGETALL' '+SMEMBERS' '+ZRANGE' \
    '+LRANGE' '+XRANGE' '+XREAD' '+XINFO' \
    '+TTL' '+TYPE' '+EXISTS' '+SCAN' \
    '+PING' '+ECHO' '+INFO'

# Test it
redis-cli -h 127.0.0.1 -p 7000 --user dashboard_reader -a dashPass \
    GET "{metrics}:cpu:node1"
# → (returns value)

redis-cli -h 127.0.0.1 -p 7000 --user dashboard_reader -a dashPass \
    SET "{metrics}:cpu:node1" "99"
# → (error) NOPERM this user has no permissions to run the 'set' command

redis-cli -h 127.0.0.1 -p 7000 --user dashboard_reader -a dashPass \
    GET "secret:api_key"
# → (error) NOPERM this user has no permissions to access the 'secret:api_key' key
```

### Automating ACL Sync Across Cluster Nodes

Since ACLs don't replicate, you need external automation. Here are two approaches:

**Approach 1: Shared ACL file + script**

```bash
#!/bin/bash
# sync_acls.sh — distribute ACL file and reload on all nodes

ACL_FILE="/etc/redis/users.acl"
NODES=("node-a:7000" "node-b:7001" "node-c:7002"
       "node-d:7003" "node-e:7004" "node-f:7005")
ADMIN_USER="admin"
ADMIN_PASS="strongAdminPassword"

# Copy ACL file to all nodes (assumes SSH access)
for node in "${NODES[@]}"; do
    host="${node%%:*}"
    echo "Copying ACL file to $host..."
    scp "$ACL_FILE" "$host:/etc/redis/users.acl"
done

# Reload ACLs on all nodes
for node in "${NODES[@]}"; do
    host="${node%%:*}"
    port="${node##*:}"
    echo "Reloading ACLs on $host:$port..."
    result=$(redis-cli -h "$host" -p "$port" --user "$ADMIN_USER" -a "$ADMIN_PASS" ACL LOAD 2>&1)
    if [ "$result" != "OK" ]; then
        echo "  ERROR: $result"
    else
        echo "  OK"
    fi
done

# Verify: list users on each node
echo ""
echo "=== Verification ==="
for node in "${NODES[@]}"; do
    host="${node%%:*}"
    port="${node##*:}"
    users=$(redis-cli -h "$host" -p "$port" --user "$ADMIN_USER" -a "$ADMIN_PASS" ACL LIST 2>&1 | wc -l)
    echo "$host:$port → $users ACL rules"
done
```

**Approach 2: Programmatic ACL sync (no shared filesystem needed)**

```python
import redis

ADMIN_CREDS = {"username": "admin", "password": "strongAdminPassword"}

NODES = [
    ("node-a", 7000), ("node-b", 7001), ("node-c", 7002),
    ("node-d", 7003), ("node-e", 7004), ("node-f", 7005),
]

def get_acl_rules(host, port):
    """Fetch current ACL rules from a node."""
    r = redis.Redis(host=host, port=port, **ADMIN_CREDS)
    return r.acl_list()

def sync_acls(source_host, source_port):
    """Read ACLs from source node and apply to all other nodes."""
    rules = get_acl_rules(source_host, source_port)
    print(f"Source {source_host}:{source_port} has {len(rules)} ACL rules")

    for host, port in NODES:
        if host == source_host and port == source_port:
            continue
        try:
            r = redis.Redis(host=host, port=port, **ADMIN_CREDS)
            # Clear existing non-admin users and reapply
            existing_users = r.acl_users()
            for user in existing_users:
                if user.decode() not in ("admin", "default"):
                    r.acl_deluser(user.decode())

            for rule in rules:
                rule_str = rule.decode() if isinstance(rule, bytes) else rule
                # ACL LIST returns full rule strings — apply via ACL SETUSER
                parts = rule_str.split(" ", 1)
                username = parts[0].replace("user:", "").strip()
                if username == "admin":
                    continue  # don't overwrite admin on target
                r.execute_command("ACL", "SETUSER", *rule_str.split())

            print(f"  ✓ Synced to {host}:{port}")
        except Exception as e:
            print(f"  ✗ Failed on {host}:{port}: {e}")

    # Save to disk on all nodes
    for host, port in NODES:
        try:
            r = redis.Redis(host=host, port=port, **ADMIN_CREDS)
            r.execute_command("ACL", "SAVE")
            print(f"  ✓ ACL SAVE on {host}:{port}")
        except Exception as e:
            print(f"  ✗ ACL SAVE failed on {host}:{port}: {e}")

# Usage: sync from the source-of-truth node to all others
sync_acls("node-a", 7000)
```

### Best Practices for Cluster ACLs

- **Single source of truth:** Maintain one canonical ACL file in version control. Deploy it to all nodes via CI/CD.
- **Always disable the default user** in production: `user default off`.
- **Use `ACL SAVE`** after `ACL SETUSER` to persist to the ACL file on disk — otherwise changes are lost on restart.
- **Test ACL changes on one node first** before rolling out cluster-wide.
- **Monitor denied commands:** `redis-cli ACL LOG` shows recent permission denials — check this after deployments.

```bash
# Check recent ACL violations on each node
for port in 7000 7001 7002 7003 7004 7005; do
    echo "=== Node :$port ==="
    redis-cli -p $port --user admin -a adminPass ACL LOG 5
done
```
