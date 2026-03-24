# OpenTelemetry Troubleshooting Guide

> Systematic diagnosis for common OTel issues. Each section: symptoms → causes → diagnostic steps → fixes.

## Table of Contents

- [Missing Spans Diagnosis](#missing-spans-diagnosis)
- [Context Propagation Breaks](#context-propagation-breaks)
- [High Cardinality Issues](#high-cardinality-issues)
- [Memory Leaks in Instrumentation](#memory-leaks-in-instrumentation)
- [Collector Pipeline Debugging](#collector-pipeline-debugging)
- [Exporter Failures](#exporter-failures)
- [SDK Initialization Ordering](#sdk-initialization-ordering)
- [Sampling Confusion](#sampling-confusion)
- [Quick Diagnostic Commands](#quick-diagnostic-commands)

---

## Missing Spans Diagnosis

### Symptoms

- Traces appear fragmented — child spans show as separate root traces
- Span count lower than expected requests
- Traces end abruptly — downstream service spans missing
- Some services never appear in trace UI

### Diagnostic Decision Tree

```
Missing spans?
├─ No spans at all → SDK initialization issue (see SDK Initialization Ordering)
├─ Some spans missing from specific service
│  ├─ Check: is auto-instrumentation loaded?
│  │  └─ Node: --require ./tracing.js before app code?
│  │  └─ Python: opentelemetry-instrument wrapper used?
│  │  └─ Java: -javaagent flag present?
│  ├─ Check: is the library instrumented?
│  │  └─ Custom HTTP clients may not be auto-instrumented
│  └─ Check: sampling rate
│     └─ OTEL_TRACES_SAMPLER_ARG=0 means 0% sampling
├─ Spans appear as separate traces (broken parent-child)
│  └─ Context propagation break (see next section)
└─ Spans exported but not in backend
   └─ Collector dropping? Backend ingestion error? Check Collector logs
```

### Step-by-Step Diagnosis

**1. Enable debug logging**

```bash
# SDK-level debug
export OTEL_LOG_LEVEL=debug

# Node.js — add diagnostic logger
export OTEL_LOG_LEVEL=debug
# or in code:
const { diag, DiagConsoleLogger, DiagLogLevel } = require('@opentelemetry/api');
diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.DEBUG);

# Python
import logging
logging.basicConfig(level=logging.DEBUG)
```

**2. Use ConsoleSpanExporter to verify spans are created**

```python
from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor
provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
```

```javascript
const { ConsoleSpanExporter, SimpleSpanProcessor } = require('@opentelemetry/sdk-trace-base');
provider.addSpanProcessor(new SimpleSpanProcessor(new ConsoleSpanExporter()));
```

**3. Check Collector is receiving data**

```bash
# Check Collector debug exporter output
# In collector config:
exporters:
  debug:
    verbosity: detailed

# Verify data reaches Collector
curl -s http://localhost:8888/metrics | grep otelcol_receiver_accepted_spans
# Should show non-zero counter
```

**4. Verify traceflags**

```
# Check traceparent header
traceparent: 00-<trace_id>-<span_id>-01
                                       ^^ 01 = sampled, 00 = NOT sampled
# If 00: check sampler config
```

### Common Fixes

| Issue | Fix |
|-------|-----|
| No spans at all | Ensure SDK initializes before app code imports |
| Async spans missing | Capture Context before async boundary, reattach in callback |
| Library not instrumented | Add specific instrumentation package |
| Sampler dropping | Set `OTEL_TRACES_SAMPLER=always_on` for debugging |
| Spans created but not exported | Check exporter endpoint, TLS, network connectivity |

---

## Context Propagation Breaks

### Symptoms

- Child spans appear as root spans (new trace IDs)
- `traceparent` header missing from outgoing requests
- Cross-service traces are disconnected

### Diagnosis

**1. Verify propagator configuration**

```bash
# All services must use the same propagator
export OTEL_PROPAGATORS=tracecontext,baggage

# Common mistake: service A uses W3C, service B uses B3
# Fix: align all services or use CompositeTextMapPropagator
```

**2. Inspect HTTP headers**

```bash
# Add request logging to see if traceparent is injected
curl -v http://service-b/api/endpoint 2>&1 | grep -i traceparent
# Expected: traceparent: 00-<32hex>-<16hex>-01

# In application code — log outgoing headers
```

**3. Check auto-instrumentation coverage**

```bash
# Node.js — verify instrumentation packages installed
npm ls | grep @opentelemetry/instrumentation

# Python — list installed instrumentations
pip list | grep opentelemetry-instrumentation

# Missing instrumentation for HTTP client = no header injection
```

### Common Propagation Break Scenarios

**Scenario: Async code loses context**

```javascript
// BROKEN — context lost in callback
http.get(url, (response) => {
  // No active span context here
  processResponse(response);
});

// FIXED — use context.with() or instrumented client
const { context } = require('@opentelemetry/api');
const currentContext = context.active();
http.get(url, (response) => {
  context.with(currentContext, () => {
    processResponse(response);
  });
});
```

```java
// BROKEN — CompletableFuture loses context
CompletableFuture.supplyAsync(() -> doWork());

// FIXED — capture and restore context
Context currentContext = Context.current();
CompletableFuture.supplyAsync(() -> {
    try (Scope scope = currentContext.makeCurrent()) {
        return doWork();
    }
});
```

**Scenario: Message queue breaks context**

```python
# Producer must inject context into message headers
headers = {}
propagate.inject(headers)
producer.send(topic, value=payload, headers=headers)

# Consumer must extract context from headers
ctx = propagate.extract(carrier=dict(message.headers))
with tracer.start_as_current_span("consume", context=ctx):
    process(message)
```

**Scenario: Reverse proxy / API gateway strips headers**

```nginx
# Nginx — ensure traceparent is forwarded
proxy_pass_request_headers on;
# Or explicitly:
proxy_set_header traceparent $http_traceparent;
proxy_set_header tracestate $http_tracestate;
proxy_set_header baggage $http_baggage;
```

**Scenario: gRPC metadata not propagated**

```python
# Ensure gRPC instrumentation propagates metadata
# Install: pip install opentelemetry-instrumentation-grpc
from opentelemetry.instrumentation.grpc import GrpcInstrumentorClient, GrpcInstrumentorServer
GrpcInstrumentorClient().instrument()
GrpcInstrumentorServer().instrument()
```

---

## High Cardinality Issues

### Symptoms

- Metric storage exploding (disk/memory usage in Prometheus/Mimir)
- Backend queries slow or timing out
- OOM in Collector or backend
- Alert: "cardinality limit exceeded"

### Diagnosis

```bash
# Check cardinality in Prometheus
curl -s http://prometheus:9090/api/v1/label/__name__/values | jq '.data | length'
# Check per-metric cardinality
curl -s 'http://prometheus:9090/api/v1/query?query=count({__name__="http_server_duration_bucket"}) by (le)' | jq

# In Collector — check metrics
curl -s http://collector:8888/metrics | grep otelcol_processor_dropped
```

### Identifying High-Cardinality Attributes

**Dangerous attributes** (unbounded cardinality):
- `user.id`, `session.id`, `request.id` — unique per request
- `db.statement` — unique SQL queries
- `url.full` — includes query params, unique per request
- `http.target` — with path params: `/users/123`, `/users/456`
- `error.message` — free-text, nearly unique

**Safe attributes** (bounded cardinality):
- `http.request.method` — ~9 values
- `http.response.status_code` — ~50 values
- `http.route` — `/users/{id}`, not `/users/123`
- `db.system` — postgresql, mysql, redis
- `db.operation.name` — SELECT, INSERT, UPDATE
- `rpc.service`, `rpc.method` — fixed set

### Fixes

**1. Use Metric Views to drop high-cardinality attributes**

```python
from opentelemetry.sdk.metrics.view import View

views = [
    View(
        instrument_name="http.server.duration",
        attribute_keys={"http.request.method", "http.response.status_code", "http.route"},
    ),
    View(
        instrument_name="db.client.duration",
        attribute_keys={"db.system", "db.operation.name"},
    ),
]
```

**2. Use Collector filter/transform processors**

```yaml
processors:
  transform:
    metric_statements:
      - context: datapoint
        statements:
          - delete_key(attributes, "user.id")
          - delete_key(attributes, "request.id")

  attributes/remove-high-card:
    actions:
      - key: url.full
        action: delete
      - key: db.statement
        action: hash
```

**3. Use `http.route` instead of `url.path`**

```python
# BAD: url.path = /users/abc-123-def (high cardinality)
# GOOD: http.route = /users/{userId} (low cardinality)
span.set_attribute("http.route", "/users/{userId}")
```

### Cardinality Budget

| Instrument | Max Attribute Combinations | Action if Exceeded |
|-----------|---------------------------|-------------------|
| Counter | < 2,000 | Drop attributes via View |
| Histogram | < 500 | Fewer buckets + fewer attributes |
| Gauge | < 1,000 | Aggregate or drop dimensions |

---

## Memory Leaks in Instrumentation

### Symptoms

- Application memory grows steadily over hours/days
- OOM kills in production
- Span count in memory keeps growing

### Common Causes and Fixes

**1. Spans never ended**

```python
# LEAK: span started but never ended
span = tracer.start_span("operation")
# ... exception thrown, span.end() never called

# FIX: always use context manager
with tracer.start_as_current_span("operation") as span:
    do_work()  # span.end() called automatically
```

```javascript
// LEAK: span.end() not called in error path
const span = tracer.startSpan('operation');
try {
  await doWork();
  span.end();
} catch (err) {
  // span.end() NOT called!
  throw err;
}

// FIX: use startActiveSpan with finally
tracer.startActiveSpan('operation', async (span) => {
  try {
    await doWork();
  } finally {
    span.end();
  }
});
```

**2. SimpleSpanProcessor in production**

```python
# LEAK-PRONE: SimpleSpanProcessor blocks and buffers
provider.add_span_processor(SimpleSpanProcessor(exporter))

# FIX: Always use BatchSpanProcessor in production
provider.add_span_processor(BatchSpanProcessor(
    exporter,
    max_queue_size=4096,
    max_export_batch_size=512,
    schedule_delay_millis=5000,
))
```

**3. Unbounded metric attributes causing memory growth**

```python
# Each unique attribute combination creates a new time series in memory
# 1M unique user IDs = 1M time series in memory
counter.add(1, {"user.id": user_id})  # Memory grows forever

# FIX: use bounded attributes only
counter.add(1, {"http.method": method, "http.route": route})
```

**4. Collector tail_sampling buffer too large**

```yaml
# Memory grows with num_traces * spans_per_trace
processors:
  tail_sampling:
    num_traces: 1000000    # Too high — ~4GB+ memory
    decision_wait: 120s    # Too long — more traces buffered

# FIX: reduce buffer and wait time
    num_traces: 100000
    decision_wait: 30s
```

**5. Event/attribute accumulation on long-lived spans**

```python
# LEAK: long-lived span accumulates events indefinitely
with tracer.start_as_current_span("long_running_job") as span:
    for item in million_items:
        span.add_event("processed", {"item.id": item.id})
        # ^ Accumulates 1M events in memory

# FIX: create child spans instead
with tracer.start_as_current_span("long_running_job") as parent:
    for batch in chunk(items, 100):
        with tracer.start_as_current_span("process_batch") as child:
            child.set_attribute("batch.size", len(batch))
            process(batch)
```

---

## Collector Pipeline Debugging

### Collector Internal Metrics

The Collector exposes metrics about its own health at `http://collector:8888/metrics`:

```bash
# Key metrics to monitor
curl -s http://collector:8888/metrics | grep -E "^otelcol_" | head -30

# Receiver metrics — data coming in
otelcol_receiver_accepted_spans_total        # Spans accepted
otelcol_receiver_refused_spans_total         # Spans refused (backpressure)

# Processor metrics — data being processed
otelcol_processor_dropped_spans_total        # Spans dropped by processor
otelcol_processor_batch_send_size            # Batch sizes

# Exporter metrics — data going out
otelcol_exporter_sent_spans_total            # Successfully exported
otelcol_exporter_send_failed_spans_total     # Failed exports
otelcol_exporter_queue_size                  # Queue backlog
otelcol_exporter_queue_capacity              # Queue capacity
```

### Enable Debug Logging

```yaml
service:
  telemetry:
    logs:
      level: debug          # verbose — use temporarily
      # level: info         # normal
      encoding: json        # structured logs for easier parsing
    metrics:
      address: 0.0.0.0:8888
```

### Debug Exporter for Pipeline Inspection

```yaml
exporters:
  debug:
    verbosity: detailed     # normal | detailed
    sampling_initial: 5     # first N items logged at startup
    sampling_thereafter: 1  # every Nth item after

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/backend, debug]  # add debug alongside real exporter
```

### zpages Extension

```yaml
extensions:
  zpages:
    endpoint: 0.0.0.0:55679

# Access diagnostic pages:
# http://collector:55679/debug/tracez     — trace samples
# http://collector:55679/debug/pipelinez  — pipeline topology
# http://collector:55679/debug/extensionz — extension status
```

### Common Collector Issues

| Symptom | Metric to Check | Fix |
|---------|----------------|-----|
| Data not arriving | `receiver_accepted_spans = 0` | Check receiver endpoint, TLS, ports |
| Data arriving but not exported | `exporter_send_failed > 0` | Check exporter endpoint, auth, network |
| Backpressure / data loss | `receiver_refused_spans > 0` | Increase batch size, add replicas |
| OOM crashes | Memory usage via pprof | Add memory_limiter, reduce tail_sampling buffers |
| High CPU | Collector CPU metrics | Reduce transform complexity, add batch processor |

### pprof Extension for Profiling

```yaml
extensions:
  pprof:
    endpoint: 0.0.0.0:1777

# Profile memory usage
curl -s http://collector:1777/debug/pprof/heap > heap.prof
go tool pprof heap.prof

# Profile CPU
curl -s 'http://collector:1777/debug/pprof/profile?seconds=30' > cpu.prof
```

---

## Exporter Failures

### Symptoms

- `otelcol_exporter_send_failed_spans_total` increasing
- "connection refused" or "deadline exceeded" in Collector logs
- Backend shows gaps in data

### Diagnosis

```bash
# 1. Check exporter queue
curl -s http://collector:8888/metrics | grep queue_size
# If queue_size ≈ queue_capacity → backpressure, exports failing

# 2. Test backend connectivity from Collector
curl -v http://tempo:4317  # Should connect (gRPC)
curl -v http://tempo:4318/v1/traces  # HTTP endpoint

# 3. Check TLS issues
openssl s_client -connect backend:4317 -brief
```

### Common Exporter Issues and Fixes

**Connection refused**

```yaml
# Verify endpoint is correct and reachable
exporters:
  otlp:
    endpoint: "tempo:4317"        # gRPC — no http:// prefix
    # endpoint: "http://tempo:4318" # HTTP — needs http:// prefix
    tls:
      insecure: true              # For non-TLS internal connections
```

**Timeout / deadline exceeded**

```yaml
exporters:
  otlp:
    endpoint: "tempo:4317"
    timeout: 30s                  # Increase timeout
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000            # Buffer during outages
```

**Auth failures (401/403)**

```yaml
exporters:
  otlp:
    headers:
      Authorization: "Bearer ${env:OTEL_EXPORTER_AUTH_TOKEN}"
      X-Scope-OrgID: "tenant-1"  # Multi-tenant backends like Mimir
```

---

## SDK Initialization Ordering

### The Golden Rule

**OTel SDK must initialize before any application code that creates spans, metrics, or uses instrumented libraries.**

### Node.js

```bash
# CORRECT: --require loads tracing before app
node --require ./tracing.js app.js

# WRONG: import tracing after app modules
# app.js:
import express from 'express';       # Express loads first — NOT instrumented
import './tracing.js';                # Too late — monkey-patching won't work
```

```javascript
// tracing.js — must be loaded first
const { NodeSDK } = require('@opentelemetry/sdk-node');
const sdk = new NodeSDK({ ... });
sdk.start();
// Auto-instrumentation patches modules BEFORE they're imported by app code
```

### Python

```bash
# CORRECT: use opentelemetry-instrument wrapper
opentelemetry-instrument --service_name my-service python app.py

# CORRECT: programmatic setup at top of entrypoint
# app.py:
from tracing_setup import init_tracing
init_tracing()  # MUST be before any framework imports that should be instrumented
from flask import Flask  # Now Flask will be instrumented
```

### Java

```bash
# Agent — auto-instruments at JVM startup
java -javaagent:opentelemetry-javaagent.jar -jar app.jar

# Spring Boot — starter auto-configures if on classpath
# No ordering issues — Spring manages lifecycle
```

### Common Initialization Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| SDK init after app imports | Auto-instrumentation doesn't work | Use `--require` (Node) or instrument wrapper (Python) |
| Multiple TracerProviders | Duplicate/missing spans | Set global provider once |
| Missing shutdown hook | Spans lost on graceful shutdown | `process.on('SIGTERM', () => sdk.shutdown())` |
| MeterProvider set after instruments created | Metrics not exported | Create MeterProvider before any `meter.create_*` calls |
| Async SDK init without await | Race condition — early spans lost | Await `sdk.start()` or use sync init |

---

## Sampling Confusion

### "I set sampling to 10% but I see 0 traces"

```bash
# Check the actual sampler being used
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1

# ParentBased means:
# - If parent is sampled → child is sampled (regardless of ratio)
# - If parent is NOT sampled → child is NOT sampled
# - If NO parent (root span) → apply ratio (10%)

# If upstream always sends traceflags=00 (not sampled),
# ALL downstream spans will be dropped!

# Debug: temporarily set to always_on
export OTEL_TRACES_SAMPLER=always_on
```

### "Tail sampling keeps everything"

```yaml
# Tail sampling policies are OR — any matching policy keeps the trace
# If probabilistic is 100%, everything is kept regardless of other policies
policies:
  - name: baseline
    type: probabilistic
    probabilistic:
      sampling_percentage: 100  # ← This keeps EVERYTHING

# FIX: reduce baseline percentage
      sampling_percentage: 5
```

---

## Quick Diagnostic Commands

```bash
# === SDK Diagnostics ===
# Check if OTel env vars are set
env | grep OTEL_ | sort

# Test OTLP endpoint connectivity
grpcurl -plaintext otel-collector:4317 list
# or for HTTP
curl -sf http://otel-collector:4318/v1/traces -d '{}' -H 'Content-Type: application/json'

# === Collector Diagnostics ===
# Health check
curl -sf http://collector:13133/

# Internal metrics summary
curl -s http://collector:8888/metrics | grep -E "^otelcol_(receiver|exporter|processor)" | sort

# Accepted vs refused vs dropped
curl -s http://collector:8888/metrics | grep -E "(accepted|refused|dropped)_spans"

# Exporter queue status
curl -s http://collector:8888/metrics | grep "queue_size\|queue_capacity"

# === Backend Diagnostics ===
# Query Jaeger for recent traces
curl -s 'http://jaeger:16686/api/traces?service=my-service&limit=5' | jq '.data | length'

# Check Prometheus targets
curl -s http://prometheus:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# === Network Diagnostics ===
# Test gRPC connectivity
nc -zv otel-collector 4317
# Test HTTP connectivity
nc -zv otel-collector 4318
```
