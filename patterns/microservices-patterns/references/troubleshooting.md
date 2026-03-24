# Microservices Troubleshooting Guide

Common pitfalls, anti-patterns, and their remedies. Each section: symptoms, root cause, impact, fix.

## Table of Contents

1. [Distributed Monolith](#1-distributed-monolith)
2. [Chatty Services](#2-chatty-services)
3. [Shared Database Coupling](#3-shared-database-coupling)
4. [Improper Service Boundaries](#4-improper-service-boundaries)
5. [Cascade Failures](#5-cascade-failures)
6. [Data Consistency Issues](#6-data-consistency-issues)
7. [Deployment Coupling](#7-deployment-coupling)
8. [Testing in Production Safely](#8-testing-in-production-safely)
9. [Debugging Distributed Systems](#9-debugging-distributed-systems)

---

## 1. Distributed Monolith

### Symptoms
- Cannot deploy one service without deploying others simultaneously
- Changing one service's API breaks multiple other services immediately
- All services share a release schedule or version number
- A single team must coordinate changes across many services
- Service failures cascade to the entire system

### Root Cause
Services are physically separated but logically coupled through shared databases, synchronous call chains, shared libraries with business logic, or lock-step deployment requirements.

### Impact
You get the worst of both worlds: the operational complexity of microservices (network failures, distributed debugging, deployment orchestration) with none of the benefits (independent deployment, team autonomy, isolated scaling).

### Fix
1. **Audit coupling points.** Map all inter-service dependencies. Look for shared DB tables, shared domain libraries, synchronous call chains longer than 2 hops.
2. **Introduce async communication.** Replace synchronous call chains with events. Services react to events rather than calling each other directly.
3. **Enforce database-per-service.** Migrate shared tables into the owning service. Other services access data through APIs or consume events.
4. **Define explicit contracts.** Use consumer-driven contract tests (Pact) to decouple API evolution from deployment schedules.
5. **Allow independent deployment.** If you can't deploy Service A without Service B, they're not separate services — merge or properly decouple them.

### Litmus Test
> Can you deploy any single service to production without coordinating with other teams? If no, you have a distributed monolith.

---

## 2. Chatty Services

### Symptoms
- A single user request triggers 10+ inter-service API calls
- P99 latency is dominated by cumulative network round-trips, not computation
- Service dependency graphs show fan-out patterns (one request fans out to many services)
- Timeouts increase proportionally with the number of downstream calls

### Root Cause
Over-granular service decomposition (nanoservices), services modeled around data entities instead of business capabilities, or missing aggregation layers.

### Impact
- Network latency compounds: 10 calls × 5ms each = 50ms minimum overhead
- Reliability decreases multiplicatively: 10 services at 99.9% uptime = 99% aggregate uptime
- Debugging becomes exponentially harder with each hop

### Fix
1. **Merge nanoservices.** If two services always change together and are called together, they should be one service.
2. **Add aggregation layers.** Use Backend-for-Frontend (BFF) or API Composition to batch downstream calls.
3. **Use async where possible.** Replace synchronous data fetching with event-driven data replication. Maintain local read models.
4. **Batch API designs.** Support bulk endpoints (`GET /users?ids=1,2,3`) instead of single-entity endpoints.
5. **Cache aggressively.** Cache reference data locally to eliminate repetitive cross-service calls.

### Diagnostic Command
Count inter-service calls per user request using distributed tracing:
```
# In Jaeger/Zipkin, look for traces with > 5 spans per request
# High span counts indicate chatty patterns
```

---

## 3. Shared Database Coupling

### Symptoms
- Multiple services read/write the same database tables
- Schema migrations require coordinating across multiple teams
- Database connection pools are exhausted by combined service load
- No clear owner for shared tables — data quality degrades

### Root Cause
Teams took a shortcut during decomposition: split the application but left the database shared. Common during monolith migrations.

### Impact
- Schema changes break multiple services simultaneously
- No independent scaling — all services contend for same DB resources
- Ownership ambiguity leads to data corruption and conflicting business rules
- Cannot adopt different storage technologies per service

### Fix

**Phase 1: Identify ownership.**
Map every table to exactly one owning service. Tables used by multiple services need an owner decision.

**Phase 2: Create read APIs.**
Non-owning services access shared data through the owning service's API instead of direct DB queries.

**Phase 3: Replicate via events.**
For high-read-volume data, the owning service publishes change events. Consuming services maintain local read replicas.

**Phase 4: Split the database.**
Migrate owned tables into service-specific databases. Cut direct DB connections from non-owning services.

```
BEFORE:  ServiceA → SharedDB ← ServiceB ← ServiceC
AFTER:   ServiceA → DB_A
         ServiceB → DB_B (listens to events from A)
         ServiceC → DB_C (calls B's API for B-owned data)
```

### Timeline
Plan 3–6 months per major table migration. This is a gradual, high-risk change — never big-bang it.

---

## 4. Improper Service Boundaries

### Symptoms
- Services named after technical layers (`AuthService`, `DatabaseService`, `NotificationService`) instead of business domains
- Most changes require modifying 3+ services
- Teams struggle to determine which service owns a feature
- Data entities are split across services (half of `Order` in one service, half in another)

### Root Cause
Decomposition by technical layer instead of business capability. Or premature decomposition without understanding the domain.

### Impact
- Feature development slows because every change crosses service boundaries
- Communication overhead between teams increases
- Domain logic leaks into multiple services, creating inconsistency

### Fix
1. **Use DDD to find boundaries.** Run Event Storming workshops to identify bounded contexts. Map aggregates, commands, and events.
2. **Align to business capabilities.** `OrderManagement`, `Billing`, `Inventory` — not `RestController`, `DataAccess`, `MessageSender`.
3. **Apply the "two pizza team" test.** Each service should be owned by a team of 5–8 people who understand its full domain.
4. **Start with a monolith.** If domain boundaries are unclear, build a well-structured modular monolith first. Extract services only when boundaries are proven.

### Boundary Validation Questions
- Does this service represent a single business capability?
- Can the owning team make changes without coordinating with other teams?
- Does the service own its data end-to-end?
- Would a domain expert recognize this as a coherent business concept?

---

## 5. Cascade Failures

### Symptoms
- One service going down takes 5+ other services with it
- Timeout errors propagate upstream in a chain reaction
- Thread pools and connection pools fill up waiting for failed downstream services
- System-wide outages triggered by a single component failure

### Root Cause
Synchronous call chains without resilience patterns. Service A calls B, which calls C. When C is slow or down, B's threads block, then A's threads block, and so on up the chain.

### Impact
Total system outage from a single service failure. Recovery requires restarting multiple services in dependency order.

### Fix

**Immediate (hours):**
1. Add timeouts to ALL outgoing calls. No call should wait more than 2–5 seconds.
2. Set connection pool limits per downstream dependency (bulkhead pattern).

**Short-term (days):**
3. Implement circuit breakers on all cross-service calls. Configure per-dependency thresholds.
4. Define fallback responses: cached data, default values, or graceful degradation.

**Medium-term (weeks):**
5. Replace synchronous chains with async event-driven communication where possible.
6. Implement bulkhead pattern: isolate thread pools per downstream dependency.
7. Add load shedding: reject requests early when system is overloaded rather than queueing indefinitely.

**Long-term (months):**
8. Run chaos engineering experiments (Chaos Monkey, Litmus) to validate resilience.
9. Implement cell-based architecture for blast radius containment.

### Resilience Stack
```
Request → Rate Limiter → Circuit Breaker → Bulkhead → Timeout → Retry → Fallback
            (shed load)   (fail fast)     (isolate)   (bound wait) (transient) (degrade)
```

---

## 6. Data Consistency Issues

### Symptoms
- Different services show different data for the same entity (order shows "paid" in one, "unpaid" in another)
- Phantom reads: data appears and disappears inconsistently
- Business operations partially complete (payment charged but order not created)
- Reports show impossible states or mismatched totals

### Root Cause
Distributed systems cannot guarantee strong consistency across services (CAP theorem). Teams designed for strong consistency but implemented eventual consistency without proper patterns.

### Fix

**Accept eventual consistency by design:**
1. Use saga pattern for cross-service transactions with explicit compensation.
2. Use transactional outbox + CDC for reliable event publishing (eliminate dual-write risk).
3. Make all consumers idempotent — processing the same event twice must be safe.
4. Implement read-your-writes consistency where needed: after a write, route subsequent reads to the source of truth, not a replica.

**Detect and repair inconsistencies:**
5. Run periodic reconciliation jobs that compare data across services and flag discrepancies.
6. Implement event-sourced audit logs to reconstruct and verify state.
7. Add correlation IDs to trace a business transaction across all participating services.

**Communicate consistency expectations:**
8. Document staleness SLAs for every read model (e.g., "order status may be up to 5 seconds stale").
9. Design UIs to show "pending" states explicitly rather than hiding eventual consistency from users.

---

## 7. Deployment Coupling

### Symptoms
- Releases require deploying 3+ services in a specific order
- Rollback of one service requires rolling back others
- Release trains and deployment windows spanning multiple teams
- Environment contention: teams waiting for shared staging environments

### Root Cause
Coupled APIs without backward compatibility, shared database schemas, or feature dependencies spanning services.

### Fix
1. **Maintain backward-compatible APIs.** New versions must support old clients. Use additive changes (new fields, new endpoints) — never remove or rename existing fields without a deprecation period.
2. **Use expand-and-contract for schema changes:**
   - Expand: add new column/field alongside old one
   - Migrate: backfill data, update all consumers
   - Contract: remove old column/field
3. **Deploy in any order.** If service A v2 requires service B v3, you have coupling. Design APIs so any version combination works within N and N-1.
4. **Use feature flags** to decouple deployment from release. Deploy code dark, enable when all dependencies are ready.
5. **Give each team its own environment.** Use ephemeral environments (Namespace per PR, Docker Compose stacks) to eliminate contention.

---

## 8. Testing in Production Safely

### Why Test in Production
Pre-production environments can't replicate production's scale, data variety, traffic patterns, and infrastructure quirks. Some bugs only manifest in production.

### Safe Techniques

**1. Canary deployments:**
Route 1–5% of traffic to the new version. Monitor error rates, latency, and business metrics. Auto-rollback if degraded.

**2. Feature flags:**
Deploy code to all instances but enable for a subset of users (internal users, beta testers, specific tenants).

**3. Shadow traffic (dark launching):**
Duplicate production traffic to the new version without returning its responses to users. Compare outputs for correctness.

**4. Synthetic monitoring:**
Run automated test transactions against production endpoints continuously. Detect regressions immediately.

**5. Chaos engineering:**
Inject failures in production (kill instances, add latency, partition networks) to validate resilience. Start with non-critical services.

**6. Observability-driven testing:**
Deploy, observe dashboards and alerts. If anomalies appear within the bake window (15–60 minutes), auto-rollback.

### Safety Rules
- Never test destructive operations without a kill switch
- Always have instant rollback capability (blue-green, feature flags)
- Start with lowest-risk environments/users and expand gradually
- Monitor business metrics (conversion, revenue), not just technical metrics

---

## 9. Debugging Distributed Systems

### The Core Challenge
A single user request may traverse 10+ services. Logs are scattered across hosts, timestamps drift, and causality is hard to reconstruct.

### Essential Tooling

**1. Distributed tracing (non-negotiable):**
- Propagate W3C Trace Context headers across ALL service calls
- Every service creates spans for inbound/outbound calls
- Tools: OpenTelemetry (instrumentation) + Jaeger/Tempo (visualization)

**2. Structured logging:**
- JSON logs with mandatory fields: `traceId`, `spanId`, `service`, `timestamp`, `level`, `message`
- Correlate logs across services using traceId
- Ship to centralized store: ELK, Loki, Splunk

**3. Metrics with context:**
- RED metrics per service: Rate, Errors, Duration
- USE metrics per resource: Utilization, Saturation, Errors
- Tag metrics with service, version, environment, endpoint

### Debugging Workflow

```
1. Start with the symptom: user report, alert, anomaly in dashboard
2. Find the trace ID from the failing request
3. View the full trace in Jaeger/Tempo — identify which service/span is slow or erroring
4. Jump to that service's logs filtered by trace ID
5. Check that service's metrics for anomalies at the same timestamp
6. Examine the failing service's dependencies — is it a downstream issue?
7. Reproduce locally if needed using the captured request payload
```

### Common Gotchas
- **Clock skew:** Use NTP everywhere. Distributed traces rely on synchronized clocks.
- **Missing spans:** Instrument async message consumers, not just HTTP handlers.
- **Log volume explosion:** Use sampling for high-throughput traces (keep 100% of error traces, sample 1% of success traces).
- **Context loss:** Ensure trace context propagates through message queues, thread pools, and async callbacks — it doesn't happen automatically in most frameworks.
