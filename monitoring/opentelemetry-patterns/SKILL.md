---
name: opentelemetry-patterns
description: >
  Comprehensive guide for implementing OpenTelemetry observability across traces, metrics,
  and logs — from SDK setup to production Collector pipelines.
  USE when: setting up OpenTelemetry SDKs (Node.js, Python, Go, Java), implementing
  distributed tracing, collecting metrics with OTel API, correlating logs with trace
  context, configuring OTel Collector pipelines, instrumenting spans/attributes/events,
  propagating context (W3C TraceContext, Baggage), configuring exporters (OTLP, Jaeger,
  Zipkin, Prometheus), defining sampling strategies (head-based, tail-based), applying
  semantic conventions, building observability pipelines, writing custom span processors,
  creating metric views, using exemplars for metric-trace correlation, deploying Collector
  in agent/gateway patterns, troubleshooting missing spans or context propagation issues,
  managing metric cardinality, writing custom exporters, using OTTL transforms, configuring
  connectors (spanmetrics, routing), setting up resource detectors.
  DO NOT USE when: configuring Datadog or New Relic proprietary agents without OTel,
  setting up Prometheus-only monitoring without OpenTelemetry, implementing application
  logging without tracing context, configuring vendor-specific APM agents (AppDynamics,
  Dynatrace native), writing StatsD/Graphite metrics without OTel.
---

# OpenTelemetry Patterns

## Core Signals

- **Traces**: Distributed request flows as spans in a DAG. Spans have: traceId, spanId, parentSpanId, name, kind, attributes, events, links, status.
- **Metrics**: Aggregated numerical measurements — Counter (monotonic), Histogram (distributions), Gauge (point-in-time), UpDownCounter (bidirectional).
- **Logs**: Timestamped records correlated via trace_id/span_id fields.
- All signals share: Resource identity, Context propagation, OTLP export.

## SDK Setup — Node.js

```javascript
// tracing.js — load via: node --require ./tracing.js app.js
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-grpc');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { Resource } = require('@opentelemetry/resources');
const { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } = require('@opentelemetry/semantic-conventions');
const sdk = new NodeSDK({
  resource: new Resource({
    [ATTR_SERVICE_NAME]: 'order-service',
    [ATTR_SERVICE_VERSION]: '1.4.0',
    'deployment.environment': 'production',
  }),
  traceExporter: new OTLPTraceExporter({ url: 'http://otel-collector:4317' }),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter({ url: 'http://otel-collector:4317' }),
    exportIntervalMillis: 15000,
  }),
  instrumentations: [getNodeAutoInstrumentations({
    '@opentelemetry/instrumentation-fs': { enabled: false },
  })],
});
sdk.start();
process.on('SIGTERM', () => sdk.shutdown());
```

## SDK Setup — Python

```python
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
resource = Resource.create({SERVICE_NAME: "payment-service", "deployment.environment": "production"})
tp = TracerProvider(resource=resource)
tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint="http://otel-collector:4317", insecure=True)))
trace.set_tracer_provider(tp)
reader = PeriodicExportingMetricReader(OTLPMetricExporter(endpoint="http://otel-collector:4317", insecure=True))
metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[reader]))
```

Auto-instrument: `opentelemetry-instrument --service_name payment-service python app.py`

## SDK Setup — Go

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)
func initTracer(ctx context.Context) (*sdktrace.TracerProvider, error) {
    exp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpoint("otel-collector:4317"), otlptracegrpc.WithInsecure())
    if err != nil { return nil, err }
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exp),
        sdktrace.WithResource(resource.NewWithAttributes(semconv.SchemaURL, semconv.ServiceName("inventory-svc"))),
    )
    otel.SetTracerProvider(tp)
    return tp, nil
}
```

## SDK Setup — Java (Spring Boot)

```properties
# application.properties — with opentelemetry-spring-boot-starter dependency
otel.service.name=user-service
otel.exporter.otlp.endpoint=http://otel-collector:4317
otel.exporter.otlp.protocol=grpc
```

Agent alternative: `java -javaagent:opentelemetry-javaagent.jar -jar app.jar`

## Manual Instrumentation — Spans

```python
tracer = trace.get_tracer("order.processor", "1.0.0")
with tracer.start_as_current_span("process_order") as span:
    span.set_attribute("order.id", order_id)
    span.set_attribute("order.total", 99.95)
    span.add_event("inventory_checked", {"available": True, "warehouse": "us-east-1"})
    result = process(order)
    span.set_attribute("order.status", result.status)
```

```javascript
const tracer = opentelemetry.trace.getTracer('order.processor', '1.0.0');
async function processOrder(order) {
  return tracer.startActiveSpan('process_order', async (span) => {
    try {
      span.setAttribute('order.id', order.id);
      const result = await execute(order);
      span.setStatus({ code: SpanStatusCode.OK });
      return result;
    } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
      throw err;
    } finally { span.end(); }
  });
}
```

### Span Links — connect causally related traces (batch job → trigger)

```python
from opentelemetry.trace import Link
with tracer.start_as_current_span("batch_process", links=[
    Link(trigger_span_context, attributes={"link.type": "trigger"})
]) as span:
    process_batch()
```

## Context Propagation

W3C TraceContext headers (default, auto-propagated):
```
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
tracestate: vendor1=opaque_value
```

### Manual Inject/Extract

```python
from opentelemetry import propagate
headers = {}
propagate.inject(headers)  # inject into outgoing request
ctx = propagate.extract(carrier=request.headers)  # extract from incoming
with tracer.start_as_current_span("handle", context=ctx) as span:
    process_request()
```

### Baggage — Cross-Service Key-Value Context

```python
from opentelemetry import baggage, context
ctx = baggage.set_baggage("tenant.id", "acme-corp")
token = context.attach(ctx)
# Downstream: tenant = baggage.get_baggage("tenant.id")
```

Never put PII/secrets in baggage. Configure: `OTEL_PROPAGATORS=tracecontext,baggage`

## Metrics API

```python
meter = metrics.get_meter("order.metrics", "1.0.0")
# Counter — monotonically increasing
request_counter = meter.create_counter("http.server.request.count", unit="1")
request_counter.add(1, {"http.method": "POST", "http.route": "/orders"})
# Histogram — distributions (latency, sizes)
duration_hist = meter.create_histogram("http.server.duration", unit="ms")
duration_hist.record(45.2, {"http.method": "GET", "http.status_code": 200})
# UpDownCounter — bidirectional (active connections)
active = meter.create_up_down_counter("http.server.active_requests", unit="1")
active.add(1)   # request start
active.add(-1)  # request end
# Observable Gauge — async callback
def cpu_cb(options):
    yield metrics.Observation(psutil.cpu_percent(), {"host.name": hostname})
meter.create_observable_gauge("system.cpu.utilization", callbacks=[cpu_cb], unit="1")
```

**Cardinality rules**: Use http.method, http.status_code, http.route. Never use user.id, request.id — unbounded cardinality explodes storage. Keep < 2000 attribute combos per instrument.

## Exporters

| Exporter | Protocol | Signals | Use Case |
|----------|----------|---------|----------|
| OTLP/gRPC | gRPC | All | Default, highest throughput |
| OTLP/HTTP | HTTP/protobuf | All | Firewall-friendly |
| Prometheus | HTTP pull | Metrics | Prometheus scrape |
| Console | stdout | All | Dev/debug only |

Prefer OTLP to Collector, not directly to backends.

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4317"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
export OTEL_EXPORTER_OTLP_HEADERS="x-api-key=secret"
export OTEL_EXPORTER_OTLP_COMPRESSION="gzip"
```

## OTel Collector — Production Config

```yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }
processors:
  memory_limiter:
    check_interval: 5s
    limit_mib: 4096
    spike_limit_mib: 512
  batch:
    timeout: 5s
    send_batch_size: 8192
  attributes/sanitize:
    actions:
      - { key: db.statement, action: hash }
      - { key: http.request.header.authorization, action: delete }
  filter/health:
    traces:
      span:
        - 'attributes["http.route"] == "/healthz"'
  tail_sampling:
    decision_wait: 10s
    policies:
      - { name: errors, type: status_code, status_code: { status_codes: [ERROR] } }
      - { name: slow, type: latency, latency: { threshold_ms: 2000 } }
      - { name: baseline, type: probabilistic, probabilistic: { sampling_percentage: 10 } }
exporters:
  otlp/traces: { endpoint: "tempo:4317", tls: { insecure: true } }
  prometheusremotewrite: { endpoint: "http://mimir:9009/api/v1/push" }
  otlp/logs: { endpoint: "loki:3100" }
service:
  telemetry:
    logs: { level: info }
    metrics: { address: 0.0.0.0:8888 }
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, filter/health, tail_sampling, attributes/sanitize, batch]
      exporters: [otlp/traces]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/logs]
```

**Processor ordering**: memory_limiter → filter → sampling → transform → batch (always last).

**Agent vs Gateway**: Agent (DaemonSet) for local collection → Gateway (Deployment) for tail sampling, routing → Backends.

## Sampling Strategies

### Head-Based (SDK-side)

```python
from opentelemetry.sdk.trace.sampling import ParentBasedTraceIdRatio
tp = TracerProvider(sampler=ParentBasedTraceIdRatio(0.1), resource=resource)  # 10% new traces
```

```bash
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1
```

### Tail-Based (Collector-side)

Use `tail_sampling` processor (see Collector config above). Combine policies: status_code (errors), latency (slow), probabilistic (baseline), string_attribute (match values).

| Scenario | Strategy | Rationale |
|----------|----------|-----------|
| High-volume API | Head 5-10% + tail errors | Cost control + error coverage |
| Payment/audit | Head 100% | Full compliance trail |
| Development | AlwaysOn | Full visibility |
| Batch jobs | ParentBased | Follow upstream decision |

## Semantic Conventions

```python
# HTTP: http.request.method, http.response.status_code, url.full, http.route
# DB:   db.system, db.statement, db.operation.name, db.namespace
# RPC:  rpc.system, rpc.service, rpc.method
# Messaging: messaging.system, messaging.operation.type, messaging.destination.name
span.set_attribute("http.request.method", "POST")
span.set_attribute("http.response.status_code", 201)
span.set_attribute("http.route", "/api/v1/orders")
```

Resource attributes: `OTEL_RESOURCE_ATTRIBUTES="service.name=order-svc,service.version=1.4.0,deployment.environment=production"`

Standard: service.name, service.version, service.namespace, deployment.environment, host.name, cloud.provider, cloud.region, k8s.pod.name, k8s.namespace.name.

## Log Correlation

```python
# Python — inject trace context into structured logs
import structlog
from opentelemetry import trace
def add_trace_context(logger, method_name, event_dict):
    ctx = trace.get_current_span().get_span_context()
    if ctx.is_valid:
        event_dict["trace_id"] = format(ctx.trace_id, "032x")
        event_dict["span_id"] = format(ctx.span_id, "016x")
    return event_dict
structlog.configure(processors=[add_trace_context, structlog.dev.ConsoleRenderer()])
```

```javascript
// Node.js — pino with trace context
const { trace } = require('@opentelemetry/api');
const logger = pino({ mixin() {
    const span = trace.getActiveSpan();
    if (!span) return {};
    const ctx = span.spanContext();
    return { trace_id: ctx.traceId, span_id: ctx.spanId };
}});
// Output: {"msg":"Order created","trace_id":"abc123...","span_id":"def456..."}
```

## Resource Detection

```javascript
const { detectResourcesSync } = require('@opentelemetry/resources');
const { awsEcsDetectorSync } = require('@opentelemetry/resource-detector-aws');
const resource = detectResourcesSync({ detectors: [awsEcsDetectorSync] });
// Detects: cloud.provider, cloud.platform, container.id, aws.ecs.task.arn
```

## Performance Rules

- Always use BatchSpanProcessor — never SimpleSpanProcessor in production
- Export interval: 15-30s for metrics; batch 8192 spans default
- Head-sample 5-20% for high-volume services
- Collector sizing: ~15k spans/sec per CPU core; scale horizontally
- gRPC is 2-3x more efficient than HTTP; use HTTP only when gRPC blocked
- Limit: 64-128 attributes/span, avoid high-cardinality attribute values

```bash
export OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT=64
export OTEL_BSP_MAX_QUEUE_SIZE=4096
export OTEL_BSP_MAX_EXPORT_BATCH_SIZE=512
export OTEL_BSP_SCHEDULE_DELAY=5000
```

## Troubleshooting

**No traces**: Enable `OTEL_LOG_LEVEL=debug` → use ConsoleSpanExporter → check `curl http://collector:4318/v1/traces` → verify SDK loads before app code → set `OTEL_TRACES_SAMPLER=always_on`.

**Context lost**: Check `OTEL_PROPAGATORS=tracecontext,baggage` → verify HTTP client instrumented → inspect `traceparent` header → for queues, serialize/rehydrate context explicitly.

**Collector OOM**: Add memory_limiter first in processor chain → reduce batch/tail_sampling buffers → filter noisy spans → use gateway pattern for tail sampling.

**Metrics missing**: Wait for export interval (default 60s) → verify MeterProvider set before instruments created → check cardinality limits → confirm exporter endpoint.

## Kubernetes Deployment

```yaml
# App pod env — point to node-local agent
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://$(HOST_IP):4317"
  - name: OTEL_SERVICE_NAME
    value: "order-service"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "k8s.namespace.name=$(K8S_NAMESPACE),k8s.pod.name=$(K8S_POD_NAME)"
  - name: HOST_IP
    valueFrom: { fieldRef: { fieldPath: status.hostIP } }
```

Deploy Collector as DaemonSet (agent) + Deployment (gateway). Apps → Agent (batch, head-sample) → Gateway (tail-sample, route) → Backends (Tempo, Mimir, Loki).

## Additional Resources

### Reference Documentation

Detailed deep-dives for advanced use cases:

- **[references/advanced-patterns.md](references/advanced-patterns.md)** — Custom span processors (enrichment, redaction, filtering), metric views (rename, bucket customization, cardinality control), exemplars (metric↔trace correlation), baggage propagation patterns, multi-signal correlation (resource, log, metric→trace), span links (batch, retry, async), tail-based sampling (composite policies, multi-layer architecture), resource detectors (AWS, GCP, Azure, custom), custom exporters (Python, Node.js), advanced context propagation (custom propagators, message queues), OTTL transforms, connectors (spanmetrics, count, routing).

- **[references/troubleshooting.md](references/troubleshooting.md)** — Systematic diagnosis for: missing spans (decision tree, debug logging, ConsoleSpanExporter), context propagation breaks (async code, message queues, proxies, gRPC), high cardinality issues (dangerous vs safe attributes, cardinality budgets, View fixes), memory leaks (unclosed spans, SimpleSpanProcessor, unbounded attributes), Collector pipeline debugging (internal metrics, zpages, pprof, debug exporter), exporter failures (connection, timeout, auth), SDK initialization ordering (Node.js, Python, Java gotchas), sampling confusion.

- **[references/collector-reference.md](references/collector-reference.md)** — OTel Collector deep-dive: receivers (OTLP, Jaeger, Prometheus, filelog, hostmetrics, Kafka), processors (batch, memory_limiter, filter, attributes, resource, tail_sampling, transform, k8sattributes, groupbytrace), exporters (OTLP, Prometheus, prometheusremotewrite, Loki, debug, file, loadbalancing), connectors (spanmetrics, count, routing, forward), extensions (health_check, pprof, zpages, basicauth, file_storage, bearertokenauth), deployment patterns (agent, gateway, sidecar, full architecture diagrams), distributions, configuration best practices.

### Scripts

Executable helper tools:

- **[scripts/setup-otel.sh](scripts/setup-otel.sh)** — Automated OTel SDK setup for Node.js or Python projects. Installs packages, creates tracing boilerplate, prints run instructions. Usage: `./scripts/setup-otel.sh [node|python] --service-name my-svc`

- **[scripts/collector-health.sh](scripts/collector-health.sh)** — Checks Collector health, receiver/processor/exporter metrics, queue status, resource usage. Supports `--json` output and `--watch` mode. Usage: `./scripts/collector-health.sh --host otel-collector`

### Templates

Ready-to-customize config files:

- **[assets/otel-collector-config.template.yaml](assets/otel-collector-config.template.yaml)** — Production Collector config: OTLP receiver, memory_limiter + filter + attributes + batch processors, spanmetrics connector, multi-backend exporters (OTLP, Prometheus remote write, Loki), health/pprof/zpages extensions. Includes commented-out sections for Prometheus scraping, host metrics, filelog, and tail sampling.

- **[assets/docker-compose.template.yml](assets/docker-compose.template.yml)** — Full observability stack: OTel Collector + Jaeger (traces UI) + Prometheus (metrics, exemplar-enabled) + Grafana (dashboards) + optional Loki (logs). Includes provisioning config snippets for Grafana datasources.

- **[assets/tracing-setup.template.ts](assets/tracing-setup.template.ts)** — TypeScript OTel SDK initialization boilerplate with custom span processor (sensitive data redaction), metric views (histogram buckets, cardinality control), auto-instrumentation config (health check filtering), graceful shutdown handling.