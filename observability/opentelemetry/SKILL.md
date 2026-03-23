---
name: opentelemetry
description: |
  USE when: code imports opentelemetry, @opentelemetry/*, go.opentelemetry.io/otel, or io.opentelemetry; user asks about distributed tracing, spans, trace context, OTLP, OTel Collector, telemetry pipelines, auto-instrumentation, W3C traceparent, span processors, metric counters/histograms/gauges, log bridge API, context propagation, baggage, sampling strategies, or exporter configuration for Jaeger/Prometheus/Zipkin/Tempo/Honeycomb/Datadog.
  DO NOT USE when: user asks about application-level logging frameworks only (log4j, winston, pino) without OTel integration, APM-vendor-specific SDKs (Datadog dd-trace, New Relic agent) without OTel, or browser-only analytics/RUM unrelated to OpenTelemetry.
---

# OpenTelemetry Instrumentation Guide

## Architecture

OpenTelemetry separates concerns into three layers:

- **API**: Vendor-neutral interfaces for instrumenting code. Libraries depend ONLY on the API. Never import SDK packages in library code.
- **SDK**: Implements the API. Configures span processors, metric readers, samplers, exporters. App owners configure the SDK at startup.
- **Collector**: Standalone binary that receives, processes, and exports telemetry. Decouples apps from backends.
- **OTLP (OpenTelemetry Protocol)**: Wire protocol for all three signals. Supports gRPC (port 4317) and HTTP/protobuf (port 4318).

Data flow: `[App] → [API] → [SDK] → [Collector] → [Backend]`

## Three Signals

### Traces

Traces represent end-to-end request paths through distributed systems.

- **Span**: Unit of work with name, start/end time, attributes, events, links, status.
- **SpanContext**: Immutable context (trace ID, span ID, trace flags) propagated across boundaries.
- **SpanKind**: CLIENT, SERVER, PRODUCER, CONSUMER, INTERNAL.
- **Span Status**: Unset, Ok, Error. Set Error on failures with descriptive message.
- **Span Events**: Timestamped annotations within a span (e.g., exception events).
- **Span Links**: Connect causally related traces (e.g., batch processing linking to triggering spans).

### Metrics

- **Counter**: Monotonically increasing value (e.g., requests_total). Use `add()`, never negative.
- **UpDownCounter**: Value that increases and decreases (e.g., active_connections).
- **Histogram**: Distribution of values (e.g., request_duration_ms). Records value, SDK computes buckets.
- **Gauge**: Point-in-time measurement (e.g., cpu_temperature). Use `record()`.
- **Views**: SDK-side configuration to customize aggregation, rename instruments, drop attributes.
- **Aggregation**: Sum (counters), LastValue (gauges), ExplicitBucketHistogram (histograms).

### Logs

- **Log Bridge API**: Connect existing logging frameworks (log4j, slog, winston) to OTel pipeline. Do NOT replace existing loggers—bridge them.
- Logs are correlated with traces via trace context (trace_id, span_id injected automatically when bridge is configured).
- Use structured logging. Attach attributes as key-value pairs, not string interpolation.

## Context Propagation

Propagators serialize/deserialize context across process boundaries via headers.

**W3C TraceContext** (default, recommended):
```
traceparent: 00-<trace-id>-<span-id>-<trace-flags>
tracestate: vendor1=value1,vendor2=value2
```

**B3** (Zipkin-compatible):
```
X-B3-TraceId: <trace-id>
X-B3-SpanId: <span-id>
X-B3-Sampled: 1
```

Set propagators: `OTEL_PROPAGATORS=tracecontext,baggage` (default) or `b3,b3multi`.

**Baggage**: Key-value pairs propagated with context across services. Use for cross-cutting concerns (tenant ID, feature flags). Baggage is NOT automatically added to span attributes—read explicitly. Keep baggage small; it travels with every request.

## Sampling Strategies

Configure via `OTEL_TRACES_SAMPLER` env var:

| Sampler | Env Value | Behavior |
|---|---|---|
| AlwaysOn | `always_on` | Record all spans. Dev/debug only. |
| AlwaysOff | `always_off` | Drop all spans. |
| TraceIdRatio | `traceidratio` | Sample N% of traces. Set ratio with `OTEL_TRACES_SAMPLER_ARG=0.1` for 10%. |
| ParentBased+AlwaysOn | `parentbased_always_on` | Default. Respect parent decision, sample root spans. |
| ParentBased+TraceIdRatio | `parentbased_traceidratio` | Respect parent, ratio-sample root spans. Production recommended. |

Always use ParentBased wrappers in production to maintain trace completeness.

## Resource Attributes & Semantic Conventions

Set via code or `OTEL_RESOURCE_ATTRIBUTES` env var:

```bash
export OTEL_RESOURCE_ATTRIBUTES="service.name=payment-api,service.version=2.1.0,deployment.environment=production"
```

Required attributes:
- `service.name`: Logical service name. MUST set this.
- `service.version`: Deployed version.
- `deployment.environment`: prod, staging, dev.

Common attributes: `host.name`, `cloud.provider`, `cloud.region`, `k8s.namespace.name`, `k8s.pod.name`, `container.id`.

Use semantic conventions for span/metric attributes: `http.request.method`, `http.response.status_code`, `url.full`, `db.system`, `db.statement`, `rpc.system`, `messaging.system`.

## Environment Variables

| Variable | Purpose | Example |
|---|---|---|
| `OTEL_SERVICE_NAME` | Service name (shortcut) | `my-api` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector endpoint | `http://localhost:4317` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | Protocol | `grpc` or `http/protobuf` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Auth headers | `x-api-key=abc123` |
| `OTEL_TRACES_SAMPLER` | Sampler type | `parentbased_traceidratio` |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument | `0.1` |
| `OTEL_PROPAGATORS` | Propagation formats | `tracecontext,baggage` |
| `OTEL_LOGS_EXPORTER` | Log exporter | `otlp` or `none` |
| `OTEL_METRICS_EXPORTER` | Metrics exporter | `otlp` or `prometheus` |
| `OTEL_TRACES_EXPORTER` | Traces exporter | `otlp` or `jaeger` |
| `OTEL_EXPORTER_OTLP_COMPRESSION` | Compression | `gzip` |

Per-signal endpoint override: `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`.

## Node.js / TypeScript Setup

Install:
```bash
npm install @opentelemetry/sdk-node @opentelemetry/api \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-http \
  @opentelemetry/exporter-metrics-otlp-http \
  @opentelemetry/sdk-metrics
```

Create `instrumentation.ts` — MUST execute before app code:
```typescript
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-http';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { Resource } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';

const sdk = new NodeSDK({
  resource: new Resource({
    [ATTR_SERVICE_NAME]: 'my-service',
    [ATTR_SERVICE_VERSION]: '1.0.0',
  }),
  traceExporter: new OTLPTraceExporter(),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter(),
    exportIntervalMillis: 60_000,
  }),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();
process.on('SIGTERM', () => sdk.shutdown());
```

Run: `node --require ./dist/instrumentation.js ./dist/app.js`

Manual span creation:
```typescript
import { trace, SpanStatusCode } from '@opentelemetry/api';

const tracer = trace.getTracer('my-service', '1.0.0');

async function processOrder(orderId: string) {
  return tracer.startActiveSpan('processOrder', async (span) => {
    try {
      span.setAttribute('order.id', orderId);
      const result = await doWork();
      span.setStatus({ code: SpanStatusCode.OK });
      return result;
    } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: (err as Error).message });
      span.recordException(err as Error);
      throw err;
    } finally {
      span.end();
    }
  });
}
```

## Python Setup

Install:
```bash
pip install opentelemetry-distro[otlp]
opentelemetry-bootstrap -a install  # auto-detect and install instrumentations
```

Run with auto-instrumentation (zero code changes):
```bash
opentelemetry-instrument \
  --service_name my-service \
  --exporter_otlp_endpoint http://localhost:4317 \
  python app.py
```

Manual instrumentation:
```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource

resource = Resource.create({"service.name": "my-service"})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)

tracer = trace.get_tracer("my-service")

with tracer.start_as_current_span("process-payment") as span:
    span.set_attribute("payment.amount", 99.99)
    # business logic
```

## Go Setup

Install:
```bash
go get go.opentelemetry.io/otel
go get go.opentelemetry.io/otel/sdk
go get go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp
go get go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
```

Initialize:
```go
package main

import (
    "context"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

func initTracer(ctx context.Context) (*sdktrace.TracerProvider, error) {
    exp, err := otlptracehttp.New(ctx)
    if err != nil {
        return nil, err
    }
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exp),
        sdktrace.WithResource(resource.NewWithAttributes(
            semconv.SchemaURL,
            semconv.ServiceNameKey.String("my-service"),
        )),
    )
    otel.SetTracerProvider(tp)
    return tp, nil
}
```

Create spans:
```go
tracer := otel.Tracer("my-service")
ctx, span := tracer.Start(ctx, "processOrder")
defer span.End()
span.SetAttributes(attribute.String("order.id", orderID))
```

Instrument HTTP handlers: wrap with `otelhttp.NewHandler(handler, "route-name")`.

## Java Setup

**Java Agent (auto-instrumentation, recommended start)**:
```bash
# Download agent jar from GitHub releases
java -javaagent:opentelemetry-javaagent.jar \
  -Dotel.service.name=my-service \
  -Dotel.exporter.otlp.endpoint=http://localhost:4317 \
  -jar myapp.jar
```

The agent auto-instruments Servlet, Spring, JDBC, gRPC, Kafka, and 100+ libraries. Zero code changes.

**Programmatic (manual)**:
```java
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.api.trace.Span;

Tracer tracer = GlobalOpenTelemetry.getTracer("my-service");
Span span = tracer.spanBuilder("processOrder").startSpan();
try (var scope = span.makeCurrent()) {
    span.setAttribute("order.id", orderId);
    // business logic
} catch (Exception e) {
    span.setStatus(StatusCode.ERROR, e.getMessage());
    span.recordException(e);
    throw e;
} finally {
    span.end();
}
```

## OTel Collector

### Configuration Structure

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    send_batch_size: 8192
    timeout: 5s
  memory_limiter:
    check_interval: 1s
    limit_mib: 2048
    spike_limit_mib: 512
  attributes:
    actions:
      - key: environment
        value: production
        action: upsert

exporters:
  otlp:
    endpoint: tempo.example.com:4317
    tls:
      insecure: false
  prometheus:
    endpoint: 0.0.0.0:8889
  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp]
```

### Pipeline Components

**Receivers**: Ingest data. `otlp` (gRPC/HTTP), `prometheus` (scrape), `jaeger`, `zipkin`, `filelog`, `hostmetrics`.

**Processors**: Transform data. Always include `memory_limiter` first, `batch` last.
- `batch`: Buffer and send in batches. Reduces network calls.
- `memory_limiter`: Prevent OOM. MUST be first processor.
- `attributes`: Add/remove/update attributes.
- `filter`: Drop unwanted telemetry by attribute match.
- `tail_sampling`: Make sampling decisions after seeing complete traces (Collector only).
- `resource`: Add resource attributes.

**Exporters**: Send data. `otlp` (to another collector or backend), `prometheus`, `debug` (stdout), `zipkin`.

### Deployment Patterns

| Pattern | Use Case | Pros |
|---|---|---|
| **Sidecar** | Per-pod in Kubernetes | Low latency, isolated failure blast radius |
| **Agent (DaemonSet)** | Per-node | Lower resource overhead than sidecar |
| **Gateway** | Centralized | Single config, cross-cutting processing, tail sampling |

Production pattern: Agent on each node → Gateway cluster → Backend. Use `loadbalancing` exporter on agents to distribute traces to gateways by trace ID for tail sampling.

## Exporters & Backend Integration

| Backend | Exporter | Notes |
|---|---|---|
| Grafana Tempo | `otlp` | Native OTLP ingestion. Pair with Grafana for visualization. |
| Jaeger | `otlp` | Jaeger natively accepts OTLP since v1.35. |
| Prometheus | `prometheus` exporter or `prometheusremotewrite` | For metrics. Collector exposes scrape endpoint. |
| Zipkin | `zipkin` | Legacy format support. |
| Honeycomb | `otlp` with `OTEL_EXPORTER_OTLP_HEADERS=x-honeycomb-team=<key>` | Direct OTLP ingestion. |
| Datadog | `datadog` exporter (contrib) | Use `otel-collector-contrib` image. |

## Auto-Instrumentation vs Manual

**Auto-instrumentation**: Instruments known libraries (HTTP, DB, messaging) with zero code changes. Use as baseline. Provides standard spans for framework operations.

**Manual instrumentation**: Add custom spans for business logic, custom attributes, events. Layer on top of auto-instrumentation. Always prefer `startActiveSpan` (JS) / `start_as_current_span` (Python) / `tracer.Start(ctx, ...)` (Go) to maintain context hierarchy.

Combine both: auto-instrumentation for infrastructure, manual for business domain.

## Common Pitfalls

1. **Missing `span.end()`**: Spans never export. Always end spans in `finally` blocks.
2. **Not propagating context**: Pass `ctx`/`context` through function calls. Without it, child spans become orphaned root spans.
3. **High-cardinality attributes**: Never use user IDs, request IDs, or unbounded values as metric attributes. Traces allow high cardinality; metrics do not.
4. **SDK in library code**: Libraries MUST depend only on the API package, never the SDK. App owners configure the SDK.
5. **Forgetting `memory_limiter`**: Collector OOMs under load. Always add as first processor.
6. **Synchronous exporters**: Use `BatchSpanProcessor`, never `SimpleSpanProcessor` in production. Simple blocks on each span.
7. **Not setting `service.name`**: Telemetry groups under "unknown_service". Always set it.
8. **Instrumenting before SDK init**: In Node.js, load instrumentation file BEFORE app code via `--require` or top-level import.
9. **Baggage leakage**: Baggage propagates to ALL downstream services. Never put sensitive data in baggage.
10. **Ignoring graceful shutdown**: Call `sdk.shutdown()` / `tp.Shutdown(ctx)` on SIGTERM to flush pending telemetry.

## Performance Considerations

- Use `BatchSpanProcessor` with tuned `maxExportBatchSize` (default 512) and `scheduledDelayMillis` (default 5000).
- Set `OTEL_EXPORTER_OTLP_COMPRESSION=gzip` to reduce network bandwidth.
- Use `ParentBased(TraceIdRatio)` sampling in production. Start at 10% (`0.1`) and adjust.
- Collector `batch` processor: set `send_batch_size: 8192`, `timeout: 5s` for throughput.
- Drop unused attributes in Collector with `attributes` processor to reduce storage.
- Use `filter` processor to drop health-check and readiness-probe spans.

## Examples

### Input: "Add tracing to my Express app"

```typescript
// instrumentation.ts — run with: node --require ./instrumentation.js app.js
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter(),
  instrumentations: [getNodeAutoInstrumentations()],
});
sdk.start();
```

Output: Express HTTP spans auto-created for every request with `http.method`, `http.route`, `http.status_code` attributes. Child spans for outgoing HTTP calls, DB queries auto-linked.

### Input: "Set up tail sampling to keep error traces and sample 10% of success"

See [collector-recipes.md](references/collector-recipes.md#tail-sampling-processor) for complete gateway config. Minimal policy:

```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    policies:
      - name: errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow-requests
        type: latency
        latency: { threshold_ms: 5000 }
      - name: percentage
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }
```

## References

In-depth guides in `references/`:

| File | Topics |
|---|---|
| [advanced-patterns.md](references/advanced-patterns.md) | Custom span processors, batch vs simple exporters, tail-based sampling architecture, span links & events, metric views & aggregation, exemplars, log correlation, custom propagators, resource detection, multi-signal correlation, instrumentation libraries deep dive |
| [troubleshooting.md](references/troubleshooting.md) | Missing spans (propagation, sampling, unended spans), high cardinality metrics, Collector pipeline debugging (zpages, debug exporter, internal metrics), memory issues, gRPC vs HTTP transport, SDK init order, auto-instrumentation failures, context loss in async code |
| [collector-recipes.md](references/collector-recipes.md) | Production Collector configs: span filtering by attribute, tail sampling processor (complete gateway config), routing to multiple backends, transforming metrics, filelog receiver for K8s logs, K8s metadata enrichment (k8sattributes), health check extension, load balancing exporter, Collector scaling patterns (agent + gateway, sidecar, HPA) |

## Scripts

Executable helpers in `scripts/`:

| Script | Purpose | Usage |
|---|---|---|
| [setup-local-stack.sh](scripts/setup-local-stack.sh) | Stand up a full local OTel stack (Collector + Jaeger + Prometheus + Grafana) via Docker Compose | `./scripts/setup-local-stack.sh up` |
| [instrument-node-app.sh](scripts/instrument-node-app.sh) | Add OTel auto-instrumentation to an existing Node.js project — installs packages, creates bootstrap file | `./scripts/instrument-node-app.sh --project-dir ./my-app --typescript` |
| [validate-collector-config.sh](scripts/validate-collector-config.sh) | Multi-level Collector config validation: YAML syntax, required sections, pipeline reference consistency, best practices, native `otelcol validate` | `./scripts/validate-collector-config.sh config.yaml` |

## Assets

Ready-to-use templates and configs in `assets/`:

| File | Description |
|---|---|
| [collector-config.yaml](assets/collector-config.yaml) | Production-ready Collector config with OTLP receivers, memory limiter, batch processor, multiple exporters (OTLP, Prometheus), health check, zpages, span filtering, attribute redaction |
| [docker-compose.yml](assets/docker-compose.yml) | Full observability stack: Collector (contrib), Jaeger (with persistent storage), Prometheus, Grafana (with pre-provisioned datasources) |
| [node-tracing.ts](assets/node-tracing.ts) | Node.js/TypeScript tracing setup module with auto-instrumentation, all three signals, resource detectors, graceful shutdown, health check filtering |
| [otel-env.sh](assets/otel-env.sh) | Environment variables template for OTel SDK — `source` before running your app, with development/production presets |
