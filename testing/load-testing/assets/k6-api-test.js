// k6-api-test.js — Production-ready k6 API load test template
//
// Usage:
//   k6 run --env BASE_URL=https://api.example.com k6-api-test.js
//   k6 run --env BASE_URL=https://api.example.com --env SCENARIO=smoke k6-api-test.js
//   k6 run --env BASE_URL=https://api.example.com --out influxdb=http://localhost:8086/k6 k6-api-test.js
//
// Environment variables:
//   BASE_URL             - Target API base URL (required)
//   SCENARIO             - Which scenario to run: smoke|load|stress|soak (default: load)
//   LOAD_TEST_PASSWORD   - Password for auth (optional)
//   SLACK_WEBHOOK_URL    - Slack webhook for notifications (optional)
//   TEST_RUN_ID          - Custom run identifier (optional)

import http from 'k6/http';
import { check, sleep, group, fail } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import { SharedArray } from 'k6/data';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';
import { randomIntBetween, randomItem } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

// =============================================================================
// Custom Metrics
// =============================================================================

const errorRate = new Rate('error_rate');
const apiLatency = new Trend('api_latency');
const loginDuration = new Trend('login_duration');
const businessErrors = new Counter('business_errors');
const activeUsers = new Gauge('active_users');

// =============================================================================
// Test Data (loaded once, shared across VUs)
// =============================================================================

// Uncomment and create users.csv for data-driven testing:
// const users = new SharedArray('users', function () {
//   const papaparse = require('https://jslib.k6.io/papaparse/5.1.1/index.js');
//   return papaparse.parse(open('./data/users.csv'), { header: true }).data;
// });

const BASE_URL = __ENV.BASE_URL || fail('BASE_URL environment variable is required');
const SCENARIO = __ENV.SCENARIO || 'load';

// =============================================================================
// Scenario Definitions
// =============================================================================

const scenarios = {
  smoke: {
    smoke: {
      executor: 'constant-vus',
      vus: 1,
      duration: '1m',
      exec: 'apiFlow',
    },
  },
  load: {
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 50 },    // ramp up
        { duration: '5m', target: 50 },    // steady state
        { duration: '2m', target: 100 },   // increase
        { duration: '5m', target: 100 },   // steady state
        { duration: '2m', target: 0 },     // ramp down
      ],
      exec: 'apiFlow',
      gracefulRampDown: '30s',
    },
  },
  stress: {
    stress: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 100 },
        { duration: '3m', target: 100 },
        { duration: '2m', target: 200 },
        { duration: '3m', target: 200 },
        { duration: '2m', target: 300 },
        { duration: '3m', target: 300 },
        { duration: '2m', target: 0 },
      ],
      exec: 'apiFlow',
      gracefulRampDown: '30s',
    },
  },
  soak: {
    soak: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '5m', target: 50 },
        { duration: '60m', target: 50 },   // sustained load for 1 hour
        { duration: '5m', target: 0 },
      ],
      exec: 'apiFlow',
    },
  },
  // Open-loop: maintain fixed RPS regardless of response time
  rps_target: {
    constant_rps: {
      executor: 'constant-arrival-rate',
      rate: 200,
      timeUnit: '1s',
      duration: '10m',
      preAllocatedVUs: 50,
      maxVUs: 300,
      exec: 'apiFlow',
    },
  },
};

// =============================================================================
// Options
// =============================================================================

export const options = {
  scenarios: scenarios[SCENARIO] || scenarios.load,
  thresholds: {
    http_req_duration: [
      { threshold: 'p(95)<500', abortOnFail: false },
      { threshold: 'p(99)<1500', abortOnFail: false },
    ],
    http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true, delayAbortEval: '30s' }],
    error_rate: ['rate<0.05'],
    checks: ['rate>0.99'],
    'http_req_duration{type:api}': ['p(95)<400'],
    'http_req_duration{type:auth}': ['p(95)<600'],
  },
  dns: {
    ttl: '5m',
    select: 'roundRobin',
  },
};

// =============================================================================
// Lifecycle: setup (runs once before test)
// =============================================================================

export function setup() {
  // Health check
  const healthRes = http.get(`${BASE_URL}/health`);
  if (healthRes.status !== 200) {
    console.error(`Health check failed: ${healthRes.status} ${healthRes.body}`);
    fail(`Target ${BASE_URL} is not healthy`);
  }

  // Authenticate (if needed)
  let token = null;
  if (__ENV.LOAD_TEST_PASSWORD) {
    const loginRes = http.post(
      `${BASE_URL}/auth/token`,
      JSON.stringify({ username: 'loadtest', password: __ENV.LOAD_TEST_PASSWORD }),
      { headers: { 'Content-Type': 'application/json' }, tags: { type: 'auth' } }
    );

    if (loginRes.status === 200) {
      token = loginRes.json('access_token');
      console.log('Authentication successful');
    } else {
      console.warn(`Auth failed (${loginRes.status}), continuing without token`);
    }
  }

  return {
    token,
    startTime: Date.now(),
    baseUrl: BASE_URL,
  };
}

// =============================================================================
// Main test flow
// =============================================================================

export function apiFlow(data) {
  const params = {
    headers: {
      'Content-Type': 'application/json',
      ...(data.token ? { Authorization: `Bearer ${data.token}` } : {}),
    },
  };

  activeUsers.add(__VU);

  // --- Group: List Resources ---
  group('List Resources', () => {
    const res = http.get(`${BASE_URL}/api/items`, {
      ...params,
      tags: { name: 'GET /api/items', type: 'api' },
    });

    const success = check(res, {
      'list: status 200': (r) => r.status === 200,
      'list: has data': (r) => {
        try { return r.json('data') !== undefined; }
        catch { return false; }
      },
      'list: response < 500ms': (r) => r.timings.duration < 500,
    });

    errorRate.add(!success);
    apiLatency.add(res.timings.duration, { endpoint: 'list' });

    if (res.status >= 500) {
      businessErrors.add(1);
    }
  });

  sleep(randomIntBetween(1, 3));

  // --- Group: Get Single Resource ---
  group('Get Resource', () => {
    const id = randomIntBetween(1, 100);
    const res = http.get(`${BASE_URL}/api/items/${id}`, {
      ...params,
      tags: { name: 'GET /api/items/{id}', type: 'api' },
    });

    check(res, {
      'get: status 200': (r) => r.status === 200,
      'get: has id': (r) => {
        try { return r.json('id') !== undefined; }
        catch { return false; }
      },
    });

    errorRate.add(res.status !== 200 && res.status !== 404);
    apiLatency.add(res.timings.duration, { endpoint: 'detail' });
  });

  sleep(randomIntBetween(1, 2));

  // --- Group: Create Resource (lower frequency) ---
  if (__ITER % 5 === 0) {
    group('Create Resource', () => {
      const payload = JSON.stringify({
        name: `load-test-item-${__VU}-${__ITER}`,
        value: Math.random() * 1000,
        tags: ['load-test', `vu-${__VU}`],
      });

      const res = http.post(`${BASE_URL}/api/items`, payload, {
        ...params,
        tags: { name: 'POST /api/items', type: 'api' },
      });

      check(res, {
        'create: status 201': (r) => r.status === 201 || r.status === 200,
      });

      errorRate.add(res.status >= 400);
      apiLatency.add(res.timings.duration, { endpoint: 'create' });
    });
  }

  // --- Group: Search (every 3rd iteration) ---
  if (__ITER % 3 === 0) {
    group('Search', () => {
      const query = randomItem(['test', 'load', 'performance', 'item', 'demo']);
      const res = http.get(`${BASE_URL}/api/items?search=${query}&limit=20`, {
        ...params,
        tags: { name: 'GET /api/items?search=', type: 'api' },
      });

      check(res, {
        'search: status 200': (r) => r.status === 200,
      });

      apiLatency.add(res.timings.duration, { endpoint: 'search' });
    });
  }

  sleep(randomIntBetween(1, 4));
}

// =============================================================================
// Lifecycle: teardown (runs once after test)
// =============================================================================

export function teardown(data) {
  const durationSec = ((Date.now() - data.startTime) / 1000).toFixed(1);
  console.log(`\nTest completed in ${durationSec}s`);
  console.log(`Scenario: ${SCENARIO}`);
  console.log(`Target: ${data.baseUrl}`);
}

// =============================================================================
// Custom summary handler
// =============================================================================

export function handleSummary(data) {
  const outputs = {
    stdout: textSummary(data, { indent: '  ', enableColors: true }),
    'results/summary.json': JSON.stringify(data, null, 2),
  };

  // Slack notification on failure
  if (__ENV.SLACK_WEBHOOK_URL) {
    const p95 = data.metrics.http_req_duration?.values['p(95)'] || 0;
    const errors = data.metrics.http_req_failed?.values.rate || 0;

    let anyFailed = false;
    for (const metric of Object.values(data.metrics)) {
      if (metric.thresholds) {
        for (const t of Object.values(metric.thresholds)) {
          if (!t.ok) anyFailed = true;
        }
      }
    }

    if (anyFailed) {
      http.post(__ENV.SLACK_WEBHOOK_URL, JSON.stringify({
        text: `🔴 Load Test FAILED (${SCENARIO})\n• p95: ${p95.toFixed(0)}ms\n• Errors: ${(errors * 100).toFixed(2)}%\n• Target: ${BASE_URL}`,
      }));
    }
  }

  return outputs;
}
