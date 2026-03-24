---
name: load-testing
description: >
  Guide for designing, writing, and running load tests using k6 (primary), Locust, Artillery, and JMeter.
  Covers test types (smoke, load, stress, soak, spike, breakpoint), metrics (throughput, latency percentiles
  p50/p95/p99, error rates, saturation), scenarios, thresholds, CI/CD integration, distributed testing,
  API/database load testing, reporting with Grafana/InfluxDB, and common pitfalls like coordinated omission.
  Trigger when user asks to load test, stress test, benchmark, performance test, measure throughput or latency,
  set up k6/Locust/Artillery/JMeter, or create performance test scripts.
  Do NOT trigger for unit tests, integration tests, end-to-end functional tests, security penetration testing,
  static analysis, code coverage, or monitoring/alerting setup without a load generation component.
---

# Load Testing

## Core Concepts

**Throughput**: Requests per second (RPS) the system handles. Measure at steady state, not during ramp.
**Latency percentiles**: p50 (median), p95 (tail), p99 (worst-case user experience). Never rely on averages — they hide tail latency. A system with 50ms avg can have 2s p99.
**Saturation**: Resource utilization approaching limits (CPU, memory, DB connections, network). Once saturated, latency spikes non-linearly.
**Error rate**: Percentage of failed requests. Track separately by status code (5xx vs 4xx vs timeouts).
**Concurrent users (VUs)**: Number of simultaneous virtual users generating load. Distinct from RPS — a VU with 100ms response time generates 10 RPS.

## Test Types

| Type | Purpose | VU Pattern | Duration |
|------|---------|------------|----------|
| **Smoke** | Verify script works, baseline metrics | 1-5 VUs | 1-2 min |
| **Load** | Validate expected production load | Ramp to target | 10-30 min |
| **Stress** | Find breaking point | Ramp beyond capacity | 10-30 min |
| **Soak** | Detect memory leaks, connection exhaustion | Steady moderate load | 1-4 hours |
| **Spike** | Test sudden traffic bursts | Instant jump to peak | 5-10 min |
| **Breakpoint** | Find maximum capacity | Continuous ramp until failure | Until break |

## k6 (Primary Tool)

### Basic Test Script

```javascript
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const loginDuration = new Trend('login_duration');

export const options = {
  stages: [
    { duration: '2m', target: 50 },
    { duration: '5m', target: 50 },
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1500'],
    http_req_failed: ['rate<0.01'],
    errors: ['rate<0.05'],
    checks: ['rate>0.99'],
  },
};

export function setup() {
  const res = http.post(`${__ENV.BASE_URL}/auth/token`, JSON.stringify({
    username: 'loadtest', password: __ENV.LOAD_TEST_PASSWORD,
  }), { headers: { 'Content-Type': 'application/json' } });
  return { token: res.json('access_token') };
}

export default function (data) {
  const params = { headers: { Authorization: `Bearer ${data.token}` } };

  group('Browse Products', () => {
    const res = http.get(`${__ENV.BASE_URL}/api/products`, params);
    check(res, {
      'status is 200': (r) => r.status === 200,
      'has products': (r) => r.json('data').length > 0,
      'response < 500ms': (r) => r.timings.duration < 500,
    });
    errorRate.add(res.status !== 200);
  });

  group('Get Product Detail', () => {
    const id = Math.floor(Math.random() * 100) + 1;
    const res = http.get(`${__ENV.BASE_URL}/api/products/${id}`, params);
    check(res, { 'detail 200': (r) => r.status === 200 });
  });

  sleep(Math.random() * 3 + 1); // realistic think time 1-4s
}

export function teardown(data) {
  console.log('Test completed. Review results in Grafana.');
}
```

### Scenarios and Executors

```javascript
export const options = {
  scenarios: {
    // Simulate browsing users ramping up
    browse: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 100 },
        { duration: '5m', target: 100 },
        { duration: '2m', target: 0 },
      ],
      exec: 'browseFlow',
    },
    // Maintain constant API throughput
    api_load: {
      executor: 'constant-arrival-rate',
      rate: 200,           // 200 iterations per timeUnit
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 50,
      maxVUs: 200,
      exec: 'apiFlow',
    },
    // Distribute fixed iterations across VUs
    batch_job: {
      executor: 'shared-iterations',
      vus: 10,
      iterations: 1000,
      maxDuration: '10m',
      exec: 'batchFlow',
    },
  },
};

export function browseFlow() { /* browsing logic */ }
export function apiFlow() { /* API call logic */ }
export function batchFlow() { /* batch processing logic */ }
```

**Executor selection guide:**
- `ramping-vus` — simulate user ramp-up/ramp-down; use for load and stress tests
- `constant-arrival-rate` — maintain fixed RPS regardless of response time; use for SLO validation (avoids coordinated omission)
- `ramping-arrival-rate` — ramp RPS over time; use for breakpoint tests
- `shared-iterations` — divide fixed work across VUs; use for batch/data processing tests
- `per-vu-iterations` — each VU runs N iterations; use for per-user workflow tests
- `constant-vus` — fixed VU count; use for soak tests

### Thresholds with abortOnFail

```javascript
thresholds: {
  http_req_duration: [
    { threshold: 'p(95)<500', abortOnFail: true, delayAbortEval: '30s' },
    'p(99)<1500',
  ],
  http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true }],
  'http_req_duration{group:::Login}': ['p(95)<300'],  // per-group threshold
},
```

### Data Parameterization

```javascript
import papaparse from 'https://jslib.k6.io/papaparse/5.1.1/index.js';
import { SharedArray } from 'k6/data';

const users = new SharedArray('users', function () {
  return papaparse.parse(open('./users.csv'), { header: true }).data;
});

export default function () {
  const user = users[__VU % users.length];
  http.post(`${__ENV.BASE_URL}/login`, JSON.stringify({
    email: user.email, password: user.password,
  }));
}
```

### k6 Extensions

- **xk6-browser**: Real browser testing with Chromium for Core Web Vitals under load
- **xk6-dashboard**: Real-time HTML dashboard during test execution (`k6 run --out dashboard script.js`)
- **xk6-output-influxdb**: Stream metrics to InfluxDB for Grafana dashboards
- **xk6-kafka/xk6-sql**: Test Kafka producers/consumers and databases directly
- Build custom extensions: `xk6 build --with github.com/grafana/xk6-dashboard@latest`

### CI/CD: k6 in GitHub Actions

```yaml
name: Load Test
on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 2 * * 1-5'  # nightly on weekdays

jobs:
  load-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: grafana/k6-action@v0.3.1
        with:
          filename: tests/load/api-load.js
          flags: >-
            --env BASE_URL=${{ secrets.STAGING_URL }}
            --env LOAD_TEST_PASSWORD=${{ secrets.LOAD_TEST_PASSWORD }}
            --out json=results.json
      - name: Upload results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: k6-results
          path: results.json
```

Thresholds cause non-zero exit codes on failure — the CI job fails automatically.

### Output to Grafana + InfluxDB

```bash
# Run with InfluxDB output
k6 run --out influxdb=http://localhost:8086/k6 script.js

# Run with multiple outputs
k6 run --out json=results.json --out influxdb=http://localhost:8086/k6 script.js

# Use Grafana k6 dashboard (ID: 2587) for pre-built visualizations
```

## Locust (Python-Based)

```python
from locust import HttpUser, task, between, LoadTestShape

class APIUser(HttpUser):
    wait_time = between(1, 3)
    host = "https://api.example.com"

    def on_start(self):
        resp = self.client.post("/auth/login", json={"username": "loadtest", "password": "secret"})
        self.token = resp.json()["token"]
        self.headers = {"Authorization": f"Bearer {self.token}"}

    @task(3)
    def list_items(self):
        with self.client.get("/api/items", headers=self.headers, catch_response=True) as resp:
            if resp.status_code != 200:
                resp.failure(f"Got {resp.status_code}")
            elif resp.elapsed.total_seconds() > 0.5:
                resp.failure("Too slow")

    @task(1)
    def create_item(self):
        self.client.post("/api/items", headers=self.headers,
                         json={"name": f"item-{self.environment.runner.user_count}"})

class StepLoadShape(LoadTestShape):
    """Step load: add 10 users every 30s up to 100."""
    stages = [(30*i, 10*i, 10) for i in range(1, 11)]
    def tick(self):
        run_time = self.get_run_time()
        for duration, users, spawn_rate in self.stages:
            if run_time < duration:
                return (users, spawn_rate)
        return None
```

```bash
locust -f locustfile.py --headless -u 500 -r 50 -t 5m --csv=results  # single machine
locust -f locustfile.py --master --expect-workers=4                   # distributed master
locust -f locustfile.py --worker --master-host=192.168.1.100          # distributed worker
locust -f locustfile.py                                               # web UI at :8089
```

**Strengths**: Full Python flexibility, distributed mode, custom load shapes, web UI.
**Use when**: Python teams, complex custom behaviors, non-HTTP protocols.

## Artillery

```yaml
# artillery-config.yml
config:
  target: "https://api.example.com"
  phases:
    - duration: 60
      arrivalRate: 5
      name: "Warm up"
    - duration: 300
      arrivalRate: 50
      name: "Sustained load"
    - duration: 60
      arrivalRate: 100
      name: "Peak"
  defaults:
    headers:
      Content-Type: "application/json"
  plugins:
    expect: {}
  ensure:
    thresholds:
      - http.response_time.p95: 500
      - http.response_time.p99: 1500

scenarios:
  - name: "User journey"
    flow:
      - post:
          url: "/auth/login"
          json:
            username: "testuser"
            password: "{{ $env.TEST_PASSWORD }}"
          capture:
            - json: "$.token"
              as: "authToken"
      - get:
          url: "/api/products"
          headers:
            Authorization: "Bearer {{ authToken }}"
          expect:
            - statusCode: 200
            - hasProperty: "data"
      - think: 2
      - get:
          url: "/api/products/{{ $randomNumber(1, 100) }}"
          headers:
            Authorization: "Bearer {{ authToken }}"
```

```bash
artillery run artillery-config.yml
artillery run --output report.json artillery-config.yml && artillery report report.json
```

**Strengths**: YAML simplicity, built-in expectations, HTML reports.
**Use when**: Quick API testing, Node.js teams, simple scenario definitions.

## JMeter (Brief Comparison)

Use JMeter when: legacy enterprise requirements, need GUI test builder, JDBC/JMS/FTP testing, or existing JMeter infrastructure. Prefer k6/Locust/Artillery for new projects — they are faster, more CI-friendly, and developer-centric.

```bash
# CLI mode for CI/CD
jmeter -n -t test-plan.jmx -l results.jtl -e -o report/
```

## API Protocol Testing

### REST Load Test (k6)
Use the basic k6 script pattern above. Add `http.batch()` for parallel requests within a VU.

### GraphQL (k6)

```javascript
const query = `query GetUser($id: ID!) { user(id: $id) { name email orders { id } } }`;

export default function () {
  const res = http.post(`${__ENV.BASE_URL}/graphql`, JSON.stringify({
    query,
    variables: { id: String(Math.floor(Math.random() * 1000) + 1) },
  }), { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` } });
  check(res, {
    'no errors': (r) => !r.json('errors'),
    'has user': (r) => r.json('data.user') !== null,
  });
}
```

### gRPC (k6)

```javascript
import grpc from 'k6/net/grpc';

const client = new grpc.Client();
client.load(['proto'], 'service.proto');

export default function () {
  client.connect('localhost:50051', { plaintext: true });
  const resp = client.invoke('api.UserService/GetUser', { id: '123' });
  check(resp, {
    'status OK': (r) => r.status === grpc.StatusOK,
  });
  client.close();
}
```

### WebSocket (k6)

```javascript
import ws from 'k6/ws';
export default function () {
  const res = ws.connect(`${__ENV.WS_URL}/ws`, {}, function (socket) {
    socket.on('open', () => socket.send(JSON.stringify({ type: 'subscribe', channel: 'prices' })));
    socket.on('message', (msg) => check(JSON.parse(msg), { 'has price': (d) => d.price !== undefined }));
    socket.setTimeout(() => socket.close(), 10000);
  });
  check(res, { 'ws status 101': (r) => r && r.status === 101 });
}
```

## Database Load Testing

```javascript
// k6 with xk6-sql extension
import sql from 'k6/x/sql';
const db = sql.open('postgres', 'postgres://user:pass@localhost:5432/testdb');

export function setup() {
  sql.exec(db, `CREATE TABLE IF NOT EXISTS load_test (id SERIAL, data TEXT, created_at TIMESTAMP DEFAULT NOW())`);
}
export default function () {
  sql.exec(db, `INSERT INTO load_test (data) VALUES ('vu-${__VU}-iter-${__ITER}')`);
  const results = sql.query(db, `SELECT * FROM load_test ORDER BY created_at DESC LIMIT 10`);
  check(results, { 'got rows': (r) => r.length > 0 });
}
export function teardown() {
  sql.exec(db, `DROP TABLE IF EXISTS load_test`);
  db.close();
}
```

**Connection pool testing**: Gradually increase VUs to find the point where connection pool exhaustion causes errors. Monitor `pg_stat_activity` or equivalent.

## Distributed Testing

**k6 Cloud**: `k6 cloud script.js` uploads and runs distributed. `k6 cloud --out cloud script.js` for hybrid local execution with cloud streaming.

**k6 on Kubernetes** — use k6-operator:
```yaml
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: api-load-test
spec:
  parallelism: 4
  script:
    configMap:
      name: k6-test-script
      file: script.js
  arguments: --out influxdb=http://influxdb:8086/k6
```

Use the k6-operator for Kubernetes-native distributed execution.

**Locust distributed**: Run `locust -f locustfile.py --master --expect-workers=8` on master, `locust -f locustfile.py --worker --master-host=<MASTER_IP>` on each worker.

## Reporting

**Grafana + InfluxDB**: Run `k6 run --out influxdb=http://influxdb:8086/k6`, import Grafana dashboard ID 2587. Real-time RPS, latency percentiles, error rates, VU count.
**k6 Cloud**: Automatic dashboards, trend analysis, run comparison, shareable URLs.
**HTML Reports**: k6 → `--out json=results.json` + k6-reporter; Artillery → `artillery report report.json --output report.html`; Locust → `--csv=results` output.

### Common Patterns

**Realistic user simulation**: Add `sleep()` between requests (1-5s randomized think time). Weight tasks by real traffic ratios (80% reads, 15% writes, 5% search). Use unique test data per VU to avoid cache hits. Model user journeys, not isolated endpoints.
**Data parameterization**: Use `SharedArray` in k6 for memory-efficient CSV/JSON sharing. Rotate through users/data with `__VU` and `__ITER` counters. Generate dynamic data for writes to avoid duplicate key conflicts.
**Correlation**: Capture tokens, IDs, CSRF tokens from responses for subsequent requests. Use k6 `check()` + response parsing, Locust `catch_response`, or Artillery `capture`.

## Common Gotchas

1. **Coordinated omission**: Closed-loop tools wait for responses before sending next request, hiding latency spikes. Use `constant-arrival-rate` executor in k6 for open-loop testing.
2. **Client-side bottlenecks**: Load generator CPU/memory/network can saturate before the target. Monitor the load gen machine. Distribute across multiple machines if needed.
3. **Network limits**: Hitting bandwidth caps, connection limits, or NAT table exhaustion. Increase `ulimit -n`, tune `net.ipv4.ip_local_port_range`, use multiple source IPs.
4. **Ignoring error rates**: System may shed load by returning 503s — throughput looks fine but users are failing. Always set error rate thresholds.
5. **Testing with caching warm**: Production caches may be cold on deploy. Test both warm and cold cache scenarios.
6. **DNS caching**: k6 caches DNS by default. Set `dns: { ttl: '0', policy: 'roundRobin' }` to test load balancer distribution.
7. **Insufficient test duration**: Memory leaks and connection exhaustion only appear under sustained load. Run soak tests for 1-4 hours.
8. **Averages instead of percentiles**: A 50ms average can hide a 5s p99. Always report p50, p95, p99.
9. **Missing baseline**: Run smoke tests first to establish baseline metrics before load tests.
10. **Single-endpoint testing**: Real traffic hits many endpoints. Use scenarios with weighted tasks.

## Examples

### User prompt → expected action

**Input**: "Set up a load test for our REST API that validates we can handle 500 RPS with p95 < 200ms"
**Output**: Write a k6 script using `constant-arrival-rate` executor with `rate: 500`, threshold `http_req_duration: ['p(95)<200']`, `http_req_failed: ['rate<0.01']`, with proper auth setup, checks, and think time.

**Input**: "Our app crashes under sudden traffic spikes, help me reproduce this"
**Output**: Write a k6 spike test with `ramping-vus` executor: ramp to 50 VUs in 1m, hold 2m, spike to 500 VUs in 10s, hold 2m, ramp down. Add thresholds for error rate and p99 latency. Include `abortOnFail: false` to capture full failure behavior.

**Input**: "Add load testing to our CI pipeline"
**Output**: Create GitHub Actions workflow using `grafana/k6-action`, run smoke test on every PR (low VUs, short duration), full load test nightly via cron. Upload results as artifacts. Thresholds auto-fail the pipeline on regression.

**Input**: "We need to test our GraphQL API under load"
**Output**: Write k6 script with `http.post()` to GraphQL endpoint, parameterize queries with realistic variables, check for `errors` field in response, set thresholds on response time. Use `group()` to separate query types in metrics.

**Input**: "Help me find our database bottleneck under concurrent load"
**Output**: Write k6 test with xk6-sql extension targeting the database directly. Ramp VUs from 1 to 100, monitor query latency and error rate. Separately, test the API layer to compare — delta reveals ORM/connection pool overhead. Advise monitoring `pg_stat_activity` or connection pool metrics during test.

**Input**: "Set up Locust for our Python team to load test"
**Output**: Write `locustfile.py` with `HttpUser` class, `@task`-decorated methods with appropriate weights, `on_start` for auth, `catch_response=True` for custom validation. Include `LoadTestShape` for custom ramp pattern. Provide CLI commands for headless and distributed modes.
