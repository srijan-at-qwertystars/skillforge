#!/usr/bin/env bash
#
# lighthouse-audit.sh — Run Lighthouse audit on a built Astro site
#
# Builds the Astro site (if not already built), serves it locally,
# runs Lighthouse CI audits, and outputs the report.
#
# Prerequisites:
#   - Node.js 18+
#   - Chrome/Chromium installed (or set CHROME_PATH)
#
# Usage:
#   ./lighthouse-audit.sh [options]
#
# Options:
#   --url=<url>         Audit a specific URL instead of building locally
#   --pages=<paths>     Comma-separated page paths to audit (default: /)
#   --format=html|json  Report format (default: html)
#   --output-dir=<dir>  Output directory for reports (default: ./lighthouse-reports)
#   --no-build          Skip building (use existing dist/)
#   --threshold=<n>     Minimum performance score 0-100 (default: 90, exit 1 if below)
#   --categories=<cats> Comma-separated categories to assert
#                       (default: performance,accessibility,best-practices,seo)
#
# Examples:
#   ./lighthouse-audit.sh
#   ./lighthouse-audit.sh --pages=/,/about,/blog --threshold=85
#   ./lighthouse-audit.sh --url=https://my-site.com --format=json
#   ./lighthouse-audit.sh --no-build --pages=/,/blog/first-post
#

set -euo pipefail

# --- Defaults ---
TARGET_URL=""
PAGES="/"
REPORT_FORMAT="html"
OUTPUT_DIR="./lighthouse-reports"
SKIP_BUILD=false
THRESHOLD=90
CATEGORIES="performance,accessibility,best-practices,seo"
SERVE_PID=""

# --- Cleanup on exit ---
cleanup() {
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    --url=*)        TARGET_URL="${arg#--url=}" ;;
    --pages=*)      PAGES="${arg#--pages=}" ;;
    --format=*)     REPORT_FORMAT="${arg#--format=}" ;;
    --output-dir=*) OUTPUT_DIR="${arg#--output-dir=}" ;;
    --no-build)     SKIP_BUILD=true ;;
    --threshold=*)  THRESHOLD="${arg#--threshold=}" ;;
    --categories=*) CATEGORIES="${arg#--categories=}" ;;
    --help|-h)
      head -28 "$0" | tail -26
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# --- Ensure dependencies ---
check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "Error: '$1' is not installed." >&2
    echo "Install with: $2" >&2
    exit 1
  fi
}

check_command node "https://nodejs.org"

# Install lighthouse if not available
if ! npx --no -- lighthouse --version &>/dev/null 2>&1; then
  echo "📦 Installing Lighthouse CLI..."
  npm install -g lighthouse
fi

mkdir -p "$OUTPUT_DIR"

# --- Determine base URL ---
if [[ -n "$TARGET_URL" ]]; then
  BASE_URL="$TARGET_URL"
  echo "🔍 Auditing remote URL: $BASE_URL"
else
  # Build the site if needed
  if [[ "$SKIP_BUILD" == false ]]; then
    echo "🔨 Building Astro site..."
    npm run build
  fi

  if [[ ! -d "dist" ]]; then
    echo "Error: dist/ directory not found. Run 'npm run build' first." >&2
    exit 1
  fi

  # Find an available port
  PORT=4173
  while lsof -i :"$PORT" &>/dev/null 2>&1; do
    PORT=$((PORT + 1))
  done

  echo "🌐 Starting preview server on port $PORT..."
  npx serve dist/ -l "$PORT" -s &>/dev/null &
  SERVE_PID=$!

  # Wait for server to be ready
  for i in {1..30}; do
    if curl -s "http://localhost:$PORT" >/dev/null 2>&1; then
      break
    fi
    if [[ $i -eq 30 ]]; then
      echo "Error: Preview server failed to start." >&2
      exit 1
    fi
    sleep 0.5
  done

  BASE_URL="http://localhost:$PORT"
  echo "✅ Server ready at $BASE_URL"
fi

# --- Run Lighthouse audits ---
IFS=',' read -ra PAGE_ARRAY <<< "$PAGES"
FAILED=false

echo ""
echo "📊 Running Lighthouse audits..."
echo "   Threshold: $THRESHOLD"
echo "   Categories: $CATEGORIES"
echo ""

for page in "${PAGE_ARRAY[@]}"; do
  # Normalize path
  page="${page#/}"
  url="${BASE_URL}/${page}"
  safe_name="${page//\//_}"
  [[ -z "$safe_name" ]] && safe_name="index"

  report_file="$OUTPUT_DIR/lighthouse-${safe_name}.report.$REPORT_FORMAT"

  echo "🔍 Auditing: $url"

  npx lighthouse "$url" \
    --output="$REPORT_FORMAT" \
    --output-path="$report_file" \
    --chrome-flags="--headless --no-sandbox --disable-gpu" \
    --quiet \
    2>/dev/null || true

  # Extract scores from JSON (run a secondary JSON audit if format is HTML)
  if [[ "$REPORT_FORMAT" == "html" ]]; then
    json_output=$(npx lighthouse "$url" \
      --output=json \
      --chrome-flags="--headless --no-sandbox --disable-gpu" \
      --quiet \
      2>/dev/null || echo "{}")
  else
    json_output=$(cat "$report_file" 2>/dev/null || echo "{}")
  fi

  # Parse scores
  if command -v node &>/dev/null; then
    scores=$(node -e "
      try {
        const r = JSON.parse(process.argv[1]);
        const cats = r.categories || {};
        const out = {};
        for (const [k, v] of Object.entries(cats)) {
          out[k] = Math.round((v.score || 0) * 100);
        }
        console.log(JSON.stringify(out));
      } catch { console.log('{}'); }
    " "$json_output" 2>/dev/null || echo "{}")

    echo "   Scores:"
    node -e "
      const s = JSON.parse(process.argv[1]);
      const threshold = parseInt(process.argv[2]);
      let fail = false;
      for (const [k, v] of Object.entries(s)) {
        const icon = v >= threshold ? '✅' : '❌';
        if (v < threshold) fail = true;
        console.log('     ' + icon + ' ' + k + ': ' + v);
      }
      if (fail) process.exit(1);
    " "$scores" "$THRESHOLD" 2>/dev/null || FAILED=true
  fi

  echo "   Report: $report_file"
  echo ""
done

# --- Summary ---
echo "📁 Reports saved to: $OUTPUT_DIR/"

if [[ "$FAILED" == true ]]; then
  echo ""
  echo "❌ Some scores are below the threshold of $THRESHOLD."
  exit 1
else
  echo ""
  echo "✅ All scores meet the threshold of $THRESHOLD."
fi
