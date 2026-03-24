# NATS Troubleshooting Guide

Practical diagnostics and fixes for common NATS issues in production.

## Table of Contents

- [1. Slow Consumers](#1-slow-consumers)
- [2. Message Loss Debugging](#2-message-loss-debugging)
- [3. Connection Issues](#3-connection-issues)
- [4. Cluster Split-Brain](#4-cluster-split-brain)
- [5. JetStream Resource Exhaustion](#5-jetstream-resource-exhaustion)
- [6. Client Reconnection Handling](#6-client-reconnection-handling)
- [7. Auth Failures](#7-auth-failures)
- [8. Leaf Node Connectivity](#8-leaf-node-connectivity)
- [9. Monitoring with nats-top](#9-monitoring-with-nats-top)
- [10. Tracing with Headers](#10-tracing-with-headers)

---

## 1. Slow Consumers

Server logs emit warnings when a client can't keep up:

```
[WRN] 192.168.1.40:52130 - cid:87 - "orders-processor" - Slow Consumer Detected
[WRN] 192.168.1.40:52130 - cid:87 - Slow Consumer (Dropped: 1482)
```

**Detection** — sort connections by pending count:

```bash
nats server report connections --sort pending
# CID │ Name              │ Pending │ Msgs Out
#  87 │ orders-processor  │  48,210 │  1.2M
#  45 │ analytics-ingest  │  12,004 │  890K
```

**Causes:** blocking handlers (sync DB writes, HTTP calls in callbacks), insufficient throughput on a single subscriber, broad wildcard subscriptions matching more subjects than expected.

**Fixes:**

```
# nats-server.conf — increase write buffer
max_pending: 67108864    # 64MB per connection
write_deadline: "10s"
```

Use queue groups to distribute load, and batch processing to reduce per-message overhead:

```go
sub, _ := nc.QueueSubscribe("orders.created", "order-workers", handler)

// JetStream pull consumer with batching
sub, _ := js.PullSubscribe("orders.>", "batch-processor")
msgs, _ := sub.Fetch(100, nats.MaxWait(5*time.Second))
```

Enable **push consumer flow control** so the server pauses instead of dropping:

```bash
nats consumer add ORDERS flow-processor \
  --flow-control --idle-heartbeat 5s --ack explicit --max-pending 10000
```

Set **client-side pending limits**:

```go
sub, _ := nc.Subscribe("events.>", handler)
sub.SetPendingLimits(500_000, 256*1024*1024) // 500K msgs, 256MB
```

---

## 2. Message Loss Debugging

Core NATS = **at-most-once** (no subscribers → message gone). JetStream = **at-least-once** with persistence and acks. Losing messages on core NATS is by design — use JetStream.

**Check stream and consumer state:**

```bash
nats stream info ORDERS
#   Messages: 1,482,901 | First Seq: 102 | Last Seq: 1,483,002 | Num Deleted: 214

nats consumer info ORDERS order-processor
#   Num Ack Pending: 140    ← delivered but not acked
#   Num Redelivered:  23    ← re-sent after ack timeout
```

Growing `Num Ack Pending` = consumer receives but doesn't ack. Check for exceptions before `msg.Ack()`, ack timeout too short, or client crashes.

**Subscribe to JetStream advisories** to track delivery issues:

```bash
nats sub '$JS.EVENT.ADVISORY.>'
# Key subjects:
#   $JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.<stream>.<consumer>
#   $JS.EVENT.ADVISORY.CONSUMER.MSG_TERMINATED.<stream>.<consumer>
```

**Common causes:**

| Cause | Symptom | Fix |
|-------|---------|-----|
| No subscribers (core NATS) | Messages never received | Use JetStream |
| Slow consumer drops | `Slow Consumer (Dropped: N)` in logs | Flow control, queue groups |
| Stream limits exceeded | `First Sequence` advances | Increase `max_msgs`/`max_bytes`/`max_age` |
| Max delivery exceeded | `MAX_DELIVERIES` advisory | Increase `max_deliver`, fix processing errors |
| Ack timeout too short | `Num Redelivered` climbs | Increase `ack_wait` |

---

## 3. Connection Issues

**Port requirements:**

| Port | Purpose |
|------|---------|
| 4222 | Client connections |
| 6222 | Cluster routing |
| 7422 | Leaf nodes |
| 8222 | Monitoring HTTP |

```bash
dig nats.internal.example.com +short
nc -zv nats-server.example.com 4222 6222 8222
nats server ping    # nats-1 rtt=1.23ms | nats-2 rtt=2.45ms | nats-3 rtt=1.89ms
```

**TLS handshake failures** — common log errors:

```
[ERR] TLS handshake error: x509: certificate signed by unknown authority
```

```bash
openssl s_client -connect nats-server:4222 </dev/null 2>&1 | openssl x509 -noout -dates -subject
openssl verify -CAfile /etc/nats/ca.pem /etc/nats/server-cert.pem
```

**Reconnection config:**

```go
nc, _ := nats.Connect("nats://s1:4222,nats://s2:4222,nats://s3:4222",
    nats.Timeout(10*time.Second),        nats.MaxReconnects(-1),
    nats.ReconnectWait(2*time.Second),   nats.ReconnectBufSize(16*1024*1024),
    nats.ReconnectJitter(500*time.Millisecond, 5*time.Second),
    nats.PingInterval(20*time.Second),   nats.MaxPingsOutstanding(3),
)
```

**Max payload exceeded** — default is 1MB. Check with `curl -s http://localhost:8222/varz | jq '.max_payload'`. Increase in config: `max_payload: 8388608` (use object store for larger data).

---

## 4. Cluster Split-Brain

JetStream uses **Raft consensus**. Each stream has a Raft group with leader + followers. A leader needs a **quorum** (majority): 3-node cluster tolerates 1 failure, 5-node tolerates 2. Never run 2-node clusters — losing one node means no quorum.

**Detection:**

```bash
nats server report jetstream
# Server  │ Streams │ Messages │ Meta Leader
# nats-1  │     12  │    1.2M  │ yes
# nats-2  │     12  │    1.2M  │
# nats-3* │      0  │       0  │          ← partitioned or lagging

nats stream info ORDERS --json | jq '.cluster.replicas[] | {name, current, active, lag}'
# {"name":"nats-3","current":false,"active":"45s","lag":12840}  ← behind
```

If no meta leader exists, all JetStream API ops fail with `nats: no JetStream meta leader found`. Verify majority of servers can communicate over port 6222:

```bash
curl -s http://nats-1:8222/routez | jq '.routes[] | {remote_id, ip, port}'
```

**Force leader stepdown** when a stream leader is unhealthy:

```bash
nats stream cluster step-down ORDERS
nats consumer cluster step-down ORDERS order-processor
```

After partition heals, Raft automatically reconciles — monitor with:

```bash
watch -n 2 'nats stream info ORDERS --json | jq ".cluster.replicas[]"'
```

---

## 5. JetStream Resource Exhaustion

**Symptoms:** `nats: insufficient resources` or `JetStream resource limits exceeded`.

```bash
nats account info
#   Memory:  1.0GB / 1.0GB (100%)  ← exhausted
#   Storage: 18GB / 50GB (36%)
#   Streams: 24 / unlimited

curl -s http://localhost:8222/jsz | jq '{memory_used, store_used, store_reserved}'
df -h /data/nats/jetstream
```

**Setting limits** — server-level:

```
jetstream { store_dir: "/data/nats/jetstream"; max_mem: 4GB; max_file: 100GB }
```

Per-stream:

```bash
nats stream edit ORDERS --max-msgs 10000000 --max-bytes 10GB --max-age 72h --discard old
```

**Cleanup:**

```bash
nats stream purge ORDERS --force          # purge all
nats stream purge ORDERS --keep 1000      # keep last 1000
nats stream rm OLD_EVENTS --force
nats consumer rm ORDERS stale-consumer --force

# Find ephemeral consumer bloat
for s in $(nats stream ls -n); do echo "$s: $(nats consumer ls "$s" -n | wc -l)"; done
```

---

## 6. Client Reconnection Handling

**Reconnect callbacks** — essential for observability:

```go
nc, _ := nats.Connect("nats://localhost:4222",
    nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
        log.Printf("Disconnected: %v", err)
    }),
    nats.ReconnectHandler(func(nc *nats.Conn) {
        log.Printf("Reconnected to %s", nc.ConnectedUrl())
    }),
    nats.ClosedHandler(func(nc *nats.Conn) {
        log.Printf("Connection closed: %v", nc.LastError())
    }),
)
```

During reconnect, the client **buffers publishes** in memory (default 8MB). Configure with `nats.ReconnectBufSize(32*1024*1024)`. If the buffer fills, `Publish()` returns an error.
**Drain mode** for graceful shutdown — unsubscribes, processes pending, flushes, then closes:

```go
sigCh := make(chan os.Signal, 1)
signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
go func() { <-sigCh; nc.Drain() }()
```

**Reconnect jitter** prevents thundering herd after server restarts:

```go
nats.ReconnectJitter(100*time.Millisecond, 2*time.Second)
```

**Stale connection detection** — server-side: `ping_interval: 20` and `ping_max: 3` in config.

---

## 7. Auth Failures

Start server with debug flags: `nats-server -c nats.conf -DV`

**NKey errors** — verify seed/public key match:

```bash
nsc describe user -a MyAccount -n MyUser
nats pub test "hello" --nkey /path/to/user.nk
```

Common issues: wrong file permissions on seed, mixing account NKeys with user NKeys.

**JWT expired** — decode and check:

```bash
nsc describe user -a MyAccount -n MyUser --json | jq '.exp'
nsc generate creds -a MyAccount -n MyUser -o /path/to/user.creds  # reissue
```

**Credential file format** — must contain both JWT and NKey seed sections. Malformed files (extra whitespace, missing delimiters) fail silently.

**Permission violations:**

```
[ERR] Permissions Violation for Publish to "orders.create"
```

```bash
nsc describe user -a MyAccount -n MyUser --json | jq '.nats | {pub, sub}'
```

Static permissions in server config:

```
authorization {
  users = [{
    user: "order-svc", password: "$2a$11$..."
    permissions: {
      publish:   { allow: ["orders.>", "$JS.API.>"], deny: ["admin.>"] }
      subscribe: { allow: ["orders.>", "_INBOX.>"] }
    }
  }]
}
```

**Account connection limits exceeded:**

```bash
curl -s http://localhost:8222/accountz?acc=ORDERS_SVC | jq '{num_connections, limits}'
```

---

## 8. Leaf Node Connectivity

**Handshake failures:**

```
[ERR] Error trying to connect as leafnode: dial tcp 10.0.1.10:7422: connection refused
```

Hub-side config:

```
leafnodes { port: 7422; tls { cert_file: "..."; key_file: "..."; ca_file: "..." } }
```

Leaf-side config with **account mapping** (misconfiguration causes silent routing failures):

```
leafnodes {
  remotes [{
    urls: ["nats-leaf://hub:7422"]
    account: "EDGE_ORDERS"
    credentials: "/etc/nats/edge.creds"
  }]
}
```

**Monitoring:**

```bash
curl -s http://hub-nats:8222/leafz | jq '.leafs[] | {name, account, rtt, in_msgs, out_msgs}'
```

**High-latency links** — increase timeouts:

```
ping_interval: 30
ping_max: 5
write_deadline: "30s"
```

---

## 9. Monitoring with nats-top

```bash
go install github.com/nats-io/nats-top@latest
nats-top -s http://nats-server:8222 -d 2
# Server: CPU 12.3%  Memory: 245.2M  Slow Consumers: 2
# In: 4.2K/s  Out: 8.1K/s
#   CID  NAME               PENDING  MSGS_TO  BYTES_TO
#    87  orders-processor    48210    1.2M     4.5GB
```

**Key metrics:** CPU >80% = overloaded, Slow Consumers >0 = investigate, high Pending = slow consumer. Interactive keys: `o` sort, `n` limit, `s` refresh, `q` quit.

**Alerting** — Prometheus rules:

```yaml
- alert: NATSSlowConsumers
  expr: nats_varz_slow_consumers > 0
  for: 2m
- alert: NATSJetStreamStorageHigh
  expr: (nats_server_jetstream_store_used / nats_server_jetstream_store_reserved) > 0.85
  for: 5m
```

---

## 10. Tracing with Headers

NATS 2.2+ supports message headers for distributed tracing.

```go
msg := nats.NewMsg("orders.created")
msg.Data = orderJSON
msg.Header.Set("Nats-Trace-Dest", "trace.orders")  // server-side trace routing
msg.Header.Set("X-Trace-Id", "abc-123-def-456")
msg.Header.Set("X-Origin-Service", "api-gateway")
nc.PublishMsg(msg)
```

**Request ID propagation** in request-reply chains:

```go
func handleValidate(msg *nats.Msg) {
    requestID := msg.Header.Get("X-Request-Id")
    downstream := nats.NewMsg("inventory.check")
    downstream.Header.Set("X-Request-Id", requestID)
    reply, _ := nc.RequestMsg(downstream, 3*time.Second)
    msg.Respond(reply.Data)
}
```

**Correlating logs:**

```bash
cat /var/log/services/orders.log | jq 'select(.request_id == "abc-123-def-456")'
```

**Useful header patterns** for production systems:

```go
msg.Header.Set("X-Idempotency-Key", "order-12345-create")  // dedup
msg.Header.Set("X-Schema-Version", "2.1")                  // schema evolution
msg.Header.Set("X-Retry-Count", strconv.Itoa(retryCount))  // dead-letter metadata
```

---

## Quick Reference

```bash
nats server report connections           # connection health
nats server report jetstream             # JetStream cluster state
nats server ping                         # RTT to all servers
nats stream info <STREAM>               # stream state
nats consumer info <STREAM> <CONSUMER>  # consumer lag
curl http://localhost:8222/healthz       # health check
curl http://localhost:8222/jsz           # JetStream resources
curl http://localhost:8222/connz         # connections
curl http://localhost:8222/leafz         # leaf nodes
nats-server -c nats.conf -DV            # debug mode
```
