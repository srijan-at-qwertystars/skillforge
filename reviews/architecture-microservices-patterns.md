# Review: microservices-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys).

Excellent microservices architecture guide with clear ASCII diagrams throughout. Covers service decomposition (business capability, DDD subdomain, strangler fig), communication patterns (REST vs gRPC sync, async message brokers), API Gateway (BFF pattern, responsibilities table, tools), circuit breaker (state machine, Resilience4j config, retry with backoff, bulkhead), service discovery (client-side/server-side/DNS/service mesh), service mesh (Istio vs Linkerd comparison with ambient mode mention), sidecar and ambassador patterns, distributed transactions (saga choreography vs orchestration, design rules, avoid 2PC), data management (database per service, CQRS, shared DB anti-pattern), observability (distributed tracing with W3C Trace Context, correlation IDs, health checks), deployment patterns (blue-green, canary, feature flags), testing (contract testing with Pact, synthetic monitoring, chaos engineering), anti-patterns (distributed monolith, chatty services), and quick reference table.
