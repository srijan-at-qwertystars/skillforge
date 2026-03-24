# OpenTelemetry Advanced Patterns

> Dense reference for advanced OTel SDK and Collector patterns. Each section is self-contained with code examples.

## Table of Contents

- [Custom Span Processors](#custom-span-processors)
- [Metric Views](#metric-views)
- [Exemplars — Metric↔Trace Correlation](#exemplars)
- [Baggage Propagation](#baggage-propagation)
- [Multi-Signal Correlation](#multi-signal-correlation)
- [Span Links](#span-links)
- [Tail-Based Sampling with OTel Collector](#tail-based-sampling-with-otel-collector)
- [Resource Detectors](#resource-detectors)
- [Custom Exporters](#custom-exporters)
- [Advanced Context Propagation](#advanced-context-propagation)
- [OTTL (OpenTelemetry Transformation Language)](#ottl)
- [Connectors — Cross-Pipeline Signal Bridging](#connectors)

---

## Custom Span Processors

Span processors intercept spans between creation and export. Use them for enrichment, filtering, redaction, or custom routing.

### Node.js — Custom Processor

```javascript
const { SpanProcessor } = require('@opentelemetry/sdk-trace-base');

class RedactingSpanProcessor {
  onStart(span, parentContext) {
    // Enrich at span creation
    span.setAttribute('processor.version', '1.0.0');
  }

  onEnd(span) {
    // Redact sensitive attributes before export
    const attrs = span.attributes;
    if (attrs['db.statement']) {
      span.attributes['db.statement'] = '[REDACTED]';
    }
    if (attrs['http.request.header.authorization']) {
      delete span.attributes['http.request.header.authorization'];
    }
  }

  shutdown() { return Promise.resolve(); }
  forceFlush() { return Promise.resolve(); }
}

// Register with TracerProvider
const { NodeTracerProvider } = require('@opentelemetry/sdk-trace-node');
const provider = new NodeTracerProvider();
provider.addSpanProcessor(new RedactingSpanProcessor());
provider.addSpanProcessor(new BatchSpanProcessor(exporter)); // chain after
```

### Python — Custom Processor

```python
from opentelemetry.sdk.trace import SpanProcessor, ReadableSpan
from opentelemetry.context import Context

class TenantEnrichmentProcessor(SpanProcessor):
    """Copies baggage tenant.id into every span as an attribute."""

    def on_start(self, span, parent_context: Context = None):
        from opentelemetry import baggage
        tenant = baggage.get_baggage("tenant.id", parent_context)
        if tenant:
            span.set_attribute("tenant.id", tenant)

    def on_end(self, span: ReadableSpan):
        pass  # Read-only at this point

    def shutdown(self):
        pass

    def force_flush(self, timeout_millis=30000):
        return True
```

### Java — Custom Processor with Agent

```java
// Implement SpanProcessor interface
public class ComplianceProcessor implements SpanProcessor {
    @Override
    public void onStart(Context parentContext, ReadWriteSpan span) {
        span.setAttribute("compliance.checked", true);
    }

    @Override
    public boolean isStartRequired() { return true; }

    @Override
    public void onEnd(ReadableSpan span) {
        // Log spans with PII attributes for audit
        if (span.getAttribute(AttributeKey.stringKey("user.email")) != null) {
            auditLogger.log(span.getSpanContext().getTraceId());
        }
    }

    @Override
    public boolean isEndRequired() { return true; }
}
```

For the Java Agent, register via `AutoConfigurationCustomizerProvider` SPI with an extension JAR.

### Processor Chaining Order

```
SDK creates span
  → EnrichmentProcessor (add attributes)
    → RedactionProcessor (remove/hash sensitive data)
      → FilteringProcessor (drop noisy spans)
        → BatchSpanProcessor (batch + export)
```

**Rule**: Mutation processors before BatchSpanProcessor. BatchSpanProcessor should always be last.

---

## Metric Views

Views customize metric output without changing instrumentation code. Use them to rename instruments, filter attributes, change aggregations, or set histogram bucket boundaries.

### Node.js

```javascript
const { MeterProvider, View } = require('@opentelemetry/sdk-metrics');

const meterProvider = new MeterProvider({
  views: [
    // Custom histogram buckets for HTTP latency
    new View({
      instrumentName: 'http.server.duration',
      instrumentType: InstrumentType.HISTOGRAM,
      aggregation: new ExplicitBucketHistogramAggregation(
        [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
      ),
    }),

    // Drop high-cardinality attribute from a metric
    new View({
      instrumentName: 'http.server.request.count',
      attributeKeys: ['http.method', 'http.route', 'http.status_code'],
      // Only these attributes kept; user.id, request.id dropped
    }),

    // Rename instrument
    new View({
      instrumentName: 'legacy.request.latency',
      name: 'http.server.duration',
    }),
  ],
});
```

### Python

```python
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.view import View, ExplicitBucketHistogramAggregation

views = [
    View(
        instrument_name="http.server.duration",
        aggregation=ExplicitBucketHistogramAggregation(
            boundaries=[5, 10, 25, 50, 100, 250, 500, 1000, 5000]
        ),
    ),
    View(
        instrument_name="db.client.duration",
        attribute_keys={"db.system", "db.operation.name"},
        # Drops db.statement and other high-cardinality attrs
    ),
]

provider = MeterProvider(views=views, metric_readers=[reader], resource=resource)
```

### Cardinality Control via Views

```python
# Wildcard view: limit ALL instruments to safe attributes
View(
    instrument_name="*",
    attribute_keys={"service.name", "http.method", "http.status_code"},
)
```

**Key insight**: Views are evaluated at MeterProvider construction. Apply them early. Use wildcards cautiously.

---

## Exemplars

Exemplars bridge metrics and traces by attaching trace/span IDs to metric data points (typically histogram buckets). This enables "click a latency spike → jump to exact trace."

### How Exemplars Work

1. Application records a histogram measurement inside an active span context
2. SDK captures `trace_id` and `span_id` as exemplar metadata on the metric observation
3. Exemplars are exported alongside metric data to the backend
4. Dashboards (Grafana, etc.) render exemplar dots on metric charts with trace links

### Enabling Exemplars

```python
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import ExemplarFilterType

# Exemplar filters: ALWAYS_ON, ALWAYS_OFF, TRACE_BASED (default)
provider = MeterProvider(
    metric_readers=[reader],
    resource=resource,
    # TRACE_BASED: only attach exemplars when span is sampled
)
```

```javascript
// Node.js — exemplars are automatic when recording within an active span
const histogram = meter.createHistogram('http.server.duration', { unit: 'ms' });

async function handleRequest(req, res) {
  return tracer.startActiveSpan('handle_request', async (span) => {
    const start = Date.now();
    const result = await processRequest(req);
    // This measurement auto-attaches trace_id/span_id as exemplar
    histogram.record(Date.now() - start, {
      'http.method': req.method,
      'http.status_code': res.statusCode,
    });
    span.end();
    return result;
  });
}
```

### Collector Config for Exemplars

```yaml
# Ensure exemplar-aware exporters
exporters:
  prometheusremotewrite:
    endpoint: "http://mimir:9009/api/v1/push"
    # Prometheus remote write preserves exemplars
  otlp:
    endpoint: "tempo:4317"
    # OTLP natively supports exemplars
```

### Backend Requirements

| Backend | Exemplar Support | Notes |
|---------|-----------------|-------|
| Grafana Mimir | ✅ | Enable `exemplars-storage` |
| Prometheus | ✅ | `--enable-feature=exemplar-storage` |
| Google Cloud Monitoring | ✅ | Native support |
| Grafana Tempo | ✅ (for trace links) | Via exemplar on metrics |
| Datadog | ⚠️ Partial | Trace-metric correlation via tags |

---

## Baggage Propagation

Baggage carries cross-service key-value pairs through the entire request path. Unlike span attributes, baggage propagates to downstream services.

### Advanced Baggage Patterns

```python
from opentelemetry import baggage, context, propagate

# Pattern 1: Multi-tenant context propagation
def tenant_middleware(request, next_handler):
    tenant_id = request.headers.get("X-Tenant-ID")
    ctx = baggage.set_baggage("tenant.id", tenant_id)
    ctx = baggage.set_baggage("tenant.tier", lookup_tier(tenant_id), context=ctx)
    token = context.attach(ctx)
    try:
        return next_handler(request)
    finally:
        context.detach(token)

# Pattern 2: Feature flag propagation
ctx = baggage.set_baggage("feature.new_checkout", "true")
ctx = baggage.set_baggage("experiment.variant", "B", context=ctx)
```

### Baggage Span Processor — Lift Baggage into Spans

```python
class BaggageSpanProcessor(SpanProcessor):
    """Copies all baggage entries into span attributes with 'baggage.' prefix."""

    def __init__(self, keys_to_copy=None):
        self._keys = keys_to_copy  # None = copy all

    def on_start(self, span, parent_context=None):
        all_baggage = baggage.get_all(parent_context)
        for key, value in all_baggage.items():
            if self._keys is None or key in self._keys:
                span.set_attribute(f"baggage.{key}", value)
```

### Security Considerations

- Baggage is transmitted in **plaintext** HTTP headers
- **Never** put PII, tokens, secrets, or passwords in baggage
- Header size limit: ~8KB practical limit (browser/proxy restrictions)
- Use an allowlist processor to control which baggage keys propagate

```python
# Collector-side: strip unauthorized baggage before export
processors:
  attributes/baggage-filter:
    actions:
      - key: "baggage.internal.debug_token"
        action: delete
```

---

## Multi-Signal Correlation

Correlating traces, metrics, and logs through shared context.

### Resource-Level Correlation

All signals share `Resource` attributes — this is the primary correlation key:

```python
from opentelemetry.sdk.resources import Resource

shared_resource = Resource.create({
    "service.name": "payment-service",
    "service.version": "2.1.0",
    "deployment.environment": "production",
    "service.namespace": "checkout",
    "service.instance.id": socket.gethostname(),
})

# Apply to ALL providers
trace.set_tracer_provider(TracerProvider(resource=shared_resource))
metrics.set_meter_provider(MeterProvider(resource=shared_resource, ...))
# LoggerProvider uses the same resource
```

### Trace↔Log Correlation

```python
# Inject trace context into every log record
import logging
from opentelemetry.instrumentation.logging import LoggingInstrumentor

LoggingInstrumentor().instrument(set_logging_format=True)
# Logs now include: otelTraceID, otelSpanID, otelServiceName
```

### Trace↔Metric via Exemplars

See [Exemplars](#exemplars) section above.

### Metric→Trace via spanmetrics Connector

```yaml
# Collector config: generate metrics from traces
connectors:
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s]
    dimensions:
      - name: http.request.method
      - name: http.response.status_code
      - name: http.route
    exemplars:
      enabled: true
    metrics_flush_interval: 15s

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo, spanmetrics]
    metrics/spanmetrics:
      receivers: [spanmetrics]
      exporters: [prometheusremotewrite]
```

---

## Span Links

Links connect spans across trace boundaries — use for batch processing, fan-out, async workflows, or event-driven architectures.

### Patterns

```python
from opentelemetry.trace import Link

# Pattern 1: Batch job linking to all triggering requests
trigger_contexts = [msg.span_context for msg in batch_messages]
with tracer.start_as_current_span(
    "process_batch",
    links=[Link(ctx, {"link.type": "trigger"}) for ctx in trigger_contexts],
) as span:
    span.set_attribute("batch.size", len(batch_messages))
    process_all(batch_messages)

# Pattern 2: Async event → processing span
with tracer.start_as_current_span(
    "handle_event",
    links=[Link(event.producer_span_context, {"link.type": "produced_by"})],
) as span:
    handle(event)

# Pattern 3: Retry linking to original attempt
with tracer.start_as_current_span(
    "retry_payment",
    links=[Link(original_span_context, {"link.type": "retry_of", "retry.count": 2})],
) as span:
    retry_payment()
```

### When to Use Links vs Parent-Child

| Scenario | Use |
|----------|-----|
| Synchronous call chain | Parent-child spans |
| Message queue consumer → producer | Span link |
| Batch job → individual triggers | Span links (multiple) |
| Retry → original attempt | Span link |
| Fork-join / fan-out | Span links to forked operations |
| Cross-tenant or cross-system | Span link |

---

## Tail-Based Sampling with OTel Collector

Tail sampling makes decisions after a trace completes, keeping errors and slow traces while dropping routine ones.

### Production Configuration

```yaml
processors:
  tail_sampling:
    decision_wait: 30s
    num_traces: 200000
    expected_new_traces_per_sec: 5000
    policies:
      # Keep all errors
      - name: errors-always
        type: status_code
        status_code:
          status_codes: [ERROR]

      # Keep slow requests
      - name: slow-requests
        type: latency
        latency:
          threshold_ms: 2000

      # Keep specific high-value operations
      - name: payment-operations
        type: string_attribute
        string_attribute:
          key: service.name
          values: [payment-service, billing-service]
          enabled_regex_matching: false

      # Composite policy: error OR slow for specific service
      - name: composite-checkout
        type: composite
        composite:
          max_total_spans_per_second: 1000
          policy_order: [checkout-errors, checkout-slow, checkout-baseline]
          composite_sub_policy:
            - name: checkout-errors
              type: status_code
              status_code:
                status_codes: [ERROR]
            - name: checkout-slow
              type: latency
              latency:
                threshold_ms: 500
            - name: checkout-baseline
              type: probabilistic
              probabilistic:
                sampling_percentage: 5
          rate_allocation:
            - policy: checkout-errors
              percent: 50
            - policy: checkout-slow
              percent: 30
            - policy: checkout-baseline
              percent: 20

      # Baseline random sampling for everything else
      - name: probabilistic-baseline
        type: probabilistic
        probabilistic:
          sampling_percentage: 10
```

### Multi-Layer Architecture for Tail Sampling

```
Apps → Agent Collectors (DaemonSet)
         ↓ (route by trace ID hash)
       Gateway Collectors (Deployment, 3+ replicas)
         ↓ (tail_sampling processor)
       Backends (Tempo, Jaeger)
```

**Critical**: All spans of a trace must arrive at the same gateway instance. Use a load balancer with trace-ID-based routing:

```yaml
# Agent Collector config — route to gateway by trace ID
exporters:
  loadbalancing:
    protocol:
      otlp:
        endpoint: "otel-gateway-headless:4317"
        tls:
          insecure: true
    resolver:
      dns:
        hostname: otel-gateway-headless
        port: 4317
```

### Metrics Before Sampling

**Always** generate span metrics before tail sampling, or metrics will be inaccurate:

```yaml
service:
  pipelines:
    traces/pre-sampling:
      receivers: [otlp]
      exporters: [spanmetrics]     # metrics first
    traces:
      receivers: [otlp]
      processors: [tail_sampling, batch]
      exporters: [otlp/tempo]       # then sample
    metrics:
      receivers: [spanmetrics, otlp]
      exporters: [prometheusremotewrite]
```

---

## Resource Detectors

Resource detectors auto-populate `Resource` attributes with environment metadata.

### Available Detectors

| Detector | Attributes Added |
|----------|-----------------|
| `envDetectorSync` | From `OTEL_RESOURCE_ATTRIBUTES` env var |
| `hostDetectorSync` | `host.name`, `host.id`, `host.arch` |
| `osDetectorSync` | `os.type`, `os.version`, `os.description` |
| `processDetectorSync` | `process.pid`, `process.runtime.name`, `process.command` |
| `awsEc2DetectorSync` | `cloud.provider`, `cloud.region`, `host.id`, `host.type` |
| `awsEcsDetectorSync` | `cloud.platform`, `container.id`, `aws.ecs.task.arn` |
| `gcpDetectorSync` | `cloud.provider`, `cloud.region`, `cloud.zone` |
| `containerDetectorSync` | `container.id` |

### Node.js

```javascript
const { detectResourcesSync, envDetectorSync, hostDetectorSync,
        processDetectorSync } = require('@opentelemetry/resources');
const { awsEcsDetectorSync } = require('@opentelemetry/resource-detector-aws');

const resource = detectResourcesSync({
  detectors: [
    envDetectorSync,
    hostDetectorSync,
    processDetectorSync,
    awsEcsDetectorSync,
  ],
});

const sdk = new NodeSDK({ resource, ... });
```

### Python

```python
from opentelemetry.sdk.resources import Resource, OTELResourceDetector, ProcessResourceDetector
from opentelemetry.resource.detector.azure import AzureVMResourceDetector

resource = Resource.create({}).merge(
    OTELResourceDetector().detect()
).merge(
    ProcessResourceDetector().detect()
).merge(
    AzureVMResourceDetector().detect()
)
```

### Custom Resource Detector

```python
from opentelemetry.sdk.resources import ResourceDetector, Resource

class GitResourceDetector(ResourceDetector):
    def detect(self) -> Resource:
        import subprocess
        try:
            commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], text=True
            ).strip()
            branch = subprocess.check_output(
                ["git", "rev-parse", "--abbrev-ref", "HEAD"], text=True
            ).strip()
            return Resource.create({
                "vcs.repository.ref.revision": commit,
                "vcs.repository.ref.name": branch,
            })
        except Exception:
            return Resource.create({})
```

---

## Custom Exporters

Write custom exporters to send telemetry to unsupported backends.

### Python — Custom Span Exporter

```python
from opentelemetry.sdk.trace.export import SpanExporter, SpanExportResult
import json, requests

class WebhookSpanExporter(SpanExporter):
    def __init__(self, webhook_url: str):
        self._url = webhook_url

    def export(self, spans):
        payload = []
        for span in spans:
            payload.append({
                "trace_id": format(span.context.trace_id, "032x"),
                "span_id": format(span.context.span_id, "016x"),
                "name": span.name,
                "duration_ms": (span.end_time - span.start_time) / 1e6,
                "status": span.status.status_code.name,
                "attributes": dict(span.attributes),
            })
        try:
            resp = requests.post(self._url, json=payload, timeout=5)
            return SpanExportResult.SUCCESS if resp.ok else SpanExportResult.FAILURE
        except Exception:
            return SpanExportResult.FAILURE

    def shutdown(self):
        pass

    def force_flush(self, timeout_millis=30000):
        return True
```

### Node.js — Custom Metric Exporter

```javascript
const { PushMetricExporter } = require('@opentelemetry/sdk-metrics');

class CustomMetricExporter {
  export(metrics, resultCallback) {
    for (const scopeMetrics of metrics.scopeMetrics) {
      for (const metric of scopeMetrics.metrics) {
        // Transform and send to custom backend
        console.log(`${metric.descriptor.name}: ${JSON.stringify(metric.dataPoints)}`);
      }
    }
    resultCallback({ code: ExportResultCode.SUCCESS });
  }

  async forceFlush() {}
  async shutdown() {}

  selectAggregationTemporality(instrumentType) {
    return AggregationTemporality.DELTA;
  }
}
```

### Guidelines

- **Never mutate** span/metric data passed to `export()` — it may be shared
- Implement **retry logic** yourself — SDKs don't retry failed exports
- Use **BatchSpanProcessor** with custom exporters for buffering
- Implement `shutdown()` properly to flush pending data on process exit

---

## Advanced Context Propagation

### Custom Propagator

```python
from opentelemetry.context.propagation import TextMapPropagator

class CustomHeaderPropagator(TextMapPropagator):
    """Propagates internal request ID alongside W3C context."""

    def inject(self, carrier, context=None, setter=None):
        request_id = context_api.get_value("internal.request_id", context)
        if request_id:
            setter.set(carrier, "X-Internal-Request-ID", request_id)

    def extract(self, carrier, context=None, getter=None):
        request_id = getter.get(carrier, "X-Internal-Request-ID")
        if request_id:
            return context_api.set_value("internal.request_id", request_id[0], context)
        return context

    @property
    def fields(self):
        return {"x-internal-request-id"}
```

### Composite Propagator

```python
from opentelemetry.propagators.composite import CompositeTextMapPropagator
from opentelemetry.propagators.textmap import TraceContextTextMapPropagator
from opentelemetry.propagators.b3 import B3MultiFormat

# Support both W3C and B3 (for mixed environments)
propagator = CompositeTextMapPropagator([
    TraceContextTextMapPropagator(),
    B3MultiFormat(),
    CustomHeaderPropagator(),
])
propagate.set_global_textmap(propagator)
```

### Message Queue Context Propagation

```python
# Producer: inject context into message headers
from opentelemetry import propagate

def publish_message(topic, payload):
    headers = {}
    propagate.inject(headers)
    kafka_producer.send(topic, value=payload, headers=headers)

# Consumer: extract and continue trace
def consume_message(message):
    ctx = propagate.extract(carrier=dict(message.headers))
    with tracer.start_as_current_span("process_message", context=ctx) as span:
        span.set_attribute("messaging.destination.name", message.topic)
        process(message.value)
```

---

## OTTL

The OpenTelemetry Transformation Language enables declarative telemetry manipulation in the Collector.

### Common Transform Patterns

```yaml
processors:
  transform:
    trace_statements:
      - context: span
        statements:
          # Truncate long attribute values
          - truncate_all(attributes, 256)
          # Hash sensitive data
          - set(attributes["db.statement"], SHA256(attributes["db.statement"]))
            where attributes["db.system"] == "postgresql"
          # Set span status from HTTP code
          - set(status.code, 2) where attributes["http.response.status_code"] >= 500

    metric_statements:
      - context: datapoint
        statements:
          # Convert units
          - set(attributes["converted"], "true")
            where metric.name == "process.runtime.jvm.memory.usage"

    log_statements:
      - context: log
        statements:
          # Parse JSON body
          - merge_maps(attributes, ParseJSON(body), "insert")
            where IsMatch(body, "^\\{")
          # Set severity from parsed level
          - set(severity_text, attributes["level"])
```

---

## Connectors

Connectors bridge pipelines, acting as both exporter (from source pipeline) and receiver (to destination pipeline).

### spanmetrics Connector

```yaml
connectors:
  spanmetrics:
    histogram:
      explicit:
        buckets: [2ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s]
    dimensions:
      - name: http.request.method
      - name: http.response.status_code
      - name: rpc.service
    exemplars:
      enabled: true
    namespace: "traces.spanmetrics"
    metrics_flush_interval: 15s
```

### count Connector — Generate Counts from Any Signal

```yaml
connectors:
  count:
    traces:
      spans:
        "error.span.count":
          description: "Count of error spans"
          conditions:
            - status.code == 2
        "db.span.count":
          conditions:
            - attributes["db.system"] != nil
    logs:
      "error.log.count":
        conditions:
          - severity_number >= 17  # ERROR and above
```

### routing Connector — Route to Different Pipelines

```yaml
connectors:
  routing:
    table:
      - statement: route() where attributes["service.name"] == "payment-service"
        pipelines: [traces/high-priority]
      - statement: route() where attributes["http.route"] == "/healthz"
        pipelines: [traces/low-priority]
    default_pipelines: [traces/default]
```
