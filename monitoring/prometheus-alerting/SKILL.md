---
name: prometheus-alerting
description: |
  Use when user configures Prometheus, writes PromQL queries, creates alerting rules, sets up recording rules, configures Alertmanager routing, or integrates Prometheus with Grafana or service discovery.
  Do NOT use for Datadog, CloudWatch, or other proprietary monitoring. Do NOT use for OpenTelemetry collector setup (use opentelemetry-instrumentation skill).
---

# Prometheus Monitoring & Alerting

## Metric Types

Use the correct type for each measurement:

- **Counter**: Monotonically increasing value. Use for requests served, errors emitted, bytes sent. Always apply `rate()` or `increase()` before graphing.
- **Gauge**: Value that goes up and down. Use for temperature, memory usage, queue depth, active connections.
- **Histogram**: Samples observations into configurable buckets. Use for request latency, response sizes. Enables `histogram_quantile()` aggregation.
- **Summary**: Client-side quantile calculation. Use only when you need precise quantiles from a single instance and cannot aggregate across instances. Prefer histograms in most cases.

## Metric Naming Conventions

Follow these rules for all custom metrics:

- Use snake_case: `http_requests_total`, `process_cpu_seconds_total`.
- Include unit as suffix: `_seconds`, `_bytes`, `_total`, `_info`, `_ratio`.
- Counters must end in `_total`.
- Use base units (seconds not milliseconds, bytes not kilobytes).
- Prefix with application/subsystem name: `myapp_http_requests_total`.

## Label Best Practices

- Keep label cardinality bounded. Never use user IDs, request IDs, session tokens, IP addresses, or timestamps as label values.
- Use labels for dimensions you will filter/aggregate on: `method`, `status_code`, `endpoint`, `instance`, `job`.
- Every unique label combination creates a new time series. Adding a label with 1000 values multiplies series count by 1000.
- Drop high-cardinality labels at scrape time with `metric_relabel_configs`:

```yaml
metric_relabel_configs:
  - source_labels: [pod_uid]
    action: labeldrop
  - source_labels: [__name__]
    regex: "expensive_metric_.+"
    action: drop
```

## PromQL Essentials

### Selectors

```promql
http_requests_total{method="GET", status="200"}   # exact match
http_requests_total{status=~"5.."}                 # regex match
http_requests_total{method!="OPTIONS"}             # negative match
http_requests_total{job="api"}[5m]                 # range vector
```

### Aggregation

```promql
sum by (method) (rate(http_requests_total[5m]))
avg without (instance) (node_memory_MemAvailable_bytes)
topk(5, sum by (endpoint) (rate(http_requests_total[5m])))
count by (job) (up)
```

### Key Functions

```promql
rate(http_requests_total[5m])                       # per-second rate (counters)
increase(http_requests_total[1h])                   # total increase (counters)
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
predict_linear(node_filesystem_avail_bytes[1h], 4 * 3600)  # predict 4h ahead
absent(up{job="payment-service"})                   # detect missing series
clamp_min(free_disk_bytes, 0)
rate(http_requests_total[5m])[30m:1m]               # subquery
```

## Common PromQL Patterns

### Error Rate (RED)

```promql
sum by (service) (rate(http_requests_total{status=~"5.."}[5m]))
  / sum by (service) (rate(http_requests_total[5m]))
```

### Saturation (USE)

```promql
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))  # CPU
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)      # memory
rate(node_disk_io_time_seconds_total[5m])                               # disk I/O
```

### Availability SLI

```promql
sum(rate(http_requests_total{status!~"5.."}[5m]))
  / sum(rate(http_requests_total[5m]))
```

## Recording Rules

Pre-compute expensive queries. Use the naming convention `level:metric:operations`.

```yaml
groups:
  - name: http_recording_rules
    interval: 30s
    rules:
      # Per-job request rate
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))
      # Per-job error ratio
      - record: job:http_errors:ratio5m
        expr: >
          sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
          / sum by (job) (rate(http_requests_total[5m]))
      # p99 latency per job
      - record: job:http_request_duration_seconds:p99_5m
        expr: >
          histogram_quantile(0.99,
          sum by (job, le) (rate(http_request_duration_seconds_bucket[5m])))

  - name: node_recording_rules
    rules:
      - record: instance:node_cpu_utilization:avg5m
        expr: >
          1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
      - record: instance:node_memory_utilization:ratio
        expr: >
          1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```

When to create recording rules:
- Expression is used in multiple alerts or dashboards.
- Query takes >1s on the Prometheus `/query` endpoint.
- Aggregation reduces cardinality significantly.
- Needed for federation (federate only recorded metrics to global Prometheus).

## Alerting Rules

```yaml
groups:
  - name: service_alerts
    rules:
      - alert: HighErrorRate
        expr: job:http_errors:ratio5m > 0.05
        for: 5m
        labels:
          severity: critical
          team: backend
        annotations:
          summary: "High error rate on {{ $labels.job }}"
          description: "Error rate is {{ printf \"%.1f\" (mul $value 100) }}% (threshold 5%)"
          runbook_url: "https://wiki.example.com/runbooks/high-error-rate"

      - alert: HighLatency
        expr: job:http_request_duration_seconds:p99_5m > 1.0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "p99 latency above 1s on {{ $labels.job }}"
          description: "Current p99: {{ printf \"%.2f\" $value }}s"

      - alert: TargetDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.job }}/{{ $labels.instance }} is down"

      - alert: PrometheusTargetMissing
        expr: absent(up{job="payment-service"})
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Payment service target missing entirely"

      - alert: DiskWillFillIn4Hours
        expr: predict_linear(node_filesystem_avail_bytes[1h], 4 * 3600) < 0
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Disk on {{ $labels.instance }} predicted full within 4h"

      - alert: HighMemoryUsage
        expr: instance:node_memory_utilization:ratio > 0.9
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Memory usage above 90% on {{ $labels.instance }}"
```

### Alerting Rule Guidelines

- Set `for` duration to avoid flapping. Use 5m minimum for warnings, 2-3m for critical.
- Always include `severity` label for routing.
- Always include `runbook_url` annotation.
- Use recording rules in alert expressions for readability and performance.
- Template annotations with `{{ $labels.field }}` and `{{ $value }}`.
- Validate with `promtool check rules rules.yml`.

## Alertmanager Configuration

```yaml
global:
  resolve_timeout: 5m
  slack_api_url: "https://hooks.slack.com/services/XXX"

route:
  receiver: fallback-email
  group_by: [alertname, cluster, namespace]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - match:
        severity: critical
      receiver: pagerduty-oncall
      group_wait: 10s
      repeat_interval: 1h
    - match:
        severity: warning
      receiver: slack-warnings
      repeat_interval: 12h
    - match_re:
        team: "backend|platform"
      receiver: team-slack
      continue: true

receivers:
  - name: fallback-email
    email_configs:
      - to: "oncall@example.com"
        send_resolved: true

  - name: pagerduty-oncall
    pagerduty_configs:
      - service_key_file: /etc/alertmanager/pagerduty-key
        severity: '{{ if eq .CommonLabels.severity "critical" }}critical{{ else }}warning{{ end }}'

  - name: slack-warnings
    slack_configs:
      - channel: "#alerts-warning"
        send_resolved: true
        title: '{{ .CommonAnnotations.summary }}'
        text: '{{ .CommonAnnotations.description }}'

  - name: team-slack
    slack_configs:
      - channel: "#team-{{ .CommonLabels.team }}-alerts"
        send_resolved: true

inhibit_rules:
  # Suppress warnings when critical is firing for same alertname
  - source_matchers:
      - severity="critical"
    target_matchers:
      - severity="warning"
    equal: [alertname, namespace]

  # Suppress all alerts if cluster is down
  - source_matchers:
      - alertname="ClusterDown"
    target_matchers:
      - severity=~"warning|info"
    equal: [cluster]
```

### Alertmanager Best Practices

- Always define a fallback receiver to catch unmatched alerts.
- Use `group_by` with `[alertname, cluster, namespace]` to batch related alerts.
- Set `continue: true` on routes that should also match subsequent sibling routes.
- Use inhibition to suppress downstream alerts when root-cause alert is firing.
- Use silences for planned maintenance windows — do not disable alert rules.
- Tune `group_wait` (10-30s), `group_interval` (5m), `repeat_interval` (1-12h) per severity.

## Service Discovery

### Kubernetes SD

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Only scrape pods with annotation prometheus.io/scrape=true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      # Override metrics path from annotation
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      # Override port from annotation
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      # Map namespace and pod name to labels
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
```

### File SD

Use for targets managed by config management or custom scripts:

```yaml
scrape_configs:
  - job_name: file-targets
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/*.json
        refresh_interval: 5m
```

Target file format (`/etc/prometheus/targets/app.json`):

```json
[
  {
    "targets": ["app1:9090", "app2:9090"],
    "labels": { "env": "prod", "team": "backend" }
  }
]
```

### Consul SD

```yaml
scrape_configs:
  - job_name: consul-services
    consul_sd_configs:
      - server: consul.service.consul:8500
        services: []
    relabel_configs:
      - source_labels: [__meta_consul_service]
        target_label: job
      - source_labels: [__meta_consul_tags]
        regex: .*,prometheus,.*
        action: keep
      - source_labels: [__meta_consul_dc]
        target_label: datacenter
```

### Relabeling Cheat Sheet

| Action        | Purpose                                      |
|---------------|----------------------------------------------|
| `keep`        | Drop targets not matching regex              |
| `drop`        | Drop targets matching regex                  |
| `replace`     | Set target_label from source_labels          |
| `labelmap`    | Copy labels matching regex                   |
| `labeldrop`   | Remove labels matching regex                 |
| `labelkeep`   | Keep only labels matching regex              |
| `hashmod`     | Shard targets across Prometheus instances     |

## Grafana Dashboard Patterns

### Grafana Variable Templates

- `label_values(up, job)` — populate job dropdown.
- `label_values(node_uname_info{job="$job"}, instance)` — cascade instance from job.

### Panel Best Practices

- **Rate panels**: Always `rate()` or `irate()` on counters. Never graph raw counters.
- **Heatmaps**: Use `rate(metric_bucket[5m])` with format=heatmap for latency distributions.
- **Stat panels**: Use `avg_over_time(metric[1h])` for single-stat displays.
- **Layout**: Top row = SLIs (error rate, p99, throughput). Second row = saturation (CPU, mem, disk). Lower rows = detailed breakdowns.

## USE/RED Method Reference

### USE Method (Infrastructure)

For every resource (CPU, memory, disk, network):

| Signal       | Example PromQL                                                            |
|-------------|---------------------------------------------------------------------------|
| Utilization | `1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))`     |
| Saturation  | `node_load1 / count without(cpu)(count by(cpu,instance)(node_cpu_seconds_total{mode="idle"}))` |
| Errors      | `rate(node_disk_io_errors_total[5m])`                                     |

### RED Method (Services)

For every service endpoint:

| Signal   | Example PromQL                                                              |
|---------|-----------------------------------------------------------------------------|
| Rate    | `sum by(service)(rate(http_requests_total[5m]))`                            |
| Errors  | `sum by(service)(rate(http_requests_total{status=~"5.."}[5m]))`             |
| Duration| `histogram_quantile(0.99, sum by(le,service)(rate(http_request_duration_seconds_bucket[5m])))` |

## Cardinality Management

- Monitor series count: `prometheus_tsdb_head_series`.
- Find top offenders: `topk(10, count by (__name__)({__name__=~".+"}))`.
- Check TSDB status page: `/api/v1/status/tsdb` for per-metric and per-label cardinality.
- Set `sample_limit` per scrape job to cap ingestion.
- Use `metric_relabel_configs` to drop labels or entire metrics before storage.
- Use recording rules to pre-aggregate, then drop raw high-cardinality metrics.
- Alert on cardinality growth:

```yaml
- alert: HighCardinalityMetric
  expr: count by (__name__) ({__name__=~".+"}) > 50000
  for: 1h
  labels:
    severity: warning
  annotations:
    summary: "Metric {{ $labels.__name__ }} has {{ $value }} series"
```

## Anti-Patterns

### Missing `rate()` on Counters

```promql
# WRONG: graphs counter resets as drops
http_requests_total

# CORRECT: per-second rate
rate(http_requests_total[5m])
```

### High-Cardinality Labels

```promql
# WRONG: unbounded user_id label creates millions of series
http_requests_total{user_id="..."}

# CORRECT: use logs/traces for per-user data, metrics for aggregates
sum by (method, status) (rate(http_requests_total[5m]))
```

### Alerting on Raw Gauges Without Smoothing

```promql
# WRONG: fires on momentary spikes
node_memory_MemAvailable_bytes < 1e9

# CORRECT: average over window to smooth noise
avg_over_time(node_memory_MemAvailable_bytes[10m]) < 1e9
```

### Using `irate()` in Alerts

```promql
# WRONG: irate looks at only last two samples, too volatile for alerting
irate(http_requests_total[5m]) > 1000

# CORRECT: rate gives stable average over the window
rate(http_requests_total[5m]) > 1000
```

### Missing `for` Duration

```yaml
# WRONG: fires immediately on transient condition
- alert: HighCPU
  expr: instance:node_cpu_utilization:avg5m > 0.9

# CORRECT: require sustained condition
- alert: HighCPU
  expr: instance:node_cpu_utilization:avg5m > 0.9
  for: 10m
```

### Aggregating Without Specifying Labels

```promql
# WRONG: loses all labels, hard to identify source
sum(rate(http_requests_total[5m]))

# CORRECT: preserve labels needed for routing and debugging
sum by (job, method) (rate(http_requests_total[5m]))
```

<!-- tested: pass -->
