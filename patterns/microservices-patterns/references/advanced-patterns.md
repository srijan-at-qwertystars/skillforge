# Advanced Microservices Patterns

Dense reference for architects and senior engineers. Each section is self-contained with problem statement, solution mechanics, and implementation guidance.

## Table of Contents

1. [Choreography vs Orchestration Deep Dive](#choreography-vs-orchestration-deep-dive)
2. [Distributed Saga Compensation](#distributed-saga-compensation)
3. [Event-Driven Architecture with CDC](#event-driven-architecture-with-cdc)
4. [Service Mesh: Data Plane vs Control Plane](#service-mesh-data-plane-vs-control-plane)
5. [API Versioning Strategies](#api-versioning-strategies)
6. [Distributed Caching](#distributed-caching)
7. [Cell-Based Architecture](#cell-based-architecture)
8. [Data Mesh in Microservices](#data-mesh-in-microservices)
9. [Platform Engineering Patterns](#platform-engineering-patterns)

---

## Choreography vs Orchestration Deep Dive

### When Choreography Wins

Use choreography when services are truly autonomous, the flow involves 2–4 services, and event ordering is flexible.

**Mechanics:**
- Each service publishes domain events after completing its local transaction.
- Downstream services subscribe to relevant event topics and react independently.
- No central coordinator — the workflow emerges from event subscriptions.

**Compensation in choreography:** Each service publishes compensating events on failure. Downstream consumers must handle both forward and compensating events idempotently.

```
OrderService publishes OrderCreated
  → PaymentService subscribes, processes, publishes PaymentCharged
    → InventoryService subscribes, processes, publishes StockReserved
      → ShippingService subscribes, publishes ShipmentScheduled

On PaymentService failure:
  PaymentService publishes PaymentFailed
    → OrderService subscribes, publishes OrderCancelled
```

**Failure modes:** Circular event chains, lost events (need guaranteed delivery), out-of-order processing, hard-to-trace distributed workflows.

### When Orchestration Wins

Use orchestration when flows involve 5+ services, require strict ordering, need centralized monitoring, or have complex branching/compensation logic.

**Mechanics:**
- A dedicated orchestrator (state machine) sends commands to participants and awaits replies.
- Orchestrator persists its state (workflow engine, durable execution).
- On failure, orchestrator drives compensation in reverse order.

**Tools:** Temporal, Camunda, AWS Step Functions, Netflix Conductor.

```
Orchestrator state machine:
  S1: CreateOrder → on success → S2
  S2: ChargePayment → on success → S3, on failure → C1
  S3: ReserveInventory → on success → S4, on failure → C2
  S4: ScheduleShipment → on success → DONE, on failure → C3
  C3: ReleaseInventory → C2
  C2: RefundPayment → C1
  C1: CancelOrder → FAILED
```

### Hybrid Approach

Use orchestration at the business-process level (order fulfillment) and choreography at the infrastructure level (notifications, analytics, audit). The orchestrator emits domain events that loosely-coupled consumers can subscribe to.

### Decision Matrix

| Criterion | Choreography | Orchestration |
|---|---|---|
| Services in flow | 2–4 | 5+ |
| Ordering requirements | Flexible | Strict |
| Debugging ease | Hard | Easy |
| Single point of failure | None | Orchestrator |
| Coupling | Loose (event contracts) | Medium (command contracts) |
| Team autonomy | High | Medium |
| Compensation complexity | Distributed, harder | Centralized, easier |

---

## Distributed Saga Compensation

### Compensation Is Not Rollback

Database rollback erases changes. Saga compensation creates new operations that semantically reverse prior effects, leaving an audit trail.

### Compensation Strategies

**1. Status-based compensation:**
Change record state instead of deleting. `ACTIVE → CANCELLED`, `RESERVED → RELEASED`.

**2. Reverse operation compensation:**
Create semantically opposite transactions: refund for payment, credit for debit, release for reservation.

**3. Semantic compensation with business rules:**
Some operations cannot be fully reversed (email sent, physical shipment). Use compensating business actions: send correction email, create return shipment.

### Compensation Design Rules

1. **Every forward step must have a defined compensating action** — design them together, not as afterthoughts.
2. **Compensating actions must be idempotent** — they may execute multiple times due to retries.
3. **Compensation must succeed eventually** — use retry with backoff. If compensation itself fails, alert for manual intervention.
4. **Track saga state persistently** — store current step, completed steps, and compensation status in a durable store.
5. **Use correlation IDs** — link all saga participants and their compensating actions for tracing.

### Pivot and Retriable Transactions

- **Pivot transaction:** The decision point in a saga. Before the pivot, all steps are compensatable. After the pivot, all steps are retriable (must eventually succeed).
- **Retriable transactions:** Steps that can be retried indefinitely without side effects (idempotent operations).

```
Compensatable → Compensatable → PIVOT → Retriable → Retriable
  CreateOrder  →  ReserveStock  → ChargePayment → ShipOrder → SendConfirmation
  (can cancel)    (can release)   (decision point) (must retry) (must retry)
```

---

## Event-Driven Architecture with CDC

### The Dual-Write Problem

Writing to a database AND publishing an event are two separate operations. If either fails independently, data and events diverge. CDC solves this.

### Change Data Capture (CDC)

CDC reads the database transaction log (WAL/binlog) and emits change events. No application code changes needed.

**Architecture:**
```
Service → writes to DB → DB transaction log
                              ↓
                         CDC Connector (Debezium)
                              ↓
                         Message Broker (Kafka)
                              ↓
                         Downstream consumers
```

**Two CDC approaches:**

| Approach | How | When |
|---|---|---|
| CDC on business tables | Captures raw INSERT/UPDATE/DELETE on domain tables | Data replication, analytics, warehousing |
| CDC on outbox table | Captures rows from a dedicated `outbox` table | Business event publishing, microservice integration |

### Outbox + CDC (Gold Standard)

1. Application writes domain data AND an outbox event row in the same DB transaction (atomicity guaranteed).
2. Debezium CDC connector watches the outbox table.
3. Debezium publishes outbox rows as events to Kafka.
4. Downstream services consume business-meaningful events.

**Benefits:** Atomic consistency between data and events, no dual-write risk, at-least-once delivery, no changes to existing write path.

### CDC Implementation Checklist

- [ ] Enable WAL/binlog on source database
- [ ] Deploy Debezium connector with appropriate transforms
- [ ] Configure outbox table with: `id`, `aggregate_type`, `aggregate_id`, `event_type`, `payload`, `created_at`
- [ ] Set up dead-letter topic for failed transformations
- [ ] Monitor connector lag and replication slot growth
- [ ] Implement idempotent consumers downstream
- [ ] Set retention policies on CDC topics

---

## Service Mesh: Data Plane vs Control Plane

### Data Plane

The data plane consists of proxies (sidecars) deployed alongside every service instance. They intercept all inbound/outbound network traffic.

**Responsibilities:** Load balancing, circuit breaking, retries, timeouts, mTLS encryption, request routing, telemetry collection, protocol translation.

**Implementations:**
- **Envoy** (C++): Most feature-rich, used by Istio. Supports HTTP/2, gRPC, WebSocket, Wasm extensions.
- **linkerd2-proxy** (Rust): Ultralight, purpose-built for service mesh. Lower latency and memory footprint.

### Control Plane

The control plane manages configuration, policy distribution, certificate management, and service discovery for all data plane proxies.

**Responsibilities:** Push routing rules to proxies, issue and rotate mTLS certificates, aggregate telemetry, enforce authorization policies.

### Istio vs Linkerd Decision Guide

| Factor | Istio | Linkerd |
|---|---|---|
| Data plane proxy | Envoy (C++) | linkerd2-proxy (Rust) |
| Resource overhead | High (1–4 GB, 2 vCPUs) | Low (300–800 MB, 0.5 vCPU) |
| Extensibility | High (Wasm plugins, custom filters) | Minimal |
| Learning curve | Steep | Gentle |
| Multi-cluster | Full support | Limited |
| Best for | Complex enterprise, fine-grained control | Simplicity, resource-constrained environments |

### When to Adopt a Service Mesh

- **Yes:** 50+ services, strict mTLS requirements, traffic shifting (canary), need consistent observability without code changes.
- **No:** < 20 services, simple routing needs, team lacks operational capacity for mesh management.
- **Alternative:** Start with a library-based approach (Resilience4j, Polly) and adopt mesh when operational needs justify it.

---

## API Versioning Strategies

### Strategy Comparison

| Strategy | Mechanism | Visibility | Caching | REST Purity |
|---|---|---|---|---|
| URL path | `/api/v2/orders` | High | Easy | Low |
| Query param | `/api/orders?version=2` | Medium | Tricky | Low |
| Custom header | `X-API-Version: 2` | Low | Proxy issues | Medium |
| Content negotiation | `Accept: application/vnd.api.v2+json` | Low | Complex | High |

### Recommended Approach

**External APIs:** URL path versioning (`/api/v1/...`). Explicit, debuggable, cache-friendly. Used by Stripe, GitHub, Google.

**Internal APIs (service-to-service):** Header versioning or content negotiation. Keeps URLs clean, enables gradual migration.

### Versioning Rules

1. **Only bump major version for breaking changes.** Adding fields is not breaking. Removing/renaming fields is.
2. **Support N-1 at minimum.** Run current and previous version simultaneously.
3. **Announce deprecation with timeline.** Use `Sunset` and `Deprecation` HTTP headers.
4. **Use schema evolution for events.** Avro/Protobuf with schema registry for backward/forward compatible event schemas.
5. **Contract tests between versions.** Ensure N-1 consumers still work with N producers.

---

## Distributed Caching

### Caching Strategies

**Cache-aside (Lazy loading):** Application checks cache first. On miss, reads from DB, writes to cache. Most common pattern.

**Write-through:** Application writes to cache and DB simultaneously. Cache is always consistent but adds write latency.

**Write-behind (Write-back):** Application writes to cache only. Cache asynchronously writes to DB. Fast writes but risk of data loss.

**Read-through:** Cache itself loads data from DB on miss. Application only interacts with cache.

### Multi-Service Caching Architecture

```
Client → API Gateway (edge cache: CDN, Varnish)
  → Service A (local cache: in-process, Caffeine)
    → Distributed cache (Redis Cluster / Memcached)
      → Database (source of truth)
```

### Cache Invalidation Patterns

- **TTL-based:** Set expiry on all cache entries. Simple but stale reads during TTL window.
- **Event-driven invalidation:** Publish cache-invalidation events on data change. Near-real-time consistency.
- **Version stamps:** Include version in cache key. On update, increment version — old entries naturally expire.

### Rules

1. Cache immutable data aggressively (reference data, configs). Cache mutable data with short TTLs.
2. Never cache without TTL. Stale caches cause insidious bugs.
3. Use consistent hashing for cache key distribution across nodes.
4. Plan for cache stampede: use lock-based refresh or probabilistic early expiration.
5. Monitor hit rates. Below 80% indicates a caching strategy problem.

---

## Cell-Based Architecture

### Problem

In traditional microservices, a single bad deployment or infrastructure failure can affect all users. The blast radius is the entire system.

### Solution

Divide the system into independent, self-contained **cells**. Each cell is a complete replica of the application stack (compute, storage, networking) serving a subset of users/tenants.

### Architecture

```
                    Cell Router (lightweight, ultra-resilient)
                   /          |          \
              Cell A       Cell B       Cell C
           (Users 1-1000) (1001-2000) (2001-3000)
           [App + DB +    [App + DB +  [App + DB +
            Cache + MQ]    Cache + MQ]  Cache + MQ]
```

### Cell Design Rules

1. **Cells are fully isolated.** No shared databases, no shared message queues, no cross-cell calls.
2. **Cell router is the only shared component.** Keep it stateless and minimal (hash-based routing).
3. **Deploy to one cell first.** Use cells as natural canary targets — deploy to Cell A, monitor, then promote.
4. **Size cells for your blast radius tolerance.** If you can tolerate 5% user impact, create 20+ cells.
5. **Map cells to infrastructure isolation.** Separate AWS accounts, availability zones, or regions.

### When to Use

- Multi-tenant SaaS with strict isolation requirements
- Systems requiring < 99.99% blast radius containment
- Regulatory compliance requiring data residency per region/tenant
- 100+ services where operational complexity justifies cell overhead

---

## Data Mesh in Microservices

### Core Principles

1. **Domain-oriented data ownership:** The team that owns the microservice owns its data products. No central data team bottleneck.
2. **Data as a product:** Data outputs have SLAs, documentation, discoverability, and versioned schemas — just like APIs.
3. **Self-serve data platform:** A shared platform provides infrastructure (pipelines, catalogs, governance tools) so domain teams can publish data products independently.
4. **Federated computational governance:** Centralized policies (security, compliance, interoperability) enforced through automation, not manual gatekeeping.

### Data Mesh + Microservices Integration

```
Microservice A (Orders domain)
  → Owns: orders DB, order-events Kafka topic
  → Publishes: "Orders" data product (curated, documented, SLA'd)
  → Registers in: Data catalog (discoverable by other domains)

Microservice B (Analytics domain)
  → Discovers: "Orders" data product via catalog
  → Consumes: order-events topic with defined schema contract
  → Owns: analytics-specific transformations and storage
```

### Implementation Patterns

- **Event streaming as data product transport:** Use Kafka topics with schema registry as the backbone for data product delivery.
- **Data contracts:** Formal agreements between producer and consumer defining schema, SLAs, freshness guarantees.
- **Domain data store selection:** Each domain picks the best storage (relational, document, graph, time-series) for its data products.

### When NOT to Use Data Mesh

- Small organizations (< 5 domains/teams) — overhead isn't justified
- When a centralized data warehouse already meets needs well
- Teams lack data engineering maturity to own data products

---

## Platform Engineering Patterns

### Internal Developer Platform (IDP)

A self-service layer that abstracts infrastructure complexity, enabling development teams to deploy, observe, and manage services without deep infrastructure knowledge.

### Core Platform Capabilities

| Capability | What It Provides | Tools |
|---|---|---|
| Service scaffolding | Templates for new services with CI/CD, observability, configs | Backstage, Cookiecutter |
| Infrastructure provisioning | Self-serve infra via APIs/UI | Terraform, Crossplane, Pulumi |
| Deployment pipelines | Standardized CI/CD with guardrails | ArgoCD, Flux, GitHub Actions |
| Observability stack | Metrics, logs, traces out-of-the-box | OpenTelemetry, Grafana, Datadog |
| Service catalog | Discoverability, ownership, dependency mapping | Backstage, Port, Cortex |
| Security baseline | mTLS, secret management, RBAC | Vault, cert-manager, OPA |

### Golden Path Pattern

Define an opinionated, well-supported "golden path" for service development. Teams CAN deviate but get best support on the golden path.

**Golden path includes:** Language/framework choice, project structure, CI/CD pipeline, observability integration, deployment target, security scanning.

### Platform as a Product

1. Treat internal developers as customers. Measure adoption and satisfaction.
2. Provide self-serve APIs — never require tickets for standard operations.
3. Build thin abstractions over infrastructure. Don't hide complexity entirely; make it manageable.
4. Maintain backward compatibility in platform APIs. Version platform changes like any other API.

### Platform Team Anti-Patterns

- **Ticket ops:** Platform team becomes a bottleneck processing requests manually.
- **Over-abstraction:** Hiding so much that teams can't debug production issues.
- **Mandate without value:** Forcing platform adoption without demonstrating developer productivity gains.
