# k6 Advanced Patterns Reference

## Table of Contents
- [Complex Scenario Composition](#complex-scenario-composition)
- [Custom Executors Deep-Dive](#custom-executors-deep-dive)
- [Modular Test Structure](#modular-test-structure)
- [Data Correlation](#data-correlation)
- [Dynamic Data Generation](#dynamic-data-generation)
- [Custom Metrics and Summary Handlers](#custom-metrics-and-summary-handlers)
- [Test Lifecycle Hooks](#test-lifecycle-hooks)
- [Browser Module Deep-Dive](#browser-module-deep-dive)
- [gRPC Testing Patterns](#grpc-testing-patterns)
- [WebSocket Testing Patterns](#websocket-testing-patterns)
- [Distributed Testing](#distributed-testing)

---

## Complex Scenario Composition

### Multi-Scenario with Staggered Start Times

Run different user flows concurrently with independent timing:

```javascript
export const options = {
  scenarios: {
    // Background browsing traffic starts immediately
    browse: {
      executor: 'constant-vus',
      exec: 'browseFlow',
      vus: 20,
      duration: '10m',
    },
    // Auth spike starts at 2m
    auth_spike: {
      executor: 'ramping-arrival-rate',
      exec: 'authFlow',
      startTime: '2m',
      startRate: 5,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 200,
      stages: [
        { target: 100, duration: '1m' },
        { target: 100, duration: '3m' },
        { target: 5, duration: '1m' },
      ],
    },
    // Checkout flow starts at 5m (after auth users exist)
    checkout: {
      executor: 'per-vu-iterations',
      exec: 'checkoutFlow',
      startTime: '5m',
      vus: 10,
      iterations: 20,
      maxDuration: '5m',
    },
  },
};

export function browseFlow() { /* ... */ }
export function authFlow() { /* ... */ }
export function checkoutFlow() { /* ... */ }
```

### Per-Scenario Environment Variables and Tags

```javascript
export const options = {
  scenarios: {
    internal_api: {
      executor: 'constant-vus',
      exec: 'internalTest',
      vus: 10,
      duration: '5m',
      env: { API_HOST: 'internal-api.local', API_KEY: 'internal-key' },
      tags: { team: 'platform', tier: 'internal' },
    },
    public_api: {
      executor: 'constant-vus',
      exec: 'publicTest',
      vus: 50,
      duration: '5m',
      env: { API_HOST: 'api.example.com', API_KEY: 'public-key' },
      tags: { team: 'frontend', tier: 'public' },
    },
  },
  thresholds: {
    'http_req_duration{tier:internal}': ['p(95)<200'],
    'http_req_duration{tier:public}': ['p(95)<500'],
  },
};
```

### Graceful Stop and Ramp-Down

```javascript
export const options = {
  scenarios: {
    main: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 100 },
        { duration: '5m', target: 100 },
        { duration: '2m', target: 0 },
      ],
      gracefulRampDown: '30s', // VUs get 30s to finish current iteration
      gracefulStop: '1m',      // scenario gets 1m after duration to wrap up
    },
  },
};
```

---

## Custom Executors Deep-Dive

### Open vs Closed Model Decision Matrix

| Model | Executor | Use When |
|-------|----------|----------|
| **Closed** | `constant-vus` | Steady concurrency, simple load |
| **Closed** | `ramping-vus` | Classic ramp-up/plateau/ramp-down |
| **Open** | `constant-arrival-rate` | Fixed RPS regardless of response time |
| **Open** | `ramping-arrival-rate` | Ramp throughput for breakpoint testing |
| **Bounded** | `shared-iterations` | Fixed total work across all VUs |
| **Bounded** | `per-vu-iterations` | Each VU does exact N iterations |

### Arrival Rate: Pre-Allocation Strategy

```javascript
export const options = {
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: 500,            // 500 iterations/second
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 100, // start with 100 VUs
      maxVUs: 1000,         // scale up to 1000 if needed
      // If preAllocatedVUs is too low, k6 allocates more (up to maxVUs)
      // Each new VU allocation has overhead — pre-allocate enough
    },
  },
};
```

**Sizing rule of thumb:** `preAllocatedVUs ≈ rate × expected_avg_response_time_seconds`. If avg response = 200ms and rate = 500/s, pre-allocate ~100 VUs.

### Externally Controlled Executor

Dynamically adjust VUs at runtime via k6 REST API:

```javascript
export const options = {
  scenarios: {
    controlled: {
      executor: 'externally-controlled',
      vus: 10,
      maxVUs: 500,
      duration: '30m',
    },
  },
};
```

```bash
# Scale VUs via REST API while test runs
curl -X PATCH http://localhost:6565/v1/status \
  -H 'Content-Type: application/json' \
  -d '{"data":{"attributes":{"vus":200}}}'

# k6 must be started with --address flag:
k6 run --address localhost:6565 script.js
```

---

## Modular Test Structure

### Recommended Project Layout

```
k6-tests/
├── config/
│   ├── environments.js     # env-specific configs
│   └── thresholds.js       # shared threshold definitions
├── scenarios/
│   ├── smoke.js            # smoke test entry point
│   ├── load.js             # load test entry point
│   └── stress.js           # stress test entry point
├── flows/
│   ├── auth.js             # login/logout flow
│   ├── browse.js           # browsing flow
│   └── checkout.js         # checkout flow
├── helpers/
│   ├── requests.js         # HTTP helper wrappers
│   ├── checks.js           # reusable check functions
│   └── data.js             # data loading utilities
├── testdata/
│   ├── users.json
│   └── products.csv
└── lib/
    └── utils.js            # general utilities
```

### Environment Config Module

```javascript
// config/environments.js
const environments = {
  staging: {
    baseUrl: 'https://staging-api.example.com',
    wsUrl: 'wss://staging-ws.example.com',
    thinkTime: { min: 1, max: 3 },
  },
  production: {
    baseUrl: 'https://api.example.com',
    wsUrl: 'wss://ws.example.com',
    thinkTime: { min: 2, max: 5 },
  },
};

export default environments[__ENV.ENV || 'staging'];
```

### Reusable Flow Module

```javascript
// flows/auth.js
import http from 'k6/http';
import { check } from 'k6';
import env from '../config/environments.js';

export function login(username, password) {
  const res = http.post(`${env.baseUrl}/auth/login`,
    JSON.stringify({ username, password }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'Login' } }
  );
  const success = check(res, {
    'login status 200': (r) => r.status === 200,
    'login has token': (r) => r.json('token') !== undefined,
  });
  return success ? res.json('token') : null;
}

export function authenticatedHeaders(token) {
  return {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${token}`,
  };
}
```

### Scenario Entry Point Using Modules

```javascript
// scenarios/load.js
import { login, authenticatedHeaders } from '../flows/auth.js';
import { SharedArray } from 'k6/data';
import http from 'k6/http';
import { sleep } from 'k6';
import env from '../config/environments.js';

const users = new SharedArray('users', () => JSON.parse(open('../testdata/users.json')));

export const options = {
  scenarios: {
    load: {
      executor: 'ramping-vus',
      stages: [
        { duration: '2m', target: 50 },
        { duration: '5m', target: 50 },
        { duration: '2m', target: 0 },
      ],
    },
  },
  thresholds: {
    'http_req_duration{name:Login}': ['p(95)<400'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const user = users[__VU % users.length];
  const token = login(user.username, user.password);
  if (!token) return;

  http.get(`${env.baseUrl}/products`, {
    headers: authenticatedHeaders(token),
    tags: { name: 'ListProducts' },
  });

  sleep(Math.random() * (env.thinkTime.max - env.thinkTime.min) + env.thinkTime.min);
}
```

---

## Data Correlation

Extract values from one response and use in subsequent requests (session tokens, IDs, CSRF tokens):

### Token Extraction Chain

```javascript
import http from 'k6/http';
import { check } from 'k6';

export default function () {
  // Step 1: Login → extract token
  const loginRes = http.post('https://api.example.com/auth/login',
    JSON.stringify({ username: 'testuser', password: 'testpass' }),
    { headers: { 'Content-Type': 'application/json' } }
  );
  const token = loginRes.json('data.accessToken');
  const refreshToken = loginRes.json('data.refreshToken');
  check(loginRes, { 'has token': () => token !== undefined });

  // Step 2: Create resource → extract ID from response
  const createRes = http.post('https://api.example.com/orders',
    JSON.stringify({ items: [{ sku: 'ABC123', qty: 2 }] }),
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );
  const orderId = createRes.json('data.orderId');
  check(createRes, { 'order created': (r) => r.status === 201 });

  // Step 3: Use extracted ID in subsequent request
  const statusRes = http.get(`https://api.example.com/orders/${orderId}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  check(statusRes, { 'order found': (r) => r.status === 200 });
}
```

### HTML Form / CSRF Token Extraction

```javascript
import http from 'k6/http';
import { parseHTML } from 'k6/html';

export default function () {
  // Load page with CSRF token
  const page = http.get('https://example.com/login');
  const doc = parseHTML(page.body);
  const csrfToken = doc.find('input[name="csrf_token"]').attr('value');

  // Submit form with extracted token
  http.post('https://example.com/login', {
    username: 'test',
    password: 'pass',
    csrf_token: csrfToken,
  });
}
```

### Response Header Correlation

```javascript
export default function () {
  const res = http.post('https://api.example.com/session', '{}');
  // Extract from headers
  const sessionId = res.headers['X-Session-Id'];
  const rateLimitRemaining = parseInt(res.headers['X-RateLimit-Remaining']);

  // Use in next request
  http.get('https://api.example.com/data', {
    headers: { 'X-Session-Id': sessionId },
  });
}
```

---

## Dynamic Data Generation

### UUID and Random Data

```javascript
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';
import { randomString, randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';
import exec from 'k6/execution';

export default function () {
  const uniqueUser = {
    id: uuidv4(),
    username: `user_${exec.vu.idInInstance}_${exec.vu.iterationInScenario}`,
    email: `${randomString(8)}@loadtest.com`,
    age: randomIntBetween(18, 65),
  };

  http.post('https://api.example.com/users',
    JSON.stringify(uniqueUser),
    { headers: { 'Content-Type': 'application/json' } }
  );
}
```

### Weighted Random Selection

```javascript
function weightedRandom(items) {
  const totalWeight = items.reduce((sum, item) => sum + item.weight, 0);
  let random = Math.random() * totalWeight;
  for (const item of items) {
    random -= item.weight;
    if (random <= 0) return item.value;
  }
  return items[items.length - 1].value;
}

const actions = [
  { value: 'browse', weight: 60 },
  { value: 'search', weight: 25 },
  { value: 'purchase', weight: 10 },
  { value: 'return', weight: 5 },
];

export default function () {
  const action = weightedRandom(actions);
  // Route to different flows based on weight
  switch (action) {
    case 'browse': browseCatalog(); break;
    case 'search': searchProducts(); break;
    case 'purchase': makePurchase(); break;
    case 'return': initiateReturn(); break;
  }
}
```

---

## Custom Metrics and Summary Handlers

### Business-Level Custom Metrics

```javascript
import { Counter, Gauge, Rate, Trend } from 'k6/metrics';

// Business metrics
const orderValue = new Trend('order_value_usd', false);
const ordersPlaced = new Counter('orders_placed');
const cartAbandonRate = new Rate('cart_abandon_rate');
const inventoryLevel = new Gauge('inventory_level');

// SLA metrics
const e2eLatency = new Trend('e2e_checkout_latency', true);

export const options = {
  thresholds: {
    order_value_usd: ['avg>50'],
    orders_placed: ['count>100'],
    cart_abandon_rate: ['rate<0.3'],
    e2e_checkout_latency: ['p(95)<3000'],
  },
};

export default function () {
  const start = Date.now();
  // ... checkout flow ...
  e2eLatency.add(Date.now() - start);
  ordersPlaced.add(1);
  orderValue.add(149.99);
  cartAbandonRate.add(false); // false = completed, true = abandoned
}
```

### Custom Summary Handler (handleSummary)

```javascript
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';
import { htmlReport } from 'https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js';

export function handleSummary(data) {
  // data contains all metric results, thresholds, checks, groups
  const failedThresholds = Object.entries(data.metrics)
    .filter(([, m]) => m.thresholds && Object.values(m.thresholds).some(t => !t.ok))
    .map(([name]) => name);

  return {
    // Console output
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
    // HTML report file
    'report.html': htmlReport(data),
    // JSON summary
    'summary.json': JSON.stringify(data, null, 2),
    // Custom JUnit XML for CI
    'junit.xml': generateJUnitXml(data, failedThresholds),
  };
}

function generateJUnitXml(data, failedThresholds) {
  const testcases = Object.entries(data.metrics)
    .filter(([, m]) => m.thresholds)
    .map(([name, m]) => {
      const passed = Object.values(m.thresholds).every(t => t.ok);
      return passed
        ? `  <testcase name="${name}" classname="k6.thresholds"/>`
        : `  <testcase name="${name}" classname="k6.thresholds"><failure message="Threshold breached"/></testcase>`;
    }).join('\n');

  return `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="k6" tests="${Object.keys(data.metrics).length}" failures="${failedThresholds.length}">
${testcases}
</testsuite>`;
}
```

---

## Test Lifecycle Hooks

### Setup with Error Handling and Retry

```javascript
import http from 'k6/http';
import exec from 'k6/execution';

export function setup() {
  // Retry setup operations
  let token = null;
  for (let attempt = 1; attempt <= 3; attempt++) {
    const res = http.post('https://api.example.com/auth/service-token',
      JSON.stringify({ clientId: __ENV.CLIENT_ID, secret: __ENV.CLIENT_SECRET }),
      { headers: { 'Content-Type': 'application/json' } }
    );
    if (res.status === 200) {
      token = res.json('token');
      break;
    }
    console.warn(`Setup attempt ${attempt} failed: ${res.status}`);
    if (attempt === 3) {
      exec.test.abort('Setup failed after 3 attempts');
    }
  }

  // Seed test data
  const testOrg = http.post('https://api.example.com/orgs',
    JSON.stringify({ name: `loadtest-${Date.now()}` }),
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );

  return {
    token,
    orgId: testOrg.json('id'),
    startTime: Date.now(),
  };
}

export function teardown(data) {
  // Cleanup: delete test org
  http.del(`https://api.example.com/orgs/${data.orgId}`, null, {
    headers: { Authorization: `Bearer ${data.token}` },
  });
  console.log(`Test duration: ${(Date.now() - data.startTime) / 1000}s`);
}
```

### Using exec.test.abort for Early Termination

```javascript
import exec from 'k6/execution';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');
let consecutiveErrors = 0;

export default function () {
  const res = http.get('https://api.example.com/health');
  if (res.status !== 200) {
    consecutiveErrors++;
    errorRate.add(1);
    if (consecutiveErrors > 50) {
      exec.test.abort('Too many consecutive errors — target may be down');
    }
  } else {
    consecutiveErrors = 0;
    errorRate.add(0);
  }
}
```

---

## Browser Module Deep-Dive

### Hybrid Protocol + Browser Test

```javascript
import { browser } from 'k6/browser';
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  scenarios: {
    // High-volume API load
    api_load: {
      executor: 'constant-arrival-rate',
      exec: 'apiTest',
      rate: 100,
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 50,
      maxVUs: 200,
    },
    // Low-volume browser tests for UX metrics
    browser_test: {
      executor: 'constant-vus',
      exec: 'browserTest',
      vus: 2,
      duration: '5m',
      options: { browser: { type: 'chromium' } },
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500'],
    browser_web_vital_lcp: ['p(95)<2500'],
    browser_web_vital_fid: ['p(95)<100'],
    browser_web_vital_cls: ['p(95)<0.1'],
  },
};

export function apiTest() {
  http.get('https://api.example.com/products');
}

export async function browserTest() {
  const page = await browser.newPage();
  try {
    await page.goto('https://example.com', { waitUntil: 'networkidle' });

    // Measure custom timing
    const navTiming = JSON.parse(
      await page.evaluate(() => JSON.stringify(performance.getEntriesByType('navigation')[0]))
    );
    console.log(`DOM Interactive: ${navTiming.domInteractive}ms`);

    // User interaction
    await page.locator('#search-input').fill('test product');
    await page.locator('#search-btn').click();
    await page.waitForSelector('.results-list', { timeout: 5000 });

    const resultCount = await page.locator('.result-item').count();
    check(null, { 'search has results': () => resultCount > 0 });
  } finally {
    await page.close();
  }
}
```

### Browser: Screenshots and Network Interception

```javascript
export async function browserTest() {
  const page = await browser.newPage();
  try {
    // Block analytics/tracking for cleaner tests
    await page.route('**/*google-analytics*', (route) => route.abort());
    await page.route('**/*hotjar*', (route) => route.abort());

    await page.goto('https://example.com');

    // Take screenshot on failure
    const heading = await page.locator('h1').textContent();
    if (!heading.includes('Welcome')) {
      await page.screenshot({ path: `screenshots/failure-${Date.now()}.png` });
    }

    // Evaluate JavaScript in page context
    const perfMetrics = await page.evaluate(() => ({
      memory: performance.memory?.usedJSHeapSize,
      resources: performance.getEntriesByType('resource').length,
    }));
    console.log(`Page resources: ${perfMetrics.resources}`);
  } finally {
    await page.close();
  }
}
```

---

## gRPC Testing Patterns

### Bidirectional Streaming

```javascript
import grpc from 'k6/net/grpc';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

const client = new grpc.Client();
client.load(['./proto'], 'chat.proto');
const grpcLatency = new Trend('grpc_latency', true);

export default function () {
  client.connect('localhost:50051', {
    plaintext: false,
    timeout: '5s',
    tls: {
      cacert: open('./certs/ca.pem'),
      cert: open('./certs/client-cert.pem'),
      key: open('./certs/client-key.pem'),
    },
  });

  const start = Date.now();

  // Unary call
  const resp = client.invoke('chat.ChatService/SendMessage', {
    user: `user-${__VU}`,
    text: `Message from VU ${__VU} iteration ${__ITER}`,
    timestamp: Date.now(),
  });

  grpcLatency.add(Date.now() - start);

  check(resp, {
    'gRPC status OK': (r) => r && r.status === grpc.StatusOK,
    'has message id': (r) => r && r.message.messageId !== '',
  });

  client.close();
  sleep(0.5);
}
```

### gRPC with Server Reflection (No .proto Files)

```javascript
import grpc from 'k6/net/grpc';

const client = new grpc.Client();

export default function () {
  // Reflect discovers services/methods at runtime
  client.connect('localhost:50051', { plaintext: true, reflect: true });

  const resp = client.invoke('mypackage.MyService/MyMethod', {
    field1: 'value',
    field2: 42,
  });

  check(resp, { 'status ok': (r) => r && r.status === grpc.StatusOK });
  client.close();
}
```

---

## WebSocket Testing Patterns

### Full-Duplex Chat Simulation

```javascript
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const wsMessages = new Counter('ws_messages_sent');
const wsLatency = new Trend('ws_roundtrip', true);

export const options = {
  scenarios: {
    websocket: {
      executor: 'ramping-vus',
      stages: [
        { duration: '1m', target: 50 },
        { duration: '3m', target: 50 },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    ws_roundtrip: ['p(95)<500'],
  },
};

export default function () {
  const url = `wss://ws.example.com/chat?userId=vu-${__VU}`;
  const params = { headers: { Authorization: 'Bearer token123' } };

  const res = ws.connect(url, params, function (socket) {
    let msgCount = 0;
    const maxMessages = 10;

    socket.on('open', () => {
      console.log(`VU ${__VU} connected`);
      // Join a room
      socket.send(JSON.stringify({ type: 'join', room: 'loadtest' }));
    });

    socket.on('message', (msg) => {
      const data = JSON.parse(msg);
      if (data.type === 'pong') {
        wsLatency.add(Date.now() - data.clientTimestamp);
      }
    });

    socket.on('error', (e) => {
      console.error(`WS error VU ${__VU}: ${e.error()}`);
    });

    // Send messages at intervals
    socket.setInterval(() => {
      if (msgCount >= maxMessages) {
        socket.close();
        return;
      }
      socket.send(JSON.stringify({
        type: 'ping',
        clientTimestamp: Date.now(),
        message: `Message ${msgCount} from VU ${__VU}`,
      }));
      wsMessages.add(1);
      msgCount++;
    }, 1000);

    // Timeout safety
    socket.setTimeout(() => {
      socket.close();
    }, 30000);
  });

  check(res, { 'ws connected': (r) => r && r.status === 101 });
  sleep(1);
}
```

---

## Distributed Testing

### k6-operator on Kubernetes

Create a `TestRun` custom resource:

```yaml
# k6-testrun.yaml
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: load-test
spec:
  parallelism: 4          # 4 k6 runner pods
  script:
    configMap:
      name: k6-test-script
      file: script.js
  arguments: --out influxdb=http://influxdb:8086/k6
  runner:
    resources:
      limits:
        cpu: "1"
        memory: "1Gi"
      requests:
        cpu: "500m"
        memory: "512Mi"
    env:
      - name: BASE_URL
        value: "https://staging.example.com"
```

```bash
# Create ConfigMap from test script
kubectl create configmap k6-test-script --from-file=script.js

# Apply the TestRun
kubectl apply -f k6-testrun.yaml

# Monitor pods
kubectl get pods -l app=k6 -w

# Check logs
kubectl logs -l app=k6 --tail=50 -f

# Delete when done
kubectl delete testrun load-test
```

### Private Load Zone Configuration

```yaml
# For scripts requiring access to internal services
spec:
  runner:
    serviceAccountName: k6-runner
    nodeSelector:
      pool: loadtest
    tolerations:
      - key: "dedicated"
        operator: "Equal"
        value: "loadtest"
        effect: "NoSchedule"
```

### Multi-Region Distributed Test (Docker Compose)

```bash
# Run from multiple machines simultaneously
# Machine 1 (US-East):
K6_INFLUXDB_ADDR=http://central-influxdb:8086/k6 \
  k6 run --tag region=us-east --out influxdb script.js

# Machine 2 (EU-West):
K6_INFLUXDB_ADDR=http://central-influxdb:8086/k6 \
  k6 run --tag region=eu-west --out influxdb script.js

# Aggregate results in Grafana by filtering on region tag
```
