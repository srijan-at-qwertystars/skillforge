---
name: grafana-dashboards
description: >
  Create, configure, and provision Grafana dashboards and visualizations. Use when: building Grafana dashboards, configuring panels (time series, stat, gauge, table, heatmap, logs, geomap, bar chart), writing PromQL/LogQL queries for Grafana panels, setting up Grafana variables and templating, configuring Grafana annotations, creating Grafana alert rules with contact points and notification policies, provisioning dashboards via YAML/JSON, using Grafonnet jsonnet library or Terraform grafana provider for dashboard-as-code, organizing Grafana folders and permissions. Do NOT use when: configuring Prometheus server without Grafana involvement, building Datadog or New Relic dashboards, creating Kibana/OpenSearch visualizations, general metrics collection or instrumentation without dashboard context, configuring standalone alertmanager without Grafana unified alerting.
---

# Grafana Dashboards & Visualization

## Dashboard JSON Structure

Every Grafana dashboard is a JSON document. Set `id: null` for new dashboards; Grafana assigns it.

```json
{
  "id": null,
  "uid": "svc-overview-01",
  "title": "Service Overview",
  "tags": ["production", "backend"],
  "timezone": "browser",
  "editable": true,
  "graphTooltip": 1,
  "schemaVersion": 39,
  "version": 0,
  "time": { "from": "now-6h", "to": "now" },
  "refresh": "30s",
  "panels": [],
  "templating": { "list": [] },
  "annotations": { "list": [] },
  "links": []
}
```

Key fields: `uid` (unique string, stable across exports), `schemaVersion` (39+ for Grafana 11.x), `graphTooltip` (0=default, 1=shared crosshair, 2=shared tooltip).

## Panel Types & Configuration

### Grid Positioning

Every panel requires `gridPos`: `{ "x": 0, "y": 0, "w": 12, "h": 8 }`. Dashboard width is 24 units.

### Time Series Panel

```json
{
  "type": "timeseries",
  "title": "Request Rate",
  "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
  "datasource": { "type": "prometheus", "uid": "prometheus-main" },
  "targets": [{
    "expr": "sum(rate(http_requests_total{job=\"$job\"}[5m])) by (status_code)",
    "legendFormat": "{{status_code}}"
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "reqps",
      "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 }
    },
    "overrides": [{
      "matcher": { "id": "byName", "options": "500" },
      "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }]
    }]
  }
}
```

### Stat Panel

```json
{
  "type": "stat",
  "title": "Total Requests",
  "targets": [{ "expr": "sum(increase(http_requests_total{job=\"$job\"}[24h]))" }],
  "fieldConfig": {
    "defaults": {
      "unit": "short",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 10000 },
          { "color": "red", "value": 50000 }
        ]
      }
    }
  },
  "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background" }
}
```

### Gauge Panel

Set `options.showThresholdLabels: true` and `fieldConfig.defaults.min/max` for proper scaling. Use `unit` field for display (percent, bytes, etc.).

### Table Panel

```json
{
  "type": "table",
  "title": "Top Endpoints",
  "targets": [{
    "expr": "topk(10, sum(rate(http_requests_total[5m])) by (handler))",
    "format": "table", "instant": true
  }],
  "transformations": [
    { "id": "organize", "options": { "excludeByName": { "Time": true } } }
  ],
  "fieldConfig": {
    "overrides": [{
      "matcher": { "id": "byName", "options": "Value" },
      "properties": [{ "id": "custom.cellOptions", "value": { "type": "color-background" } }]
    }]
  }
}
```

### Logs Panel

```json
{
  "type": "logs",
  "title": "Application Logs",
  "datasource": { "type": "loki", "uid": "loki-main" },
  "targets": [{
    "expr": "{namespace=\"$namespace\", app=\"$app\"} |= \"$search\" | logfmt | level=~\"$level\"",
    "refId": "A"
  }],
  "options": { "showTime": true, "sortOrder": "Descending", "wrapLogMessage": true }
}
```

### Heatmap, Bar Chart, Geomap Panels

- **Heatmap**: `"type": "heatmap"`. Set `options.calculate: true` for raw data, `false` for pre-bucketed. Configure `options.yAxis.unit` and `color.scheme`.
- **Bar Chart**: `"type": "barchart"`. Set `options.orientation` ("horizontal"/"vertical"), `options.showValue`. Pair with instant queries and table format.
- **Geomap**: `"type": "geomap"`. Requires `latitude`/`longitude` fields or field mappings. Set `options.view.id` for map type.

## Queries

### PromQL Patterns for Dashboards

```
# Rate of counter
rate(http_requests_total{job="$job"}[$__rate_interval])

# Error ratio
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# Histogram quantile (p99 latency)
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job="$job"}[5m])) by (le))

# Aggregation with variable
sum by ($groupby) (rate(metric_name[$__rate_interval]))
```

Use `$__rate_interval` instead of hardcoded `[5m]` — it auto-adjusts to scrape interval. Use `$__interval` for non-rate aggregations.

### LogQL Patterns for Dashboards

```
# Filter and parse
{namespace="production", app="api"} |= "error" | json | line_format "{{.message}}"

# Metric query from logs (rate of errors)
sum(rate({app="api"} |= "error" [5m])) by (level)

# Pattern-based extraction
{job="nginx"} | pattern "<ip> - - <_> \"<method> <uri> <_>\" <status> <size>" | status >= 400
```

## Variables (Templating)

Define in `templating.list`. Variable types:

### Query Variable (dynamic from datasource)

```json
{
  "name": "namespace",
  "type": "query",
  "datasource": { "type": "prometheus", "uid": "prometheus-main" },
  "query": "label_values(kube_pod_info, namespace)",
  "refresh": 2,
  "sort": 1,
  "multi": true,
  "includeAll": true,
  "allValue": ".*"
}
```

`refresh`: 1=on dashboard load, 2=on time range change. `sort`: 0=disabled, 1=alpha asc, 2=alpha desc, 3=numeric asc.

### Chained Variables

Create dependency chains: namespace → service → pod.

```json
[
  { "name": "namespace", "query": "label_values(kube_pod_info, namespace)" },
  { "name": "service", "query": "label_values(kube_pod_info{namespace=\"$namespace\"}, service)" },
  { "name": "pod", "query": "label_values(kube_pod_info{namespace=\"$namespace\", service=\"$service\"}, pod)" }
]
```

### Custom Variable

```json
{ "name": "env", "type": "custom", "query": "production,staging,development", "current": { "text": "production", "value": "production" } }
```

### Interval Variable

```json
{ "name": "smoothing", "type": "interval", "query": "1m,5m,15m,30m,1h", "auto": true, "auto_count": 30, "auto_min": "10s" }
```

### Datasource Variable

```json
{ "name": "ds_prometheus", "type": "datasource", "query": "prometheus" }
```

Reference in panels: `"datasource": { "type": "prometheus", "uid": "$ds_prometheus" }`.

### Variable Syntax

Use `$var` for simple substitution, `${var}` mid-string, `${var:regex}` for regex-escaped, `${var:pipe}` for pipe-delimited multi-values, `${var:csv}` for comma-separated.

## Annotations

```json
{
  "annotations": {
    "list": [{
      "name": "Deployments",
      "datasource": { "type": "prometheus", "uid": "prometheus-main" },
      "expr": "changes(deploy_timestamp{app=\"$app\"}[1m]) > 0",
      "tagKeys": "app,version",
      "textFormat": "Deployed {{version}}",
      "iconColor": "blue",
      "enable": true
    }]
  }
}
```

## Dashboard Links

```json
{
  "links": [
    { "title": "Logs", "url": "/d/logs-dash/logs?var-app=$app", "type": "link", "icon": "doc", "targetBlank": false },
    { "title": "Related", "type": "dashboards", "tags": ["production"], "asDropdown": true }
  ]
}
```

## Provisioning

### Dashboard Provider (YAML)

Place in `provisioning/dashboards/`. Set `foldersFromFilesStructure: true` to mirror subdirectory layout as Grafana folders. Set `allowUiUpdates: false` to enforce file-based source of truth.

```yaml
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: Production
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

### Datasource Provisioning

Place in `provisioning/datasources/`. Set explicit `uid` values to match panel references. Use `access: proxy` (routes through Grafana backend).

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus-main
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      timeInterval: 15s
      httpMethod: POST
  - name: Loki
    type: loki
    uid: loki-main
    access: proxy
    url: http://loki:3100
```

For full provisioning schemas (datasource, alerting, contact points, notification policies) see `references/api-reference.md` and `assets/provisioning.template.yml`.

### Directory Layout

```
grafana/
  provisioning/
    dashboards/default.yaml
    datasources/datasources.yaml
    alerting/{rules,contact-points,policies}.yaml
  dashboards/
    infrastructure/{node-exporter,kubernetes}.json
    application/{api-overview,database}.json
```

## Alerting (Unified Alerting)

### Alert Rule Provisioning

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: platform-alerts
    folder: Alerts
    interval: 1m
    rules:
      - uid: high-error-rate
        title: High Error Rate
        condition: C
        data:
          - refId: A
            relativeTimeRange: { from: 300, to: 0 }
            datasourceUid: prometheus-main
            model:
              expr: sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))
              instant: true
          - refId: B
            relativeTimeRange: { from: 0, to: 0 }
            datasourceUid: __expr__
            model: { type: reduce, reducer: last, expression: A }
          - refId: C
            datasourceUid: __expr__
            model: { type: threshold, expression: B, conditions: [{ evaluator: { type: gt, params: [0.05] } }] }
        for: 5m
        labels:
          severity: critical
          team: backend
        annotations:
          summary: "Error rate above 5%"
          runbook_url: "https://wiki.example.com/runbooks/high-error-rate"
```

### Contact Points & Notification Policies

```yaml
# contact-points.yaml
apiVersion: 1
contactPoints:
  - orgId: 1
    name: platform-slack
    receivers:
      - uid: slack-receiver
        type: slack
        settings:
          url: https://hooks.slack.com/services/T00/B00/XXX
          recipient: "#alerts-platform"
---
# policies.yaml
apiVersion: 1
policies:
  - orgId: 1
    receiver: platform-slack
    group_by: [alertname, namespace]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - receiver: pagerduty-oncall
        matchers: [severity = critical]
      - receiver: email-team
        matchers: [team = database]
```

Route with `matchers` using label selectors. Set `continue: true` to evaluate sibling routes after match.

## Grafana as Code (Grafonnet)

Install with jsonnet-bundler: `jb init && jb install github.com/grafana/grafonnet/gen/grafonnet-latest@main`

```jsonnet
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

g.dashboard.new('Service Overview')
+ g.dashboard.withUid('svc-overview')
+ g.dashboard.withTags(['production'])
+ g.dashboard.withRefresh('30s')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.withVariables([
    g.dashboard.variable.query.new('namespace')
    + g.dashboard.variable.query.withDatasource('prometheus', 'prometheus-main')
    + g.dashboard.variable.query.queryTypes.withLabelValues('namespace', 'kube_pod_info'),
  ])
+ g.dashboard.withPanels(
  g.util.grid.makeGrid([
    g.panel.timeSeries.new('Request Rate')
    + g.panel.timeSeries.queryOptions.withDatasource('prometheus', 'prometheus-main')
    + g.panel.timeSeries.queryOptions.withTargets([
        g.query.prometheus.new('prometheus-main',
          'sum(rate(http_requests_total{namespace="$namespace"}[$__rate_interval])) by (status_code)')
        + g.query.prometheus.withLegendFormat('{{status_code}}'),
      ])
    + g.panel.timeSeries.standardOptions.withUnit('reqps'),
  ], panelWidth=12, panelHeight=8)
)
```

Build: `jsonnet -J vendor/ dashboard.jsonnet > dashboard.json`. For Terraform integration and full Grafonnet API reference, see `references/api-reference.md`.

## Best Practices

- One dashboard per service/domain. Avoid mega-dashboards with 30+ panels.
- Use folders: `Infrastructure/`, `Application/`, `Business/`, `Alerts/`.
- Tag consistently: environment, team, service. Use dashboard links for drill-downs.
- Limit to 15-20 panels per dashboard; each fires a separate query.
- Use `$__rate_interval` over hardcoded intervals. Set `instant: true` for stat/gauge/table.
- Avoid unbounded regex like `{__name__=~".*"}`; always scope with at least one label.
- Set `refresh` to 30s for ops, 5m+ for business dashboards.
- Repeat panels across variable values: set `"repeat": "instance"`, `"repeatDirection": "h"`, `"maxPerRow": 4`. For rows: set `"repeat"` on `"type": "row"`.
- Export: remove `id`, `version` before committing to Git. Keep `uid` stable.
- Use folder-level permissions for team access. See `references/advanced-patterns.md` for organization strategies.

## Reference Documents

### Advanced Patterns (`references/advanced-patterns.md`)

Deep-dive into complex dashboard configurations:
- **Complex PromQL**: Multi-window rate comparison, Apdex scores, SLO burn rates, subqueries, multi-quantile overlays
- **Multi-datasource dashboards**: Mixed datasource panels, cross-source joins with transformations
- **Variable chaining**: Deep chains (cluster→namespace→service→pod), formatting syntax, ad-hoc filters
- **Row/panel repeating**: Repeat per variable, nested repeat, grid layout control
- **Dynamic thresholds**: Absolute/percentage modes, threshold lines on time series
- **Value mappings**: Value, range, regex, and special (null/NaN/bool) mappings
- **Field overrides**: Matcher types, per-field styling, axis placement, stacking
- **Link patterns**: Data links with field/value variables, dashboard-level links, drill-downs
- **Embedded panels**: iframe embedding, public dashboards, required `grafana.ini` settings
- **Grafana Scenes**: SDK for building dynamic plugin-based dashboards, Scenes vs standard dashboards
- **Dashboard versioning**: Built-in history, Git-based workflows, JSON cleanup for VCS
- **Organization strategies**: Folder hierarchy, naming conventions, tag strategy, linking patterns
- **Transformations**: Merge, join, organize, filter, calculate, group, sort with chaining examples

### Troubleshooting (`references/troubleshooting.md`)

Systematic fixes organized by symptom:
- **Slow dashboards**: Panel count limits, query optimization checklist, browser performance
- **Missing data**: Diagnostic flowchart, format mismatches, stale variables, NaN handling
- **Variable failures**: Empty dropdowns, chained variable quoting, multi-value regex matchers
- **Provisioning errors**: File path/permission checks, UID collisions, `allowUiUpdates` behavior
- **Panel rendering**: Wrong visualization type, Y-axis issues, legend config, null value handling
- **Alerting problems**: Rules not firing, missing notifications, silence/mute checks, multi-dimensional alerts
- **Data source connections**: Prometheus/Loki-specific errors, proxy vs direct, TLS configuration
- **Permission issues**: Folder access, service account tokens, datasource permissions
- **Version migration**: Grafana 9→10→11→12 breaking changes, migration checklist
- **Diagnostics**: Query inspector, server metrics, database queries, Docker troubleshooting, profiling

### API Reference (`references/api-reference.md`)

Complete schema and API documentation:
- **Dashboard JSON model**: All top-level fields with types, full skeleton template
- **Panel schema**: Common fields, gridPos, fieldConfig (defaults + overrides), panel-type options (timeseries, stat, table, gauge, logs)
- **Target/query schema**: Prometheus target fields, Loki target, expression targets for alerts
- **Templating schema**: Variable types (query, custom, textbox, constant, interval, datasource, adhoc), field reference, Prometheus query functions
- **Annotation schema**: Datasource-backed annotations, built-in annotation config
- **Provisioning YAML**: Dashboard provider schema, datasource schema, alert rule/contact point/notification policy schemas
- **HTTP API**: Dashboard CRUD, folder management, datasource endpoints, alerting API, annotations, service accounts, search parameters
- **Grafonnet library**: Installation, dashboard/panel/query/variable functions, grid layout utility, build commands

## Scripts

### `scripts/setup-grafana.sh`

Starts Grafana via Docker with provisioning directories and initial datasources pre-configured. Supports `--port`, `--prometheus-url`, `--loki-url`, `--admin-password`, `--grafana-version` flags.

### `scripts/export-dashboards.sh`

Exports all dashboards from a running Grafana instance to JSON files organized by folder. Supports `--token`, `--strip-ids` (for VCS), and `--folder` filtering.

## Asset Templates

| Template | Description |
|----------|-------------|
| `assets/dashboard.template.json` | Production dashboard with stat panels (uptime, request rate, error rate, p99, instances, memory), time series (traffic, latency percentiles), table (top endpoints), and logs panel. Includes datasource variable, chained job/instance variables, annotations, and dashboard links. |
| `assets/provisioning.template.yml` | Complete provisioning config with Prometheus, Loki, and Tempo datasources plus dashboard file provider. Includes comments for PostgreSQL and team-specific provider configurations. |
| `assets/docker-compose.template.yml` | Full monitoring stack: Grafana + Prometheus + Loki + Promtail + Node Exporter + cAdvisor. Includes healthchecks, named volumes, supporting config file templates in comments. |

<!-- tested: pass -->
