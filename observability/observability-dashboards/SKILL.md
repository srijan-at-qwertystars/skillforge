---
name: observability-dashboards
description:
  positive: "Use when user builds Grafana dashboards, asks about PromQL queries, LogQL, dashboard-as-code (Grafonnet/Terraform), panel types, variable templates, or observability visualization best practices."
  negative: "Do NOT use for Prometheus alerting rules (use prometheus-alerting skill), OpenTelemetry instrumentation (use opentelemetry-instrumentation skill), or Datadog/New Relic-specific features."
---

# Observability Dashboards

## Dashboard Design Principles

### Frameworks

Pick a signal framework per dashboard layer:

- **USE** (Utilization, Saturation, Errors) — infrastructure resources (CPU, memory, disk, network).
- **RED** (Rate, Errors, Duration) — user-facing services and APIs.
- **Four Golden Signals** (Latency, Traffic, Errors, Saturation) — Google SRE's superset covering both.

Alert on symptoms (RED/golden signals). Diagnose using causes (USE).

### Audience-Focused Design

- **Executive/business**: SLO compliance, error budget burn, uptime percentage. Use stat and gauge panels.
- **On-call SRE**: Golden signals, recent deploys, alert timeline. Optimize for 3 AM triage.
- **Developer**: Per-service RED metrics, trace exemplars, log panels. Link to source and runbooks.

### Drill-Down Hierarchy

Structure dashboards in layers:

1. **Fleet overview** — all services at a glance (stat panels, traffic heatmap).
2. **Service detail** — RED metrics, resource usage, dependencies for one service.
3. **Instance/pod** — per-replica metrics, logs, traces.

Link layers with dashboard links and data links. Every panel should answer one question.

## Grafana Fundamentals

### Core Concepts

- **Panel**: Single visualization bound to one or more queries.
- **Row**: Collapsible group of panels. Use rows to separate logical sections.
- **Variables**: Template values (dropdowns) that parameterize queries. Defined at dashboard level.
- **Annotations**: Event markers on time series (deploys, incidents, config changes).
- **Dashboard links**: Navigate between dashboards, passing variable values.
- **Data links**: Click a data point to jump to another dashboard, Explore, or external URL.
- **Time range**: Global or per-panel override. Default to 1h for operational dashboards.

### Layout

Grafana uses a 24-column grid. Standard widths:

- Full-width overview: 24 columns.
- Two-column layout: 12 + 12.
- Stat row: 4–6 columns per stat panel.

Place summary stats at top, detailed graphs below, logs at bottom.

## PromQL for Dashboards

### Rate and Counters

Always apply `rate()` or `increase()` to counters. Never plot raw counter values.

```promql
# Request rate per second (use 2-5x scrape interval for range)
sum(rate(http_requests_total{job="api"}[5m])) by (status_code)

# Error percentage
sum(rate(http_requests_total{status_code=~"5.."}[5m]))
/ sum(rate(http_requests_total[5m])) * 100

# Per-instance CPU usage
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

Use `rate()` for dashboards (smoothed). Reserve `irate()` for spike detection only.

### Histogram Quantiles

Always wrap `rate()` inside `histogram_quantile()` and preserve the `le` label:

```promql
# P95 latency
histogram_quantile(0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)

# P99 latency by service
histogram_quantile(0.99,
  sum by (le, service) (rate(http_request_duration_seconds_bucket[5m]))
)
```

### Aggregations

```promql
# Top 5 endpoints by request rate
topk(5, sum by (handler) (rate(http_requests_total[5m])))

# Memory usage ratio
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100

# Saturation: disk I/O utilization
rate(node_disk_io_time_seconds_total[5m])
```

### Recording Rules

Precompute expensive queries. Use naming convention `level:metric:operations`:

```yaml
groups:
  - name: service_red
    interval: 30s
    rules:
      - record: service:http_requests:rate5m
        expr: sum by (service) (rate(http_requests_total[5m]))
      - record: service:http_errors:ratio_rate5m
        expr: |
          sum by (service) (rate(http_requests_total{status_code=~"5.."}[5m]))
          / sum by (service) (rate(http_requests_total[5m]))
      - record: service:http_duration:p99_rate5m
        expr: |
          histogram_quantile(0.99,
            sum by (le, service) (rate(http_request_duration_seconds_bucket[5m]))
          )
```

Reference recording rules in dashboard queries for faster load times.

## LogQL

### Log Queries

```logql
# Basic stream selector with line filter
{job="api", namespace="prod"} |= "error" != "healthcheck"

# Regex line filter
{app=~"web-.*"} |~ "timeout|connection refused"

# JSON parser with label filter
{app="payments"} | json | level="error" | status_code >= 500

# Logfmt parser with duration filter
{job="gateway"} | logfmt | duration > 500ms

# Pattern parser for structured text logs
{job="nginx"} | pattern "<ip> - - [<timestamp>] \"<method> <path> <_>\" <status> <bytes>"

# Regexp parser to extract fields
{job="app"} | regexp "(?P<trace_id>[a-f0-9]{32})"
```

### Metric Queries

```logql
# Error log rate per service
sum by (service) (rate({job="api"} |= "error" [1m]))

# Count logs by level over time
sum by (level) (count_over_time({app="web"} | json [5m]))

# Quantile of extracted numeric field
quantile_over_time(0.95, {app="api"} | logfmt | unwrap duration_ms [5m]) by (endpoint)

# Bytes rate for volume monitoring
sum by (namespace) (bytes_rate({namespace=~".+"} [5m]))
```

### Pipeline Chaining

Chain stages with `|`. Order matters — filter early to reduce processing:

```logql
{job="api"}
  |= "request"
  | json
  | status_code >= 400
  | line_format "{{.method}} {{.path}} → {{.status_code}} ({{.duration}}ms)"
```

## Panel Types

Choose the panel type that matches the data and question:

| Panel | Use For | Example |
|-------|---------|---------|
| **Time series** | Trends over time | Request rate, latency, CPU |
| **Stat** | Single current value | Uptime %, active users, error count |
| **Gauge** | Value against a range | CPU usage 0–100%, disk fill |
| **Bar chart** | Categorical comparison | Requests by endpoint, errors by service |
| **Table** | Tabular data, top-N lists | Top slow queries, pod status list |
| **Heatmap** | Distribution over time | Latency distribution, request density |
| **State timeline** | State changes over time | Pod ready/not-ready, deploy status |
| **Logs** | Raw log lines | Application logs from Loki |
| **Node graph** | Service dependencies | Service mesh topology |
| **Traces** | Distributed trace spans | Request waterfall from Tempo |

### Panel JSON Snippet

```json
{
  "type": "timeseries",
  "title": "Request Rate",
  "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
  "targets": [{
    "expr": "sum(rate(http_requests_total{service=\"$service\"}[5m])) by (status_code)",
    "legendFormat": "{{status_code}}"
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "reqps",
      "custom": { "drawStyle": "line", "fillOpacity": 10 }
    }
  }
}
```

## Variables and Templates

### Query Variable

```json
{
  "name": "service",
  "type": "query",
  "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
  "query": "label_values(http_requests_total, service)",
  "refresh": 2,
  "multi": false,
  "includeAll": true
}
```

### Chained Variables

Create dependent dropdowns — second variable filters based on first:

```
# Variable: namespace
label_values(kube_pod_info, namespace)

# Variable: pod (depends on namespace)
label_values(kube_pod_info{namespace="$namespace"}, pod)
```

### Variable Types

- **Query**: Populated from data source (label values, metric names).
- **Custom**: Static list of values (e.g., `5m,15m,1h` for interval selection).
- **Datasource**: Switch between Prometheus instances.
- **Interval**: Auto-calculated or user-selected time interval (`$__interval`).
- **Text box**: Free-form user input for ad-hoc filtering.

### Multi-Value Usage

Enable `multi` and `includeAll` for multi-select. Use regex join in queries:

```promql
http_requests_total{service=~"$service"}
```

Grafana auto-expands `$service` to `svc1|svc2|svc3` when multiple values are selected.

## Dashboard Organization

- **Folders**: Group by team (`platform/`, `backend/`, `infra/`) or domain.
- **Tags**: Apply consistent tags — `production`, `slo`, `infrastructure`, `service:payments`.
- **Starring**: Star frequently used dashboards for quick access.
- **Home dashboard**: Set a fleet overview as the org home dashboard.
- **Playlists**: Rotate dashboards on wall monitors. Set 30–60s interval per slide.
- **Naming convention**: `[Team] Service — View` (e.g., `[Platform] API Gateway — Overview`).

## Dashboard-as-Code

### Grafonnet (Jsonnet)

```jsonnet
local grafana = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local dashboard = grafana.dashboard;
local prometheus = grafana.query.prometheus;
local timeSeries = grafana.panel.timeSeries;

dashboard.new('API Service Overview')
+ dashboard.withUid('api-overview')
+ dashboard.withTags(['api', 'production'])
+ dashboard.withPanels([
  timeSeries.new('Request Rate')
  + timeSeries.queryOptions.withTargets([
    prometheus.new('$datasource',
      'sum(rate(http_requests_total{service="$service"}[5m])) by (status_code)')
    + prometheus.withLegendFormat('{{status_code}}'),
  ])
  + timeSeries.standardOptions.withUnit('reqps')
  + timeSeries.panelOptions.withGridPos(h=8, w=12, x=0, y=0),
])
```

Compile: `jsonnet -J vendor dashboard.jsonnet > dashboard.json`

### Terraform Grafana Provider

```hcl
resource "grafana_folder" "platform" {
  title = "Platform"
}

resource "grafana_dashboard" "api_overview" {
  folder      = grafana_folder.platform.id
  config_json = file("${path.module}/dashboards/api-overview.json")
  overwrite   = true
}
```

### File Provisioning

Place dashboard JSON in provisioned directories:

```yaml
# /etc/grafana/provisioning/dashboards/default.yaml
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ''
    type: file
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

### CI/CD Pipeline

1. Store `.jsonnet` files in Git.
2. On PR: lint with `jsonnetfmt`, validate JSON schema.
3. On merge to main: compile Jsonnet → JSON, run `terraform apply` or push via Grafana HTTP API.
4. Tag releases for rollback capability.

## Alert Visualization

- **Threshold lines**: Add fixed thresholds to time series panels. Set `color: red` above SLO breach values.
- **Alert states**: Panels show green/amber/red borders when linked to Grafana alert rules.
- **Annotation markers**: Query alert state history as annotations to see when alerts fired/resolved.
- **Alert list panel**: Show active alerts in a dedicated panel on overview dashboards.

```json
{
  "fieldConfig": {
    "defaults": {
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 200 },
          { "color": "red", "value": 500 }
        ]
      }
    }
  }
}
```

## Common Dashboard Patterns

### Service Overview

Top row: stat panels for request rate, error rate, p99 latency, uptime.
Middle: time series for RED metrics broken down by endpoint.
Bottom: recent logs panel, deployment annotations.

### SLO Dashboard

- Stat panels: SLO target, current SLI value, error budget remaining %.
- Time series: error budget burn rate over 30d window.
- Gauge: error budget consumption (green < 80%, yellow < 95%, red ≥ 95%).

```promql
# Error budget remaining (30-day window, 99.9% SLO target)
1 - (
  sum(rate(http_requests_total{status_code=~"5.."}[30d]))
  / sum(rate(http_requests_total[30d]))
) / (1 - 0.999)
```

### Infrastructure Dashboard

- CPU, memory, disk, network per node (USE method).
- Pod restart counts, OOMKill events.
- Node readiness state timeline.

### On-Call Dashboard

- Alert list panel (active firing alerts).
- Recent deployments annotation overlay.
- Service map or node graph.
- Quick links to runbooks and incident management.

## Data Sources

| Source | Protocol | Use Case |
|--------|----------|----------|
| **Prometheus** | PromQL | Metrics (counters, gauges, histograms) |
| **Loki** | LogQL | Log aggregation and search |
| **Tempo** | TraceQL | Distributed traces |
| **Elasticsearch** | Lucene/KQL | Logs, APM, full-text search |
| **CloudWatch** | CloudWatch query | AWS service metrics and logs |
| **InfluxDB** | Flux/InfluxQL | Time series with high-cardinality tags |

### Mixed Queries

Use the `-- Mixed --` data source to combine queries from different sources in one panel. Set per-query data source UIDs. Useful for correlating metrics with deploy events or log counts.

## Performance

### Query Optimization

- Filter by labels early — reduce cardinality before aggregation.
- Use recording rules for queries repeated across dashboards.
- Set `$__rate_interval` instead of hardcoded ranges to auto-align with scrape intervals.
- Avoid `{__name__=~".+"}` or unbounded label matchers.

### Dashboard Settings

- **Max data points**: Set to panel width in pixels (default 1000). Lower values reduce query load.
- **Min interval**: Set to scrape interval or higher to avoid unnecessary granularity.
- **Time range limits**: Restrict max time range on heavy dashboards (e.g., 7d max).
- **Refresh interval**: 30s for operational, 5m for business dashboards. Avoid < 10s.
- **Caching**: Enable Grafana query caching or use Thanos/Cortex query-frontend caching.
- **Lazy loading**: Collapse rows to defer rendering off-screen panels.

## Sharing

- **Snapshots**: Point-in-time dashboard captures. Share internally without granting Grafana access.
- **Public dashboards**: Enable per-dashboard public access (read-only, no auth required).
- **Embedding**: Use `<iframe>` with auth token or public dashboard URL. Set `allow_embedding = true` in `grafana.ini`.
- **PDF reports**: Grafana Enterprise feature. Schedule email delivery of rendered dashboards.
- **JSON export**: Export dashboard JSON via UI or API (`GET /api/dashboards/uid/:uid`). Store in Git.
- **Grafana HTTP API**: Automate export/import with `curl`:

```bash
curl -H "Authorization: Bearer $GRAFANA_TOKEN" \
  "$GRAFANA_URL/api/dashboards/uid/api-overview" | jq '.dashboard' > export.json
```

## Anti-Patterns

Avoid these mistakes:

- **Too many panels**: Keep under 20 panels per dashboard. Split into linked dashboards instead.
- **No drill-down**: Every overview dashboard must link to detail dashboards. Dead-end dashboards waste time.
- **Vanity metrics**: Remove panels nobody acts on. If a panel never triggers investigation, delete it.
- **Dashboard sprawl**: Audit dashboards quarterly. Archive unused ones. Enforce folder/tag conventions.
- **Hardcoded filters**: Use variables instead of hardcoding `job="api"` in every query.
- **Missing units**: Always set `unit` in field config. Unlabeled Y-axes cause misinterpretation.
- **No annotations**: Mark deploys and config changes. Without context, spikes are mysteries.
- **Ignoring cardinality**: High-cardinality labels (user_id, request_id) in dashboard queries crash Prometheus.
- **Copy-paste dashboards**: Use Grafonnet or provisioning to generate consistent dashboards from templates.
- **Wall of graphs**: If every panel is a time series, rethink. Mix stat, gauge, table, and state timeline.
