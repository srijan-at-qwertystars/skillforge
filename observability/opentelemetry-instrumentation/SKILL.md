---
name: opentelemetry-instrumentation
description: |
  Use when user instruments applications with OpenTelemetry (OTel), configures traces/metrics/logs, sets up the OTel Collector, asks about distributed tracing, span attributes, context propagation, or exporters (Jaeger, Zipkin, OTLP, Prometheus).
  Do NOT use for Datadog-specific, New Relic-specific, or proprietary APM tool configurations. Do NOT use for general logging frameworks (log4j, winston) unless OTel log bridging.
---

# OpenTelemetry Instrumentation

## Architecture Overview

OTel has four core components:

- **API** — vendor-neutral interfaces for creating telemetry (traces, metrics, logs). Import the API package in library code.
- **SDK** — implements the API. Configure samplers, processors, and exporters here. Initialize once at application startup.
- **Collector** — standalone binary that receives, processes, and exports telemetry. Deploy as agent (sidecar) or gateway (centralized).
- **Exporters** — send data to backends (OTLP, Jaeger, Zipkin, Prometheus, etc.).

Signal flow:

```
App (SDK + API) --> [OTLP] --> Collector --> Backend (Jaeger/Tempo/Prometheus/etc.)
```

Always send telemetry to a Collector rather than directly to a backend. This decouples apps from backends, enables retry/batching, and simplifies backend migration.

---

## Auto-Instrumentation Setup

Use auto-instrumentation for immediate coverage of HTTP, gRPC, database, and messaging frameworks. Layer manual instrumentation on top for business logic.

### Python

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
```

```bash
opentelemetry-instrument \
  --service_name my-service \
  --traces_exporter otlp \
  --metrics_exporter otlp \
  --exporter_otlp_endpoint http://localhost:4317 \
  python app.py
```

### Node.js

```bash
npm install @opentelemetry/auto-instrumentations-node @opentelemetry/sdk-node @opentelemetry/exporter-trace-otlp-grpc
```

```js
// tracing.js — require BEFORE any other imports
const { NodeSDK } = require("@opentelemetry/sdk-node");
const { getNodeAutoInstrumentations } = require("@opentelemetry/auto-instrumentations-node");
const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-grpc");

const sdk = new NodeSDK({
  serviceName: "my-service",
  traceExporter: new OTLPTraceExporter({ url: "http://localhost:4317" }),
  instrumentations: [getNodeAutoInstrumentations()],
});
sdk.start();
```

Run with: `node --require ./tracing.js app.js`

### Java

Download the Java agent JAR from the OTel releases page.

```bash
java -javaagent:opentelemetry-javaagent.jar \
  -Dotel.service.name=my-service \
  -Dotel.exporter.otlp.endpoint=http://localhost:4317 \
  -jar myapp.jar
```

### Go

Go does not have a bytecode agent. Use instrumentation libraries per framework:

```bash
go get go.opentelemetry.io/otel \
       go.opentelemetry.io/otel/sdk \
       go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
```

```go
import "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

handler := otelhttp.NewHandler(mux, "server")
http.ListenAndServe(":8080", handler)
```

### Key Rules

- Initialize instrumentation **before** importing instrumented libraries (critical in Python and Node.js).
- Set `OTEL_SERVICE_NAME` and `OTEL_EXPORTER_OTLP_ENDPOINT` via environment variables for consistency across deployments.
- Filter noisy spans (health checks, static assets) with sampler config or Collector processors.

---

## Manual Instrumentation

### Creating a Tracer and Spans

```python
from opentelemetry import trace

tracer = trace.get_tracer("com.example.checkout", "1.0.0")

with tracer.start_as_current_span("process-order") as span:
    span.set_attribute("order.id", order_id)
    span.set_attribute("order.total", 99.95)
    span.add_event("payment-processed", {"gateway": "stripe"})
    # child span
    with tracer.start_as_current_span("validate-inventory"):
        validate(order)
```

### Go Example

```go
ctx, span := tracer.Start(ctx, "process-order",
    trace.WithAttributes(
        attribute.String("order.id", orderID),
        attribute.Float64("order.total", 99.95),
    ),
)
defer span.End()
```

### Span Links

Use links to associate spans across independent traces (e.g., a batch job consuming multiple queue messages):

```python
link = trace.Link(producer_span_context, attributes={"source": "queue"})
with tracer.start_as_current_span("batch-process", links=[link]):
    process_batch()
```

### Recording Errors

```python
try:
    do_work()
except Exception as e:
    span.set_status(trace.StatusCode.ERROR, str(e))
    span.record_exception(e)
    raise
```

### Rules

- Name spans after the operation, not the function: `"HTTP GET /users/:id"`, not `"handleRequest"`.
- Keep attribute cardinality bounded — never use user IDs, request bodies, or UUIDs as attribute values at high volume.
- Set span status to `ERROR` only on unhandled/unexpected failures, not on expected business errors (e.g., 404).

---

## Context Propagation

Context propagation stitches spans across service boundaries into a single trace.

### W3C TraceContext (Default)

OTel uses W3C TraceContext by default. The `traceparent` header carries trace ID, span ID, and sampling flag:

```
traceparent: 00-4bf92f3577b86cd5014ba7e5f7e3e2d0-00f067aa0ba902b7-01
```

### Baggage

Propagate key-value pairs across service boundaries for cross-cutting concerns:

```python
from opentelemetry import baggage, context

ctx = baggage.set_baggage("tenant.id", "acme-corp")
token = context.attach(ctx)
# downstream services can read baggage.get_baggage("tenant.id")
context.detach(token)
```

### Propagator Configuration

```python
from opentelemetry.propagators.composite import CompositeTextMapPropagator
from opentelemetry.propagators.b3 import B3MultiFormat

# Support both W3C and B3 for mixed ecosystems
propagator = CompositeTextMapPropagator([
    TraceContextTextMapPropagator(),
    B3MultiFormat(),
])
set_global_textmap(propagator)
```

### Async and Message Queues

Inject context into message headers when producing; extract when consuming:

```python
from opentelemetry.propagate import inject, extract

# Producer
headers = {}
inject(headers)
publish(message, headers=headers)

# Consumer
ctx = extract(carrier=message.headers)
with tracer.start_as_current_span("process-message", context=ctx):
    handle(message)
```

### Pitfall

Missing context propagation is the #1 cause of broken traces. Always propagate context across HTTP, gRPC, message queues, and thread/coroutine boundaries.

---

## Metrics API

### Instrument Types

| Instrument | Use Case | Example |
|---|---|---|
| Counter | Monotonically increasing values | Requests served, bytes sent |
| UpDownCounter | Values that go up and down | Active connections, queue depth |
| Histogram | Distribution of values | Request latency, payload size |
| Gauge | Point-in-time measurement | CPU usage, temperature |

### Python Example

```python
from opentelemetry import metrics

meter = metrics.get_meter("com.example.api", "1.0.0")

request_counter = meter.create_counter(
    "http.server.request.count",
    unit="1",
    description="Total HTTP requests",
)

latency_histogram = meter.create_histogram(
    "http.server.request.duration",
    unit="ms",
    description="Request latency",
)

request_counter.add(1, {"http.method": "GET", "http.route": "/users"})
latency_histogram.record(42.5, {"http.method": "GET", "http.route": "/users"})
```

### Views

Use views to customize aggregation, rename metrics, or drop unwanted attributes:

```python
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.view import View, ExplicitBucketHistogramAggregation

view = View(
    instrument_name="http.server.request.duration",
    aggregation=ExplicitBucketHistogramAggregation(
        boundaries=[5, 10, 25, 50, 100, 250, 500, 1000]
    ),
)
provider = MeterProvider(views=[view])
```

---

## Collector Configuration

### Full Example

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  prometheus:
    config:
      scrape_configs:
        - job_name: "app-metrics"
          scrape_interval: 15s
          static_configs:
            - targets: ["app:9090"]

processors:
  batch:
    send_batch_size: 1024
    timeout: 5s
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  attributes:
    actions:
      - key: environment
        value: production
        action: upsert
  filter:
    traces:
      span:
        - 'attributes["http.route"] == "/healthz"'

exporters:
  otlp:
    endpoint: tempo:4317
    tls:
      insecure: false
      cert_file: /certs/client.crt
      key_file: /certs/client.key
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true
  prometheusremotewrite:
    endpoint: http://prometheus:9090/api/v1/write

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679

service:
  extensions: [health_check, zpages]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp, otlp/jaeger]
    metrics:
      receivers: [otlp, prometheus]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, attributes, batch]
      exporters: [otlp]
```

### Processor Order

Place processors in this order: `memory_limiter` → `filter` → `attributes` → `batch`. The `memory_limiter` must come first to prevent OOM. The `batch` processor must come last to group data for efficient export.

### Deployment Patterns

- **Agent mode** — deploy as sidecar/DaemonSet alongside each app. Low latency, local processing.
- **Gateway mode** — centralized Collector behind a load balancer. Use for tail sampling, cross-service aggregation, and routing.
- **Layered** — agents forward to gateways. Agents handle buffering; gateways handle sampling and fan-out.

### Operational Rules

- Validate config before deploy: `otelcol validate --config=config.yaml`.
- Never run the Collector as root.
- Store TLS certs and credentials in secret stores, not in config YAML.
- Monitor Collector health via the `health_check` extension and internal metrics.

---

## Sampling Strategies

### Head-Based Sampling

Decision made at trace creation. All downstream services honor the decision.

```python
from opentelemetry.sdk.trace.sampling import TraceIdRatioBased, ParentBased

# Sample 10% of new traces; follow parent decision for child spans
sampler = ParentBased(root=TraceIdRatioBased(0.1))
```

Use when: cost control matters and you accept uniform random trace loss.

### Tail-Based Sampling

Decision made after collecting all spans in a trace. Configure in the Collector:

```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    policies:
      - name: errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow-requests
        type: latency
        latency: { threshold_ms: 2000 }
      - name: baseline
        type: probabilistic
        probabilistic: { sampling_percentage: 5 }
```

Use when: you must capture all errors and outliers. Requires a gateway Collector with sufficient memory.

### Combined Strategy

Use head-based sampling at 100% (keep all) in the SDK, then apply tail-based sampling in a gateway Collector. This ensures complete traces reach the Collector before filtering.

---

## Resource Attributes and Semantic Conventions

### Required Resource Attributes

Set these on every service:

```bash
export OTEL_RESOURCE_ATTRIBUTES="service.name=orders-api,service.version=2.3.1,deployment.environment=production"
```

| Attribute | Purpose |
|---|---|
| `service.name` | Identifies the service (required) |
| `service.version` | Enables version-aware debugging |
| `deployment.environment` | Separates prod/staging/dev |
| `service.namespace` | Groups related services |
| `host.name` | Identifies the host |

### Semantic Conventions for Spans

Follow OTel semantic conventions for consistent querying across services:

- **HTTP**: `http.request.method`, `http.route`, `http.response.status_code`, `url.full`
- **Database**: `db.system`, `db.namespace`, `db.operation.name`, `db.query.text`
- **Messaging**: `messaging.system`, `messaging.operation.type`, `messaging.destination.name`
- **RPC**: `rpc.system`, `rpc.service`, `rpc.method`

### Span Naming

- Use `<OPERATION> <TARGET>` format: `GET /users/:id`, `SELECT orders`, `publish notifications`.
- Never include variable data (IDs, timestamps) in span names — use attributes instead.
- Keep span names low cardinality (<100 unique names per service).

---

## Best Practices

### Attribute Cardinality

- Bound attribute values. Never use unbounded values (UUIDs, emails, full URLs with query params) as span or metric attributes.
- High-cardinality metric attributes cause memory explosion in backends. Cap at <20 unique values per attribute for metrics.
- Use `filter` or `attributes` processors in the Collector to strip or hash sensitive/high-cardinality fields.

### Instrumentation Hygiene

- Initialize SDK once at startup. Never create multiple `TracerProvider` or `MeterProvider` instances.
- Always call `span.End()` (Go) or use context managers (Python `with` blocks) to avoid leaked spans.
- Flush telemetry on shutdown: call `provider.shutdown()` or register shutdown hooks.
- Use `OTEL_LOG_LEVEL=debug` to diagnose missing telemetry during development.

### Common Pitfalls

| Pitfall | Consequence | Fix |
|---|---|---|
| Missing context propagation | Broken traces, orphan spans | Inject/extract context at every service boundary |
| Unbounded attributes | Backend memory explosion | Limit cardinality; use views to drop attributes |
| SDK init after library import | Missing startup spans | Move SDK init to top of entrypoint |
| No `batch` processor in Collector | Poor export performance | Always include `batch` as last processor |
| Sampling in SDK + Collector | Double sampling, lost data | Sample at one layer only, or use 100% SDK + tail at Collector |
| Span names with IDs | Unusable trace search | Use parameterized routes: `/users/:id` not `/users/12345` |
| No `memory_limiter` | Collector OOM under load | Always configure `memory_limiter` first in processor chain |
| Exporting directly to backend | Tight coupling, no retry | Route through Collector |

### Environment Variables Reference

| Variable | Purpose |
|---|---|
| `OTEL_SERVICE_NAME` | Service name (overrides resource attribute) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector endpoint |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` or `http/protobuf` |
| `OTEL_TRACES_SAMPLER` | Sampler type (`parentbased_traceidratio`) |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument (e.g., `0.1`) |
| `OTEL_PROPAGATORS` | Propagator list (`tracecontext,baggage`) |
| `OTEL_RESOURCE_ATTRIBUTES` | Comma-separated `key=value` pairs |
| `OTEL_LOG_LEVEL` | SDK log level (`debug`, `info`, `warn`, `error`) |

<!-- tested: pass -->
