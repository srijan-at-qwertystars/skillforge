#!/usr/bin/env bash
#
# ws-debug-proxy.sh — Transparent WebSocket debug proxy
#
# Creates a proxy that sits between client and server, logging all WebSocket
# frames in both directions. Useful for debugging message flow, timing, and
# protocol issues without modifying client or server code.
#
# Usage:
#   ./ws-debug-proxy.sh [options]
#
# Options:
#   -l, --listen PORT      Local port to listen on (default: 8888)
#   -t, --target URL       Target WebSocket server URL (default: ws://localhost:3000)
#   -o, --output FILE      Log output file (default: stdout + ws-debug.log)
#   -f, --format FORMAT    Output format: text, json, or compact (default: text)
#   --no-color             Disable colored output
#   -h, --help             Show this help
#
# Examples:
#   ./ws-debug-proxy.sh -t ws://localhost:3000 -l 8888
#   ./ws-debug-proxy.sh -t wss://api.example.com/ws -f json
#   ./ws-debug-proxy.sh -t ws://backend:3000 -o debug.log
#
# Then point your client to ws://localhost:8888 instead of the target server.

set -euo pipefail

# Defaults
LISTEN_PORT=8888
TARGET_URL="ws://localhost:3000"
OUTPUT_FILE="ws-debug.log"
FORMAT="text"
USE_COLOR=true

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--listen) LISTEN_PORT="$2"; shift 2 ;;
    -t|--target) TARGET_URL="$2"; shift 2 ;;
    -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
    -f|--format) FORMAT="$2"; shift 2 ;;
    --no-color) USE_COLOR=false; shift ;;
    -h|--help)
      head -22 "$0" | tail -20
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Check for Node.js
if ! command -v node &>/dev/null; then
  echo "Error: Node.js is required."
  exit 1
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Install ws if needed
cd "$TMPDIR"
npm init -y > /dev/null 2>&1
npm install ws > /dev/null 2>&1

# Create proxy script
cat > "$TMPDIR/proxy.js" << 'PROXYEOF'
const http = require('http');
const WebSocket = require('ws');
const fs = require('fs');

const LISTEN_PORT = parseInt(process.env.LISTEN_PORT);
const TARGET_URL = process.env.TARGET_URL;
const OUTPUT_FILE = process.env.OUTPUT_FILE;
const FORMAT = process.env.FORMAT;
const USE_COLOR = process.env.USE_COLOR === 'true';

// Color codes
const C = USE_COLOR ? {
  reset: '\x1b[0m',
  dim: '\x1b[2m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  white: '\x1b[37m',
  bgRed: '\x1b[41m',
  bgGreen: '\x1b[42m',
} : { reset:'', dim:'', red:'', green:'', yellow:'', blue:'', magenta:'', cyan:'', white:'', bgRed:'', bgGreen:'' };

const logStream = fs.createWriteStream(OUTPUT_FILE, { flags: 'a' });
let connectionCounter = 0;

function timestamp() {
  return new Date().toISOString();
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
}

function truncate(str, maxLen = 200) {
  if (str.length <= maxLen) return str;
  return str.substring(0, maxLen) + `... [${str.length - maxLen} more chars]`;
}

function formatData(data, isBinary) {
  if (isBinary) {
    const buf = Buffer.from(data);
    const hex = buf.toString('hex').match(/.{1,2}/g)?.join(' ') || '';
    return `[binary ${formatBytes(buf.length)}] ${truncate(hex, 100)}`;
  }
  const str = data.toString();
  try {
    const parsed = JSON.parse(str);
    return JSON.stringify(parsed, null, 2);
  } catch {
    return str;
  }
}

function log(connId, direction, type, data, extra = '') {
  const ts = timestamp();
  const isSend = direction === '→';

  if (FORMAT === 'json') {
    const entry = {
      timestamp: ts,
      connection: connId,
      direction: isSend ? 'client→server' : 'server→client',
      type,
      data: typeof data === 'string' ? data : data?.toString(),
      ...extra ? { extra } : {},
    };
    const line = JSON.stringify(entry);
    console.log(line);
    logStream.write(line + '\n');
    return;
  }

  if (FORMAT === 'compact') {
    const arrow = isSend ? '→' : '←';
    const shortData = typeof data === 'string' ? truncate(data, 80) : data;
    const line = `${ts} [${connId}] ${arrow} ${type}: ${shortData}`;
    console.log(isSend ? `${C.green}${line}${C.reset}` : `${C.blue}${line}${C.reset}`);
    logStream.write(line + '\n');
    return;
  }

  // text format (default)
  const arrow = isSend
    ? `${C.green}CLIENT → SERVER${C.reset}`
    : `${C.blue}SERVER → CLIENT${C.reset}`;
  const header = `${C.dim}${ts}${C.reset} ${C.yellow}[conn:${connId}]${C.reset} ${arrow} ${C.cyan}${type}${C.reset}`;

  console.log(header);
  if (data) {
    const formatted = typeof data === 'string' ? data : formatData(data, false);
    const lines = formatted.split('\n');
    lines.forEach(line => {
      console.log(`  ${C.dim}│${C.reset} ${line}`);
    });
  }
  if (extra) {
    console.log(`  ${C.dim}└ ${extra}${C.reset}`);
  }
  console.log('');
  logStream.write(`${ts} [conn:${connId}] ${direction} ${type}: ${data || ''}${extra ? ' ' + extra : ''}\n`);
}

// Create HTTP server for the proxy
const server = http.createServer((req, res) => {
  // Forward non-WebSocket requests
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      target: TARGET_URL,
      activeConnections: connectionCounter,
    }));
    return;
  }
  res.writeHead(404);
  res.end('WebSocket debug proxy — connect via WebSocket');
});

const wss = new WebSocket.Server({ server });

wss.on('connection', (clientWs, req) => {
  const connId = ++connectionCounter;
  const clientIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress;

  log(connId, '→', 'CONNECT', null,
    `from ${clientIp} | target: ${TARGET_URL}`);

  // Connect to target server
  const headers = {};
  // Forward relevant headers
  ['cookie', 'authorization', 'sec-websocket-protocol'].forEach(h => {
    if (req.headers[h]) headers[h] = req.headers[h];
  });

  const targetWs = new WebSocket(TARGET_URL, {
    headers,
    rejectUnauthorized: false, // for self-signed certs in dev
  });

  let clientClosed = false;
  let targetClosed = false;
  let messageCount = { clientToServer: 0, serverToClient: 0, bytes: 0 };

  targetWs.on('open', () => {
    log(connId, '←', 'TARGET_CONNECTED', null,
      `protocol: ${targetWs.protocol || 'none'}`);
  });

  // Client → Server
  clientWs.on('message', (data, isBinary) => {
    messageCount.clientToServer++;
    messageCount.bytes += data.length || Buffer.byteLength(data);

    const formatted = formatData(data, isBinary);
    log(connId, '→', isBinary ? 'BINARY' : 'TEXT', formatted,
      `size: ${formatBytes(data.length || Buffer.byteLength(data))} | msg #${messageCount.clientToServer}`);

    if (targetWs.readyState === WebSocket.OPEN) {
      targetWs.send(data, { binary: isBinary });
    }
  });

  // Server → Client
  targetWs.on('message', (data, isBinary) => {
    messageCount.serverToClient++;
    messageCount.bytes += data.length || Buffer.byteLength(data);

    const formatted = formatData(data, isBinary);
    log(connId, '←', isBinary ? 'BINARY' : 'TEXT', formatted,
      `size: ${formatBytes(data.length || Buffer.byteLength(data))} | msg #${messageCount.serverToClient}`);

    if (clientWs.readyState === WebSocket.OPEN) {
      clientWs.send(data, { binary: isBinary });
    }
  });

  // Forward pings/pongs
  clientWs.on('ping', (data) => {
    log(connId, '→', 'PING', formatBytes(data.length));
    if (targetWs.readyState === WebSocket.OPEN) targetWs.ping(data);
  });

  clientWs.on('pong', (data) => {
    log(connId, '→', 'PONG', formatBytes(data.length));
    if (targetWs.readyState === WebSocket.OPEN) targetWs.pong(data);
  });

  targetWs.on('ping', (data) => {
    log(connId, '←', 'PING', formatBytes(data.length));
    if (clientWs.readyState === WebSocket.OPEN) clientWs.ping(data);
  });

  targetWs.on('pong', (data) => {
    log(connId, '←', 'PONG', formatBytes(data.length));
    if (clientWs.readyState === WebSocket.OPEN) clientWs.pong(data);
  });

  // Handle close
  clientWs.on('close', (code, reason) => {
    clientClosed = true;
    log(connId, '→', 'CLOSE', null,
      `code: ${code} | reason: ${reason?.toString() || 'none'} | ` +
      `total: ${messageCount.clientToServer}↑ ${messageCount.serverToClient}↓ ${formatBytes(messageCount.bytes)}`);
    if (!targetClosed && targetWs.readyState === WebSocket.OPEN) {
      targetWs.close(code, reason);
    }
  });

  targetWs.on('close', (code, reason) => {
    targetClosed = true;
    log(connId, '←', 'CLOSE', null,
      `code: ${code} | reason: ${reason?.toString() || 'none'}`);
    if (!clientClosed && clientWs.readyState === WebSocket.OPEN) {
      clientWs.close(code, reason);
    }
  });

  // Handle errors
  clientWs.on('error', (err) => {
    log(connId, '→', 'ERROR', err.message);
  });

  targetWs.on('error', (err) => {
    log(connId, '←', 'ERROR', err.message);
    if (clientWs.readyState === WebSocket.OPEN) {
      clientWs.close(1011, 'Target connection error');
    }
  });
});

server.listen(LISTEN_PORT, () => {
  console.log(`${C.magenta}╔══════════════════════════════════════════════╗${C.reset}`);
  console.log(`${C.magenta}║       WebSocket Debug Proxy                  ║${C.reset}`);
  console.log(`${C.magenta}╠══════════════════════════════════════════════╣${C.reset}`);
  console.log(`${C.magenta}║${C.reset}  Listen:  ${C.green}ws://localhost:${LISTEN_PORT}${C.reset}`);
  console.log(`${C.magenta}║${C.reset}  Target:  ${C.blue}${TARGET_URL}${C.reset}`);
  console.log(`${C.magenta}║${C.reset}  Log:     ${C.yellow}${OUTPUT_FILE}${C.reset}`);
  console.log(`${C.magenta}║${C.reset}  Format:  ${FORMAT}`);
  console.log(`${C.magenta}╠══════════════════════════════════════════════╣${C.reset}`);
  console.log(`${C.magenta}║${C.reset}  Point your client to:                       ${C.magenta}║${C.reset}`);
  console.log(`${C.magenta}║${C.reset}    ${C.green}ws://localhost:${LISTEN_PORT}${C.reset}    (instead of target)  ${C.magenta}║${C.reset}`);
  console.log(`${C.magenta}║${C.reset}                                               ${C.magenta}║${C.reset}`);
  console.log(`${C.magenta}║${C.reset}  Press Ctrl+C to stop                         ${C.magenta}║${C.reset}`);
  console.log(`${C.magenta}╚══════════════════════════════════════════════╝${C.reset}`);
  console.log('');
});

// Graceful shutdown
process.on('SIGINT', () => {
  console.log(`\n${C.yellow}Shutting down proxy...${C.reset}`);
  wss.clients.forEach(ws => ws.close(1001, 'Proxy shutting down'));
  logStream.end();
  server.close(() => process.exit(0));
});
PROXYEOF

# Run the proxy
echo "Starting WebSocket debug proxy..."
LISTEN_PORT="$LISTEN_PORT" \
TARGET_URL="$TARGET_URL" \
OUTPUT_FILE="$OUTPUT_FILE" \
FORMAT="$FORMAT" \
USE_COLOR="$USE_COLOR" \
  node "$TMPDIR/proxy.js"
