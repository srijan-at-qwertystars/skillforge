#!/usr/bin/env bash
#
# find-slow-tests.sh — Identify slowest Jest tests and suggest optimizations
#
# Usage: ./find-slow-tests.sh [--top N] [--threshold MS] [-- jest-args...]
#   --top N         Show top N slowest suites (default: 10)
#   --threshold MS  Flag tests slower than MS milliseconds (default: 5000)
#   -- jest-args    Additional arguments passed to Jest
#
# Runs Jest with JSON output, parses timing data, and prints recommendations.

set -euo pipefail

TOP=10
THRESHOLD=5000
JEST_ARGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)       TOP="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    -h|--help)   head -11 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
    --)          shift; JEST_ARGS="$*"; break ;;
    *)           JEST_ARGS="$JEST_ARGS $1"; shift ;;
  esac
done

TMPFILE=$(mktemp /tmp/jest-results-XXXXXX.json)
trap 'rm -f "$TMPFILE"' EXIT

echo "⏱️  Running Jest with timing analysis..."
echo ""

# Run Jest with JSON output (allow failure — we still want timing data)
npx jest --json --outputFile="$TMPFILE" $JEST_ARGS 2>/dev/null || true

if [ ! -s "$TMPFILE" ]; then
  echo "❌ No test results found. Ensure Jest is configured correctly."
  exit 1
fi

# Parse and display results
node -e "
const fs = require('fs');
const results = JSON.parse(fs.readFileSync('$TMPFILE', 'utf8'));
const top = $TOP;
const threshold = $THRESHOLD;

// Suite-level timing
const suites = results.testResults.map(r => ({
  file: r.testFilePath.replace(process.cwd() + '/', ''),
  duration: (r.perfStats.end - r.perfStats.start),
  tests: r.testResults.length,
  failures: r.numFailingTests,
})).sort((a, b) => b.duration - a.duration);

console.log('━'.repeat(80));
console.log('📊 SLOWEST TEST SUITES (top ' + top + ')');
console.log('━'.repeat(80));
console.log('');
console.log('Duration    Tests  File');
console.log('─'.repeat(80));

suites.slice(0, top).forEach(s => {
  const dur = (s.duration / 1000).toFixed(1).padStart(7) + 's';
  const flag = s.duration > threshold ? ' ⚠️ ' : '   ';
  const tests = String(s.tests).padStart(5);
  console.log(dur + flag + tests + '  ' + s.file);
});

// Individual slow tests
const slowTests = [];
results.testResults.forEach(suite => {
  suite.testResults.forEach(t => {
    if (t.duration > threshold) {
      slowTests.push({
        name: t.fullName,
        duration: t.duration,
        file: suite.testFilePath.replace(process.cwd() + '/', ''),
      });
    }
  });
});
slowTests.sort((a, b) => b.duration - a.duration);

if (slowTests.length > 0) {
  console.log('');
  console.log('━'.repeat(80));
  console.log('🐌 INDIVIDUAL TESTS EXCEEDING ' + threshold + 'ms');
  console.log('━'.repeat(80));
  console.log('');
  slowTests.slice(0, top).forEach(t => {
    const dur = (t.duration / 1000).toFixed(1).padStart(7) + 's';
    console.log(dur + '  ' + t.name);
    console.log('         ' + t.file);
    console.log('');
  });
}

// Summary & recommendations
const totalDuration = suites.reduce((sum, s) => sum + s.duration, 0);
const totalTests = suites.reduce((sum, s) => sum + s.tests, 0);
const slowSuites = suites.filter(s => s.duration > threshold);

console.log('━'.repeat(80));
console.log('📋 SUMMARY');
console.log('━'.repeat(80));
console.log('  Total suites:      ' + suites.length);
console.log('  Total tests:       ' + totalTests);
console.log('  Total duration:    ' + (totalDuration / 1000).toFixed(1) + 's');
console.log('  Slow suites:       ' + slowSuites.length + ' (>' + threshold + 'ms)');
console.log('  Slow ind. tests:   ' + slowTests.length + ' (>' + threshold + 'ms)');
console.log('');

if (slowSuites.length > 0 || slowTests.length > 0) {
  console.log('💡 OPTIMIZATION SUGGESTIONS');
  console.log('─'.repeat(80));

  // Detect transformer
  const config = results.config || {};
  const transform = JSON.stringify(config.transform || {});
  if (transform.includes('ts-jest')) {
    console.log('  → Switch from ts-jest to @swc/jest for 2-5x faster transforms');
  }

  console.log('  → Use jest.useFakeTimers() for tests with delays/timeouts');
  console.log('  → Mock heavy I/O (network, filesystem) with jest.mock() or MSW');
  console.log('  → Move expensive setup from beforeEach to beforeAll');
  console.log('  → Use --shard flag for CI parallelism');
  console.log('  → Run with --runInBand to identify shared-state bottlenecks');
  console.log('  → Set workerIdleMemoryLimit to recycle leaky workers');
  console.log('');
}
" 2>/dev/null || {
  echo "❌ Failed to parse results. Ensure Node.js is available."
  exit 1
}
