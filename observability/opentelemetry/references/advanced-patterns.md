# OpenTelemetry Advanced Patterns

## Table of Contents

- [Custom Span Processors](#custom-span-processors)
- [Batch vs Simple Exporters](#batch-vs-simple-exporters)
- [Tail-Based Sampling with Collector](#tail-based-sampling-with-collector)
- [Span Links](#span-links)
- [Span Events](#span-events)
- [Metric Views and Aggregation](#metric-views-and-aggregation)
- [Exemplars](#exemplars)
- [Log Correlation with Traces](#log-correlation-with-traces)
- [Custom Propagators](#custom-propagators)
- [Resource Detection](#resource-detection)
- [Multi-Signal Correlation](#multi-signal-correlation)
- [Instrumentation Libraries Deep Dive](#instrumentation-libraries-deep-dive)

---

## Custom Span Processors

Span processors intercept spans at `OnStart` and `OnEnd` to enrich, filter, or transform before export.

### When to Build Custom Processors

- Redact PII from span attributes before export
- Attach runtime metadata (git SHA, feature flags) to every span
- Filter out noisy spans (health checks, readiness probes) at SDK level
- Route spans to different exporters based on attributes

### Implementation Pattern (Node.js)

```typescript
import { SpanProcessor, ReadableSpan, Span } from '@opentelemetry/sdk-trace-base';

class RedactingSpanProcessor implements SpanProcessor {
  private sensitiveKeys = ['user.email', 'http.request.header.authorization'];

  onStart(span: Span): void {
    // Attach build metadata to every span
    span.setAttribute('app.build_sha', process.env.GIT_SHA ?? 'unknown');
  }

  onEnd(span: ReadableSpan): void {
    // Redact sensitive attributes before export
    for (const key of this.sensitiveKeys) {
      if (span.attributes[key]) {
        (span.attributes as Record<string, unknown>)[key] = '[REDACTED]';
      }
    }
  }

  async forceFlush(): Promise<void> {}
  async shutdown(): Promise<void> {}
}
```

### Implementation Pattern (Python)

```python
from opentelemetry.sdk.trace import SpanProcessor, ReadableSpan, Span

class FilterHealthCheckProcessor(SpanProcessor):
    def on_start(self, span: Span, parent_context=None) -> None:
        pass

    def on_end(self, span: ReadableSpan) -> None:
        # Drop health check spans by returning early
        if span.name in ("/healthz", "/readyz", "GET /health"):
            return
        # Forward to next processor in chain
        self._next_processor.on_end(span)
```

### Chaining Processors

Register multiple processors — they execute in order:

```typescript
const provider = new NodeTracerProvider();
provider.addSpanProcessor(new RedactingSpanProcessor());
provider.addSpanProcessor(new BatchSpanProcessor(new OTLPTraceExporter()));
```

---

## Batch vs Simple Exporters

| Aspect | SimpleSpanProcessor | BatchSpanProcessor |
|---|---|---|
| Export timing | Synchronous on `span.end()` | Async, batched by size/interval |
| Network calls | One per span | One per batch |
| Memory | Minimal | Buffers spans in queue |
| Data loss risk | Very low | Possible on crash before flush |
| Production use | **Never** | **Always** |

### Tuning BatchSpanProcessor

```typescript
new BatchSpanProcessor(exporter, {
  maxQueueSize: 2048,            // Max spans buffered (default: 2048)
  maxExportBatchSize: 512,       // Spans per export call (default: 512)
  scheduledDelayMillis: 5000,    // Export interval (default: 5000ms)
  exportTimeoutMillis: 30000,    // Timeout per export (default: 30000ms)
});
```

**Rules of thumb:**
- `maxQueueSize` ≥ 4× `maxExportBatchSize` to absorb bursts
- Lower `scheduledDelayMillis` for latency-sensitive debugging (1000ms)
- Always call `sdk.shutdown()` on SIGTERM to flush the buffer

### When SimpleSpanProcessor Is Acceptable

- Unit tests that assert on exported spans
- CLI tools that process a single request then exit
- Local development where you want immediate span visibility

---

## Tail-Based Sampling with Collector

Tail-based sampling makes decisions after seeing the complete trace, enabling policies like "keep all errors" without head-based guessing.

### Architecture Requirements

All spans for a trace **must** arrive at the same Collector instance. Use the `loadbalancing` exporter with `traceID` routing:

```
[App Agents] → [loadbalancing exporter (by traceID)] → [Gateway Collectors] → [Backend]
```

### Agent-Layer Config (DaemonSet)

```yaml
exporters:
  loadbalancing:
    protocol:
      otlp:
        tls:
          insecure: true
    resolver:
      dns:
        hostname: otel-gateway-headless.observability.svc.cluster.local
        port: 4317
```

### Gateway-Layer Config (tail sampling)

```yaml
processors:
  groupbytrace:
    wait_duration: 10s
    num_traces: 100000
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    expected_new_traces_per_sec: 1000
    policies:
      - name: errors-always
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow-requests
        type: latency
        latency: { threshold_ms: 2000 }
      - name: high-value-endpoints
        type: string_attribute
        string_attribute:
          key: http.route
          values: ["/api/checkout", "/api/payment"]
      - name: baseline-sample
        type: probabilistic
        probabilistic: { sampling_percentage: 5 }
```

**Critical rules:**
- `groupbytrace` MUST come before `tail_sampling` in the pipeline
- Do NOT place `batch` before `tail_sampling` — it can split trace spans across batches
- Place `batch` AFTER `tail_sampling` for efficient export
- Memory sizing: `num_traces × avg_spans_per_trace × avg_span_size`

### Composite Policies (AND logic)

```yaml
policies:
  - name: slow-errors-only
    type: and
    and:
      and_sub_policy:
        - name: is-error
          type: status_code
          status_code: { status_codes: [ERROR] }
        - name: is-slow
          type: latency
          latency: { threshold_ms: 1000 }
```

---

## Span Links

Links connect causally related spans across trace boundaries — unlike parent-child, links are many-to-many.

### Use Cases

- **Batch processing**: Link each batch-item span to the span that enqueued it
- **Fan-out/fan-in**: Link aggregation span to all contributing spans
- **Retries**: Link retry span to the original failed span

### Creating Links

```typescript
const enqueuingSpanContext = trace.getSpan(context.active())?.spanContext();

tracer.startActiveSpan('processBatchItem', {
  links: enqueuingSpanContext
    ? [{ context: enqueuingSpanContext, attributes: { 'link.type': 'enqueued_by' } }]
    : [],
}, async (span) => {
  // process item
  span.end();
});
```

```python
from opentelemetry import trace

link = trace.Link(enqueuing_span.get_span_context(),
                  attributes={"link.type": "enqueued_by"})
with tracer.start_as_current_span("process_batch_item", links=[link]) as span:
    pass
```

---

## Span Events

Events are timestamped annotations within a span's lifetime. They do NOT create new spans.

### Common Patterns

```typescript
span.addEvent('cache.miss', { 'cache.key': 'user:123' });
span.addEvent('retry.attempt', { 'retry.count': 2, 'retry.reason': 'timeout' });

// Exception events (prefer recordException for stack traces)
span.recordException(error);   // Adds 'exception' event with type, message, stacktrace
```

### When to Use Events vs Child Spans

| Use Events | Use Child Spans |
|---|---|
| Point-in-time annotations | Operations with duration |
| Cache hits/misses | Database queries |
| Retry attempts | HTTP calls |
| State transitions | Business logic steps |
| Lightweight, no export overhead | Need separate timing/attributes |

---

## Metric Views and Aggregation

Views customize how instruments are aggregated in the SDK — rename, change aggregation, drop attributes.

### Defining Views (Node.js)

```typescript
import { View, ExplicitBucketHistogramAggregation } from '@opentelemetry/sdk-metrics';

const meterProvider = new MeterProvider({
  views: [
    // Custom histogram buckets for HTTP duration
    new View({
      instrumentName: 'http.server.request.duration',
      aggregation: new ExplicitBucketHistogramAggregation(
        [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
      ),
    }),
    // Drop high-cardinality attribute from a metric
    new View({
      instrumentName: 'http.server.request.duration',
      attributeKeys: ['http.request.method', 'http.response.status_code'],
      // Only these attributes kept; url.full is dropped
    }),
    // Rename an instrument
    new View({
      instrumentName: 'legacy.counter',
      name: 'app.requests_total',
    }),
  ],
});
```

### Aggregation Types

| Aggregation | Used For | Default Instrument |
|---|---|---|
| Sum | Counters, UpDownCounters | Counter, UpDownCounter |
| LastValue | Current state | Gauge |
| ExplicitBucketHistogram | Distributions | Histogram |
| ExponentialBucketHistogram | Auto-bucketed distributions | (opt-in) |
| Drop | Disable an instrument | (explicit only) |

---

## Exemplars

Exemplars link metric data points to trace spans, enabling drill-down from a metric spike to the specific trace.

### How They Work

When a metric records a value inside an active span, the SDK attaches the span's trace ID and span ID as an exemplar on the metric data point.

### Enabling Exemplars

```typescript
// Node.js — exemplar filter
const meterProvider = new MeterProvider({
  readers: [new PeriodicExportingMetricReader({ exporter })],
  // ExemplarFilter: AlwaysOn, AlwaysSample, TraceBased (default)
});
```

```bash
# Via environment variable
export OTEL_METRICS_EXEMPLAR_FILTER=trace_based   # default: attach exemplars when sampled
```

**Backend requirements:** Not all backends support exemplars. Prometheus (with native histograms), Grafana Tempo+Mimir, and Honeycomb support exemplar-based drill-down.

---

## Log Correlation with Traces

The goal: every log line carries `trace_id` and `span_id` for seamless correlation.

### Node.js (Pino + OTel)

```typescript
import pino from 'pino';
import { trace } from '@opentelemetry/api';

const logger = pino({
  mixin() {
    const span = trace.getActiveSpan();
    if (span) {
      const ctx = span.spanContext();
      return { trace_id: ctx.traceId, span_id: ctx.spanId };
    }
    return {};
  },
});
```

### Python (structlog + OTel)

```python
import structlog
from opentelemetry import trace

def add_trace_context(logger, method_name, event_dict):
    span = trace.get_current_span()
    ctx = span.get_span_context()
    if ctx.is_valid:
        event_dict["trace_id"] = format(ctx.trace_id, '032x')
        event_dict["span_id"] = format(ctx.span_id, '016x')
    return event_dict

structlog.configure(processors=[add_trace_context, structlog.dev.ConsoleRenderer()])
```

### Log Bridge API (OTel-native)

For full pipeline integration (logs through the Collector):

```typescript
import { logs } from '@opentelemetry/api-logs';
import { LoggerProvider, BatchLogRecordProcessor } from '@opentelemetry/sdk-logs';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-http';

const loggerProvider = new LoggerProvider();
loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(new OTLPLogExporter()));
logs.setGlobalLoggerProvider(loggerProvider);
```

---

## Custom Propagators

Build custom propagators when you need to support proprietary context formats or add custom fields.

### Implementation (Node.js)

```typescript
import { TextMapPropagator, TextMapSetter, TextMapGetter, Context } from '@opentelemetry/api';
import { TraceState } from '@opentelemetry/core';

class TenantPropagator implements TextMapPropagator {
  inject(context: Context, carrier: unknown, setter: TextMapSetter): void {
    const tenantId = context.getValue(TENANT_KEY);
    if (tenantId) setter.set(carrier, 'x-tenant-id', String(tenantId));
  }

  extract(context: Context, carrier: unknown, getter: TextMapGetter): Context {
    const tenantId = getter.get(carrier, 'x-tenant-id');
    return tenantId ? context.setValue(TENANT_KEY, tenantId) : context;
  }

  fields(): string[] { return ['x-tenant-id']; }
}
```

### Registering Composite Propagator

```typescript
import { CompositePropagator, W3CTraceContextPropagator, W3CBaggagePropagator } from '@opentelemetry/core';

api.propagation.setGlobalPropagator(new CompositePropagator({
  propagators: [
    new W3CTraceContextPropagator(),
    new W3CBaggagePropagator(),
    new TenantPropagator(),
  ],
}));
```

---

## Resource Detection

Resource detectors automatically populate resource attributes from the runtime environment.

### Built-in Detectors

```typescript
import { envDetector, hostDetector, processDetector } from '@opentelemetry/resources';
import { awsEcsDetector, awsEc2Detector } from '@opentelemetry/resource-detector-aws';
import { gcpDetector } from '@opentelemetry/resource-detector-gcp';

const sdk = new NodeSDK({
  resourceDetectors: [
    envDetector,         // Reads OTEL_RESOURCE_ATTRIBUTES
    hostDetector,        // host.name, host.arch
    processDetector,     // process.pid, process.runtime.*
    awsEcsDetector,      // cloud.provider, cloud.platform, aws.ecs.*
    gcpDetector,         // cloud.provider, cloud.region, gcp.*
  ],
});
```

### Detector Priority

Detectors run in order. Later detectors do NOT override earlier values. Place specific detectors (AWS, GCP) before generic ones.

---

## Multi-Signal Correlation

The power of OTel is correlating traces, metrics, and logs via shared context.

### Correlation Keys

| Signal A | Signal B | Correlation Key |
|---|---|---|
| Trace → Log | `trace_id`, `span_id` in log record |
| Metric → Trace | Exemplar with `trace_id`, `span_id` |
| Log → Metric | Shared resource attributes (`service.name`) |
| Trace → Trace | Span links |

### Enabling Full Correlation

1. **Same `service.name` and `service.instance.id`** across all signals
2. **Exemplars enabled** on metric instruments (trace-based filter)
3. **Log bridge** or mixin injecting trace context into logs
4. **Same Collector pipeline** processing all signals for consistent resource enrichment

---

## Instrumentation Libraries Deep Dive

### How Auto-Instrumentation Works

Auto-instrumentation patches library prototypes/hooks at import time:

- **Node.js**: Uses `require-in-the-middle` to intercept `require()` calls and monkey-patch modules
- **Python**: Uses `wrapt` or `importlib` hooks to wrap functions
- **Java**: Uses `-javaagent` bytecode manipulation at class load time
- **Go**: No runtime patching — uses compile-time wrapper packages

### Selective Instrumentation

Disable noisy instrumentations to reduce overhead:

```typescript
getNodeAutoInstrumentations({
  '@opentelemetry/instrumentation-fs': { enabled: false },
  '@opentelemetry/instrumentation-dns': { enabled: false },
  '@opentelemetry/instrumentation-net': { enabled: false },
  '@opentelemetry/instrumentation-http': {
    ignoreIncomingRequestHook: (req) => req.url === '/healthz',
  },
});
```

### Writing Custom Instrumentation

For internal libraries not covered by auto-instrumentation:

```typescript
import { InstrumentationBase, InstrumentationNodeModuleDefinition } from '@opentelemetry/instrumentation';

class MyLibInstrumentation extends InstrumentationBase {
  constructor() {
    super('my-lib-instrumentation', '1.0.0');
  }

  protected init(): InstrumentationNodeModuleDefinition[] {
    return [new InstrumentationNodeModuleDefinition(
      'my-lib', ['>=2.0.0'],
      (moduleExports) => {
        this._wrap(moduleExports, 'doWork', this._patchDoWork());
        return moduleExports;
      },
      (moduleExports) => {
        this._unwrap(moduleExports, 'doWork');
      },
    )];
  }

  private _patchDoWork() {
    const instrumentation = this;
    return function (original: Function) {
      return function (this: unknown, ...args: unknown[]) {
        return instrumentation.tracer.startActiveSpan('my-lib.doWork', (span) => {
          try {
            return original.apply(this, args);
          } finally {
            span.end();
          }
        });
      };
    };
  }
}
```
