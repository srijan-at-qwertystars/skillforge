---
name: microservices-patterns
description: >
  Guide for designing, implementing, and evolving microservices architectures using
  proven distributed systems patterns. Covers decomposition strategies, inter-service
  communication, data management, resilience, observability, testing, and deployment.
  Use when asked about microservices, service decomposition, distributed systems patterns,
  saga pattern, CQRS, circuit breaker, API gateway, event-driven architecture, service mesh,
  strangler fig migration, sidecar patterns, or distributed transactions.
  NOT for monolith design, NOT for single-service applications, NOT for Kubernetes
  orchestration details, NOT for container runtime configuration.
---

# Microservices Patterns

Apply these patterns when designing, building, or migrating to microservices. Select patterns based on the specific distributed systems problem. Never adopt patterns speculatively — each adds operational complexity.

## Decomposition Strategies

### By Business Capability
Align each service to a stable business function (e.g., Order Management, Billing, Inventory). Services own their domain end-to-end.

Rules:
- One service = one business capability. Never split a capability across services.
- Define service boundaries at organizational team boundaries (Conway's Law).
- Each service owns its data, API, and deployment pipeline.

### By Subdomain (DDD)
Use Domain-Driven Design bounded contexts to define service boundaries.

Rules:
- Identify core, supporting, and generic subdomains. Invest most in core.
- Define explicit context maps between services (upstream/downstream, conformist, anti-corruption layer).
- Use ubiquitous language within each bounded context; translate at boundaries.
- Keep aggregates within a single service. Never split an aggregate across services.

## API Gateway Pattern

Route all external client requests through a single entry point.

Rules:
- Handle cross-cutting concerns: authentication, rate limiting, TLS termination, request logging.
- Aggregate responses from multiple downstream services when clients need composite data.
- Never put business logic in the gateway — routing and policy only.
- Implement request/response transformation and protocol translation (REST to gRPC).

```
Client → API Gateway → [Auth Service, Order Service, Product Service]
                     → Aggregated response back to client
```

## Backends for Frontends (BFF)

Create dedicated backend services per frontend type (web, mobile, IoT).

Rules:
- Each BFF tailors API responses to its frontend's needs (field selection, pagination, caching).
- BFF owns the aggregation logic for its client. Keep it thin — no domain logic.
- Deploy and scale BFFs independently from downstream services.

## Service Discovery

Enable services to locate each other dynamically without hardcoded addresses.

Rules:
- Use client-side discovery (service queries registry) or server-side discovery (load balancer queries registry).
- Register services on startup, deregister on shutdown. Implement health-check-based eviction.
- Tools: Consul, etcd, Eureka, or DNS-based discovery in Kubernetes.

## Circuit Breaker

Prevent cascading failures by stopping calls to failing downstream services.

Rules:
- Track failure rate over a sliding window. Open circuit when threshold exceeded (e.g., >50% failures in 10s).
- In open state, fail fast with fallback response. After timeout, enter half-open state and probe.
- Configure per-dependency: different thresholds for critical vs. non-critical services.
- Always provide meaningful fallback: cached data, default response, or graceful degradation.

```python
# Circuit breaker states
CLOSED  → calls pass through, failures counted
OPEN    → calls blocked, fallback returned immediately
HALF_OPEN → limited probe calls, success resets to CLOSED
```

## Bulkhead Pattern

Isolate service resources into independent pools to contain failures.

Rules:
- Assign separate thread pools or connection pools per downstream dependency.
- If one dependency exhausts its pool, other dependencies remain unaffected.
- Combine with circuit breaker: bulkhead limits concurrency, circuit breaker limits failure rate.
- Size pools based on expected load and acceptable latency for each dependency.

## Retry with Exponential Backoff

Retry transient failures with progressively longer delays.

Rules:
- Use exponential backoff: delay = base * 2^attempt (e.g., 1s, 2s, 4s, 8s).
- Add random jitter to prevent thundering herd: delay = base * 2^attempt + random(0, base).
- Set max retries (3–5) and max delay cap (30–60s).
- Only retry on transient errors (5xx, timeouts). Never retry 4xx client errors.
- Ensure downstream operations are idempotent before enabling retries.

## Saga Pattern

Coordinate distributed transactions across services using a sequence of local transactions with compensating actions.

### Choreography
Each service publishes domain events; other services react.

Rules:
- Service completes local transaction, publishes event. Next service listens and acts.
- On failure, publish compensating events to undo prior steps.
- Best for simple flows (2–4 services). Becomes hard to trace with more.
- Every service must handle out-of-order and duplicate events.

### Orchestration
A central orchestrator directs the saga steps.

Rules:
- Orchestrator sends commands to each participant, waits for response, decides next step.
- On failure, orchestrator sends compensating commands in reverse order.
- Best for complex flows (5+ services) or when you need centralized monitoring.
- Orchestrator must be stateful and persistent (use a workflow engine or state machine).

```
# Choreography: Order Saga
OrderService → OrderCreated event
  → PaymentService listens → PaymentProcessed event
    → InventoryService listens → InventoryReserved event
      → ShippingService listens → OrderShipped event

# Orchestration: Order Saga
Orchestrator → CreateOrder(OrderService)
            → ProcessPayment(PaymentService)
            → ReserveInventory(InventoryService)
            → ShipOrder(ShippingService)
On failure at any step → compensate in reverse
```

## CQRS (Command Query Responsibility Segregation)

Separate write (command) and read (query) models into distinct paths.

Rules:
- Command side enforces business rules, validates, persists to write store.
- Query side reads from denormalized, read-optimized views or materialized projections.
- Sync read models via domain events (eventual consistency). Document acceptable staleness.
- Use CQRS only when read/write workloads differ significantly in shape or scale.
- Combine with Event Sourcing when you need full audit trail and temporal queries.

## Event-Driven Architecture

Services communicate asynchronously through domain events.

Rules:
- Publish events to a broker (Kafka, RabbitMQ, SNS/SQS). Consumers subscribe to topics.
- Events are immutable facts: `OrderPlaced`, `PaymentReceived`, `InventoryUpdated`.
- Design events as contracts: version them, use schema registry (Avro, Protobuf).
- Guarantee at-least-once delivery. Make consumers idempotent.
- Use dead-letter queues for messages that fail after max retries.

## Idempotent Consumer

Ensure processing the same message multiple times produces the same result.

Rules:
- Assign a unique idempotency key to every message/request (UUID, request ID).
- Store processed keys in a deduplication table. Check before processing.
- Set TTL on dedup entries based on your retry window (e.g., 24–72 hours).
- For HTTP APIs, accept `Idempotency-Key` header. Return cached response for duplicate keys.

```sql
-- Deduplication table
CREATE TABLE processed_events (
  event_id UUID PRIMARY KEY,
  processed_at TIMESTAMP DEFAULT NOW(),
  result JSONB
);
-- Before processing: SELECT 1 FROM processed_events WHERE event_id = ?
-- If found, return cached result. If not, process and INSERT.
```

## Transactional Outbox

Guarantee reliable event publishing alongside local database writes.

Rules:
- Write domain event to an `outbox` table in the same local DB transaction as the state change.
- A separate poller or CDC (Change Data Capture) process reads the outbox and publishes to the broker.
- Delete or mark outbox rows as published after successful broker acknowledgment.
- Guarantees at-least-once delivery without two-phase commit.

```sql
BEGIN TRANSACTION;
  INSERT INTO orders (id, status) VALUES ('ord-123', 'created');
  INSERT INTO outbox (id, aggregate_type, event_type, payload)
    VALUES (gen_random_uuid(), 'Order', 'OrderCreated', '{"orderId":"ord-123"}');
COMMIT;
-- CDC/poller picks up outbox rows and publishes to Kafka/RabbitMQ
```

## Database per Service

Each service owns a private database. No direct database access from other services.

Rules:
- Access another service's data only through its public API. Never share DB connections.
- Choose storage technology per service needs: relational, document, graph, time-series.
- Handle cross-service queries via API Composition or CQRS materialized views.
- Accept eventual consistency. Design UIs and workflows to tolerate it.

### Shared Database Anti-Pattern

Multiple services sharing one database schema.

Why it fails:
- Tight coupling: schema changes break multiple services simultaneously.
- No independent deployment. No independent scaling.
- Ownership ambiguity leads to data integrity issues.
- Only acceptable as transitional state during monolith migration. Plan your exit.

## API Composition

Aggregate data from multiple services into a single response.

Rules:
- Implement in the API Gateway or a dedicated Composer service.
- Call downstream services in parallel when possible. Use timeouts and fallbacks.
- Handle partial failures: return partial data with degraded status, not a full error.
- Cache frequently composed responses to reduce downstream load.

## Strangler Fig Migration

Incrementally replace monolith functionality with microservices.

Rules:
- Route requests through a facade (proxy). Redirect specific routes to new services.
- Migrate one bounded context at a time, starting with the least coupled.
- Keep monolith and new services running in parallel during transition.
- Use feature flags to control traffic routing. Roll back instantly if needed.
- Never do a big-bang rewrite. Each increment must be independently deployable and testable.

```
Phase 1: Proxy → 100% Monolith
Phase 2: Proxy → /orders/* → OrderService | rest → Monolith
Phase 3: Proxy → /orders/*, /payments/* → New Services | rest → Monolith
Phase N: Proxy → 100% Microservices → Decommission Monolith
```

## Sidecar / Ambassador / Adapter Patterns

### Sidecar
Deploy a helper process alongside each service instance.

Rules:
- Handle cross-cutting concerns: logging, metrics, mTLS, config, proxy.
- Sidecar shares lifecycle with its service (same pod, same VM).
- Keep sidecars generic and reusable across services.

### Ambassador
A specialized sidecar acting as a proxy for outbound traffic.

Rules:
- Handle retries, circuit breaking, routing, and monitoring for outgoing calls.
- Offload connection management (connection pooling, TLS) from the service.

### Adapter
A specialized sidecar that standardizes a service's interface.

Rules:
- Normalize heterogeneous service outputs to a common format (metrics, logs, protocols).
- Use when integrating legacy services with different interfaces into a unified system.

## Service Mesh

Dedicated infrastructure layer for managing service-to-service communication.

Rules:
- Deploy data plane proxies (Envoy) as sidecars to every service.
- Control plane (Istio, Linkerd) manages routing, load balancing, mTLS, observability.
- Use for: mutual TLS everywhere, traffic shifting (canary), distributed tracing injection.
- Adds latency and operational complexity. Justify with scale (50+ services) or strict security needs.

## Observability Patterns

### Distributed Tracing
Track requests across service boundaries with correlation IDs.

Rules:
- Propagate trace context (W3C Trace Context, B3) in headers across all service calls.
- Instrument at service entry/exit points. Record span timing, status, metadata.
- Tools: OpenTelemetry (standard), Jaeger, Zipkin for collection and visualization.

### Health Check API
Expose endpoints reporting service and dependency health.

Rules:
- `/health/live` — process is running (liveness). `/health/ready` — can serve traffic (readiness).
- Readiness checks must verify downstream dependencies (DB, cache, message broker).
- Return structured JSON: `{"status":"UP","dependencies":{"db":"UP","cache":"DOWN"}}`.
- Integrate with orchestrator (K8s probes) and load balancer health checks.

### Log Aggregation
Centralize logs from all services into a searchable store.

Rules:
- Emit structured logs (JSON) with correlation ID, service name, timestamp.
- Ship to central store: ELK (Elasticsearch/Logstash/Kibana), Loki, Splunk.
- Set consistent log levels across services. Alert on ERROR patterns.

## Testing Strategies

### Contract Testing (Consumer-Driven Contracts)
Verify service interfaces without full integration tests.

Rules:
- Consumer defines expected request/response pairs (contract).
- Provider runs contract tests in CI to verify it honors all consumer contracts.
- Tools: Pact, Spring Cloud Contract. Fail the provider build if contracts break.
- Test at the API boundary, not internal implementation.

### Testing Pyramid for Microservices
- Unit tests: business logic within each service (fast, many).
- Integration tests: service + its database/dependencies (medium).
- Contract tests: inter-service API compatibility (medium).
- End-to-end tests: critical paths only (slow, few). Avoid broad E2E coverage.

## Deployment Patterns

### Blue-Green Deployment
Run two identical environments. Route traffic to one while deploying to the other.

Rules:
- Deploy new version to idle environment. Run smoke tests. Switch traffic atomically.
- Keep both environments running briefly for instant rollback.
- Ensure database migrations are backward-compatible (both versions must work with same schema).

### Canary Deployment
Roll out changes to a small subset of traffic before full deployment.

Rules:
- Route 1–5% traffic to canary. Monitor error rates, latency, business metrics.
- Automate promotion: increase traffic if metrics are healthy, roll back if degraded.
- Use weighted routing (service mesh, load balancer) to control traffic split.

### Feature Flags
Decouple deployment from release. Deploy code dark, enable via configuration.

Rules:
- Use feature flags for gradual rollouts, A/B testing, kill switches.
- Clean up flags after full rollout. Stale flags are technical debt.
- Tools: LaunchDarkly, Unleash, Flagsmith, or simple config-based flags.

## Distributed Transactions

Avoid traditional two-phase commit (2PC) in microservices — it blocks and doesn't scale.

Rules:
- Prefer Saga pattern for cross-service state changes.
- Use Transactional Outbox + CDC for reliable event publishing.
- Accept eventual consistency. Design compensating actions for every forward action.
- If you truly need strong consistency across services, reconsider your service boundaries.

## Pattern Selection Decision Guide

```
Need to break apart a monolith?
  → Strangler Fig + Decompose by Business Capability

Need cross-service data queries?
  → API Composition (simple) or CQRS (complex/high-scale)

Need cross-service transactions?
  → Saga (Choreography for simple, Orchestration for complex)

Need resilience against downstream failures?
  → Circuit Breaker + Bulkhead + Retry with Backoff

Need reliable async messaging?
  → Event-Driven + Transactional Outbox + Idempotent Consumer

Need safe deployments?
  → Canary + Feature Flags (or Blue-Green for atomic switches)

Need observability across services?
  → Distributed Tracing + Log Aggregation + Health Check APIs
```

## Examples

### Input: "Design an order processing system with payments and inventory"
Output: Apply Decompose by Business Capability. Create OrderService, PaymentService, InventoryService. Use Saga (Orchestration) for the order flow: create order → process payment → reserve inventory. Implement Transactional Outbox in each service for reliable event publishing. Add Circuit Breaker on payment calls. Expose a Health Check API per service. Use API Gateway for client-facing endpoints.

### Input: "We have a monolith and want to migrate to microservices"
Output: Apply Strangler Fig. Stand up an API proxy in front of the monolith. Identify bounded contexts via DDD. Extract the least-coupled domain first as a new service with its own database (Database per Service). Route its traffic through the proxy to the new service. Use feature flags to control cutover. Repeat for each domain. Keep shared database access as temporary bridge; plan schema migration per service.

### Input: "Our checkout fails when the recommendation service is slow"
Output: Apply Circuit Breaker on the recommendation call with 5s timeout, 50% failure threshold. Add Bulkhead: isolate recommendation calls in a dedicated thread pool (10 threads max). Implement fallback: return cached/popular recommendations when circuit is open. Add Retry with Backoff only for transient errors (503, timeout) with max 2 retries. Add distributed tracing to identify latency source.

### Input: "How do I ensure exactly-once processing with Kafka consumers?"
Output: Use Idempotent Consumer pattern. Assign each message a unique event ID. Store processed event IDs in a deduplication table within the same transaction as your business logic. On duplicate receipt, return the cached result. Combine with Transactional Outbox on the producer side: write events to an outbox table in the local DB transaction, then use CDC (Debezium) to publish to Kafka. This achieves effectively-once semantics end-to-end.

## References

Detailed research and pattern catalogs for deep dives:

- **references/advanced-patterns.md** — Choreography vs orchestration deep dive, distributed saga compensation strategies, event-driven architecture with CDC, service mesh data plane vs control plane, API versioning strategies, distributed caching patterns, cell-based architecture, data mesh in microservices, platform engineering patterns.
- **references/troubleshooting.md** — Common microservices pitfalls with symptoms/fix format: distributed monolith anti-pattern, chatty services, shared database coupling, improper service boundaries, cascade failures, data consistency issues, deployment coupling, testing in production safely, debugging distributed systems.
- **references/pattern-catalog.md** — Complete 28-pattern catalog in Problem/Solution/Consequences format with complexity ratings (★–★★★★), decision matrix, pattern dependency map, and recommended adoption order.

## Scripts

Executable helpers for microservices development workflows:

- **scripts/service-dependency-map.sh** — Scans a codebase for HTTP clients, gRPC, message broker usage, Docker Compose links, and K8s Service references. Outputs a text dependency report and Graphviz DOT graph.
- **scripts/health-check-all.sh** — Checks health of all microservices via `/health/ready` endpoints. Supports config file, Kubernetes auto-discovery, Docker Compose auto-discovery, parallel checks, and colorized output.
- **scripts/contract-test-setup.sh** — Sets up Pact consumer-driven contract testing for Node.js, Java, or Python. Generates consumer/provider test files, optionally provisions a Pact Broker via Docker, and creates a CI integration script.

## Assets

Templates, configurations, and reference implementations:

- **assets/saga-orchestrator.ts** — Generic TypeScript saga orchestrator with type-safe step definitions, automatic reverse-order compensation on failure, persistent state tracking, idempotent retry logic, and example order fulfillment saga.
- **assets/circuit-breaker.ts** — Circuit breaker implementation with sliding time window, configurable failure thresholds, CLOSED/OPEN/HALF_OPEN state machine, metrics collection, and fallback support.
- **assets/api-gateway.yaml** — API Gateway configuration template with Kong declarative config (routing, rate limiting, JWT auth, CORS, correlation IDs) and commented Envoy proxy config (circuit breaking, health checks, retry policies).
- **assets/outbox-pattern.sql** — PostgreSQL transactional outbox schema with polling query (FOR UPDATE SKIP LOCKED), dead letter table, idempotent consumer table, cleanup jobs, and monitoring queries.
- **assets/docker-compose-microservices.yaml** — Multi-service local development setup with API Gateway (Kong), 4 application services, per-service PostgreSQL databases, Kafka (KRaft mode), Redis, OpenTelemetry Collector, Jaeger, Prometheus, Grafana, pgAdmin, and MailHog.

<!-- tested: pass -->
