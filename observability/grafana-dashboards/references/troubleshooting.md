# Grafana Troubleshooting Guide

> Comprehensive troubleshooting reference for common Grafana issues. Each section: symptoms, root causes, diagnostic steps, fixes.

## Table of Contents

- [Slow Dashboard Loading](#slow-dashboard-loading)
- [Query Timeout](#query-timeout)
- [Data Source Connection Errors](#data-source-connection-errors)
- [Variable Query Performance](#variable-query-performance)
- [Alerting Not Firing](#alerting-not-firing)
- [Notification Delivery Failures](#notification-delivery-failures)
- [Dashboard Provisioning Conflicts](#dashboard-provisioning-conflicts)
- [Permission Issues](#permission-issues)
- [LDAP/OAuth Configuration Problems](#ldapoauth-configuration-problems)
- [Panel Rendering Issues](#panel-rendering-issues)
- [Time Zone Confusion](#time-zone-confusion)
- [Missing Data Points](#missing-data-points)
- [Grafana Behind Reverse Proxy](#grafana-behind-reverse-proxy)
- [Upgrade and Migration Issues](#upgrade-and-migration-issues)

---

## Slow Dashboard Loading

### Symptoms
- Dashboard takes >5s to render
- Browser tab becomes unresponsive
- "Loading" spinners persist on panels

### Root causes and fixes

**Too many panels**
- Diagnostic: Count panels — `jq '.panels | length' dashboard.json`
- Fix: Limit to ≤20 panels. Split into overview + detail dashboards linked via dashboard links. Use collapsible rows for secondary panels.

**Expensive queries**
- Diagnostic: Open browser DevTools → Network tab → filter `api/ds/query`. Check response time per query.
- Fix:
  - Add `maxDataPoints: 1000` to panel to reduce resolution
  - Set `minInterval: "1m"` on panels to prevent sub-minute resolution on large ranges
  - Use recording rules for complex aggregations
  - Replace `{job=~".*"}` with specific label matchers

**Large time ranges**
- Diagnostic: Check if users set "Last 30 days" on high-resolution dashboards
- Fix: Set sensible default time range. Add interval variable with auto-scaling. Set `minInterval` per panel.

**Missing indexes on SQL data sources**
- Diagnostic: `EXPLAIN ANALYZE` on the generated SQL query
- Fix: Add indexes on time columns and frequently filtered columns

**Browser resource limits**
- Diagnostic: Chrome DevTools → Performance tab → record a load
- Fix: Reduce `maxDataPoints`, use server-side transformations, enable panel lazy loading (default in Grafana 10+)

**Query caching not enabled**
- Fix (Enterprise): Set `jsonData.cacheLevel` to `"Medium"` or `"High"` on data source. OSS: use Prometheus recording rules as alternative.

---

## Query Timeout

### Symptoms
- `"Query timeout"` or `"context deadline exceeded"` error in panel
- Partial data loads then errors

### Root causes and fixes

**Grafana-side timeout too low**
```ini
# grafana.ini
[dataproxy]
timeout = 300           # seconds, default 30
keep_alive_seconds = 30
```

**Prometheus query timeout**
```yaml
# prometheus.yml
global:
  query_timeout: 2m     # default 2m; increase cautiously
```

Or per-query in Grafana data source settings: `jsonData.queryTimeout: "120s"`

**Query too expensive**
- Use `topk()` / `bottomk()` to limit series count
- Add label filters to reduce cardinality
- Replace `rate(metric[long_range])` with recording rules:
  ```yaml
  # Recording rule
  - record: job:http_requests:rate5m
    expr: sum by (job) (rate(http_requests_total[5m]))
  ```
- Use `$__rate_interval` instead of large fixed windows

**High cardinality**
- Diagnostic: `count(http_requests_total)` — if >100k series, cardinality is too high
- Fix: Drop high-cardinality labels with relabeling or metric_relabel_configs. Use `without()` instead of `by()` to exclude noisy labels.

---

## Data Source Connection Errors

### Symptoms
- `"Bad Gateway"`, `"Connection refused"`, `"no such host"` in panel or data source test

### Diagnostic flow

```
1. Test data source: Settings → Save & Test
2. Check Grafana server logs: journalctl -u grafana-server -f
3. Verify network: docker exec grafana curl -v http://prometheus:9090/-/healthy
4. Check DNS resolution: docker exec grafana nslookup prometheus
5. Verify TLS certs: openssl s_client -connect prometheus:9090
```

### Common fixes

**Docker networking**
- Use Docker service names, not `localhost`: `http://prometheus:9090` not `http://localhost:9090`
- Ensure services are on the same Docker network:
  ```yaml
  networks:
    monitoring:
      driver: bridge
  ```

**TLS certificate errors**
```ini
# grafana.ini — skip TLS verify (dev only!)
[dataproxy]
tls_skip_verify = true
```

Better: mount CA cert and reference in data source `jsonData.tlsAuthWithCACert`.

**Access mode**
- Use `access: proxy` (Grafana server makes requests) — preferred
- `access: direct` (browser makes requests) — only for same-origin, exposes credentials
- Fix CORS: If `access: direct`, the data source must return `Access-Control-Allow-Origin` headers

**Authentication failures**
- Check data source credentials (Basic auth, Bearer token)
- For Prometheus with auth: set `basicAuth: true`, `basicAuthUser`, `secureJsonData.basicAuthPassword`
- For Mimir multi-tenancy: set `jsonData.httpHeaderName1: X-Scope-OrgID`, `secureJsonData.httpHeaderValue1: tenant-id`

---

## Variable Query Performance

### Symptoms
- Dashboard loads slowly but panels are fast
- Variable dropdowns take seconds to populate
- "Loading" on variable selectors

### Root causes and fixes

**Unfiltered label_values**
```
# Slow — scans all metrics
label_values(namespace)

# Fast — filtered to specific metric
label_values(kube_pod_info, namespace)
```

**Cascading refresh storm**
- If all variables use `refresh: 2` (on time range change), changing time triggers all queries simultaneously
- Fix: Use `refresh: 1` for variables that don't change with time (clusters, namespaces). Use `refresh: 2` only for time-dependent variables.

**Expensive regex in variable query**
- Regex applied client-side after fetching all values
- Fix: Push filtering into the query: `label_values(metric{env="prod"}, instance)` instead of `label_values(metric, instance)` + regex `/prod-.*/`

**Too many variable values**
- Diagnostic: Check variable preview — if >500 values, it's too many
- Fix: Add filters in the query, use `regex` to post-filter, or restructure labels

**query_result() vs label_values()**
- `label_values()` uses label index — fast O(1) lookup
- `query_result(sort_desc(sum by (x) (metric)))` executes full query — slow
- Use `query_result` only when you need computed values

---

## Alerting Not Firing

### Symptoms
- Alert rule shows `Normal` state despite condition being met
- Alert is in `Pending` state indefinitely
- No notifications received

### Diagnostic steps

1. **Check alert state**: Alerting → Alert rules → find rule → check State and Health
2. **Preview query**: Click "Run queries" in rule editor to see current values
3. **Check `for` duration**: Alert stays `Pending` for the configured `for` duration before firing
4. **Check evaluation**: Verify `interval` — rule evaluates only at this frequency
5. **Check Grafana logs**: `grep "alerting" /var/log/grafana/grafana.log`

### Common fixes

**Condition logic error**
- The `condition` field must reference the refId of the final expression (typically a threshold or math expression), not a data query
- Verify the math/threshold expression produces the expected boolean result

**No data handling**
- Default: `NoData` state, which may not trigger notifications
- Fix: Set `noDataState: "Alerting"` or `noDataState: "OK"` based on preference:
  ```yaml
  noDataState: Alerting     # Treat no data as an alert
  execErrState: Alerting    # Treat execution errors as alert
  ```

**Multi-dimensional alerts**
- If query returns multiple series, each series is evaluated independently
- Use `reduce` expression to aggregate: `refId: B, type: reduce, expression: A, reducer: last`

**Evaluation interval mismatch**
- Rule group interval must be ≤ data source scrape interval for meaningful evaluation
- If `interval: 10s` but Prometheus scrapes every 60s, many evaluations see the same data

**Classic vs unified alerting**
- Grafana 11 uses unified alerting only. Legacy alert tab on dashboards is removed.
- Migrate with: `GET /api/alert-notifications` → recreate as contact points

---

## Notification Delivery Failures

### Symptoms
- Alert fires (visible in UI) but no notification received
- Notification error in Grafana logs

### Diagnostic steps

1. Check **Alerting → Notification policies** — verify route matches alert labels
2. Check **Contact points** → "Test" button — sends test notification
3. Check `group_wait`, `group_interval`, `repeat_interval` — notification may be grouped/suppressed
4. Check **Silences** — active silence may be suppressing notifications
5. Check **Mute timings** — may be in a mute window
6. Check Grafana logs: `grep "notif" /var/log/grafana/grafana.log`

### Common fixes

**Routing mismatch**
- Notifications go to the **first matching route**; order matters
- `matchers` use `=`, `!=`, `=~`, `!~` syntax
- Test with: Alerting → Notification policies → preview routing

**Slack integration**
```yaml
# Common Slack issues:
# 1. Bot not in channel — invite bot to channel first
# 2. Token type — use Bot Token (xoxb-), not User Token
# 3. Scopes — bot needs: chat:write, chat:write.public
settings:
  recipient: "#alerts"      # Include the # prefix
  token: "$SLACK_BOT_TOKEN" # Bot token, not webhook URL
  # OR use webhook:
  url: "https://hooks.slack.com/services/T.../B.../xxx"
```

**PagerDuty**
```yaml
# Use Integration Key (not API key)
# Integration type: Events API v2
settings:
  integrationKey: "$PD_INTEGRATION_KEY"
  severity: "{{ .CommonLabels.severity }}"
  class: "{{ .CommonLabels.alertname }}"
```

**Email (SMTP)**
```ini
# grafana.ini
[smtp]
enabled = true
host = smtp.gmail.com:587
user = alerts@company.com
password = $__file{/etc/grafana/smtp_password}
from_address = alerts@company.com
startTLS_policy = MandatoryStartTLS
```

**Repeat interval too long**
- Default `repeat_interval: 4h` means a firing alert only re-notifies every 4h
- Reduce for critical alerts: `repeat_interval: 15m`

---

## Dashboard Provisioning Conflicts

### Symptoms
- Dashboard changes revert after edit in UI
- `"Dashboard has been changed by another session"` error
- Duplicate dashboards appear

### Root causes and fixes

**File provisioning overwrites UI edits**
- By design: provisioned dashboards are read-only (re-synced on `updateIntervalSeconds`)
- Fix: Set `allowUiUpdates: true` in provider config to allow saving
- Better: Edit dashboard JSON files in Git, not UI

**UID conflicts**
- Two dashboards with the same `uid` cause one to overwrite the other
- Fix: Ensure unique UIDs across all provisioning sources
- Use deterministic UIDs: `team-service-aspect` pattern

**Folder conflicts**
- Provisioning creates folders by name — if a folder with the same name exists from a different source, dashboards may land in the wrong folder
- Fix: Use `folderUid` instead of folder name when possible

**updateIntervalSeconds race**
- Low interval (e.g., 10s) can cause conflicts if file is being written while Grafana scans
- Fix: Use `updateIntervalSeconds: 30` or higher. Write to temp file, then atomic rename.

**foldersFromFilesStructure behavior**
```yaml
options:
  path: /var/lib/grafana/dashboards
  foldersFromFilesStructure: true
```
- Directory structure under `path` maps to Grafana folders
- `path/Infrastructure/cpu.json` → folder "Infrastructure", dashboard "cpu"
- Don't mix with explicit `folder` setting — they conflict

---

## Permission Issues

### Symptoms
- `"Access denied"` or 403 errors
- Dashboard visible but not editable
- Data source queries return empty results despite data existing

### Diagnostic

```bash
# Check user permissions
curl -s http://localhost:3000/api/user -H "Authorization: Bearer $TOKEN" | jq

# Check folder permissions
curl -s http://localhost:3000/api/folders/{uid}/permissions -H "Authorization: Bearer $TOKEN" | jq

# Check data source permissions (Enterprise)
curl -s http://localhost:3000/api/datasources/{id}/permissions -H "Authorization: Bearer $TOKEN" | jq
```

### Grafana role hierarchy

| Role | Dashboards | Data Sources | Alerting | Admin |
|------|-----------|-------------|---------|-------|
| Viewer | View | Query (via panels) | View | — |
| Editor | Create/Edit/Delete | Query | Create/Edit | — |
| Admin | All + Permissions | All + Config | All | Org settings |
| Server Admin | All | All | All | All orgs, users, settings |

### Common fixes

- **Provisioned dashboard not editable**: Provisioned dashboards are read-only unless `allowUiUpdates: true`
- **Folder permissions**: Dashboards inherit folder permissions. Check folder-level ACLs.
- **Team-based access**: Assign folder permissions to teams, not individual users
- **Service account scope**: Create service accounts with minimum required permissions
- **Anonymous access**: Enable with `[auth.anonymous] enabled = true` and set `org_role = Viewer`

---

## LDAP/OAuth Configuration Problems

### LDAP troubleshooting

**Config file location**: Referenced in `grafana.ini` under `[auth.ldap]`:

```ini
[auth.ldap]
enabled = true
config_file = /etc/grafana/ldap.toml
allow_sign_up = true
```

**ldap.toml common issues**:

```toml
[[servers]]
host = "ldap.company.com"
port = 636
use_ssl = true
start_tls = false
ssl_skip_verify = false         # Set true for self-signed certs (dev only)
root_ca_cert = "/etc/grafana/ca.crt"

bind_dn = "cn=grafana,ou=service,dc=company,dc=com"
bind_password = "${LDAP_BIND_PASSWORD}"   # Use env var

search_filter = "(sAMAccountName=%s)"     # AD; for OpenLDAP: "(uid=%s)"
search_base_dns = ["dc=company,dc=com"]

[servers.attributes]
member_of = "memberOf"
email = "mail"
name = "displayName"
surname = "sn"
username = "sAMAccountName"       # or "uid" for OpenLDAP

[[servers.group_mappings]]
group_dn = "cn=grafana-admins,ou=groups,dc=company,dc=com"
org_role = "Admin"

[[servers.group_mappings]]
group_dn = "cn=grafana-editors,ou=groups,dc=company,dc=com"
org_role = "Editor"

[[servers.group_mappings]]
group_dn = "*"
org_role = "Viewer"
```

**Debug LDAP**: Enable debug logging:
```ini
[log]
level = debug
filters = ldap:debug
```

Test from command line: `ldapsearch -H ldaps://ldap.company.com -D "cn=grafana,..." -w password -b "dc=company,dc=com" "(sAMAccountName=testuser)"`

### OAuth troubleshooting

**Generic OAuth**:
```ini
[auth.generic_oauth]
enabled = true
name = SSO
client_id = grafana-client-id
client_secret = $__file{/etc/grafana/oauth_secret}
auth_url = https://sso.company.com/authorize
token_url = https://sso.company.com/token
api_url = https://sso.company.com/userinfo
scopes = openid profile email
role_attribute_path = contains(groups[*], 'grafana-admin') && 'Admin' || 'Viewer'
allow_sign_up = true
```

**Common OAuth issues**:
- **Redirect URI mismatch**: Must match exactly in IdP config — `https://grafana.company.com/login/generic_oauth`
- **TLS errors**: Set `tls_skip_verify_insecure = true` (dev only) or mount CA cert
- **Role mapping not working**: `role_attribute_path` uses JMESPath — test expressions at jmespath.org
- **PKCE required**: Add `use_pkce = true` for OAuth providers requiring PKCE

---

## Panel Rendering Issues

### Symptoms
- Panel shows "No data" when data exists
- Wrong visualization type
- Values display incorrectly

### Common fixes

**"No data" but data exists**
1. Check data source selector on the panel — may point to wrong data source
2. Check time range — data may be outside current window
3. Check variable values — `$var` may be empty or `All` with wrong `allValue`
4. Click "Query inspector" (panel menu → Inspect → Query) to see raw response
5. Verify query in Explore first

**Wrong format for panel type**
| Panel type | Required format |
|-----------|----------------|
| Time series | Time + numeric fields |
| Table | Any tabular data |
| Stat | Single value or reducible series |
| Heatmap | Histogram buckets (le labels) or raw values |
| Logs | Log stream with time, message, level |

**Heatmap with histogram_quantile data**
- Don't use `histogram_quantile()` for heatmap — use raw bucket rates:
  ```promql
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
  ```
- Set format to `Heatmap` in query options

**Stat panel showing wrong value**
- Check `options.reduceOptions.calcs` — should be `["lastNotNull"]`, `["mean"]`, etc.
- Multi-series: set `options.reduceOptions.values: false` to show one stat per series

**Units and decimals**
- Set `fieldConfig.defaults.unit` — see full list at `grafana.com/docs/grafana/latest/panels-visualizations/query-transform-data/`
- Common: `reqps`, `s`, `ms`, `bytes`, `decbytes`, `percent`, `percentunit`, `short`, `none`
- `percentunit` expects 0–1 range; `percent` expects 0–100

---

## Time Zone Confusion

### Symptoms
- Data appears shifted by hours
- Annotations/events show at wrong time
- Different users see different times

### How time zones work in Grafana

1. **Dashboard timezone** (`timezone` field):
   - `""` or `"browser"` — use user's browser timezone
   - `"utc"` — force UTC display
   - Specific tz: `"America/New_York"`
2. **Data source time**: Prometheus stores UTC epoch. Loki timestamps are UTC. SQL sources may store local time.
3. **User preference**: Profile → Preferences → Timezone — overrides dashboard setting if dashboard uses `"browser"`

### Common fixes

**Ops dashboards**: Use `"timezone": "utc"` — eliminates ambiguity across teams in different zones.

**SQL data in local time**:
```sql
-- Convert to UTC in query
SELECT $__timeGroup(created_at AT TIME ZONE 'America/New_York' AT TIME ZONE 'UTC', '1h') AS time, count(*)
FROM events WHERE $__timeFilter(created_at) GROUP BY time ORDER BY time
```

**Annotations at wrong time**: Annotation API expects epoch milliseconds in UTC. Verify with:
```bash
date -d "2024-01-15T10:00:00Z" +%s%3N  # Get UTC epoch ms
```

**Grafana server timezone**: Set `TZ=UTC` env var or in systemd unit to avoid server-local-time confusion.

---

## Missing Data Points

### Symptoms
- Gaps in time series graphs
- Data exists in Explore but not in dashboard panel
- Intermittent data loss appearance

### Root causes and fixes

**Resolution mismatch**
- Panel `maxDataPoints` (default 1500) determines query resolution step
- If time range is 7d with 1500 points → step = ~6.7m → points at <6.7m intervals are averaged/lost
- Fix: Reduce time range or increase `maxDataPoints` (caution: performance)

**Stale markers / series churn**
- Prometheus marks series stale after 5 minutes of no scrapes
- Fix: Use `rate()` or `increase()` which handle staleness. For raw values, use `last_over_time(metric[10m])`.

**$__rate_interval too large**
- When zoom level is very wide, `$__rate_interval` becomes large and smooths out spikes
- Fix: Set `minInterval` on panel to limit minimum resolution

**Connect null values**
```json
{
  "fieldConfig": {
    "defaults": {
      "custom": {
        "spanNulls": true,           // Connect across gaps
        "spanNulls": 3600000         // Connect gaps up to 1h (ms)
      }
    }
  }
}
```

**Query returns no data for part of range**
- Source hasn't collected data for that period
- Fix: Verify with direct source query, not Grafana. Check scrape targets, ingestion pipeline.

---

## Grafana Behind Reverse Proxy

### Symptoms
- Login redirect loops
- WebSocket errors (live features broken)
- Assets fail to load (CSS, JS)
- OAuth callback fails

### Nginx configuration

```nginx
server {
    listen 443 ssl;
    server_name grafana.company.com;

    ssl_certificate /etc/ssl/grafana.crt;
    ssl_certificate_key /etc/ssl/grafana.key;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # WebSocket support (required for live features)
    location /api/live/ {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
```

### Grafana configuration

```ini
[server]
domain = grafana.company.com
root_url = https://grafana.company.com/
serve_from_sub_path = false       # Set true if serving from /grafana/ subpath

# If behind subpath (e.g., /grafana/):
# root_url = https://company.com/grafana/
# serve_from_sub_path = true
```

### Common proxy issues

**Redirect loops**: Ensure `root_url` matches the external URL exactly, including protocol and trailing slash.

**Subpath misconfiguration**: If serving at `/grafana/`, BOTH `root_url` and `serve_from_sub_path` must be set. Nginx:
```nginx
location /grafana/ {
    proxy_pass http://localhost:3000/;  # Note trailing slash
}
```

**Large request bodies**: Provisioning or importing large dashboards may hit body size limits:
```nginx
client_max_body_size 10m;
```

**Timeout for long queries**:
```nginx
proxy_read_timeout 300;
proxy_connect_timeout 60;
proxy_send_timeout 300;
```

---

## Upgrade and Migration Issues

### Pre-upgrade checklist

1. **Backup database**: `cp /var/lib/grafana/grafana.db /backups/grafana-$(date +%F).db`
2. **Backup configs**: `cp -r /etc/grafana /backups/grafana-config-$(date +%F)/`
3. **Export dashboards**: Use API or dashboard-export script
4. **Check breaking changes**: Review release notes at `grafana.com/docs/grafana/latest/whatsnew/`
5. **Test in staging**: Run new version against database copy first

### Common migration issues

**Database migration failures**
```bash
# Check Grafana logs for migration errors
journalctl -u grafana-server | grep -i "migration"

# Force re-run migrations (caution!)
grafana-server --config=/etc/grafana/grafana.ini migrate
```

**Plugin compatibility**
- After upgrade, plugins may need updates
- Check: `grafana cli plugins ls`
- Update all: `grafana cli plugins update-all`
- Some plugins dropped in newer versions — check deprecation notices

**Legacy alerting → Unified alerting migration**
- Grafana 11 only supports unified alerting
- Auto-migration runs on upgrade but may need manual review
- Export legacy alerts before upgrade: `GET /api/alerts`
- Check migrated rules: Alerting → Alert rules → look for `migrated-` prefixed rules

**Dashboard schema version**
- Newer Grafana versions bump `schemaVersion` in dashboard JSON
- Old dashboards auto-upgrade on load, but re-exporting updates the schema
- If version-controlling dashboards, re-export after upgrade to capture schema changes

**grafana.ini deprecated settings**
```ini
# Deprecated in 11.x — move to new syntax:
# OLD: [auth.proxy] enabled = true
# NEW: [auth.proxy] enabled = true  (same, but check new options)

# Check for deprecated settings:
grafana-server --config=/etc/grafana/grafana.ini --verify-config
```

### Version-specific notes

| Upgrade path | Key changes |
|-------------|-------------|
| 9.x → 10.x | New navigation, Scenes, correlations, subfolders alpha |
| 10.x → 11.x | Unified alerting only, Angular plugins removed, subfolders GA |
| Any → latest | Always check: deprecated APIs, removed plugins, auth changes |

### Rollback procedure

1. Stop Grafana: `systemctl stop grafana-server`
2. Restore database: `cp /backups/grafana-YYYY-MM-DD.db /var/lib/grafana/grafana.db`
3. Restore configs: `cp -r /backups/grafana-config-YYYY-MM-DD/* /etc/grafana/`
4. Downgrade package: `apt install grafana=10.4.0` or `yum downgrade grafana-10.4.0`
5. Start Grafana: `systemctl start grafana-server`
6. Verify: Check dashboards, alerts, data sources
