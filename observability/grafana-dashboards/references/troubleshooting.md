# Grafana Dashboard Troubleshooting Reference

---

## Table of Contents

1. [Dashboard Loading Slowly](#1-dashboard-loading-slowly)
2. [Variable Query Performance](#2-variable-query-performance)
3. [Template Variable `$__all` Behavior](#3-template-variable-__all-behavior)
4. [Mixed Data Source Gotchas](#4-mixed-data-source-gotchas)
5. [Alerting Evaluation Issues](#5-alerting-evaluation-issues)
6. [Provisioning Errors and Debugging](#6-provisioning-errors-and-debugging)
7. [CORS and Proxy Issues](#7-cors-and-proxy-issues)
8. [LDAP/OAuth Config Problems](#8-ldapoauth-config-problems)
9. [Dashboard JSON Export/Import Incompatibilities](#9-dashboard-json-exportimport-incompatibilities)
10. [Panel Rendering Differences Between Versions](#10-panel-rendering-differences-between-versions)

---

## 1. Dashboard Loading Slowly

### Symptoms

- Dashboard takes more than 5–10 seconds to render.
- Browser tab becomes unresponsive or shows high memory usage.
- Network tab shows dozens of simultaneous data source requests.
- Grafana logs show `context deadline exceeded` or timeout errors.

### Root Causes

- Too many queries per dashboard — each panel fires one or more queries on load.
- Excessive time range (e.g., 30 days) with high-resolution step intervals.
- More than 30 panels on a single dashboard.
- Unoptimized PromQL missing label matchers, causing full table scans.
- Browser memory limits hit when rendering large result sets.
- `max_concurrent_datasource_requests` set too low (default 5), serializing queries.

### Diagnostic Steps

1. Count data source requests in browser DevTools → Network tab (filter by `/api/ds/query`).
2. Check total panel count:
   ```bash
   cat dashboard.json | jq '[.panels[], .panels[]?.panels[]?] | length'
   ```
3. Inspect per-query execution times via panel title → Inspect → Query.
4. Look for unscoped PromQL — `rate(http_requests_total[5m])` scans everything.
5. Check `max_concurrent_datasource_requests`:
   ```bash
   grep max_concurrent /etc/grafana/grafana.ini
   ```

### Fix

**Use collapsed rows to defer query execution:**
```json
{ "type": "row", "title": "Detailed Metrics", "collapsed": true, "panels": [] }
```

**Increase concurrent requests:**
```ini
[dataproxy]
max_concurrent_datasource_requests = 30
```

**Add label matchers to every PromQL query:**
```promql
sum(rate(http_requests_total{job="api-server", cluster="$cluster"}[5m]))
```

**Set Min Interval** to `1m` on queries to avoid sub-second resolution over long ranges. Limit the default time range to `now-6h` and split oversized dashboards into focused ones linked via drill-down URLs.

---

## 2. Variable Query Performance

### Symptoms

- Dashboard stalls before any panel data appears.
- Variable dropdowns are slow to populate.
- Switching variable values causes noticeable delays.

### Root Causes

- `label_values()` without a metric name scans all series in the TSDB.
- Regex filters in variable queries force expensive server-side evaluation.
- `refresh: 1` (on dashboard load) re-queries every time the dashboard opens.
- High-cardinality labels (e.g., `pod`, `container_id`) return thousands of values.
- Missing `sort` causes Grafana to sort large result sets client-side.

### Diagnostic Steps

1. Check variable definitions:
   ```bash
   cat dashboard.json | jq '.templating.list[] | {name, query, refresh, sort}'
   ```
2. Test the query directly — compare scoped vs unscoped:
   ```bash
   curl -s 'http://prometheus:9090/api/v1/label/namespace/values' | jq '.data | length'
   curl -s 'http://prometheus:9090/api/v1/label/namespace/values?match[]=up{job="kubelet"}' | jq '.data | length'
   ```
3. Measure cardinality: `count(count by (namespace) (up))`.

### Fix

**Scope `label_values()` with a metric:**
```
label_values(kube_pod_info{job="kube-state-metrics"}, namespace)
```

**Set refresh to `2` (on time range change) instead of `1`:**
```json
{ "name": "namespace", "type": "query", "refresh": 2 }
```

**Use recording rules for variable sources:**
```yaml
rules:
  - record: namespace:active:count
    expr: count by (namespace) (up{job="kubelet"})
```

**Enable sort** — `"sort": 1` (alpha asc), `3` (num asc), `5` (case-insensitive asc).

**Enable query caching** (Enterprise or Thanos Query Frontend):
```ini
[caching]
enabled = true
ttl = 60
```

---

## 3. Template Variable `$__all` Behavior

### Symptoms

- Selecting "All" produces slow queries or query errors.
- Prometheus returns errors about query length exceeding limits.
- "All" produces different results than selecting every value individually.
- Dashboard returns no data when "All" is selected.

### Root Causes

- `includeAll: true` generates a regex union of every value (`val1|val2|val3|...`).
- No `allValue` override set — Grafana auto-generates the pipe-delimited regex.
- Query explosion when a high-cardinality variable expands inline.
- Custom `allValue: .*` not configured.

### Diagnostic Steps

1. Open Query Inspector with "All" selected — check `executedQueryString`.
2. Check variable config:
   ```bash
   cat dashboard.json | jq '.templating.list[] | {name, includeAll, allValue, multi}'
   ```
3. Count expansion size:
   ```bash
   curl -s 'http://prometheus:9090/api/v1/label/namespace/values' | jq '.data | length'
   ```

### Fix

**Set `allValue` to avoid regex explosion:**
```json
{ "name": "namespace", "includeAll": true, "allValue": ".*", "multi": true }
```
This produces `{namespace=~".*"}` instead of `{namespace=~"default|kube-system|..."}`.

Use `.+` instead of `.*` to exclude empty label values.

**Ensure queries use `=~` (regex), not `=` (exact):**
```promql
rate(http_requests_total{namespace=~"$namespace"}[5m])
```

**Limit cardinality** to prevent runaway expansion:
```
query_result(topk(50, count by (pod) (up{job="kubelet"})))
```

---

## 4. Mixed Data Source Gotchas

### Symptoms

- Panels using `-- Mixed --` show partial or no data.
- Legend entries display inconsistent formats across queries.
- Transformations (merge, join) fail or produce empty tables.
- Time alignment issues across sources.

### Root Causes

- Different time formats between sources (epoch seconds vs milliseconds vs ISO 8601).
- Incompatible data frames — time-series vs table frames.
- Legend format strings apply per-query only, not across mixed sources.
- Transformations require matching field names and types.
- `-- Mixed --` at the panel level hides per-query data source assignment errors.

### Diagnostic Steps

1. Check per-query data source assignment:
   ```bash
   cat dashboard.json | jq '.panels[] | {title, targets: [.targets[] | {refId, datasource}]}'
   ```
2. Inspect raw data frames via Inspect → Data → DataFrame view.
3. Test each query individually by switching to a single data source.

### Fix

**Use explicit per-query data source assignment:**
```json
{
  "targets": [
    { "refId": "A", "datasource": { "type": "prometheus", "uid": "prom-main" } },
    { "refId": "B", "datasource": { "type": "elasticsearch", "uid": "es-logs" } }
  ]
}
```

**Normalize time fields:**
```json
{ "id": "convertFieldType", "options": { "conversions": [{ "targetField": "Time", "destinationType": "time" }] } }
```

**Set legend format per query** to avoid inconsistent naming. **Use "Outer join"** instead of "Merge" for time-series from different sources:
```json
{ "id": "joinByField", "options": { "byField": "Time", "mode": "outer" } }
```

**Rename fields before merging:**
```json
{ "id": "organize", "options": { "renameByName": { "Value #A": "prom_val", "Value #B": "es_val" } } }
```

---

## 5. Alerting Evaluation Issues

### Symptoms

- Alert rule shows `pending` state and never fires.
- Alert shows `noData` or `error` state unexpectedly.
- Alert fires too many instances (multi-dimensional explosion).
- Migration from classic to unified alerting produces broken rules.

### Root Causes

- `for` duration has not elapsed, or the condition flickers above/below threshold.
- `noData` handling defaults to `NoData` state instead of `OK` or `Alerting`.
- Data source permissions block alerting access.
- High-cardinality queries produce one alert instance per label combination.
- Evaluation group interval is longer than expected.
- Classic alerting uses different semantics than unified alerting (Grafana 8+).

### Diagnostic Steps

1. Check alert rule state:
   ```bash
   curl -s -H "Authorization: Bearer $GRAFANA_API_KEY" \
     http://localhost:3000/api/v1/provisioning/alert-rules | \
     jq '.[] | {title, noDataState, execErrState, for}'
   ```
2. Check evaluation group interval:
   ```bash
   curl -s -H "Authorization: Bearer $GRAFANA_API_KEY" \
     http://localhost:3000/api/v1/provisioning/folder/my-folder/rule-groups | jq '.[] | {name, interval}'
   ```
3. Test the query using rule preview in the UI (Alerting → Alert rules → Preview).
4. Check logs: `grep -i "alerting\|ngalert" /var/log/grafana/grafana.log | tail -50`

### Fix

**Set `noData`/`error` handling explicitly:**
```yaml
rules:
  - uid: my-alert
    title: High Error Rate
    noDataState: OK
    execErrState: Alerting
    for: 5m
    data:
      - refId: A
        datasourceUid: prometheus-main
        model:
          expr: rate(http_errors_total{job="api-server"}[5m])
      - refId: C
        datasourceUid: __expr__
        model:
          type: threshold
          conditions:
            - evaluator: { type: gt, params: [0.05] }
```

**Fix multi-dimensional explosion — aggregate before alerting:**
```promql
# Before — one alert per pod × namespace × instance
rate(http_errors_total[5m]) > 0.05
# After
sum by (namespace) (rate(http_errors_total{job="api-server"}[5m])) > 0.05
```

**Smooth flickering conditions:**
```promql
avg_over_time(rate(http_errors_total{job="api-server"}[5m])[15m:1m]) > 0.05
```

**Enable unified alerting:**
```ini
[unified_alerting]
enabled = true
[alerting]
enabled = false
```

---

## 6. Provisioning Errors and Debugging

### Symptoms

- Grafana fails to start with provisioning-related errors.
- Provisioned dashboards do not appear in the UI.
- Saving a provisioned dashboard fails with "cannot save provisioned dashboard."
- UID conflicts cause overwrite or import errors.

### Root Causes

- YAML syntax errors (tabs vs spaces, unquoted special characters).
- Incorrect `provisioning/dashboards` path in the provider config.
- `disableDeletion: true` prevents removal even after the source file is deleted.
- UID conflicts between provisioned dashboards.
- `allowUiUpdates: false` (default) blocks UI modifications.
- File permissions prevent the Grafana user from reading provisioning files.

### Diagnostic Steps

1. Start with debug logging:
   ```bash
   GF_LOG_LEVEL=debug grafana-server
   ```
2. Validate YAML:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('provisioning/dashboards/default.yaml'))"
   ```
3. Validate JSON and check UID uniqueness:
   ```bash
   jq . dashboards/my-dashboard.json > /dev/null
   find provisioning/ -name '*.json' -exec jq -r '.uid' {} \; | sort | uniq -d
   ```
4. Check file permissions:
   ```bash
   ls -la provisioning/dashboards/
   sudo -u grafana cat provisioning/dashboards/default.yaml
   ```

### Fix

**Correct provider YAML:**
```yaml
apiVersion: 1
providers:
  - name: default
    orgId: 1
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

**Find and resolve UID conflicts:**
```bash
find /var/lib/grafana/dashboards -name '*.json' \
  -exec jq -r '{file: input_filename, uid: .uid}' {} \; | \
  jq -s 'group_by(.uid) | map(select(length > 1))'
```

**Fix file permissions:**
```bash
sudo chown -R grafana:grafana /etc/grafana/provisioning/
sudo chown -R grafana:grafana /var/lib/grafana/dashboards/
sudo chmod -R 755 /var/lib/grafana/dashboards/
```

**Debug with structured log filters:**
```ini
[log]
level = info
filters = provisioning.dashboard:debug provisioning.datasource:debug
```

---

## 7. CORS and Proxy Issues

### Symptoms

- Blank pages or partially loaded UI behind a reverse proxy.
- API calls from external apps fail with CORS errors.
- WebSocket connections for Grafana Live fail.
- Login redirects loop or point to the wrong URL.
- Embedding panels in iframes shows "refused to display."

### Root Causes

- `root_url` not matching the external URL from the reverse proxy.
- `serve_from_sub_path` not enabled when mounted at a sub-path (e.g., `/grafana/`).
- WebSocket upgrade headers not forwarded by the proxy.
- `allow_embedding` not enabled for iframe use.
- Cookie `SameSite`/`Secure` attributes conflict with the proxy setup.
- Load balancer without session affinity causes session loss.

### Diagnostic Steps

1. Check configuration:
   ```bash
   grep -E "root_url|serve_from_sub_path" /etc/grafana/grafana.ini
   ```
2. Test WebSocket connectivity through the proxy:
   ```bash
   curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://grafana.example.com/api/live/ws
   ```
3. Inspect cookie headers from login response:
   ```bash
   curl -v -X POST http://localhost:3000/login \
     -H "Content-Type: application/json" \
     -d '{"user":"admin","password":"admin"}' 2>&1 | grep -i set-cookie
   ```

### Fix

**Configure `root_url` and `serve_from_sub_path`:**
```ini
[server]
domain = grafana.example.com
root_url = https://grafana.example.com/grafana/
serve_from_sub_path = true
```

**Nginx with WebSocket support:**
```nginx
location /grafana/ {
    proxy_pass http://localhost:3000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

**Traefik:**
```yaml
http:
  routers:
    grafana:
      rule: "Host(`grafana.example.com`) && PathPrefix(`/grafana`)"
      service: grafana
      middlewares: [grafana-stripprefix]
  middlewares:
    grafana-stripprefix:
      stripPrefix:
        prefixes: ["/grafana"]
```

**Enable embedding and fix cookies:**
```ini
[security]
allow_embedding = true
cookie_samesite = lax
cookie_secure = true
```

**CORS headers for API access (nginx):**
```nginx
location /grafana/api/ {
    proxy_pass http://localhost:3000/api/;
    add_header Access-Control-Allow-Origin "https://myapp.example.com" always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
    add_header Access-Control-Allow-Credentials "true" always;
    if ($request_method = OPTIONS) { return 204; }
}
```

**For multi-instance setups, use a shared session store:**
```ini
[session]
provider = mysql
provider_config = user:password@tcp(db:3306)/grafana_sessions
```

---

## 8. LDAP/OAuth Config Problems

### Symptoms

- LDAP login fails with "Invalid username or password" despite correct credentials.
- LDAP users assigned the wrong role.
- OAuth redirects fail with "redirect URI mismatch."
- OIDC token validation fails with signature or audience errors.
- `auto_login` does not redirect automatically.
- `allowed_organizations` blocks legitimate users.

### Root Causes

- LDAP bind DN or password is incorrect.
- `group_dn` in group mapping does not match actual DNs in the directory.
- OAuth `redirect_uri` does not match Grafana's `root_url` + callback path.
- `auto_login = true` not set under the specific OAuth provider section.
- Role mapping references a claim not present in the token.

### Diagnostic Steps

1. Test LDAP bind directly:
   ```bash
   ldapsearch -x -H ldap://ldap.example.com:389 \
     -D "cn=grafana,ou=service-accounts,dc=example,dc=com" \
     -w 'bind-password' -b "ou=users,dc=example,dc=com" "(uid=testuser)"
   ```
2. Decode OAuth/OIDC token claims:
   ```bash
   echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
   ```
3. Enable debug logging:
   ```ini
   [log]
   filters = oauth:debug ldap:debug login:debug
   ```

### Fix

**LDAP configuration (`ldap.toml`):**
```toml
[[servers]]
host = "ldap.example.com"
port = 636
use_ssl = true
bind_dn = "cn=grafana,ou=service-accounts,dc=example,dc=com"
bind_password = "${LDAP_BIND_PASSWORD}"
search_filter = "(uid=%s)"
search_base_dns = ["ou=users,dc=example,dc=com"]

[servers.attributes]
username = "uid"
email = "mail"
member_of = "memberOf"

[[servers.group_mappings]]
group_dn = "cn=admins,ou=groups,dc=example,dc=com"
org_role = "Admin"
grafana_admin = true

[[servers.group_mappings]]
group_dn = "cn=editors,ou=groups,dc=example,dc=com"
org_role = "Editor"

[[servers.group_mappings]]
group_dn = "*"
org_role = "Viewer"
```

**OAuth/OIDC configuration:**
```ini
[auth.generic_oauth]
enabled = true
client_id = grafana-client-id
client_secret = ${OAUTH_CLIENT_SECRET}
scopes = openid profile email groups
auth_url = https://idp.example.com/authorize
token_url = https://idp.example.com/token
api_url = https://idp.example.com/userinfo
redirect_url = https://grafana.example.com/login/generic_oauth
auto_login = true
role_attribute_path = contains(groups[*], 'grafana-admin') && 'Admin' || contains(groups[*], 'grafana-editor') && 'Editor' || 'Viewer'
allowed_organizations = my-org-slug
allow_sign_up = true
```

**Common redirect URI mismatches** — must exactly match what is registered in the IdP:
```
Correct:   https://grafana.example.com/login/generic_oauth
Wrong:     http://... (scheme)  |  .../grafana/login/... (sub-path)  |  .../ (trailing slash)
```

**Debug group mapping** — compare `memberOf` values from `ldapsearch` exactly with `group_dn` in `ldap.toml`.

---

## 9. Dashboard JSON Export/Import Incompatibilities

### Symptoms

- Import shows "data source not found" on all panels.
- Import fails with "A dashboard with the same UID already exists."
- Panel layout or types change after import.
- Panel plugins referenced in the JSON are not installed on the target.

### Root Causes

- Data source UIDs in exported JSON do not match UIDs on the target instance.
- Missing `__inputs` and `__requires` sections that enable portability.
- `schemaVersion` is newer than what the target Grafana supports.
- Dashboard UID collisions on import.
- Panel plugins not installed on the target.
- Folder assignment not handled during API import.

### Diagnostic Steps

1. Check data source references and schema version:
   ```bash
   cat dashboard.json | jq '{datasources: [.panels[].datasource] | unique, schemaVersion}'
   ```
2. Check for `__inputs`/`__requires`:
   ```bash
   cat dashboard.json | jq '{__inputs, __requires}'
   ```
3. Check for UID collisions:
   ```bash
   UID=$(cat dashboard.json | jq -r '.uid')
   curl -s -H "Authorization: Bearer $GRAFANA_API_KEY" \
     "http://target-grafana:3000/api/dashboards/uid/$UID"
   ```
4. List required panel plugins:
   ```bash
   cat dashboard.json | jq '[.panels[].type, .panels[]?.panels[]?.type] | unique'
   ```

### Fix

**Add `__inputs` for portable data source mapping:**
```json
{
  "__inputs": [{ "name": "DS_PROMETHEUS", "type": "datasource", "pluginId": "prometheus" }],
  "__requires": [
    { "type": "grafana", "id": "grafana", "version": "9.0.0" },
    { "type": "panel", "id": "timeseries" },
    { "type": "datasource", "id": "prometheus" }
  ]
}
```

**Replace data source UIDs for the target environment:**
```bash
cat dashboard.json | jq '
  (.panels[].datasource.uid) = "target-prom-uid" |
  (.panels[].targets[].datasource.uid) = "target-prom-uid"
' > dashboard-fixed.json
```

**Remove UID to avoid collisions:**
```bash
cat dashboard.json | jq 'del(.uid) | del(.id)' > dashboard-no-uid.json
```

**Import via API with folder assignment:**
```bash
curl -s -X POST -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"dashboard\": $(cat dashboard-fixed.json), \"folderUid\": \"my-folder\", \"overwrite\": true}" \
  http://target-grafana:3000/api/dashboards/db
```

**Install missing plugins** before import:
```bash
grafana-cli plugins install grafana-piechart-panel && systemctl restart grafana-server
```

---

## 10. Panel Rendering Differences Between Versions

### Symptoms

- Panels from Grafana 7/8 look different or break in Grafana 9/10+.
- Legacy "Graph" panels show a deprecation banner or Angular fallback.
- Thresholds, overrides, or axis configs display incorrectly after upgrade.
- Tooltip behavior changes between versions.
- Visualization suggestions recommend unexpected panel types.

### Root Causes

- Legacy Graph panel (Angular/Flot) deprecated in favor of Time Series (React).
- Angular panel plugins being removed; Grafana 11+ disables Angular by default.
- Field config format changed (overrides, thresholds, mappings).
- Threshold format: `{ value, colorMode, op }` → `{ steps: [{ value, color }] }`.
- `graphTooltip` behavior: `0` = single, `1` = shared crosshair, `2` = shared tooltip.

### Diagnostic Steps

1. Find legacy panels:
   ```bash
   cat dashboard.json | jq '[.panels[] | select(.type == "graph")] | length'
   ```
2. Check Angular support:
   ```bash
   grep "angular_support_enabled" /etc/grafana/grafana.ini
   ```
3. Compare threshold formats:
   ```bash
   cat dashboard.json | jq '.panels[] | select(.type == "graph") | .thresholds'
   cat dashboard.json | jq '.panels[] | select(.type == "timeseries") | .fieldConfig.defaults.thresholds'
   ```
4. Find panels with old-style config:
   ```bash
   cat dashboard.json | jq '[.panels[] | select(.yaxes != null) | .title]'
   ```

### Fix

**Migrate thresholds — old to new format:**
```json
// Old (Graph panel)
{ "thresholds": [{ "value": 80, "colorMode": "critical", "op": "gt", "fill": true }] }

// New (Time Series panel)
{ "fieldConfig": { "defaults": { "thresholds": {
  "mode": "absolute",
  "steps": [{ "value": null, "color": "green" }, { "value": 80, "color": "red" }]
} } } }
```

**Migrate axis configuration:**
```json
// Old
{ "yaxes": [{ "format": "bytes", "min": 0, "label": "Memory" }] }
// New
{ "fieldConfig": { "defaults": { "unit": "bytes", "min": 0, "custom": { "axisLabel": "Memory" } } } }
```

**Enable Angular temporarily during migration (Grafana 11+):**
```ini
[security]
angular_support_enabled = true
```

> **Warning:** Angular support will be removed in a future release. Use only as a temporary measure.

**Batch-migrate Graph panels to Time Series with `jq`:**
```bash
cat dashboard.json | jq '
  .panels = [.panels[] |
    if .type == "graph" then
      .type = "timeseries" |
      .fieldConfig = {
        defaults: { custom: {
          drawStyle: "line",
          fillOpacity: (.fill // 1) * 10,
          lineWidth: (.linewidth // 1),
          stacking: { mode: (if .stack then "normal" else "none" end) }
        } },
        overrides: []
      } |
      del(.bars, .dashes, .fill, .lines, .linewidth, .points,
          .stack, .steppedLine, .yaxes, .xaxis, .seriesOverrides)
    else . end
  ]
' > dashboard-migrated.json
```

**Set `graphTooltip` at dashboard level:**
```json
{ "graphTooltip": 2 }
```
Values: `0` = default/single, `1` = shared crosshair, `2` = shared tooltip.
