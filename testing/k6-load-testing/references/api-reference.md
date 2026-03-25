# k6 API Reference

## Table of Contents
- [HTTP Module (k6/http)](#http-module-k6http)
- [Core Functions (k6)](#core-functions-k6)
- [Custom Metrics (k6/metrics)](#custom-metrics-k6metrics)
- [Options Object](#options-object)
- [Scenarios and Executors](#scenarios-and-executors)
- [Lifecycle Functions](#lifecycle-functions)
- [SharedArray (k6/data)](#sharedarray-k6data)
- [open() Function](#open-function)
- [Encoding (k6/encoding)](#encoding-k6encoding)
- [Crypto (k6/crypto)](#crypto-k6crypto)
- [Execution Context (k6/execution)](#execution-context-k6execution)
- [Browser Module (k6/browser)](#browser-module-k6browser)
- [HTML Parsing (k6/html)](#html-parsing-k6html)
- [WebSocket (k6/ws)](#websocket-k6ws)
- [gRPC (k6/net/grpc)](#grpc-k6netgrpc)
- [Built-in Metrics](#built-in-metrics)
- [Environment and Globals](#environment-and-globals)

---

## HTTP Module (k6/http)

```javascript
import http from 'k6/http';
```

### Request Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `http.get` | `get(url, [params])` | HTTP GET |
| `http.post` | `post(url, [body], [params])` | HTTP POST |
| `http.put` | `put(url, [body], [params])` | HTTP PUT |
| `http.patch` | `patch(url, [body], [params])` | HTTP PATCH |
| `http.del` | `del(url, [body], [params])` | HTTP DELETE |
| `http.head` | `head(url, [params])` | HTTP HEAD |
| `http.options` | `options(url, [body], [params])` | HTTP OPTIONS |
| `http.request` | `request(method, url, [body], [params])` | Any method |
| `http.asyncRequest` | `asyncRequest(method, url, [body], [params])` | Async (returns Promise) |
| `http.batch` | `batch(requests)` | Parallel requests |

### Params Object

```javascript
{
  headers: { 'Content-Type': 'application/json' },
  tags: { name: 'MyRequest' },           // custom metric tags
  timeout: '30s',                          // request timeout
  redirects: 5,                            // max redirects (0 = none)
  responseType: 'text',                    // 'text' | 'binary' | 'none'
  responseCallback: http.expectedStatuses(200, 201), // auto-check
  auth: 'basic',                           // 'basic' | 'digest' | 'ntlm'
  compression: 'gzip',                     // request body compression
  jar: http.cookieJar(),                   // cookie jar
}
```

### Response Object

```javascript
const res = http.get(url);
res.status;                  // number: HTTP status code
res.status_text;             // string: "200 OK"
res.body;                    // string: response body
res.headers;                 // object: response headers
res.timings;                 // object: timing breakdown
res.timings.duration;        // number: total request time (ms)
res.timings.blocked;         // number: time blocked
res.timings.connecting;      // number: TCP connecting time
res.timings.tls_handshaking; // number: TLS handshake time
res.timings.sending;         // number: data sending time
res.timings.waiting;         // number: TTFB
res.timings.receiving;       // number: data receiving time
res.url;                     // string: final URL (after redirects)
res.cookies;                 // object: response cookies
res.json([selector]);        // parse body as JSON, optional gjson selector
res.html([selector]);        // parse body as HTML Selection
res.submitForm([params]);    // submit an HTML form from response
res.clickLink([params]);     // follow a link from response
```

### Cookie Jar

```javascript
const jar = http.cookieJar();
jar.set(url, name, value, [options]);  // options: { domain, path, expires, secure, ... }
jar.cookiesForURL(url);                // returns cookies object
jar.clear(url);                        // clear cookies for URL
```

### http.file

```javascript
// Create file data for multipart uploads
const file = http.file(data, filename, contentType);
// data: string | ArrayBuffer (use open('path', 'b') for binary)
```

### http.expectedStatuses

```javascript
// Use as responseCallback for automatic status checking
const params = {
  responseCallback: http.expectedStatuses(200, 201, {min: 200, max: 299}),
};
```

---

## Core Functions (k6)

```javascript
import { check, group, sleep, fail, randomSeed } from 'k6';
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `check` | `check(val, sets, [tags])` | Boolean assertions; returns true if all pass |
| `group` | `group(name, fn)` | Groups requests/checks; nesting supported |
| `sleep` | `sleep(seconds)` | Pause VU for N seconds (fractional OK) |
| `fail` | `fail([msg])` | Abort current VU iteration immediately |
| `randomSeed` | `randomSeed(int)` | Seed Math.random() for reproducibility |

### check Details

```javascript
// Returns boolean — true if ALL checks pass
const passed = check(res, {
  'status is 200': (r) => r.status === 200,
  'body size > 0': (r) => r.body.length > 0,
  'has token': (r) => r.json('token') !== undefined,
}, { myTag: 'auth' });

// check does NOT abort on failure — use with conditional logic
if (!passed) {
  console.warn('Check failed');
  return; // skip rest of iteration
}
```

### group Details

```javascript
// Groups organize metrics in output. Return value is the function's return value.
const result = group('Login Flow', () => {
  const res = http.post(url, body);
  check(res, { 'login ok': (r) => r.status === 200 });
  return res.json('token');
});
```

---

## Custom Metrics (k6/metrics)

```javascript
import { Counter, Gauge, Rate, Trend } from 'k6/metrics';
```

| Type | Constructor | `.add()` | Aggregates | Use Case |
|------|-------------|----------|------------|----------|
| `Counter` | `Counter(name, isTime)` | `.add(value)` | count, rate | Total events (errors, orders) |
| `Gauge` | `Gauge(name, isTime)` | `.add(value)` | value, min, max | Current state (active users) |
| `Rate` | `Rate(name)` | `.add(boolean)` | rate | Success/failure ratios |
| `Trend` | `Trend(name, isTime)` | `.add(value, tags)` | avg, min, max, med, p(N) | Latencies, durations |

The `isTime` parameter (default `false`) indicates if values are milliseconds — affects display formatting.

```javascript
const myTrend = new Trend('api_latency', true);  // isTime=true → "ms" display
myTrend.add(150);
myTrend.add(230, { endpoint: '/users' });  // with tags
```

### Threshold Aggregators

| Aggregator | Applies To | Example |
|------------|-----------|---------|
| `avg` | Trend | `'avg<200'` |
| `min` | Trend | `'min>0'` |
| `max` | Trend | `'max<1000'` |
| `med` | Trend | `'med<150'` |
| `p(N)` | Trend | `'p(95)<500'` |
| `count` | Counter | `'count<100'` |
| `rate` | Rate, Counter | `'rate<0.01'` |
| `value` | Gauge | `'value>0'` |

---

## Options Object

```javascript
export const options = {
  // Execution
  vus: 10,                              // default VU count
  duration: '30s',                      // test duration
  iterations: 100,                      // total iterations (overrides duration)
  stages: [{ duration: '1m', target: 10 }], // ramping stages

  // Scenarios (overrides vus/duration/stages)
  scenarios: { /* see Scenarios section */ },

  // Thresholds
  thresholds: {
    metric_name: ['aggregator<value'],
    'metric{tag:val}': [{ threshold: 'p(95)<500', abortOnFail: true, delayAbortEval: '10s' }],
  },

  // HTTP
  batch: 20,                            // max parallel batch requests
  batchPerHost: 6,                      // max parallel per host
  httpDebug: 'full',                    // 'full' | '' (headers only)
  insecureSkipTLSVerify: false,         // skip TLS verification
  noConnectionReuse: false,             // disable keep-alive
  noVUConnectionReuse: false,           // per-VU connection reuse
  userAgent: 'k6/0.50.0 (https://k6.io/)',
  discardResponseBodies: false,         // don't store bodies
  blockHostnames: ['*.analytics.com'],  // block requests to hostnames

  // TLS
  tlsAuth: [{ cert: open('cert.pem'), key: open('key.pem'), domains: ['example.com'] }],
  tlsVersion: { min: 'tls1.2', max: 'tls1.3' },
  // Supported: 'tls1.0', 'tls1.1', 'tls1.2', 'tls1.3'

  // Tags
  tags: { testType: 'load' },          // global tags on all metrics
  systemTags: ['proto', 'status', 'method', 'url', 'name', 'group', 'check', 'error', 'tls_version', 'scenario', 'expected_response'],

  // DNS
  dns: {
    ttl: '5m',                          // DNS cache TTL
    select: 'roundRobin',              // 'first', 'random', 'roundRobin'
    policy: 'preferIPv4',              // 'preferIPv4', 'preferIPv6', 'onlyIPv4', 'onlyIPv6', 'any'
  },

  // Output
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  summaryTimeUnit: 'ms',               // 'us', 'ms', 's'
  noSummary: false,                     // suppress end-of-test summary

  // Execution control
  setupTimeout: '60s',                 // max time for setup()
  teardownTimeout: '60s',              // max time for teardown()
  gracefulStop: '30s',                 // grace period after duration
  gracefulRampDown: '30s',             // grace period during ramp-down

  // Cloud
  cloud: {
    projectID: 12345,
    name: 'My Test',
    distribution: { loadZoneUS: { loadZone: 'amazon:us:ashburn', percent: 60 },
                    loadZoneEU: { loadZone: 'amazon:ie:dublin', percent: 40 } },
  },
};
```

---

## Scenarios and Executors

### Common Fields (All Executors)

```javascript
{
  executor: 'constant-vus',           // required
  exec: 'myFunction',                 // function name (default: 'default')
  startTime: '30s',                   // delay before scenario starts
  gracefulStop: '30s',                // grace period after duration
  env: { KEY: 'value' },             // per-scenario env vars
  tags: { scenario: 'main' },        // per-scenario tags
}
```

### Executor Configurations

```javascript
// constant-vus
{ executor: 'constant-vus', vus: 10, duration: '5m' }

// ramping-vus
{
  executor: 'ramping-vus',
  startVUs: 0,
  stages: [{ duration: '2m', target: 100 }, { duration: '5m', target: 100 }, { duration: '2m', target: 0 }],
  gracefulRampDown: '30s',
}

// constant-arrival-rate
{
  executor: 'constant-arrival-rate',
  rate: 200,                   // iterations per timeUnit
  timeUnit: '1s',              // default: '1s'
  duration: '5m',
  preAllocatedVUs: 50,         // VUs pre-allocated at start
  maxVUs: 200,                 // max VUs to allocate
}

// ramping-arrival-rate
{
  executor: 'ramping-arrival-rate',
  startRate: 0,
  timeUnit: '1s',
  preAllocatedVUs: 20,
  maxVUs: 200,
  stages: [{ target: 100, duration: '2m' }, { target: 0, duration: '1m' }],
}

// shared-iterations
{ executor: 'shared-iterations', vus: 10, iterations: 500, maxDuration: '10m' }

// per-vu-iterations
{ executor: 'per-vu-iterations', vus: 20, iterations: 50, maxDuration: '10m' }

// externally-controlled
{ executor: 'externally-controlled', vus: 10, maxVUs: 500, duration: '30m' }
```

---

## Lifecycle Functions

```javascript
// INIT — runs once per VU at startup
// Top-level code: imports, options, open(), SharedArray
import http from 'k6/http';
export const options = { /* ... */ };
const data = JSON.parse(open('./data.json'));

// SETUP — runs once before all VUs; return value passed to default and teardown
export function setup() {
  const res = http.post('https://api.example.com/auth', '...');
  return { token: res.json('token') };
}

// DEFAULT — runs repeatedly per VU (main test logic)
export default function (data) {
  // data = return value from setup()
  http.get('https://api.example.com/', {
    headers: { Authorization: `Bearer ${data.token}` },
  });
}

// TEARDOWN — runs once after all VUs finish
export function teardown(data) {
  // data = same return value from setup()
  http.post('https://api.example.com/cleanup');
}

// HANDLE SUMMARY — runs once at very end; customize output
export function handleSummary(data) {
  return {
    stdout: JSON.stringify(data, null, 2),
    'summary.json': JSON.stringify(data),
  };
}
```

**Rules:**
- `open()` and `SharedArray` only in init (top-level)
- `setup()` and `teardown()` can make HTTP calls
- `setup()` return value must be JSON-serializable
- `handleSummary()` receives all metrics data

---

## SharedArray (k6/data)

```javascript
import { SharedArray } from 'k6/data';

// Constructor: SharedArray(name, callback)
// callback runs ONCE, must return an array
// All VUs share the same read-only data
const users = new SharedArray('users', function () {
  return JSON.parse(open('./users.json'));
});

// Access by index (read-only)
export default function () {
  const user = users[__VU % users.length];  // round-robin
  const randomUser = users[Math.floor(Math.random() * users.length)];
  console.log(users.length);  // .length property available
}
```

---

## open() Function

```javascript
// Read file contents at init time ONLY
// Returns string (text mode) or ArrayBuffer (binary mode)

const text = open('./file.txt');              // text mode (default)
const binary = open('./image.png', 'b');      // binary mode → ArrayBuffer
const csv = open('./data.csv');               // read CSV as string

// CANNOT be called inside default, setup, or teardown functions
```

---

## Encoding (k6/encoding)

```javascript
import encoding from 'k6/encoding';

encoding.b64encode(input, [encoding]);    // Base64 encode ('std' | 'url' | 'rawstd' | 'rawurl')
encoding.b64decode(input, [encoding], [format]); // Base64 decode, format: 's' (string) | 'b' (ArrayBuffer)
```

```javascript
const encoded = encoding.b64encode('hello world');           // "aGVsbG8gd29ybGQ="
const decoded = encoding.b64decode('aGVsbG8gd29ybGQ=', 'std', 's');  // "hello world"
const urlSafe = encoding.b64encode('data', 'url');
```

---

## Crypto (k6/crypto)

```javascript
import crypto from 'k6/crypto';

// Hashing
crypto.md5(input, outputEncoding);       // 'hex' (default) | 'base64' | 'binary'
crypto.sha1(input, outputEncoding);
crypto.sha256(input, outputEncoding);
crypto.sha384(input, outputEncoding);
crypto.sha512(input, outputEncoding);
crypto.sha512_256(input, outputEncoding);
crypto.ripemd160(input, outputEncoding);

// HMAC
crypto.hmac(algorithm, key, input, outputEncoding);
// algorithm: 'md5' | 'sha1' | 'sha256' | 'sha384' | 'sha512' | 'sha512_256' | 'ripemd160'

// Hasher (streaming)
const hasher = crypto.createHash(algorithm);
hasher.update(input);
const digest = hasher.digest(outputEncoding);

// HMAC Hasher (streaming)
const hmacHasher = crypto.createHMAC(algorithm, key);
hmacHasher.update(input);
const hmacDigest = hmacHasher.digest(outputEncoding);

// Random bytes
crypto.randomBytes(length);  // returns ArrayBuffer
```

```javascript
// Example: Sign API request
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';

const timestamp = Date.now().toString();
const signature = crypto.hmac('sha256', __ENV.API_SECRET, timestamp, 'hex');
http.get('https://api.example.com/data', {
  headers: { 'X-Timestamp': timestamp, 'X-Signature': signature },
});
```

---

## Execution Context (k6/execution)

```javascript
import exec from 'k6/execution';
```

### Properties

```javascript
// VU Info
exec.vu.idInInstance;          // number: unique VU ID within this k6 instance
exec.vu.idInTest;              // number: unique VU ID across distributed test
exec.vu.iterationInInstance;   // number: iteration count for this VU (instance)
exec.vu.iterationInScenario;  // number: iteration count for this VU (scenario)
exec.vu.tags;                  // object: VU-level tags (read/write)

// Scenario Info
exec.scenario.name;            // string: current scenario name
exec.scenario.executor;        // string: executor type
exec.scenario.startTime;       // number: scenario start timestamp (epoch ms)
exec.scenario.progress;        // number: 0.0 - 1.0 completion progress
exec.scenario.iterationInInstance; // number: total iterations in instance
exec.scenario.iterationInTest; // number: total iterations in test

// Instance Info
exec.instance.iterationsCompleted;  // number: total completed iterations
exec.instance.iterationsInterrupted; // number: interrupted iterations
exec.instance.vusActive;       // number: currently active VUs
exec.instance.vusInitialized;  // number: initialized VUs
exec.instance.currentTestRunDuration; // number: elapsed ms

// Test Control
exec.test.abort([reason]);     // abort entire test immediately
```

```javascript
// Example: Unique data per VU + iteration
import exec from 'k6/execution';

export default function () {
  const uniqueEmail = `user-${exec.vu.idInInstance}-${exec.vu.iterationInScenario}@test.com`;

  // Dynamic tags
  exec.vu.tags['custom_tag'] = 'my_value';

  // Abort on condition
  if (exec.instance.vusActive < 1) {
    exec.test.abort('No active VUs');
  }
}
```

---

## Browser Module (k6/browser)

```javascript
import { browser } from 'k6/browser';
```

Requires scenario with `options: { browser: { type: 'chromium' } }`.

### Key APIs

```javascript
// Browser
const page = await browser.newPage();
browser.isConnected();

// Page
await page.goto(url, { waitUntil: 'load' | 'domcontentloaded' | 'networkidle' });
await page.waitForNavigation();
await page.waitForSelector(selector, { timeout: 5000, state: 'visible' | 'hidden' });
await page.waitForTimeout(ms);
await page.reload();
await page.goBack();
await page.goForward();
await page.screenshot({ path: 'screenshot.png' });
await page.close();
page.url();
await page.title();
await page.content();

// Evaluate JavaScript in page
const result = await page.evaluate(() => document.title);
const result = await page.evaluate((arg) => arg.foo, { foo: 'bar' });

// Locators (recommended)
const locator = page.locator(selector);
await locator.click();
await locator.fill(text);
await locator.type(text);             // key by key
await locator.selectOption(value);
await locator.check();                // checkbox
await locator.uncheck();
await locator.press('Enter');
await locator.isVisible();
await locator.isEnabled();
await locator.textContent();
await locator.inputValue();
const count = await locator.count();

// Keyboard
await page.keyboard.press('Tab');
await page.keyboard.type('text');

// Mouse
await page.mouse.click(x, y);
```

### Web Vitals Metrics (Automatic)

| Metric | Type | Description |
|--------|------|-------------|
| `browser_web_vital_lcp` | Trend | Largest Contentful Paint |
| `browser_web_vital_fid` | Trend | First Input Delay |
| `browser_web_vital_cls` | Trend | Cumulative Layout Shift |
| `browser_web_vital_ttfb` | Trend | Time to First Byte |
| `browser_web_vital_fcp` | Trend | First Contentful Paint |
| `browser_web_vital_inp` | Trend | Interaction to Next Paint |

---

## HTML Parsing (k6/html)

```javascript
import { parseHTML } from 'k6/html';

const doc = parseHTML(res.body);
doc.find(selector);                    // CSS selector → Selection
selection.text();                       // text content
selection.html();                       // inner HTML
selection.attr(name);                   // attribute value
selection.first();                      // first element
selection.last();                       // last element
selection.eq(index);                    // element at index
selection.each(function (idx, el) {}); // iterate
selection.size();                       // count matching elements
```

---

## WebSocket (k6/ws)

```javascript
import ws from 'k6/ws';

const res = ws.connect(url, params, callback);
// params: { headers: {}, tags: {} }
// callback: function (socket) { ... }
// Returns: Response object { status, headers, body, error, url }
```

### Socket Object

```javascript
socket.on('open', () => {});
socket.on('message', (msg) => {});
socket.on('binaryMessage', (msg) => {});  // ArrayBuffer
socket.on('ping', () => {});
socket.on('pong', () => {});
socket.on('close', () => {});
socket.on('error', (e) => { e.error(); });

socket.send(data);                      // string
socket.sendBinary(data);               // ArrayBuffer
socket.ping();
socket.close();

socket.setInterval(callback, intervalMs);
socket.setTimeout(callback, timeoutMs);
```

---

## gRPC (k6/net/grpc)

```javascript
import grpc from 'k6/net/grpc';
const client = new grpc.Client();
```

### Client Methods

```javascript
// Load proto files (init time only)
client.load(importPaths, ...protoFiles);

// Connect
client.connect(address, {
  plaintext: true,              // no TLS
  reflect: false,               // use server reflection
  timeout: '5s',
  tls: { cacert, cert, key },  // TLS config (open() at init)
});

// Invoke RPC
const resp = client.invoke(method, message, {
  metadata: { 'x-api-key': 'secret' },
  tags: { name: 'MyRPC' },
  timeout: '10s',
});

// Response
resp.status;     // grpc status code
resp.message;    // response message object
resp.headers;    // response metadata
resp.trailers;   // response trailers
resp.error;      // error details (if status != OK)

client.close();
```

### Status Codes

```javascript
grpc.StatusOK;                 // 0
grpc.StatusCancelled;          // 1
grpc.StatusUnknown;            // 2
grpc.StatusInvalidArgument;    // 3
grpc.StatusDeadlineExceeded;   // 4
grpc.StatusNotFound;           // 5
grpc.StatusAlreadyExists;      // 6
grpc.StatusPermissionDenied;   // 7
grpc.StatusResourceExhausted;  // 8
grpc.StatusFailedPrecondition; // 9
grpc.StatusAborted;            // 10
grpc.StatusOutOfRange;         // 11
grpc.StatusUnimplemented;      // 12
grpc.StatusInternal;           // 13
grpc.StatusUnavailable;        // 14
grpc.StatusDataLoss;           // 15
grpc.StatusUnauthenticated;    // 16
```

---

## Built-in Metrics

### HTTP Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `http_reqs` | Counter | Total HTTP requests made |
| `http_req_duration` | Trend | Total request time (ms) |
| `http_req_blocked` | Trend | Time blocked before initiating request |
| `http_req_connecting` | Trend | TCP connection time |
| `http_req_tls_handshaking` | Trend | TLS handshake time |
| `http_req_sending` | Trend | Time sending request body |
| `http_req_waiting` | Trend | Time to first byte (TTFB) |
| `http_req_receiving` | Trend | Time receiving response body |
| `http_req_failed` | Rate | Rate of failed requests (non-2xx/3xx by default) |

### Execution Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `iterations` | Counter | Total completed VU iterations |
| `iteration_duration` | Trend | Full iteration time including sleep |
| `vus` | Gauge | Current active VUs |
| `vus_max` | Gauge | Max configured VUs |
| `data_received` | Counter | Total bytes received |
| `data_sent` | Counter | Total bytes sent |
| `checks` | Rate | Rate of successful checks |
| `dropped_iterations` | Counter | Iterations that couldn't start (arrival-rate) |

### WebSocket Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `ws_connecting` | Trend | WebSocket connection time |
| `ws_msgs_sent` | Counter | Messages sent |
| `ws_msgs_received` | Counter | Messages received |
| `ws_sessions` | Counter | Total WebSocket sessions |
| `ws_session_duration` | Trend | Session duration |

### gRPC Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `grpc_req_duration` | Trend | gRPC request duration |

---

## Environment and Globals

### Global Variables

```javascript
__ENV          // object: environment variables (read-only in VU context)
__VU           // number: current VU ID (1-based) — legacy, prefer exec.vu.idInInstance
__ITER         // number: current iteration (0-based) — legacy, prefer exec.vu.iterationInScenario
__ENV.MY_VAR   // access env var set via -e flag or OS environment
```

### Setting Environment Variables

```bash
# CLI flags
k6 run -e BASE_URL=https://api.example.com -e TOKEN=secret script.js

# OS environment
export BASE_URL=https://api.example.com
k6 run script.js

# In options (per-scenario)
export const options = {
  scenarios: {
    main: { env: { ENDPOINT: '/api/v2' } },
  },
};
```

### CLI Flags Reference (Common)

```bash
k6 run [flags] script.js

--vus, -u              VU count
--duration, -d         Test duration
--iterations, -i       Total iterations
--stage, -s            Ramping stages (repeatable): -s 1m:10 -s 5m:50
--env, -e              Set env variable: -e KEY=VAL
--out, -o              Output backend: -o json=file.json
--tag                  Global tag: --tag name=value
--http-debug           HTTP debug output ('' or 'full')
--verbose              Verbose logging
--address              REST API address (for externally-controlled)
--summary-trend-stats  Trend stats to show: avg,min,med,max,p(90),p(95)
--no-summary           Suppress end-of-test summary
--no-color             Disable colored output
--log-output           Log destination: stderr, stdout, file=path
--log-format           Log format: raw, json
```
