# k6 Troubleshooting Reference

## Table of Contents
- [Script Compilation Errors](#script-compilation-errors)
- [Import Issues](#import-issues)
- [Certificate / TLS Errors](#certificate--tls-errors)
- [Performance Bottlenecks](#performance-bottlenecks)
- [Memory Issues](#memory-issues)
- [Result Interpretation Pitfalls](#result-interpretation-pitfalls)
- [Flaky Thresholds](#flaky-thresholds)
- [CI Timeout Issues](#ci-timeout-issues)
- [Output Backend Configuration](#output-backend-configuration)
- [Debugging with --http-debug](#debugging-with---http-debug)
- [Common Error Messages Reference](#common-error-messages-reference)

---

## Script Compilation Errors

### "SyntaxError: unexpected token"

k6 uses ES6 modules, **not CommonJS**.

```javascript
// ❌ WRONG — CommonJS
const http = require('k6/http');
module.exports = function () {};

// ✅ CORRECT — ES6 modules
import http from 'k6/http';
export default function () {}
```

### "default is not defined" / Missing Default Export

Every k6 script needs a default exported function:

```javascript
// ❌ Missing default export
export function myTest() { /* ... */ }

// ✅ Correct
export default function () { /* ... */ }

// ✅ Also correct with named scenarios
export const options = {
  scenarios: { s1: { executor: 'constant-vus', exec: 'myTest', vus: 1, duration: '1m' } },
};
export function myTest() { /* ... */ }
// Note: default export can be empty or omitted ONLY if every scenario has exec:
export default function () {}
```

### "GoError: cannot use open() in the VU context"

`open()` can only be called during init (top-level scope), not inside the default function:

```javascript
// ❌ WRONG — open() inside VU function
export default function () {
  const data = open('./data.json');  // GoError!
}

// ✅ CORRECT — open() at init time
const rawData = open('./data.json');
const data = JSON.parse(rawData);
export default function () {
  console.log(data[0]);
}
```

### "TypeError: ... is not a function"

Usually caused by wrong import path or non-existent module method:

```javascript
// ❌ Wrong module path
import { sleep } from 'k6/http';  // sleep is in 'k6', not 'k6/http'

// ✅ Correct
import { check, sleep } from 'k6';
import http from 'k6/http';
```

---

## Import Issues

### Relative Path Resolution

k6 resolves paths relative to the **script file location**, not CWD:

```
project/
├── tests/
│   └── load.js          ← entry script
├── helpers/
│   └── utils.js
└── testdata/
    └── users.json
```

```javascript
// In tests/load.js:
import { helper } from '../helpers/utils.js';  // ✅ relative to tests/
const users = JSON.parse(open('../testdata/users.json'));  // ✅
```

### Remote Module Import Failures

```javascript
// ❌ May fail if GitHub serves HTML instead of raw JS
import papa from 'https://github.com/user/repo/blob/main/lib.js';

// ✅ Use raw URLs or jslib
import papa from 'https://jslib.k6.io/papaparse/5.1.1/index.js';

// ✅ Pin specific versions to avoid breakage
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';
```

### "Module not found" in Docker

Mount scripts and all dependencies:

```bash
# ❌ Only mounts the script, not helpers/testdata
docker run --rm -v $(pwd)/test.js:/test.js grafana/k6 run /test.js

# ✅ Mount entire project directory
docker run --rm -v $(pwd):/scripts grafana/k6 run /scripts/tests/load.js
```

---

## Certificate / TLS Errors

### Skip TLS Verification (Testing Only)

```javascript
export const options = {
  insecureSkipTLSVerify: true,  // Disables cert validation globally
};
```

### Custom CA Certificate

```javascript
export const options = {
  tlsAuth: [{
    cert: open('./certs/client.pem'),
    key: open('./certs/client-key.pem'),
  }],
};
// Or via environment variable:
// K6_INSECURE_SKIP_TLS_VERIFY=true k6 run script.js
```

### Force TLS Version

```javascript
export const options = {
  tlsVersion: {
    min: 'tls1.2',
    max: 'tls1.3',
  },
};
```

### "x509: certificate signed by unknown authority"

- Add your CA to the system trust store, or
- Use `insecureSkipTLSVerify: true` for internal/dev environments
- Mount CA certs into Docker: `-v /path/to/ca.pem:/etc/ssl/certs/ca.pem`

---

## Performance Bottlenecks

### Too Many VUs — Load Generator Saturation

**Symptoms:** Increasing VUs doesn't increase RPS; CPU at 100%; "dropped iterations" warnings.

**Diagnosis:**
```bash
# Monitor k6 process resources during test
k6 run --summary-trend-stats="avg,min,med,max,p(90),p(95),p(99)" script.js

# Watch system resources
top -p $(pgrep k6)
vmstat 1
```

**Solutions:**
1. **Reduce per-VU work:** Remove unnecessary `console.log()` in hot paths
2. **Use arrival-rate executors:** They'll warn about insufficient VUs
3. **Distribute load:** Use multiple k6 instances or k6-operator
4. **Optimize checks:** Complex JSON parsing in checks is expensive at scale

### High "http_req_blocked" Times

Blocked time = waiting for a TCP connection slot. Indicates connection pool exhaustion.

```javascript
// Increase max connections per host (default: unlimited but OS-constrained)
export const options = {
  batch: 20,              // max parallel requests in http.batch()
  batchPerHost: 6,        // max parallel requests per host in batch
  noConnectionReuse: false, // keep-alive (default)
};
```

### "dropped iterations" Warning

Means arrival-rate executor couldn't start iterations fast enough.

```
WARN  dropped 150 iterations during scenario "load"
```

**Fix:** Increase `preAllocatedVUs` or `maxVUs`:
```javascript
export const options = {
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: 100,
      preAllocatedVUs: 200,  // increase from 50
      maxVUs: 500,           // increase from 200
    },
  },
};
```

---

## Memory Issues

### Symptoms

- k6 process killed by OOM killer
- "runtime: out of memory" panic
- Gradual memory growth during soak tests

### SharedArray for Large Datasets

```javascript
// ❌ Each VU gets its own copy — 100 VUs × 50MB = 5GB
const data = JSON.parse(open('./large-dataset.json'));

// ✅ Shared across all VUs — one copy in memory
import { SharedArray } from 'k6/data';
const data = new SharedArray('dataset', () => JSON.parse(open('./large-dataset.json')));
```

### Avoid Accumulating Data in VU Context

```javascript
// ❌ Memory leak — array grows every iteration
let results = [];
export default function () {
  const res = http.get('https://api.example.com/data');
  results.push(res.body);  // Never freed!
}

// ✅ Process and discard within iteration
export default function () {
  const res = http.get('https://api.example.com/data');
  check(res, { 'ok': (r) => r.status === 200 });
  // Don't store response bodies
}
```

### Reduce Logging in Hot Paths

```javascript
// ❌ Console output is expensive at scale
export default function () {
  const res = http.get('https://api.example.com/data');
  console.log(`Response: ${res.status} ${res.body}`);  // Slow!
}

// ✅ Log only on errors, sparingly
export default function () {
  const res = http.get('https://api.example.com/data');
  if (res.status !== 200) {
    console.warn(`Unexpected status: ${res.status}`);
  }
}
```

### Discard Response Bodies

```javascript
export const options = {
  discardResponseBodies: true,  // Global: don't store bodies
};

// Override per-request when needed
export default function () {
  const res = http.get('https://api.example.com/data', {
    responseType: 'text',  // or 'binary', 'none'
  });
}
```

---

## Result Interpretation Pitfalls

### Coordinated Omission

If your test uses `sleep()` with closed-model executors (`constant-vus`), slow responses reduce effective RPS but don't queue up — masking real latency under load.

**Fix:** Use open-model executors (`constant-arrival-rate`) for throughput-oriented tests. They maintain target RPS regardless of response time.

### Misleading Averages

- **Average latency** hides tail latency spikes. Always look at **p95 and p99**.
- A p95 of 200ms with p99 of 5000ms means 1 in 100 requests is 25x slower.

### http_req_duration Components

```
http_req_duration = http_req_sending + http_req_waiting + http_req_receiving

Full timeline:
http_req_blocked → http_req_connecting → http_req_tls_handshaking →
http_req_sending → http_req_waiting (TTFB) → http_req_receiving
```

If `http_req_blocked` is high → connection pool issue (client-side).
If `http_req_waiting` is high → server processing is slow.
If `http_req_connecting` is high → network latency or DNS.

### Warm-Up Bias

The first few seconds include TCP/TLS setup overhead. Exclude warm-up:

```javascript
export const options = {
  scenarios: {
    warmup: {
      executor: 'constant-vus', vus: 5, duration: '30s',
      tags: { phase: 'warmup' },
    },
    main: {
      executor: 'constant-vus', vus: 50, duration: '5m',
      startTime: '30s',
      tags: { phase: 'main' },
    },
  },
  thresholds: {
    // Only threshold the main phase
    'http_req_duration{phase:main}': ['p(95)<500'],
  },
};
```

---

## Flaky Thresholds

### Common Causes

1. **Too few samples** — Short tests or low VU counts produce unreliable percentiles
2. **Environment noise** — Shared CI runners, network jitter, cold starts
3. **Threshold on wrong metric** — Using `avg` instead of `p(95)` or vice versa

### Stabilization Strategies

```javascript
export const options = {
  thresholds: {
    // ❌ Flaky — avg is sensitive to outliers
    http_req_duration: ['avg<200'],

    // ✅ More stable — p(95) tolerates some outliers
    http_req_duration: ['p(95)<500'],

    // ✅ Use abortOnFail with delay to avoid false positives
    http_req_failed: [{
      threshold: 'rate<0.05',
      abortOnFail: true,
      delayAbortEval: '30s',  // Wait 30s before evaluating
    }],
  },
};
```

### Minimum Sample Size

Don't apply tight thresholds on tests with < 100 iterations. Use longer durations or higher VU counts for statistical significance.

---

## CI Timeout Issues

### GitHub Actions Timeout

```yaml
jobs:
  load-test:
    runs-on: ubuntu-latest
    timeout-minutes: 30      # Default is 6h but explicitly set
    steps:
      - uses: actions/checkout@v4
      - uses: grafana/setup-k6-action@v1
      - run: k6 run --duration 10m tests/load.js
        timeout-minutes: 15   # Step-level timeout
```

### Fast-Fail Patterns

```javascript
export const options = {
  thresholds: {
    http_req_failed: [{
      threshold: 'rate<0.1',
      abortOnFail: true,
      delayAbortEval: '10s',
    }],
    http_req_duration: [{
      threshold: 'p(95)<2000',
      abortOnFail: true,
      delayAbortEval: '30s',
    }],
  },
};
```

### Resource-Constrained CI Runners

CI runners typically have 2 CPU cores and 7GB RAM. Limit test scale:

```javascript
// Scale based on environment
const isCI = __ENV.CI === 'true';
export const options = {
  scenarios: {
    load: {
      executor: 'constant-vus',
      vus: isCI ? 20 : 100,
      duration: isCI ? '2m' : '10m',
    },
  },
};
```

---

## Output Backend Configuration

### InfluxDB Connection Issues

```bash
# Test InfluxDB connectivity first
curl -i http://localhost:8086/ping

# Common errors:
# "connection refused" → InfluxDB not running or wrong port
# "database not found" → create the database first
influx -execute 'CREATE DATABASE k6'

# k6 InfluxDB v1
k6 run --out influxdb=http://localhost:8086/k6 script.js

# k6 InfluxDB v2 (uses environment variables)
K6_INFLUXDB_ORGANIZATION=myorg \
K6_INFLUXDB_BUCKET=k6 \
K6_INFLUXDB_TOKEN=mytoken \
  k6 run --out experimental-influxdb script.js
```

### Prometheus Remote Write

```bash
K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true \
  k6 run --out experimental-prometheus-rw script.js

# If Prometheus rejects writes:
# - Check remote_write is enabled in prometheus.yml
# - Verify CORS/auth headers
# - Check for "out of order samples" — Prometheus needs --enable-feature=native-histograms
```

### JSON/CSV Output Size

Large tests produce huge JSON files. Filter or sample:

```bash
# Pipe to jq for filtering
k6 run --out json=- script.js | jq 'select(.type=="Point" and .metric=="http_req_duration")' > filtered.json

# Compress output
k6 run --out json=results.json script.js && gzip results.json
```

---

## Debugging with --http-debug

### Basic HTTP Debugging

```bash
# Show request/response headers
k6 run --http-debug script.js

# Show headers AND bodies
k6 run --http-debug=full script.js

# Combine with reduced VUs for readability
k6 run --http-debug=full --vus 1 --iterations 1 script.js
```

### Verbose Logging

```bash
# Set log level
k6 run --verbose script.js

# Log with specific level
k6 run --log-output=stderr --log-format=json script.js
```

### In-Script Debug Logging

```javascript
import http from 'k6/http';

export default function () {
  const res = http.get('https://api.example.com/data');

  // Debug response details
  console.log(`Status: ${res.status}`);
  console.log(`Headers: ${JSON.stringify(res.headers)}`);
  console.log(`Body (first 200 chars): ${res.body.substring(0, 200)}`);
  console.log(`Timings: ${JSON.stringify(res.timings)}`);

  // Check cookies
  const jar = http.cookieJar();
  const cookies = jar.cookiesForURL(res.url);
  console.log(`Cookies: ${JSON.stringify(cookies)}`);
}
```

---

## Common Error Messages Reference

| Error | Cause | Fix |
|-------|-------|-----|
| `GoError: cannot use open() in VU context` | `open()` called inside default function | Move to init scope |
| `SyntaxError: unexpected token` | CommonJS syntax or ES6+ unsupported feature | Use ES6 imports, check syntax |
| `ERRO[0000] TypeError: Cannot read property of undefined` | Accessing property on null response | Add null checks before `.json()` |
| `WARN dropped N iterations` | Not enough VUs for arrival-rate | Increase `preAllocatedVUs`/`maxVUs` |
| `request timeout` | Server didn't respond in time | Increase `timeout` in request params |
| `dial tcp: lookup ... no such host` | DNS resolution failed | Check URL, network, Docker DNS |
| `x509: certificate signed by unknown authority` | Self-signed or unknown CA cert | Use `insecureSkipTLSVerify` or add CA |
| `ERRO context canceled` | Test aborted or VU interrupted | Check gracefulStop, timeouts |
| `runtime: out of memory` | VU data accumulation or huge dataset | Use SharedArray, discard bodies |
| Exit code `99` | Thresholds breached | Check threshold definitions vs results |
| Exit code `107` | GoError during init | Check open() paths, module imports |
| Exit code `108` | GoError during setup | Check setup() HTTP calls, auth |
