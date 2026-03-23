---
name: microservices-patterns
description:
  positive: >
    Use when user designs microservices architecture, asks about service decomposition,
    API gateway patterns, circuit breaker, service mesh (Istio, Linkerd), distributed
    transactions, sidecar pattern, or inter-service communication.
  negative: >
    Do NOT use for monolithic application design, event-driven architecture specifics
    (use event-driven-architecture skill), or Kafka specifics (use kafka-event-streaming skill).
---

# Microservices Design Patterns

## Service Decomposition Strategies

### By Business Capability

Map services to business functions. Each service owns its domain end-to-end.

```
┌─────────────────────────────────────────────┐
│              E-Commerce System              │
├──────────┬──────────┬─────────┬─────────────┤
│  Order   │Inventory │ Payment │Notification │
│ - create │ - check  │ - charge│ - email     │
│ - cancel │ - reserve│ - refund│ - sms/push  │
└──────────┴──────────┴─────────┴─────────────┘
```

- One team owns one service. Align to Conway's Law.
- Keep bounded contexts explicit — never share domain models across services.

### By Subdomain (DDD)

| Subdomain Type | Example             | Build vs Buy |
|----------------|---------------------|--------------|
| Core           | Pricing engine      | Build        |
| Supporting     | Customer onboarding | Build/buy    |
| Generic        | Email delivery      | Buy (SaaS)   |

### Strangler Fig Pattern

Incrementally replace a monolith by routing traffic to new services:

```
         ┌──────────────┐
Request ─┤  API Gateway  │
         └──┬────────┬───┘
      ┌─────▼───┐ ┌──▼──────────┐
      │   New   │ │   Legacy    │
      │ Service │ │  Monolith   │
      └─────────┘ └─────────────┘
```

1. Place a facade (gateway) in front of the monolith.
2. Implement one bounded context as a new service.
3. Redirect matching routes to the new service.
4. Repeat until monolith is decommissioned.

---

## Communication Patterns

### Synchronous

| Protocol | Use When                               | Avoid When                     |
|----------|----------------------------------------|--------------------------------|
| REST     | CRUD, public APIs, broad compatibility | High-throughput internal calls |
| gRPC     | Internal calls, streaming, low latency | Browser clients (use gRPC-Web) |

```protobuf
service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (OrderResponse);
  rpc StreamUpdates(OrderId) returns (stream OrderEvent);
}
```

### Asynchronous

Use message brokers (RabbitMQ, NATS) or event streaming (Kafka, Pulsar) for:
- Fire-and-forget commands
- Event notification across bounded contexts
- Temporal decoupling (producer/consumer run independently)

```
Producer ──▶ [ Message Broker ] ──▶ Consumer A
                                ──▶ Consumer B
```

Choose sync when the caller needs an immediate response.
Choose async when the operation can complete later or fans out to multiple consumers.

---

## API Gateway Pattern

```
┌────────┐ ┌────────┐ ┌────────┐
│  Web   │ │ Mobile │ │  3rd   │
└───┬────┘ └───┬────┘ └───┬────┘
    └──────────┼───────────┘
               ▼
┌─────────────────────────────────┐
│         API Gateway             │
│  [Auth] [Rate Limit] [Aggreg.] │
└──┬─────────┬──────────┬────────┘
   ▼         ▼          ▼
┌──────┐ ┌───────┐ ┌─────────┐
│Order │ │Product│ │Shipping │
└──────┘ └───────┘ └─────────┘
```

### Backend for Frontend (BFF)

Deploy separate gateway instances per client type. Each BFF tailors payloads, auth flows, and aggregation to its client.

```
Web App  ──▶  Web BFF    ──┐
Mobile   ──▶  Mobile BFF ──├──▶ Microservices
Partner  ──▶  Partner BFF──┘
```

### Gateway Responsibilities

| Concern         | Implementation                                  |
|-----------------|--------------------------------------------------|
| Authentication  | Validate JWT/OAuth2 tokens, attach user context  |
| Rate limiting   | Token bucket or sliding window per API key       |
| Routing         | Path-based or header-based to upstream services  |
| Aggregation     | Compose responses from multiple services         |
| Caching         | Cache GET responses with TTL at edge             |
| TLS termination | Offload HTTPS; use mTLS internally               |

**Tools:** Kong, APISIX, Envoy Gateway, AWS API Gateway, Traefik.

---

## Circuit Breaker Pattern

Prevent cascading failures when a downstream service degrades.

### State Machine

```
            success threshold met
     ┌──────────────────────────────┐
     │                              │
┌────▼───┐  failure threshold  ┌───┴─────┐  timeout  ┌───────────┐
│ CLOSED │ ─────────────────▶  │  OPEN   │ ────────▶ │ HALF-OPEN │
│(normal)│                     │(reject) │           │ (probe)   │
└────────┘                     └─────────┘           └─────┬─────┘
     ▲               probe fails → back to OPEN           │
     └────────────── probe succeeds ──────────────────────┘
```

- **Closed** — requests flow. Track failure count.
- **Open** — reject immediately. Return fallback.
- **Half-Open** — allow limited probes. Close on success, reopen on failure.

### Configuration (Resilience4j)

```yaml
resilience4j.circuitbreaker:
  instances:
    paymentService:
      failureRateThreshold: 50
      waitDurationInOpenState: 30s
      slidingWindowSize: 20
      permittedNumberOfCallsInHalfOpenState: 5
```

### Retry with Exponential Backoff

```
Attempt 1 → fail → wait 100ms
Attempt 2 → fail → wait 200ms
Attempt 3 → fail → wait 400ms + jitter
Attempt 4 → fail → circuit opens
```

### Bulkhead Pattern

Isolate thread/connection pools per dependency so one slow service cannot exhaust all resources:

```
┌─────────────────────────────────────┐
│           Service A                 │
│  ┌──────────┐  ┌──────────────┐    │
│  │ Pool: DB │  │Pool: Payment │    │
│  │ (10 thr) │  │  (5 thr)    │    │
│  └──────────┘  └──────────────┘    │
└─────────────────────────────────────┘
Payment down → only 5 threads blocked, DB unaffected.
```

**Fallbacks:** Return cached data, default values, or degraded responses when circuit is open.

---

## Service Discovery

| Pattern      | Mechanism                                    | Example         |
|--------------|----------------------------------------------|-----------------|
| Client-side  | Client queries registry, picks instance      | Eureka + Ribbon |
| Server-side  | Load balancer queries registry, routes       | AWS ALB         |
| DNS-based    | Service name resolves via DNS SRV records    | Consul DNS      |
| Service mesh | Sidecar proxy handles discovery transparently| Istio, Linkerd  |

Prefer service mesh in Kubernetes. Use DNS-based for simpler deployments.

---

## Service Mesh

### Architecture

```
┌──────────────────────────────────────────┐
│            Control Plane                 │
│  (Istiod / Linkerd Control Plane)        │
│  - Certificate authority (mTLS)          │
│  - Config distribution / telemetry       │
└─────────┬──────────────────┬─────────────┘
    ┌─────▼─────┐      ┌─────▼─────┐
    │  Pod A     │      │  Pod B     │
    │ ┌───────┐  │ mTLS │ ┌───────┐  │
    │ │Sidecar◄──┼──────┼─►Sidecar│  │
    │ │(Envoy)│  │      │ │(Envoy)│  │
    │ └───┬───┘  │      │ └───┬───┘  │
    │ ┌───▼───┐  │      │ ┌───▼───┐  │
    │ │  App  │  │      │ │  App  │  │
    │ └───────┘  │      │ └───────┘  │
    └────────────┘      └────────────┘
```

### Istio vs Linkerd

| Capability         | Istio                            | Linkerd                     |
|--------------------|----------------------------------|-----------------------------|
| Traffic mgmt       | L7 VirtualService, DestinationRule | Service profiles, per-route |
| Security           | Strict mTLS, SPIFFE, RBAC       | Auto mTLS, zero config      |
| Observability      | Kiali, Jaeger, Prometheus        | Built-in dashboard, tap     |
| Resource overhead  | Higher (Envoy sidecars)          | Lower (Rust micro-proxy)    |
| Ambient mode       | Sidecarless via ztunnel (2025+)  | N/A                         |
| Complexity         | More knobs, more power           | Opinionated, simpler        |

**Choose Istio** for complex enterprise routing, fine-grained policy, multi-cluster.
**Choose Linkerd** for simplicity, low overhead, fast adoption.

### Key Capabilities

- **Traffic splitting:** Route 5% canary, 95% stable.
- **Fault injection:** Simulate latency/errors to test resilience.
- **mTLS everywhere:** Encrypt all service-to-service traffic automatically.
- **Golden signals:** Latency, traffic, errors, saturation — no app code changes.

---

## Sidecar and Ambassador Patterns

### Sidecar

Attach a helper container alongside the app in the same pod. Use cases: log collection (Fluentd), mTLS proxy (Envoy), config refresh, metrics export.

```
┌───────────────────────────┐
│ Pod                       │
│ ┌────────┐  ┌───────────┐│
│ │  App   │  │  Sidecar  ││
│ └────────┘  └───────────┘│
└───────────────────────────┘
```

### Ambassador

Specialized sidecar acting as client-side proxy to external services — handles connection pooling, retry logic, and TLS termination.

---

## Distributed Transactions

### Saga Pattern

Coordinate multi-service transactions through local transactions with compensating actions.

#### Choreography

```
Order ──event──▶ Payment ──event──▶ Inventory ──event──▶ Shipping
  │                │                   │
  ◄──compensate────◄──compensate───────◄── (on failure)
```

Each service listens for events and emits next event or compensation.

#### Orchestration

```
        ┌────────────────┐
        │Saga Orchestrator│
        └┬───┬────┬───┬──┘
    ┌────▼┐  ▼    ▼  ┌▼───────┐
    │Order│  │    │   │Shipping│
    └─────┘  ▼    ▼   └────────┘
        Payment  Inventory
```

**Orchestrator:** Centralized visibility, easier debugging, clear compensation ordering.
**Choreography:** No single point of failure, lower coupling.

#### Design Rules

1. Make every step **idempotent**.
2. Define **compensating actions** for every forward step.
3. Store saga state persistently (saga log).
4. Use correlation IDs to trace the entire transaction.

### Avoid Two-Phase Commit (2PC)

2PC blocks resources, creates tight coupling, and fails under network partitions. Prefer sagas with eventual consistency.

---

## Data Management

### Database per Service

Each service owns its data store. No direct database sharing.

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│  Order   │  │ Product  │  │   User   │
│ Service  │  │ Service  │  │ Service  │
└────┬─────┘  └────┬─────┘  └────┬─────┘
┌────▼─────┐  ┌────▼─────┐  ┌────▼─────┐
│ Postgres │  │  Mongo   │  │  MySQL   │
└──────────┘  └──────────┘  └──────────┘
```

Pick storage per access pattern (polyglot persistence).

### CQRS

Separate write (command) and read (query) models:

```
Commands ──▶ Write Model ──▶ Event Store ──▶ Projector ──▶ Read Model
Queries  ◄──────────────────────────────────────────────◄─┘
```

Apply when read/write workloads scale differently, queries span multiple services, or you need a full audit trail (event sourcing).

### Shared Database Anti-Pattern

**Never** let multiple services share database tables. Creates hidden coupling, schema change nightmares, and prevents independent deployment.

---

## Observability

### Stack

```
┌─────────────────────────────────────────┐
│          Observability Stack            │
│  Traces         Metrics        Logs    │
│  (Jaeger/Tempo) (Prometheus)  (Loki)   │
│       └────────────┼───────────┘       │
│                    ▼                   │
│           Grafana + Alertmanager       │
└─────────────────────────────────────────┘
```

### Distributed Tracing

Propagate trace context (W3C Trace Context) through all calls:

```
Gateway [trace-id: abc, span: 1]
  └─▶ Order Service [trace-id: abc, span: 2]
        └─▶ Payment Service [trace-id: abc, span: 3]
```

Use OpenTelemetry SDK. Export to Jaeger, Tempo, or Zipkin.

### Correlation IDs

Generate `X-Correlation-ID` at the edge. Pass through every service call and log entry to link all telemetry for one request.

### Centralized Logging

Emit structured JSON logs with correlation ID, service name, timestamp. Aggregate with Fluentd → Loki or Elasticsearch.

### Health Checks

Expose `/health/live` and `/health/ready`. Wire into Kubernetes liveness/readiness probes.

---

## Deployment Patterns

### Blue-Green

Run two identical environments. Cutover by switching load balancer from Blue (current) to Green (new). Rollback by switching back.

### Canary

```
LB ──▶ 95% → v1.2 (stable)
   ──▶  5% → v1.3 (canary)
Monitor error rate/latency → ramp 25% → 50% → 100% or rollback.
```

Service mesh traffic splitting simplifies canary rollouts.

### Feature Flags

Decouple deployment from release:

```python
if feature_flags.is_enabled("new_checkout", user_id=user.id):
    return new_checkout(cart)
return legacy_checkout(cart)
```

**Tools:** LaunchDarkly, Unleash, Flagsmith, OpenFeature SDK.

---

## Testing Strategies

### Contract Testing

Verify service interfaces match consumer expectations without full E2E tests:

```
Consumer defines contract (Pact file)
  → Provider verifies against its API
  → Both deploy independently if contract passes
```

**Tools:** Pact, Spring Cloud Contract.

### Synthetic Monitoring

Run production-like transactions on schedule against live services. Catches integration issues unit tests miss.

### Chaos Engineering

| Experiment             | Tool            | Purpose                       |
|------------------------|-----------------|-------------------------------|
| Kill random pods       | Chaos Monkey    | Validate auto-recovery        |
| Inject network latency | Toxiproxy       | Test timeout/retry logic      |
| Simulate AZ failure    | Litmus, Gremlin | Validate multi-AZ redundancy  |
| CPU/memory stress      | stress-ng       | Test autoscaling triggers     |

Start small in production with blast radius controls.

---

## Anti-Patterns

### Distributed Monolith

Services deployed together, shared business-logic libraries, long synchronous call chains. **Fix:** Async events for cross-service workflows. Eliminate shared domain libraries.

### Chatty Services

One user request triggers 10+ inter-service calls.

```
BAD:  Client → A → B → C → D → E  (serial, 5 hops)
GOOD: Client → A → [B, C parallel] → D (aggregated)
```

**Fix:** Aggregate at gateway/BFF. Use CQRS materialized views. Batch requests.

### Shared Database

Multiple services read/write same tables. **Fix:** Extract an owning service. Communicate via API or events. Accept eventual consistency.

---

## Quick Reference

| Problem                        | Pattern                        |
|--------------------------------|--------------------------------|
| Break apart monolith           | Strangler fig + BFF            |
| Single client entry point      | API Gateway                    |
| Prevent cascading failures     | Circuit breaker + bulkhead     |
| Multi-service transactions     | Saga (orchestration preferred) |
| Service-to-service security    | Service mesh (mTLS)            |
| Independent data scaling       | Database per service + CQRS    |
| Debug production requests      | Distributed tracing + corr. ID |
| Safe deployments               | Canary + feature flags         |
| Validate cross-team contracts  | Pact contract testing          |
| Prove resilience               | Chaos engineering              |

<!-- tested: pass -->
