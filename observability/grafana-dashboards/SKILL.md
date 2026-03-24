---
name: grafana-dashboards
description: >
  Use when creating Grafana dashboards, panels, visualizations, provisioning dashboards as code,
  configuring data sources, templating variables, or alerting in Grafana. Covers dashboard JSON
  models, panel configuration, transformations, overrides, annotations, unified alerting, Grafonnet,
  Terraform provisioning, RBAC, and plugin development. Do NOT use for Prometheus query writing
  (use prometheus-monitoring skill), Kibana dashboards, Datadog dashboards, or general monitoring
  architecture without Grafana.
---

# Grafana Dashboards

## Dashboard JSON Model

Every Grafana dashboard is a JSON document. Understand the top-level structure:

```json
{
  "id": null,
  "uid": "abc123def",
  "title": "Service Overview",
  "tags": ["production", "backend"],
  "timezone": "browser",
  "editable": true,
  "graphTooltip": 1,
  "panels": [],
  "templating": { "list": [] },
  "annotations": { "list": [] },
  "time": { "from": "now-6h", "to": "now" },
  "refresh": "30s",
  "schemaVersion": 39,
  "version": 0,
  "links": [],
  "fiscalYearStartMonth": 0
}
```

Set `uid` explicitly for stable references across environments. Use `schemaVersion` matching your Grafana version. Set `graphTooltip: 1` for shared crosshair or `2` for shared tooltip across panels.

## Panel Types

Choose the right visualization for the data:

| Panel | Use Case |
|-------|----------|
| **Time series** | Metrics over time — lines, bars, points. Primary workhorse. |
| **Stat** | Single KPI with optional sparkline. Use for current value, total, or average. |
| **Gauge** | Value relative to min/max with thresholds (disk usage, CPU%). |
| **Bar gauge** | Horizontal/vertical bars with threshold coloring. Compare across instances. |
| **Table** | Tabular data, logs summary, multi-column detail views. |
| **Heatmap** | Distribution over time (latency buckets, request density). |
| **Histogram** | Statistical distribution of values across bins. |
| **Logs** | Log stream display. Integrates with Loki, Elasticsearch. |
| **Node graph** | Service dependency maps, trace topology, network graphs. |
| **Geomap** | Geospatial data on interactive maps. |
| **Canvas** | Free-form layout with custom elements, dynamic positioning. |

Panel JSON structure:

```json
{
  "type": "timeseries",
  "title": "Request Rate",
  "id": 1,
  "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
  "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
  "targets": [
    {
      "expr": "rate(http_requests_total{job=\"$job\"}[5m])",
      "legendFormat": "{{method}} {{status}}"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "reqps",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 500 },
          { "color": "red", "value": 1000 }
        ]
      }
    },
    "overrides": []
  },
  "options": {
    "tooltip": { "mode": "multi" },
    "legend": { "displayMode": "table", "placement": "bottom", "calcs": ["mean", "max"] }
  }
}
```

Use `gridPos` for layout: `w` max is 24. Standard row height is `h: 8`.

## Query Editors

Configure `targets` based on data source type:

**Prometheus**: Use `expr` with PromQL. Set `legendFormat` with `{{label}}` syntax. Use `$__rate_interval` for rate queries.

**Loki**: Use `expr` with LogQL. Set `queryType` to `range` or `instant`. Use line filters and label matchers.

**Elasticsearch**: Use `bucketAggs` and `metrics` arrays. Configure `timeField` and index pattern.

**InfluxDB**: Use Flux or InfluxQL via `query` field. Set `resultFormat` to `time_series` or `table`.

**MySQL/PostgreSQL**: Use raw SQL in `rawSql`. Reference `$__timeFilter(time_column)` and `$__timeGroup(time_column, $__interval)` macros.

**CloudWatch**: Set `namespace`, `metricName`, `dimensions`, `statistic`, and `period`.

## Templating Variables

Define variables in `templating.list` to make dashboards dynamic and reusable.

### Variable Types

**Query** — populate from data source:
```json
{
  "name": "instance",
  "type": "query",
  "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
  "query": "label_values(up{job=\"$job\"}, instance)",
  "refresh": 2,
  "multi": true,
  "includeAll": true,
  "sort": 1
}
```

**Custom** — static list: `"query": "us-east-1,us-west-2,eu-west-1"`, `"type": "custom"`.

**Interval** — time intervals: `"query": "1m,5m,15m,1h,6h,1d"`, `"type": "interval"`. Use `$__auto_interval_<name>` for auto.

**Datasource** — select data source at runtime: `"type": "datasource"`, `"query": "prometheus"`.

**Text box** — free-form input: `"type": "textbox"`, `"query": ""`.

**Constant** — hidden fixed value: `"type": "constant"`, `"query": "production"`, `"hide": 2`.

### Chaining and Multi-Value

Chain variables by referencing parent variables in child queries: `label_values(up{job="$job"}, instance)`. Set `refresh: 2` (on time range change) for dependent variables. For multi-value, use `multi: true` and format with `${variable:pipe}`, `${variable:regex}`, or `${variable:csv}` depending on data source requirements. Use `includeAll: true` with an `allValue` of `.*` for regex-based sources.

## Transformations

Apply transformations in the panel's Transform tab. Chain them — each processes the previous output:

- **Filter by name** — select fields by name or regex pattern
- **Filter by value** — include/exclude rows matching conditions (greater than, regex, null)
- **Organize fields** — rename, reorder, hide columns
- **Join by field** — SQL-like join on a shared field across queries (inner, outer)
- **Reduce** — collapse time series to single values (last, mean, max, min, count, sum)
- **Add field from calculation** — derive new fields (binary operations, unary, row index, percentage)
- **Group by** — aggregate rows by field values with sum, mean, count, min, max
- **Merge** — combine all query results into a single table
- **Series to rows** — convert each series into a table row for side-by-side comparison
- **Sort by** — order results by a field
- **Limit** — restrict number of rows returned
- **Concatenate fields** — combine frames into one

Order matters: filter first, then reduce, then organize for clean output.

## Overrides

### Field Overrides

Override defaults for specific fields in `fieldConfig.overrides`:

```json
{
  "overrides": [
    {
      "matcher": { "id": "byName", "options": "error_rate" },
      "properties": [
        { "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } },
        { "id": "custom.axisPlacement", "value": "right" },
        { "id": "unit", "value": "percentunit" }
      ]
    }
  ]
}
```

Matchers: `byName`, `byRegexp`, `byType`, `byFrameRefID`. Override any field config property: unit, decimals, color, axis, thresholds, display name.

### Value Mappings

Map raw values to display text/colors: `{ "type": "value", "options": { "0": { "text": "DOWN", "color": "red" }, "1": { "text": "UP", "color": "green" } } }`.

Types: `value` (exact match), `range` (numeric range), `regex` (pattern match), `special` (null, NaN, boolean).

### Thresholds

Define in `fieldConfig.defaults.thresholds`. Mode `absolute` for fixed values, `percentage` for relative. Steps are evaluated bottom-up — first matching step wins.

### Color Schemes

Set `fieldConfig.defaults.color.mode`: `fixed`, `palette-classic`, `continuous-GrYlRd`, `continuous-BlYlRd`, `thresholds`, `shades`. Use `thresholds` mode to color by threshold steps.

## Annotations

Mark events on time-series panels for contextual overlay.

**Native annotations** — manually added via UI, stored in Grafana database.

**Data source annotations** — query-driven:
```json
{
  "annotations": {
    "list": [
      {
        "name": "Deployments",
        "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
        "expr": "changes(deployment_timestamp{app=\"$app\"}[1m]) > 0",
        "enable": true,
        "iconColor": "#FF6600",
        "titleFormat": "Deploy: {{version}}",
        "tagKeys": "app,environment",
        "useValueForTime": false
      }
    ]
  }
}
```

**Tag filtering** — use `tagKeys` to add filterable tags. Users filter annotations by tag in the dashboard UI. Set `enable: false` to hide by default but allow toggle.

## Alerting

Grafana Unified Alerting (replaces legacy alerting since Grafana 9+):

### Alert Rules

Define conditions in Grafana-managed or data source-managed (Mimir/Loki) rules. Each rule specifies:
- Query and condition expressions (reduce + threshold or math)
- Evaluation group and interval
- For duration (pending period before firing)
- Labels for routing and grouping
- Annotations for notification content (`summary`, `description`, `runbook_url`)

### Contact Points

Define notification destinations: Email, Slack, PagerDuty, OpsGenie, Microsoft Teams, Discord, Webhook, Kafka, Google Chat, AWS SNS. Each contact point holds one or more integrations. Configure message templates using Go template syntax.

### Notification Policies

Route alerts to contact points using label matchers in a hierarchical tree:
- Default policy at root catches unmatched alerts
- Child policies match on labels (e.g., `team=platform`, `severity=critical`)
- Configure `group_by`, `group_wait`, `group_interval`, `repeat_interval`
- Use `continue: true` to evaluate sibling policies after a match

### Silences and Mute Timings

**Silences** — suppress specific alerts by matcher for a duration. Use for planned maintenance.

**Mute timings** — recurring schedules (weekends, holidays) when notifications are suppressed. Attach to notification policies.

## Dashboard Provisioning

### File-Based YAML

Place provider config in `provisioning/dashboards/`:

```yaml
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: 'Infrastructure'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

Place dashboard JSON files in the referenced path. Set `foldersFromFilesStructure: true` to auto-create folders matching directory structure.

### Grafana API

Use HTTP API for programmatic management:
```bash
curl -X POST http://localhost:3000/api/dashboards/db \
  -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"dashboard": {...}, "folderId": 0, "overwrite": true}'
```

### Terraform / Pulumi

```hcl
resource "grafana_dashboard" "service" {
  config_json = file("${path.module}/dashboards/service.json")
  folder      = grafana_folder.infra.id
  overwrite   = true
}

resource "grafana_folder" "infra" {
  title = "Infrastructure"
}
```

Pulumi uses similar patterns via the Grafana provider package.

### Grafonnet (Jsonnet)

Generate dashboard JSON programmatically:

```jsonnet
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

g.dashboard.new('Service Dashboard')
+ g.dashboard.withUid('svc-dash')
+ g.dashboard.withTags(['service', 'production'])
+ g.dashboard.withPanels([
    g.panel.timeSeries.new('Request Rate')
    + g.panel.timeSeries.queryOptions.withTargets([
        g.query.prometheus.new('A', 'rate(http_requests_total[5m])')
    ])
    + g.panel.timeSeries.standardOptions.withUnit('reqps')
    + g.panel.timeSeries.panelOptions.withGridPos(0, 0, 12, 8),
])
```

Install with `jb install github.com/grafana/grafonnet/gen/grafonnet-latest`. Render: `jsonnet -J vendor dashboard.jsonnet > dashboard.json`.

## Data Source Configuration and Provisioning

Provision data sources via `provisioning/datasources/`:

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      timeInterval: '15s'
      httpMethod: POST
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        - datasourceUid: tempo-uid
          matcherRegex: 'traceID=(\w+)'
          name: TraceID
          url: '$${__value.raw}'
```

Use `secureJsonData` for secrets (API keys, passwords). Reference data sources in panels by `uid` not name for portability.

## Dashboard Links, Drilldowns, Data Links

**Dashboard links** — add to `links` array at dashboard level. Link to other dashboards with variable forwarding: `keepTime: true`, `includeVars: true`.

**Data links** — on panel fields, link to external URLs or other dashboards. Use `${__value.raw}`, `${__field.name}`, `${__series.name}` variables:
```json
{
  "fieldConfig": {
    "defaults": {
      "links": [
        {
          "title": "View in Jaeger",
          "url": "http://jaeger:16686/trace/${__value.raw}",
          "targetBlank": true
        }
      ]
    }
  }
}
```

**Drilldown** — use data links with `${__data.fields.fieldname}` to pass clicked values to target dashboards.

## Repeat Panels and Rows

Create dynamic dashboards that expand based on variable values.

**Repeat panel** — set `repeat` on a panel to a multi-value variable name. Set `repeatDirection` to `h` (horizontal) or `v` (vertical). Set `maxPerRow` to control wrapping.

```json
{
  "repeat": "instance",
  "repeatDirection": "h",
  "maxPerRow": 4
}
```

**Repeat row** — set `repeat` on a row panel. All panels within the row repeat for each variable value. Use for per-service or per-environment sections.

## Dashboard Best Practices

### Golden Signals Dashboard

Structure around the four golden signals (from Google SRE):
1. **Latency** — histogram/heatmap of request duration (`histogram_quantile(0.99, ...)`)
2. **Traffic** — time series of request rate (`rate(http_requests_total[5m])`)
3. **Errors** — stat/time series of error rate (`rate(http_requests_total{status=~"5.."}[5m])`)
4. **Saturation** — gauge of resource utilization (CPU, memory, queue depth)

### USE Method (Resources)

For each resource (CPU, memory, disk, network): **Utilization** (% busy), **Saturation** (queue length), **Errors** (error count). One row per resource.

### RED Method (Services)

For each service: **Rate** (requests/sec), **Errors** (failed requests/sec), **Duration** (latency distribution). One row per service.

### SLO Dashboards

Display error budget burn rate, SLI compliance over windows (1h, 6h, 1d, 30d). Use stat panels for current burn rate, time series for historical. Alert when burn rate exceeds threshold.

## Grafana as Code

### Dashboard-as-Code Workflow

1. Write dashboards in Grafonnet (Jsonnet) or generate JSON via scripts
2. Store in version control alongside application code
3. Validate JSON schema in CI (`grafana dashboard lint` or custom validation)
4. Deploy via Terraform, provisioning YAML, or Grafana API in CD pipeline
5. Use `uid` for stable references; avoid relying on numeric `id`
6. Export existing dashboards via API for migration: `GET /api/dashboards/uid/<uid>`

## Authentication and RBAC

**Basic roles**: Viewer (read-only), Editor (create/edit dashboards), Admin (full control).

**Teams** — group users. Assign folder permissions to teams for bulk access control.

**Folder permissions** — grant View, Edit, or Admin per folder to users/teams. Remove inherited permissions to restrict access.

**RBAC (Enterprise/Cloud)** — fine-grained permissions: `dashboards:read`, `dashboards:write`, `datasources:query`, `folders:create`. Create custom roles combining specific actions and scopes.

**Service accounts** — use for API access and CI/CD. Assign roles to service accounts like users. Generate tokens for programmatic access.

## Plugins

### Panel Plugins

Extend visualization capabilities. Install via `grafana-cli plugins install <plugin-id>` or provision in `plugin` directory. Popular: Flowcharting, Diagram, Plotly, Candlestick, Dynamic Text.

### Data Source Plugins

Connect to additional backends. Each plugin provides query editor and data frame translation. Install and configure like built-in sources.

### App Plugins

Bundle dashboards, data sources, and custom pages into a single installable package. Define in `plugin.json` with routes, includes, and RBAC actions. Use for complete observability solutions (e.g., Grafana Cloud integrations).

Build custom plugins with `@grafana/create-plugin`:
```bash
npx @grafana/create-plugin@latest
cd my-plugin && npm install && npm run dev
```

## References

In-depth guides in `references/`:

| Document | Contents |
|----------|----------|
| **[advanced-patterns.md](references/advanced-patterns.md)** | Grafonnet (Jsonnet) dashboard-as-code, advanced templating (chained variables, ad-hoc filters, `__interval`/`__rate_interval`), mixed data sources, shared crosshair, annotations from multiple sources, transformations chaining, dashboard linking, embedding/public dashboards, Grafana Scenes, plugin development |
| **[troubleshooting.md](references/troubleshooting.md)** | Slow dashboards, variable query performance, `$__all` behavior, mixed data source gotchas, alerting evaluation issues, provisioning errors, CORS/proxy issues, LDAP/OAuth config, JSON import/export incompatibilities, panel rendering version differences |
| **[dashboard-recipes.md](references/dashboard-recipes.md)** | Ready-to-use dashboard recipes with full panel JSON: Kubernetes cluster overview, RED metrics, USE method, SLO with error budget burn rate, PostgreSQL/MySQL, NGINX/HAProxy, Docker host monitoring, CI/CD pipeline metrics, business KPIs |
| **[promql-logql-guide.md](references/promql-logql-guide.md)** | PromQL and LogQL query patterns for Grafana panels |

## Scripts

Helper scripts in `scripts/` (all executable):

| Script | Purpose | Key Flags |
|--------|---------|-----------|
| **export-dashboards.sh** | Export all dashboards from Grafana via API | `--url`, `--api-key`, `--output-dir` |
| **import-dashboards.sh** | Import dashboard JSON files with folder creation and data source substitution | `--url`, `--api-key`, `--input-dir`, `--folder`, `--ds-map` |
| **provision-grafana.sh** | Spin up Grafana + Prometheus + Loki + Promtail via Docker Compose | `--data-dir`, `--port`, `--prometheus-port` |
| **dashboard-export.sh** | Lightweight single-dashboard export | `--uid`, `--url` |
| **alert-rules-sync.sh** | Sync alert rules between Grafana instances | `--source-url`, `--target-url` |
| **grafana-init.sh** | Initialize Grafana with default configuration | `--config-dir` |

## Assets

Templates and configs in `assets/`:

| Asset | Description |
|-------|-------------|
| **docker-compose.yml** | Full monitoring stack: Grafana + Prometheus + Loki + Promtail with health checks and named volumes |
| **provisioning/dashboards.yml** | Dashboard provisioning provider config (file-based, folder structure) |
| **provisioning/datasources.yml** | Data source provisioning for Prometheus + Loki |
| **golden-signals-dashboard.json** | Complete Golden Signals dashboard (Latency, Traffic, Errors, Saturation) with template variables |
<!-- tested: pass -->
