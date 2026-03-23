---
name: load-testing-k6
description: >
  Use when user writes load tests with k6, asks about k6 scripting, VUs, scenarios, thresholds,
  checks, HTTP requests, k6 browser module, or performance testing CI integration.
  Do NOT use for JMeter, Locust, Artillery, Gatling, or E2E testing (use playwright-e2e-testing skill).
---

# k6 Load Testing

## Script Structure

Every k6 script has four lifecycle stages: **init**, **setup**, **VU code** (default function), and **teardown**.

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 10,
  duration: '30s',
};

export function setup() {
  // Run once before test. Return data passed to default and teardown.
  return { token: 'abc123' };
}

export default function (data) {
  // Runs repeatedly per VU for the test duration.
  const res = http.get('https://test.k6.io/', {
    headers: { Authorization: `Bearer ${data.token}` },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);
}

export function teardown(data) {
  // Run once after test completes.
}
```

**Options reference:**

| Option | Purpose | Example |
|---|---|---|
| `vus` | Concurrent virtual users | `10` |
| `duration` | Total test duration | `'5m'` |
| `iterations` | Total iterations across all VUs | `100` |
| `stages` | Ramp VUs over time | See ramping-vus |
| `thresholds` | Pass/fail criteria | See Thresholds |
| `scenarios` | Advanced executor configs | See Scenarios |

## HTTP Requests

### GET with query params and headers

```javascript
import http from 'k6/http';

const res = http.get('https://api.example.com/users?page=1', {
  headers: { 'Accept': 'application/json', 'X-API-Key': __ENV.API_KEY },
  tags: { name: 'GetUsers' },
});
```

### POST with JSON body

```javascript
const payload = JSON.stringify({ username: 'testuser', password: 'pass123' });
const res = http.post('https://api.example.com/login', payload, {
  headers: { 'Content-Type': 'application/json' },
});
const token = res.json('access_token');
```

### File upload

```javascript
const f = open('/path/to/file.bin', 'b');
const res = http.post('https://api.example.com/upload', { file: http.file(f, 'file.bin') });
```

### Response parsing

```javascript
const body = res.json();              // Parse JSON
const value = res.json('data.items'); // JSONPath
const html = res.html();             // Parse HTML
const el = html.find('h1').text();   // CSS selector
```

## Checks and Thresholds

### Checks (assertions that don't halt execution)

```javascript
check(res, {
  'status is 200': (r) => r.status === 200,
  'body contains expected': (r) => r.body.includes('success'),
  'response time < 500ms': (r) => r.timings.duration < 500,
});
```

### Thresholds (SLO enforcement, fail the test run)

```javascript
export const options = {
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],   // Latency percentiles
    http_req_failed: ['rate<0.01'],                    // Error rate under 1%
    checks: ['rate>0.99'],                             // 99% of checks must pass
    'http_req_duration{name:GetUsers}': ['p(95)<300'], // Per-endpoint threshold
  },
};
```

### Abort on threshold breach

```javascript
export const options = {
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.1', abortOnFail: true, delayAbortEval: '10s' }],
  },
};
```

## Scenarios

Scenarios define independent workloads with different executors.

### constant-vus```javascript
export const options = {
  scenarios: {
    steady: { executor: 'constant-vus', vus: 50, duration: '5m' },
  },
};
```

### ramping-vus

```javascript
export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 50 },
        { duration: '5m', target: 50 },
        { duration: '2m', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
};
```

### constant-arrival-rate (fixed RPS regardless of response time)

```javascript
export const options = {
  scenarios: {
    fixed_rps: {
      executor: 'constant-arrival-rate',
      rate: 100, timeUnit: '1s', duration: '5m',
      preAllocatedVUs: 50, maxVUs: 200,
    },
  },
};
```

### shared-iterations (fixed total iterations split across VUs)

```javascript
export const options = {
  scenarios: {
    shared: { executor: 'shared-iterations', vus: 10, iterations: 500, maxDuration: '2m' },
  },
};
```

### externally-controlled (scale VUs via k6 REST API at runtime)

```javascript
export const options = {
  scenarios: {
    external: { executor: 'externally-controlled', vus: 10, maxVUs: 100, duration: '10m' },
  },
};
// Scale during run: k6 scale --vus 50
```

### Multiple scenarios with separate functions

```javascript
export const options = {
  scenarios: {
    browse: { executor: 'constant-vus', vus: 20, duration: '5m', exec: 'browseFlow' },
    purchase: { executor: 'ramping-vus', startVUs: 0, stages: [{ duration: '5m', target: 10 }], exec: 'purchaseFlow' },
  },
};

export function browseFlow() { /* browsing logic */ }
export function purchaseFlow() { /* checkout logic */ }
```

## Test Types

### Smoke (validate script works, minimal load)

```javascript
export const options = { vus: 1, duration: '1m' };
```

### Load (typical production traffic)

```javascript
export const options = {
  stages: [
    { duration: '5m', target: 100 },
    { duration: '10m', target: 100 },
    { duration: '5m', target: 0 },
  ],
};
```

### Stress (find breaking point)

```javascript
export const options = {
  stages: [
    { duration: '2m', target: 100 }, { duration: '5m', target: 100 },
    { duration: '2m', target: 200 }, { duration: '5m', target: 200 },
    { duration: '2m', target: 300 }, { duration: '5m', target: 300 },
    { duration: '2m', target: 0 },
  ],
};
```

### Spike (sudden traffic burst)

```javascript
export const options = {
  stages: [
    { duration: '10s', target: 100 }, { duration: '1m', target: 100 },
    { duration: '10s', target: 1000 }, { duration: '3m', target: 1000 },
    { duration: '10s', target: 100 }, { duration: '3m', target: 0 },
  ],
};
```

### Soak (sustained load over hours)

```javascript
export const options = {
  stages: [
    { duration: '5m', target: 100 },
    { duration: '4h', target: 100 },
    { duration: '5m', target: 0 },
  ],
};
```

## Data Parameterization

### SharedArray (memory-efficient, read-only, shared across VUs)

```javascript
import { SharedArray } from 'k6/data';

const users = new SharedArray('users', function () {
  return JSON.parse(open('./data/users.json'));
});

export default function () {
  const user = users[__VU % users.length];
  http.post('https://api.example.com/login', JSON.stringify(user));
}
```

### CSV data via papaparse

```javascript
import { SharedArray } from 'k6/data';
import papaparse from 'https://jslib.k6.io/papaparse/5.1.1/index.js';

const csvData = new SharedArray('csv', function () {
  return papaparse.parse(open('./data/users.csv'), { header: true }).data;
});
```

### Environment variables

```bash
k6 run -e BASE_URL=https://staging.example.com -e API_KEY=secret script.js
```
```javascript
const baseUrl = __ENV.BASE_URL || 'https://api.example.com';
```

## Groups and Tags

```javascript
import { group } from 'k6';

export default function () {
  group('user login', function () {
    http.post('https://api.example.com/login', '{}');
  });
  group('fetch dashboard', function () {
    http.get('https://api.example.com/dashboard');
  });
}
```

Tag requests for metric filtering:

```javascript
const res = http.get('https://api.example.com/users', {
  tags: { name: 'GetUsers', type: 'api' },
});
```

Tag-scoped thresholds:

```javascript
export const options = {
  thresholds: {
    'http_req_duration{name:GetUsers}': ['p(95)<300'],
    'http_req_duration{type:api}': ['p(99)<1000'],
  },
};
```

## Custom Metrics

```javascript
import { Counter, Gauge, Rate, Trend } from 'k6/metrics';

const errorCount = new Counter('errors');       // Cumulative count
const activeUsers = new Gauge('active_users');   // Last/min/max value
const successRate = new Rate('success_rate');     // Ratio of true to total
const apiLatency = new Trend('api_latency', true); // Stats + percentiles (ms)

export default function () {
  const res = http.get('https://api.example.com/data');
  errorCount.add(res.status !== 200);
  activeUsers.add(__VU);
  successRate.add(res.status === 200);
  apiLatency.add(res.timings.duration);
}
```

Threshold on custom metrics:

```javascript
export const options = {
  thresholds: {
    errors: ['count<10'],
    success_rate: ['rate>0.95'],
    api_latency: ['p(95)<500'],
  },
};
```

## k6 Browser Module

Use real Chromium for frontend performance metrics (LCP, FCP, CLS, TTFB). Run with `K6_BROWSER_ENABLED=true`. Browser VUs use async/await.

```javascript
import { browser } from 'k6/browser';
import { check } from 'k6';

export const options = {
  scenarios: {
    ui: {
      executor: 'shared-iterations', vus: 1, iterations: 1,
      options: { browser: { type: 'chromium' } },
    },
  },
  thresholds: {
    browser_web_vital_lcp: ['p(95)<2500'],
    browser_web_vital_cls: ['p(95)<0.1'],
  },
};

export default async function () {
  const page = await browser.newPage();
  try {
    await page.goto('https://test.k6.io/');
    await page.locator('a[href="/contacts.php"]').click();
    await page.waitForNavigation();
    check(page, { 'header visible': (p) => p.locator('h3').isVisible() });
  } finally {
    await page.close();
  }
}
```

### Hybrid testing (protocol + browser)

Combine high-VU protocol load with low-VU browser testing for backend and frontend metrics.

```javascript
export const options = {
  scenarios: {
    protocol: { executor: 'constant-vus', vus: 50, duration: '5m', exec: 'protocolTest' },
    browser: { executor: 'shared-iterations', vus: 2, iterations: 5, exec: 'browserTest',
               options: { browser: { type: 'chromium' } } },
  },
};
```

## Protocol Support

### WebSocket
```javascript
import ws from 'k6/ws';

export default function () {
  const res = ws.connect('wss://echo.websocket.org', {}, function (socket) {
    socket.on('open', () => socket.send('hello'));
    socket.on('message', (msg) => { check(msg, { 'echo': (m) => m === 'hello' }); socket.close(); });
    socket.setTimeout(() => socket.close(), 5000);
  });
  check(res, { 'ws status 101': (r) => r && r.status === 101 });
}
```

### gRPC

```javascript
import grpc from 'k6/net/grpc';
const client = new grpc.Client();
client.load(['definitions'], 'hello.proto');

export default function () {
  client.connect('grpc.example.com:443', { plaintext: false });
  const res = client.invoke('hello.HelloService/SayHello', { name: 'k6' });
  check(res, { 'grpc status OK': (r) => r && r.status === grpc.StatusOK });
  client.close();
}
```

## CI/CD Integration

### GitHub Actions
```yaml
name: Performance Tests
on: [push, pull_request]

jobs:
  k6:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: grafana/setup-k6-action@v1
      - uses: grafana/run-k6-action@v1
        with:
          path: tests/performance/*.js
```

k6 exits non-zero when thresholds fail — the CI job fails automatically.

### Strategy

- **PR merges:** Run smoke tests (1 VU, 1 min).
- **Staging deploy:** Run load tests with production-like thresholds.
- **Nightly:** Run soak or stress tests.
- Store results in Grafana Cloud for trend tracking across builds.

## Results Output

```bash
k6 run script.js --out json=results.json           # JSON lines
k6 run script.js --out csv=results.csv              # CSV
k6 run script.js --out influxdb=http://localhost:8086/k6  # InfluxDB v1
k6 run script.js --out cloud                        # Stream to Grafana Cloud
k6 run script.js --out json=r.json --out influxdb=http://localhost:8086/k6  # Multiple
```

## Common Patterns

- **Correlation:** Extract tokens from login response, pass to subsequent requests.
- **Think time:** Add `sleep(Math.random() * 3 + 1)` between requests.
- **Batch requests:** Use `http.batch()` for parallel requests in a single VU iteration.
- **Request grouping:** Wrap related requests in `group()`.
- **Dynamic URLs:** Use `__ENV.BASE_URL` for environment-specific targets.

## Anti-Patterns

- **No thresholds:** Always define thresholds. Without them, tests never fail.
- **Ignoring sleep:** Omitting think time creates unrealistic closed-loop load.
- **SharedArray mutations:** SharedArray is read-only. Do not modify in VU code.
- **Global state between VUs:** VUs are isolated. Do not rely on shared mutable state.
- **Averages over percentiles:** Use `p(95)` or `p(99)`, not `avg`, for latency thresholds.
- **Hardcoded URLs:** Use environment variables for base URLs.
- **Too many browser VUs:** Use 1–5 for frontend metrics; use protocol VUs for load.

<!-- tested: pass -->
