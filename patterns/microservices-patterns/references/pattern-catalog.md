# Microservices Pattern Catalog

Complete catalog in Problem → Solution → Consequences format. Each pattern includes a decision rating and implementation complexity.

**Complexity ratings:** ★ Simple | ★★ Moderate | ★★★ Complex | ★★★★ Very Complex

## Table of Contents

### Decomposition Patterns
1. [Decompose by Business Capability](#1-decompose-by-business-capability)
2. [Decompose by Subdomain (DDD)](#2-decompose-by-subdomain-ddd)
3. [Strangler Fig Migration](#3-strangler-fig-migration)
4. [Anti-Corruption Layer](#4-anti-corruption-layer)

### Communication Patterns
5. [API Gateway](#5-api-gateway)
6. [Backends for Frontends (BFF)](#6-backends-for-frontends-bff)
7. [Service Discovery](#7-service-discovery)
8. [API Composition](#8-api-composition)
9. [Async Messaging](#9-async-messaging)

### Data Management Patterns
10. [Database per Service](#10-database-per-service)
11. [Saga (Choreography)](#11-saga-choreography)
12. [Saga (Orchestration)](#12-saga-orchestration)
13. [CQRS](#13-cqrs)
14. [Event Sourcing](#14-event-sourcing)
15. [Transactional Outbox](#15-transactional-outbox)
16. [Idempotent Consumer](#16-idempotent-consumer)

### Resilience Patterns
17. [Circuit Breaker](#17-circuit-breaker)
18. [Bulkhead](#18-bulkhead)
19. [Retry with Backoff](#19-retry-with-backoff)
20. [Rate Limiting](#20-rate-limiting)
21. [Load Shedding](#21-load-shedding)

### Deployment Patterns
22. [Blue-Green Deployment](#22-blue-green-deployment)
23. [Canary Deployment](#23-canary-deployment)
24. [Feature Flags](#24-feature-flags)

### Cross-Cutting Patterns
25. [Sidecar / Service Mesh](#25-sidecar--service-mesh)
26. [Distributed Tracing](#26-distributed-tracing)
27. [Health Check API](#27-health-check-api)
28. [Externalized Configuration](#28-externalized-configuration)

### Decision Matrix
29. [Pattern Selection Matrix](#pattern-selection-matrix)

---

## Decomposition Patterns

### 1. Decompose by Business Capability
**Complexity:** ★★

**Problem:** How to decompose an application into services?

**Solution:** Define services corresponding to business capabilities. A business capability is something a business does to generate value (e.g., Order Management, Billing, Inventory). Each service owns its capability end-to-end: UI, business logic, and data.

**Consequences:**
- ✅ Stable boundaries (business capabilities change less frequently than technology)
- ✅ Aligns teams to business outcomes (Conway's Law)
- ✅ Each service can be developed, deployed, and scaled independently
- ⚠️ Requires understanding of business domain (not just code structure)
- ❌ Cross-capability features require inter-service coordination

**When to use:** Always the starting point for decomposition. Works best when business capabilities are well-understood and stable.

---

### 2. Decompose by Subdomain (DDD)
**Complexity:** ★★★

**Problem:** How to find optimal service boundaries when business capabilities are unclear?

**Solution:** Apply Domain-Driven Design. Identify bounded contexts through Event Storming or domain analysis. Map core (competitive advantage), supporting (necessary but not differentiating), and generic (commodity) subdomains. Each bounded context becomes a service candidate.

**Consequences:**
- ✅ Precise boundaries based on domain language and models
- ✅ Explicit context maps define integration contracts
- ✅ Investment prioritized: core domains get best engineering
- ⚠️ Requires DDD expertise and domain expert involvement
- ❌ High upfront investment in domain modeling

**When to use:** When business capabilities overlap or are hard to identify. When domain complexity justifies the DDD investment.

---

### 3. Strangler Fig Migration
**Complexity:** ★★★

**Problem:** How to migrate from a monolith to microservices without a risky big-bang rewrite?

**Solution:** Place a routing facade in front of the monolith. Incrementally route specific endpoints to new microservices. Migrate one bounded context at a time, starting with the least coupled. Run monolith and new services in parallel.

**Consequences:**
- ✅ Incremental migration with rollback capability at each step
- ✅ Continuously deliverable — system never enters an unusable state
- ✅ Risk is contained to one context per migration phase
- ⚠️ Requires maintaining two systems in parallel during transition
- ❌ Facade/proxy adds latency. Migration can stall if not prioritized.

**When to use:** Always prefer this over big-bang rewrites. Any monolith-to-microservices migration.

---

### 4. Anti-Corruption Layer
**Complexity:** ★★

**Problem:** How to prevent a legacy system's model from corrupting a new service's domain model?

**Solution:** Implement a translation layer between the new service and the legacy system. The ACL maps legacy concepts to the new domain model. The new service never directly depends on legacy schemas, APIs, or data formats.

**Consequences:**
- ✅ New services maintain clean domain models
- ✅ Legacy system changes don't propagate to new services
- ✅ Can be removed once legacy system is decommissioned
- ⚠️ Additional development and maintenance effort for the translation layer
- ❌ Adds latency and a potential failure point

**When to use:** During monolith migration. When integrating with external systems that have different domain models.

---

## Communication Patterns

### 5. API Gateway
**Complexity:** ★★

**Problem:** How should external clients access multiple microservices?

**Solution:** Single entry point that routes requests, handles cross-cutting concerns (auth, rate limiting, TLS, logging), and optionally aggregates responses. Implementations: Kong, Envoy, AWS API Gateway, NGINX.

**Consequences:**
- ✅ Simplifies client integration — one endpoint instead of many
- ✅ Centralizes cross-cutting concerns
- ✅ Enables protocol translation (REST→gRPC, WebSocket→HTTP)
- ⚠️ Can become a bottleneck if not scaled properly
- ❌ Must not contain business logic — routing and policy only

**When to use:** Almost always for external-facing APIs. Optional for internal service-to-service communication.

---

### 6. Backends for Frontends (BFF)
**Complexity:** ★★

**Problem:** Different frontends (web, mobile, IoT) need different API shapes from the same backend services.

**Solution:** Create a dedicated backend service per frontend type. Each BFF tailors responses to its client's needs (field selection, pagination, response format). BFFs are thin — aggregation and formatting only, no domain logic.

**Consequences:**
- ✅ Each frontend gets optimized API responses
- ✅ Frontend teams can iterate on their BFF independently
- ✅ Reduces over-fetching and under-fetching
- ⚠️ Code duplication across BFFs if not managed carefully
- ❌ More services to deploy and maintain

**When to use:** When you have 2+ significantly different frontend clients with divergent data needs.

---

### 7. Service Discovery
**Complexity:** ★★

**Problem:** How do services find each other's network locations without hardcoded addresses?

**Solution:** Services register themselves with a registry on startup and deregister on shutdown. Clients query the registry to find service instances. Two approaches: client-side discovery (client queries registry directly) or server-side discovery (load balancer queries registry).

**Consequences:**
- ✅ Dynamic scaling — new instances are automatically discoverable
- ✅ Enables load balancing and failover
- ✅ No hardcoded addresses in configuration
- ⚠️ Registry is a critical component — must be highly available
- ❌ Stale registrations if health checks are not configured

**When to use:** Always in dynamic environments (Kubernetes, cloud). DNS-based discovery in K8s may suffice for simpler setups.

---

### 8. API Composition
**Complexity:** ★★

**Problem:** How to query data that spans multiple services?

**Solution:** A Composer service (or API Gateway) calls multiple downstream services, aggregates their responses, and returns a unified result. Call downstream services in parallel when possible. Handle partial failures gracefully (return partial data with degraded indicators).

**Consequences:**
- ✅ Simple to implement for straightforward aggregation
- ✅ No data duplication across services
- ⚠️ Availability is the product of downstream service availabilities
- ❌ Performance limited by the slowest downstream call
- ❌ Not suitable for complex queries with joins, sorts, or filters across services

**When to use:** Simple cross-service queries with 2–4 downstream sources. For complex scenarios, use CQRS instead.

---

### 9. Async Messaging
**Complexity:** ★★★

**Problem:** How to decouple services temporally and reduce synchronous call chains?

**Solution:** Services communicate via messages/events through a broker (Kafka, RabbitMQ, SQS). Producers publish events; consumers subscribe to topics. Events are immutable facts. Consumers must be idempotent (at-least-once delivery is standard).

**Consequences:**
- ✅ Loose coupling — producer doesn't know/care about consumers
- ✅ Temporal decoupling — services don't need to be available simultaneously
- ✅ Natural buffering under load spikes
- ⚠️ Eventual consistency — consumers process events with delay
- ❌ Complex debugging — async flows harder to trace than sync calls
- ❌ Message ordering challenges with partitioned topics

**When to use:** When services don't need immediate responses. When you need to decouple event producers from consumers.

---

## Data Management Patterns

### 10. Database per Service
**Complexity:** ★★

**Problem:** How to ensure services are truly independent and loosely coupled?

**Solution:** Each service owns a private database. No other service accesses it directly. Cross-service data access only through APIs or events. Each service can choose the optimal storage technology (relational, document, graph, time-series).

**Consequences:**
- ✅ True independence — deploy, scale, and evolve storage independently
- ✅ Polyglot persistence — right tool for each job
- ✅ No schema coupling between services
- ⚠️ Cross-service queries require API Composition or CQRS
- ❌ Distributed transactions require saga pattern
- ❌ Data duplication across services

**When to use:** Always in a properly designed microservices architecture. The foundation for service independence.

---

### 11. Saga (Choreography)
**Complexity:** ★★★

**Problem:** How to maintain data consistency across services without distributed transactions?

**Solution:** Each service publishes domain events after completing its local transaction. Other services react to these events and execute their own local transactions. On failure, services publish compensating events that reverse prior steps.

**Consequences:**
- ✅ No central coordinator — services remain autonomous
- ✅ Loose coupling through events
- ✅ Easy to add new participants
- ⚠️ Hard to track overall saga state — workflow is implicit in event subscriptions
- ❌ Difficult to debug and test complex flows
- ❌ Risk of cyclic event dependencies

**When to use:** Simple flows with 2–4 services. When service autonomy is prioritized over workflow visibility.

---

### 12. Saga (Orchestration)
**Complexity:** ★★★★

**Problem:** How to coordinate complex multi-service transactions with clear workflow visibility?

**Solution:** A central orchestrator (state machine) directs the saga. It sends commands to participants, awaits replies, and decides next steps. On failure, it drives compensating actions in reverse order. Orchestrator must be stateful and persistent.

**Consequences:**
- ✅ Clear, centralized workflow logic — easy to understand, debug, and monitor
- ✅ Centralized compensation handling
- ✅ Works well for complex branching and conditional logic
- ⚠️ Orchestrator is a single point of failure (must be highly available)
- ❌ Tighter coupling to orchestrator
- ❌ Orchestrator can become a bottleneck

**When to use:** Complex flows with 5+ services. When centralized monitoring and compensation are priorities.

---

### 13. CQRS
**Complexity:** ★★★

**Problem:** How to handle complex queries that span multiple services or require different data models for reads vs writes?

**Solution:** Separate command (write) and query (read) sides into distinct models. Writes go through the command model with full business validation. Reads come from denormalized, optimized views updated via domain events. Read models are eventually consistent.

**Consequences:**
- ✅ Read and write models optimized independently
- ✅ Read side scales independently from write side
- ✅ Supports complex queries without impacting write performance
- ⚠️ Eventual consistency between read and write models
- ❌ Significant added complexity — only worth it for complex domains
- ❌ More infrastructure (separate stores, event processing)

**When to use:** When read/write workloads have significantly different shapes or scale requirements. When you need cross-service query views.

---

### 14. Event Sourcing
**Complexity:** ★★★★

**Problem:** How to have a complete audit trail and enable temporal queries over domain state?

**Solution:** Persist domain state as a sequence of immutable events rather than current state. Reconstruct current state by replaying events. Use snapshots for performance. Combine with CQRS for read-optimized projections.

**Consequences:**
- ✅ Complete audit trail — every state change recorded
- ✅ Temporal queries — what was the state at any point in time?
- ✅ Natural event publishing for downstream consumers
- ⚠️ Event schema evolution is complex — must maintain backward compatibility
- ❌ Learning curve is steep — fundamentally different from CRUD
- ❌ Eventual consistency for read models
- ❌ Event store must handle high throughput and long-term retention

**When to use:** Financial systems, audit-heavy domains, systems requiring temporal queries. Rarely justified for CRUD-dominated services.

---

### 15. Transactional Outbox
**Complexity:** ★★

**Problem:** How to reliably publish events alongside database writes without dual-write risk?

**Solution:** Write the domain event to an `outbox` table in the same database transaction as the business data change. A separate process (poller or CDC connector) reads outbox rows and publishes them to the message broker. Guarantees at-least-once delivery.

**Consequences:**
- ✅ Atomic consistency between data changes and event publication
- ✅ No dual-write risk — single DB transaction
- ✅ Works with any message broker
- ⚠️ Adds latency (polling interval) or infrastructure (CDC connector)
- ❌ Outbox table can grow if publishing falls behind — needs monitoring

**When to use:** Whenever a service needs to publish events as part of a state change. Pair with CDC (Debezium) for near-real-time delivery.

---

### 16. Idempotent Consumer
**Complexity:** ★★

**Problem:** How to handle duplicate message delivery safely?

**Solution:** Assign a unique ID to every message. Before processing, check a deduplication store. If already processed, return the cached result. If new, process and record the ID. Set TTL on dedup entries.

**Consequences:**
- ✅ Safe at-least-once processing — duplicates handled gracefully
- ✅ Enables retry without side effects
- ⚠️ Dedup store adds a DB lookup per message
- ❌ Must be applied consistently across all consumers

**When to use:** Always when consuming events from message brokers with at-least-once delivery guarantees (Kafka, SQS, RabbitMQ).

---

## Resilience Patterns

### 17. Circuit Breaker
**Complexity:** ★★

**Problem:** How to prevent cascading failures when a downstream service is failing?

**Solution:** Wrap downstream calls in a circuit breaker that tracks failures over a sliding window. When failures exceed a threshold, the circuit opens — subsequent calls fail immediately with a fallback response. After a timeout, the circuit enters half-open state for probe calls.

**Consequences:**
- ✅ Prevents resource exhaustion from blocked threads/connections
- ✅ Gives failing services time to recover
- ✅ Provides meaningful fallback responses to users
- ⚠️ Requires tuning thresholds per dependency
- ❌ Fallback responses may not satisfy all use cases

**When to use:** On ALL synchronous cross-service calls. Configure different thresholds for critical vs. non-critical dependencies.

---

### 18. Bulkhead
**Complexity:** ★★

**Problem:** How to prevent one failing dependency from consuming all system resources?

**Solution:** Isolate resources (thread pools, connection pools, semaphores) per downstream dependency. If one pool is exhausted, other dependencies are unaffected. Size pools based on expected load.

**Consequences:**
- ✅ Failure containment — one slow dependency can't starve others
- ✅ Predictable resource allocation per dependency
- ⚠️ Resource underutilization if pools are over-provisioned
- ❌ More complex resource management and configuration

**When to use:** Whenever a service has multiple downstream dependencies with different reliability characteristics.

---

### 19. Retry with Backoff
**Complexity:** ★

**Problem:** How to handle transient failures in downstream calls?

**Solution:** Retry failed calls with exponential backoff and jitter. `delay = base × 2^attempt + random(0, base)`. Set max retries (3–5) and max delay cap (30–60s). Only retry transient errors (5xx, timeouts). Never retry 4xx.

**Consequences:**
- ✅ Recovers from transient failures automatically
- ✅ Jitter prevents thundering herd on recovery
- ⚠️ Downstream operations must be idempotent
- ❌ Increases overall latency for the retried request
- ❌ Can amplify load on already-stressed services if not combined with circuit breaker

**When to use:** Always for transient failure handling. Always combine with circuit breaker to prevent retry storms.

---

### 20. Rate Limiting
**Complexity:** ★★

**Problem:** How to protect services from excessive request volume?

**Solution:** Limit the number of requests a client/service can make within a time window. Algorithms: token bucket (smooth, bursty), sliding window (precise), fixed window (simple). Return HTTP 429 with `Retry-After` header.

**Consequences:**
- ✅ Protects services from overload and abuse
- ✅ Fair resource sharing across clients
- ⚠️ Must calibrate limits carefully — too aggressive rejects legitimate traffic
- ❌ Requires distributed rate limiting for multi-instance services (Redis-backed)

**When to use:** API gateways for external traffic. Service-to-service when downstream capacity is limited.

---

### 21. Load Shedding
**Complexity:** ★★

**Problem:** How to maintain responsiveness when the system is overloaded?

**Solution:** When approaching capacity limits, reject excess requests immediately (HTTP 503) instead of queueing them. Prioritize requests: serve critical paths, shed optional features. Better to serve 80% of requests well than 100% of requests poorly.

**Consequences:**
- ✅ Maintains quality of service for accepted requests
- ✅ Prevents cascading resource exhaustion
- ⚠️ Rejected requests need client-side retry logic
- ❌ Requires understanding of request priority and system capacity

**When to use:** High-traffic services where overload would cause cascading failures. Combine with rate limiting at the gateway.

---

## Deployment Patterns

### 22. Blue-Green Deployment
**Complexity:** ★★

**Problem:** How to deploy with zero downtime and instant rollback?

**Solution:** Maintain two identical environments (blue/green). Deploy new version to idle environment. Run smoke tests. Switch traffic atomically via load balancer/DNS. Keep old environment running for instant rollback.

**Consequences:**
- ✅ Zero-downtime deployment
- ✅ Instant rollback by switching traffic back
- ✅ Full pre-production validation in production infrastructure
- ⚠️ Double infrastructure cost during deployment
- ❌ Database migrations must be backward-compatible (both versions run against same DB)

**When to use:** When zero downtime and instant rollback are requirements. When you can afford double infrastructure temporarily.

---

### 23. Canary Deployment
**Complexity:** ★★★

**Problem:** How to validate new versions with real production traffic while minimizing risk?

**Solution:** Route a small percentage (1–5%) of traffic to the new version. Monitor error rates, latency, and business metrics. Gradually increase traffic if metrics are healthy. Auto-rollback if degraded.

**Consequences:**
- ✅ Real production validation with minimal blast radius
- ✅ Gradual rollout catches issues before full deployment
- ✅ Data-driven promotion decisions
- ⚠️ Requires sophisticated traffic routing (service mesh, weighted LB)
- ❌ Monitoring and automated rollback add complexity

**When to use:** For high-risk changes or when blue-green's "all-or-nothing" switching is too risky. Best with automated metrics-based promotion.

---

### 24. Feature Flags
**Complexity:** ★★

**Problem:** How to decouple deployment from feature release?

**Solution:** Wrap new features in conditional flags. Deploy code to all instances (dark launch). Enable features per user segment, percentage, or environment via configuration. Disable instantly if issues arise.

**Consequences:**
- ✅ Deploy anytime, release when ready
- ✅ Instant kill switch for problematic features
- ✅ Enables A/B testing and gradual rollouts
- ⚠️ Stale flags become technical debt — clean up after full rollout
- ❌ Increases code complexity with conditional paths

**When to use:** Always for user-facing features in production. Essential complement to canary and blue-green deployments.

---

## Cross-Cutting Patterns

### 25. Sidecar / Service Mesh
**Complexity:** ★★★★

**Problem:** How to handle cross-cutting concerns (mTLS, tracing, retries, rate limiting) consistently across all services without duplicating code?

**Solution:** Deploy a proxy sidecar alongside each service instance. The sidecar handles network concerns transparently. A control plane manages configuration, certificates, and policies for all sidecars.

**Consequences:**
- ✅ Consistent security, observability, and traffic management
- ✅ Language/framework agnostic — works with any service
- ✅ No application code changes for cross-cutting concerns
- ⚠️ Adds latency (extra network hop through sidecar)
- ❌ Significant operational complexity
- ❌ Resource overhead (CPU/memory per sidecar)

**When to use:** 50+ services, strict security requirements (mTLS everywhere), polyglot architectures, need for consistent traffic management.

---

### 26. Distributed Tracing
**Complexity:** ★★

**Problem:** How to debug and monitor requests that span multiple services?

**Solution:** Propagate trace context (W3C Trace Context) in headers across all calls. Each service creates spans for operations. Collect spans in a tracing backend. Visualize the full request flow as a trace.

**Consequences:**
- ✅ End-to-end visibility across service boundaries
- ✅ Identifies latency bottlenecks and failure points
- ✅ Essential for debugging distributed systems
- ⚠️ Instrumentation effort across all services
- ❌ Trace storage costs at high throughput — use sampling

**When to use:** Always in production microservices. Non-negotiable for debugging distributed systems.

---

### 27. Health Check API
**Complexity:** ★

**Problem:** How do orchestrators and load balancers know if a service is healthy?

**Solution:** Expose `/health/live` (process running) and `/health/ready` (can serve traffic) endpoints. Readiness checks verify downstream dependencies. Return structured JSON with component status.

**Consequences:**
- ✅ Enables automated failover and load balancing
- ✅ Distinguishes between process health and readiness
- ✅ Feeds into alerting and dashboards
- ⚠️ Readiness checks must be fast — don't do expensive operations
- ❌ Can cause cascading restarts if dependency checks are too aggressive

**When to use:** Always. Every microservice must expose health endpoints.

---

### 28. Externalized Configuration
**Complexity:** ★

**Problem:** How to manage configuration across environments without rebuilding or redeploying?

**Solution:** Store configuration outside the application (environment variables, config servers, K8s ConfigMaps/Secrets). Services read configuration at startup or via hot reload. Sensitive values stored in secret managers (Vault, AWS Secrets Manager).

**Consequences:**
- ✅ Same artifact across all environments
- ✅ Change configuration without redeployment
- ✅ Centralized secret management
- ⚠️ Configuration drift between environments if not managed
- ❌ Config server becomes a dependency — must be highly available

**When to use:** Always. No hardcoded configuration in application code.

---

## Pattern Selection Matrix

### By Problem Domain

| Problem | Primary Pattern | Secondary Pattern | Complexity |
|---|---|---|---|
| Breaking apart monolith | Strangler Fig | Anti-Corruption Layer | ★★★ |
| Service boundaries | Decompose by Business Capability | Decompose by Subdomain | ★★ |
| External client access | API Gateway | BFF | ★★ |
| Cross-service queries | API Composition | CQRS | ★★–★★★ |
| Cross-service transactions | Saga (Choreography/Orchestration) | Transactional Outbox | ★★★–★★★★ |
| Reliable event publishing | Transactional Outbox + CDC | Event Sourcing | ★★ |
| Duplicate message handling | Idempotent Consumer | — | ★★ |
| Downstream failure protection | Circuit Breaker | Bulkhead + Retry | ★★ |
| Overload protection | Rate Limiting | Load Shedding | ★★ |
| Zero-downtime deployment | Blue-Green | Canary + Feature Flags | ★★–★★★ |
| Cross-cutting concerns | Sidecar / Service Mesh | — | ★★★★ |
| Debugging in production | Distributed Tracing | Structured Logging | ★★ |
| Audit trail | Event Sourcing | CQRS | ★★★★ |

### Pattern Dependency Map

```
Database per Service ← (foundation for all data patterns)
  → Saga (requires separate DBs to exist)
  → CQRS (benefits from polyglot persistence)
  → Transactional Outbox (operates within service's own DB)

Transactional Outbox + CDC → feeds → Async Messaging → consumed by → Idempotent Consumer

Circuit Breaker + Bulkhead + Retry = Resilience Stack (deploy together)

API Gateway → may use → Service Discovery + BFF

Strangler Fig → uses → Anti-Corruption Layer + API Gateway routing
```

### Adoption Order (Recommended)

Start with foundational patterns and add complexity only when needed:

```
Phase 1 (Day 1): Health Check API, Externalized Config, Structured Logging
Phase 2 (First services): API Gateway, Database per Service, Service Discovery
Phase 3 (Inter-service calls): Circuit Breaker, Retry with Backoff, Distributed Tracing
Phase 4 (Data consistency): Transactional Outbox, Idempotent Consumer, Async Messaging
Phase 5 (Complex workflows): Saga Pattern, CQRS
Phase 6 (Scale): Service Mesh, Cell-Based Architecture, Event Sourcing
```
