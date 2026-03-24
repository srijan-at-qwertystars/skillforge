---
name: grafana-dashboards
description: >
  USE when: creating/editing Grafana dashboards, panels, or visualizations; writing PromQL/LogQL/TraceQL queries for Grafana; configuring Grafana data sources (Prometheus, Loki, Tempo, Mimir); setting up Grafana alerting rules, notification policies, or contact points; provisioning dashboards via YAML/JSON/Terraform/grafonnet; building LGTM stack observability; configuring Grafana variables, transformations, or annotations; generating dashboard JSON models; optimizing Grafana performance or query caching.
  DO NOT USE when: instrumenting application code with OpenTelemetry SDKs (use opentelemetry skill); writing Prometheus recording rules or scrape configs without Grafana context; deploying standalone Loki/Tempo/Mimir without Grafana dashboards; building non-Grafana monitoring UIs (Datadog, New Relic, Kibana); general Kubernetes or Helm work unrelated to Grafana.
---

# Grafana Dashboards Skill (Grafana 11.x)

## Architecture

Core primitives: **Data sources** (backends Grafana queries — Prometheus, Loki, Tempo, Mimir, InfluxDB, Elasticsearch, PostgreSQL, MySQL, CloudWatch, Azure Monitor). **Dashboards** — containers of panels in a grid, identified by UID, stored as JSON. **Panels** — individual visualizations bound to queries. **Rows** — collapsible panel groupings. **Folders** — hierarchical organization with permissions (subfolders GA in 11.x). **Organizations** — tenant isolation boundary. **Explore** — ad-hoc query interface.

## Dashboard JSON Model

```json
{
  "uid": "abc123", "title": "Service Overview", "tags": ["production"],
  "timezone": "browser", "schemaVersion": 39, "editable": true,
  "graphTooltip": 1, "time": { "from": "now-6h", "to": "now" },
  "refresh": "30s", "templating": { "list": [] },
  "annotations": { "list": [] }, "panels": [], "links": []
}
```

Panel structure:

```json
{
  "id": 1, "type": "timeseries", "title": "Request Rate",
  "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
  "datasource": { "type": "prometheus", "uid": "prom-1" },
  "targets": [{
    "expr": "rate(http_requests_total{job=\"api\"}[5m])",
    "legendFormat": "{{method}} {{status}}", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "reqps",
      "thresholds": { "mode": "absolute", "steps": [
        { "color": "green", "value": null }, { "color": "red", "value": 1000 }
      ]}
    }, "overrides": []
  }, "options": {}
}
```

Set `graphTooltip` to `1` (shared crosshair) or `2` (shared tooltip). Use `"editable": false` for provisioned dashboards.

## Panel Types

| Type | `type` value | Use case |
|------|-------------|----------|
| Time series | `timeseries` | Trends, rates, gauges over time |
| Stat | `stat` | Single KPIs, sparklines |
| Gauge | `gauge` | Value vs min/max range |
| Bar chart | `barchart` | Categorical comparisons |
| Table | `table` | Tabular multi-column data |
| Logs | `logs` | Log streams (Loki) |
| Traces | `traces` | Trace waterfall (Tempo) |
| Heatmap | `heatmap` | Distribution over time |
| Geomap | `geomap` | Geographic data |
| Canvas | `canvas` | Custom interactive diagrams |
| Pie chart | `piechart` | Proportional data |
| Histogram | `histogram` | Frequency distribution |
| Text | `text` | Markdown documentation |
| Node graph | `nodeGraph` | Service dependency maps |

## Data Sources

Provision via YAML in `provisioning/datasources/`:

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      httpMethod: POST
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo-uid
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        - name: TraceID
          matcherRegex: "traceID=(\\w+)"
          url: "$${__value.raw}"
          datasourceUid: tempo-uid
  - name: Tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      tracesToLogsV2: { datasourceUid: loki-uid, filterByTraceID: true }
      nodeGraph: { enabled: true }
      serviceMap: { datasourceUid: prom-uid }
```

Supported types: `prometheus`, `loki`, `tempo`, `influxdb`, `elasticsearch`, `postgres`, `mysql`, `mssql`, `cloudwatch`, `grafana-azure-monitor-datasource`, `stackdriver`, `graphite`, `jaeger`, `zipkin`, `testdata`.

## Query Languages

### PromQL (Prometheus/Mimir)

```promql
sum by (service) (rate(http_requests_total[5m]))
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))
rate(http_requests_total{instance=~"$instance"}[${__rate_interval}])
```

Always use `$__rate_interval` instead of hardcoded intervals — accounts for scrape interval and resolution.

### LogQL (Loki)

```logql
{app="nginx", env="production"} |= "error" != "healthcheck"
{app="api"} | json | status >= 500 | line_format "{{.method}} {{.path}} {{.status}}"
sum(rate({app="api"} |= "error" [5m])) by (level)
{job="syslog"} | pattern "<_> <level> <msg>" | level="ERROR"
```

### TraceQL (Tempo)

```
{ span.http.method = "POST" && span.http.status_code >= 500 }
{ resource.service.name = "checkout" && duration > 2s }
```

### SQL (PostgreSQL, MySQL)

```sql
SELECT $__timeGroup(created_at, '1h') AS time, count(*) AS value, status AS metric
FROM orders WHERE $__timeFilter(created_at) GROUP BY time, status ORDER BY time
```

Macros: `$__timeFilter(col)`, `$__timeFrom()`, `$__timeTo()`, `$__timeGroup(col, interval)`, `$__unixEpochFilter(col)`.

## Variables

Types: `query` (from data source), `custom` (static CSV), `constant` (hidden fixed), `datasource` (pick data source), `interval` (time intervals), `textbox` (free text), `adhoc` (auto-filter by tag keys).

```json
{ "templating": { "list": [
  { "name": "datasource", "type": "datasource", "query": "prometheus" },
  { "name": "namespace", "type": "query",
    "datasource": { "uid": "${datasource}" },
    "query": "label_values(kube_pod_info, namespace)",
    "refresh": 2, "multi": true, "includeAll": true, "allValue": ".*" },
  { "name": "pod", "type": "query",
    "query": "label_values(kube_pod_info{namespace=~\"$namespace\"}, pod)",
    "refresh": 2, "multi": true, "includeAll": true },
  { "name": "interval", "type": "interval", "query": "1m,5m,15m,1h",
    "auto": true, "auto_min": "10s" },
  { "name": "env", "type": "custom", "query": "production,staging,development" },
  { "name": "cluster", "type": "constant", "query": "us-east-1" },
  { "name": "search", "type": "textbox" }
]}}
```

Chain variables by referencing `$parent_var` in child queries. Set `refresh: 1` (dashboard load) or `refresh: 2` (time range change). Use `${var:regex}` for regex-safe values, `${var:pipe}` for pipe-delimited.

## Transformations

Apply in panel config to reshape results. Execute in order — chain for complex reshaping:

- **Filter by name** / **Filter data by values**: include/exclude fields or rows
- **Group by**: aggregate (sum, mean, count, min, max)
- **Join by field**: merge queries on common field (outer/inner)
- **Organize fields**: reorder, rename, hide columns
- **Calculate field**: binary ops, reduce row, unary
- **Rename by regex**: batch rename with capture groups
- **Sort by**: order by field values
- **Partition by values**: split frame by unique values
- **Convert field type**: string↔number↔time
- **Merge** / **Concatenate fields**: combine frames
- **Format string** / **Transpose**: format values, pivot rows/columns

## Alerting (Unified Alerting)

### Alert Rules

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: sre-alerts
    folder: Infrastructure
    interval: 1m
    rules:
      - uid: high-error-rate
        title: High Error Rate
        condition: C
        data:
          - refId: A
            datasourceUid: prometheus-uid
            model:
              expr: sum(rate(http_requests_total{status=~"5.."}[5m]))
          - refId: B
            datasourceUid: prometheus-uid
            model:
              expr: sum(rate(http_requests_total[5m]))
          - refId: C
            datasourceUid: __expr__
            model:
              type: math
              expression: "$A / $B"
              conditions:
                - evaluator: { type: gt, params: [0.05] }
        for: 5m
        labels: { severity: critical, team: platform }
        annotations:
          summary: "Error rate above 5%"
          runbook_url: "https://wiki.internal/runbooks/high-error-rate"
```

### Contact Points

```yaml
apiVersion: 1
contactPoints:
  - orgId: 1
    name: platform-oncall
    receivers:
      - uid: slack-platform
        type: slack
        settings: { recipient: "#platform-alerts", token: "$SLACK_BOT_TOKEN" }
      - uid: pagerduty-platform
        type: pagerduty
        settings: { integrationKey: "$PD_KEY", severity: critical }
```

Supported: slack, pagerduty, email, webhook, teams, opsgenie, victorops, discord, telegram, googlechat, sns, kafka, line, threema, pushover, sensugo, oncall.

### Notification Policies

```yaml
apiVersion: 1
policies:
  - orgId: 1
    receiver: platform-oncall
    group_by: ['alertname', 'namespace']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - receiver: pagerduty-platform
        matchers: ['severity = critical']
      - receiver: slack-platform
        matchers: ['severity = warning']
        repeat_interval: 12h
```

### Silences and Mute Timings

Mute timings define recurring quiet windows:

```yaml
apiVersion: 1
muteTimes:
  - orgId: 1
    name: weekends
    time_intervals:
      - weekdays: ['saturday', 'sunday']
```

Reference in policies: `mute_time_intervals: ['weekends']`. Create ad-hoc silences via UI/API for maintenance.

## Dashboard Provisioning

### File-Based

```yaml
# provisioning/dashboards/default.yaml
apiVersion: 1
providers:
  - name: default
    folder: General
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

### API-Based

```bash
curl -X POST http://localhost:3000/api/dashboards/db \
  -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"dashboard":{"uid":"svc","title":"Service","panels":[]},"overwrite":true,"folderUid":"infra"}'
```

### Terraform

```hcl
resource "grafana_folder" "infra" { title = "Infrastructure" }
resource "grafana_dashboard" "svc" {
  folder      = grafana_folder.infra.id
  config_json = file("${path.module}/dashboards/service.json")
}
resource "grafana_data_source" "prom" {
  type = "prometheus"
  name = "Prometheus"
  url  = "http://prometheus:9090"
  json_data_encoded = jsonencode({ httpMethod = "POST" })
}
```

### Grafonnet (Jsonnet)

```jsonnet
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
g.dashboard.new('Service Overview')
+ g.dashboard.withUid('svc-overview')
+ g.dashboard.withRefresh('30s')
+ g.dashboard.withPanels([
  g.panel.timeSeries.new('Request Rate')
  + g.panel.timeSeries.queryOptions.withTargets([
    g.query.prometheus.new('prometheus', 'sum by (svc) (rate(http_requests_total[5m]))')
  ])
  + g.panel.timeSeries.standardOptions.withUnit('reqps')
  + g.panel.timeSeries.gridPos.withW(12) + g.panel.timeSeries.gridPos.withH(8),
])
```

Build: `jsonnet -J vendor dashboard.jsonnet > dashboard.json`

## LGTM Stack

| Component | Signal | Default Port |
|-----------|--------|-------------|
| Mimir | Metrics (Prometheus remote write) | 9009 |
| Loki | Logs (HTTP push / Promtail) | 3100 |
| Tempo | Traces (OTLP, Jaeger, Zipkin) | 3200 (HTTP), 4317 (gRPC) |
| Grafana | Visualization | 3000 |
| Alloy | Collection/routing (OTLP) | 4317, 4318 |

Flow: Apps → Alloy/OTel Collector → Loki/Mimir/Tempo → Grafana. Configure cross-references: exemplars in Prometheus → Tempo traces; derived fields in Loki → Tempo; Tempo service graph → Prometheus metrics.

## Annotations

```json
{ "annotations": { "list": [
  { "datasource": { "type": "grafana", "uid": "-- Grafana --" },
    "enable": true, "name": "Deployments", "iconColor": "blue",
    "target": { "matchAny": true, "tags": ["deploy"], "type": "tags" } }
]}}
```

Push via API: `POST /api/annotations` with `{"dashboardUID":"svc","time":1700000000000,"tags":["deploy"],"text":"v2.3.1"}`.

## Authentication

Configure in `grafana.ini`: OAuth (`[auth.github]`, `[auth.google]`, `[auth.generic_oauth]`), LDAP (`[auth.ldap]` + `ldap.toml`), SAML Enterprise (`[auth.saml]`). Prefer **service accounts** over legacy API keys — they support RBAC, token rotation, fine-grained permissions. Create via Administration → Service accounts.

## Performance

- Use `$__rate_interval` not hardcoded intervals
- Limit ≤20 panels per dashboard; split into linked dashboards
- Set refresh ≥30s in production; use `maxDataPoints` to cap samples (default 1500)
- Enable query caching: `jsonData.cacheLevel: "Low|Medium|High"` (Enterprise)
- Avoid `.*` regex in label matchers — use specific values
- Use `graphTooltip: 1` (shared crosshair) for correlated investigation
- Set `minInterval` on panels to prevent excessive data points

## Common Pitfalls

- **Hardcoded rate intervals**: Use `[$__rate_interval]` not `[5m]` — incorrect rates at different zoom
- **Variable refresh**: Use `refresh: 2` for time-dependent vars, `refresh: 1` for static label lists
- **Provisioned edits lost**: File-provisioned dashboards revert on scan unless `allowUiUpdates: true`
- **Panel ID conflicts**: Set `id: null` when copying panels for auto-assignment
- **Alert `for` duration**: Too short = flapping, too long = delayed notification
- **Proxy vs direct**: Use `access: proxy` (server-side) — `direct` exposes credentials to browser
- **Schema version**: Always export from running Grafana to get correct `schemaVersion`
- **Timezone**: Use `"utc"` for ops dashboards; `"browser"` varies per user
- **Multi-value vars**: Use `${var:pipe}` for `a|b|c`, `${var:regex}` for regex-safe matching

## Examples

### Input: "Create HTTP service health dashboard"

```json
{
  "uid": "http-health", "title": "HTTP Service Health",
  "tags": ["http", "sre"], "schemaVersion": 39, "graphTooltip": 1,
  "templating": { "list": [
    { "name": "job", "type": "query", "query": "label_values(up, job)", "refresh": 1 }
  ]},
  "panels": [
    { "id": 1, "type": "stat", "title": "Availability",
      "gridPos": { "x": 0, "y": 0, "w": 6, "h": 4 },
      "targets": [{ "expr": "avg(up{job=\"$job\"})", "refId": "A" }],
      "fieldConfig": { "defaults": { "unit": "percentunit",
        "thresholds": { "steps": [{"color":"red","value":null},{"color":"green","value":0.99}] }}}},
    { "id": 2, "type": "timeseries", "title": "Request Rate",
      "gridPos": { "x": 6, "y": 0, "w": 18, "h": 8 },
      "targets": [{ "expr": "sum by (status) (rate(http_requests_total{job=\"$job\"}[$__rate_interval]))",
        "legendFormat": "{{status}}", "refId": "A" }],
      "fieldConfig": { "defaults": { "unit": "reqps" } }},
    { "id": 3, "type": "heatmap", "title": "Latency Distribution",
      "gridPos": { "x": 0, "y": 8, "w": 24, "h": 8 },
      "targets": [{ "expr": "sum by (le) (rate(http_request_duration_seconds_bucket{job=\"$job\"}[$__rate_interval]))",
        "format": "heatmap", "refId": "A" }]}
  ]
}
```

### Input: "Add Loki error log panel"

```json
{
  "type": "logs", "title": "Application Errors",
  "datasource": { "type": "loki", "uid": "loki-1" },
  "targets": [{ "expr": "{app=\"$app\"} |= \"error\" | json | level=\"error\" | line_format \"{{.timestamp}} [{{.level}}] {{.message}}\"", "refId": "A" }],
  "options": { "showTime": true, "wrapLogMessage": true, "enableLogDetails": true, "sortOrder": "Descending", "dedupStrategy": "none" },
  "gridPos": { "x": 0, "y": 0, "w": 24, "h": 10 }
}
```

### Input: "Alert on high memory"

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: infra-memory
    folder: Infrastructure
    interval: 1m
    rules:
      - uid: high-memory
        title: High Memory Usage
        condition: B
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
          - refId: B
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator: { type: gt, params: [85] }
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "Memory usage above 85% on {{ $labels.instance }}"
```

---

## Additional Resources

### References

In-depth guides in `references/`:

| File | Topics |
|------|--------|
| `references/advanced-patterns.md` | Library panels, dashboard links & drilldowns, variable chaining, repeating panels/rows, mixed data sources, correlations, Grafana Scenes, plugin development, k6 integration, SLO/business/capacity dashboards |
| `references/troubleshooting.md` | Slow loading, query timeouts, data source errors, variable performance, alerting issues, notifications, provisioning conflicts, permissions, LDAP/OAuth, rendering, time zones, missing data, reverse proxy, upgrades |
| `references/promql-logql-guide.md` | PromQL deep dive (vectors, aggregation, rate/irate, histogram_quantile, recording rules, subqueries), LogQL (selectors, filters, parsers, metrics from logs, pattern matching), TraceQL, SQL macros, Flux |

### Scripts

Executable utilities in `scripts/`:

| Script | Purpose | Usage |
|--------|---------|-------|
| `scripts/grafana-init.sh` | Local Grafana + Docker setup with provisioned data sources | `./grafana-init.sh [prometheus\|loki\|postgres\|all]` |
| `scripts/dashboard-export.sh` | Export all dashboards as JSON organized by folder | `./dashboard-export.sh <URL> <API_KEY> [OUTPUT_DIR]` |
| `scripts/alert-rules-sync.sh` | Export/import/sync alert rules between instances | `./alert-rules-sync.sh sync <SRC_URL> <SRC_KEY> <TGT_URL> <TGT_KEY>` |

### Assets

Templates and configs in `assets/`:

| File | Description |
|------|-------------|
| `assets/docker-compose.yml` | Full LGTM stack (Grafana, Prometheus, Loki, Tempo) with node-exporter |
| `assets/dashboard-template.json` | Production dashboard with golden signals, variables, annotations, logs panel |
| `assets/provisioning/datasources.yml` | Prometheus + Loki + Tempo with exemplars, derived fields, trace-to-logs |
| `assets/provisioning/dashboards.yml` | File-based dashboard provisioning config |
| `assets/alert-rule-template.json` | Unified alerting: 3 alert rules, contact point, notification policy, mute timing |
