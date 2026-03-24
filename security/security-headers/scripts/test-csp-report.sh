#!/usr/bin/env bash
#
# test-csp-report.sh — Set up a CSP reporting endpoint for testing
#
# Usage:
#   ./test-csp-report.sh                  # Start on default port 3100
#   ./test-csp-report.sh --port 8080      # Start on custom port
#   ./test-csp-report.sh --log-file /tmp/csp-reports.json  # Log to file
#
# Creates an Express server that receives and logs CSP violation reports.
# Useful for testing CSP in report-only mode during development.
#
# Prerequisites:
#   Node.js >= 16
#
# CSP header to point at this server:
#   Content-Security-Policy-Report-Only: default-src 'self'; report-uri http://localhost:3100/csp-report
#

set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# --- Parse args ---
PORT=3100
LOG_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--port PORT] [--log-file PATH]"
      echo ""
      echo "Starts a local CSP violation report collection server."
      echo ""
      echo "Options:"
      echo "  --port PORT        Port to listen on (default: 3100)"
      echo "  --log-file PATH    Also write reports to a JSON file"
      echo "  -h, --help         Show this help message"
      echo ""
      echo "Point your CSP report-uri at:"
      echo "  report-uri http://localhost:PORT/csp-report"
      echo ""
      echo "Or use the Reporting API:"
      echo "  Report-To: {\"group\":\"csp\",\"endpoints\":[{\"url\":\"http://localhost:PORT/csp-report\"}]}"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Check Node.js ---
if ! command -v node &>/dev/null; then
  echo -e "${RED}Error: Node.js is required but not found.${NC}"
  echo "Install Node.js from https://nodejs.org"
  exit 1
fi

NODE_VERSION=$(node -v | grep -oP '\d+' | head -1)
if [[ "$NODE_VERSION" -lt 16 ]]; then
  echo -e "${RED}Error: Node.js >= 16 required, found $(node -v)${NC}"
  exit 1
fi

# --- Create temp directory ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Write server script ---
LOG_FILE_JS="null"
if [[ -n "$LOG_FILE" ]]; then
  LOG_FILE_JS="\"$LOG_FILE\""
fi

cat > "$TMPDIR/server.js" << 'SERVEREOF'
const http = require('http');
const fs = require('fs');

const PORT = parseInt(process.env.CSP_PORT || '3100', 10);
const LOG_FILE = process.env.CSP_LOG_FILE || null;

const COLORS = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  cyan: '\x1b[36m',
  dim: '\x1b[2m',
};

let reportCount = 0;

function formatReport(report) {
  // Handle both report-uri and report-to formats
  const body = report['csp-report'] || report.body || report;
  const lines = [];

  lines.push(`${COLORS.bold}${COLORS.cyan}━━━ CSP Violation Report #${++reportCount} ━━━${COLORS.reset}`);
  lines.push(`${COLORS.dim}${new Date().toISOString()}${COLORS.reset}`);
  lines.push('');

  const fields = [
    ['Document URL', body['document-uri'] || body.documentURL],
    ['Violated Directive', body['violated-directive'] || body.violatedDirective],
    ['Effective Directive', body['effective-directive'] || body.effectiveDirective],
    ['Blocked URI', body['blocked-uri'] || body.blockedURL],
    ['Source File', body['source-file'] || body.sourceFile],
    ['Line/Column', (body['line-number'] || body.lineNumber) ?
      `${body['line-number'] || body.lineNumber}:${body['column-number'] || body.columnNumber}` : null],
    ['Status Code', body['status-code'] || body.statusCode],
    ['Disposition', body.disposition],
    ['Sample', body['script-sample'] || body.sample],
  ];

  for (const [label, value] of fields) {
    if (value !== null && value !== undefined && value !== '') {
      const color = label === 'Blocked URI' ? COLORS.red :
                    label === 'Violated Directive' ? COLORS.yellow : '';
      lines.push(`  ${COLORS.bold}${label}:${COLORS.reset} ${color}${value}${COLORS.reset}`);
    }
  }

  // Show a simplified original policy
  const policy = body['original-policy'] || body.originalPolicy;
  if (policy) {
    const truncated = policy.length > 120 ? policy.substring(0, 120) + '...' : policy;
    lines.push(`  ${COLORS.bold}Policy:${COLORS.reset} ${COLORS.dim}${truncated}${COLORS.reset}`);
  }

  lines.push('');
  return lines.join('\n');
}

function isNoise(report) {
  const body = report['csp-report'] || report.body || report;
  const blocked = body['blocked-uri'] || body.blockedURL || '';
  const noisePatterns = [
    /^(chrome|moz|safari|ms-browser)-extension:\/\//,
    /^about:/,
    /webkit-masked-url/,
  ];
  return noisePatterns.some(p => p.test(blocked));
}

const server = http.createServer((req, res) => {
  // CORS headers for cross-origin reporting
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.method === 'GET' && req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(`
      <html><body style="font-family: monospace; padding: 2rem;">
        <h2>CSP Report Collector</h2>
        <p>Reports received: <strong>${reportCount}</strong></p>
        <p>POST violations to: <code>http://localhost:${PORT}/csp-report</code></p>
        <h3>CSP Header to use:</h3>
        <pre>Content-Security-Policy-Report-Only: default-src 'self'; report-uri http://localhost:${PORT}/csp-report</pre>
        <h3>Reporting API header:</h3>
        <pre>Report-To: {"group":"csp","max_age":86400,"endpoints":[{"url":"http://localhost:${PORT}/csp-report"}]}</pre>
      </body></html>
    `);
    return;
  }

  if (req.method === 'GET' && req.url === '/stats') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ reports_received: reportCount }));
    return;
  }

  if (req.method === 'POST' && (req.url === '/csp-report' || req.url === '/csp-reports')) {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      res.writeHead(204);
      res.end();

      try {
        let reports;
        const parsed = JSON.parse(body);

        // Handle Reporting API (array) vs report-uri (single object)
        if (Array.isArray(parsed)) {
          reports = parsed;
        } else {
          reports = [parsed];
        }

        for (const report of reports) {
          if (isNoise(report)) {
            process.stdout.write(`${COLORS.dim}[noise] Extension/about: report filtered${COLORS.reset}\n`);
            continue;
          }

          console.log(formatReport(report));

          // Log to file if configured
          if (LOG_FILE) {
            const logEntry = JSON.stringify({
              timestamp: new Date().toISOString(),
              report,
            }) + '\n';
            fs.appendFileSync(LOG_FILE, logEntry);
          }
        }
      } catch (err) {
        console.error(`${COLORS.red}Failed to parse report:${COLORS.reset}`, err.message);
        console.error(`${COLORS.dim}Raw body: ${body.substring(0, 500)}${COLORS.reset}`);
      }
    });
    return;
  }

  res.writeHead(404);
  res.end('Not found');
});

server.listen(PORT, () => {
  console.log(`${COLORS.green}${COLORS.bold}╔════════════════════════════════════════════════════╗${COLORS.reset}`);
  console.log(`${COLORS.green}${COLORS.bold}║  CSP Report Collector running on port ${PORT}        ║${COLORS.reset}`);
  console.log(`${COLORS.green}${COLORS.bold}╚════════════════════════════════════════════════════╝${COLORS.reset}`);
  console.log('');
  console.log(`${COLORS.cyan}Report endpoint:${COLORS.reset} http://localhost:${PORT}/csp-report`);
  console.log(`${COLORS.cyan}Dashboard:${COLORS.reset}       http://localhost:${PORT}/`);
  console.log(`${COLORS.cyan}Stats:${COLORS.reset}           http://localhost:${PORT}/stats`);
  if (LOG_FILE) {
    console.log(`${COLORS.cyan}Log file:${COLORS.reset}        ${LOG_FILE}`);
  }
  console.log('');
  console.log(`${COLORS.yellow}Add to your CSP header:${COLORS.reset}`);
  console.log(`  report-uri http://localhost:${PORT}/csp-report`);
  console.log('');
  console.log(`${COLORS.yellow}Or use the Reporting API:${COLORS.reset}`);
  console.log(`  Report-To: {"group":"csp","max_age":86400,"endpoints":[{"url":"http://localhost:${PORT}/csp-report"}]}`);
  console.log('');
  console.log(`${COLORS.dim}Press Ctrl+C to stop${COLORS.reset}`);
  console.log('');
  console.log('Waiting for CSP violation reports...');
  console.log('');
});
SERVEREOF

# --- Start server ---
echo -e "${BOLD}Starting CSP Report Collector...${NC}"
echo ""

CSP_PORT="$PORT" CSP_LOG_FILE="${LOG_FILE}" exec node "$TMPDIR/server.js"
