---
name: prometheus-monitoring
description: >
  Guide for Prometheus monitoring: PromQL queries, metric instrumentation (counter, gauge, histogram, summary),
  alerting rules, recording rules, Alertmanager configuration (routing, grouping, inhibition, silencing),
  service discovery (Kubernetes, Consul, file-based, static), exporters, Pushgateway, federation,
  remote write/read, storage retention, and Grafana integration. Use when working with Prometheus server
  config, PromQL expressions, metrics collection, scrape targets, prometheus.yml, alertmanager.yml,
  or client libraries (Go, Python, Java, Node.js). Do NOT use for Datadog, New Relic, CloudWatch,
  Splunk, or vendor-specific APM tools. Do NOT use for general logging without Prometheus context.
  Do NOT use for Grafana-only dashboard design unrelated to Prometheus data sources.
---

# Prometheus Monitoring

## Architecture

Prometheus uses a pull-based model. The server scrapes `/metrics` endpoints at configured intervals.

**Core components:**
- **Prometheus Server** — scrapes targets, stores TSDB, evaluates rules, serves PromQL
- **Alertmanager** — deduplicates, groups, routes, and silences alerts; sends notifications
- **Pushgateway** — accepts pushed metrics from short-lived/batch jobs
- **Exporters** — expose metrics from third-party systems (node_exporter, blackbox_exporter, mysqld_exporter)
- **Client Libraries** — instrument application code (Go, Python, Java, Node.js)

**Data flow:** Targets expose metrics → Prometheus scrapes → TSDB stores → PromQL queries → Alertmanager routes alerts → Receivers notify.

## Metric Types

### Counter
Monotonically increasing value. Resets only on process restart. Use for requests, errors, bytes sent.
```
http_requests_total{method="GET", status="200"} 1027
```
Query with `rate()` or `increase()`, never raw value.

### Gauge
Value that goes up and down. Use for temperature, memory, queue size, active connections.
```
node_memory_MemAvailable_bytes 2.147483648e+09
```

### Histogram
Samples observations into configurable buckets. Exposes `_bucket`, `_count`, `_sum`. Use for latency, request size.
```
http_request_duration_seconds_bucket{le="0.1"} 500
http_request_duration_seconds_bucket{le="0.5"} 900
http_request_duration_seconds_bucket{le="+Inf"} 1000
http_request_duration_seconds_count 1000
http_request_duration_seconds_sum 250.5
```

### Summary
Calculates quantiles client-side. Cannot be aggregated across instances. Prefer histograms.

## Naming Conventions

Follow `<namespace>_<subsystem>_<name>_<unit>` pattern:
- Use snake_case: `http_request_duration_seconds`
- Append `_total` for counters: `http_requests_total`
- Append unit suffix: `_seconds`, `_bytes`, `_ratio`
- Use `_bucket`, `_count`, `_sum` for histograms (auto-generated)

**Label rules:** Use labels for dimensions, not metric name parts. Keep cardinality bounded — never use user_id, request_id, or unbounded values. Normalize URL paths to route templates.

## Instrumentation

### Go
```go
import (
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
    "github.com/prometheus/client_golang/prometheus/promhttp"
    "net/http"
)

var (
    httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
        Name: "myapp_http_requests_total",
        Help: "Total HTTP requests by method and status.",
    }, []string{"method", "status"})

    requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
        Name:    "myapp_http_request_duration_seconds",
        Help:    "HTTP request duration in seconds.",
        Buckets: []float64{0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
    }, []string{"method", "endpoint"})
)

func handler(w http.ResponseWriter, r *http.Request) {
    timer := prometheus.NewTimer(requestDuration.WithLabelValues(r.Method, r.URL.Path))
    defer timer.ObserveDuration()
    httpRequests.WithLabelValues(r.Method, "200").Inc()
    w.WriteHeader(http.StatusOK)
}

func main() {
    http.Handle("/metrics", promhttp.Handler())
    http.HandleFunc("/", handler)
    http.ListenAndServe(":8080", nil)
}
```

### Python
```python
from prometheus_client import Counter, Histogram, start_http_server
import time

REQUEST_COUNT = Counter('myapp_http_requests_total', 'Total HTTP requests', ['method', 'status'])
REQUEST_DURATION = Histogram('myapp_http_request_duration_seconds', 'Request duration',
                             ['method', 'endpoint'],
                             buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10])

def handle_request(method, endpoint):
    REQUEST_COUNT.labels(method=method, status='200').inc()
    with REQUEST_DURATION.labels(method=method, endpoint=endpoint).time():
        time.sleep(0.1)  # simulate work

if __name__ == '__main__':
    start_http_server(8000)
    while True:
        handle_request('GET', '/api/users')
        time.sleep(1)
```

### Node.js
```javascript
const client = require('prom-client');
const express = require('express');
const app = express();

const httpRequests = new client.Counter({
    name: 'myapp_http_requests_total',
    help: 'Total HTTP requests',
    labelNames: ['method', 'status']
});

const requestDuration = new client.Histogram({
    name: 'myapp_http_request_duration_seconds',
    help: 'Request duration in seconds',
    labelNames: ['method', 'endpoint'],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
});

app.use((req, res, next) => {
    const end = requestDuration.startTimer({ method: req.method, endpoint: req.path });
    res.on('finish', () => {
        httpRequests.inc({ method: req.method, status: res.statusCode });
        end();
    });
    next();
});

app.get('/metrics', async (req, res) => {
    res.set('Content-Type', client.register.contentType);
    res.end(await client.register.metrics());
});

app.listen(3000);
```

## PromQL Reference

### Selectors
```promql
http_requests_total                              # all series
http_requests_total{job="api"}                   # label match
http_requests_total{status=~"5.."}               # regex match
http_requests_total{method!="OPTIONS"}           # negative match
http_requests_total{job="api"}[5m]               # range vector (last 5 min)
http_requests_total{job="api"} offset 1h         # 1 hour ago
```

### Rate and Increase
```promql
rate(http_requests_total[5m])                    # per-second rate over 5m
irate(http_requests_total[5m])                   # instant rate (last 2 points)
increase(http_requests_total[1h])                # total increase over 1h
```
Set range ≥ 4× scrape interval for `rate()`. Use `rate()` for dashboards, `irate()` for volatile alerting.

### Aggregations
```promql
sum(rate(http_requests_total[5m])) by (service)          # total RPS per service
avg(node_cpu_seconds_total) by (instance)                # avg CPU per instance
topk(5, sum(rate(http_requests_total[5m])) by (endpoint))# top 5 endpoints
count(up == 1) by (job)                                  # count healthy targets
```

### Histogram Quantiles
```promql
# P99 latency across all instances
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))

# P95 latency per service
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))

# Apdex score (requests < 0.3s satisfied, < 1.2s tolerating)
(
  sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
  + sum(rate(http_request_duration_seconds_bucket{le="1.2"}[5m]))
) / 2 / sum(rate(http_request_duration_seconds_count[5m]))
```

### Useful Patterns
```promql
# Error rate percentage
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) * 100

# Saturation — disk almost full
(node_filesystem_size_bytes - node_filesystem_avail_bytes) / node_filesystem_size_bytes * 100 > 90

# Predict disk full in 4 hours
predict_linear(node_filesystem_avail_bytes[1h], 4 * 3600) < 0
```

## Recording Rules

Precompute expensive queries. Place in rule files loaded via `rule_files` in prometheus.yml.

```yaml
# rules/recording-rules.yml
groups:
  - name: http_recording_rules
    interval: 30s
    rules:
      - record: job:http_requests_total:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job)

      - record: job:http_request_duration_seconds:p99
        expr: histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))

      - record: job:http_error_ratio:rate5m
        expr: >
          sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)
          / sum(rate(http_requests_total[5m])) by (job)
```
Naming convention: `level:metric:operations` — e.g., `job:http_requests_total:rate5m`.

## Alerting Rules

```yaml
# rules/alerting-rules.yml
groups:
  - name: service_alerts
    rules:
      - alert: HighErrorRate
        expr: job:http_error_ratio:rate5m > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High error rate on {{ $labels.job }}"
          description: "Error rate is {{ $value | humanizePercentage }} for job {{ $labels.job }}."

      - alert: TargetDown
        expr: up == 0
        for: 3m
        labels:
          severity: warning
        annotations:
          summary: "Target {{ $labels.instance }} is down"

      - alert: DiskSpaceLow
        expr: >
          (node_filesystem_avail_bytes / node_filesystem_size_bytes) < 0.1
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Disk space below 10% on {{ $labels.instance }}"

      - alert: HighLatencyP99
        expr: job:http_request_duration_seconds:p99 > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "P99 latency above 2s on {{ $labels.job }}"
```
Always use `for` to prevent flapping. Reference recording rules in alert expressions for performance.

## Alertmanager Configuration

```yaml
# alertmanager.yml
global:
  resolve_timeout: 5m
  smtp_from: 'alerts@example.com'
  smtp_smarthost: 'smtp.example.com:587'

route:
  receiver: default-slack
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - receiver: pagerduty-critical
      match:
        severity: critical
      continue: false
    - receiver: slack-warnings
      match:
        severity: warning

receivers:
  - name: default-slack
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/T00/B00/XXX'
        channel: '#alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}'

  - name: pagerduty-critical
    pagerduty_configs:
      - service_key: '<PAGERDUTY_KEY>'

  - name: slack-warnings
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/T00/B00/YYY'
        channel: '#warnings'

inhibit_rules:
  - source_match:
      severity: critical
    target_match:
      severity: warning
    equal: ['alertname', 'cluster', 'service']
```

**Key concepts:** `group_by` combines alerts into one notification. `group_wait`/`group_interval`/`repeat_interval` control notification timing. `inhibit_rules` suppress warnings when critical fires. Silences via UI for maintenance.

## Prometheus Server Configuration

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: production
    region: us-east-1

rule_files:
  - 'rules/recording-rules.yml'
  - 'rules/alerting-rules.yml'

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node1:9100', 'node2:9100']

  - job_name: 'app'
    metrics_path: /metrics
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/ca.pem
    basic_auth:
      username: prom
      password_file: /etc/prometheus/password
    static_configs:
      - targets: ['app1:8080', 'app2:8080']
```

## Service Discovery

### File-Based
```yaml
scrape_configs:
  - job_name: 'file-sd'
    file_sd_configs:
      - files: ['/etc/prometheus/targets/*.json']
        refresh_interval: 30s
```
Target file format:
```json
[{"targets": ["host1:9090", "host2:9090"], "labels": {"env": "prod"}}]
```

### Kubernetes
```yaml
scrape_configs:
  - job_name: 'k8s-pods'
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
        replacement: ${1}:$1
```
Roles: `node`, `pod`, `service`, `endpoints`, `endpointslice`, `ingress`.

### Consul
```yaml
scrape_configs:
  - job_name: 'consul'
    consul_sd_configs:
      - server: 'consul:8500'
        services: ['web', 'api']
```

## Storage and Retention

Configure via CLI flags:
```
--storage.tsdb.path=/prometheus/data
--storage.tsdb.retention.time=30d
--storage.tsdb.retention.size=50GB
```

**Remote write** for long-term storage (Thanos, Cortex, VictoriaMetrics, Mimir):
```yaml
remote_write:
  - url: "https://mimir.example.com/api/v1/push"
    queue_config:
      capacity: 10000
      max_shards: 30
      max_samples_per_send: 5000
      batch_send_deadline: 5s
    headers:
      X-Scope-OrgID: tenant-1

remote_read:
  - url: "https://mimir.example.com/prometheus/api/v1/read"
    read_recent: true
```

## Federation

Hierarchical federation — a global Prometheus scrapes from regional instances:
```yaml
scrape_configs:
  - job_name: 'federate'
    honor_labels: true
    metrics_path: '/federate'
    params:
      'match[]':
        - '{job=~".+"}'
        - '{__name__=~"job:.*"}'
    static_configs:
      - targets:
          - 'prometheus-us:9090'
          - 'prometheus-eu:9090'
```
Federate only recording rules and aggregated metrics. Avoid federating raw high-cardinality series.

## Grafana Integration

Configure Prometheus as data source: URL `http://prometheus:9090`, access Server (proxy). Use `$__rate_interval` for `rate()`. Use template variables: `label_values(http_requests_total, service)`. Dashboard JSON can be version-controlled via provisioning API.

## Best Practices

1. **Instrument the four golden signals:** latency, traffic, errors, saturation (per Google SRE)
2. **Use recording rules** for any query used in dashboards or alerts
3. **Set `for` on all alerts** — minimum 3–5 minutes to prevent flapping
4. **Control cardinality** — monitor `prometheus_tsdb_head_series` and alert on growth
5. **Use `relabel_configs`** to drop unnecessary labels/targets before ingestion
6. **Validate configs:** `promtool check config prometheus.yml` and `promtool check rules rules/*.yml`
7. **Use Pushgateway only for batch jobs** — never for long-running services
8. **Monitor Prometheus itself:** `prometheus_tsdb_head_series`, `prometheus_rule_evaluation_duration_seconds`

## References

- **`references/promql-cookbook.md`** — Vector matching, subqueries, rate/irate/increase, histogram_quantile, label_replace/join, absent, anti-patterns, optimization, ready-made queries.
- **`references/troubleshooting.md`** — High cardinality, OOM, slow queries, scrape failures, staleness, WAL corruption, Alertmanager routing, federation, remote write.
- **`references/alerting-patterns.md`** — SLO-based alerts, multi-window burn-rate, routing trees, inhibition, silencing, templates, PagerDuty/Slack/webhook, fatigue prevention.

## Scripts

- **`scripts/setup-prometheus-stack.sh`** — Generate Docker Compose stack (Prometheus + Alertmanager + Grafana + Node Exporter + cAdvisor).
- **`scripts/check-cardinality.sh`** — Analyze TSDB cardinality: top series, label pairs, storage growth.
- **`scripts/validate-rules.sh`** — Validate recording/alerting rules with `promtool check rules`.

## Assets

- **`assets/prometheus.yml`** — Production config with service discovery, relabeling, remote write, TLS.
- **`assets/alertmanager.yml`** — Routing tree, Slack/PagerDuty/email/webhook receivers, inhibition rules.
- **`assets/recording-rules.yml`** — CPU, memory, disk, network, HTTP rates/latency, SLO burn rate windows.
- **`assets/alerting-rules.yml`** — Multi-window burn-rate SLO alerts, node health, disk prediction, self-monitoring.
- **`assets/docker-compose.yml`** — Full monitoring stack with health checks and persistent volumes.
