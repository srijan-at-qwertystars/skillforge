/**
 * k6 Load Test Template — Production-Ready
 *
 * Features: multi-scenario, thresholds, data parameterization, custom metrics,
 *           environment selection, groups, tags, custom summary.
 *
 * Usage:
 *   k6 run -e ENV=staging -e BASE_URL=https://api.example.com load-test.template.js
 *   k6 run --out json=results.json load-test.template.js
 *
 * Customize:
 *   1. Replace API endpoints with your actual endpoints
 *   2. Update testdata/users.json with valid test credentials
 *   3. Adjust thresholds to match your SLAs
 *   4. Configure scenarios for your traffic patterns
 */

import http from 'k6/http';
import { check, group, sleep, fail } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';
import exec from 'k6/execution';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

// ── Configuration ───────────────────────────────────────────────────────────

const BASE_URL = __ENV.BASE_URL || 'https://api.example.com';
const IS_CI = __ENV.CI === 'true';

// ── Test Data (loaded once, shared across VUs) ──────────────────────────────

const users = new SharedArray('users', () =>
  JSON.parse(open('./testdata/users.json'))
);

// ── Custom Metrics ──────────────────────────────────────────────────────────

const errorRate = new Rate('custom_error_rate');
const apiErrors = new Counter('api_errors');
const loginLatency = new Trend('login_latency', true);
const businessTxn = new Counter('business_transactions');

// ── Options ─────────────────────────────────────────────────────────────────

export const options = {
  scenarios: {
    // Smoke: quick validation (runs first)
    smoke: {
      executor: 'shared-iterations',
      exec: 'smokeTest',
      vus: 1,
      iterations: 5,
      tags: { test_type: 'smoke' },
    },
    // Load: normal traffic pattern
    load: {
      executor: 'ramping-vus',
      exec: 'loadTest',
      startTime: '30s', // starts after smoke
      startVUs: 0,
      stages: IS_CI
        ? [
            { duration: '1m', target: 20 },
            { duration: '2m', target: 20 },
            { duration: '30s', target: 0 },
          ]
        : [
            { duration: '2m', target: 50 },
            { duration: '5m', target: 50 },
            { duration: '2m', target: 0 },
          ],
      tags: { test_type: 'load' },
    },
    // Spike: sudden burst (optional, starts later)
    // Uncomment to include spike testing:
    // spike: {
    //   executor: 'ramping-arrival-rate',
    //   exec: 'loadTest',
    //   startTime: '10m',
    //   startRate: 10,
    //   timeUnit: '1s',
    //   preAllocatedVUs: 50,
    //   maxVUs: 300,
    //   stages: [
    //     { target: 200, duration: '30s' },
    //     { target: 200, duration: '1m' },
    //     { target: 10, duration: '30s' },
    //   ],
    //   tags: { test_type: 'spike' },
    // },
  },

  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.95'],
    custom_error_rate: ['rate<0.05'],
    login_latency: ['p(95)<400'],
    // Abort early on critical failures
    'http_req_failed{test_type:smoke}': [
      { threshold: 'rate<0.01', abortOnFail: true, delayAbortEval: '10s' },
    ],
  },

  // Suppress response bodies for memory efficiency
  discardResponseBodies: false,
};

// ── Helper Functions ────────────────────────────────────────────────────────

function getUser() {
  return users[exec.vu.idInInstance % users.length];
}

function authHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  };
}

function recordResult(res, label) {
  const success = check(res, {
    [`${label}: status 2xx`]: (r) => r.status >= 200 && r.status < 300,
    [`${label}: response time < 1s`]: (r) => r.timings.duration < 1000,
  });
  errorRate.add(!success);
  if (!success) apiErrors.add(1);
  return success;
}

function thinkTime() {
  sleep(Math.random() * 2 + 1); // 1-3 seconds
}

// ── Smoke Test Flow ─────────────────────────────────────────────────────────

export function smokeTest() {
  group('Smoke — Health Check', () => {
    const res = http.get(`${BASE_URL}/health`, {
      tags: { name: 'HealthCheck' },
    });
    check(res, {
      'health: status 200': (r) => r.status === 200,
    });
  });
  sleep(1);
}

// ── Load Test Flow ──────────────────────────────────────────────────────────

export function loadTest() {
  const user = getUser();
  let token = null;

  // Login
  group('Auth — Login', () => {
    const start = Date.now();
    const res = http.post(
      `${BASE_URL}/auth/login`,
      JSON.stringify({
        username: user.username,
        password: user.password,
      }),
      {
        headers: { 'Content-Type': 'application/json' },
        tags: { name: 'Login' },
      }
    );
    loginLatency.add(Date.now() - start);

    if (recordResult(res, 'login') && res.status === 200) {
      token = res.json('token');
    } else {
      return; // skip rest if login fails
    }
  });

  if (!token) return;
  thinkTime();

  // Browse
  group('Browse — List Resources', () => {
    const res = http.get(`${BASE_URL}/api/resources?page=1&limit=20`, {
      headers: authHeaders(token),
      tags: { name: 'ListResources' },
    });
    recordResult(res, 'list');

    // Data correlation: use IDs from response
    if (res.status === 200) {
      const items = res.json('data.items');
      if (items && items.length > 0) {
        const itemId = items[Math.floor(Math.random() * items.length)].id;
        const detail = http.get(`${BASE_URL}/api/resources/${itemId}`, {
          headers: authHeaders(token),
          tags: { name: 'GetResource' },
        });
        recordResult(detail, 'detail');
      }
    }
  });

  thinkTime();

  // Transaction
  group('Transaction — Create', () => {
    const payload = {
      name: `item-${exec.vu.idInInstance}-${exec.vu.iterationInScenario}`,
      value: Math.floor(Math.random() * 1000),
      timestamp: new Date().toISOString(),
    };

    const res = http.post(`${BASE_URL}/api/resources`, JSON.stringify(payload), {
      headers: authHeaders(token),
      tags: { name: 'CreateResource' },
    });

    if (recordResult(res, 'create')) {
      businessTxn.add(1);
    }
  });

  thinkTime();
}

// Default export (required even when using exec in scenarios)
export default function () {
  loadTest();
}

// ── Custom Summary Handler ──────────────────────────────────────────────────

export function handleSummary(data) {
  const outputs = {
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
  };

  // Always write JSON summary
  outputs['results/summary.json'] = JSON.stringify(data, null, 2);

  return outputs;
}
