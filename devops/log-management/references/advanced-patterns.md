# Advanced Logging Patterns

> Deep-dive reference for production logging: distributed tracing correlation, OpenTelemetry integration, log-based metrics, structured schema design, contextual logging, enrichment pipelines, multi-tenant isolation, and audit compliance.

## Table of Contents

- [Distributed Tracing Correlation](#distributed-tracing-correlation)
- [OpenTelemetry Log Bridge API](#opentelemetry-log-bridge-api)
- [Log-Based Metrics Extraction](#log-based-metrics-extraction)
- [Structured Logging Schema Design](#structured-logging-schema-design)
- [Contextual Logging (MDC / Context Propagation)](#contextual-logging-mdc--context-propagation)
- [Log Enrichment Pipelines](#log-enrichment-pipelines)
- [Multi-Tenant Logging Isolation](#multi-tenant-logging-isolation)
- [Audit Log Compliance (SOC2, HIPAA, GDPR)](#audit-log-compliance-soc2-hipaa-gdpr)
- [Log Analytics Patterns](#log-analytics-patterns)

---

## Distributed Tracing Correlation

Correlating logs with distributed traces enables "click from trace span → see exact logs" and vice versa.

### Key Fields

Every log entry in a traced system must include:

| Field | Source | Purpose |
|-------|--------|---------|
| `trace_id` | W3C Trace Context / OpenTelemetry | Links log to distributed trace |
| `span_id` | Current span | Links log to specific operation |
| `parent_span_id` | Parent span | Reconstructs call hierarchy |
| `service.name` | OTEL resource | Identifies emitting service |
| `request_id` | Application | Groups all work for one user request |

### Implementation Patterns

**Auto-injection (preferred):** Use OTEL SDK auto-instrumentation to inject trace context into log records automatically. Supported in Java (Logback/Log4j2 appenders), Python (logging integration), Node.js (Pino/Winston hooks), Go (slog handler wrappers).

**Manual injection:** Extract from current span context and add to logger:

```python
# Python — inject trace context into structlog
from opentelemetry import trace

def add_trace_context(logger, method_name, event_dict):
    span = trace.get_current_span()
    ctx = span.get_span_context()
    if ctx.is_valid:
        event_dict["trace_id"] = format(ctx.trace_id, "032x")
        event_dict["span_id"] = format(ctx.span_id, "016x")
    return event_dict

structlog.configure(processors=[add_trace_context, ...])
```

```go
// Go — inject trace context into slog
func TraceHandler(next slog.Handler) slog.Handler {
    return &traceHandler{next: next}
}

func (h *traceHandler) Handle(ctx context.Context, r slog.Record) error {
    span := trace.SpanFromContext(ctx)
    sc := span.SpanContext()
    if sc.IsValid() {
        r.AddAttrs(
            slog.String("trace_id", sc.TraceID().String()),
            slog.String("span_id", sc.SpanID().String()),
        )
    }
    return h.next.Handle(ctx, r)
}
```

### Backend Correlation

| Platform | How to Link |
|----------|-------------|
| Grafana (Loki + Tempo) | Configure derived fields in Loki data source: regex `trace_id=(\w+)` → link to Tempo |
| Elastic (ELK + APM) | Use `trace.id` and `span.id` ECS fields; Kibana auto-links to APM traces |
| Datadog | Unified `dd.trace_id` / `dd.span_id` injected by Datadog SDK |
| Jaeger + ELK | Store `traceID` in log, create Kibana URL template linking to Jaeger UI |

---

## OpenTelemetry Log Bridge API

The OTEL Log Bridge API connects existing language-native loggers to the OpenTelemetry pipeline without requiring you to replace your logging library.

### Architecture

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────┐
│  App Code    │────▶│  Native Logger   │────▶│  OTEL Bridge │
│  log.info()  │     │  (Pino/slog/etc) │     │  Appender    │
└──────────────┘     └──────────────────┘     └──────┬───────┘
                                                      │
                                              ┌───────▼───────┐
                                              │ OTEL Collector │
                                              │  (logs pipeline)│
                                              └───────┬───────┘
                                                      │
                                     ┌────────────────┼────────────────┐
                                     ▼                ▼                ▼
                                   Loki         Elasticsearch      S3/GCS
```

### OTEL Log Data Model

| Field | Type | Description |
|-------|------|-------------|
| `Timestamp` | uint64 | Event time (nanoseconds since epoch) |
| `ObservedTimestamp` | uint64 | When collector received the log |
| `SeverityNumber` | int | 1-24 (maps to TRACE through FATAL) |
| `SeverityText` | string | Original level string ("INFO", "warn") |
| `Body` | any | Log message (string, map, or array) |
| `Attributes` | map | Structured key-value context |
| `Resource` | map | Service identity (name, version, env) |
| `TraceId` | bytes | W3C trace ID (16 bytes) |
| `SpanId` | bytes | W3C span ID (8 bytes) |
| `TraceFlags` | byte | Sampling flags |

### Language Integrations

**Java (Log4j2 / Logback):**
```xml
<!-- Add OTEL appender to logback.xml -->
<appender name="OpenTelemetry" class="io.opentelemetry.instrumentation.logback.appender.v1_0.OpenTelemetryAppender">
  <captureExperimentalAttributes>true</captureExperimentalAttributes>
  <captureMdcAttributes>*</captureMdcAttributes>
</appender>
```

**Python:**
```python
from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor, OTLPLogExporter

provider = LoggerProvider()
provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
set_logger_provider(provider)

# Now standard logging.getLogger() calls emit to OTEL
import opentelemetry.instrumentation.logging
opentelemetry.instrumentation.logging.LoggingInstrumentor().instrument(set_logging_format=True)
```

**Node.js:**
```javascript
const { logs } = require('@opentelemetry/api-logs');
const { LoggerProvider, BatchLogRecordProcessor } = require('@opentelemetry/sdk-logs');
const { OTLPLogExporter } = require('@opentelemetry/exporter-logs-otlp-grpc');

const loggerProvider = new LoggerProvider();
loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(new OTLPLogExporter()));
logs.setGlobalLoggerProvider(loggerProvider);
```

---

## Log-Based Metrics Extraction

Extract quantitative metrics from log streams to power dashboards and alerts without separate instrumentation.

### Techniques

**1. Loki — metric queries from logs:**
```logql
# Error rate per service (counter)
sum(rate({job="app"} | json | level="error" [5m])) by (service)

# P99 request duration from log fields (histogram)
quantile_over_time(0.99, {job="app"} | json | unwrap duration_ms [5m]) by (endpoint)

# Unique users per hour
count_over_time({job="auth"} | json | action="login" [1h])
```

**2. Logstash — emit metrics to Prometheus:**
```ruby
filter {
  if [level] == "error" {
    metrics {
      meter => ["error_rate"]
      add_tag => "metric"
    }
  }
}
output {
  if "metric" in [tags] {
    prometheus_exporter { host => "0.0.0.0" port => 9198 }
  }
}
```

**3. Vector — log-to-metric transforms:**
```toml
[transforms.log_to_metric]
type = "log_to_metric"
inputs = ["app_logs"]

[[transforms.log_to_metric.metrics]]
type = "counter"
field = "level"
name = "log_events_total"
tags.level = "{{level}}"
tags.service = "{{service}}"

[[transforms.log_to_metric.metrics]]
type = "histogram"
field = "duration_ms"
name = "request_duration_ms"
```

**4. OTEL Collector — connectors pipeline:**
```yaml
connectors:
  count:
    logs:
      log.error.count:
        description: "Error log count"
        conditions:
          - 'severity_number >= 17'  # ERROR and above
        attributes:
          - key: service.name

service:
  pipelines:
    logs:
      receivers: [filelog]
      exporters: [count]
    metrics:
      receivers: [count]
      exporters: [prometheus]
```

### Anti-Patterns

- **Don't extract high-cardinality metrics** (e.g., per-user-id counters) — use log queries instead
- **Don't replace proper instrumentation** — log-derived metrics have higher latency and miss events during sampling
- **Don't create too many metric series** — each unique label combination creates a new time series

---

## Structured Logging Schema Design

### Canonical Schema

Design a schema once, enforce across all services via shared libraries or linting.

```json
{
  "timestamp": "2024-03-24T12:34:56.789Z",
  "level": "info",
  "message": "Request completed",
  "logger": "http.handler",

  "service": {
    "name": "user-api",
    "version": "2.4.1",
    "environment": "production",
    "instance_id": "i-0abc123"
  },

  "trace": {
    "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
    "span_id": "00f067aa0ba902b7",
    "parent_span_id": "d7ad64be7f244c13"
  },

  "request": {
    "id": "req-a1b2c3d4",
    "method": "POST",
    "path": "/api/v2/orders",
    "user_agent": "Mozilla/5.0",
    "duration_ms": 142,
    "status": 201
  },

  "context": {
    "user_id": "usr_12345",
    "tenant_id": "tenant_acme",
    "feature_flags": ["new-checkout"]
  },

  "error": {
    "type": "ValidationError",
    "message": "Missing required field: email",
    "stack": "...",
    "code": "VALIDATION_001"
  },

  "schema_version": "1.2"
}
```

### Schema Design Rules

1. **Use consistent field names** — `duration_ms` not sometimes `latency` or `elapsed`
2. **Nest related fields** — `request.method`, `service.name`, not flat `request_method`
3. **Use snake_case** — universal, works across languages
4. **Version your schema** — add `schema_version` field for backward compatibility
5. **Separate context from event** — `message` describes what happened, `context` provides environment
6. **Use typed values** — `duration_ms: 142` (number) not `"142"` (string)
7. **Limit top-level fields** — avoid mapping explosions in Elasticsearch; use nested objects
8. **Include error objects** — structured error with type/message/stack/code, not error-in-message

### ECS (Elastic Common Schema) Alignment

If using ELK, align with [Elastic Common Schema](https://www.elastic.co/guide/en/ecs/current/index.html):
- `@timestamp`, `log.level`, `message`, `service.name`, `trace.id`, `error.message`, `error.stack_trace`

---

## Contextual Logging (MDC / Context Propagation)

### Per-Language Patterns

**Java — MDC (Mapped Diagnostic Context):**
```java
// Set at request entry (filter/interceptor)
MDC.put("request_id", requestId);
MDC.put("user_id", userId);
MDC.put("tenant_id", tenantId);

try {
    // All log statements in this thread automatically include MDC fields
    logger.info("Processing order");  // includes request_id, user_id, tenant_id
} finally {
    MDC.clear();  // ALWAYS clear to prevent context leakage
}

// Thread-pool propagation — wrap Runnable to copy MDC
public class MdcAwareRunnable implements Runnable {
    private final Map<String, String> contextMap = MDC.getCopyOfContextMap();
    private final Runnable delegate;

    public MdcAwareRunnable(Runnable delegate) { this.delegate = delegate; }

    @Override
    public void run() {
        MDC.setContextMap(contextMap);
        try { delegate.run(); }
        finally { MDC.clear(); }
    }
}
executor.submit(new MdcAwareRunnable(() -> processOrder(order)));
```

**Python — contextvars (async-safe):**
```python
import contextvars
import structlog

request_id_var: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="")
tenant_id_var: contextvars.ContextVar[str] = contextvars.ContextVar("tenant_id", default="")

def inject_context(logger, method_name, event_dict):
    event_dict["request_id"] = request_id_var.get()
    event_dict["tenant_id"] = tenant_id_var.get()
    return event_dict

structlog.configure(processors=[inject_context, structlog.processors.JSONRenderer()])

# In middleware (FastAPI example)
@app.middleware("http")
async def context_middleware(request, call_next):
    request_id_var.set(request.headers.get("X-Request-ID", str(uuid4())))
    tenant_id_var.set(request.headers.get("X-Tenant-ID", ""))
    return await call_next(request)
```

**Go — context.Context (idiomatic):**
```go
type ctxKey string

const (
    requestIDKey ctxKey = "request_id"
    tenantIDKey  ctxKey = "tenant_id"
)

// Middleware adds context
func WithRequestContext(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        ctx := context.WithValue(r.Context(), requestIDKey,
            r.Header.Get("X-Request-ID"))
        ctx = context.WithValue(ctx, tenantIDKey,
            r.Header.Get("X-Tenant-ID"))
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

// Logger extracts from context
func LoggerFromCtx(ctx context.Context) *slog.Logger {
    return slog.Default().With(
        "request_id", ctx.Value(requestIDKey),
        "tenant_id", ctx.Value(tenantIDKey),
    )
}
```

**Node.js — AsyncLocalStorage:**
```javascript
import { AsyncLocalStorage } from 'node:async_hooks';
import pino from 'pino';

const als = new AsyncLocalStorage();
const baseLogger = pino();

export const logger = new Proxy(baseLogger, {
  get(target, prop) {
    const store = als.getStore();
    const child = store ? target.child(store) : target;
    return child[prop];
  }
});

// Express middleware
app.use((req, res, next) => {
  als.run({
    request_id: req.headers['x-request-id'] || crypto.randomUUID(),
    tenant_id: req.headers['x-tenant-id'],
  }, next);
});
```

---

## Log Enrichment Pipelines

### Pipeline Architecture

```
App (JSON logs)
  → Collector (Fluent Bit / OTEL Collector)
    → Enrich (add k8s metadata, geo-IP, tenant info)
      → Redact (PII removal)
        → Route (by tenant, severity, compliance)
          → Store (Elasticsearch / Loki / S3)
```

### Enrichment Stages

**1. Kubernetes metadata (Fluent Bit):**
```ini
[FILTER]
    Name         kubernetes
    Match        kube.*
    Merge_Log    On
    K8S-Logging.Parser On
    Labels       On
    Annotations  Off
```

**2. Geo-IP enrichment (Logstash):**
```ruby
filter {
  geoip {
    source => "client_ip"
    target => "geo"
    fields => ["city_name", "country_code2", "location"]
  }
}
```

**3. PII redaction (OTEL Collector):**
```yaml
processors:
  transform:
    log_statements:
      - context: log
        statements:
          - replace_pattern(body, "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z]{2,}\\b", "[EMAIL_REDACTED]")
          - replace_pattern(body, "\\b\\d{3}-\\d{2}-\\d{4}\\b", "[SSN_REDACTED]")
          - replace_pattern(attributes["user.email"], ".*", "[REDACTED]")
```

**4. Tenant-based routing (Vector):**
```toml
[transforms.route_by_tenant]
type = "route"
inputs = ["enriched_logs"]

[transforms.route_by_tenant.route]
enterprise = '.tenant_tier == "enterprise"'
standard = '.tenant_tier == "standard"'
_unmatched = "default"

[sinks.enterprise_es]
type = "elasticsearch"
inputs = ["route_by_tenant.enterprise"]
endpoints = ["https://es-enterprise:9200"]

[sinks.standard_loki]
type = "loki"
inputs = ["route_by_tenant.standard"]
endpoint = "http://loki:3100"
```

---

## Multi-Tenant Logging Isolation

### Isolation Strategies

| Strategy | Isolation Level | Complexity | Use Case |
|----------|----------------|------------|----------|
| **Label/field tagging** | Logical | Low | Most SaaS applications |
| **Separate indices** | Index-level | Medium | Per-tenant compliance needs |
| **Separate clusters** | Infrastructure | High | Regulated industries (HIPAA) |
| **Separate storage buckets** | Storage | Medium | Data residency requirements |

### Implementation: Separate Elasticsearch Indices

```ruby
# Logstash — route to per-tenant index
output {
  elasticsearch {
    hosts => ["es:9200"]
    index => "logs-%{[tenant_id]}-%{+YYYY.MM.dd}"
    # Use index template per tenant for custom retention
  }
}
```

```json
// Elasticsearch role — restrict tenant access
{
  "indices": [{
    "names": ["logs-acme-*"],
    "privileges": ["read"],
    "query": { "term": { "tenant_id": "acme" } }
  }]
}
```

### Implementation: Loki Multi-Tenancy

```yaml
# Loki config — enable multi-tenancy
auth_enabled: true

# Promtail — set tenant header
clients:
  - url: http://loki:3100/loki/api/v1/push
    tenant_id: "${TENANT_ID}"

# Query — pass tenant header
# curl -H "X-Scope-OrgID: acme" http://loki:3100/loki/api/v1/query
```

---

## Audit Log Compliance (SOC2, HIPAA, GDPR)

### Requirements Matrix

| Requirement | SOC2 | HIPAA | GDPR |
|------------|------|-------|------|
| **Log access events** | ✅ Required | ✅ Required (PHI access) | ✅ Required |
| **Tamper-proof storage** | ✅ Required | ✅ Required | Recommended |
| **Retention period** | 1 year typical | 6 years minimum | "As long as necessary" |
| **Access control on logs** | ✅ RBAC required | ✅ Minimum necessary | ✅ Data minimization |
| **PII/PHI in logs** | Minimize | ❌ Prohibit unless needed | ❌ Minimize, enable deletion |
| **Data residency** | N/A | US typically | ✅ EU/specified region |
| **Breach notification** | Required | 60 days | 72 hours |
| **Right to deletion** | N/A | N/A | ✅ "Right to be forgotten" |

### Audit Log Schema

```json
{
  "timestamp": "2024-03-24T12:34:56.789Z",
  "event_type": "data_access",
  "action": "read",
  "actor": {
    "user_id": "usr_12345",
    "email_hash": "sha256:abc...",
    "ip_address": "10.0.1.50",
    "user_agent": "Mozilla/5.0",
    "auth_method": "sso_saml"
  },
  "resource": {
    "type": "patient_record",
    "id": "rec_67890",
    "owner_tenant": "hospital_a"
  },
  "outcome": "success",
  "metadata": {
    "request_id": "req-abc",
    "service": "records-api",
    "environment": "production"
  }
}
```

### Tamper-Proof Storage

- **WORM (Write Once Read Many):** AWS S3 Object Lock, Azure Immutable Blob Storage
- **Hash chains:** Each log batch includes SHA-256 hash of previous batch
- **Separate audit log pipeline:** Audit logs must not flow through the same pipeline as application logs where developers have write access

```bash
# AWS S3 Object Lock for audit logs
aws s3api put-object-lock-configuration \
  --bucket audit-logs-prod \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": {
      "DefaultRetention": {
        "Mode": "COMPLIANCE",
        "Years": 7
      }
    }
  }'
```

### GDPR-Specific: Right to Deletion

Implement pseudonymization so you can delete the mapping key:

```
Log entry:  { "user_ref": "anon_abc123", "action": "purchase" }
Mapping DB: { "anon_abc123" → "user@example.com" }

Deletion request → delete mapping → logs become truly anonymous
```

---

## Log Analytics Patterns

### Common Queries

**Error spike detection (Loki):**
```logql
# Sudden error increase vs baseline
sum(rate({service=~".+"} | json | level="error" [5m])) by (service)
  > 3 * sum(rate({service=~".+"} | json | level="error" [1h])) by (service)
```

**Slow request analysis (Elasticsearch):**
```json
{
  "query": { "bool": {
    "must": [
      { "range": { "duration_ms": { "gte": 1000 } } },
      { "range": { "@timestamp": { "gte": "now-1h" } } }
    ]
  }},
  "aggs": {
    "by_endpoint": {
      "terms": { "field": "request.path.keyword", "size": 20 },
      "aggs": {
        "p99_duration": { "percentiles": { "field": "duration_ms", "percents": [50, 95, 99] } }
      }
    }
  }
}
```

**User journey reconstruction:**
```logql
{service=~".+"} | json | request_id="req-abc123" | line_format "{{.timestamp}} [{{.service}}] {{.message}}"
```

**Deployment impact analysis:**
```logql
# Compare error rates before/after deployment
# Before (look at 1h window before deploy time)
sum(rate({service="api"} | json | level="error" [1h] offset 2h))
# After
sum(rate({service="api"} | json | level="error" [1h]))
```
