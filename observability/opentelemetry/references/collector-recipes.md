# OpenTelemetry Collector Recipes

## Table of Contents

- [Filtering Spans by Attribute](#filtering-spans-by-attribute)
- [Tail Sampling Processor](#tail-sampling-processor)
- [Routing to Multiple Backends](#routing-to-multiple-backends)
- [Transforming Metrics](#transforming-metrics)
- [Log Parsing with Filelog Receiver](#log-parsing-with-filelog-receiver)
- [Kubernetes Metadata Enrichment](#kubernetes-metadata-enrichment)
- [Health Check Extension](#health-check-extension)
- [Load Balancing Exporter](#load-balancing-exporter)
- [Collector Scaling Patterns](#collector-scaling-patterns)

---

## Filtering Spans by Attribute

Drop noisy spans to reduce storage costs without modifying application code.

### Drop Health Checks and Internal Probes

```yaml
processors:
  filter/drop-health:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.route"] == "/healthz"'
        - 'attributes["http.route"] == "/readyz"'
        - 'attributes["http.route"] == "/livez"'
        - 'attributes["http.target"] == "/metrics"'
        - 'name == "GET /favicon.ico"'
```

### Drop Spans by Service Name

```yaml
processors:
  filter/drop-noisy-services:
    error_mode: ignore
    traces:
      span:
        - 'resource.attributes["service.name"] == "internal-cron"'
        - 'resource.attributes["service.name"] == "log-shipper"'
```

### Keep Only Error Spans (aggressive cost reduction)

```yaml
processors:
  filter/errors-only:
    error_mode: ignore
    traces:
      span:
        - 'status.code != STATUS_CODE_ERROR'
```

### Drop Spans Below Duration Threshold

```yaml
processors:
  filter/drop-fast-spans:
    error_mode: ignore
    traces:
      span:
        - 'duration < 1000000'   # Drop spans under 1ms (value in nanoseconds)
```

### Pipeline Wiring

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, filter/drop-health, batch]
      exporters: [otlp/backend]
```

---

## Tail Sampling Processor

Production-grade tail sampling configuration for gateway Collectors.

### Complete Gateway Config

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 4096
    spike_limit_mib: 1024

  groupbytrace:
    wait_duration: 10s
    num_traces: 200000

  tail_sampling:
    decision_wait: 10s
    num_traces: 200000
    expected_new_traces_per_sec: 5000
    policies:
      # Policy 1: Always keep errors
      - name: errors
        type: status_code
        status_code:
          status_codes: [ERROR]

      # Policy 2: Always keep slow traces
      - name: slow-traces
        type: latency
        latency:
          threshold_ms: 2000

      # Policy 3: Always keep specific endpoints
      - name: critical-endpoints
        type: string_attribute
        string_attribute:
          key: http.route
          values:
            - /api/checkout
            - /api/payment
            - /api/auth/login
          enabled_regex_matching: false

      # Policy 4: Composite — sample 50% of DB-heavy traces
      - name: db-heavy-sample
        type: and
        and:
          and_sub_policy:
            - name: has-db-spans
              type: string_attribute
              string_attribute:
                key: db.system
                values: [postgresql, mysql, redis]
            - name: fifty-percent
              type: probabilistic
              probabilistic:
                sampling_percentage: 50

      # Policy 5: Baseline sampling for everything else
      - name: baseline
        type: probabilistic
        probabilistic:
          sampling_percentage: 5

  batch:
    send_batch_size: 8192
    timeout: 5s

exporters:
  otlp/backend:
    endpoint: tempo.observability:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, groupbytrace, tail_sampling, batch]
      exporters: [otlp/backend]
```

### Memory Sizing Formula

```
Required memory ≈ num_traces × avg_spans_per_trace × avg_span_bytes
Example: 200,000 × 5 × 2KB = ~2GB

Set container memory limit to 1.5× the calculated value.
Set memory_limiter.limit_mib to 80% of container memory.
```

---

## Routing to Multiple Backends

Send different signals or subsets to different backends.

### Route Traces and Metrics to Different Backends

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

exporters:
  otlp/tempo:
    endpoint: tempo.observability:4317
    tls:
      insecure: true

  otlp/loki:
    endpoint: loki.observability:3100
    tls:
      insecure: true

  prometheusremotewrite:
    endpoint: http://mimir.observability:9009/api/v1/push

  otlp/honeycomb:
    endpoint: api.honeycomb.io:443
    headers:
      x-honeycomb-team: ${env:HONEYCOMB_API_KEY}

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 2048
  batch:
    send_batch_size: 8192

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/tempo, otlp/honeycomb]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/loki]
```

### Route by Attribute (Routing Connector)

Send traces from different teams to different backends:

```yaml
connectors:
  routing:
    table:
      - statement: route() where resource.attributes["team"] == "payments"
        pipelines: [traces/payments]
      - statement: route() where resource.attributes["team"] == "platform"
        pipelines: [traces/platform]
    default_pipelines: [traces/default]

service:
  pipelines:
    traces/ingest:
      receivers: [otlp]
      processors: [memory_limiter]
      exporters: [routing]
    traces/payments:
      receivers: [routing]
      processors: [batch]
      exporters: [otlp/payments-backend]
    traces/platform:
      receivers: [routing]
      processors: [batch]
      exporters: [otlp/platform-backend]
    traces/default:
      receivers: [routing]
      processors: [batch]
      exporters: [otlp/default-backend]
```

---

## Transforming Metrics

Use the `transform` processor to reshape metrics before export.

### Rename Metrics

```yaml
processors:
  transform/rename:
    metric_statements:
      - context: metric
        statements:
          - set(name, "app.http.duration") where name == "http.server.request.duration"
          - set(description, "HTTP request duration in seconds") where name == "app.http.duration"
```

### Drop Unwanted Attributes from Metrics

```yaml
processors:
  transform/drop-attrs:
    metric_statements:
      - context: datapoint
        statements:
          - delete_key(attributes, "net.host.name")
          - delete_key(attributes, "net.host.port")
          - delete_key(attributes, "http.scheme")
          - delete_key(attributes, "url.full")
```

### Add Static Labels

```yaml
processors:
  transform/add-labels:
    metric_statements:
      - context: datapoint
        statements:
          - set(attributes["environment"], "production")
          - set(attributes["region"], "us-east-1")
```

### Convert Metric Types

```yaml
processors:
  transform/convert:
    metric_statements:
      - context: metric
        statements:
          # Convert monotonic sum to gauge (use cautiously)
          - set(type, METRIC_DATA_TYPE_GAUGE) where name == "process.cpu.time"
```

### Aggregate by Dropping Dimensions

```yaml
processors:
  # Use metricstransform for aggregation
  metricstransform:
    transforms:
      - include: http.server.request.duration
        action: update
        operations:
          - action: aggregate_labels
            aggregation_type: sum
            label_set:
              - http.request.method
              - http.response.status_code
              # Only keep these; everything else aggregated away
```

---

## Log Parsing with Filelog Receiver

Collect and parse application logs from files — essential for Kubernetes deployments.

### Kubernetes Container Logs

```yaml
receivers:
  filelog/k8s:
    include:
      - /var/log/pods/*/*/*.log
    exclude:
      - /var/log/pods/*/otc-container/*.log   # Don't collect own logs
    include_file_path: true
    include_file_name: false
    start_at: end                              # Don't replay old logs on restart
    retry_on_failure:
      enabled: true
    operators:
      # Parse CRI/Docker container log format
      - type: container
        id: container-parser

      # Extract severity from JSON logs
      - type: json_parser
        id: json-parser
        if: 'body matches "^\\{"'
        parse_from: body
        parse_to: attributes

      - type: severity_parser
        parse_from: attributes.level
        mapping:
          error: [err, error, ERROR, fatal, FATAL]
          warn: [warn, warning, WARN, WARNING]
          info: [info, INFO]
          debug: [debug, DEBUG, trace, TRACE]
```

### Structured Application Logs (JSON)

```yaml
receivers:
  filelog/app:
    include:
      - /var/log/app/*.log
    operators:
      - type: json_parser
        parse_from: body
        timestamp:
          parse_from: attributes.timestamp
          layout: '%Y-%m-%dT%H:%M:%S.%fZ'
        severity:
          parse_from: attributes.level
      # Extract trace context if present in log
      - type: trace_parser
        trace_id:
          parse_from: attributes.trace_id
        span_id:
          parse_from: attributes.span_id
```

### Multiline Log Parsing (Stack Traces)

```yaml
receivers:
  filelog/java:
    include:
      - /var/log/app/java-app.log
    multiline:
      line_start_pattern: '^\d{4}-\d{2}-\d{2}'   # New entry starts with date
    operators:
      - type: regex_parser
        regex: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) (?P<level>\w+) (?P<logger>\S+) - (?P<message>.*)'
        timestamp:
          parse_from: attributes.timestamp
          layout: '%Y-%m-%d %H:%M:%S.%f'
        severity:
          parse_from: attributes.level
```

---

## Kubernetes Metadata Enrichment

Attach pod, namespace, deployment, and label metadata to all telemetry signals.

### k8sattributes Processor Config

```yaml
processors:
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    filter:
      node_from_env_var: KUBE_NODE_NAME
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.pod.start_time
        - k8s.deployment.name
        - k8s.replicaset.name
        - k8s.statefulset.name
        - k8s.daemonset.name
        - k8s.job.name
        - k8s.cronjob.name
        - k8s.node.name
        - k8s.container.name
        - container.id
        - container.image.name
        - container.image.tag
      labels:
        - tag_name: app.kubernetes.io/name
          key: app.kubernetes.io/name
          from: pod
        - tag_name: app.kubernetes.io/version
          key: app.kubernetes.io/version
          from: pod
      annotations:
        - tag_name: release.track
          key: release-track
          from: pod
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.ip
      - sources:
          - from: connection
```

### Required RBAC for k8sattributes

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["apps"]
    resources: ["replicasets", "deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "watch", "list"]
```

### Injecting Node Name via Env Var (DaemonSet)

```yaml
env:
  - name: KUBE_NODE_NAME
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName
```

---

## Health Check Extension

Monitor Collector health for Kubernetes liveness/readiness probes.

### Configuration

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /health
    check_collector_pipeline:
      enabled: true
      exporter_failure_threshold: 5   # Unhealthy after 5 consecutive export failures

service:
  extensions: [health_check]
```

### Kubernetes Probe Config

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 13133
  initialDelaySeconds: 15
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /health
    port: 13133
  initialDelaySeconds: 5
  periodSeconds: 5
```

### Full Extension Stack

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679
  pprof:
    endpoint: 0.0.0.0:1777    # Go pprof for performance profiling

service:
  extensions: [health_check, zpages, pprof]
  telemetry:
    logs:
      level: info
    metrics:
      address: 0.0.0.0:8888   # Collector self-metrics for Prometheus
```

---

## Load Balancing Exporter

Distribute traces across multiple Collector gateways by trace ID — required for tail sampling.

### DNS-Based Discovery

```yaml
exporters:
  loadbalancing:
    routing_key: traceID
    protocol:
      otlp:
        timeout: 10s
        tls:
          insecure: true
    resolver:
      dns:
        hostname: otel-gateway-headless.observability.svc.cluster.local
        port: 4317
        interval: 5s     # Re-resolve DNS every 5s to pick up new pods
```

### Kubernetes Service Discovery

```yaml
exporters:
  loadbalancing:
    routing_key: traceID
    protocol:
      otlp:
        tls:
          insecure: true
    resolver:
      k8s:
        service: otel-gateway.observability
        ports:
          - 4317
```

### Static Backend List (non-Kubernetes)

```yaml
exporters:
  loadbalancing:
    routing_key: traceID
    protocol:
      otlp:
        tls:
          insecure: true
    resolver:
      static:
        hostnames:
          - gateway-1.example.com:4317
          - gateway-2.example.com:4317
          - gateway-3.example.com:4317
```

---

## Collector Scaling Patterns

### Pattern 1: Agent + Gateway (Recommended for Production)

```
┌─────────────┐     ┌─────────────────┐     ┌─────────┐
│ App Pod      │     │ Agent (DaemonSet)│     │ Gateway │
│ ──────────── │────▸│ • memory_limiter │────▸│ (Deploy)│────▸ Backend
│ OTel SDK     │     │ • batch          │     │ • tail  │
│ localhost:4317│     │ • resource attrs │     │ • filter│
└─────────────┘     └─────────────────┘     └─────────┘
```

**Agent config (per-node, lightweight):**

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
processors:
  memory_limiter:
    limit_mib: 512
  resource:
    attributes:
      - key: k8s.node.name
        value: ${env:KUBE_NODE_NAME}
        action: upsert
  batch:
    send_batch_size: 4096
    timeout: 2s
exporters:
  loadbalancing:
    routing_key: traceID
    resolver:
      dns:
        hostname: otel-gateway-headless
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [loadbalancing]
```

### Pattern 2: Sidecar (Low-Latency, Per-Pod)

Deploy a Collector container in each application pod. Best for:
- Applications requiring mTLS to Collector
- Latency-sensitive workloads
- Strong isolation requirements

Resource overhead: ~50-100MB per pod.

### Pattern 3: Horizontal Pod Autoscaler for Gateway

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: otel-gateway
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: otel-gateway
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 75
```

### Sizing Guidelines

| Throughput | Agent Memory | Gateway Memory | Gateway Replicas |
|---|---|---|---|
| < 10K spans/sec | 256MB | 1GB | 2 |
| 10-50K spans/sec | 512MB | 2GB | 3-5 |
| 50-200K spans/sec | 1GB | 4GB | 5-10 |
| > 200K spans/sec | 1GB | 8GB | 10+ |

Scale gateways horizontally. Always use headless service for DNS-based load balancing so new pods are discovered automatically.
