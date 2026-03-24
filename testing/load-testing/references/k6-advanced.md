# k6 Advanced Patterns

## Table of Contents

- [Custom Metrics](#custom-metrics)
- [Custom Executors Deep Dive](#custom-executors-deep-dive)
- [Browser Testing with xk6-browser](#browser-testing-with-xk6-browser)
- [gRPC Load Testing](#grpc-load-testing)
- [WebSocket Testing](#websocket-testing)
- [Test Data Management](#test-data-management)
- [Custom Summary Handlers](#custom-summary-handlers)
- [k6 Extensions Ecosystem](#k6-extensions-ecosystem)
- [k6 Cloud Features](#k6-cloud-features)
- [Test Lifecycle Hooks](#test-lifecycle-hooks)
- [Scenario-Based Testing](#scenario-based-testing)
- [Environment-Specific Configs](#environment-specific-configs)
- [Tagging and Filtering](#tagging-and-filtering)
- [Advanced Checks and Groups](#advanced-checks-and-groups)
- [HTTP/2 and Connection Reuse](#http2-and-connection-reuse)

---

## Custom Metrics

k6 provides four custom metric types. Use them to track domain-specific performance.

### Metric Types

```javascript
import { Counter, Gauge, Rate, Trend } from 'k6/metrics';

// Counter — cumulative count
const totalOrders = new Counter('total_orders');

// Gauge — last observed value (min/max tracked automatically)
const activeConnections = new Gauge('active_connections');

// Rate — percentage of true values
const checkoutSuccess = new Rate('checkout_success_rate');

// Trend — distribution statistics (min, max, avg, med, p90, p95, p99)
const orderProcessingTime = new Trend('order_processing_time', true); // true = time values in ms
```

### Tagging Custom Metrics

```javascript
import { Trend } from 'k6/metrics';

const apiLatency = new Trend('api_latency');

export default function () {
  const res = http.get(`${BASE_URL}/api/users`);
  apiLatency.add(res.timings.duration, { endpoint: '/api/users', method: 'GET' });

  const res2 = http.post(`${BASE_URL}/api/orders`, payload);
  apiLatency.add(res2.timings.duration, { endpoint: '/api/orders', method: 'POST' });
}
```

### Thresholds on Custom Metrics

```javascript
export const options = {
  thresholds: {
    'order_processing_time': ['p(95)<2000', 'p(99)<5000'],
    'checkout_success_rate': ['rate>0.98'],
    'api_latency{endpoint:/api/users}': ['p(95)<300'],
    'api_latency{endpoint:/api/orders}': ['p(95)<1000'],
  },
};
```

### Composite Business Metrics

```javascript
import { Trend, Rate, Counter } from 'k6/metrics';

const e2eCheckout = new Trend('e2e_checkout_duration');
const checkoutErrors = new Rate('checkout_error_rate');
const revenue = new Counter('simulated_revenue');

export default function () {
  const start = Date.now();

  const cart = addToCart();
  const payment = processPayment();
  const confirmation = confirmOrder();

  const totalDuration = Date.now() - start;
  e2eCheckout.add(totalDuration);
  checkoutErrors.add(confirmation.status !== 200);

  if (confirmation.status === 200) {
    revenue.add(confirmation.json('order.total'));
  }
}
```

---

## Custom Executors Deep Dive

### constant-arrival-rate — Open-Loop Testing

Prevents coordinated omission by maintaining fixed request rate regardless of response times.

```javascript
export const options = {
  scenarios: {
    open_loop_test: {
      executor: 'constant-arrival-rate',
      rate: 500,             // 500 iterations per timeUnit
      timeUnit: '1s',        // = 500 RPS
      duration: '10m',
      preAllocatedVUs: 100,  // start with this many VUs
      maxVUs: 1000,          // scale up if needed (responses slow down)
    },
  },
};
```

**Key insight**: If `maxVUs` is reached and iterations are still queued, k6 logs `dropped_iterations`. This means your system cannot sustain the target rate — that's the finding.

### ramping-arrival-rate — Breakpoint Discovery

```javascript
export const options = {
  scenarios: {
    breakpoint: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 2000,
      stages: [
        { duration: '2m', target: 50 },
        { duration: '2m', target: 100 },
        { duration: '2m', target: 200 },
        { duration: '2m', target: 500 },
        { duration: '2m', target: 1000 },
      ],
    },
  },
};
```

### externally-controlled — Dynamic Adjustment

```javascript
export const options = {
  scenarios: {
    dynamic: {
      executor: 'externally-controlled',
      vus: 10,
      maxVUs: 500,
      duration: '30m',
    },
  },
};

// During test, use k6 REST API to adjust:
// PATCH http://localhost:6565/v1/status
// { "data": { "attributes": { "vus": 200 } } }
```

Run with: `k6 run --address localhost:6565 script.js`

### Multiple Scenarios with Graceful Stops

```javascript
export const options = {
  scenarios: {
    reads: {
      executor: 'constant-arrival-rate',
      rate: 400,
      timeUnit: '1s',
      duration: '10m',
      preAllocatedVUs: 50,
      maxVUs: 200,
      exec: 'readFlow',
      gracefulStop: '30s',  // allow 30s for in-flight requests to complete
    },
    writes: {
      executor: 'constant-arrival-rate',
      rate: 100,
      timeUnit: '1s',
      duration: '10m',
      preAllocatedVUs: 20,
      maxVUs: 100,
      exec: 'writeFlow',
      startTime: '30s',     // start 30s after reads begin
      gracefulStop: '30s',
    },
  },
};
```

---

## Browser Testing with xk6-browser

### Installation

```bash
# k6 v0.46+ includes browser module natively
k6 run --browser script.js

# Or build custom binary
xk6 build --with github.com/grafana/xk6-browser@latest
```

### Page Load and Web Vitals

```javascript
import { browser } from 'k6/browser';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const lcp = new Trend('web_vitals_lcp');
const fcp = new Trend('web_vitals_fcp');
const cls = new Trend('web_vitals_cls');
const ttfb = new Trend('web_vitals_ttfb');

export const options = {
  scenarios: {
    browser: {
      executor: 'constant-vus',
      vus: 5,
      duration: '5m',
      options: { browser: { type: 'chromium' } },
    },
  },
  thresholds: {
    web_vitals_lcp: ['p(95)<2500'],
    web_vitals_fcp: ['p(95)<1800'],
    web_vitals_cls: ['p(95)<0.1'],
  },
};

export default async function () {
  const page = await browser.newPage();

  try {
    await page.goto(__ENV.BASE_URL, { waitUntil: 'networkidle' });

    // Collect Web Vitals
    const vitals = await page.evaluate(() => {
      return new Promise((resolve) => {
        const results = {};
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            if (entry.entryType === 'largest-contentful-paint') results.lcp = entry.startTime;
            if (entry.entryType === 'first-contentful-paint') results.fcp = entry.startTime;
            if (entry.entryType === 'layout-shift' && !entry.hadRecentInput) {
              results.cls = (results.cls || 0) + entry.value;
            }
          }
          if (results.lcp) resolve(results);
        }).observe({ type: 'largest-contentful-paint', buffered: true });

        setTimeout(() => resolve(results), 5000);
      });
    });

    if (vitals.lcp) lcp.add(vitals.lcp);
    if (vitals.fcp) fcp.add(vitals.fcp);
    if (vitals.cls !== undefined) cls.add(vitals.cls);
  } finally {
    await page.close();
  }
}
```

### User Flow with Screenshots on Failure

```javascript
import { browser } from 'k6/browser';
import { check } from 'k6';

export default async function () {
  const page = await browser.newPage();

  try {
    await page.goto(`${__ENV.BASE_URL}/login`);

    // Fill login form
    await page.locator('#email').fill('testuser@example.com');
    await page.locator('#password').fill(__ENV.TEST_PASSWORD);
    await page.locator('button[type="submit"]').click();

    // Wait for navigation
    await page.waitForNavigation({ waitUntil: 'networkidle' });

    const success = check(page, {
      'redirected to dashboard': (p) => p.url().includes('/dashboard'),
    });

    if (!success) {
      await page.screenshot({ path: `screenshots/failure-${Date.now()}.png` });
    }

    // Interact with dashboard
    await page.locator('[data-testid="create-project"]').click();
    await page.waitForSelector('[data-testid="project-form"]');
  } finally {
    await page.close();
  }
}
```

### Hybrid Protocol + Browser Test

```javascript
import { browser } from 'k6/browser';
import http from 'k6/http';

export const options = {
  scenarios: {
    // API load in background
    api_load: {
      executor: 'constant-arrival-rate',
      rate: 200,
      timeUnit: '1s',
      duration: '10m',
      preAllocatedVUs: 50,
      maxVUs: 200,
      exec: 'apiTest',
    },
    // Browser users experiencing the load
    browser_users: {
      executor: 'constant-vus',
      vus: 3,
      duration: '10m',
      exec: 'browserTest',
      options: { browser: { type: 'chromium' } },
    },
  },
};

export function apiTest() {
  http.get(`${__ENV.BASE_URL}/api/products`);
}

export async function browserTest() {
  const page = await browser.newPage();
  try {
    await page.goto(`${__ENV.BASE_URL}/products`);
    await page.waitForSelector('.product-card');
  } finally {
    await page.close();
  }
}
```

---

## gRPC Load Testing

### Basic gRPC

```javascript
import grpc from 'k6/net/grpc';
import { check, sleep } from 'k6';
import { Trend, Rate } from 'k6/metrics';

const client = new grpc.Client();
client.load(['proto'], 'user_service.proto');

const grpcDuration = new Trend('grpc_req_duration');
const grpcErrors = new Rate('grpc_errors');

export const options = {
  scenarios: {
    grpc_load: {
      executor: 'constant-arrival-rate',
      rate: 100,
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 20,
      maxVUs: 100,
    },
  },
  thresholds: {
    grpc_req_duration: ['p(95)<200', 'p(99)<500'],
    grpc_errors: ['rate<0.01'],
  },
};

export default function () {
  client.connect('localhost:50051', {
    plaintext: true,
    timeout: '5s',
  });

  const start = Date.now();
  const resp = client.invoke('api.UserService/GetUser', {
    id: String(Math.floor(Math.random() * 10000) + 1),
  });
  grpcDuration.add(Date.now() - start);

  check(resp, {
    'status OK': (r) => r && r.status === grpc.StatusOK,
    'has user': (r) => r && r.message && r.message.name !== '',
  });
  grpcErrors.add(resp.status !== grpc.StatusOK);

  client.close();
  sleep(0.1);
}
```

### gRPC Streaming

```javascript
import grpc from 'k6/net/grpc';

const client = new grpc.Client();
client.load(['proto'], 'stream_service.proto');

export default function () {
  client.connect('localhost:50051', { plaintext: true });

  const stream = new grpc.Stream(client, 'api.StreamService/BidirectionalStream');

  stream.on('data', (msg) => {
    check(msg, { 'received response': (m) => m !== null });
  });

  stream.on('error', (err) => {
    console.error(`Stream error: ${err.message}`);
  });

  // Send multiple messages
  for (let i = 0; i < 10; i++) {
    stream.write({ message: `request-${i}` });
  }

  stream.end();
  client.close();
}
```

### gRPC with TLS and Metadata

```javascript
export default function () {
  client.connect('api.example.com:443', {
    plaintext: false,
    reflect: true,  // use server reflection instead of loading .proto files
  });

  const metadata = {
    'x-request-id': `load-test-${__VU}-${__ITER}`,
    'authorization': `Bearer ${__ENV.GRPC_TOKEN}`,
  };

  const resp = client.invoke('api.OrderService/CreateOrder', {
    items: [{ product_id: '123', quantity: 2 }],
    customer_id: 'test-user',
  }, { metadata });

  check(resp, {
    'order created': (r) => r && r.status === grpc.StatusOK,
    'has order ID': (r) => r && r.message && r.message.order_id !== '',
  });

  client.close();
}
```

---

## WebSocket Testing

### Sustained Connection with Metrics

```javascript
import ws from 'k6/ws';
import { check } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

const msgLatency = new Trend('ws_message_latency');
const msgCount = new Counter('ws_messages_received');
const connectFailure = new Rate('ws_connect_failure');

export const options = {
  scenarios: {
    websocket: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 100 },
        { duration: '5m', target: 100 },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    ws_message_latency: ['p(95)<100'],
    ws_connect_failure: ['rate<0.01'],
  },
};

export default function () {
  const url = `${__ENV.WS_URL}/ws?token=${__ENV.WS_TOKEN}`;

  const res = ws.connect(url, { tags: { name: 'price-feed' } }, function (socket) {
    let messagesSent = 0;

    socket.on('open', () => {
      socket.send(JSON.stringify({
        type: 'subscribe',
        channels: ['prices', 'orderbook'],
      }));

      // Send periodic pings
      socket.setInterval(() => {
        socket.ping();
        socket.send(JSON.stringify({
          type: 'heartbeat',
          timestamp: Date.now(),
        }));
        messagesSent++;
      }, 5000);
    });

    socket.on('message', (data) => {
      const msg = JSON.parse(data);
      msgCount.add(1);

      if (msg.timestamp) {
        msgLatency.add(Date.now() - msg.timestamp);
      }

      check(msg, {
        'valid message type': (m) => ['price', 'orderbook', 'heartbeat_ack'].includes(m.type),
        'has data': (m) => m.data !== undefined || m.type === 'heartbeat_ack',
      });
    });

    socket.on('error', (e) => {
      console.error(`WS error VU ${__VU}: ${e.error()}`);
    });

    socket.on('close', () => {
      console.log(`VU ${__VU}: connection closed after ${messagesSent} heartbeats`);
    });

    // Keep connection open for test duration
    socket.setTimeout(() => {
      socket.close();
    }, 60000); // 60s per connection cycle
  });

  connectFailure.add(res.status !== 101);
  check(res, { 'ws connected': (r) => r && r.status === 101 });
}
```

### Chat Application Load Test

```javascript
import ws from 'k6/ws';
import { sleep } from 'k6';

export default function () {
  const roomId = `room-${(__VU % 10) + 1}`;  // 10 chat rooms

  const res = ws.connect(`${__ENV.WS_URL}/chat/${roomId}`, {}, function (socket) {
    socket.on('open', () => {
      socket.send(JSON.stringify({ type: 'join', user: `user-${__VU}` }));
    });

    socket.on('message', (data) => {
      const msg = JSON.parse(data);
      if (msg.type === 'joined') {
        // Simulate typing and sending messages
        socket.setInterval(() => {
          socket.send(JSON.stringify({
            type: 'message',
            text: `Load test message from VU ${__VU} at ${Date.now()}`,
            room: roomId,
          }));
        }, 3000 + Math.random() * 5000); // 3-8s between messages
      }
    });

    socket.setTimeout(() => {
      socket.send(JSON.stringify({ type: 'leave' }));
      socket.close();
    }, 120000);
  });
}
```

---

## Test Data Management

### SharedArray for Memory Efficiency

`SharedArray` shares read-only data across all VUs in a single memory allocation.

```javascript
import { SharedArray } from 'k6/data';
import papaparse from 'https://jslib.k6.io/papaparse/5.1.1/index.js';

// Loaded once, shared across all VUs (read-only)
const users = new SharedArray('users', function () {
  return papaparse.parse(open('./data/users.csv'), { header: true }).data;
});

const products = new SharedArray('products', function () {
  return JSON.parse(open('./data/products.json'));
});

export default function () {
  // Unique user per VU (cycling through dataset)
  const user = users[__VU % users.length];

  // Random product per iteration
  const product = products[Math.floor(Math.random() * products.length)];

  http.post(`${BASE_URL}/api/orders`, JSON.stringify({
    user_id: user.id,
    product_id: product.id,
    quantity: Math.floor(Math.random() * 5) + 1,
  }));
}
```

### CSV Parsing Patterns

```javascript
import papaparse from 'https://jslib.k6.io/papaparse/5.1.1/index.js';
import { SharedArray } from 'k6/data';

// Large CSV with headers
const testData = new SharedArray('large-dataset', function () {
  const raw = open('./data/test-data.csv');
  const parsed = papaparse.parse(raw, {
    header: true,
    skipEmptyLines: true,
    dynamicTyping: true,     // auto-convert numbers/booleans
    transformHeader: (h) => h.trim().toLowerCase().replace(/\s+/g, '_'),
  });

  if (parsed.errors.length > 0) {
    console.warn(`CSV parse warnings: ${JSON.stringify(parsed.errors.slice(0, 5))}`);
  }

  return parsed.data;
});

// Sequential access — each VU gets unique rows
export default function () {
  const index = (__VU - 1) * 100 + __ITER; // assuming 100 iterations per VU
  if (index >= testData.length) return;
  const row = testData[index];
  // Use row.field_name
}
```

### Dynamic Data Generation

```javascript
import { randomString, randomIntBetween, randomItem } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

export default function () {
  const payload = {
    email: `loadtest+${randomString(8)}@example.com`,
    name: `User ${randomString(6)}`,
    age: randomIntBetween(18, 65),
    plan: randomItem(['free', 'pro', 'enterprise']),
    created_at: new Date().toISOString(),
  };

  http.post(`${BASE_URL}/api/users`, JSON.stringify(payload), {
    headers: { 'Content-Type': 'application/json' },
  });
}
```

### Test Data Isolation Strategies

```javascript
// Per-VU unique data using setup() to generate/provision
export function setup() {
  const users = [];
  for (let i = 0; i < 100; i++) {
    const res = http.post(`${BASE_URL}/api/test-users`, JSON.stringify({
      email: `perf-test-${Date.now()}-${i}@test.com`,
    }));
    users.push(res.json());
  }
  return { users };
}

export default function (data) {
  const user = data.users[__VU % data.users.length];
  // Test with provisioned user
}

export function teardown(data) {
  // Clean up test data
  for (const user of data.users) {
    http.del(`${BASE_URL}/api/test-users/${user.id}`);
  }
}
```

---

## Custom Summary Handlers

### Custom JSON Summary

```javascript
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

export function handleSummary(data) {
  const summary = {
    timestamp: new Date().toISOString(),
    test_run_id: __ENV.TEST_RUN_ID || `run-${Date.now()}`,
    environment: __ENV.ENVIRONMENT || 'unknown',
    metrics: {
      http_req_duration_p95: data.metrics.http_req_duration?.values['p(95)'],
      http_req_duration_p99: data.metrics.http_req_duration?.values['p(99)'],
      http_req_failed_rate: data.metrics.http_req_failed?.values.rate,
      http_reqs_rate: data.metrics.http_reqs?.values.rate,
      vus_max: data.metrics.vus_max?.values.max,
      iterations_count: data.metrics.iterations?.values.count,
    },
    thresholds: {},
  };

  // Extract threshold pass/fail
  for (const [name, threshold] of Object.entries(data.metrics)) {
    if (threshold.thresholds) {
      summary.thresholds[name] = {};
      for (const [key, val] of Object.entries(threshold.thresholds)) {
        summary.thresholds[name][key] = val.ok;
      }
    }
  }

  return {
    stdout: textSummary(data, { indent: '  ', enableColors: true }),
    'results/summary.json': JSON.stringify(summary, null, 2),
    'results/raw-data.json': JSON.stringify(data, null, 2),
  };
}
```

### HTML Report Generation

```javascript
import { htmlReport } from 'https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: '  ', enableColors: true }),
    'results/report.html': htmlReport(data),
    'results/summary.json': JSON.stringify(data, null, 2),
  };
}
```

### Slack/Webhook Notification on Completion

```javascript
import http from 'k6/http';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

export function handleSummary(data) {
  const p95 = data.metrics.http_req_duration?.values['p(95)'] || 0;
  const errorRate = data.metrics.http_req_failed?.values.rate || 0;
  const rps = data.metrics.http_reqs?.values.rate || 0;

  // Check if any thresholds failed
  let failed = false;
  for (const metric of Object.values(data.metrics)) {
    if (metric.thresholds) {
      for (const t of Object.values(metric.thresholds)) {
        if (!t.ok) failed = true;
      }
    }
  }

  const emoji = failed ? '🔴' : '🟢';
  const status = failed ? 'FAILED' : 'PASSED';

  if (__ENV.SLACK_WEBHOOK_URL) {
    http.post(__ENV.SLACK_WEBHOOK_URL, JSON.stringify({
      text: `${emoji} Load Test ${status}\n` +
            `• p95 latency: ${p95.toFixed(0)}ms\n` +
            `• Error rate: ${(errorRate * 100).toFixed(2)}%\n` +
            `• Throughput: ${rps.toFixed(0)} RPS\n` +
            `• Environment: ${__ENV.ENVIRONMENT || 'unknown'}`,
    }));
  }

  return {
    stdout: textSummary(data, { indent: '  ', enableColors: true }),
    'results/summary.json': JSON.stringify(data, null, 2),
  };
}
```

---

## k6 Extensions Ecosystem

### Most Useful Extensions

| Extension | Purpose | Install |
|-----------|---------|---------|
| **xk6-browser** | Chromium browser testing (built-in since k6 v0.46) | Built-in |
| **xk6-dashboard** | Real-time HTML dashboard | `xk6 build --with github.com/grafana/xk6-dashboard` |
| **xk6-sql** | Direct database testing (Postgres, MySQL, SQLite) | `xk6 build --with github.com/grafana/xk6-sql` |
| **xk6-kafka** | Kafka producer/consumer testing | `xk6 build --with github.com/mostafa/xk6-kafka` |
| **xk6-output-prometheus-remote** | Prometheus remote write output | `xk6 build --with github.com/grafana/xk6-output-prometheus-remote` |
| **xk6-disruptor** | Fault injection for k8s | `xk6 build --with github.com/grafana/xk6-disruptor` |
| **xk6-exec** | Execute OS commands during test | `xk6 build --with github.com/grafana/xk6-exec` |

### Building Custom k6 Binary

```bash
# Install xk6
go install go.k6.io/xk6/cmd/xk6@latest

# Build with multiple extensions
xk6 build latest \
  --with github.com/grafana/xk6-dashboard@latest \
  --with github.com/grafana/xk6-sql@latest \
  --with github.com/mostafa/xk6-kafka@latest

# Use the custom binary
./k6 run --out dashboard script.js
```

### xk6-sql Database Testing

```javascript
import sql from 'k6/x/sql';
import driver from 'k6/x/sql/driver/postgres';

const db = sql.open(driver, 'postgres://user:pass@localhost:5432/testdb?sslmode=disable');

export const options = {
  scenarios: {
    db_reads: {
      executor: 'constant-arrival-rate',
      rate: 100,
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 20,
      maxVUs: 50,
      exec: 'readTest',
    },
    db_writes: {
      executor: 'constant-arrival-rate',
      rate: 20,
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 10,
      maxVUs: 30,
      exec: 'writeTest',
    },
  },
};

export function readTest() {
  const id = Math.floor(Math.random() * 100000) + 1;
  const results = sql.query(db, `SELECT * FROM users WHERE id = $1`, id);
  check(results, { 'row found': (r) => r.length > 0 });
}

export function writeTest() {
  sql.exec(db, `INSERT INTO events (type, data, created_at) VALUES ($1, $2, NOW())`,
    'load_test', `{"vu": ${__VU}, "iter": ${__ITER}}`);
}

export function teardown() {
  db.close();
}
```

---

## k6 Cloud Features

### Running on k6 Cloud

```bash
# Authenticate
k6 login cloud --token YOUR_API_TOKEN

# Run entirely on k6 Cloud (distributed)
k6 cloud script.js

# Run locally, stream results to Cloud
k6 run --out cloud script.js

# Run on Cloud from specific geo-locations
k6 cloud --env REGION=us-east-1 script.js
```

### Cloud Configuration in Script

```javascript
export const options = {
  cloud: {
    projectID: 12345,
    name: 'API Load Test - Production',
    distribution: {
      us_east: { loadZone: 'amazon:us:ashburn', percent: 50 },
      eu_west: { loadZone: 'amazon:ie:dublin', percent: 30 },
      ap_south: { loadZone: 'amazon:sg:singapore', percent: 20 },
    },
  },
};
```

### Performance Insights (Automated Analysis)

k6 Cloud automatically detects:
- **Throughput plateau** — system stops scaling before target
- **Increased error rate** — errors correlate with load increase
- **High response time variability** — unstable latency distribution
- **Third-party bottlenecks** — external service degradation

---

## Test Lifecycle Hooks

```javascript
// 1. init — Module-level code runs once per VU during initialization.
//    Load files, define options, import modules.
import http from 'k6/http';
import { SharedArray } from 'k6/data';

const data = new SharedArray('data', () => JSON.parse(open('./data.json')));

export const options = { vus: 10, duration: '5m' };

// 2. setup() — Runs once before all VUs start.
//    Provision test data, get auth tokens, warm up caches.
export function setup() {
  const token = http.post(`${BASE_URL}/auth`, JSON.stringify(creds)).json('token');
  return { token, startTime: Date.now() };
}

// 3. default function (or named scenario function) — Runs repeatedly per VU.
//    The actual test logic.
export default function (setupData) {
  http.get(`${BASE_URL}/api/test`, {
    headers: { Authorization: `Bearer ${setupData.token}` },
  });
}

// 4. teardown() — Runs once after all VUs finish.
//    Clean up test data, send notifications.
export function teardown(setupData) {
  const duration = (Date.now() - setupData.startTime) / 1000;
  console.log(`Test ran for ${duration}s`);
  http.del(`${BASE_URL}/api/test-data`);
}

// 5. handleSummary() — Runs once after teardown with aggregated results.
//    Generate custom reports, send to external systems.
export function handleSummary(data) {
  return { stdout: JSON.stringify(data.metrics, null, 2) };
}
```

**Important**: `setup()` and `teardown()` run as a single VU — don't put load-generating code there. The return value from `setup()` is serialized/deserialized (JSON), so it cannot contain functions or complex objects.

---

## Scenario-Based Testing

### E-Commerce Load Model

```javascript
export const options = {
  scenarios: {
    // 70% of users just browse
    browsers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '3m', target: 350 },
        { duration: '10m', target: 350 },
        { duration: '2m', target: 0 },
      ],
      exec: 'browseProducts',
    },
    // 20% add to cart
    shoppers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '3m', target: 100 },
        { duration: '10m', target: 100 },
        { duration: '2m', target: 0 },
      ],
      exec: 'addToCart',
    },
    // 10% complete purchase
    buyers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '3m', target: 50 },
        { duration: '10m', target: 50 },
        { duration: '2m', target: 0 },
      ],
      exec: 'checkout',
    },
    // Background: API health checks
    monitoring: {
      executor: 'constant-arrival-rate',
      rate: 1,
      timeUnit: '1s',
      duration: '15m',
      preAllocatedVUs: 1,
      exec: 'healthCheck',
    },
  },
};

export function browseProducts() {
  group('Browse', () => {
    http.get(`${BASE_URL}/api/products`);
    sleep(randomIntBetween(2, 5));
    const id = randomIntBetween(1, 100);
    http.get(`${BASE_URL}/api/products/${id}`);
    sleep(randomIntBetween(1, 3));
  });
}

export function addToCart() {
  browseProducts();
  group('Cart', () => {
    http.post(`${BASE_URL}/api/cart`, JSON.stringify({
      product_id: randomIntBetween(1, 100),
      quantity: randomIntBetween(1, 3),
    }));
    sleep(randomIntBetween(2, 8));
  });
}

export function checkout() {
  addToCart();
  group('Checkout', () => {
    http.post(`${BASE_URL}/api/orders`, JSON.stringify({ payment_method: 'test' }));
    sleep(1);
  });
}

export function healthCheck() {
  const res = http.get(`${BASE_URL}/health`);
  check(res, { 'healthy': (r) => r.status === 200 });
}
```

---

## Environment-Specific Configs

### Config Files Pattern

```javascript
// config.js — shared across environments
const configs = {
  dev: {
    baseUrl: 'https://dev.example.com',
    vus: 10,
    duration: '2m',
    thresholds: { 'http_req_duration': ['p(95)<1000'] },
  },
  staging: {
    baseUrl: 'https://staging.example.com',
    vus: 100,
    duration: '10m',
    thresholds: { 'http_req_duration': ['p(95)<500'] },
  },
  production: {
    baseUrl: 'https://api.example.com',
    vus: 500,
    duration: '15m',
    thresholds: { 'http_req_duration': ['p(95)<300', 'p(99)<1000'] },
  },
};

export default configs[__ENV.ENVIRONMENT || 'dev'];
```

```javascript
// test.js
import config from './config.js';

export const options = {
  vus: config.vus,
  duration: config.duration,
  thresholds: config.thresholds,
};

export default function () {
  http.get(`${config.baseUrl}/api/health`);
}
```

```bash
# Run with environment
k6 run --env ENVIRONMENT=staging test.js
```

### Options Override via CLI

```bash
# Override script options from CLI
k6 run \
  --vus 200 \
  --duration 30m \
  --env BASE_URL=https://staging.example.com \
  --tag testrun=nightly-2024-01-15 \
  --out influxdb=http://influxdb:8086/k6 \
  script.js
```

---

## Tagging and Filtering

### Custom Tags

```javascript
export default function () {
  const params = {
    tags: {
      api_version: 'v2',
      feature: 'search',
      priority: 'high',
    },
  };

  http.get(`${BASE_URL}/api/v2/search?q=test`, params);
}
```

### Tag-Based Thresholds

```javascript
export const options = {
  thresholds: {
    'http_req_duration{api_version:v2}': ['p(95)<200'],
    'http_req_duration{feature:search}': ['p(95)<500'],
    'http_req_duration{priority:high}': ['p(99)<300'],
    'http_req_failed{feature:checkout}': ['rate<0.001'],
  },
};
```

### Filtering Metrics Output

```bash
# Only output metrics with specific tags
k6 run --tag env=staging --tag team=platform script.js

# In InfluxDB/Grafana, filter dashboards by these tags
```

---

## Advanced Checks and Groups

### Nested Groups for Metric Hierarchy

```javascript
export default function () {
  group('User Journey', () => {
    group('Authentication', () => {
      const loginRes = http.post(`${BASE_URL}/login`, loginPayload);
      check(loginRes, { 'login success': (r) => r.status === 200 });
    });

    group('Product Browsing', () => {
      const listRes = http.get(`${BASE_URL}/api/products`);
      check(listRes, { 'products loaded': (r) => r.status === 200 });

      if (listRes.status === 200) {
        const products = listRes.json('data');
        const product = products[Math.floor(Math.random() * products.length)];

        const detailRes = http.get(`${BASE_URL}/api/products/${product.id}`);
        check(detailRes, { 'detail loaded': (r) => r.status === 200 });
      }
    });
  });
}
```

Groups create `group_duration` metrics: `group_duration{group:::User Journey::Authentication}`, useful for per-journey thresholds.

---

## HTTP/2 and Connection Reuse

### Connection Configuration

```javascript
export const options = {
  // HTTP/2 is enabled by default for HTTPS
  // Force HTTP/1.1 if needed:
  // httpDebug: 'full',

  dns: {
    ttl: '5m',           // DNS cache TTL
    select: 'roundRobin', // or 'random', 'first'
    policy: 'preferIPv4',
  },

  // Connection settings
  noConnectionReuse: false,    // reuse connections (default)
  noVUConnectionReuse: false,  // share connections across VUs
  minIterationDuration: '1s',  // minimum time between iterations per VU

  // TLS settings
  tlsAuth: [
    {
      cert: open('./certs/client.crt'),
      key: open('./certs/client.key'),
    },
  ],
  tlsVersion: {
    min: 'tls1.2',
    max: 'tls1.3',
  },
};
```

### Batch Requests (Parallel within VU)

```javascript
export default function () {
  const responses = http.batch([
    ['GET', `${BASE_URL}/api/user/profile`],
    ['GET', `${BASE_URL}/api/user/notifications`],
    ['GET', `${BASE_URL}/api/user/settings`],
  ]);

  check(responses[0], { 'profile loaded': (r) => r.status === 200 });
  check(responses[1], { 'notifications loaded': (r) => r.status === 200 });
  check(responses[2], { 'settings loaded': (r) => r.status === 200 });
}
```
