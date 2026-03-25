---
name: k6-load-testing
description: >
  Generate and edit Grafana k6 load testing scripts. Covers HTTP, WebSocket, gRPC, and browser protocol testing.
  Handles test lifecycle (init/setup/default/teardown), all six executors (shared-iterations, per-vu-iterations,
  constant-vus, ramping-vus, constant-arrival-rate, ramping-arrival-rate), checks, thresholds, custom metrics,
  scenarios, data parameterization, groups, tags, output backends, CI/CD integration, and xk6 extensions.
  USE WHEN: writing k6 scripts, load/performance/stress/soak/spike/breakpoint testing, k6 scenarios, k6 thresholds,
  k6 checks, HTTP load testing, gRPC testing with k6, browser testing with k6, WebSocket load testing, k6 cloud
  execution, k6 custom metrics, k6 data parameterization.
  DO NOT USE WHEN: configuring JMeter XML, writing Locust Python scripts, editing Artillery YAML, writing Gatling
  Scala simulations, Playwright e2e functional testing unrelated to k6, unit testing (Jest/Mocha/pytest).
---
# k6 Load Testing Skill
## Installation
```bash
brew install k6                     # macOS
sudo apt-get install k6             # Debian/Ubuntu (after adding k6 repo)
choco install k6                    # Windows
docker run --rm -i grafana/k6 run - <script.js  # Docker
```
Run: `k6 run script.js`. Flags: `--vus 10 --duration 30s`, `--out json=results.json`.
## Test Lifecycle (init → setup → default → teardown)
```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';
// INIT: runs once per VU. Import modules, define options. No HTTP here.
export const options = {
  vus: 10, duration: '30s',
  thresholds: { http_req_duration: ['p(95)<500'], http_req_failed: ['rate<0.01'] },
};
// SETUP: runs once. Return data shared across VUs.
export function setup() {
  const res = http.post('https://api.example.com/auth',
    JSON.stringify({ username: 'test', password: 'pass' }),
    { headers: { 'Content-Type': 'application/json' } });
  return { token: res.json('token') };
}
// DEFAULT: runs repeatedly per VU. Main test logic.
export default function (data) {
  const res = http.get('https://api.example.com/items', {
    headers: { Authorization: `Bearer ${data.token}` },
  });
  check(res, {
    'status 200': (r) => r.status === 200,
    'has items': (r) => r.json('items').length > 0,
  });
  sleep(1);
}
// TEARDOWN: runs once after all VUs finish.
export function teardown(data) {
  http.post('https://api.example.com/logout', null, {
    headers: { Authorization: `Bearer ${data.token}` },
  });
}
```
## HTTP Requests
```javascript
import http from 'k6/http';
// GET with headers
http.get('https://api.example.com/users?page=1', {
  headers: { Accept: 'application/json', Authorization: 'Bearer tok' },
  tags: { name: 'GetUsers' },
});
// POST JSON
http.post('https://api.example.com/users',
  JSON.stringify({ name: 'Alice' }),
  { headers: { 'Content-Type': 'application/json' } });
// PUT / DELETE
http.put('https://api.example.com/users/1', JSON.stringify({ name: 'Bob' }),
  { headers: { 'Content-Type': 'application/json' } });
http.del('https://api.example.com/users/1');
// Batch (parallel)
const responses = http.batch([
  ['GET', 'https://api.example.com/users'],
  ['GET', 'https://api.example.com/products'],
]);
// File upload
import { FormData } from 'https://jslib.k6.io/formdata/0.0.2/index.js';
const fd = new FormData();
fd.append('file', http.file(open('./data.csv', 'b'), 'data.csv'));
http.post('https://api.example.com/upload', fd.body(),
  { headers: { 'Content-Type': fd.contentType } });
```
## Checks and Thresholds
Checks = assertions (non-failing, reported as rate). Thresholds = pass/fail gates (exit code 99 on breach).
```javascript
export const options = {
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.95'],
    'http_req_duration{name:Login}': ['p(95)<300'],  // tagged threshold
  },
};
export default function () {
  const res = http.get('https://api.example.com/health');
  check(res, {
    'status 200': (r) => r.status === 200,
    'body not empty': (r) => r.body.length > 0,
    'latency < 300ms': (r) => r.timings.duration < 300,
  });
}
```
Threshold aggregators: `avg`, `min`, `max`, `med`, `p(N)`, `count`, `rate`.
## Scenarios and Executors
```javascript
export const options = { scenarios: {
  // constant-vus: fixed VU count
  steady: { executor: 'constant-vus', vus: 50, duration: '5m' },
  // ramping-vus: ramp VUs through stages (closed model)
  ramp: {
    executor: 'ramping-vus', startVUs: 0,
    stages: [{ duration: '2m', target: 100 }, { duration: '5m', target: 100 }, { duration: '2m', target: 0 }],
  },
  // constant-arrival-rate: fixed RPS (open model)
  fixed_rps: {
    executor: 'constant-arrival-rate',
    rate: 200, timeUnit: '1s', duration: '5m', preAllocatedVUs: 50, maxVUs: 200,
  },
  // ramping-arrival-rate: ramp RPS through stages
  ramp_rps: {
    executor: 'ramping-arrival-rate', startRate: 10, timeUnit: '1s',
    preAllocatedVUs: 20, maxVUs: 300,
    stages: [{ target: 100, duration: '2m' }, { target: 200, duration: '3m' }, { target: 50, duration: '1m' }],
  },
  // shared-iterations: fixed total iterations split across VUs
  batch: { executor: 'shared-iterations', vus: 10, iterations: 500, maxDuration: '10m' },
  // per-vu-iterations: each VU runs N iterations
  per_user: { executor: 'per-vu-iterations', vus: 20, iterations: 50, maxDuration: '10m' },
}};
```
**Selection guide:** `constant-vus`/`ramping-vus` = closed model (control concurrency). `constant-arrival-rate`/`ramping-arrival-rate` = open model (control throughput/RPS). `shared-iterations`/`per-vu-iterations` = bounded work.
## Test Type Patterns
```javascript
// LOAD: normal traffic
export const options = { stages: [
  { duration: '5m', target: 100 }, { duration: '10m', target: 100 }, { duration: '5m', target: 0 },
]};
// STRESS: beyond capacity
export const options = { stages: [
  { duration: '2m', target: 100 }, { duration: '5m', target: 200 },
  { duration: '2m', target: 300 }, { duration: '5m', target: 300 }, { duration: '5m', target: 0 },
]};
// SPIKE: sudden burst
export const options = { stages: [
  { duration: '10s', target: 100 }, { duration: '1m', target: 1000 },
  { duration: '3m', target: 1000 }, { duration: '10s', target: 100 },
]};
// SOAK: extended duration for leak detection
export const options = { stages: [
  { duration: '5m', target: 100 }, { duration: '4h', target: 100 }, { duration: '5m', target: 0 },
]};
// BREAKPOINT: find limits via ramping-arrival-rate
export const options = { scenarios: { breakpoint: {
  executor: 'ramping-arrival-rate', startRate: 1, timeUnit: '1s',
  preAllocatedVUs: 50, maxVUs: 2000,
  stages: [{ target: 50, duration: '2m' }, { target: 200, duration: '2m' },
    { target: 500, duration: '2m' }, { target: 1000, duration: '2m' }],
}}};
```
## Groups, Tags, and Environment Variables
```javascript
import { group } from 'k6';
import http from 'k6/http';
const BASE_URL = __ENV.BASE_URL || 'https://api.example.com';
export default function () {
  group('Auth', () => {
    http.post(`${BASE_URL}/login`, JSON.stringify({ user: 'test', pass: 'test' }),
      { headers: { 'Content-Type': 'application/json' }, tags: { name: 'Login', type: 'auth' } });
  });
  group('Browse', () => {
    http.get(`${BASE_URL}/products`, { tags: { name: 'ListProducts' } });
  });
}
```
Run: `k6 run -e BASE_URL=https://staging.example.com -e API_KEY=secret script.js`
Tag-filtered thresholds: `'http_req_duration{name:Login}': ['p(95)<300']`
## Data Parameterization
```javascript
import { SharedArray } from 'k6/data';
import papaparse from 'https://jslib.k6.io/papaparse/5.1.1/index.js';
// JSON (memory-efficient via SharedArray)
const users = new SharedArray('users', () => JSON.parse(open('./testdata/users.json')));
// CSV via papaparse
const csvData = new SharedArray('csv', () =>
  papaparse.parse(open('./testdata/data.csv'), { header: true }).data);
export default function () {
  const user = users[Math.floor(Math.random() * users.length)]; // random
  const row = csvData[__VU % csvData.length];                   // sequential per VU
  http.post('https://api.example.com/login',
    JSON.stringify({ username: user.username, password: user.password }));
}
```
`open()` reads files at init time only. Always wrap in `SharedArray` for multi-VU memory efficiency.
## Custom Metrics
```javascript
import { Counter, Gauge, Rate, Trend } from 'k6/metrics';
const loginErrors = new Counter('login_errors');   // cumulative count
const activeUsers = new Gauge('active_users');      // last/min/max value
const successRate = new Rate('success_rate');        // percentage true
const loginTime = new Trend('login_time', true);    // stats (avg/p95/p99)
export const options = {
  thresholds: {
    login_errors: ['count<10'], success_rate: ['rate>0.95'], login_time: ['p(95)<400'],
  },
};
export default function () {
  const start = Date.now();
  const res = http.post('https://api.example.com/login',
    JSON.stringify({ user: 'test', pass: 'test' }));
  loginTime.add(Date.now() - start);
  successRate.add(res.status === 200);
  if (res.status !== 200) loginErrors.add(1);
  activeUsers.add(__VU);
}
```
## Output Backends
```bash
k6 run --out json=results.json script.js           # JSON
k6 run --out csv=results.csv script.js              # CSV
k6 run --out influxdb=http://localhost:8086/k6 script.js  # InfluxDB
k6 run --out experimental-prometheus-rw script.js   # Prometheus Remote Write
k6 cloud run script.js                              # Grafana Cloud k6
k6 run --out cloud script.js                        # push local results to cloud
# Multiple outputs
k6 run --out json=out.json --out influxdb=http://localhost:8086/k6 script.js
```
Set `K6_PROMETHEUS_RW_SERVER_URL` for Prometheus. Set `K6_CLOUD_TOKEN` via `k6 cloud login`.
## Browser Module
Chromium-based frontend testing via Chrome DevTools Protocol. API mirrors Playwright.
```javascript
import { browser } from 'k6/browser';
import { check } from 'k6';
export const options = {
  scenarios: { ui: {
    executor: 'constant-vus', vus: 1, duration: '30s',
    options: { browser: { type: 'chromium' } },
  }},
  thresholds: {
    browser_web_vital_lcp: ['p(95)<2500'],
    browser_web_vital_cls: ['p(95)<0.1'],
  },
};
export default async function () {
  const page = await browser.newPage();
  try {
    await page.goto('https://example.com');
    await page.locator('#username').fill('testuser');
    await page.locator('#password').fill('testpass');
    await page.locator('button[type="submit"]').click();
    await page.waitForNavigation();
    check(page, { 'header visible': (p) => p.locator('h1').isVisible() });
  } finally { await page.close(); }
}
```
Run: `K6_BROWSER_HEADLESS=true k6 run browser-test.js`
## WebSocket Testing
```javascript
import ws from 'k6/ws';
import { check } from 'k6';
export default function () {
  const res = ws.connect('wss://echo.websocket.org', {}, function (socket) {
    socket.on('open', () => { socket.send('hello k6'); });
    socket.on('message', (msg) => {
      check(msg, { 'msg received': (m) => m.length > 0 });
    });
    socket.on('error', (e) => console.error('WS error:', e.error()));
    socket.setTimeout(() => socket.close(), 5000);
  });
  check(res, { 'ws status 101': (r) => r && r.status === 101 });
}
```
## gRPC Testing
```javascript
import grpc from 'k6/net/grpc';
import { check, sleep } from 'k6';
const client = new grpc.Client();
client.load(['./proto'], 'hello.proto');  // init time only
export default function () {
  client.connect('localhost:50051', { plaintext: true });
  // TLS: client.connect('grpc.example.com:443', {})
  // Reflection: client.connect('addr', { reflect: true })
  const resp = client.invoke('hello.HelloService/SayHello', { greeting: 'k6' });
  check(resp, {
    'gRPC OK': (r) => r && r.status === grpc.StatusOK,
    'has reply': (r) => r && r.message.reply.includes('k6'),
  });
  // With metadata: client.invoke('svc/Method', data, { metadata: { 'x-api-key': 'secret' } })
  client.close();
  sleep(1);
}
```
Status codes: `grpc.StatusOK`, `grpc.StatusNotFound`, `grpc.StatusInternal`, etc.
## CI/CD Integration
```yaml
# GitHub Actions
name: Load Test
on: [push]
jobs:
  k6:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: grafana/setup-k6-action@v1
      - uses: grafana/run-k6-action@v1
        with:
          path: tests/load/*.js
```
```yaml
# GitLab CI
load_test:
  image: grafana/k6:latest
  script: k6 run --out json=results.json tests/load/test.js
  artifacts:
    paths: [results.json]
    when: always
```
```bash
# Docker
docker run --rm -v $(pwd):/scripts grafana/k6 run /scripts/test.js
```
Thresholds cause non-zero exit (code 99) — pipeline fails automatically on SLA breach.
## k6 Extensions (xk6)
```bash
go install go.k6.io/xk6/cmd/xk6@latest
xk6 build --with github.com/grafana/xk6-dashboard@latest    # real-time HTML dashboard
xk6 build --with github.com/grafana/xk6-sql@latest          # database testing
xk6 build --with github.com/grafana/xk6-output-prometheus-remote@latest
# Multiple: xk6 build --with github.com/grafana/xk6-dashboard --with github.com/grafana/xk6-sql
```
Popular: `xk6-dashboard`, `xk6-sql`, `xk6-kafka`, `xk6-redis`, `xk6-output-prometheus-remote`. Registry: https://registry.k6.io/
## Built-in Metrics Reference
| Metric | Type | Description |
|---|---|---|
| `http_req_duration` | Trend | Total request time (ms) |
| `http_req_blocked` | Trend | Time blocked before request |
| `http_req_connecting` | Trend | TCP connection time |
| `http_req_tls_handshaking` | Trend | TLS handshake time |
| `http_req_waiting` | Trend | TTFB (time to first byte) |
| `http_req_failed` | Rate | Failed request percentage |
| `http_reqs` | Counter | Total HTTP requests |
| `iterations` | Counter | Completed iterations |
| `iteration_duration` | Trend | Full iteration time |
| `vus` / `vus_max` | Gauge | Current / max VUs |
| `checks` | Rate | Check pass rate |
| `data_received` / `data_sent` | Counter | Bytes received / sent |
## Complete Example
```javascript
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';
const errorRate = new Rate('errors');
const apiLatency = new Trend('api_latency', true);
const users = new SharedArray('users', () => JSON.parse(open('./users.json')));
export const options = {
  scenarios: {
    smoke: { executor: 'constant-vus', vus: 1, duration: '1m', tags: { test_type: 'smoke' } },
    load: {
      executor: 'ramping-vus', startVUs: 0, startTime: '1m',
      stages: [{ duration: '3m', target: 50 }, { duration: '5m', target: 50 }, { duration: '2m', target: 0 }],
      tags: { test_type: 'load' },
    },
  },
  thresholds: { http_req_duration: ['p(95)<500'], errors: ['rate<0.05'], api_latency: ['p(99)<800'] },
};
export default function () {
  const user = users[__VU % users.length];
  const base = __ENV.BASE_URL || 'https://api.example.com';
  group('Auth', () => {
    const r = http.post(`${base}/login`,
      JSON.stringify({ username: user.username, password: user.password }),
      { headers: { 'Content-Type': 'application/json' }, tags: { name: 'Login' } });
    check(r, { 'login 200': (r) => r.status === 200 }) || errorRate.add(1);
    apiLatency.add(r.timings.duration);
  });
  group('Browse', () => {
    const r = http.get(`${base}/products`, { tags: { name: 'Products' } });
    check(r, { 'products 200': (r) => r.status === 200 }) || errorRate.add(1);
    apiLatency.add(r.timings.duration);
  });
  sleep(Math.random() * 3 + 1);
}
// Run: k6 run -e BASE_URL=https://staging.api.com --out json=results.json script.js
```

## Reference Documentation

Detailed reference docs live in `references/`:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Complex scenario composition (staggered starts, per-scenario env/tags), custom executor deep-dive (open vs closed model, arrival-rate sizing, externally-controlled), modular test structure (project layout, reusable flows, environment configs), data correlation (token extraction chains, CSRF, response headers), dynamic data generation (UUID, weighted random), custom metrics with business KPIs, handleSummary for custom reports (HTML, JUnit XML), test lifecycle hooks (setup retry, abort conditions), browser module deep-dive (hybrid protocol+browser, screenshots, Web Vitals), gRPC patterns (TLS, server reflection, bidirectional streaming), WebSocket patterns (full-duplex chat simulation), distributed testing (k6-operator on Kubernetes, multi-region)

- **[troubleshooting.md](references/troubleshooting.md)** — Script compilation errors (CommonJS vs ES6, missing exports, open() context), import issues (relative paths, remote modules, Docker mounts), certificate/TLS errors (skip verify, custom CA, TLS version), performance bottlenecks (load generator saturation, connection pool, dropped iterations), memory issues (SharedArray, body discard, logging), result interpretation pitfalls (coordinated omission, misleading averages, warm-up bias), flaky thresholds (stabilization strategies, sample size), CI timeout solutions (fast-fail, resource constraints), output backend configuration (InfluxDB v1/v2, Prometheus Remote Write), debugging with --http-debug, common error messages quick-reference table

- **[api-reference.md](references/api-reference.md)** — Complete k6 JavaScript API: http module (all methods, params, response object, cookies, file upload, expectedStatuses), core functions (check, group, sleep, fail, randomSeed), custom metrics (Counter, Gauge, Rate, Trend with aggregators), full options object (HTTP, TLS, DNS, tags, cloud config), scenarios and all 7 executors, lifecycle functions (init/setup/default/teardown/handleSummary), SharedArray, open(), encoding (base64), crypto (hash, HMAC, randomBytes), execution context (vu, scenario, instance, test.abort), browser module API (page, locator, keyboard, mouse, Web Vitals metrics), HTML parsing, WebSocket socket API, gRPC client API with all status codes, built-in metrics tables, environment globals and CLI flags

## Scripts

Helper scripts in `scripts/`:

- **[setup-k6.sh](scripts/setup-k6.sh)** — Auto-detects OS and installs k6 (macOS/Linux/Windows). Scaffolds a complete project structure with `scenarios/`, `flows/`, `helpers/`, `config/`, `testdata/` directories, environment config module, shared thresholds, reusable request/check helpers, and sample test data. Run: `./scripts/setup-k6.sh [project-dir]`

- **[run-suite.sh](scripts/run-suite.sh)** — Runs k6 test suites with environment selection (`-e staging`), optional JSON/InfluxDB/Cloud output, threshold validation, timestamped result directories, and a pass/fail summary report. Supports `--dry-run` for validation. Run: `./scripts/run-suite.sh -s scenarios/load.js -e staging --json`

## Templates

Production-ready templates in `assets/`:

- **[load-test.template.js](assets/load-test.template.js)** — Full k6 script with multi-scenario (smoke → load → spike), custom metrics, SharedArray data parameterization, data correlation, CI-aware scaling, groups, tags, and custom handleSummary

- **[ci-workflow.template.yml](assets/ci-workflow.template.yml)** — GitHub Actions workflow: smoke on PRs, load on main, optional cloud stress via workflow_dispatch, artifact upload, threshold gates (exit 99 = fail), job summary

- **[docker-compose.template.yml](assets/docker-compose.template.yml)** — k6 + InfluxDB 1.8 + Grafana stack with healthchecks, auto-provisioned datasource, anonymous Grafana access. Import dashboard ID 2587 or 18030
