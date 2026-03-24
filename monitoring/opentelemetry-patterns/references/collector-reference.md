# OpenTelemetry Collector Deep-Dive Reference

> Comprehensive reference for OTel Collector components, configuration, and deployment patterns.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Receivers](#receivers)
  - [OTLP Receiver](#otlp-receiver)
  - [Jaeger Receiver](#jaeger-receiver)
  - [Prometheus Receiver](#prometheus-receiver)
  - [Filelog Receiver](#filelog-receiver)
  - [Host Metrics Receiver](#host-metrics-receiver)
  - [Kafka Receiver](#kafka-receiver)
- [Processors](#processors)
  - [batch](#batch-processor)
  - [memory_limiter](#memory_limiter-processor)
  - [filter](#filter-processor)
  - [attributes](#attributes-processor)
  - [resource](#resource-processor)
  - [tail_sampling](#tail_sampling-processor)
  - [transform](#transform-processor)
  - [k8sattributes](#k8sattributes-processor)
  - [groupbytrace](#groupbytrace-processor)
- [Exporters](#exporters)
  - [OTLP Exporter](#otlp-exporter)
  - [Jaeger Exporter](#jaeger-exporter)
  - [Prometheus Exporter](#prometheus-exporter)
  - [Prometheus Remote Write Exporter](#prometheus-remote-write-exporter)
  - [Loki Exporter](#loki-exporter)
  - [Debug Exporter](#debug-exporter)
  - [File Exporter](#file-exporter)
  - [Loadbalancing Exporter](#loadbalancing-exporter)
- [Connectors](#connectors)
  - [spanmetrics](#spanmetrics-connector)
  - [count](#count-connector)
  - [routing](#routing-connector)
  - [forward](#forward-connector)
- [Extensions](#extensions)
  - [health_check](#health_check)
  - [pprof](#pprof)
  - [zpages](#zpages)
  - [basicauth](#basicauth)
  - [file_storage](#file_storage)
  - [bearertokenauth](#bearertokenauth)
- [Deployment Patterns](#deployment-patterns)
- [Distributions](#distributions)
- [Configuration Best Practices](#configuration-best-practices)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    OTel Collector                            │
│                                                             │
│  Receivers ──→ Processors ──→ Exporters                    │
│  (ingest)      (transform)    (output)                     │
│                                                             │
│  Connectors: bridge between pipelines (exporter→receiver)  │
│  Extensions: health, auth, storage (non-pipeline)          │
│                                                             │
│  service:                                                   │
│    pipelines:                                               │
│      traces:    receivers → processors → exporters          │
│      metrics:   receivers → processors → exporters          │
│      logs:      receivers → processors → exporters          │
│    extensions: [health_check, pprof]                        │
└─────────────────────────────────────────────────────────────┘
```

**Key concepts:**
- Each pipeline handles one signal type (traces, metrics, or logs)
- Components can appear in multiple pipelines with different configurations using `type/name` syntax (e.g., `otlp/traces`, `otlp/metrics`)
- Processor order within a pipeline matters — data flows left to right
- Connectors act as an exporter in one pipeline and receiver in another

---

## Receivers

### OTLP Receiver

The universal OTel receiver. Accepts traces, metrics, and logs over gRPC and HTTP.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        max_recv_msg_size_mib: 16        # Max message size (default 4)
        max_concurrent_streams: 100
        keepalive:
          server_parameters:
            max_connection_idle: 11s
            max_connection_age: 60s
        tls:
          cert_file: /certs/server.crt
          key_file: /certs/server.key
          client_ca_file: /certs/ca.crt    # mTLS
      http:
        endpoint: 0.0.0.0:4318
        cors:
          allowed_origins: ["https://*.example.com"]
          allowed_headers: ["*"]
          max_age: 7200
        tls:
          cert_file: /certs/server.crt
          key_file: /certs/server.key
```

**Endpoints:**
- gRPC: `<host>:4317` (default)
- HTTP traces: `<host>:4318/v1/traces`
- HTTP metrics: `<host>:4318/v1/metrics`
- HTTP logs: `<host>:4318/v1/logs`

### Jaeger Receiver

Accepts Jaeger-native protocols for migration scenarios.

```yaml
receivers:
  jaeger:
    protocols:
      grpc:
        endpoint: 0.0.0.0:14250
      thrift_http:
        endpoint: 0.0.0.0:14268
      thrift_compact:
        endpoint: 0.0.0.0:6831
      thrift_binary:
        endpoint: 0.0.0.0:6832
```

**Use case**: Migrating from Jaeger agents/clients to OTel — accept both formats during transition.

### Prometheus Receiver

Scrapes Prometheus-format metric endpoints.

```yaml
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: 'node-exporter'
          scrape_interval: 15s
          static_configs:
            - targets: ['localhost:9100']
              labels:
                cluster: production

        - job_name: 'kubernetes-pods'
          kubernetes_sd_configs:
            - role: pod
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
              action: replace
              target_label: __address__
              regex: (.+)
              replacement: ${1}:${2}

        - job_name: 'otel-collector'
          scrape_interval: 10s
          static_configs:
            - targets: ['localhost:8888']
```

**Notes:**
- Uses same `scrape_configs` syntax as Prometheus server
- Supports Kubernetes service discovery
- Converts Prometheus metrics to OTLP internally
- Does NOT support Prometheus recording rules or alerting rules

### Filelog Receiver

Tails and parses log files into OTLP log records.

```yaml
receivers:
  filelog:
    include:
      - /var/log/app/*.log
      - /var/log/syslog
    exclude:
      - /var/log/app/debug.log
    start_at: end                        # end | beginning
    include_file_name: true
    include_file_path: true
    poll_interval: 200ms
    max_concurrent_files: 1024
    encoding: utf-8

    # Multi-line log parsing (e.g., Java stack traces)
    multiline:
      line_start_pattern: '^\d{4}-\d{2}-\d{2}'

    # Operator pipeline for parsing
    operators:
      # Parse JSON logs
      - type: json_parser
        parse_from: body
        timestamp:
          parse_from: attributes.timestamp
          layout: '%Y-%m-%dT%H:%M:%S.%fZ'
        severity:
          parse_from: attributes.level
          mapping:
            error: [err, error, ERROR]
            warn: [warn, warning, WARN]
            info: [info, INFO]

      # Parse regex for non-JSON logs
      - type: regex_parser
        regex: '^(?P<timestamp>\S+) (?P<level>\S+) (?P<message>.*)'
        parse_from: body
        timestamp:
          parse_from: attributes.timestamp
          layout: '%Y-%m-%dT%H:%M:%S.%fZ'

      # Move parsed fields
      - type: move
        from: attributes.message
        to: body

    # Persistent offset tracking across restarts
    storage: file_storage/logs

extensions:
  file_storage/logs:
    directory: /var/lib/otelcol/file_storage
```

### Host Metrics Receiver

Collects system-level metrics from the host.

```yaml
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
      memory:
      disk:
      filesystem:
        exclude_mount_points:
          mount_points: ["/dev/*", "/proc/*", "/sys/*"]
          match_type: regexp
      load:
      network:
      paging:
      process:
        include:
          match_type: regexp
          names: ["java.*", "python.*", "node"]
```

### Kafka Receiver

Consume telemetry from Kafka topics.

```yaml
receivers:
  kafka:
    brokers: ["kafka:9092"]
    topic: otlp_spans
    encoding: otlp_proto
    group_id: otel-collector
    initial_offset: latest
    auth:
      sasl:
        username: ${env:KAFKA_USER}
        password: ${env:KAFKA_PASS}
        mechanism: SCRAM-SHA-256
```

---

## Processors

### batch Processor

Batches data before export to reduce network overhead. **Should always be last in processor chain.**

```yaml
processors:
  batch:
    send_batch_size: 8192          # Trigger export at N items
    send_batch_max_size: 16384     # Hard cap per batch
    timeout: 5s                    # Max wait before flushing
```

**Tuning guidelines:**
- High throughput: `send_batch_size: 8192`, `timeout: 5s`
- Low latency: `send_batch_size: 256`, `timeout: 1s`
- Cost optimization: `send_batch_size: 16384`, `timeout: 30s`

### memory_limiter Processor

Prevents OOM by applying backpressure when memory usage is high. **Should always be first in processor chain.**

```yaml
processors:
  memory_limiter:
    check_interval: 5s
    limit_mib: 4096                # Hard memory limit
    spike_limit_mib: 512           # Max spike allowed above limit
    limit_percentage: 80           # Alternative: % of total memory
    spike_limit_percentage: 15
```

**How it works:**
1. Monitors memory usage at `check_interval`
2. If usage exceeds `limit_mib - spike_limit_mib`, starts refusing data
3. When memory drops, resumes accepting data
4. Upstream receivers return errors → SDK retries

### filter Processor

Drop spans, metrics, or logs matching OTTL conditions.

```yaml
processors:
  # Filter traces
  filter/drop-health:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.route"] == "/healthz"'
        - 'attributes["http.route"] == "/readyz"'
        - 'name == "GET /favicon.ico"'

  # Filter metrics
  filter/drop-internal-metrics:
    error_mode: ignore
    metrics:
      metric:
        - 'name == "process.runtime.jvm.classes.loaded"'
        - 'HasAttrOnDatapoint("internal", true)'
      datapoint:
        - 'attributes["environment"] == "test"'

  # Filter logs
  filter/drop-debug-logs:
    error_mode: ignore
    logs:
      log_record:
        - 'severity_number < 9'    # Drop below INFO
        - 'IsMatch(body, "^DEBUG")'
```

### attributes Processor

Add, update, delete, or hash span/log attributes.

```yaml
processors:
  attributes/enrich:
    actions:
      # Add static attribute
      - key: deployment.cluster
        value: us-east-1
        action: insert

      # Delete sensitive data
      - key: http.request.header.authorization
        action: delete
      - key: http.request.header.cookie
        action: delete

      # Hash PII
      - key: db.statement
        action: hash

      # Extract from existing attribute
      - key: http.url
        pattern: '^https?://(?P<host>[^/]+)'
        action: extract
        # Creates attributes["host"] from the URL

      # Upsert — insert or update
      - key: environment
        value: ${env:DEPLOY_ENV}
        action: upsert
```

### resource Processor

Modify resource-level attributes.

```yaml
processors:
  resource/add-cluster:
    attributes:
      - key: k8s.cluster.name
        value: "prod-us-east"
        action: upsert
      - key: internal.collector.version
        action: delete
```

### tail_sampling Processor

Makes sampling decisions after the trace is complete. See [advanced-patterns.md](./advanced-patterns.md#tail-based-sampling-with-otel-collector) for detailed patterns.

```yaml
processors:
  tail_sampling:
    decision_wait: 30s
    num_traces: 200000
    expected_new_traces_per_sec: 5000
    policies:
      # Always keep errors
      - name: errors
        type: status_code
        status_code:
          status_codes: [ERROR]

      # Keep slow traces
      - name: slow-requests
        type: latency
        latency:
          threshold_ms: 2000

      # Keep specific operations
      - name: payments
        type: string_attribute
        string_attribute:
          key: service.name
          values: [payment-service]

      # Boolean attribute match
      - name: important
        type: boolean_attribute
        boolean_attribute:
          key: important
          value: true

      # OTTL condition
      - name: ottl-filter
        type: ottl_condition
        ottl_condition:
          span:
            - 'attributes["http.response.status_code"] >= 500'

      # Composite policy with rate limiting
      - name: composite
        type: composite
        composite:
          max_total_spans_per_second: 5000
          policy_order: [errors-sub, latency-sub, baseline-sub]
          composite_sub_policy:
            - name: errors-sub
              type: status_code
              status_code: { status_codes: [ERROR] }
            - name: latency-sub
              type: latency
              latency: { threshold_ms: 1000 }
            - name: baseline-sub
              type: probabilistic
              probabilistic: { sampling_percentage: 5 }
          rate_allocation:
            - policy: errors-sub
              percent: 50
            - policy: latency-sub
              percent: 30
            - policy: baseline-sub
              percent: 20

      # Baseline probabilistic
      - name: baseline
        type: probabilistic
        probabilistic:
          sampling_percentage: 10
```

**Important**: Tail sampling is memory-intensive. It must buffer all spans until the trace completes (or `decision_wait` expires). Use only in gateway Collectors.

### transform Processor

Uses OTTL for complex telemetry transformations.

```yaml
processors:
  transform/traces:
    error_mode: ignore
    trace_statements:
      - context: resource
        statements:
          - set(attributes["collector.name"], "gateway-us-east")

      - context: span
        statements:
          # Truncate long attributes
          - truncate_all(attributes, 512)
          # Hash sensitive data
          - set(attributes["db.statement"], SHA256(attributes["db.statement"]))
            where attributes["db.system"] == "postgresql"
          # Set status from HTTP code
          - set(status.code, STATUS_CODE_ERROR) where attributes["http.response.status_code"] >= 500
          # Rename attribute
          - set(attributes["http.method"], attributes["http.request.method"])
            where attributes["http.request.method"] != nil
          - delete_key(attributes, "http.request.method")

  transform/metrics:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(attributes["env"], "prod")
            where resource.attributes["deployment.environment"] == "production"

  transform/logs:
    error_mode: ignore
    log_statements:
      - context: log
        statements:
          # Parse JSON body into attributes
          - merge_maps(attributes, ParseJSON(body), "insert")
            where IsMatch(body, "^\\{")
          # Set severity from parsed level
          - set(severity_text, attributes["level"])
            where attributes["level"] != nil
          # Redact email addresses
          - replace_pattern(body, "\\b[\\w.-]+@[\\w.-]+\\.\\w+\\b", "[REDACTED_EMAIL]")
```

### k8sattributes Processor

Auto-enriches telemetry with Kubernetes metadata.

```yaml
processors:
  k8sattributes:
    auth_type: "serviceAccount"
    passthrough: false
    extract:
      metadata:
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.namespace.name
        - k8s.node.name
        - k8s.deployment.name
        - k8s.replicaset.name
        - k8s.container.name
      labels:
        - tag_name: app.label.component
          key: app.kubernetes.io/component
      annotations:
        - tag_name: app.annotation.version
          key: app.version
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.ip
```

### groupbytrace Processor

Groups spans by trace ID before processing. Required before tail_sampling for accurate decisions.

```yaml
processors:
  groupbytrace:
    wait_duration: 10s
    num_traces: 100000
```

---

## Exporters

### OTLP Exporter

Send data to any OTLP-compatible backend.

```yaml
exporters:
  # gRPC (recommended for performance)
  otlp/grpc:
    endpoint: tempo:4317
    tls:
      insecure: true                  # Non-TLS internal
    compression: gzip
    timeout: 30s
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
      storage: file_storage/otlp     # Persistent queue

  # HTTP (firewall-friendly)
  otlp/http:
    endpoint: https://otlp.vendor.com
    headers:
      Authorization: "Bearer ${env:API_KEY}"
    compression: gzip
    tls:
      cert_file: /certs/client.crt
      key_file: /certs/client.key
```

### Jaeger Exporter

**Deprecated** — use OTLP exporter to send to Jaeger (Jaeger supports OTLP natively since v1.35).

```yaml
exporters:
  # Preferred: OTLP to Jaeger
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true
```

### Prometheus Exporter

Exposes metrics as a Prometheus scrape endpoint.

```yaml
exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: otel                   # Prefix: otel_metric_name
    const_labels:
      cluster: prod-us-east
    send_timestamps: true
    metric_expiration: 5m
    resource_to_telemetry_conversion:
      enabled: true                   # Resource attrs → metric labels
    enable_open_metrics: true
```

### Prometheus Remote Write Exporter

Pushes metrics to Prometheus-compatible remote write endpoints (Mimir, Thanos, Cortex).

```yaml
exporters:
  prometheusremotewrite:
    endpoint: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: "tenant-1"
    tls:
      insecure: true
    resource_to_telemetry_conversion:
      enabled: true
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
      queue_size: 10000
```

### Loki Exporter

Send logs to Grafana Loki.

```yaml
exporters:
  loki:
    endpoint: http://loki:3100/loki/api/v1/push
    headers:
      X-Scope-OrgID: "tenant-1"
    default_labels_enabled:
      exporter: true
      job: true
      instance: true
      level: true
    labels:
      attributes:
        service.name: "service"
        severity: "level"
      resource:
        deployment.environment: "env"
```

### Debug Exporter

Logs telemetry to stdout for debugging.

```yaml
exporters:
  debug:
    verbosity: detailed    # basic | normal | detailed
    sampling_initial: 5
    sampling_thereafter: 200
```

### File Exporter

Write telemetry to files (useful for archival or offline analysis).

```yaml
exporters:
  file:
    path: /var/log/otel/traces.jsonl
    rotation:
      max_megabytes: 100
      max_days: 7
      max_backups: 5
    format: json           # json | proto
    compression: zstd
```

### Loadbalancing Exporter

Distributes traces by trace ID to downstream Collectors for tail sampling.

```yaml
exporters:
  loadbalancing:
    routing_key: traceID
    protocol:
      otlp:
        timeout: 1s
        tls:
          insecure: true
    resolver:
      dns:
        hostname: otel-gateway-headless
        port: 4317
      # or k8s:
      # k8s:
      #   service: otel-gateway
      #   ports:
      #     - 4317
```

---

## Connectors

### spanmetrics Connector

Generates RED metrics (Rate, Errors, Duration) from trace spans.

```yaml
connectors:
  spanmetrics:
    histogram:
      explicit:
        buckets: [2ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s]
    dimensions:
      - name: http.request.method
      - name: http.response.status_code
      - name: http.route
      - name: rpc.service
      - name: rpc.method
    exemplars:
      enabled: true
    exclude_dimensions: ["net.sock.peer.addr"]
    namespace: "traces.spanmetrics"
    metrics_flush_interval: 15s
    aggregation_temporality: "AGGREGATION_TEMPORALITY_CUMULATIVE"

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo, spanmetrics]    # spanmetrics as exporter
    metrics/spanmetrics:
      receivers: [spanmetrics]                 # spanmetrics as receiver
      exporters: [prometheusremotewrite]
```

### count Connector

Counts telemetry items by conditions — generates metrics from any signal.

```yaml
connectors:
  count:
    traces:
      spans:
        "trace.error.count":
          conditions:
            - status.code == 2
        "trace.span.count": {}
    logs:
      "log.error.count":
        conditions:
          - severity_number >= 17
      "log.total.count": {}
```

### routing Connector

Routes telemetry to different pipelines based on conditions.

```yaml
connectors:
  routing:
    default_pipelines: [traces/default]
    table:
      - statement: route() where resource.attributes["service.namespace"] == "critical"
        pipelines: [traces/high-priority]
      - statement: route() where attributes["http.route"] == "/healthz"
        pipelines: [traces/low-priority]
```

### forward Connector

Simple passthrough — useful for splitting/joining pipelines.

```yaml
connectors:
  forward: {}
```

---

## Extensions

### health_check

HTTP health endpoint for liveness/readiness probes.

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: "/health"
    tls:
      cert_file: /certs/server.crt
      key_file: /certs/server.key
    check_collector_pipeline:
      enabled: true
      interval: 5m
      exporter_failure_threshold: 5
```

```bash
# Kubernetes probes
livenessProbe:
  httpGet:
    path: /health
    port: 13133
readinessProbe:
  httpGet:
    path: /health
    port: 13133
```

### pprof

Go pprof profiling endpoint for performance debugging.

```yaml
extensions:
  pprof:
    endpoint: 0.0.0.0:1777
    block_profile_fraction: 0
    mutex_profile_fraction: 0
```

```bash
# Memory profile
go tool pprof http://collector:1777/debug/pprof/heap
# CPU profile (30 seconds)
go tool pprof http://collector:1777/debug/pprof/profile?seconds=30
# Goroutine dump
curl http://collector:1777/debug/pprof/goroutine?debug=2
```

### zpages

Built-in diagnostic pages for pipeline inspection.

```yaml
extensions:
  zpages:
    endpoint: 0.0.0.0:55679
```

**Pages:**
| Page | URL | Purpose |
|------|-----|---------|
| TraceZ | `/debug/tracez` | Recent trace samples by latency bucket |
| PipelineZ | `/debug/pipelinez` | Pipeline topology and component status |
| ExtensionZ | `/debug/extensionz` | Extension status |

### basicauth

HTTP basic auth for receivers.

```yaml
extensions:
  basicauth/server:
    htpasswd:
      file: /etc/otel/.htpasswd
      # or inline:
      # inline: |
      #   user1:$apr1$...hashed...
      #   user2:$apr1$...hashed...

  basicauth/client:
    client_auth:
      username: ${env:OTEL_USER}
      password: ${env:OTEL_PASS}

receivers:
  otlp:
    protocols:
      http:
        auth:
          authenticator: basicauth/server

exporters:
  otlp:
    auth:
      authenticator: basicauth/client
```

### file_storage

Persistent storage for queues and checkpoints (survive restarts).

```yaml
extensions:
  file_storage/queue:
    directory: /var/lib/otelcol/storage
    timeout: 10s
    compaction:
      on_start: true
      on_rebound: true
      directory: /tmp/otelcol-compaction

exporters:
  otlp:
    sending_queue:
      storage: file_storage/queue    # Persistent queue
```

### bearertokenauth

Bearer token authentication for receivers and exporters.

```yaml
extensions:
  bearertokenauth:
    token: ${env:OTEL_AUTH_TOKEN}
    # or from file:
    # filename: /var/run/secrets/token
```

---

## Deployment Patterns

### Agent Mode (DaemonSet)

Runs on every node, collects from local pods. Lightweight processing only.

```
Pod → localhost:4317 → Agent Collector
                         ├─ batch
                         ├─ memory_limiter
                         └─ export → Gateway / Backend
```

```yaml
# Agent config — minimal processing
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

processors:
  memory_limiter:
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    timeout: 5s
    send_batch_size: 4096
  k8sattributes:
    passthrough: true            # Just tag, don't resolve

exporters:
  loadbalancing:
    routing_key: traceID
    protocol:
      otlp:
        endpoint: otel-gateway-headless:4317
        tls: { insecure: true }
    resolver:
      dns:
        hostname: otel-gateway-headless

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, batch]
      exporters: [loadbalancing]
```

### Gateway Mode (Deployment)

Centralized Collector for heavy processing — tail sampling, spanmetrics, routing.

```
Agent Collectors → Gateway Collector (3+ replicas)
                     ├─ tail_sampling
                     ├─ spanmetrics
                     ├─ transform
                     └─ export → Backends
```

```yaml
# Gateway config — full processing
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }

processors:
  memory_limiter:
    limit_mib: 8192
    spike_limit_mib: 2048
  tail_sampling:
    decision_wait: 30s
    num_traces: 200000
    policies:
      - { name: errors, type: status_code, status_code: { status_codes: [ERROR] } }
      - { name: slow, type: latency, latency: { threshold_ms: 2000 } }
      - { name: baseline, type: probabilistic, probabilistic: { sampling_percentage: 10 } }
  batch:
    send_batch_size: 8192
    timeout: 5s

connectors:
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 50ms, 100ms, 500ms, 1s, 5s]
    dimensions:
      - name: http.request.method
      - name: http.response.status_code
    exemplars:
      enabled: true

exporters:
  otlp/tempo:
    endpoint: tempo:4317
    tls: { insecure: true }
  prometheusremotewrite:
    endpoint: http://mimir:9009/api/v1/push

extensions:
  health_check: {}
  pprof: { endpoint: 0.0.0.0:1777 }
  zpages: { endpoint: 0.0.0.0:55679 }

service:
  extensions: [health_check, pprof, zpages]
  pipelines:
    traces/ingest:
      receivers: [otlp]
      processors: [memory_limiter]
      exporters: [spanmetrics]                # metrics before sampling
    traces/sample:
      receivers: [otlp]
      processors: [memory_limiter, tail_sampling, batch]
      exporters: [otlp/tempo]
    metrics:
      receivers: [spanmetrics, otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite]
```

### Sidecar Mode

One Collector per pod — simplest for single-service debugging or isolation requirements.

```yaml
# Pod spec with sidecar
spec:
  containers:
    - name: app
      env:
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://localhost:4317"
    - name: otel-collector
      image: otel/opentelemetry-collector-contrib:latest
      ports:
        - containerPort: 4317
      volumeMounts:
        - name: otel-config
          mountPath: /etc/otelcol-contrib
```

### Full Architecture: Agent + Gateway

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   App Pod 1  │     │   App Pod 2  │     │   App Pod 3  │
│ ┌──────────┐ │     │ ┌──────────┐ │     │ ┌──────────┐ │
│ │   App    │ │     │ │   App    │ │     │ │   App    │ │
│ └────┬─────┘ │     │ └────┬─────┘ │     │ └────┬─────┘ │
│      │OTLP   │     │      │OTLP   │     │      │OTLP   │
│      ▼       │     │      ▼       │     │      ▼       │
│ ┌──────────┐ │     │ ┌──────────┐ │     │ ┌──────────┐ │
│ │Agent Coll│ │     │ │Agent Coll│ │     │ │Agent Coll│ │
│ └────┬─────┘ │     │ └────┬─────┘ │     │ └────┬─────┘ │
└──────┼───────┘     └──────┼───────┘     └──────┼───────┘
       │ loadbalancing      │                     │
       └────────────────────┼─────────────────────┘
                            ▼
              ┌─────────────────────────┐
              │  Gateway Collector(s)   │
              │  - tail_sampling        │
              │  - spanmetrics          │
              │  - transform            │
              └────────┬────────────────┘
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
     ┌────────┐  ┌──────────┐  ┌───────┐
     │ Tempo  │  │  Mimir   │  │ Loki  │
     │(traces)│  │(metrics) │  │(logs) │
     └────────┘  └──────────┘  └───────┘
```

---

## Distributions

| Distribution | Use Case | Includes |
|-------------|----------|----------|
| `otel/opentelemetry-collector` | Core only | OTLP receiver/exporter, basic processors |
| `otel/opentelemetry-collector-contrib` | Production | All community receivers, processors, exporters |
| `otel/opentelemetry-collector-k8s` | Kubernetes | K8s-specific components optimized |
| Custom (via OCB) | Vendor/custom | Build your own with `ocb` (OpenTelemetry Collector Builder) |

```bash
# Build custom distribution
ocb --config builder-config.yaml

# builder-config.yaml
dist:
  name: my-otel-collector
  output_path: ./dist
exporters:
  - gomod: go.opentelemetry.io/collector/exporter/otlpexporter v0.100.0
receivers:
  - gomod: go.opentelemetry.io/collector/receiver/otlpreceiver v0.100.0
processors:
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor v0.100.0
```

---

## Configuration Best Practices

### Processor Ordering

```yaml
# Correct order:
processors: [memory_limiter, filter, k8sattributes, transform, attributes, tail_sampling, batch]
#             ^first              ^middle                                                    ^last
# memory_limiter: FIRST — prevents OOM
# filter: EARLY — reduce volume before heavy processing
# transform/attributes: MIDDLE — enrich/modify data
# tail_sampling: LATE — needs complete traces
# batch: LAST — always batch before export
```

### Environment Variable Substitution

```yaml
# Reference env vars with ${env:VAR_NAME}
exporters:
  otlp:
    endpoint: ${env:OTEL_BACKEND_ENDPOINT}
    headers:
      Authorization: "Bearer ${env:OTEL_AUTH_TOKEN}"
```

### Configuration Validation

```bash
# Validate config before deploying
otelcol validate --config config.yaml
otelcol-contrib validate --config config.yaml
```

### Resource Limits (Kubernetes)

```yaml
resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "2"
    memory: "4Gi"

# Match memory_limiter to container limits
# limit_mib should be ~80% of container memory limit
# spike_limit_mib should be ~15% of limit_mib
```

### Multi-Tenant Configuration

```yaml
# Route by tenant header
processors:
  routing:
    from_attribute: X-Scope-OrgID
    table:
      - value: tenant-a
        exporters: [otlp/tenant-a]
      - value: tenant-b
        exporters: [otlp/tenant-b]
    default_exporters: [otlp/default]
```
