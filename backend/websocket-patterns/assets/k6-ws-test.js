/**
 * k6 WebSocket Load Test Script
 *
 * Tests WebSocket server performance with realistic connection lifecycle:
 *   - Connection establishment and handshake timing
 *   - Message sending and round-trip latency measurement
 *   - Concurrent connection handling
 *   - Room join/leave operations
 *   - Graceful disconnect
 *
 * Prerequisites:
 *   brew install k6    # macOS
 *   # or: https://k6.io/docs/get-started/installation/
 *
 * Usage:
 *   k6 run k6-ws-test.js
 *   k6 run --vus 200 --duration 60s k6-ws-test.js
 *   k6 run --env WS_URL=wss://staging.example.com/ws k6-ws-test.js
 *   k6 run --out json=results.json k6-ws-test.js
 *
 * Environment Variables:
 *   WS_URL     - WebSocket server URL (default: ws://localhost:3000)
 *   AUTH_TOKEN - JWT token for authentication (default: none)
 *   ROOM_NAME  - Room to join for testing (default: load-test)
 */

import ws from 'k6/ws';
import { check, sleep, fail } from 'k6';
import { Counter, Trend, Rate, Gauge } from 'k6/metrics';

// ── Custom Metrics ─────────────────────────────────────

const wsConnectionTime = new Trend('ws_connection_time_ms', true);
const wsMessageLatency = new Trend('ws_message_latency_ms', true);
const wsMessagesSent = new Counter('ws_messages_sent');
const wsMessagesReceived = new Counter('ws_messages_received');
const wsConnectSuccess = new Rate('ws_connect_success');
const wsMessageSuccess = new Rate('ws_message_success');
const wsActiveConnections = new Gauge('ws_active_connections');
const wsErrors = new Counter('ws_errors');

// ── Test Configuration ─────────────────────────────────

const WS_URL = __ENV.WS_URL || 'ws://localhost:3000';
const AUTH_TOKEN = __ENV.AUTH_TOKEN || '';
const ROOM_NAME = __ENV.ROOM_NAME || 'load-test';

export const options = {
  // Ramp-up pattern: gradual increase to find breaking point
  stages: [
    { duration: '10s', target: 50 },    // warm up
    { duration: '30s', target: 200 },   // ramp to 200 VUs
    { duration: '60s', target: 200 },   // sustain 200 VUs
    { duration: '20s', target: 500 },   // push to 500 VUs
    { duration: '30s', target: 500 },   // sustain 500 VUs
    { duration: '10s', target: 0 },     // ramp down
  ],

  // Thresholds — test fails if these aren't met
  thresholds: {
    ws_connect_success: ['rate>0.95'],              // >95% connections succeed
    ws_connection_time_ms: ['p(95)<3000'],           // p95 connection time < 3s
    ws_message_latency_ms: ['p(50)<100', 'p(95)<500', 'p(99)<2000'],
    ws_message_success: ['rate>0.99'],               // >99% messages get response
    ws_errors: ['count<100'],                        // fewer than 100 errors total
  },
};

// ── Test Scenario ──────────────────────────────────────

export default function () {
  const params = {};

  // Add auth if provided
  if (AUTH_TOKEN) {
    params.headers = {
      'Authorization': `Bearer ${AUTH_TOKEN}`,
    };
  }

  const connectStart = Date.now();

  const res = ws.connect(WS_URL, params, function (socket) {
    const connectDuration = Date.now() - connectStart;
    wsConnectionTime.add(connectDuration);
    wsActiveConnections.add(1);

    let messageCount = 0;
    let receivedCount = 0;
    let lastLatency = 0;

    // ── On Open ────────────────────────────────────────
    socket.on('open', () => {
      wsConnectSuccess.add(1);

      // Join a room
      socket.send(JSON.stringify({
        type: 'join',
        payload: { room: `${ROOM_NAME}-${__VU % 10}` }, // distribute across 10 rooms
      }));

      // Send periodic messages (simulating real user behavior)
      // Message every 2-5 seconds (randomized)
      const messageInterval = setInterval(() => {
        const sendTime = Date.now();
        const msg = {
          type: 'message',
          id: `msg-${__VU}-${messageCount}`,
          payload: {
            text: `Load test message ${messageCount} from VU ${__VU}`,
            room: `${ROOM_NAME}-${__VU % 10}`,
            timestamp: sendTime,
          },
        };

        socket.send(JSON.stringify(msg));
        wsMessagesSent.add(1);
        messageCount++;
      }, 2000 + Math.random() * 3000);

      // Send pings for latency measurement (every 5s)
      const pingInterval = setInterval(() => {
        socket.send(JSON.stringify({
          type: 'ping',
          timestamp: Date.now(),
        }));
      }, 5000);

      // Close connection after test lifecycle
      const testDuration = 20000 + Math.random() * 40000; // 20-60s per VU
      socket.setTimeout(() => {
        clearInterval(messageInterval);
        clearInterval(pingInterval);

        // Leave room before disconnecting
        socket.send(JSON.stringify({
          type: 'leave',
          payload: { room: `${ROOM_NAME}-${__VU % 10}` },
        }));

        // Small delay then close
        socket.setTimeout(() => {
          socket.close();
        }, 500);
      }, testDuration);
    });

    // ── On Message ─────────────────────────────────────
    socket.on('message', (rawData) => {
      wsMessagesReceived.add(1);
      receivedCount++;

      try {
        const data = JSON.parse(rawData);

        // Measure ping-pong latency
        if (data.type === 'pong' && data.payload?.serverTime) {
          lastLatency = Date.now() - data.payload.serverTime;
          wsMessageLatency.add(lastLatency);
          wsMessageSuccess.add(1);
        }

        // Measure message acknowledgement latency
        if (data.type === 'message:ack' && data.timestamp) {
          const ackLatency = Date.now() - data.timestamp;
          wsMessageLatency.add(ackLatency);
          wsMessageSuccess.add(1);
        }

        // Handle welcome message
        if (data.type === 'welcome') {
          // Connection fully established
        }

        // Handle errors from server
        if (data.type === 'error') {
          wsErrors.add(1);
          console.warn(`VU ${__VU}: Server error: ${data.payload?.message || data.error}`);
        }
      } catch (e) {
        // Non-JSON message — might be binary or raw text
      }
    });

    // ── On Close ───────────────────────────────────────
    socket.on('close', () => {
      wsActiveConnections.add(-1);
    });

    // ── On Error ───────────────────────────────────────
    socket.on('error', (e) => {
      wsErrors.add(1);
      wsConnectSuccess.add(0);
      console.error(`VU ${__VU}: WebSocket error: ${e.error()}`);
    });
  });

  // Check that connection was upgraded successfully
  const connected = check(res, {
    'WebSocket handshake status is 101': (r) => r && r.status === 101,
  });

  if (!connected) {
    wsConnectSuccess.add(0);
    wsErrors.add(1);
  }

  // Small sleep between iterations
  sleep(1 + Math.random() * 2);
}

// ── Lifecycle Hooks ────────────────────────────────────

export function setup() {
  console.log(`\n🔌 WebSocket Load Test`);
  console.log(`   Target: ${WS_URL}`);
  console.log(`   Auth: ${AUTH_TOKEN ? 'enabled' : 'disabled'}`);
  console.log(`   Room prefix: ${ROOM_NAME}`);
  console.log('');
  return {};
}

export function teardown(data) {
  console.log('\n📊 Test complete. Check thresholds above for pass/fail status.');
}

// ── Alternative: Stress Test Scenario ──────────────────
// Uncomment and rename to 'default' to use this instead.
// Rapidly opens and closes connections to test server stability.

/*
export function stressTest() {
  const connectStart = Date.now();

  const res = ws.connect(WS_URL, {}, function (socket) {
    wsConnectionTime.add(Date.now() - connectStart);

    socket.on('open', () => {
      wsConnectSuccess.add(1);

      // Send burst of messages
      for (let i = 0; i < 10; i++) {
        socket.send(JSON.stringify({
          type: 'message',
          payload: { text: `Stress message ${i}`, room: 'stress-test' },
        }));
        wsMessagesSent.add(1);
      }

      // Close quickly
      socket.setTimeout(() => socket.close(), 2000);
    });

    socket.on('message', () => wsMessagesReceived.add(1));
    socket.on('error', (e) => { wsErrors.add(1); wsConnectSuccess.add(0); });
  });

  check(res, { 'status is 101': (r) => r && r.status === 101 });
  sleep(0.5);
}
*/
