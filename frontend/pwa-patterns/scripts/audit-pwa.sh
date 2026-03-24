#!/usr/bin/env bash
# audit-pwa.sh — Run Lighthouse PWA audit and parse results
#
# Usage: ./audit-pwa.sh <url> [output-dir]
#   url         URL to audit (must be accessible, HTTPS or localhost)
#   output-dir  Directory for report files (default: ./lighthouse-reports)
#
# Requires: Node.js and Lighthouse
# Install: npm install -g lighthouse
#          OR: npx lighthouse (used as fallback)
#
# Outputs: JSON report, summary to stdout, and identifies failing audits

set -euo pipefail

URL="${1:-}"
OUTPUT_DIR="${2:-./lighthouse-reports}"

if [ -z "$URL" ]; then
  echo "Usage: $0 <url> [output-dir]"
  echo ""
  echo "Examples:"
  echo "  $0 https://myapp.com"
  echo "  $0 http://localhost:3000 ./reports"
  exit 1
fi

# Find lighthouse
LH=""
if command -v lighthouse &>/dev/null; then
  LH="lighthouse"
else
  LH="npx --yes lighthouse"
fi

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
JSON_REPORT="$OUTPUT_DIR/pwa-audit-${TIMESTAMP}.json"
HTML_REPORT="$OUTPUT_DIR/pwa-audit-${TIMESTAMP}.html"

echo "🔍 Running Lighthouse PWA audit..."
echo "   URL: $URL"
echo "   Report: $JSON_REPORT"
echo ""

# Run Lighthouse
$LH "$URL" \
  --only-categories=pwa \
  --output=json,html \
  --output-path="$OUTPUT_DIR/pwa-audit-${TIMESTAMP}" \
  --chrome-flags="--headless --no-sandbox --disable-gpu" \
  --quiet 2>/dev/null || {
    echo "❌ Lighthouse failed. Ensure the URL is reachable and Chrome/Chromium is installed."
    echo "   For CI: apt install chromium-browser"
    exit 1
  }

# Rename outputs (Lighthouse appends format suffix)
if [ -f "$OUTPUT_DIR/pwa-audit-${TIMESTAMP}.report.json" ]; then
  mv "$OUTPUT_DIR/pwa-audit-${TIMESTAMP}.report.json" "$JSON_REPORT"
fi
if [ -f "$OUTPUT_DIR/pwa-audit-${TIMESTAMP}.report.html" ]; then
  mv "$OUTPUT_DIR/pwa-audit-${TIMESTAMP}.report.html" "$HTML_REPORT"
fi

echo "📊 PWA Audit Results"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check for required tools
if ! command -v node &>/dev/null; then
  echo "⚠️  Node.js not found — showing raw report location"
  echo "   JSON: $JSON_REPORT"
  echo "   HTML: $HTML_REPORT"
  exit 0
fi

# Parse results with Node.js
node -e "
const fs = require('fs');
const report = JSON.parse(fs.readFileSync('$JSON_REPORT', 'utf8'));
const pwa = report.categories?.pwa;

if (!pwa) {
  console.log('⚠️  No PWA category found in report');
  process.exit(1);
}

const score = Math.round((pwa.score || 0) * 100);
const icon = score >= 90 ? '🟢' : score >= 50 ? '🟡' : '🔴';
console.log(\"\n\" + icon + \" PWA Score: \" + score + \"/100\n\");

const passed = [];
const failed = [];
const manual = [];

for (const ref of pwa.auditRefs || []) {
  const audit = report.audits?.[ref.id];
  if (!audit) continue;

  if (ref.group === 'pwa-manual') {
    manual.push(audit);
  } else if (audit.score === 1) {
    passed.push(audit);
  } else {
    failed.push(audit);
  }
}

if (failed.length > 0) {
  console.log('❌ FAILING (' + failed.length + '):');
  for (const a of failed) {
    console.log('   • ' + a.title);
    if (a.description) {
      const desc = a.description.split('[')[0].trim().substring(0, 80);
      console.log('     ' + desc);
    }
  }
  console.log('');
}

if (passed.length > 0) {
  console.log('✅ PASSING (' + passed.length + '):');
  for (const a of passed) {
    console.log('   • ' + a.title);
  }
  console.log('');
}

if (manual.length > 0) {
  console.log('📋 MANUAL CHECKS (' + manual.length + '):');
  for (const a of manual) {
    console.log('   • ' + a.title);
  }
  console.log('');
}

console.log('📁 Full reports:');
console.log('   JSON: $JSON_REPORT');
console.log('   HTML: $HTML_REPORT');
"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
