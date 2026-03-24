# Load Test Reporting and Visualization

## Table of Contents

- [Grafana + InfluxDB for k6](#grafana--influxdb-for-k6)
- [Prometheus + Grafana for Locust](#prometheus--grafana-for-locust)
- [k6 Cloud Dashboards](#k6-cloud-dashboards)
- [Custom HTML Reports](#custom-html-reports)
- [SLA/SLO Validation](#slaslo-validation)
- [Trend Analysis Across Runs](#trend-analysis-across-runs)
- [Executive Summary Generation](#executive-summary-generation)
- [Performance Budgets](#performance-budgets)
- [Alerting on Regressions](#alerting-on-regressions)

---

## Grafana + InfluxDB for k6

### Architecture

```
k6 ──→ InfluxDB (time-series storage) ──→ Grafana (visualization)
                                              │
                                              ├─ Real-time dashboards
                                              ├─ Alerting rules
                                              └─ Annotations for events
```

### Quick Setup

```bash
# Start InfluxDB + Grafana with Docker Compose
# (see assets/docker-compose-monitoring.yml for full config)
docker compose up -d influxdb grafana

# Run k6 with InfluxDB output
k6 run --out influxdb=http://localhost:8086/k6 script.js

# Multiple outputs simultaneously
k6 run \
  --out influxdb=http://localhost:8086/k6 \
  --out json=results.json \
  script.js
```

### InfluxDB Configuration

```bash
# Environment variables for k6 InfluxDB output
export K6_INFLUXDB_ADDR=http://localhost:8086
export K6_INFLUXDB_DB=k6
export K6_INFLUXDB_USERNAME=k6
export K6_INFLUXDB_PASSWORD=k6password
export K6_INFLUXDB_TAGS_AS_FIELDS=vu:int,iter:int,url
export K6_INFLUXDB_PUSH_INTERVAL=5s

k6 run --out influxdb script.js
```

### Key Grafana Dashboard (ID: 2587)

Import Grafana dashboard #2587 ("k6 Load Testing Results") for pre-built panels:

| Panel | Query (InfluxQL) | Purpose |
|-------|-----------------|---------|
| RPS | `SELECT count("value") FROM "http_reqs" WHERE $timeFilter GROUP BY time($__interval)` | Throughput over time |
| Response Time | `SELECT percentile("value", 95) FROM "http_req_duration" WHERE $timeFilter GROUP BY time($__interval)` | Latency trend |
| Error Rate | `SELECT mean("value") FROM "http_req_failed" WHERE $timeFilter GROUP BY time($__interval)` | Failure rate |
| VUs | `SELECT last("value") FROM "vus" WHERE $timeFilter GROUP BY time($__interval)` | Virtual users active |
| Checks | `SELECT mean("value") FROM "checks" WHERE $timeFilter GROUP BY time($__interval)` | Assertion pass rate |

### Custom Dashboard Panels

```json
// Latency percentile panel (Grafana JSON model)
{
  "title": "Latency Percentiles",
  "type": "timeseries",
  "targets": [
    {
      "query": "SELECT percentile(\"value\", 50) AS \"p50\" FROM \"http_req_duration\" WHERE $timeFilter GROUP BY time($__interval)",
      "alias": "p50"
    },
    {
      "query": "SELECT percentile(\"value\", 95) AS \"p95\" FROM \"http_req_duration\" WHERE $timeFilter GROUP BY time($__interval)",
      "alias": "p95"
    },
    {
      "query": "SELECT percentile(\"value\", 99) AS \"p99\" FROM \"http_req_duration\" WHERE $timeFilter GROUP BY time($__interval)",
      "alias": "p99"
    }
  ],
  "fieldConfig": {
    "defaults": { "unit": "ms" }
  }
}
```

### InfluxDB Retention Policies

```sql
-- Keep detailed data for 30 days, aggregated data longer
CREATE RETENTION POLICY "thirty_days" ON "k6" DURATION 30d REPLICATION 1 DEFAULT
CREATE RETENTION POLICY "one_year" ON "k6" DURATION 365d REPLICATION 1

-- Downsample data for long-term trend analysis
CREATE CONTINUOUS QUERY "cq_hourly_p95" ON "k6"
BEGIN
  SELECT percentile("value", 95) AS "p95",
         percentile("value", 99) AS "p99",
         mean("value") AS "avg",
         count("value") AS "count"
  INTO "one_year"."http_req_duration_hourly"
  FROM "http_req_duration"
  GROUP BY time(1h), *
END
```

---

## Prometheus + Grafana for Locust

### Locust Prometheus Exporter

```python
# Install: pip install locust-plugins[prometheus]
# locustfile.py
from locust import HttpUser, task, between
from locust_plugins.listeners import prometheus

class APIUser(HttpUser):
    wait_time = between(1, 3)

    @task
    def load_test(self):
        self.client.get("/api/endpoint")
```

```bash
# Run Locust with Prometheus metrics exposed
locust -f locustfile.py --headless -u 100 -r 10 -t 5m

# Metrics available at http://localhost:8089/export/prometheus
```

### Alternative: locust-exporter Sidecar

```yaml
# docker-compose.yml
services:
  locust-master:
    image: locustio/locust
    command: -f /locustfile.py --master --headless -u 100 -r 10 -t 5m
    ports:
      - "8089:8089"
    volumes:
      - ./locustfile.py:/locustfile.py

  locust-exporter:
    image: containersol/locust_exporter
    environment:
      - LOCUST_EXPORTER_URI=http://locust-master:8089
    ports:
      - "9646:9646"  # Prometheus scrape endpoint

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
```

### Prometheus Config for Locust

```yaml
# prometheus.yml
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: 'locust'
    static_configs:
      - targets: ['locust-exporter:9646']
    metrics_path: /metrics
```

### Grafana Dashboard for Locust

Key PromQL queries:

```promql
# Requests per second
rate(locust_requests_total[1m])

# Response time p95
histogram_quantile(0.95, rate(locust_response_times_bucket[1m]))

# Error rate
rate(locust_errors_total[1m]) / rate(locust_requests_total[1m])

# Active users
locust_users

# Requests per second by endpoint
rate(locust_requests_total{name!="Aggregated"}[1m])
```

---

## k6 Cloud Dashboards

### Features

- **Real-time streaming**: Results appear as test runs
- **Geo-distributed views**: See latency by load zone
- **Comparison mode**: Overlay multiple test runs
- **Performance insights**: Automated anomaly detection
- **Trend analysis**: Track metrics across test runs over time
- **Shareable URLs**: Send results to stakeholders without Grafana access

### Configuration

```javascript
export const options = {
  cloud: {
    projectID: 12345,
    name: 'API Load Test',
    note: 'Testing after Redis cache upgrade',
  },
};
```

```bash
# Stream local results to k6 Cloud
k6 run --out cloud script.js

# Run fully on k6 Cloud infrastructure
k6 cloud script.js

# Set project via env var
K6_CLOUD_PROJECT_ID=12345 k6 run --out cloud script.js
```

### Cloud vs Self-Hosted Comparison

| Feature | k6 Cloud | Self-Hosted (Grafana+InfluxDB) |
|---------|----------|-------------------------------|
| Setup | Zero config | Docker Compose + config |
| Distributed testing | Built-in (multi-region) | Need k6-operator on K8s |
| Cost | Per-VUh pricing | Infrastructure cost only |
| Data retention | Cloud-managed | Self-managed |
| Sharing | URL sharing | Grafana access needed |
| Customization | Limited panels | Full Grafana flexibility |
| CI/CD integration | Built-in | Manual setup |

---

## Custom HTML Reports

### k6-reporter

```javascript
import { htmlReport } from 'https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: '  ', enableColors: true }),
    'reports/load-test-report.html': htmlReport(data, {
      title: 'API Load Test Report',
      showThresholds: true,
    }),
  };
}
```

### Custom Report Template

```javascript
export function handleSummary(data) {
  const p95 = data.metrics.http_req_duration?.values['p(95)'] || 0;
  const p99 = data.metrics.http_req_duration?.values['p(99)'] || 0;
  const errorRate = data.metrics.http_req_failed?.values.rate || 0;
  const rps = data.metrics.http_reqs?.values.rate || 0;
  const totalRequests = data.metrics.http_reqs?.values.count || 0;
  const maxVUs = data.metrics.vus_max?.values.max || 0;

  // Determine threshold results
  const thresholdResults = [];
  for (const [metricName, metric] of Object.entries(data.metrics)) {
    if (metric.thresholds) {
      for (const [condition, result] of Object.entries(metric.thresholds)) {
        thresholdResults.push({
          metric: metricName,
          condition,
          passed: result.ok,
        });
      }
    }
  }

  const allPassed = thresholdResults.every(t => t.passed);

  const html = `<!DOCTYPE html>
<html>
<head>
  <title>Load Test Report - ${new Date().toISOString()}</title>
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 900px; margin: 40px auto; padding: 0 20px; }
    .status { padding: 15px; border-radius: 8px; margin: 20px 0; color: white; font-size: 1.2em; }
    .pass { background: #22c55e; }
    .fail { background: #ef4444; }
    .metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; }
    .metric { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 15px; }
    .metric .value { font-size: 2em; font-weight: bold; color: #1e293b; }
    .metric .label { color: #64748b; font-size: 0.9em; }
    table { width: 100%; border-collapse: collapse; margin: 20px 0; }
    th, td { padding: 10px; text-align: left; border-bottom: 1px solid #e2e8f0; }
    .pass-badge { color: #22c55e; }
    .fail-badge { color: #ef4444; font-weight: bold; }
  </style>
</head>
<body>
  <h1>Load Test Report</h1>
  <p>Generated: ${new Date().toISOString()}</p>

  <div class="status ${allPassed ? 'pass' : 'fail'}">
    ${allPassed ? '✅ All thresholds passed' : '❌ Some thresholds failed'}
  </div>

  <h2>Key Metrics</h2>
  <div class="metrics">
    <div class="metric">
      <div class="value">${rps.toFixed(0)}</div>
      <div class="label">Requests/sec</div>
    </div>
    <div class="metric">
      <div class="value">${p95.toFixed(0)}ms</div>
      <div class="label">p95 Latency</div>
    </div>
    <div class="metric">
      <div class="value">${p99.toFixed(0)}ms</div>
      <div class="label">p99 Latency</div>
    </div>
    <div class="metric">
      <div class="value">${(errorRate * 100).toFixed(2)}%</div>
      <div class="label">Error Rate</div>
    </div>
    <div class="metric">
      <div class="value">${totalRequests.toLocaleString()}</div>
      <div class="label">Total Requests</div>
    </div>
    <div class="metric">
      <div class="value">${maxVUs}</div>
      <div class="label">Max VUs</div>
    </div>
  </div>

  <h2>Threshold Results</h2>
  <table>
    <tr><th>Metric</th><th>Condition</th><th>Result</th></tr>
    ${thresholdResults.map(t =>
      '<tr><td>' + t.metric + '</td><td>' + t.condition + '</td><td class="' +
      (t.passed ? 'pass-badge">✅ Pass' : 'fail-badge">❌ Fail') + '</td></tr>'
    ).join('')}
  </table>
</body>
</html>`;

  return {
    stdout: textSummary(data, { indent: '  ', enableColors: true }),
    'reports/report.html': html,
    'reports/summary.json': JSON.stringify(data, null, 2),
  };
}
```

### Artillery HTML Report

```bash
# Generate HTML report from Artillery results
artillery run --output results.json config.yml
artillery report results.json --output report.html
```

### Locust CSV Reports

```bash
# Locust CSV output for custom processing
locust -f locustfile.py --headless -u 100 -r 10 -t 5m \
  --csv=results --csv-full-history

# Generated files:
# results_stats.csv         — aggregate stats per endpoint
# results_stats_history.csv — time-series stats
# results_failures.csv      — error details
# results_exceptions.csv    — Python exceptions
```

---

## SLA/SLO Validation

### Defining SLOs in k6

```javascript
export const options = {
  thresholds: {
    // Availability SLO: 99.9% success rate
    http_req_failed: [{ threshold: 'rate<0.001', abortOnFail: true }],

    // Latency SLO: p95 < 200ms, p99 < 1000ms
    http_req_duration: ['p(95)<200', 'p(99)<1000'],

    // Per-endpoint SLOs
    'http_req_duration{name:login}': ['p(95)<300'],
    'http_req_duration{name:search}': ['p(95)<500'],
    'http_req_duration{name:checkout}': ['p(95)<1000'],

    // Throughput SLO: sustain at least 100 RPS
    http_reqs: ['rate>=100'],

    // Custom business SLO
    'checkout_success_rate': ['rate>0.99'],
  },
};
```

### SLO Validation Script

```javascript
import { Rate, Trend, Counter } from 'k6/metrics';

// Define SLOs as constants for documentation
const SLO = {
  AVAILABILITY: 0.999,        // 99.9%
  LATENCY_P95_MS: 200,
  LATENCY_P99_MS: 1000,
  ERROR_BUDGET_PERCENT: 0.1,  // 0.1% error budget
  MIN_THROUGHPUT_RPS: 100,
};

const sloViolations = new Counter('slo_violations');
const requestsInBudget = new Rate('requests_in_budget');

export const options = {
  thresholds: {
    http_req_failed: [`rate<${1 - SLO.AVAILABILITY}`],
    http_req_duration: [
      `p(95)<${SLO.LATENCY_P95_MS}`,
      `p(99)<${SLO.LATENCY_P99_MS}`,
    ],
    slo_violations: ['count<10'],  // fewer than 10 SLO violations total
    requests_in_budget: [`rate>${SLO.AVAILABILITY}`],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/api/endpoint`);

  const withinLatencySLO = res.timings.duration < SLO.LATENCY_P95_MS;
  const withinAvailabilitySLO = res.status < 500;

  requestsInBudget.add(withinLatencySLO && withinAvailabilitySLO);

  if (!withinLatencySLO || !withinAvailabilitySLO) {
    sloViolations.add(1);
  }
}
```

### CI/CD SLO Gate

```yaml
# GitHub Actions — fail PR if SLOs violated
- name: Run SLO validation test
  run: |
    k6 run --out json=results.json tests/slo-validation.js
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
      echo "❌ SLO thresholds violated — blocking merge"
      exit 1
    fi
    echo "✅ All SLOs met"
```

---

## Trend Analysis Across Runs

### Storing Run Metadata

```javascript
export function handleSummary(data) {
  const runData = {
    run_id: __ENV.CI_RUN_ID || `manual-${Date.now()}`,
    timestamp: new Date().toISOString(),
    git_sha: __ENV.GIT_SHA || 'unknown',
    branch: __ENV.GIT_BRANCH || 'unknown',
    environment: __ENV.ENVIRONMENT || 'unknown',
    metrics: {
      p50: data.metrics.http_req_duration?.values.med,
      p95: data.metrics.http_req_duration?.values['p(95)'],
      p99: data.metrics.http_req_duration?.values['p(99)'],
      rps: data.metrics.http_reqs?.values.rate,
      error_rate: data.metrics.http_req_failed?.values.rate,
      total_requests: data.metrics.http_reqs?.values.count,
    },
    thresholds_passed: Object.values(data.metrics)
      .filter(m => m.thresholds)
      .every(m => Object.values(m.thresholds).every(t => t.ok)),
  };

  return {
    'results/run-data.json': JSON.stringify(runData, null, 2),
  };
}
```

### Baseline Comparison Script

```bash
#!/bin/bash
# compare-results.sh — Compare current run against baseline

CURRENT="results/run-data.json"
BASELINE="baselines/baseline.json"

if [ ! -f "$BASELINE" ]; then
  echo "No baseline found. Saving current as baseline."
  cp "$CURRENT" "$BASELINE"
  exit 0
fi

# Extract metrics
curr_p95=$(jq '.metrics.p95' "$CURRENT")
base_p95=$(jq '.metrics.p95' "$BASELINE")
curr_err=$(jq '.metrics.error_rate' "$CURRENT")
base_err=$(jq '.metrics.error_rate' "$BASELINE")

# Calculate regression
p95_change=$(echo "scale=2; (($curr_p95 - $base_p95) / $base_p95) * 100" | bc)
err_change=$(echo "scale=6; $curr_err - $base_err" | bc)

echo "=== Performance Comparison ==="
echo "p95 Latency: ${base_p95}ms → ${curr_p95}ms (${p95_change}%)"
echo "Error Rate: ${base_err} → ${curr_err} (delta: ${err_change})"

# Fail if p95 regressed by more than 20%
threshold=20
if (( $(echo "$p95_change > $threshold" | bc -l) )); then
  echo "❌ REGRESSION: p95 latency increased by ${p95_change}% (threshold: ${threshold}%)"
  exit 1
fi

echo "✅ Performance within acceptable range"
```

### InfluxDB Trend Queries

```sql
-- p95 trend over last 30 days (one point per test run)
SELECT last("p95") FROM "http_req_duration_summary"
WHERE time > now() - 30d
GROUP BY time(1d), "test_name"

-- Compare today vs last week
SELECT percentile("value", 95) FROM "http_req_duration"
WHERE time > now() - 1d AND "test_name" = 'api-load'
;
SELECT percentile("value", 95) FROM "http_req_duration"
WHERE time > now() - 8d AND time < now() - 7d AND "test_name" = 'api-load'
```

---

## Executive Summary Generation

### Automated Summary Template

```javascript
export function handleSummary(data) {
  const m = data.metrics;
  const p95 = m.http_req_duration?.values['p(95)'] || 0;
  const p99 = m.http_req_duration?.values['p(99)'] || 0;
  const rps = m.http_reqs?.values.rate || 0;
  const errors = m.http_req_failed?.values.rate || 0;
  const total = m.http_reqs?.values.count || 0;
  const maxVUs = m.vus_max?.values.max || 0;
  const duration = m.iteration_duration?.values.med || 0;

  // Threshold status
  let passed = 0, failed = 0;
  const failedThresholds = [];
  for (const [name, metric] of Object.entries(m)) {
    if (metric.thresholds) {
      for (const [cond, result] of Object.entries(metric.thresholds)) {
        if (result.ok) passed++;
        else { failed++; failedThresholds.push(`${name}: ${cond}`); }
      }
    }
  }

  const status = failed === 0 ? 'PASSED' : 'FAILED';
  const emoji = failed === 0 ? '✅' : '❌';

  const summary = `
${emoji} LOAD TEST SUMMARY — ${status}
${'='.repeat(50)}
Date: ${new Date().toISOString()}
Environment: ${__ENV.ENVIRONMENT || 'unknown'}
Test: ${__ENV.TEST_NAME || 'unnamed'}

PERFORMANCE
  Throughput:     ${rps.toFixed(0)} req/sec
  Total Requests: ${total.toLocaleString()}
  Max VUs:        ${maxVUs}
  p50 Latency:    ${(m.http_req_duration?.values.med || 0).toFixed(0)}ms
  p95 Latency:    ${p95.toFixed(0)}ms
  p99 Latency:    ${p99.toFixed(0)}ms
  Error Rate:     ${(errors * 100).toFixed(3)}%

THRESHOLDS
  Passed: ${passed}/${passed + failed}
  Failed: ${failed}/${passed + failed}
${failedThresholds.length > 0 ? '  Failed checks:\n' + failedThresholds.map(t => '    ❌ ' + t).join('\n') : ''}

RECOMMENDATION
${failed > 0 ? '  ⚠️  Performance does not meet SLOs. Review failed thresholds above.' : '  ✅ System meets all performance targets at tested load.'}
${errors > 0.01 ? '  ⚠️  Error rate above 1% — investigate error causes.' : ''}
${p95 > 500 ? '  ⚠️  p95 latency above 500ms — consider optimization.' : ''}
${'='.repeat(50)}
`;

  return {
    stdout: summary,
    'reports/executive-summary.txt': summary,
    'reports/summary.json': JSON.stringify(data, null, 2),
  };
}
```

---

## Performance Budgets

### Defining Budgets

Performance budgets set maximum acceptable values for key metrics, enforced in CI/CD.

```javascript
// performance-budget.js
export const BUDGET = {
  api: {
    latency_p95_ms: 200,
    latency_p99_ms: 500,
    error_rate: 0.001,     // 0.1%
    min_rps: 500,
  },
  web: {
    lcp_ms: 2500,          // Largest Contentful Paint
    fcp_ms: 1800,          // First Contentful Paint
    cls: 0.1,              // Cumulative Layout Shift
    ttfb_ms: 800,          // Time to First Byte
  },
  database: {
    query_p95_ms: 50,
    connection_pool_usage: 0.8,  // 80% max
  },
};
```

### Budget Enforcement in k6

```javascript
import { BUDGET } from './performance-budget.js';

export const options = {
  thresholds: {
    http_req_duration: [
      `p(95)<${BUDGET.api.latency_p95_ms}`,
      `p(99)<${BUDGET.api.latency_p99_ms}`,
    ],
    http_req_failed: [`rate<${BUDGET.api.error_rate}`],
    http_reqs: [`rate>=${BUDGET.api.min_rps}`],
  },
};
```

### Budget Tracking Over Time

```bash
#!/bin/bash
# Track budget compliance across releases
# Append each run's budget status to a tracking file

RESULTS="results/summary.json"
TRACKING="baselines/budget-history.csv"

if [ ! -f "$TRACKING" ]; then
  echo "date,git_sha,p95_ms,p99_ms,error_rate,rps,budget_met" > "$TRACKING"
fi

p95=$(jq '.metrics.p95' "$RESULTS")
p99=$(jq '.metrics.p99' "$RESULTS")
err=$(jq '.metrics.error_rate' "$RESULTS")
rps=$(jq '.metrics.rps' "$RESULTS")
met=$(jq '.thresholds_passed' "$RESULTS")

echo "$(date -Iseconds),${GIT_SHA:-unknown},${p95},${p99},${err},${rps},${met}" >> "$TRACKING"
```

---

## Alerting on Regressions

### Grafana Alerts

```yaml
# Grafana alert rule (provisioned via YAML)
apiVersion: 1
groups:
  - name: load-test-alerts
    folder: Load Testing
    interval: 1m
    rules:
      - uid: perf-regression-p95
        title: "Performance Regression - p95 Latency"
        condition: B
        data:
          - refId: A
            datasourceUid: influxdb
            model:
              query: >
                SELECT percentile("value", 95) FROM "http_req_duration"
                WHERE time > now() - 1h
                GROUP BY time(5m)
          - refId: B
            datasourceUid: __expr__
            model:
              type: threshold
              conditions:
                - evaluator:
                    type: gt
                    params: [500]  # alert if p95 > 500ms
        for: 5m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Load test p95 latency exceeded 500ms"
```

### GitHub Actions PR Comment

```yaml
# Post load test results as PR comment
- name: Comment PR with results
  if: github.event_name == 'pull_request'
  uses: actions/github-script@v7
  with:
    script: |
      const fs = require('fs');
      const summary = fs.readFileSync('reports/executive-summary.txt', 'utf8');

      const body = `## 📊 Load Test Results\n\n\`\`\`\n${summary}\n\`\`\`\n\n` +
        `<details><summary>Full results</summary>\n\n` +
        `View detailed results in [Grafana](${process.env.GRAFANA_URL})\n\n</details>`;

      await github.rest.issues.createComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.issue.number,
        body,
      });
```

### Slack/Webhook Alerts

```javascript
// In k6 handleSummary
export function handleSummary(data) {
  const p95 = data.metrics.http_req_duration?.values['p(95)'] || 0;
  const errors = data.metrics.http_req_failed?.values.rate || 0;

  // Send alert if thresholds failed
  let anyFailed = false;
  for (const m of Object.values(data.metrics)) {
    if (m.thresholds) {
      for (const t of Object.values(m.thresholds)) {
        if (!t.ok) anyFailed = true;
      }
    }
  }

  if (anyFailed && __ENV.SLACK_WEBHOOK) {
    http.post(__ENV.SLACK_WEBHOOK, JSON.stringify({
      blocks: [
        {
          type: 'header',
          text: { type: 'plain_text', text: '🔴 Load Test Failed' },
        },
        {
          type: 'section',
          fields: [
            { type: 'mrkdwn', text: `*p95 Latency:*\n${p95.toFixed(0)}ms` },
            { type: 'mrkdwn', text: `*Error Rate:*\n${(errors * 100).toFixed(2)}%` },
            { type: 'mrkdwn', text: `*Environment:*\n${__ENV.ENVIRONMENT}` },
            { type: 'mrkdwn', text: `*Build:*\n${__ENV.GIT_SHA?.slice(0, 8)}` },
          ],
        },
        {
          type: 'actions',
          elements: [{
            type: 'button',
            text: { type: 'plain_text', text: 'View in Grafana' },
            url: __ENV.GRAFANA_URL,
          }],
        },
      ],
    }), { headers: { 'Content-Type': 'application/json' } });
  }

  return { stdout: textSummary(data, { indent: '  ', enableColors: true }) };
}
```

### Regression Detection Logic

```bash
#!/bin/bash
# detect-regression.sh — Statistical regression detection

CURRENT_FILE="$1"
BASELINE_DIR="baselines/history"

# Get last 5 runs for comparison
recent_p95s=$(ls -t "$BASELINE_DIR"/*.json | head -5 | xargs -I{} jq '.metrics.p95' {})
current_p95=$(jq '.metrics.p95' "$CURRENT_FILE")

# Calculate mean and stddev of recent runs
stats=$(echo "$recent_p95s" | awk '{
  sum += $1; sumsq += $1*$1; count++
} END {
  mean = sum/count;
  stddev = sqrt(sumsq/count - mean*mean);
  printf "%.2f %.2f", mean, stddev
}')

mean=$(echo "$stats" | cut -d' ' -f1)
stddev=$(echo "$stats" | cut -d' ' -f2)

# Alert if current value is >2 standard deviations above mean
threshold=$(echo "$mean + 2 * $stddev" | bc)

echo "Recent p95 mean: ${mean}ms (stddev: ${stddev}ms)"
echo "Current p95: ${current_p95}ms"
echo "Threshold (mean + 2σ): ${threshold}ms"

if (( $(echo "$current_p95 > $threshold" | bc -l) )); then
  echo "❌ REGRESSION DETECTED: p95 is ${current_p95}ms, threshold is ${threshold}ms"
  exit 1
fi

echo "✅ No regression detected"
```
