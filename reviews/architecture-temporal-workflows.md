# Review: temporal-workflows
Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5
Issues: none

Outstanding Temporal workflow orchestration guide with standard description format. Covers fundamentals (durable execution, workflow/activity/worker/task queue/server), deterministic workflow rules (5 rules), versioning (GetVersion/patched), side effects, activities (4 timeout types table, heartbeating with resume, cancellation), signals/queries/updates, child workflows (parent close policies), continue-as-new, error handling (retry policies, non-retryable errors), saga pattern (TypeScript and Go implementations with compensation), timers and scheduling (Schedules API), TypeScript SDK (Worker/Client setup), Go SDK (Worker/context propagation), Python SDK (decorators), testing (TestWorkflowEnvironment with time skipping, mocking activities), deployment (Cloud: namespaces/mTLS/retention/multi-region; Self-hosted: PostgreSQL/Cassandra/Helm/Web UI), observability (Prometheus metrics, search attributes, OpenTelemetry), and anti-patterns table (10 items).
