#!/usr/bin/env bash
#
# ws-load-test.sh — WebSocket load testing with k6 or Artillery
#
# Usage:
#   ./ws-load-test.sh [options]
#
# Options:
#   -u, --url URL         WebSocket URL (default: ws://localhost:3000)
#   -c, --connections N   Number of concurrent connections (default: 100)
#   -d, --duration SECS   Test duration in seconds (default: 30)
#   -t, --tool TOOL       Tool to use: k6, artillery, or builtin (default: auto-detect)
#   -o, --output FILE     Output report file (default: ws-load-report.json)
#   -h, --help            Show this help
#
# Examples:
#   ./ws-load-test.sh -u ws://localhost:3000 -c 500 -d 60
#   ./ws-load-test.sh --tool k6 --connections 1000
#   ./ws-load-test.sh --tool artillery -u wss://staging.example.com/ws
#   ./ws-load-test.sh --tool builtin -c 50     # no external deps needed

set -euo pipefail

# Defaults
WS_URL="ws://localhost:3000"
CONNECTIONS=100
DURATION=30
TOOL="auto"
OUTPUT="ws-load-report.json"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url) WS_URL="$2"; shift 2 ;;
    -c|--connections) CONNECTIONS="$2"; shift 2 ;;
    -d|--duration) DURATION="$2"; shift 2 ;;
    -t|--tool) TOOL="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -h|--help)
      head -20 "$0" | tail -18
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Auto-detect tool
if [ "$TOOL" = "auto" ]; then
  if command -v k6 &>/dev/null; then
    TOOL="k6"
  elif command -v artillery &>/dev/null; then
    TOOL="artillery"
  else
    TOOL="builtin"
  fi
fi

echo "╔══════════════════════════════════════════╗"
echo "║        WebSocket Load Test               ║"
echo "╠══════════════════════════════════════════╣"
echo "║  URL:          $WS_URL"
echo "║  Connections:  $CONNECTIONS"
echo "║  Duration:     ${DURATION}s"
echo "║  Tool:         $TOOL"
echo "║  Output:       $OUTPUT"
echo "╚══════════════════════════════════════════╝"
echo ""

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ── k6 test ─────────────────────────────────────────────
run_k6_test() {
  cat > "$TMPDIR/ws-test.js" << TESTEOF
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Trend, Rate } from 'k6/metrics';

// Custom metrics
const messagesSent = new Counter('ws_messages_sent');
const messagesReceived = new Counter('ws_messages_received');
const messageLatency = new Trend('ws_message_latency_ms');
const connectionTime = new Trend('ws_connection_time_ms');
const connectSuccess = new Rate('ws_connect_success');

export const options = {
  stages: [
    { duration: '${DURATION_RAMP}s', target: ${CONNECTIONS} },  // ramp up
    { duration: '${DURATION_SUSTAIN}s', target: ${CONNECTIONS} },  // sustain
    { duration: '${DURATION_RAMP}s', target: 0 },                 // ramp down
  ],
  thresholds: {
    ws_connect_success: ['rate>0.95'],           // >95% connections succeed
    ws_message_latency_ms: ['p(95)<500'],        // p95 latency < 500ms
    ws_connection_time_ms: ['p(95)<2000'],       // p95 connection time < 2s
  },
};

export default function () {
  const connectStart = Date.now();

  const res = ws.connect('${WS_URL}', {}, function (socket) {
    const connectDuration = Date.now() - connectStart;
    connectionTime.add(connectDuration);

    socket.on('open', () => {
      connectSuccess.add(1);

      // Send messages periodically
      const interval = setInterval(() => {
        const sendTime = Date.now();
        socket.send(JSON.stringify({
          type: 'ping',
          timestamp: sendTime,
        }));
        messagesSent.add(1);
      }, 1000);

      // Close after duration
      socket.setTimeout(() => {
        clearInterval(interval);
        socket.close();
      }, ${DURATION_SUSTAIN} * 1000);
    });

    socket.on('message', (data) => {
      messagesReceived.add(1);
      try {
        const msg = JSON.parse(data);
        if (msg.timestamp) {
          messageLatency.add(Date.now() - msg.timestamp);
        }
      } catch {}
    });

    socket.on('close', () => {});

    socket.on('error', (e) => {
      connectSuccess.add(0);
      console.error('WebSocket error:', e.error());
    });
  });

  check(res, {
    'status is 101': (r) => r && r.status === 101,
  });

  sleep(1);
}
TESTEOF

  # Calculate ramp/sustain durations
  local DURATION_RAMP=$((DURATION / 6))
  [ "$DURATION_RAMP" -lt 5 ] && DURATION_RAMP=5
  local DURATION_SUSTAIN=$((DURATION - DURATION_RAMP * 2))

  # Re-generate with correct values
  sed -i "s/\${DURATION_RAMP}/$DURATION_RAMP/g; s/\${DURATION_SUSTAIN}/$DURATION_SUSTAIN/g; s|\${WS_URL}|$WS_URL|g; s/\${CONNECTIONS}/$CONNECTIONS/g" "$TMPDIR/ws-test.js"

  echo "🔧 Running k6 WebSocket load test..."
  echo ""
  k6 run --summary-export="$OUTPUT" "$TMPDIR/ws-test.js"
  echo ""
  echo "📊 Report saved to: $OUTPUT"
}

# ── Artillery test ──────────────────────────────────────
run_artillery_test() {
  cat > "$TMPDIR/ws-artillery.yml" << ARTEOF
config:
  target: "${WS_URL}"
  phases:
    - duration: ${DURATION}
      arrivalRate: $((CONNECTIONS / DURATION + 1))
      maxVusers: ${CONNECTIONS}
  ws:
    rejectUnauthorized: false

scenarios:
  - engine: ws
    flow:
      - send:
          type: "message"
          payload: '{"type":"ping","timestamp":{{$timestamp}}}'
      - think: 1
      - send:
          type: "message"
          payload: '{"type":"message","text":"load test","room":"test"}'
      - think: 1
      - send:
          type: "message"
          payload: '{"type":"ping","timestamp":{{$timestamp}}}'
      - think: $((DURATION - 4))
ARTEOF

  echo "🔧 Running Artillery WebSocket load test..."
  echo ""
  artillery run --output "$OUTPUT" "$TMPDIR/ws-artillery.yml"
  echo ""
  echo "📊 Report saved to: $OUTPUT"

  if command -v artillery &>/dev/null; then
    artillery report "$OUTPUT" --output "${OUTPUT%.json}.html" 2>/dev/null && \
      echo "📈 HTML report: ${OUTPUT%.json}.html" || true
  fi
}

# ── Built-in test (Node.js) ────────────────────────────
run_builtin_test() {
  if ! command -v node &>/dev/null; then
    echo "Error: Node.js is required for the built-in test."
    exit 1
  fi

  # Check if ws module is available, install temporarily if not
  local WS_AVAILABLE=false
  node -e "require('ws')" 2>/dev/null && WS_AVAILABLE=true

  if [ "$WS_AVAILABLE" = false ]; then
    echo "📦 Installing ws module temporarily..."
    cd "$TMPDIR" && npm init -y > /dev/null 2>&1 && npm install ws --no-save > /dev/null 2>&1
    export NODE_PATH="$TMPDIR/node_modules"
  fi

  cat > "$TMPDIR/builtin-test.js" << 'NODEEOF'
const WebSocket = require('ws');

const URL = process.env.WS_URL;
const TARGET_CONNECTIONS = parseInt(process.env.CONNECTIONS);
const DURATION_SECS = parseInt(process.env.DURATION);

const stats = {
  attempted: 0,
  connected: 0,
  failed: 0,
  messagesSent: 0,
  messagesReceived: 0,
  latencies: [],
  connectionTimes: [],
  errors: [],
  startTime: Date.now(),
};

const connections = [];
let phase = 'ramping';

function connect() {
  stats.attempted++;
  const connectStart = Date.now();
  const ws = new WebSocket(URL);

  const timeout = setTimeout(() => {
    ws.terminate();
    stats.failed++;
    stats.errors.push('Connection timeout (5s)');
  }, 5000);

  ws.on('open', () => {
    clearTimeout(timeout);
    stats.connected++;
    stats.connectionTimes.push(Date.now() - connectStart);
    connections.push(ws);

    // Send periodic messages
    const interval = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        const msg = JSON.stringify({ type: 'ping', timestamp: Date.now() });
        ws.send(msg);
        stats.messagesSent++;
      }
    }, 1000);

    ws.on('close', () => {
      clearInterval(interval);
      const idx = connections.indexOf(ws);
      if (idx !== -1) connections.splice(idx, 1);
    });
  });

  ws.on('message', (data) => {
    stats.messagesReceived++;
    try {
      const msg = JSON.parse(data.toString());
      if (msg.timestamp) {
        stats.latencies.push(Date.now() - msg.timestamp);
      }
    } catch {}
  });

  ws.on('error', (err) => {
    clearTimeout(timeout);
    stats.failed++;
    stats.errors.push(err.message);
  });
}

// Ramp up connections
const rampInterval = setInterval(() => {
  if (connections.length >= TARGET_CONNECTIONS) {
    clearInterval(rampInterval);
    phase = 'sustained';
    return;
  }
  // Connect in batches
  const batch = Math.min(10, TARGET_CONNECTIONS - connections.length);
  for (let i = 0; i < batch; i++) connect();
}, 100);

// Progress reporter
const progressInterval = setInterval(() => {
  const elapsed = ((Date.now() - stats.startTime) / 1000).toFixed(0);
  const p50 = percentile(stats.latencies, 50);
  const p95 = percentile(stats.latencies, 95);
  process.stdout.write(
    `\r⏱  ${elapsed}s | Active: ${connections.length}/${TARGET_CONNECTIONS} | ` +
    `Sent: ${stats.messagesSent} | Recv: ${stats.messagesReceived} | ` +
    `Latency p50: ${p50}ms p95: ${p95}ms`
  );
}, 1000);

function percentile(arr, p) {
  if (arr.length === 0) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, idx)];
}

// End test after duration
setTimeout(() => {
  clearInterval(rampInterval);
  clearInterval(progressInterval);
  phase = 'closing';

  console.log('\n\nClosing connections...');
  connections.forEach(ws => ws.close(1000, 'Test complete'));

  setTimeout(() => {
    // Force close remaining
    connections.forEach(ws => ws.terminate());

    const elapsed = (Date.now() - stats.startTime) / 1000;
    const report = {
      summary: {
        duration: `${elapsed.toFixed(1)}s`,
        targetConnections: TARGET_CONNECTIONS,
        maxConcurrent: stats.connected,
        totalAttempted: stats.attempted,
        totalFailed: stats.failed,
        successRate: `${((stats.connected / stats.attempted) * 100).toFixed(1)}%`,
        messagesSent: stats.messagesSent,
        messagesReceived: stats.messagesReceived,
      },
      connectionTime: {
        min: `${Math.min(...stats.connectionTimes)}ms`,
        max: `${Math.max(...stats.connectionTimes)}ms`,
        avg: `${(stats.connectionTimes.reduce((a, b) => a + b, 0) / stats.connectionTimes.length).toFixed(1)}ms`,
        p95: `${percentile(stats.connectionTimes, 95)}ms`,
      },
      messageLatency: {
        min: `${Math.min(...stats.latencies)}ms`,
        max: `${Math.max(...stats.latencies)}ms`,
        avg: `${(stats.latencies.reduce((a, b) => a + b, 0) / stats.latencies.length).toFixed(1)}ms`,
        p50: `${percentile(stats.latencies, 50)}ms`,
        p95: `${percentile(stats.latencies, 95)}ms`,
        p99: `${percentile(stats.latencies, 99)}ms`,
      },
      errors: [...new Set(stats.errors)].slice(0, 10),
    };

    console.log('\n╔══════════════════════════════════════════╗');
    console.log('║        Load Test Results                 ║');
    console.log('╠══════════════════════════════════════════╣');
    console.log(`║  Duration:      ${report.summary.duration}`);
    console.log(`║  Connections:   ${report.summary.maxConcurrent}/${report.summary.targetConnections}`);
    console.log(`║  Success Rate:  ${report.summary.successRate}`);
    console.log(`║  Messages Sent: ${report.summary.messagesSent}`);
    console.log(`║  Messages Recv: ${report.summary.messagesReceived}`);
    console.log('╠──────────────────────────────────────────╣');
    console.log(`║  Connect Time (p95):  ${report.connectionTime.p95}`);
    console.log(`║  Latency (p50):       ${report.messageLatency.p50}`);
    console.log(`║  Latency (p95):       ${report.messageLatency.p95}`);
    console.log(`║  Latency (p99):       ${report.messageLatency.p99}`);
    console.log('╚══════════════════════════════════════════╝');

    if (report.errors.length > 0) {
      console.log('\n⚠️  Errors:');
      report.errors.forEach(e => console.log(`   - ${e}`));
    }

    const outputFile = process.env.OUTPUT;
    require('fs').writeFileSync(outputFile, JSON.stringify(report, null, 2));
    console.log(`\n📊 Report saved to: ${outputFile}`);

    process.exit(0);
  }, 3000);
}, DURATION_SECS * 1000);
NODEEOF

  echo "🔧 Running built-in WebSocket load test (Node.js)..."
  echo ""
  WS_URL="$WS_URL" CONNECTIONS="$CONNECTIONS" DURATION="$DURATION" OUTPUT="$OUTPUT" \
    node "$TMPDIR/builtin-test.js"
}

# ── Run selected tool ───────────────────────────────────
case "$TOOL" in
  k6)
    if ! command -v k6 &>/dev/null; then
      echo "❌ k6 not found. Install: https://k6.io/docs/get-started/installation/"
      echo "   Or use: ./ws-load-test.sh --tool builtin"
      exit 1
    fi
    run_k6_test
    ;;
  artillery)
    if ! command -v artillery &>/dev/null; then
      echo "❌ Artillery not found. Install: npm install -g artillery"
      echo "   Or use: ./ws-load-test.sh --tool builtin"
      exit 1
    fi
    run_artillery_test
    ;;
  builtin)
    run_builtin_test
    ;;
  *)
    echo "❌ Unknown tool: $TOOL (use: k6, artillery, or builtin)"
    exit 1
    ;;
esac
