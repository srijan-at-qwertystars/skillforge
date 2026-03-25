# Grafana Dashboards Troubleshooting Guide

> Systematic troubleshooting for common Grafana dashboard issues, organized by symptom.

## Table of Contents

- [Slow Dashboards](#slow-dashboards)
- [Missing Data / No Data](#missing-data--no-data)
- [Variable Query Failures](#variable-query-failures)
- [Provisioning Errors](#provisioning-errors)
- [Panel Rendering Issues](#panel-rendering-issues)
- [Alerting Problems](#alerting-problems)
- [Data Source Connection Errors](#data-source-connection-errors)
- [Permission Issues](#permission-issues)
- [Migration Between Versions](#migration-between-versions)
- [Diagnostic Tools & Techniques](#diagnostic-tools--techniques)

---

## Slow Dashboards

### Symptoms
- Dashboard takes >5s to load.
- Browser becomes unresponsive.
- Grafana backend returns 504 or slow query warnings.

### Root Causes & Fixes

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| Too many panels | Count panels (>20 is risky) | Split into sub-dashboards with links |
| Wide time range with high-cardinality queries | Check query inspector for data points | Add `min_step` or reduce time range |
| Missing `$__rate_interval` | Queries use hardcoded `[5m]` | Replace with `$__rate_interval` |
| Unbounded regex | Queries like `{__name__=~".*"}` | Always scope with at least one concrete label |
| Auto-refresh too aggressive | Refresh is `5s` or `10s` | Set to `30s` for ops, `5m+` for business |
| No instant queries on stat/gauge | Stat panels run range queries | Set `"instant": true` for single-value panels |
| Dashboard loads all collapsed rows | Rows with `collapsed: false` execute queries | Set `"collapsed": true` on rows |

### Query Optimization Checklist

1. **Use recording rules** for queries evaluated across multiple dashboards.
2. **Add `min_step`** to prevent excessive data points: `"intervalMs": 15000`.
3. **Avoid `topk()` with large N** — keep under 20.
4. **Use `instant: true`** for table, stat, gauge, bar gauge panels.
5. **Limit label cardinality** — avoid `by (pod)` when pods are ephemeral and high-volume.
6. **Check query inspector**: Dashboard → Panel → Inspect → Query tab shows query duration and data size.

### Browser-Side Performance

- Disable unused annotations (each fires a separate query).
- Reduce panel height/width — oversized panels render more pixels.
- Use `graphTooltip: 0` instead of `2` (shared tooltip) for large dashboards.
- Chrome DevTools → Performance tab → record a dashboard load to find rendering bottlenecks.

---

## Missing Data / No Data

### Diagnostic Flowchart

```
Panel shows "No data"
├── Is the datasource reachable?
│   ├── No → See "Data Source Connection Errors"
│   └── Yes ↓
├── Does the query return data in Explore?
│   ├── No → Query or metric issue (check metric name, labels)
│   └── Yes ↓
├── Is the time range correct?
│   ├── No → Adjust time range, check timezone
│   └── Yes ↓
├── Are variables resolving?
│   ├── No → See "Variable Query Failures"
│   └── Yes ↓
├── Is `format` correct? (table vs time_series)
│   ├── Wrong → Fix format in target config
│   └── Correct ↓
└── Check transformations — they may filter out all data
```

### Common Causes

**Wrong time range or timezone**:
- Dashboard timezone mismatch with data source timestamps.
- Fix: Set `"timezone": "utc"` in dashboard JSON, or ensure data timestamps match.

**Stale variable values**:
- Variables cached from previous session.
- Fix: Set `"refresh": 2` (on time range change) or `"refresh": 1` (on load).

**Query returns NaN/null**:
- Division by zero in rate calculations.
- Fix: Use `or vector(0)` to handle missing denominators:
  ```promql
  rate(errors[5m]) / (rate(total[5m]) or vector(1))
  ```

**Format mismatch**:
- Table panels need `"format": "table"` and `"instant": true`.
- Time series panels need `"format": "time_series"` (default).

**Metric not being scraped**:
- Verify in Prometheus: `up{job="your_job"}` returns 1.
- Check Prometheus targets page for scrape errors.

---

## Variable Query Failures

### Symptoms
- Variable dropdown is empty.
- Variable shows `[object Object]`.
- Chained variables don't filter.
- "Datasource not found" in variable config.

### Fixes

**Empty dropdown**:
1. Check the datasource UID matches. After migration, UIDs may change.
2. Verify the query syntax. For Prometheus: `label_values(metric_name, label_name)`.
3. Check `refresh` is set to `1` or `2` (not `0` which is never).
4. Ensure the metric exists in the selected time range.

**Chained variable not filtering**:
```json
// WRONG: Missing quotes around variable reference
{ "query": "label_values(kube_pod_info{namespace=$namespace}, pod)" }

// CORRECT: Variable in quotes for label matcher
{ "query": "label_values(kube_pod_info{namespace=\"$namespace\"}, pod)" }
```

**Multi-value variable breaks query**:
```promql
// WRONG: $namespace expands to value1|value2 without regex matcher
{namespace="$namespace"}

// CORRECT: Use regex matcher for multi-value variables
{namespace=~"$namespace"}
```

**Variable shows `[object Object]`**:
- The variable `current` value is malformed. Reset by selecting a value in the UI or updating JSON:
  ```json
  "current": { "text": "All", "value": "$__all", "selected": true }
  ```

---

## Provisioning Errors

### Dashboard Provisioning

**Dashboards don't appear after provisioning**:

| Check | How |
|-------|-----|
| File path correct | Verify `options.path` in provider YAML matches actual directory |
| File permissions | Grafana process must have read access: `chmod 644 *.json` |
| Valid JSON | Run `jq . dashboard.json` — invalid JSON silently fails |
| Unique UIDs | Two dashboards with same `uid` → only one loads |
| Provider YAML valid | Check `apiVersion: 1`, correct indentation |
| Folder exists or auto-creates | Set `folder: "MyFolder"` — created if missing |

**Dashboards revert after UI edits**:
- `allowUiUpdates: false` (default) prevents saving UI changes. Set to `true` if you want UI edits, or use Git-based workflow.

**Provisioned dashboard shows "cannot save"**:
- Expected behavior when `allowUiUpdates: false`. Edit the source JSON file instead.

### Datasource Provisioning

**Datasource not appearing**:
```yaml
# Check for these common mistakes:
apiVersion: 1  # Must be 1, not "1"
datasources:   # Not "datasource" (plural required)
  - name: Prometheus
    type: prometheus  # Lowercase, must match plugin ID
    access: proxy     # "proxy" or "direct"
    url: http://prometheus:9090  # Must be reachable from Grafana server
```

**"Datasource not found" in panels after provisioning**:
- UID mismatch: Panel references `uid: "old-uid"` but provisioned datasource has different UID.
- Fix: Set explicit `uid` in datasource provisioning YAML to match panel references.

### Log Locations

| Deployment | Log Path |
|-----------|----------|
| Linux package | `/var/log/grafana/grafana.log` |
| Docker | `docker logs <container>` |
| Kubernetes | `kubectl logs deploy/grafana -n monitoring` |
| systemd | `journalctl -u grafana-server` |

Increase log verbosity: set `[log] level = debug` in `grafana.ini` or `GF_LOG_LEVEL=debug` env var.

---

## Panel Rendering Issues

### Panel Shows Wrong Visualization

- **Time series shows as table**: Check `"type": "timeseries"` not `"type": "table"` in JSON.
- **Bars instead of lines**: Check `fieldConfig.defaults.custom.drawStyle` is `"line"`.
- **All series same color**: Check `fieldConfig.defaults.color.mode` — use `"palette-classic"` for auto-coloring.

### Y-Axis Issues

| Problem | Fix |
|---------|-----|
| Y-axis starts at non-zero | Set `fieldConfig.defaults.min: 0` |
| Dual series with different scales overlap | Use field override: set `custom.axisPlacement: "right"` for second series |
| Y-axis label missing | Set `fieldConfig.defaults.custom.axisLabel: "Requests/sec"` |
| Logarithmic scale needed | Set `fieldConfig.defaults.custom.scaleDistribution: { type: "log", log: 2 }` |

### Legend Issues

- **Legend missing**: Set `options.legend.displayMode: "list"` or `"table"`.
- **Legend values missing**: Set `options.legend.calcs: ["mean", "max", "last"]`.
- **Legend too long**: Set `options.legend.placement: "bottom"` and limit series with `topk()`.

### Null Values

- **Gaps in graph**: Set `fieldConfig.defaults.custom.spanNulls: true` (or a duration like `"1h"`).
- **Nulls as zero**: Set `fieldConfig.defaults.noValue: "0"`.

---

## Alerting Problems

### Alert Rule Not Firing

1. **Check evaluation**: Alerting → Alert Rules → find rule → check "State history".
2. **Check condition**: Ensure the threshold condition (refId C) references the correct expression.
3. **Check `for` duration**: A 5m `for` means the condition must be true for 5 continuous minutes.
4. **Check data source**: Alert queries use the server-side evaluator, not the browser.
5. **Check time range**: `relativeTimeRange: { from: 300, to: 0 }` = last 5 minutes.

### Alert Fires But No Notification

| Check | Fix |
|-------|-----|
| Contact point configured | Alerting → Contact points — verify receiver exists |
| Notification policy routes match | Check label matchers in policy tree |
| Contact point tested | Use "Test" button on contact point |
| Webhook URL reachable | Test from Grafana server: `curl <webhook_url>` |
| `group_wait` too long | Default 30s — alerts batch within this window |
| `repeat_interval` active | Won't re-fire within repeat window (default 4h) |

### Silenced or Muted Alerts

- Check Alerting → Silences for active silences matching the alert labels.
- Check mute timings in notification policies.

### Multi-Dimensional Alerts

For alerts on each instance separately:
```yaml
data:
  - refId: A
    model:
      expr: rate(http_errors_total[$__rate_interval])
      # Do NOT wrap in sum() — keep per-instance series
```

The alert evaluator creates a separate alert instance per unique label set.

---

## Data Source Connection Errors

### Prometheus

| Error | Cause | Fix |
|-------|-------|-----|
| `"Post http://prometheus:9090/api/v1/query: dial tcp: lookup prometheus: no such host"` | DNS resolution failed | Use IP or fix DNS, check Docker network |
| `"context deadline exceeded"` | Query timeout | Increase timeout in datasource config `"queryTimeout": "60s"` |
| `"bad_data: 1:X parse error"` | Invalid PromQL | Test query in Prometheus UI first |
| `"connection refused"` | Prometheus not running or wrong port | Verify `curl http://prometheus:9090/-/healthy` from Grafana host |

### Loki

| Error | Cause | Fix |
|-------|-------|-----|
| `"too many outstanding requests"` | Loki overloaded | Reduce query concurrency, add limits |
| `"max entries limit exceeded"` | Too many log lines | Add filters, reduce time range |
| Derived fields not linking | Wrong regex or datasource UID | Test regex, verify Tempo/Jaeger UID |

### General

- **Test from Grafana host**: `curl -v <datasource_url>` to verify network connectivity.
- **Proxy vs Direct**: `access: proxy` routes through Grafana backend (recommended). `access: direct` hits from browser (CORS issues common).
- **TLS errors**: Add CA cert in datasource config: `jsonData.tlsAuthWithCACert: true`, provide in `secureJsonData.tlsCACert`.

---

## Permission Issues

### Dashboard Access

| Symptom | Cause | Fix |
|---------|-------|-----|
| User can't see dashboard | No folder permission | Grant Viewer role on folder |
| User can't edit | Only has Viewer role | Grant Editor on folder or org level |
| API returns 403 | Token lacks permissions | Use service account with correct role |
| Provisioned dashboards locked | `allowUiUpdates: false` | Set to true or edit source files |

### Data Source Permissions (Enterprise)

- In Grafana Enterprise, datasource permissions restrict which teams can query.
- Default: all org users can query all datasources.
- Restrict: Datasource Settings → Permissions → Add team/user.

### Service Account Token Scopes

```bash
# Create service account via API
curl -X POST http://admin:admin@localhost:3000/api/serviceaccounts \
  -H "Content-Type: application/json" \
  -d '{"name": "ci-deployer", "role": "Editor"}'

# Create token for the service account
curl -X POST http://admin:admin@localhost:3000/api/serviceaccounts/<id>/tokens \
  -H "Content-Type: application/json" \
  -d '{"name": "ci-token"}'
```

---

## Migration Between Versions

### Grafana 9 → 10

| Breaking Change | Migration |
|----------------|-----------|
| Legacy alerting removed | Migrate to Unified Alerting before upgrade |
| Angular panels deprecated | Replace angular panels (graph, singlestat) with React equivalents |
| API key → Service accounts | Create service accounts to replace API keys |

### Grafana 10 → 11

| Breaking Change | Migration |
|----------------|-----------|
| Angular panel support removed | All angular panels must be replaced |
| `graph` panel → `timeseries` | Update `"type": "graph"` to `"type": "timeseries"` |
| `singlestat` → `stat` | Update `"type": "singlestat"` to `"type": "stat"` |
| `table-old` → `table` | Update `"type": "table-old"` to `"type": "table"` |
| schemaVersion bump | Update `schemaVersion` to 39+ |

### Grafana 11 → 12

| Change | Notes |
|--------|-------|
| Scenes-based dashboards | Optional — dynamic dashboards as new feature |
| Dashboard schema v2 | New layout system with `GridLayout`, `RowsLayout`, `TabsLayout` |
| Tab support | `TabsLayout` for panel grouping |

### Migration Checklist

1. **Backup**: Export all dashboards via API before upgrading.
2. **Test**: Deploy new version in staging with production dashboard copies.
3. **Check deprecated panels**: `grep -r '"type": "graph"' dashboards/`.
4. **Check plugins**: Verify all plugins are compatible with new version.
5. **Update provisioning**: Check for breaking YAML schema changes.
6. **Validate alerts**: Run alert rule evaluation in dry-run mode.

---

## Diagnostic Tools & Techniques

### Query Inspector

Dashboard → Panel → Inspect (i icon):
- **Query tab**: Shows raw query, response time, response size, data frames.
- **JSON tab**: Shows the complete panel JSON model.
- **Data tab**: Shows the raw data frames returned.
- **Stats tab**: Shows request duration, data points count.

### Grafana Server Diagnostics

```bash
# Check Grafana health
curl http://localhost:3000/api/health

# Check Grafana metrics (if enabled)
curl http://localhost:3000/metrics

# Key metrics to watch:
# grafana_api_response_status_total — API error rates
# grafana_alerting_rule_evaluation_duration_seconds — alert performance
# grafana_datasource_request_duration_seconds — datasource latency
# grafana_http_request_duration_seconds — overall request latency
```

### Database Diagnostics

```bash
# SQLite (default)
sqlite3 /var/lib/grafana/grafana.db ".tables"
sqlite3 /var/lib/grafana/grafana.db "SELECT uid, title, updated FROM dashboard ORDER BY updated DESC LIMIT 10;"

# Check for duplicate UIDs
sqlite3 /var/lib/grafana/grafana.db "SELECT uid, COUNT(*) c FROM dashboard GROUP BY uid HAVING c > 1;"
```

### Docker Troubleshooting

```bash
# Check Grafana container logs
docker logs grafana --tail 100 --follow

# Exec into container to check provisioning
docker exec -it grafana ls -la /etc/grafana/provisioning/
docker exec -it grafana cat /etc/grafana/provisioning/datasources/datasources.yaml

# Check if datasource is reachable from Grafana container
docker exec -it grafana curl -s http://prometheus:9090/-/healthy
```

### Performance Profiling

Enable Grafana's built-in profiling:
```ini
# grafana.ini
[diagnostics]
profiling_enabled = true
profiling_addr = 0.0.0.0
profiling_port = 6060
```

Access profiles at `http://localhost:6060/debug/pprof/`.
