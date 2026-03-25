# Grafana API & Schema Reference

> Complete reference for the Grafana dashboard JSON model, provisioning YAML schemas, HTTP API, and Grafonnet library.

## Table of Contents

- [Dashboard JSON Model](#dashboard-json-model)
- [Panel Schema](#panel-schema)
- [Target / Query Schema](#target--query-schema)
- [Templating Schema](#templating-schema)
- [Annotation Schema](#annotation-schema)
- [Provisioning YAML Schema](#provisioning-yaml-schema)
- [Grafana HTTP API](#grafana-http-api)
- [Grafonnet Library Reference](#grafonnet-library-reference)

---

## Dashboard JSON Model

### Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | `number\|null` | No | Internal numeric ID. Set `null` for new dashboards. |
| `uid` | `string` | Yes | Unique string identifier, stable across export/import. Max 40 chars. |
| `title` | `string` | Yes | Dashboard display name. |
| `description` | `string` | No | Dashboard description. |
| `tags` | `string[]` | No | Tags for organization and linking. |
| `timezone` | `string` | No | `"browser"`, `"utc"`, or IANA timezone. Default: `"browser"`. |
| `editable` | `boolean` | No | Whether dashboard is editable. Default: `true`. |
| `graphTooltip` | `number` | No | `0`=default, `1`=shared crosshair, `2`=shared tooltip. |
| `schemaVersion` | `number` | Yes | Schema version. `39` for Grafana 11.x, `40` for 12.x. |
| `version` | `number` | No | Dashboard version (auto-incremented on save). |
| `time` | `object` | No | Default time range: `{ "from": "now-6h", "to": "now" }`. |
| `timepicker` | `object` | No | Time picker config: `{ "refresh_intervals": ["5s","10s","30s","1m","5m"] }`. |
| `refresh` | `string` | No | Auto-refresh interval: `"30s"`, `"1m"`, `"5m"`, `""` (off). |
| `panels` | `Panel[]` | Yes | Array of panel objects. |
| `templating` | `object` | No | `{ "list": Variable[] }`. |
| `annotations` | `object` | No | `{ "list": Annotation[] }`. |
| `links` | `Link[]` | No | Dashboard-level links. |
| `fiscalYearStartMonth` | `number` | No | 0-11, month offset for fiscal year. |
| `liveNow` | `boolean` | No | Continuously update time range to "now". |
| `weekStart` | `string` | No | `""` (browser default), `"monday"`, `"saturday"`, `"sunday"`. |

### Full Skeleton

```json
{
  "id": null,
  "uid": "unique-dashboard-id",
  "title": "Dashboard Title",
  "description": "",
  "tags": [],
  "timezone": "browser",
  "editable": true,
  "graphTooltip": 1,
  "schemaVersion": 39,
  "version": 0,
  "time": { "from": "now-6h", "to": "now" },
  "timepicker": { "refresh_intervals": ["10s", "30s", "1m", "5m", "15m"] },
  "refresh": "30s",
  "fiscalYearStartMonth": 0,
  "liveNow": false,
  "weekStart": "",
  "panels": [],
  "templating": { "list": [] },
  "annotations": { "list": [] },
  "links": []
}
```

---

## Panel Schema

### Common Panel Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | `number` | Unique within dashboard. Auto-assigned if omitted. |
| `type` | `string` | Panel type: `timeseries`, `stat`, `gauge`, `table`, `barchart`, `heatmap`, `logs`, `piechart`, `geomap`, `histogram`, `text`, `row`, etc. |
| `title` | `string` | Panel title. |
| `description` | `string` | Panel description (shown on hover). |
| `gridPos` | `object` | Position and size (see below). |
| `datasource` | `object` | `{ "type": "prometheus", "uid": "ds-uid" }`. |
| `targets` | `Target[]` | Array of query targets. |
| `fieldConfig` | `object` | Field configuration (defaults + overrides). |
| `options` | `object` | Panel-type-specific options. |
| `transformations` | `Transform[]` | Data transformations array. |
| `repeat` | `string` | Variable name to repeat panel for. |
| `repeatDirection` | `string` | `"h"` (horizontal) or `"v"` (vertical). |
| `maxPerRow` | `number` | Max panels per row when repeating. |
| `transparent` | `boolean` | Remove panel background. |
| `links` | `Link[]` | Panel-level links. |

### gridPos Object

```json
{
  "x": 0,    // 0-23, horizontal position
  "y": 0,    // Vertical position (auto-increments)
  "w": 12,   // Width: 1-24 (full width = 24)
  "h": 8     // Height in grid units
}
```

### fieldConfig Object

```json
{
  "defaults": {
    "unit": "reqps",
    "decimals": 2,
    "min": 0,
    "max": null,
    "color": { "mode": "palette-classic" },
    "thresholds": {
      "mode": "absolute",
      "steps": [
        { "color": "green", "value": null },
        { "color": "red", "value": 80 }
      ]
    },
    "mappings": [],
    "links": [],
    "noValue": "N/A",
    "custom": {
      "drawStyle": "line",
      "lineInterpolation": "linear",
      "lineWidth": 1,
      "fillOpacity": 10,
      "gradientMode": "none",
      "spanNulls": false,
      "showPoints": "auto",
      "pointSize": 5,
      "stacking": { "mode": "none", "group": "A" },
      "axisPlacement": "auto",
      "axisLabel": "",
      "axisColorMode": "text",
      "scaleDistribution": { "type": "linear" },
      "barAlignment": 0,
      "axisCenteredZero": false,
      "thresholdsStyle": { "mode": "off" }
    }
  },
  "overrides": []
}
```

### Panel-Type-Specific Options

**Time Series**:
```json
"options": {
  "tooltip": { "mode": "multi", "sort": "desc" },
  "legend": {
    "displayMode": "table",
    "placement": "bottom",
    "calcs": ["mean", "max", "lastNotNull"],
    "showLegend": true
  }
}
```

**Stat**:
```json
"options": {
  "reduceOptions": {
    "values": false,
    "calcs": ["lastNotNull"],
    "fields": ""
  },
  "orientation": "auto",
  "textMode": "auto",
  "colorMode": "background",
  "graphMode": "area",
  "justifyMode": "auto"
}
```

**Table**:
```json
"options": {
  "showHeader": true,
  "cellHeight": "sm",
  "footer": { "show": false, "reducer": ["sum"], "fields": "" },
  "sortBy": [{ "displayName": "Value", "desc": true }]
}
```

**Gauge**:
```json
"options": {
  "reduceOptions": { "calcs": ["lastNotNull"] },
  "showThresholdLabels": false,
  "showThresholdMarkers": true,
  "orientation": "auto"
}
```

**Logs**:
```json
"options": {
  "showTime": true,
  "showLabels": false,
  "showCommonLabels": false,
  "wrapLogMessage": true,
  "prettifyLogMessage": false,
  "enableLogDetails": true,
  "sortOrder": "Descending",
  "dedupStrategy": "none"
}
```

### Row Panel

```json
{
  "type": "row",
  "title": "Section Title",
  "gridPos": { "x": 0, "y": 0, "w": 24, "h": 1 },
  "collapsed": true,
  "panels": [],
  "repeat": "variable_name"
}
```

When `collapsed: true`, child panels are nested inside the `panels` array. When `collapsed: false`, child panels follow the row in the top-level `panels` array.

---

## Target / Query Schema

### Prometheus Target

```json
{
  "refId": "A",
  "datasource": { "type": "prometheus", "uid": "prometheus-main" },
  "expr": "sum(rate(http_requests_total{job=\"$job\"}[$__rate_interval])) by (status_code)",
  "legendFormat": "{{status_code}}",
  "range": true,
  "instant": false,
  "format": "time_series",
  "interval": "",
  "intervalMs": 15000,
  "intervalFactor": 1,
  "editorMode": "code",
  "exemplar": true
}
```

| Field | Description |
|-------|-------------|
| `refId` | Query reference ID (`"A"`, `"B"`, etc). |
| `expr` | PromQL expression. |
| `legendFormat` | Legend template. Use `{{label}}` for label values, `__auto` for auto. |
| `range` | Execute as range query (for time series). |
| `instant` | Execute as instant query (for stat/table). |
| `format` | `"time_series"`, `"table"`, `"heatmap"`. |
| `interval` | Min step override (e.g., `"1m"`). |
| `intervalMs` | Min step in milliseconds. |
| `exemplar` | Show exemplars (requires exemplar-enabled datasource). |

### Loki Target

```json
{
  "refId": "A",
  "datasource": { "type": "loki", "uid": "loki-main" },
  "expr": "{namespace=\"$namespace\", app=\"$app\"} |= \"$search\" | json | level=~\"$level\"",
  "queryType": "range",
  "maxLines": 1000,
  "legendFormat": "",
  "resolution": 1
}
```

### Expression Target (for Alerts)

```json
{
  "refId": "B",
  "datasource": { "type": "__expr__", "uid": "__expr__" },
  "model": {
    "type": "reduce",
    "expression": "A",
    "reducer": "last",
    "settings": { "mode": "dropNN" }
  }
}
```

Expression types: `reduce`, `resample`, `math`, `threshold`, `classic_conditions`.

---

## Templating Schema

### Variable Object

```json
{
  "name": "variable_name",
  "label": "Display Label",
  "description": "Help text",
  "type": "query",
  "datasource": { "type": "prometheus", "uid": "prometheus-main" },
  "query": "label_values(metric_name, label_name)",
  "regex": "/pattern/",
  "sort": 1,
  "refresh": 2,
  "multi": true,
  "includeAll": true,
  "allValue": ".*",
  "current": { "text": "All", "value": "$__all", "selected": true },
  "hide": 0,
  "skipUrlSync": false
}
```

### Variable Types

| Type | `query` Field | Notes |
|------|-------------|-------|
| `query` | Datasource-specific query | Dynamic values from datasource |
| `custom` | `"val1,val2,val3"` | Static comma-separated list |
| `textbox` | Default value | Free-text input |
| `constant` | Constant value | Hidden constant, useful for provisioning |
| `interval` | `"1m,5m,15m,30m,1h"` | Time interval selection |
| `datasource` | Plugin type ID (`"prometheus"`) | Select from available datasources |
| `adhoc` | — | Auto-injected label filters |

### Field Reference

| Field | Values | Description |
|-------|--------|-------------|
| `refresh` | `0`=never, `1`=on load, `2`=on time change | When to refresh values |
| `sort` | `0`=disabled, `1`=alpha asc, `2`=alpha desc, `3`=num asc, `4`=num desc, `5`=alpha case-insensitive asc, `6`=alpha case-insensitive desc | Sort order |
| `hide` | `0`=visible, `1`=label only, `2`=hidden | Variable visibility |
| `multi` | boolean | Allow multi-select |
| `includeAll` | boolean | Add "All" option |
| `allValue` | string | Custom value for "All" (e.g., `".*"`) |
| `regex` | string | Filter/extract from query results |
| `skipUrlSync` | boolean | Exclude from URL state |

### Prometheus Query Functions for Variables

```
label_values(label_name)                        # All values for a label
label_values(metric_name, label_name)           # Values for a label on a metric
label_values(metric{label="val"}, label_name)   # Filtered label values
metrics(pattern)                                 # Metric names matching regex
query_result(promql_expression)                  # Arbitrary PromQL result
```

---

## Annotation Schema

```json
{
  "name": "Deploys",
  "datasource": { "type": "prometheus", "uid": "prometheus-main" },
  "enable": true,
  "hide": false,
  "iconColor": "blue",
  "expr": "changes(deploy_timestamp{app=\"$app\"}[1m]) > 0",
  "step": "60s",
  "tagKeys": "app,version",
  "textFormat": "Deployed {{version}}",
  "titleFormat": "Deploy",
  "useValueForTime": false,
  "type": "dashboard"
}
```

### Built-in Annotation

Every dashboard includes a default annotation for manual annotations:

```json
{
  "builtIn": 1,
  "datasource": { "type": "grafana", "uid": "-- Grafana --" },
  "enable": true,
  "hide": true,
  "iconColor": "rgba(0, 211, 255, 1)",
  "name": "Annotations & Alerts",
  "type": "dashboard"
}
```

---

## Provisioning YAML Schema

### Dashboard Provider

```yaml
apiVersion: 1                              # Required, always 1
providers:
  - name: default                          # Provider name (unique)
    orgId: 1                               # Organization ID
    folder: "Production"                   # Target folder (created if missing)
    folderUid: "prod-folder"               # Optional: explicit folder UID
    type: file                             # Always "file"
    disableDeletion: false                 # Prevent deletion from UI
    updateIntervalSeconds: 30              # File scan interval
    allowUiUpdates: false                  # Allow saving changes in UI
    options:
      path: /var/lib/grafana/dashboards    # Path to dashboard JSON files
      foldersFromFilesStructure: true      # Subdirectories → Grafana folders
```

### Datasource Provisioning

```yaml
apiVersion: 1
deleteDatasources:                         # Remove datasources before applying
  - name: Old Prometheus
    orgId: 1

datasources:
  - name: Prometheus                       # Display name
    type: prometheus                       # Plugin type ID
    uid: prometheus-main                   # Stable UID for panel references
    access: proxy                          # "proxy" (via Grafana) or "direct" (browser)
    url: http://prometheus:9090            # Datasource URL
    isDefault: true                        # Default datasource
    orgId: 1                               # Organization ID
    version: 1                             # Config version
    editable: false                        # Prevent UI edits
    jsonData:                              # Type-specific configuration
      timeInterval: "15s"                  # Default scrape interval
      httpMethod: POST                     # POST for large queries
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo-main
      incrementalQuerying: true
      incrementalQueryOverlapWindow: "10m"
    secureJsonData:                        # Encrypted fields
      httpHeaderValue1: "Bearer token"
```

### Alert Rule Provisioning

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: group-name                       # Rule group name
    folder: Alerts                         # Alert folder
    interval: 1m                           # Evaluation interval
    rules:
      - uid: rule-uid                      # Unique rule ID
        title: Rule Title
        condition: C                       # RefID of condition expression
        data:
          - refId: A
            relativeTimeRange:
              from: 300                    # Seconds ago (300 = 5m)
              to: 0
            datasourceUid: prometheus-main
            model:
              expr: "promql_expression"
              instant: true
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              type: reduce
              expression: A
              reducer: last
          - refId: C
            datasourceUid: __expr__
            model:
              type: threshold
              expression: B
              conditions:
                - evaluator:
                    type: gt               # gt, lt, within_range, outside_range
                    params: [0.05]
        for: 5m                            # Pending duration
        noDataState: NoData                # NoData, Alerting, OK
        execErrState: Error                # Error, Alerting, OK
        labels:
          severity: critical
        annotations:
          summary: "Alert description"
          runbook_url: "https://..."
```

### Contact Point Provisioning

```yaml
apiVersion: 1
contactPoints:
  - orgId: 1
    name: team-slack
    receivers:
      - uid: slack-recv-1
        type: slack                        # slack, email, pagerduty, webhook, etc.
        disableResolveMessage: false
        settings:
          url: "https://hooks.slack.com/services/..."
          recipient: "#alerts"
          username: "Grafana"
          icon_emoji: ":grafana:"
          mentionChannel: "here"
          text: |
            {{ len .Alerts.Firing }} firing, {{ len .Alerts.Resolved }} resolved
```

### Notification Policy Provisioning

```yaml
apiVersion: 1
policies:
  - orgId: 1
    receiver: default-receiver             # Default receiver
    group_by: [alertname, namespace]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - receiver: critical-pagerduty
        matchers:
          - severity = critical
        continue: false
      - receiver: team-slack
        matchers:
          - team =~ "backend|platform"
        group_by: [alertname]
        continue: true                     # Continue evaluating sibling routes
      - receiver: email-digest
        matchers:
          - severity = warning
        group_wait: 5m
        repeat_interval: 24h
```

---

## Grafana HTTP API

### Authentication

```bash
# Service account token (preferred)
curl -H "Authorization: Bearer <SA_TOKEN>" https://grafana.example.com/api/...

# Basic auth
curl -u admin:password https://grafana.example.com/api/...

# API key (deprecated — migrate to service accounts)
curl -H "Authorization: Bearer <API_KEY>" https://grafana.example.com/api/...
```

### Dashboard Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/dashboards/uid/:uid` | Get dashboard by UID |
| `POST` | `/api/dashboards/db` | Create or update dashboard |
| `DELETE` | `/api/dashboards/uid/:uid` | Delete dashboard |
| `GET` | `/api/search?query=title` | Search dashboards |
| `GET` | `/api/search?tag=production` | Search by tag |
| `GET` | `/api/dashboards/id/:id/versions` | List versions |
| `GET` | `/api/dashboards/id/:id/versions/:version` | Get specific version |
| `POST` | `/api/dashboards/id/:id/restore` | Restore version |

#### Create/Update Dashboard

```bash
curl -X POST http://localhost:3000/api/dashboards/db \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "dashboard": {
      "uid": "my-dash",
      "title": "My Dashboard",
      "panels": [],
      "schemaVersion": 39,
      "version": 0
    },
    "folderUid": "folder-uid",
    "message": "Initial creation",
    "overwrite": false
  }'
```

#### Response Structure

```json
{
  "dashboard": { /* full dashboard JSON */ },
  "meta": {
    "isStarred": false,
    "url": "/d/uid/title",
    "slug": "title",
    "type": "db",
    "canSave": true,
    "canEdit": true,
    "canAdmin": true,
    "provisioned": false,
    "provisionedExternalId": "",
    "created": "2024-01-01T00:00:00Z",
    "updated": "2024-01-01T00:00:00Z",
    "createdBy": "admin",
    "updatedBy": "admin",
    "version": 1,
    "folderId": 1,
    "folderUid": "folder-uid",
    "folderTitle": "Folder Name",
    "folderUrl": "/dashboards/f/folder-uid/folder-name"
  }
}
```

### Folder Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/folders` | List all folders |
| `GET` | `/api/folders/:uid` | Get folder by UID |
| `POST` | `/api/folders` | Create folder |
| `PUT` | `/api/folders/:uid` | Update folder |
| `DELETE` | `/api/folders/:uid` | Delete folder and contents |
| `GET` | `/api/folders/:uid/permissions` | Get folder permissions |
| `POST` | `/api/folders/:uid/permissions` | Update folder permissions |

```bash
# Create folder
curl -X POST http://localhost:3000/api/folders \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"uid": "prod", "title": "Production"}'
```

### Datasource Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/datasources` | List all datasources |
| `GET` | `/api/datasources/uid/:uid` | Get by UID |
| `GET` | `/api/datasources/name/:name` | Get by name |
| `POST` | `/api/datasources` | Create datasource |
| `PUT` | `/api/datasources/uid/:uid` | Update datasource |
| `DELETE` | `/api/datasources/uid/:uid` | Delete datasource |
| `GET` | `/api/datasources/uid/:uid/health` | Health check |

```bash
# Create datasource
curl -X POST http://localhost:3000/api/datasources \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "uid": "prom-main",
    "url": "http://prometheus:9090",
    "access": "proxy",
    "isDefault": true,
    "jsonData": { "timeInterval": "15s" }
  }'
```

### Alerting Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/v1/provisioning/alert-rules` | List all rules |
| `GET` | `/api/v1/provisioning/alert-rules/:uid` | Get rule by UID |
| `POST` | `/api/v1/provisioning/alert-rules` | Create rule |
| `PUT` | `/api/v1/provisioning/alert-rules/:uid` | Update rule |
| `DELETE` | `/api/v1/provisioning/alert-rules/:uid` | Delete rule |
| `GET` | `/api/v1/provisioning/contact-points` | List contact points |
| `POST` | `/api/v1/provisioning/contact-points` | Create contact point |
| `GET` | `/api/v1/provisioning/policies` | Get notification policy tree |
| `PUT` | `/api/v1/provisioning/policies` | Update policy tree |
| `GET` | `/api/v1/provisioning/mute-timings` | List mute timings |

### Annotation Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/annotations?from=ts&to=ts` | Query annotations |
| `POST` | `/api/annotations` | Create annotation |
| `PUT` | `/api/annotations/:id` | Update annotation |
| `DELETE` | `/api/annotations/:id` | Delete annotation |

```bash
# Create annotation
curl -X POST http://localhost:3000/api/annotations \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "dashboardUID": "dash-uid",
    "panelId": 1,
    "time": 1704067200000,
    "timeEnd": 1704070800000,
    "tags": ["deploy", "v2.1.0"],
    "text": "Deployed version 2.1.0"
  }'
```

### Service Account Endpoints

```bash
# Create service account
curl -X POST http://localhost:3000/api/serviceaccounts \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "ci-deployer", "role": "Editor"}'

# Create token for service account
curl -X POST http://localhost:3000/api/serviceaccounts/:id/tokens \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "deploy-token", "secondsToLive": 86400}'
```

### Useful Query Parameters

| Parameter | Endpoints | Description |
|-----------|-----------|-------------|
| `query` | `/api/search` | Search by title |
| `tag` | `/api/search` | Filter by tag (repeatable) |
| `type` | `/api/search` | `dash-db` or `dash-folder` |
| `folderIds` | `/api/search` | Filter by folder IDs |
| `starred` | `/api/search` | Only starred dashboards |
| `limit` | `/api/search` | Results per page (default 1000) |
| `page` | `/api/search` | Page number |

---

## Grafonnet Library Reference

### Installation

```bash
# Install jsonnet-bundler
go install github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest

# Initialize and install grafonnet
jb init
jb install github.com/grafana/grafonnet/gen/grafonnet-latest@main
```

### Import

```jsonnet
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
```

### Dashboard Functions

```jsonnet
g.dashboard.new('Title')
+ g.dashboard.withUid('uid')
+ g.dashboard.withDescription('desc')
+ g.dashboard.withTags(['tag1', 'tag2'])
+ g.dashboard.withEditable(true)
+ g.dashboard.withSchemaVersion(39)
+ g.dashboard.withRefresh('30s')
+ g.dashboard.withTimezone('browser')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.time.withTo('now')
+ g.dashboard.graphTooltip.withSharedCrosshair()   // or withSharedTooltip()
+ g.dashboard.withVariables([ ... ])
+ g.dashboard.withPanels([ ... ])
+ g.dashboard.withAnnotations([ ... ])
+ g.dashboard.withLinks([ ... ])
```

### Panel Functions

```jsonnet
// Time Series
g.panel.timeSeries.new('Title')
+ g.panel.timeSeries.queryOptions.withDatasource('prometheus', 'prom-uid')
+ g.panel.timeSeries.queryOptions.withTargets([ ... ])
+ g.panel.timeSeries.queryOptions.withInterval('1m')
+ g.panel.timeSeries.standardOptions.withUnit('reqps')
+ g.panel.timeSeries.standardOptions.withDecimals(2)
+ g.panel.timeSeries.standardOptions.withMin(0)
+ g.panel.timeSeries.standardOptions.color.withMode('palette-classic')
+ g.panel.timeSeries.standardOptions.thresholds.withMode('absolute')
+ g.panel.timeSeries.standardOptions.thresholds.withSteps([ ... ])
+ g.panel.timeSeries.options.legend.withDisplayMode('table')
+ g.panel.timeSeries.options.legend.withPlacement('bottom')
+ g.panel.timeSeries.options.legend.withCalcs(['mean', 'max'])
+ g.panel.timeSeries.options.tooltip.withMode('multi')
+ g.panel.timeSeries.fieldConfig.defaults.custom.withDrawStyle('line')
+ g.panel.timeSeries.fieldConfig.defaults.custom.withFillOpacity(10)
+ g.panel.timeSeries.fieldConfig.defaults.custom.withLineWidth(2)

// Stat
g.panel.stat.new('Title')
+ g.panel.stat.options.withColorMode('background')
+ g.panel.stat.options.withGraphMode('area')
+ g.panel.stat.options.reduceOptions.withCalcs(['lastNotNull'])

// Table
g.panel.table.new('Title')
+ g.panel.table.queryOptions.withTransformations([ ... ])

// Gauge
g.panel.gauge.new('Title')
+ g.panel.gauge.options.withShowThresholdLabels(true)

// Logs
g.panel.logs.new('Title')
+ g.panel.logs.options.withShowTime(true)
+ g.panel.logs.options.withSortOrder('Descending')
```

### Query Functions

```jsonnet
// Prometheus
g.query.prometheus.new('datasource-uid', 'promql_expr')
+ g.query.prometheus.withLegendFormat('{{label}}')
+ g.query.prometheus.withInstant(true)
+ g.query.prometheus.withFormat('table')
+ g.query.prometheus.withInterval('1m')

// Loki
g.query.loki.new('datasource-uid', '{app="api"} |= "error"')
+ g.query.loki.withMaxLines(1000)
```

### Variable Functions

```jsonnet
// Query variable
g.dashboard.variable.query.new('name')
+ g.dashboard.variable.query.withDatasource('prometheus', 'prom-uid')
+ g.dashboard.variable.query.queryTypes.withLabelValues('label', 'metric{filter="x"}')
+ g.dashboard.variable.query.withRefresh(2)
+ g.dashboard.variable.query.withSort(1)
+ g.dashboard.variable.query.selectionOptions.withMulti(true)
+ g.dashboard.variable.query.selectionOptions.withIncludeAll(true)
+ g.dashboard.variable.query.withRegex('/pattern/')

// Custom variable
g.dashboard.variable.custom.new('name', ['val1', 'val2', 'val3'])

// Datasource variable
g.dashboard.variable.datasource.new('ds_prom', 'prometheus')

// Interval variable
g.dashboard.variable.interval.new('smoothing', ['1m', '5m', '15m', '1h'])
+ g.dashboard.variable.interval.withAutoOption(30, '10s')

// Textbox variable
g.dashboard.variable.textbox.new('search', 'default_value')

// Constant variable
g.dashboard.variable.constant.new('env', 'production')
```

### Grid Layout Utility

```jsonnet
// Auto-layout panels into a grid
g.util.grid.makeGrid(
  [panel1, panel2, panel3, panel4],
  panelWidth=12,    // Each panel width (24 = full width)
  panelHeight=8,    // Each panel height
  startY=0          // Starting Y position
)

// Custom widths per panel
g.util.grid.wrapPanels(
  [
    { panel: panel1, w: 8, h: 6 },
    { panel: panel2, w: 16, h: 6 },
    { panel: panel3, w: 24, h: 10 },
  ],
  startY=0
)
```

### Build Commands

```bash
# Build single dashboard
jsonnet -J vendor/ dashboard.jsonnet > dashboard.json

# Build with external variables
jsonnet -J vendor/ --ext-str env=production dashboard.jsonnet > dashboard.json

# Build all dashboards
find . -name '*.jsonnet' -exec sh -c 'jsonnet -J vendor/ "$1" > "${1%.jsonnet}.json"' _ {} \;

# Validate output
jsonnet -J vendor/ dashboard.jsonnet | jq '.panels | length'
```
