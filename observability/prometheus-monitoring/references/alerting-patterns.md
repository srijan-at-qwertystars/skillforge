# Alerting Patterns and Best Practices

Production-grade alerting strategies for Prometheus and Alertmanager.

## Table of Contents

- [SLO-Based Alerting](#slo-based-alerting)
- [Multi-Window Multi-Burn-Rate Alerts](#multi-window-multi-burn-rate-alerts)
- [Routing Trees](#routing-trees)
- [Inhibition Rules](#inhibition-rules)
- [Silencing](#silencing)
- [Notification Templates](#notification-templates)
- [PagerDuty Integration](#pagerduty-integration)
- [Slack Integration](#slack-integration)
- [Webhook Integration](#webhook-integration)
- [Runbook Links](#runbook-links)
- [Alert Fatigue Prevention](#alert-fatigue-prevention)
- [Alert Design Principles](#alert-design-principles)
- [Complete Example: Production Alert Stack](#complete-example-production-alert-stack)

---

## SLO-Based Alerting

SLO-based alerting shifts from symptom-based thresholds ("CPU > 80%") to user-impact SLOs ("99.9% of requests succeed within 300ms").

### Core concepts

- **SLI (Service Level Indicator)** — the metric measuring user experience (e.g., request success rate, latency)
- **SLO (Service Level Objective)** — the target for the SLI (e.g., 99.9% success rate over 30 days)
- **Error budget** — the allowed failure: `1 - SLO` (e.g., 0.1% of requests can fail)
- **Burn rate** — how fast the error budget is being consumed relative to the SLO window

### Defining SLIs

```promql
# Availability SLI — ratio of successful requests
sli:availability = (
  sum(rate(http_requests_total{status!~"5.."}[5m]))
  / sum(rate(http_requests_total[5m]))
)

# Latency SLI — ratio of requests under threshold
sli:latency = (
  sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
  / sum(rate(http_request_duration_seconds_count[5m]))
)
```

### Error budget calculation

```promql
# 30-day error budget for 99.9% availability SLO
# Budget = (1 - 0.999) * total_requests_in_30d
# Budget remaining:
1 - (
  sum(increase(http_requests_total{status=~"5.."}[30d]))
  / (sum(increase(http_requests_total[30d])) * (1 - 0.999))
)
```

### Simple SLO alert (not recommended alone)

```yaml
- alert: SLOBudgetExhausted
  expr: |
    1 - (
      sum(rate(http_requests_total{status!~"5.."}[30d]))
      / sum(rate(http_requests_total[30d]))
    ) > 0.001  # 99.9% SLO
  for: 5m
  labels:
    severity: critical
```

**Problem:** This fires too late (budget already exhausted) or requires a very long evaluation window.

**Solution:** Use multi-window multi-burn-rate alerts (next section).

---

## Multi-Window Multi-Burn-Rate Alerts

The gold standard for SLO-based alerting, from Google's SRE book. Alert when the error budget is being consumed faster than expected.

### Burn rate explained

A burn rate of 1x means the error budget will be exactly consumed over the full SLO window (e.g., 30 days).
- **Burn rate 14.4x** — budget consumed in ~2 hours → page immediately
- **Burn rate 6x** — budget consumed in ~5 hours → page soon
- **Burn rate 1x** — budget consumed in 30 days → ticket, no page

### Multi-window approach

Use two windows per alert: a **long window** for significance and a **short window** for recency.

| Severity | Burn rate | Long window | Short window | Action |
|----------|-----------|-------------|--------------|--------|
| Critical (page) | 14.4x | 1h | 5m | Wake someone up |
| Critical (page) | 6x | 6h | 30m | Wake someone up |
| Warning (ticket) | 3x | 1d | 2h | File a ticket |
| Warning (ticket) | 1x | 3d | 6h | Review next business day |

### Recording rules for burn rates

```yaml
groups:
  - name: slo_burn_rates
    interval: 30s
    rules:
      # --- Error ratios at multiple windows ---
      - record: slo:http_error_ratio:rate5m
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
          / sum(rate(http_requests_total[5m])) by (service)

      - record: slo:http_error_ratio:rate30m
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[30m])) by (service)
          / sum(rate(http_requests_total[30m])) by (service)

      - record: slo:http_error_ratio:rate1h
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[1h])) by (service)
          / sum(rate(http_requests_total[1h])) by (service)

      - record: slo:http_error_ratio:rate2h
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[2h])) by (service)
          / sum(rate(http_requests_total[2h])) by (service)

      - record: slo:http_error_ratio:rate6h
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[6h])) by (service)
          / sum(rate(http_requests_total[6h])) by (service)

      - record: slo:http_error_ratio:rate1d
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[1d])) by (service)
          / sum(rate(http_requests_total[1d])) by (service)

      - record: slo:http_error_ratio:rate3d
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[3d])) by (service)
          / sum(rate(http_requests_total[3d])) by (service)
```

### Alerting rules using burn rates

For a 99.9% SLO (error budget = 0.001):

```yaml
groups:
  - name: slo_alerts
    rules:
      # Critical: 14.4x burn rate, detected in 1h/5m windows
      - alert: SLOErrorBudgetBurn_Critical_Fast
        expr: |
          slo:http_error_ratio:rate1h > (14.4 * 0.001)
          and
          slo:http_error_ratio:rate5m > (14.4 * 0.001)
        for: 2m
        labels:
          severity: critical
          slo: availability
        annotations:
          summary: "{{ $labels.service }} burning error budget 14.4x (2h to exhaustion)"
          description: "1h error rate: {{ $value | humanizePercentage }}. Budget consumed in ~2 hours at current rate."
          runbook_url: "https://runbooks.example.com/slo-budget-burn"

      # Critical: 6x burn rate, detected in 6h/30m windows
      - alert: SLOErrorBudgetBurn_Critical_Slow
        expr: |
          slo:http_error_ratio:rate6h > (6 * 0.001)
          and
          slo:http_error_ratio:rate30m > (6 * 0.001)
        for: 5m
        labels:
          severity: critical
          slo: availability
        annotations:
          summary: "{{ $labels.service }} burning error budget 6x (5h to exhaustion)"
          runbook_url: "https://runbooks.example.com/slo-budget-burn"

      # Warning: 3x burn rate, detected in 1d/2h windows
      - alert: SLOErrorBudgetBurn_Warning
        expr: |
          slo:http_error_ratio:rate1d > (3 * 0.001)
          and
          slo:http_error_ratio:rate2h > (3 * 0.001)
        for: 15m
        labels:
          severity: warning
          slo: availability
        annotations:
          summary: "{{ $labels.service }} burning error budget 3x (10d to exhaustion)"
          runbook_url: "https://runbooks.example.com/slo-budget-burn"

      # Info: 1x burn rate, detected in 3d/6h windows
      - alert: SLOErrorBudgetBurn_Info
        expr: |
          slo:http_error_ratio:rate3d > (1 * 0.001)
          and
          slo:http_error_ratio:rate6h > (1 * 0.001)
        for: 30m
        labels:
          severity: info
          slo: availability
        annotations:
          summary: "{{ $labels.service }} consuming error budget at expected rate"
```

### Latency SLO burn rates

```yaml
groups:
  - name: latency_slo_burn
    rules:
      # Latency SLI: percentage of requests above 300ms threshold
      - record: slo:http_latency_error_ratio:rate1h
        expr: |
          1 - (
            sum(rate(http_request_duration_seconds_bucket{le="0.3"}[1h])) by (service)
            / sum(rate(http_request_duration_seconds_count[1h])) by (service)
          )

      - record: slo:http_latency_error_ratio:rate5m
        expr: |
          1 - (
            sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m])) by (service)
            / sum(rate(http_request_duration_seconds_count[5m])) by (service)
          )

      # 99.5% latency SLO (budget = 0.005)
      - alert: LatencySLOBurn_Critical
        expr: |
          slo:http_latency_error_ratio:rate1h > (14.4 * 0.005)
          and
          slo:http_latency_error_ratio:rate5m > (14.4 * 0.005)
        for: 2m
        labels:
          severity: critical
          slo: latency
        annotations:
          summary: "{{ $labels.service }} latency SLO burning at 14.4x"
```

---

## Routing Trees

### Design principles

1. **Route from most specific to least specific**
2. **Use `continue: true`** when an alert should notify multiple channels
3. **Group by meaningful labels** — `alertname`, `service`, `cluster`
4. **Set appropriate timing** — critical alerts group faster, warnings can batch

### Production routing tree

```yaml
route:
  receiver: default-slack
  group_by: ['alertname', 'service', 'cluster']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    # Critical SLO burns — page immediately
    - match:
        severity: critical
        slo: availability
      receiver: pagerduty-primary
      group_wait: 10s
      repeat_interval: 1h
      routes:
        # Payment service — dedicated on-call
        - match:
            service: payment
          receiver: pagerduty-payments
          continue: true
        # Also notify Slack for visibility
        - match_re:
            service: ".+"
          receiver: slack-critical
          continue: false

    # Critical infrastructure alerts
    - match:
        severity: critical
      receiver: pagerduty-infra
      group_wait: 10s
      repeat_interval: 2h
      continue: true

    # Critical also goes to Slack
    - match:
        severity: critical
      receiver: slack-critical
      continue: false

    # Warnings — Slack only, batched
    - match:
        severity: warning
      receiver: slack-warnings
      group_wait: 2m
      group_interval: 10m
      repeat_interval: 12h

    # Info — low-priority Slack channel
    - match:
        severity: info
      receiver: slack-info
      group_wait: 5m
      repeat_interval: 24h
```

### Time-based routing (business hours)

```yaml
route:
  routes:
    - match:
        severity: critical
      receiver: pagerduty-24x7
    - match:
        severity: warning
      active_time_intervals:
        - business-hours
      receiver: slack-team
    - match:
        severity: warning
      active_time_intervals:
        - outside-business-hours
      receiver: slack-oncall

time_intervals:
  - name: business-hours
    time_intervals:
      - weekdays: ['monday:friday']
        times:
          - start_time: '09:00'
            end_time: '17:00'
  - name: outside-business-hours
    time_intervals:
      - weekdays: ['monday:friday']
        times:
          - start_time: '00:00'
            end_time: '09:00'
          - start_time: '17:00'
            end_time: '24:00'
      - weekdays: ['saturday', 'sunday']
```

---

## Inhibition Rules

Inhibition suppresses notifications for certain alerts when other related alerts are already firing. This prevents alert storms.

### Common inhibition patterns

```yaml
inhibit_rules:
  # Suppress warnings when critical exists for same alert
  - source_matchers:
      - severity = critical
    target_matchers:
      - severity = warning
    equal: ['alertname', 'service', 'instance']

  # Suppress all app alerts when the node is down
  - source_matchers:
      - alertname = NodeDown
    target_matchers:
      - severity =~ "warning|critical"
    equal: ['instance']

  # Suppress specific alerts when cluster is degraded
  - source_matchers:
      - alertname = ClusterDegraded
    target_matchers:
      - alertname =~ "PodCrashLooping|HighErrorRate|HighLatency"
    equal: ['cluster']

  # Suppress service alerts during known maintenance
  - source_matchers:
      - alertname = PlannedMaintenance
    target_matchers:
      - severity =~ ".*"
    equal: ['service']

  # Suppress child service alerts when parent is down
  - source_matchers:
      - alertname = DatabaseDown
    target_matchers:
      - alertname =~ "HighErrorRate|SlowQueries"
    equal: ['cluster']
```

### Inhibition design rules

1. **Always require `equal` labels** — prevents overly broad inhibition
2. **Be explicit** about source and target matchers — avoid regex wildcards for source
3. **Test inhibition** — use `amtool` to verify
4. **Don't over-inhibit** — a node-down should not hide security alerts

---

## Silencing

Silences temporarily mute notifications. Use for planned maintenance or known issues.

### Creating silences

```bash
# Via amtool CLI
amtool silence add \
  --alertmanager.url=http://localhost:9093 \
  --author="oncall@example.com" \
  --comment="Planned maintenance on db-01" \
  --duration=2h \
  alertname=DiskSpaceLow instance=db-01:9100

# Silence all warnings for a service
amtool silence add \
  --alertmanager.url=http://localhost:9093 \
  --author="oncall@example.com" \
  --comment="Deploying v2.3.0" \
  --duration=30m \
  severity=warning service=api

# Silence with regex match
amtool silence add \
  --alertmanager.url=http://localhost:9093 \
  --author="oncall@example.com" \
  --comment="Network maintenance" \
  --duration=4h \
  alertname=~"Network.*"

# List active silences
amtool silence query --alertmanager.url=http://localhost:9093

# Remove a silence
amtool silence expire --alertmanager.url=http://localhost:9093 <silence-id>
```

### Via API

```bash
# Create silence via API
curl -X POST http://localhost:9093/api/v2/silences \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [
      {"name": "alertname", "value": "DiskSpaceLow", "isRegex": false},
      {"name": "instance", "value": "db-01:9100", "isRegex": false}
    ],
    "startsAt": "2024-01-15T10:00:00Z",
    "endsAt": "2024-01-15T14:00:00Z",
    "createdBy": "oncall@example.com",
    "comment": "Planned disk migration"
  }'
```

### Silence best practices

1. **Always set an end time** — avoid indefinite silences
2. **Include a comment** explaining why the silence exists
3. **Set author** for accountability
4. **Use specific matchers** — avoid broad silences that hide real problems
5. **Review active silences** regularly — stale silences mask real issues
6. **Automate silence creation** for known maintenance windows via CI/CD

---

## Notification Templates

### Slack notification template

```yaml
receivers:
  - name: slack-critical
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/T00/B00/XXX'
        channel: '#alerts-critical'
        send_resolved: true
        title: '{{ if eq .Status "firing" }}🔴{{ else }}✅{{ end }} [{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
        text: >-
          {{ range .Alerts }}
          *Alert:* {{ .Labels.alertname }}
          *Severity:* {{ .Labels.severity }}
          *Service:* {{ .Labels.service | default "unknown" }}
          *Instance:* {{ .Labels.instance | default "N/A" }}
          *Summary:* {{ .Annotations.summary }}
          *Description:* {{ .Annotations.description }}
          {{ if .Annotations.runbook_url }}*Runbook:* {{ .Annotations.runbook_url }}{{ end }}
          *Started:* {{ .StartsAt.Format "2006-01-02 15:04:05 UTC" }}
          {{ if eq .Status "resolved" }}*Resolved:* {{ .EndsAt.Format "2006-01-02 15:04:05 UTC" }}{{ end }}
          ---
          {{ end }}
        color: '{{ if eq .Status "firing" }}{{ if eq (index .Alerts 0).Labels.severity "critical" }}danger{{ else }}warning{{ end }}{{ else }}good{{ end }}'
        actions:
          - type: button
            text: 'Runbook'
            url: '{{ (index .Alerts 0).Annotations.runbook_url }}'
          - type: button
            text: 'Silence'
            url: '{{ template "__alertmanagerURL" . }}/#/silences/new?filter=%7Balertname%3D%22{{ .GroupLabels.alertname }}%22%7D'
          - type: button
            text: 'Dashboard'
            url: '{{ (index .Alerts 0).Annotations.dashboard_url }}'
```

### Email notification template

```yaml
receivers:
  - name: email-team
    email_configs:
      - to: 'team@example.com'
        send_resolved: true
        headers:
          Subject: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }} - {{ .GroupLabels.service }}'
        html: |
          <h2>{{ if eq .Status "firing" }}🔴 FIRING{{ else }}✅ RESOLVED{{ end }}</h2>
          <table border="1" cellpadding="5">
            <tr><th>Alert</th><th>Severity</th><th>Instance</th><th>Summary</th></tr>
            {{ range .Alerts }}
            <tr>
              <td>{{ .Labels.alertname }}</td>
              <td>{{ .Labels.severity }}</td>
              <td>{{ .Labels.instance }}</td>
              <td>{{ .Annotations.summary }}</td>
            </tr>
            {{ end }}
          </table>
          {{ if (index .Alerts 0).Annotations.runbook_url }}
          <p><a href="{{ (index .Alerts 0).Annotations.runbook_url }}">Runbook</a></p>
          {{ end }}
```

### Custom Go templates

Create a shared template file referenced by Alertmanager:

```yaml
# alertmanager.yml
templates:
  - '/etc/alertmanager/templates/*.tmpl'
```

```go
{{/* /etc/alertmanager/templates/custom.tmpl */}}

{{ define "custom.title" }}
[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .GroupLabels.SortedPairs.Values | join " " }}
{{ end }}

{{ define "custom.text" }}
{{ if gt (len .Alerts.Firing) 0 }}
*Firing:*
{{ range .Alerts.Firing }}
  • {{ .Labels.alertname }}: {{ .Annotations.summary }}
    Labels: {{ range .Labels.SortedPairs }} {{ .Name }}={{ .Value }}{{ end }}
{{ end }}
{{ end }}
{{ if gt (len .Alerts.Resolved) 0 }}
*Resolved:*
{{ range .Alerts.Resolved }}
  • {{ .Labels.alertname }}: {{ .Annotations.summary }}
{{ end }}
{{ end }}
{{ end }}
```

---

## PagerDuty Integration

### Events API v2 (recommended)

```yaml
receivers:
  - name: pagerduty-critical
    pagerduty_configs:
      - routing_key: '<PAGERDUTY_INTEGRATION_KEY>'
        severity: '{{ if eq .GroupLabels.severity "critical" }}critical{{ else }}warning{{ end }}'
        description: '{{ .GroupLabels.alertname }}: {{ (index .Alerts 0).Annotations.summary }}'
        details:
          firing: '{{ template "pagerduty.default.description" . }}'
          service: '{{ .GroupLabels.service }}'
          cluster: '{{ .GroupLabels.cluster }}'
        links:
          - href: '{{ (index .Alerts 0).Annotations.runbook_url }}'
            text: Runbook
          - href: '{{ (index .Alerts 0).Annotations.dashboard_url }}'
            text: Dashboard
        images:
          - src: '{{ (index .Alerts 0).Annotations.graph_url }}'
            alt: 'Metric graph'
```

### PagerDuty best practices

1. **Map severity correctly** — critical → PD critical, warning → PD warning
2. **Include runbook links** — PD supports link objects that appear as buttons
3. **Set `send_resolved: true`** — automatically resolve PD incidents
4. **Use different routing keys** for different services/teams
5. **Include context** — dashboard URLs, metric values, affected instances

---

## Slack Integration

### Setup

1. Create a Slack app at https://api.slack.com/apps
2. Enable Incoming Webhooks
3. Add webhook to workspace, select channel
4. Copy the webhook URL

### Configuration

```yaml
receivers:
  - name: slack-alerts
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/T00/B00/XXX'
        channel: '#alerts'
        send_resolved: true
        username: 'Prometheus'
        icon_emoji: ':prometheus:'
        title: '{{ template "custom.title" . }}'
        text: '{{ template "custom.text" . }}'
        fallback: '{{ .GroupLabels.alertname }}: {{ .Status }}'
        color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'
```

### Slack best practices

1. **Separate channels** by severity: `#alerts-critical`, `#alerts-warning`, `#alerts-info`
2. **Use thread replies** for resolved notifications (via Slack API)
3. **Include action buttons** for runbooks and silencing
4. **Keep messages concise** — details in thread or linked dashboards
5. **Rate limit** — set `repeat_interval` high enough to avoid channel flooding

---

## Webhook Integration

### Generic webhook receiver

```yaml
receivers:
  - name: webhook-receiver
    webhook_configs:
      - url: 'https://alerthandler.example.com/alerts'
        send_resolved: true
        http_config:
          authorization:
            type: Bearer
            credentials: '<TOKEN>'
          tls_config:
            cert_file: /etc/alertmanager/client.pem
            key_file: /etc/alertmanager/client-key.pem
        max_alerts: 10  # max alerts per webhook call
```

### Webhook payload structure

```json
{
  "version": "4",
  "groupKey": "{}:{alertname=\"HighErrorRate\"}",
  "status": "firing",
  "receiver": "webhook-receiver",
  "groupLabels": {"alertname": "HighErrorRate"},
  "commonLabels": {"alertname": "HighErrorRate", "severity": "critical"},
  "commonAnnotations": {"summary": "High error rate detected"},
  "externalURL": "http://alertmanager:9093",
  "alerts": [
    {
      "status": "firing",
      "labels": {"alertname": "HighErrorRate", "service": "api", "severity": "critical"},
      "annotations": {"summary": "Error rate 5.2% on api"},
      "startsAt": "2024-01-15T10:00:00Z",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://prometheus:9090/graph?g0.expr=...",
      "fingerprint": "abc123"
    }
  ]
}
```

### Webhook use cases

- **Custom ticketing** — create Jira/Linear tickets from alerts
- **ChatOps** — post to Teams, Discord, or custom bots
- **Auto-remediation** — trigger runbooks, restart services, scale infrastructure
- **Audit logging** — record all alert state changes to a database

---

## Runbook Links

### Adding runbook links to alerts

```yaml
rules:
  - alert: HighErrorRate
    expr: job:http_error_ratio:rate5m > 0.05
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "High error rate on {{ $labels.job }}"
      runbook_url: "https://runbooks.example.com/high-error-rate"
      dashboard_url: "https://grafana.example.com/d/http-overview?var-service={{ $labels.service }}"
```

### Runbook content template

Each runbook should contain:

1. **Alert description** — what does this alert mean?
2. **Impact** — what is the user impact?
3. **Investigation steps** — PromQL queries to run, logs to check
4. **Common causes** — known root causes and their frequency
5. **Remediation steps** — how to fix each common cause
6. **Escalation** — who to contact if basic steps don't resolve
7. **Post-incident** — what to document after resolution

### Runbook URL patterns

```yaml
# Static URLs
runbook_url: "https://runbooks.example.com/alerts/{{ $labels.alertname | toLower }}"

# With service context
runbook_url: "https://wiki.example.com/oncall/runbooks/{{ $labels.service }}/{{ $labels.alertname }}"

# Grafana dashboard with variables
dashboard_url: "https://grafana.example.com/d/svc-overview?var-service={{ $labels.service }}&var-instance={{ $labels.instance }}"
```

---

## Alert Fatigue Prevention

Alert fatigue is the #1 cause of missed critical alerts. Every unnecessary alert trains engineers to ignore notifications.

### Principles

1. **Every alert must be actionable** — if there's nothing to do, remove the alert
2. **Every alert must require human judgment** — if it can be auto-remediated, automate it
3. **Every alert should represent user impact** — infrastructure metrics alone are rarely worth paging for
4. **Prefer fewer, smarter alerts** over many simple threshold alerts

### Techniques

**1. Use SLO-based alerting instead of threshold alerting:**
```yaml
# BAD: fires on any CPU spike, even if harmless
- alert: HighCPU
  expr: cpu_usage > 80
  for: 5m

# GOOD: fires when user experience is degraded
- alert: SLOErrorBudgetBurn
  expr: |
    slo:http_error_ratio:rate1h > (14.4 * 0.001)
    and slo:http_error_ratio:rate5m > (14.4 * 0.001)
  for: 2m
```

**2. Increase `for` duration:**
```yaml
# Reduce flapping — require sustained condition
- alert: DiskSpaceLow
  expr: disk_usage_percent > 90
  for: 30m  # not 1m — transient spikes are not critical
```

**3. Use `repeat_interval` wisely:**
```yaml
route:
  repeat_interval: 4h  # don't re-send the same alert every 5 minutes
```

**4. Use inhibition to suppress cascading alerts:**
```yaml
inhibit_rules:
  - source_matchers: [alertname = ClusterDown]
    target_matchers: [severity =~ "warning|critical"]
    equal: [cluster]
```

**5. Regular alert review process:**
- Track: How many alerts fired this week? How many were actionable?
- Target: < 5 pages per on-call shift per engineer
- Remove alerts that fire often but never lead to action
- Convert non-urgent alerts to tickets or dashboards

**6. Severity discipline:**

| Severity | Response | Channel | When to use |
|----------|----------|---------|-------------|
| critical | Page, wake up | PagerDuty | Active user impact, data loss risk |
| warning | Next business day | Slack | Degraded but functional, budget burn |
| info | Review weekly | Dashboard | Trends, capacity planning |

**7. Aggregate alerts:**
```yaml
# BAD: one alert per pod
- alert: PodRestarting
  expr: increase(kube_pod_container_status_restarts_total[1h]) > 3

# BETTER: aggregate by service
- alert: ServiceUnstable
  expr: |
    sum(increase(kube_pod_container_status_restarts_total[1h])) by (namespace, deployment) > 10
```

### Measuring alert quality

```promql
# Alerts fired per day (target: < 20 across all services)
sum(increase(ALERTS_FOR_STATE[1d]))

# Most frequent firing alerts (candidates for removal/tuning)
topk(10, sum(increase(ALERTS_FOR_STATE[7d])) by (alertname))

# Alert duration (long-firing alerts = possibly not actionable)
avg(ALERTS_FOR_STATE) by (alertname) / 3600  # hours
```

---

## Alert Design Principles

### The 5 rules of good alerts

1. **Alert on symptoms, not causes** — "error rate > 1%" not "CPU > 80%"
2. **Alert on user impact** — "users seeing errors" not "backend pod restarted"
3. **Include context** — annotations with dashboard URLs, runbook links, current metric values
4. **Set appropriate severity** — not everything is critical
5. **Use `for` to prevent flapping** — minimum 2-5 minutes for page-worthy alerts

### Alert annotation template

```yaml
annotations:
  summary: "Brief one-line summary with {{ $labels.service }}"
  description: |
    The error rate for {{ $labels.service }} is {{ $value | humanizePercentage }}.
    This exceeds the SLO threshold of 0.1%.
    Current burn rate: {{ $value | humanize }}x.
  runbook_url: "https://runbooks.example.com/{{ $labels.alertname | toLower }}"
  dashboard_url: "https://grafana.example.com/d/svc?var-service={{ $labels.service }}"
  impact: "Users may experience errors when using {{ $labels.service }}"
  action: "Check application logs and recent deployments"
```

---

## Complete Example: Production Alert Stack

### alerting-rules.yml

```yaml
groups:
  # --- SLO Burn Rate Alerts ---
  - name: slo_availability
    rules:
      - alert: AvailabilitySLOBurn_Page
        expr: |
          slo:http_error_ratio:rate1h > (14.4 * 0.001)
          and slo:http_error_ratio:rate5m > (14.4 * 0.001)
        for: 2m
        labels:
          severity: critical
          slo: availability
          tier: "1"
        annotations:
          summary: "{{ $labels.service }} error budget burning at 14.4x"
          runbook_url: "https://runbooks.example.com/slo-budget-burn"

      - alert: AvailabilitySLOBurn_Ticket
        expr: |
          slo:http_error_ratio:rate1d > (3 * 0.001)
          and slo:http_error_ratio:rate2h > (3 * 0.001)
        for: 15m
        labels:
          severity: warning
          slo: availability
          tier: "2"
        annotations:
          summary: "{{ $labels.service }} error budget burning at 3x"

  # --- Infrastructure ---
  - name: infrastructure
    rules:
      - alert: NodeDown
        expr: up{job="node-exporter"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Node {{ $labels.instance }} is unreachable"

      - alert: DiskWillFillIn4Hours
        expr: predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4 * 3600) < 0
        for: 30m
        labels:
          severity: critical
        annotations:
          summary: "Disk on {{ $labels.instance }} predicted to fill in 4 hours"

      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.9
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Memory usage above 90% on {{ $labels.instance }}"

  # --- Prometheus Self-Monitoring ---
  - name: prometheus_self
    rules:
      - alert: PrometheusHighCardinality
        expr: prometheus_tsdb_head_series > 2000000
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Prometheus has {{ $value }} active series"

      - alert: PrometheusRuleEvaluationSlow
        expr: prometheus_rule_evaluation_duration_seconds{quantile="0.99"} > 30
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Rule evaluation taking {{ $value }}s"

      - alert: AlertmanagerNotificationsFailing
        expr: rate(prometheus_notifications_dropped_total[5m]) > 0
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Alertmanager is dropping notifications"
```
