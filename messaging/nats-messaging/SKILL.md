---
name: nats-messaging
description: >
  Use when working with NATS messaging, NATS JetStream, NATS pub/sub,
  nats-server configuration, NATS cluster setup, NATS key-value store,
  NATS object store, or the nats CLI tool. Covers core messaging, streaming,
  persistence, authentication, clustering, and client libraries for Go,
  Python, Node.js, and Rust. Do NOT use for RabbitMQ, Kafka, Redis pub/sub,
  AWS SQS/SNS, or gRPC streaming — those are different messaging systems
  with distinct APIs and semantics.
---

# NATS Messaging

## Subject-Based Addressing

Subjects are dot-delimited tokens: `orders.us.east`. Max 16 tokens recommended.

**Wildcards (subscribers only):**
- `*` matches exactly one token: `orders.*.created` matches `orders.us.created`, not `orders.us.east.created`.
- `>` matches one or more tokens at the tail: `orders.>` matches `orders.us`, `orders.us.east.created`.
- `>` alone matches everything.

**Rules:** Publishers must use fully-qualified subjects. Never use wildcards in publish subjects.

**Naming conventions:** Use lowercase dot-separated hierarchy: `{domain}.{entity}.{action}`. Example: `billing.invoice.created`.

## Core NATS (Pub/Sub, Request/Reply, Queue Groups)

### Publish/Subscribe
Fire-and-forget broadcast. No persistence. If no subscriber is listening, message is dropped.

```go
// Go — publish
nc, _ := nats.Connect("nats://localhost:4222")
defer nc.Drain()
nc.Publish("events.user.signup", []byte(`{"id":"u1"}`))

// Go — subscribe
nc.Subscribe("events.user.*", func(m *nats.Msg) {
    fmt.Printf("Received on %s: %s\n", m.Subject, string(m.Data))
})
// Input:  publish to "events.user.signup" with {"id":"u1"}
// Output: "Received on events.user.signup: {"id":"u1"}"
```

```python
# Python — pub/sub
import nats

async def main():
    nc = await nats.connect("nats://localhost:4222")
    sub = await nc.subscribe("events.>")
    await nc.publish("events.order.placed", b'{"order":1}')
    msg = await sub.next_msg(timeout=1)
    print(f"{msg.subject}: {msg.data.decode()}")
    await nc.drain()
# Output: events.order.placed: {"order":1}
```

### Request/Reply
Synchronous RPC pattern. Client publishes with a reply inbox; responder replies.

```go
// Responder
nc.Subscribe("svc.auth.validate", func(m *nats.Msg) {
    nc.Publish(m.Reply, []byte(`{"valid":true}`))
})
// Requester
resp, err := nc.Request("svc.auth.validate", []byte(`{"token":"abc"}`), 2*time.Second)
// Input:  {"token":"abc"}
// Output: {"valid":true}
```

### Queue Groups
Load-balance messages across subscribers. Only one member per group receives each message.

```go
nc.QueueSubscribe("tasks.process", "workers", func(m *nats.Msg) {
    // Only one worker in "workers" group receives this message
})
```

```typescript
// Node.js
const nc = await connect({ servers: "nats://localhost:4222" });
const sub = nc.subscribe("tasks.process", { queue: "workers" });
for await (const msg of sub) {
    console.log(msg.string());
}
```

## JetStream

Enable with `nats-server -js` or config `jetstream: { store_dir: "/data/jetstream" }`.

### Streams
Persistent, append-only log of messages captured by subject filter.

**Stream config fields:**
- `Name`: unique identifier
- `Subjects`: array of subject filters (e.g., `["orders.>"]`)
- `Retention`: `LimitsPolicy` (default) | `WorkQueuePolicy` | `InterestPolicy`
- `MaxMsgs`, `MaxBytes`, `MaxAge`: retention limits
- `MaxMsgSize`: reject messages exceeding this size
- `Storage`: `FileStorage` (default, durable) | `MemoryStorage` (fast, volatile)
- `Replicas`: 1-5 for HA in clustered mode (use odd numbers: 1, 3, 5)
- `Duplicates`: deduplication window duration
- `Discard`: `DiscardOld` (drop oldest) | `DiscardNew` (reject new)

```bash
# nats CLI — create stream
nats stream add ORDERS --subjects="orders.>" --retention=limits \
  --max-msgs=1000000 --max-bytes=1GiB --max-age=72h \
  --storage=file --replicas=3 --discard=old --dupe-window=2m
```

```go
js, _ := nc.JetStream()
js.AddStream(&nats.StreamConfig{
    Name:       "ORDERS",
    Subjects:   []string{"orders.>"},
    Retention:  nats.LimitsPolicy,
    MaxMsgs:    1_000_000,
    MaxBytes:   1 << 30,
    MaxAge:     72 * time.Hour,
    Duplicates: 2 * time.Minute,
    Storage:    nats.FileStorage,
    Replicas:   3,
})
```

### Consumers
Named views into a stream with delivery tracking and ack management.

**Consumer types:**
- **Durable**: survives disconnects; server tracks ack state. Use for production workloads.
- **Ephemeral**: deleted on disconnect. Use for temporary/debugging reads.

**Key consumer config:**
- `AckPolicy`: `AckExplicit` (recommended) | `AckAll` | `AckNone`
- `DeliverPolicy`: `DeliverAll` | `DeliverNew` | `DeliverLast` | `DeliverByStartSequence` | `DeliverByStartTime`
- `FilterSubject`: consume only matching subjects from the stream
- `MaxDeliver`: max redelivery attempts before moving to dead letter
- `AckWait`: time before unacked message is redelivered (default 30s)

**Pull consumers** (recommended for production):
```go
sub, _ := js.PullSubscribe("orders.>", "order-processor",
    nats.AckExplicit(), nats.MaxDeliver(5))
msgs, _ := sub.Fetch(10, nats.MaxWait(5*time.Second))
for _, msg := range msgs {
    processOrder(msg.Data)
    msg.Ack()  // Always ack after successful processing
}
```

**Push consumers** (message delivered automatically):
```go
js.Subscribe("orders.created", func(m *nats.Msg) {
    processOrder(m.Data)
    m.Ack()
}, nats.Durable("push-processor"), nats.ManualAck())
```

### Exactly-Once Semantics
Combine publish-side deduplication with consumer-side explicit acks.

**Publish with dedup:**
```go
// Set Nats-Msg-Id header for deduplication
msg := &nats.Msg{
    Subject: "orders.created",
    Data:    []byte(`{"id":"ord-123"}`),
    Header:  nats.Header{"Nats-Msg-Id": []string{"ord-123-v1"}},
}
js.PublishMsg(msg)
// Republishing with same Nats-Msg-Id within the Duplicates window is a no-op
```

**Consume with double-ack:**
```go
msg.AckSync() // Waits for server confirmation of ack
```

### Retention Policies
- **LimitsPolicy**: keep messages until limits exceeded; oldest evicted. General-purpose.
- **WorkQueuePolicy**: message removed once acked. One consumer per message. Use for job queues.
- **InterestPolicy**: message kept while any defined consumer hasn't acked. Use for fan-out with persistence.

## Key-Value Store

Built on JetStream streams. Provides distributed, consistent key-value semantics.

```go
kv, _ := js.CreateKeyValue(&nats.KeyValueConfig{
    Bucket: "config", History: 5, TTL: time.Hour, Replicas: 3,
})
kv.Put("db.host", []byte("pg.prod.internal"))            // Put
entry, _ := kv.Get("db.host")                             // Get → "pg.prod.internal"
_, err := kv.Create("db.host", []byte("other"))           // Create (put-if-absent) → error: exists
kv.Update("db.host", []byte("pg2.internal"), entry.Revision()) // CAS update
kv.Delete("db.host")                                      // Delete

// Watch for changes
watcher, _ := kv.WatchAll()
for entry := range watcher.Updates() {
    if entry != nil {
        fmt.Printf("key=%s val=%s\n", entry.Key(), entry.Value())
    }
}
```

```bash
# nats CLI
nats kv add CONFIG --history=5 --ttl=1h --replicas=3
nats kv put CONFIG db.host "pg.prod.internal"
nats kv get CONFIG db.host
# Output: pg.prod.internal
```

## Object Store

Large blob/file storage built on JetStream. Objects are chunked into stream messages.

```go
obs, _ := js.CreateObjectStore(&nats.ObjectStoreConfig{Bucket: "artifacts", Replicas: 3})
file, _ := os.Open("model.bin")
obs.Put(&nats.ObjectMeta{Name: "ml/model-v2"}, file) // Store (auto-chunked)
result, _ := obs.Get("ml/model-v2")                   // Retrieve
data, _ := io.ReadAll(result)
obs.Delete("ml/model-v2")                             // Delete
watcher, _ := obs.Watch()                              // Watch changes
```

```bash
nats object add ARTIFACTS --replicas=3
nats object put ARTIFACTS model.bin --name="ml/model-v2"
nats object get ARTIFACTS "ml/model-v2" --output=downloaded.bin
nats object ls ARTIFACTS
```

## Clustering and Super-Clusters

### Cluster (Single Region/DC)
Three-node minimum for JetStream HA. Uses RAFT consensus.

```hcl
# server-1.conf
server_name: n1
jetstream: { store_dir: "/data/js" }
cluster {
    name: dc-east
    listen: 0.0.0.0:6222
    routes: [
        nats-route://n2:6222
        nats-route://n3:6222
    ]
}
```

### Super-Cluster (Multi-Region via Gateways)
Connect geographically distributed clusters. Interest-only propagation minimizes WAN traffic.

```hcl
gateway {
    name: dc-east
    listen: 0.0.0.0:7222
    gateways: [
        { name: dc-west, urls: ["nats://west-n1:7222"] }
        { name: dc-eu,   urls: ["nats://eu-n1:7222"] }
    ]
}
```

### Leaf Nodes
Bridge edge/remote servers to a hub cluster. Ideal for IoT, multi-cloud, hybrid topologies.

**Hub config:**
```hcl
leafnodes { port: 7422 }
```

**Leaf config:**
```hcl
leafnodes {
    remotes: [{ url: "nats-leaf://hub:7422", credentials: "/etc/nats/leaf.creds" }]
}
```

Leaf nodes operate independently during disconnection. Subject permissions on the leaf connection control data flow to/from hub.

## Authentication and Authorization

### Token/User-Password (dev/test only)
```hcl
authorization { token: "s3cr3t" }
# Or
authorization { users: [{ user: admin, password: "$2a$..." }] }
```

### NKey (Ed25519 — production recommended)
Server stores only the public key. Client signs a nonce with its private seed.

```hcl
authorization {
    users: [
        {
            nkey: UDXU4RCSJNZOIQHZNWXHXORDPRTGNJAHAHFRGZNEEJCPQTT2M7NLCNF4
            permissions: {
                publish: { allow: ["service.>"] }
                subscribe: { allow: ["_INBOX.>"] }
            }
        }
    ]
}
```

### JWT + Accounts (Operator Mode — large-scale production)
Decentralized, cryptographically verifiable. Managed with `nsc` CLI.

```bash
# Setup operator, account, user
nsc add operator --generate-signing-key --sys --name prod-op
nsc add account --name billing
nsc add user --account billing --name svc-billing
nsc generate config --nats-resolver --sys-account SYS > resolver.conf
# Include resolver.conf in nats-server config
```

### Accounts (Multi-Tenancy)
Isolate subject namespaces between tenants. Control cross-account access via imports/exports.

```hcl
accounts {
    BILLING: {
        users: [{ nkey: "UDXU..." }]
        exports: [{ service: "billing.charge" }]
    }
    ORDERS: {
        users: [{ nkey: "UABC..." }]
        imports: [{ service: { account: BILLING, subject: "billing.charge" } }]
    }
}
```

## Monitoring and Observability

### HTTP Monitoring Endpoints
Enable with `http_port: 8222` in server config.

| Endpoint     | Purpose                                |
|-------------|----------------------------------------|
| `/varz`     | Server stats, memory, connections       |
| `/connz`    | Active client connections detail        |
| `/routez`   | Cluster route information               |
| `/subsz`    | Subscription counts and details         |
| `/jsz`      | JetStream stream/consumer metrics       |
| `/healthz`  | Liveness/readiness check                |
| `/gatewayz` | Gateway (super-cluster) info            |
| `/leafz`    | Leaf node connection status             |
| `/accountz` | Account-level stats                     |

```bash
curl http://localhost:8222/healthz    # Output: {"status":"ok"}
curl http://localhost:8222/varz       # Server stats JSON
curl http://localhost:8222/jsz        # JetStream stats
```

### Prometheus Integration
Use `prometheus-nats-exporter` sidecar or scrape `/varz` directly.

```yaml
# prometheus.yml
scrape_configs:
  - job_name: nats
    static_configs:
      - targets: ["nats-server:8222"]
```

### nats CLI Monitoring
```bash
nats server info                  # Server version, cluster, JetStream status
nats server report connections    # Connection report across cluster
nats server report jetstream      # JetStream usage report
nats stream report                # Stream stats (messages, bytes, consumers)
nats consumer report ORDERS       # Consumer lag, ack pending
```

## Client Libraries

| Language | Package         | Install                        |
|----------|----------------|--------------------------------|
| Go       | `nats.go`      | `go get github.com/nats-io/nats.go` |
| Python   | `nats-py`      | `pip install nats-py`          |
| Node.js  | `nats`         | `npm install nats`             |
| Rust     | `async-nats`   | `cargo add async-nats`         |

### Connection Best Practices
```go
// Go — production connection with HA and reconnect
nc, err := nats.Connect("nats://n1:4222,nats://n2:4222,nats://n3:4222",
    nats.Name("order-service"),
    nats.RetryOnFailedConnect(true),
    nats.MaxReconnects(-1),
    nats.ReconnectWait(2*time.Second),
    nats.DisconnectErrHandler(func(nc *nats.Conn, err error) { log.Printf("disconnected: %v", err) }),
    nats.ReconnectHandler(func(nc *nats.Conn) { log.Printf("reconnected to %s", nc.ConnectedUrl()) }),
)
defer nc.Drain() // Always drain, never bare Close()
```

```python
# Python — production connection
nc = await nats.connect(
    servers=["nats://n1:4222", "nats://n2:4222"],
    max_reconnect_attempts=-1, reconnect_time_wait=2,
    error_cb=lambda e: print(f"Error: {e}"),
    disconnected_cb=lambda: print("Disconnected"),
    reconnected_cb=lambda: print("Reconnected"),
)
await nc.drain()  # Always drain on shutdown
```

## Patterns and Anti-Patterns

### DO: Patterns
- **Hierarchical subjects**: `{service}.{entity}.{action}` — enables flexible wildcard routing.
- **Drain on shutdown**: Always call `drain()` before exit to flush pending messages.
- **Explicit ack in JetStream**: Use `AckExplicit` and ack after processing completes.
- **Dedup headers**: Set `Nats-Msg-Id` for exactly-once publish semantics.
- **Connection pooling**: One connection per service; multiplex with subscriptions.
- **Health checks**: Monitor `/healthz` and consumer ack-pending metrics.
- **Idempotent consumers**: Design handlers to tolerate redelivery safely.
- **Pull consumers for work queues**: Better backpressure control than push.
- **Odd replica counts**: Use 1, 3, or 5 replicas for RAFT consensus.

### DON'T: Anti-Patterns
- **Bare `Close()` without `Drain()`**: Causes in-flight message loss.
- **Ignoring acks in JetStream**: Leads to infinite redelivery and resource exhaustion.
- **Overly broad wildcards (`>`) in production subscriptions**: Performance and security risk.
- **Huge messages (>1MB)**: Use Object Store for large payloads; publish a reference.
- **Sync subscribe in async contexts**: Causes deadlocks. Match sub style to runtime.
- **No reconnect handling**: Network is unreliable. Always configure reconnect with backoff.
- **Hardcoded single server URL**: Always pass multiple seed URLs for HA.
- **Skipping TLS in production**: Always enable TLS; use NKey or JWT auth.
- **Unbounded consumer without MaxDeliver**: Poison messages retry forever.
- **Mixing `WorkQueuePolicy` with multiple consumers**: Only one consumer group allowed.

## nats CLI Quick Reference

```bash
nats-server -js -sd /data/jetstream -p 4222 -m 8222     # Start server
nats context save prod --server nats://prod:4222 --creds /etc/nats/user.creds
nats pub orders.created '{"id":"o1"}'                     # Publish
nats sub "orders.>"                                       # Subscribe
nats request svc.echo "hello"                             # Request/Reply
nats stream ls                                            # List streams
nats stream info ORDERS                                   # Stream details
nats stream purge ORDERS --force                          # Purge stream
nats consumer ls ORDERS                                   # List consumers
nats consumer next ORDERS myprocessor --count=5           # Pull messages
nats kv add CONFIG --replicas=3                           # Create KV bucket
nats kv put CONFIG app.version "2.1.0"                    # Set key
nats kv get CONFIG app.version                            # Get key
nats object add BLOBS --replicas=3                        # Create object store
nats object put BLOBS ./file.tar.gz                       # Upload object
nats bench test.subject --pub 5 --sub 5 --msgs 1000000   # Benchmark
```

## Additional Resources

### Reference Documents

| Document | Contents |
|----------|----------|
| [advanced-patterns.md](references/advanced-patterns.md) | Mirrors/sources, de-duplication, flow control, Service API, micro framework, subject transforms, import/export, WebSocket, MQTT bridge, request/reply at scale, header routing, exactly-once, DLQ |
| [troubleshooting.md](references/troubleshooting.md) | Slow consumers, message loss, storage issues, split-brain, auth failures, draining, memory pressure, consumer stall, stream repair, Prometheus monitoring |
| [operations-guide.md](references/operations-guide.md) | Cluster sizing, TLS, OCSP, nsc account management, resolver config, backup/restore, rolling upgrades, resource limits, logging, Grafana dashboards, DR |
| [security-guide.md](references/security-guide.md) | Authentication methods, authorization, TLS, account isolation |
| [jetstream-patterns.md](references/jetstream-patterns.md) | JetStream usage patterns and examples |

### Scripts

| Script | Purpose |
|--------|---------|
| [setup-cluster.sh](scripts/setup-cluster.sh) | Deploy NATS cluster (Docker or bare-metal) with JetStream. `--nodes 3\|5`, `--docker\|--bare-metal`, `--clean` |
| [health-check.sh](scripts/health-check.sh) | Check health: connections, JetStream, cluster, slow consumers. `--server URL`, `--json` |
| [stream-manager.sh](scripts/stream-manager.sh) | Manage streams/consumers: create, update, purge, backup/restore. `<command> [options]` |
| [benchmark-nats.sh](scripts/benchmark-nats.sh) | NATS throughput and latency benchmarks |

### Assets

| File | Description |
|------|-------------|
| [nats-server.conf](assets/nats-server.conf) | Production config: JetStream, clustering, TLS, NKey auth, gateways, leaf nodes, WebSocket, MQTT |
| [docker-compose.yaml](assets/docker-compose.yaml) | 3-node cluster with JetStream, Prometheus exporter, nats-box |
| [kubernetes-helm-values.yaml](assets/kubernetes-helm-values.yaml) | Helm values: JetStream, clustering, TLS, monitoring, PDB, topology spread |
| [go-client-example.go](assets/go-client-example.go) | Go client example |
| [python-client-example.py](assets/python-client-example.py) | Python client example |
