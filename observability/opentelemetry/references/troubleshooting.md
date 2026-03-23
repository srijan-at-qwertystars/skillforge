# OpenTelemetry Troubleshooting Guide

## Table of Contents

- [Missing Spans](#missing-spans)
- [High Cardinality Metrics](#high-cardinality-metrics)
- [Collector Pipeline Debugging](#collector-pipeline-debugging)
- [Memory Issues in Collector](#memory-issues-in-collector)
- [gRPC vs HTTP Transport Issues](#grpc-vs-http-transport-issues)
- [SDK Initialization Order Problems](#sdk-initialization-order-problems)
- [Auto-Instrumentation Not Working](#auto-instrumentation-not-working)
- [Context Loss in Async Code](#context-loss-in-async-code)

---

## Missing Spans

### Symptom: Gaps in trace waterfall, orphaned root spans, incomplete traces

**Check 1: Context propagation is broken**

The most common cause. Verify headers are flowing between services.

```bash
# Inspect headers between services — look for traceparent
curl -v http://your-service/endpoint 2>&1 | grep -i traceparent

# In Collector, enable debug exporter to see incoming spans
exporters:
  debug:
    verbosity: detailed
```

Common propagation breakages:
- **HTTP client not instrumented**: The outgoing call doesn't inject `traceparent`. Verify your HTTP client library has an instrumentation enabled.
- **Propagator mismatch**: Service A uses W3C TraceContext but Service B expects B3. All services must use the same propagator.
- **Proxy/gateway strips headers**: Load balancers, API gateways, or service meshes may drop custom headers. Whitelist `traceparent` and `tracestate`.
- **Manual HTTP calls**: Using raw `fetch`/`http.request` without the instrumented wrapper. Ensure context is injected:

```typescript
import { propagation, context } from '@opentelemetry/api';

const headers: Record<string, string> = {};
propagation.inject(context.active(), headers);
// Pass headers to your HTTP call
```

**Check 2: Sampling is dropping spans**

```bash
# Verify sampler settings
echo $OTEL_TRACES_SAMPLER          # Should be parentbased_traceidratio
echo $OTEL_TRACES_SAMPLER_ARG      # 0.1 = only 10% of root traces

# Quick test: set to always_on temporarily
export OTEL_TRACES_SAMPLER=always_on
```

ParentBased sampling means child services inherit the parent's decision. If the root service drops a trace, all downstream services also drop it. This is correct behavior — but if you see missing spans within a sampled trace, the problem is elsewhere.

**Check 3: Spans not ending**

Spans that never call `.end()` are never exported. This is the #1 bug in manual instrumentation.

```typescript
// BAD — span never ends if doWork throws
const span = tracer.startSpan('work');
await doWork();
span.end();

// GOOD — always end in finally
const span = tracer.startSpan('work');
try {
  await doWork();
} finally {
  span.end();
}

// BEST — startActiveSpan with callback handles context and ending
await tracer.startActiveSpan('work', async (span) => {
  try {
    await doWork();
  } finally {
    span.end();
  }
});
```

**Check 4: Exporter errors**

```bash
# Check for silent export failures — enable SDK debug logging
export OTEL_LOG_LEVEL=debug

# Node.js: look for these in stderr
# "Failed to export spans" / "Export timed out"

# Verify Collector is reachable
curl -s http://localhost:4318/v1/traces -X POST -d '{}' -H 'Content-Type: application/json'
# Should return 400 (bad request) not connection refused
```

**Check 5: Clock skew**

Spans with end_time < start_time are dropped by some backends. Ensure NTP is configured on all hosts, especially in containerized environments.

---

## High Cardinality Metrics

### Symptom: Memory growth, slow metric queries, exploding storage costs

**Diagnosis:**

```bash
# In Prometheus, find high-cardinality metrics
curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:10]'

# In Collector, count unique time series
# Enable the debug exporter on metrics pipeline and count unique label sets
```

**Common culprits:**

| Attribute | Problem | Fix |
|---|---|---|
| `url.full` | Every URL with query params is unique | Use `http.route` (e.g., `/users/:id`) |
| `user.id` | Unbounded user set | Remove from metrics; keep in traces |
| `db.statement` | Every SQL query is unique | Use parameterized query template |
| `rpc.method` | Auto-generated method names | Group by service, not method |
| `error.message` | Unique stack traces | Use error category/type |

**Fix in SDK with Views:**

```typescript
// Drop url.full from histogram, keep only useful attributes
new View({
  instrumentName: 'http.server.request.duration',
  attributeKeys: ['http.request.method', 'http.response.status_code', 'http.route'],
});
```

**Fix in Collector with transform processor:**

```yaml
processors:
  transform:
    metric_statements:
      - context: datapoint
        statements:
          - delete_key(attributes, "url.full")
          - delete_key(attributes, "user.id")
  filter/drop-debug-metrics:
    metrics:
      exclude:
        match_type: regexp
        metric_names:
          - ".*debug.*"
```

**Prevention rules:**
- Traces: high cardinality is fine (each span is independent)
- Metrics: every unique attribute combination creates a time series — keep cardinality < 1000 per metric
- Set cardinality limits in Collector's spanmetrics connector if using it

---

## Collector Pipeline Debugging

### Enable zpages

zpages expose internal Collector diagnostics on a web UI:

```yaml
extensions:
  zpages:
    endpoint: 0.0.0.0:55679

service:
  extensions: [zpages]
```

Navigate to:
- `http://localhost:55679/debug/tracez` — View sampled traces through the Collector
- `http://localhost:55679/debug/pipelinez` — View pipeline topology
- `http://localhost:55679/debug/extensionz` — Extension status

### Use the debug exporter

Add to any pipeline for stdout visibility:

```yaml
exporters:
  debug:
    verbosity: detailed    # basic | normal | detailed
    sampling_initial: 5    # First N items logged in full
    sampling_thereafter: 1 # Then every Nth item

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/backend, debug]   # Add debug alongside real exporter
```

### Check Collector internal metrics

The Collector emits its own metrics. Key ones to monitor:

```
otelcol_receiver_accepted_spans          — Spans successfully received
otelcol_receiver_refused_spans           — Spans rejected (auth, format)
otelcol_processor_dropped_spans          — Spans dropped by processors
otelcol_exporter_sent_spans              — Spans successfully exported
otelcol_exporter_send_failed_spans       — Export failures
otelcol_exporter_queue_size              — Current export queue depth
otelcol_exporter_queue_capacity          — Max export queue size
otelcol_processor_batch_batch_send_size  — Actual batch sizes
```

**Where data is lost — diagnosis flow:**

```
received > 0, sent = 0     → Exporter failure (check endpoint, auth, TLS)
received > 0, dropped > 0  → Processor filtering/sampling too aggressive
received = 0               → Receiver not getting data (port, protocol mismatch)
queue_size = queue_capacity → Backpressure, exporter can't keep up
```

### Validate config before deploying

```bash
# Built-in validation
otelcol validate --config=config.yaml
otelcol-contrib validate --config=config.yaml

# YAML syntax check first
python3 -c "import yaml; yaml.safe_load(open('config.yaml'))"
```

---

## Memory Issues in Collector

### Symptom: OOMKilled pods, increasing RSS, Collector restarts

**Root causes:**

1. **Missing `memory_limiter` processor** — The single most important processor for production.

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 1800        # Hard limit — start dropping data
    spike_limit_mib: 400   # Soft limit — start refusing new data
    # Set limit_mib to ~80% of container memory limit
```

**Pipeline order matters:** `memory_limiter` MUST be the first processor.

```yaml
service:
  pipelines:
    traces:
      processors: [memory_limiter, attributes, batch]   # memory_limiter FIRST
```

2. **Batch processor queue too large**

```yaml
processors:
  batch:
    send_batch_size: 8192
    timeout: 5s
    send_batch_max_size: 16384   # Cap maximum batch size
```

3. **Tail sampling buffering too many traces**

The `tail_sampling` processor holds spans in memory for `decision_wait` duration. Memory = `num_traces × avg_spans × avg_span_size`.

```yaml
processors:
  tail_sampling:
    decision_wait: 10s      # Don't exceed 30s
    num_traces: 50000        # Limit concurrent traces in memory
```

If `num_traces` is exceeded, oldest traces are force-decided and evicted.

4. **Export queue backpressure**

When the backend is slow, the sending queue grows unbounded by default:

```yaml
exporters:
  otlp:
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000       # Limit queue size
    retry_on_failure:
      enabled: true
      max_elapsed_time: 300s
```

**Monitoring memory:**

```bash
# Check Collector memory metrics
curl -s http://localhost:8888/metrics | grep otelcol_process_runtime_total_alloc_bytes
# Also monitor container-level memory via Kubernetes metrics
```

---

## gRPC vs HTTP Transport Issues

### Choosing the Right Protocol

| Aspect | gRPC (port 4317) | HTTP/protobuf (port 4318) |
|---|---|---|
| Performance | Higher throughput, streaming | Slightly lower, request-response |
| Compatibility | Requires HTTP/2 | Works everywhere |
| Proxies/LBs | Some L7 proxies break gRPC | Universal proxy support |
| Debugging | Hard to inspect with curl | Easy to test with curl |
| Browser | Not supported | Supported |

### Common gRPC Issues

**Problem: "connection refused" or timeouts behind proxy**

Many proxies (nginx, ALB, Cloudflare) don't support HTTP/2 by default or strip gRPC frames.

```bash
# Test gRPC connectivity
grpcurl -plaintext localhost:4317 list

# If behind a proxy, switch to HTTP
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318
```

**Problem: TLS handshake failures**

```bash
# Verify TLS certificate
openssl s_client -connect collector:4317 </dev/null 2>/dev/null | openssl x509 -noout -dates

# For self-signed certs in dev, disable verification (NEVER in production)
export OTEL_EXPORTER_OTLP_INSECURE=true
```

**Problem: Wrong endpoint format**

```bash
# gRPC: just host:port, no path
export OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317

# HTTP: just host:port, SDK appends /v1/traces automatically
export OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318
# Do NOT add /v1/traces to the endpoint — the SDK does it

# Per-signal endpoints DO need the full path:
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://collector:4318/v1/traces
```

---

## SDK Initialization Order Problems

### The Golden Rule: Initialize OTel SDK BEFORE importing any application code

**Node.js:**

```bash
# Correct — instrumentation loads before app
node --require ./instrumentation.js app.js

# Also correct — ESM loader
node --import ./instrumentation.mjs app.mjs

# WRONG — importing instrumentation inside app.js
# By the time the SDK patches http/express, the modules are already loaded
```

**Python:**

```bash
# Correct — opentelemetry-instrument wraps your app
opentelemetry-instrument python app.py

# Correct — sitecustomize.py approach
export PYTHONPATH=/path/to/otel-setup:$PYTHONPATH
# Place opentelemetry setup in sitecustomize.py

# WRONG — importing setup at bottom of app.py
```

**Java:**

```bash
# Correct — javaagent loads at JVM startup
java -javaagent:opentelemetry-javaagent.jar -jar app.jar

# WRONG — adding agent after JVM starts
# Bytecode transformation must happen at class load time
```

### Diagnosing Init Order Issues

Symptoms:
- Auto-instrumentation produces no spans for some libraries
- HTTP spans appear but database spans don't
- Some modules instrumented, others not

Debug:

```bash
# Node.js — enable instrumentation debug logging
export OTEL_LOG_LEVEL=debug
# Look for: "Module X already loaded, cannot instrument"

# Python
export OTEL_PYTHON_LOG_LEVEL=debug
```

---

## Auto-Instrumentation Not Working

### Checklist

1. **Is the SDK initialized before the app?** (See SDK Initialization Order above)
2. **Is the library version supported?**

```bash
# Node.js — check supported versions
npm ls @opentelemetry/instrumentation-http
# Check the instrumentation package README for supported library versions

# Python — check installed instrumentations
opentelemetry-bootstrap --action=requirements
```

3. **Is the specific instrumentation installed?**

```bash
# Node.js — getNodeAutoInstrumentations() installs common ones
# But you may need additional packages:
npm install @opentelemetry/instrumentation-redis-4
npm install @opentelemetry/instrumentation-mongoose

# Python — auto-detect and install
opentelemetry-bootstrap -a install
```

4. **Is it explicitly disabled?**

```typescript
// Check if you accidentally disabled it
getNodeAutoInstrumentations({
  '@opentelemetry/instrumentation-http': { enabled: false },  // Oops
});
```

5. **ESM (import) vs CJS (require) — Node.js**

Auto-instrumentation hooks into `require()`. ESM modules use `import` which bypasses the hook.

```bash
# For ESM, use the --import flag with a loader
node --import ./instrumentation.mjs app.mjs

# Or use the experimental loader
node --experimental-loader @opentelemetry/instrumentation/hook.mjs app.mjs
```

6. **Framework-specific issues:**

| Framework | Common Issue | Fix |
|---|---|---|
| Next.js | Webpack bundles modules, breaking patching | Use `experimental.instrumentationHook` in `next.config.js` |
| NestJS | Dependency injection delays module loading | Ensure `--require` runs before NestJS bootstrap |
| FastAPI | Async context not propagated | Use `opentelemetry-instrumentation-fastapi` ≥ 0.39b0 |
| Spring Boot | Agent not on classpath | Verify `-javaagent` flag is first JVM arg |

---

## Context Loss in Async Code

### Symptom: Child spans appear as root spans, trace_id changes mid-request

**Node.js — AsyncLocalStorage**

The OTel SDK uses `AsyncLocalStorage` to propagate context across async boundaries. This works automatically with:
- Promises / async-await
- `setTimeout` / `setInterval`
- `EventEmitter` callbacks

Context is **lost** with:
- Native C++ addons that create callbacks outside V8
- `worker_threads` (each worker has its own context)
- Manual `new Promise()` with executor functions in some edge cases

```typescript
// WRONG — context lost because span is not active when callback runs
const span = tracer.startSpan('parent');
someNativeAddon.doWork(() => {
  const childSpan = tracer.startSpan('child');   // Orphaned!
  childSpan.end();
});
span.end();

// FIX — explicitly bind context
import { context, trace } from '@opentelemetry/api';

const span = tracer.startSpan('parent');
const ctx = trace.setSpan(context.active(), span);
someNativeAddon.doWork(context.bind(ctx, () => {
  const childSpan = tracer.startSpan('child');   // Properly parented
  childSpan.end();
}));
span.end();
```

**Python — contextvars**

Python OTel uses `contextvars` which works with `asyncio` and `threading`. Context is lost with:
- `multiprocessing` (separate memory space)
- `concurrent.futures.ProcessPoolExecutor`
- Some C extensions that bypass the Python event loop

```python
# WRONG — context lost in thread pool
import concurrent.futures
with tracer.start_as_current_span("parent"):
    with concurrent.futures.ThreadPoolExecutor() as pool:
        pool.submit(do_work)  # Context not propagated to thread

# FIX — manually propagate context
from opentelemetry.context import attach, detach, get_current

with tracer.start_as_current_span("parent"):
    ctx = get_current()
    def work_with_context():
        token = attach(ctx)
        try:
            with tracer.start_as_current_span("child"):
                do_work()
        finally:
            detach(token)
    with concurrent.futures.ThreadPoolExecutor() as pool:
        pool.submit(work_with_context)
```

**Go — Context parameter**

Go doesn't have implicit context — it's always explicit via `context.Context`. Context is "lost" when you forget to pass it:

```go
// WRONG
func handleRequest(w http.ResponseWriter, r *http.Request) {
    go processAsync()  // context.Background() — orphaned span
}

// CORRECT
func handleRequest(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    go processAsync(ctx)  // Propagate request context
}
```
