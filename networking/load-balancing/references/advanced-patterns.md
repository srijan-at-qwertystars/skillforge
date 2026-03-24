# Advanced Load Balancing Patterns

## Table of Contents

- [Consistent Hashing with Virtual Nodes](#consistent-hashing-with-virtual-nodes)
- [Power of Two Random Choices](#power-of-two-random-choices)
- [Least-Loaded with Slow Start](#least-loaded-with-slow-start)
- [Blue-Green Deployments with Load Balancers](#blue-green-deployments-with-load-balancers)
- [Canary Routing](#canary-routing)
- [Request Hedging](#request-hedging)
- [Priority-Based Routing](#priority-based-routing)
- [Circuit Breaker Integration](#circuit-breaker-integration)
- [Multi-Region Failover with GSLB](#multi-region-failover-with-gslb)
- [LB for Microservices: Sidecar vs Centralized](#lb-for-microservices-sidecar-vs-centralized)

---

## Consistent Hashing with Virtual Nodes

### Problem

Standard consistent hashing maps each physical server to a single point on the hash ring.
When servers have different capacities or when the pool is small, the distribution becomes
uneven — some servers own a much larger arc of the ring than others.

### Solution: Virtual Nodes (vnodes)

Map each physical server to **multiple points** (virtual nodes) on the ring. A server with
higher capacity gets more vnodes. This smooths the distribution and limits the "blast radius"
when a server is added or removed.

```
Physical Server A (4 CPU) → 400 vnodes
Physical Server B (2 CPU) → 200 vnodes
Physical Server C (2 CPU) → 200 vnodes
```

### How It Works

1. For each physical server, generate `N` hash values (e.g., `hash(server_id + "-" + i)` for
   `i` in `0..N`).
2. Place all virtual nodes on the ring (sorted by hash value).
3. To route a request, hash the key and walk clockwise to the first vnode.
4. Map the vnode back to the physical server.

### Tuning Vnodes

| Vnodes per server | Distribution quality | Memory overhead | Lookup speed |
|--------------------|----------------------|-----------------|--------------|
| 50                 | Moderate             | Low             | Fast         |
| 150                | Good                 | Medium          | Fast         |
| 500+               | Excellent            | Higher          | Slightly slower (binary search) |

For most production setups, **100-200 vnodes per server** provides excellent balance.

### Implementation Sketch (Python)

```python
import hashlib
from bisect import bisect_right

class ConsistentHashRing:
    def __init__(self, vnodes_per_server=150):
        self.vnodes_per_server = vnodes_per_server
        self.ring = []          # sorted list of (hash, server)
        self.hash_keys = []     # sorted hashes for binary search

    def _hash(self, key: str) -> int:
        return int(hashlib.md5(key.encode()).hexdigest(), 16)

    def add_server(self, server: str, weight: int = 1):
        for i in range(self.vnodes_per_server * weight):
            h = self._hash(f"{server}:vnode{i}")
            self.ring.append((h, server))
        self.ring.sort(key=lambda x: x[0])
        self.hash_keys = [h for h, _ in self.ring]

    def remove_server(self, server: str):
        self.ring = [(h, s) for h, s in self.ring if s != server]
        self.hash_keys = [h for h, _ in self.ring]

    def get_server(self, key: str) -> str:
        if not self.ring:
            raise ValueError("No servers in ring")
        h = self._hash(key)
        idx = bisect_right(self.hash_keys, h) % len(self.ring)
        return self.ring[idx][1]
```

### When to Use

- **Caching layers** (Memcached, Redis cluster) — minimizes cache invalidation on topology change.
- **Stateful services** where requests for the same entity should land on the same server.
- **Sharded databases** behind an application-level load balancer.
- **CDN edge routing** — map content keys to edge nodes.

### Pitfalls

- Hash function quality matters: MD5/SHA1 give good distribution; CRC32 does not.
- With replication, walk the ring to find `R` _distinct physical servers_, skipping vnodes
  belonging to the same server.
- Monitor per-server request rates; even with vnodes, distribution can drift under skewed key
  distributions.

---

## Power of Two Random Choices

### Concept

Instead of tracking the global state of all backends, pick **two backends at random** and
route the request to the one with the lower load. This simple algorithm achieves exponentially
better load distribution than pure random selection — the "power of two choices" phenomenon.

### How It Works

1. Randomly select two backends from the pool.
2. Query their current load (active connections, CPU, queue depth).
3. Route to the backend with the lower metric.

### Mathematical Insight

- Pure random: max load is `O(log n / log log n)` with `n` requests.
- Two random choices: max load drops to `O(log log n)` — an exponential improvement.
- Three or more choices provide diminishing returns over two.

### Nginx Implementation (via Lua)

```nginx
upstream app {
    server 10.0.1.1:8080;
    server 10.0.1.2:8080;
    server 10.0.1.3:8080;
    server 10.0.1.4:8080;
    # Use random with two choices (Nginx 1.15.1+)
    random two least_conn;
}
```

### Envoy Implementation

```yaml
clusters:
  - name: app_cluster
    lb_policy: RANDOM
    load_assignment:
      endpoints:
        - lb_endpoints:
            - endpoint: { address: { socket_address: { address: 10.0.1.1, port_value: 8080 }}}
            - endpoint: { address: { socket_address: { address: 10.0.1.2, port_value: 8080 }}}
    common_lb_config:
      choice_count: 2
```

### When to Use

- Large backend pools (10+ servers) where global state is expensive to maintain.
- Distributed load balancers where sharing state across LB instances is impractical.
- As a default algorithm when you have no strong reason to prefer another.

---

## Least-Loaded with Slow Start

### Problem

When a new backend joins the pool (auto-scaling, deploy, recovery), least-connections
immediately floods it because it has zero active connections. The cold server — JVM warming,
cache empty, connections not pooled — gets overwhelmed.

### Solution: Slow Start

Gradually ramp up traffic to new backends over a configurable window.

### Nginx Slow Start

```nginx
upstream app {
    least_conn;
    server 10.0.1.1:8080 weight=5 slow_start=30s;
    server 10.0.1.2:8080 weight=5 slow_start=30s;
}
```

The server's effective weight starts at 1 and linearly increases to the configured `weight`
over the `slow_start` duration.

### HAProxy Slow Start

```haproxy
backend app_servers
    balance leastconn
    server app1 10.0.1.1:8080 check weight 100 slowstart 60s
    server app2 10.0.1.2:8080 check weight 100 slowstart 60s
```

### AWS ALB Slow Start

Configure via target group attributes:

```
aws elbv2 modify-target-group-attributes \
  --target-group-arn <arn> \
  --attributes Key=slow_start.duration_seconds,Value=60
```

### Best Practices

- Set slow start duration to match your application's warm-up time (JIT compilation, cache
  priming, connection pool initialization).
- Monitor request latency on the new server during ramp-up.
- Combine with health checks: only start ramping after health check passes.
- Typical slow start windows: 30-120 seconds.

---

## Blue-Green Deployments with Load Balancers

### Architecture

Maintain two identical production environments: **Blue** (current) and **Green** (new version).
The load balancer switches traffic atomically between them.

```
                  ┌──────────────┐
     ┌───────────►│  Blue (v1)   │ ← current production
     │            └──────────────┘
┌────┴───┐
│  LB    │
└────┬───┘
     │            ┌──────────────┐
     └───────────►│  Green (v2)  │ ← new version (staged)
                  └──────────────┘
```

### Implementation with HAProxy

```haproxy
backend blue
    server blue1 10.0.1.10:8080 check
    server blue2 10.0.1.11:8080 check

backend green
    server green1 10.0.2.10:8080 check
    server green2 10.0.2.11:8080 check

frontend http
    bind *:80
    # Toggle via runtime API or config reload
    use_backend green
    # To rollback: use_backend blue
```

Switch via HAProxy runtime API (no reload needed):

```bash
echo "set server blue/blue1 state maint" | socat stdio /var/run/haproxy.sock
echo "set server green/green1 state ready" | socat stdio /var/run/haproxy.sock
```

### Implementation with AWS ALB

```bash
# Switch target group on listener rule
aws elbv2 modify-listener \
  --listener-arn <arn> \
  --default-actions Type=forward,TargetGroupArn=<green-tg-arn>
```

### Rollback

If the green environment fails validation:
1. Switch the LB back to blue.
2. Investigate issues on green.
3. Fix and redeploy green.

### Considerations

- Both environments must be fully provisioned (2x infrastructure cost during transition).
- Database migrations must be backward-compatible (blue must work with the new schema).
- Session data: use external session store (Redis) so sessions survive the switch.
- DNS TTL should be low if using DNS-based switching.

---

## Canary Routing

### Concept

Route a small percentage of traffic to the new version while the majority stays on the stable
version. Gradually increase the canary percentage as confidence grows.

### Traffic Split Strategies

| Stage     | Canary % | Duration | Validation                    |
|-----------|----------|----------|-------------------------------|
| Initial   | 1%       | 15 min   | Error rate, latency p99       |
| Expand    | 5%       | 30 min   | Business metrics, conversions |
| Ramp      | 25%      | 1 hour   | Resource utilization          |
| Majority  | 50%      | 2 hours  | Full regression               |
| Complete  | 100%     | —        | Remove old version            |

### Nginx Canary with Split Clients

```nginx
split_clients "${remote_addr}" $variant {
    5%     canary;
    *      stable;
}

upstream stable_backend {
    server 10.0.1.10:8080;
    server 10.0.1.11:8080;
}

upstream canary_backend {
    server 10.0.2.10:8080;
}

server {
    listen 80;
    location / {
        proxy_pass http://${variant}_backend;
    }
}
```

### HAProxy Canary with Weighted Backends

```haproxy
backend app
    balance roundrobin
    server stable1 10.0.1.10:8080 check weight 95
    server stable2 10.0.1.11:8080 check weight 95
    server canary1 10.0.2.10:8080 check weight 5
```

### Header-Based Canary (for internal testing)

```nginx
map $http_x_canary $backend {
    "true"   canary_backend;
    default  stable_backend;
}

server {
    listen 80;
    location / {
        proxy_pass http://$backend;
    }
}
```

### Automated Canary Analysis

Integrate with metrics to auto-promote or rollback:

```bash
# Pseudo-code for canary analysis
CANARY_ERROR_RATE=$(curl -s prometheus/api/v1/query?query=rate(http_errors{version="canary"}[5m]))
STABLE_ERROR_RATE=$(curl -s prometheus/api/v1/query?query=rate(http_errors{version="stable"}[5m]))

if (( $(echo "$CANARY_ERROR_RATE > $STABLE_ERROR_RATE * 1.5" | bc -l) )); then
    echo "Canary error rate too high — rolling back"
    # Rollback canary
else
    echo "Canary healthy — promoting"
    # Increase canary weight
fi
```

---

## Request Hedging

### Concept

Send the same request to **multiple backends simultaneously** and use the first response that
arrives. Cancel the remaining in-flight requests. This reduces tail latency at the cost of
increased backend load.

### When to Use

- Latency-sensitive services where p99 matters more than throughput.
- Read-only or idempotent requests (never hedge mutating operations).
- When backend latency variance is high (some requests occasionally take 10x longer).

### Strategies

| Strategy            | Description                                          | Overhead |
|---------------------|------------------------------------------------------|----------|
| Eager hedging       | Send to 2+ backends immediately                     | 2x+ load |
| Delayed hedging     | Send to one; if no response in `T` ms, send to another | Lower   |
| Budget-based        | Hedge only if recent p99 > threshold                 | Minimal  |

### Delayed Hedging Example (Envoy)

```yaml
clusters:
  - name: app
    lb_policy: ROUND_ROBIN
    outlier_detection:
      consecutive_5xx: 3
    # Envoy retry policy with hedging
    retry_policy:
      retry_on: "5xx,reset,connect-failure"
      num_retries: 1
      hedge_policy:
        initial_requests: 1
        additional_requests: 1
        hedge_on_per_try_timeout: true
      per_try_timeout: 100ms
```

### Safeguards

- **Budget**: Limit hedged requests to ≤10% of total traffic to avoid cascading overload.
- **Idempotency**: Only hedge reads or idempotent writes (with idempotency keys).
- **Cancellation**: Cancel losing requests promptly to free backend resources.
- **Monitoring**: Track hedge rate and compare latency improvements vs overhead.

---

## Priority-Based Routing

### Concept

Classify incoming requests by priority (critical, normal, background) and route them to
dedicated backend pools or apply different QoS policies.

### Use Cases

- **Payment processing** → high-priority pool with dedicated capacity.
- **Search/browse** → normal-priority shared pool.
- **Reports/exports** → low-priority pool, can be rate-limited.

### HAProxy Implementation

```haproxy
frontend http
    bind *:80

    # Classify by path
    acl is_payment path_beg /api/payments /api/checkout
    acl is_background path_beg /api/reports /api/exports
    acl is_internal hdr(X-Priority) high

    use_backend priority_high if is_payment or is_internal
    use_backend priority_low if is_background
    default_backend priority_normal

backend priority_high
    balance leastconn
    option httpchk GET /healthz
    server pay1 10.0.1.10:8080 check weight 100
    server pay2 10.0.1.11:8080 check weight 100

backend priority_normal
    balance roundrobin
    server app1 10.0.2.10:8080 check
    server app2 10.0.2.11:8080 check
    server app3 10.0.2.12:8080 check

backend priority_low
    balance roundrobin
    rate-limit sessions 50
    server bg1 10.0.3.10:8080 check maxconn 20
    server bg2 10.0.3.11:8080 check maxconn 20
```

### Nginx Implementation

```nginx
map $uri $priority_backend {
    ~^/api/payments   priority_high;
    ~^/api/checkout   priority_high;
    ~^/api/reports    priority_low;
    default           priority_normal;
}

upstream priority_high {
    least_conn;
    server 10.0.1.10:8080;
    server 10.0.1.11:8080;
}

upstream priority_normal {
    server 10.0.2.10:8080;
    server 10.0.2.11:8080;
    server 10.0.2.12:8080;
}

upstream priority_low {
    server 10.0.3.10:8080 max_conns=20;
    server 10.0.3.11:8080 max_conns=20;
}

server {
    listen 80;
    location / {
        proxy_pass http://$priority_backend;
    }
}
```

---

## Circuit Breaker Integration

### Concept

A circuit breaker at the LB layer automatically stops sending traffic to a failing backend,
gives it time to recover, then gradually reintroduces traffic. Three states:

```
CLOSED (normal) → error threshold exceeded → OPEN (all requests fail fast)
    ↑                                              │
    │                    timeout expires            ▼
    └──────────────── HALF-OPEN (probe traffic) ───┘
                      (success → CLOSED, failure → OPEN)
```

### Envoy Circuit Breaker Configuration

```yaml
clusters:
  - name: app
    connect_timeout: 5s
    circuit_breakers:
      thresholds:
        - priority: DEFAULT
          max_connections: 1000
          max_pending_requests: 500
          max_requests: 1500
          max_retries: 3
    outlier_detection:
      consecutive_5xx: 5
      interval: 10s
      base_ejection_time: 30s
      max_ejection_percent: 50
      enforcing_consecutive_5xx: 100
```

### HAProxy Circuit Breaker (via observe + error-limit)

```haproxy
backend app
    balance roundrobin
    option httpchk GET /healthz

    # Passive health checks act as circuit breaker
    default-server inter 5s fall 3 rise 2 observe layer7 error-limit 10 on-error mark-down

    server app1 10.0.1.10:8080 check
    server app2 10.0.1.11:8080 check
```

### LB + Application Circuit Breaker

For defense in depth, combine LB-level circuit breakers with application-level breakers:

| Layer        | Tool               | Scope                       |
|--------------|--------------------|-----------------------------|
| LB           | Envoy outlier detection | Per-backend host ejection |
| Application  | Hystrix / Resilience4j | Per-dependency call isolation |

The LB breaker removes bad hosts from the pool. The application breaker protects against slow
dependencies (databases, third-party APIs) that the LB cannot observe.

---

## Multi-Region Failover with GSLB

### Architecture

```
                    ┌─────────────┐
                    │  GSLB / DNS │
                    └──────┬──────┘
              ┌────────────┼────────────┐
              ▼            ▼            ▼
         ┌────────┐   ┌────────┐   ┌────────┐
         │ US-East│   │ EU-West│   │ AP-SE  │
         │  ALB   │   │  ALB   │   │  ALB   │
         └───┬────┘   └───┬────┘   └───┬────┘
             ▼            ▼            ▼
          Backends     Backends     Backends
```

### DNS-Based Failover (AWS Route 53)

```json
{
  "Name": "api.example.com",
  "Type": "A",
  "AliasTarget": {
    "DNSName": "us-east-1-alb.amazonaws.com",
    "EvaluateTargetHealth": true
  },
  "Failover": "PRIMARY",
  "SetIdentifier": "us-east-1",
  "HealthCheckId": "hc-us-east-1"
}
```

### Failover Decision Matrix

| Scenario                        | Action                               | RTO    |
|---------------------------------|--------------------------------------|--------|
| Single backend fails            | Regional LB removes it               | <10s   |
| All backends in AZ fail         | Regional LB routes to other AZs      | <30s   |
| Entire region fails             | GSLB routes to secondary region      | 1-5min |
| DNS propagation delay           | Use low TTL (60s) + health checks    | ~60s   |

### Active-Active vs Active-Passive

**Active-Active:**
- All regions serve traffic simultaneously.
- Requires data replication (async or sync) across regions.
- GSLB uses latency-based or geolocation routing.
- Higher availability, lower latency, but complex data consistency.

**Active-Passive:**
- Primary region handles all traffic; secondary is on standby.
- GSLB health checks trigger failover to secondary.
- Simpler data model (replicate from primary to secondary).
- Higher RTO due to cold start of passive region.

### Cross-Region Data Considerations

- **Database**: Use read replicas in each region. Write to primary, async replicate.
- **Sessions**: Use global session store (DynamoDB Global Tables, Redis with CRDT).
- **Caching**: Each region maintains its own cache. Expect cache cold start on failover.
- **Conflict resolution**: For active-active writes, implement last-writer-wins or CRDT.

---

## LB for Microservices: Sidecar vs Centralized

### Centralized Load Balancer

A dedicated LB (hardware or software) sits between service consumers and providers.

```
Client → Central LB → Service A
                    → Service B
                    → Service C
```

**Pros:**
- Single point of management and observability.
- Simpler client configuration (all clients point to the LB).
- Centralized policy enforcement (rate limiting, auth).

**Cons:**
- Single point of failure (mitigated by HA pairs).
- Extra network hop adds latency.
- LB must scale with total cluster traffic.

### Sidecar / Client-Side Load Balancer

Each service instance has its own LB (sidecar proxy or library) that discovers backends and
routes directly.

```
Service A → [sidecar proxy] → Service B instance 1
                            → Service B instance 2
                            → Service B instance 3
```

**Examples:** Envoy (Istio sidecar), Linkerd proxy, gRPC client-side LB, Netflix Ribbon.

**Pros:**
- No single point of failure.
- Eliminates extra network hop (direct pod-to-pod).
- Each service can have its own routing/retry/circuit-breaker policy.
- Scales naturally with the number of service instances.

**Cons:**
- Higher resource consumption (one proxy per pod).
- Distributed configuration and observability complexity.
- Requires service discovery integration (Consul, Kubernetes DNS).

### Comparison Table

| Aspect               | Centralized LB        | Sidecar LB               |
|-----------------------|-----------------------|---------------------------|
| Latency              | Extra hop              | Direct connection         |
| Failure blast radius | High (affects all)     | Low (per-service)         |
| Config management    | Centralized            | Distributed (control plane)|
| Resource overhead    | Dedicated infra        | Per-pod sidecar (~50MB)   |
| Observability        | Single pane            | Distributed tracing required |
| Best for             | North-south traffic    | East-west (service-to-service) |

### Hybrid Approach

Use **centralized LB** for north-south traffic (external → cluster ingress) and **sidecar
proxies** for east-west traffic (service-to-service within the cluster). This is the standard
pattern in Kubernetes with an Ingress controller + Istio/Linkerd service mesh.

```
External → [Ingress / ALB] → [Envoy sidecar] → Service A
                                              → [Envoy sidecar] → Service B
                                              → [Envoy sidecar] → Service C
```
