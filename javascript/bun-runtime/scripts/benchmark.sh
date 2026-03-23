#!/usr/bin/env bash
#
# benchmark.sh — Run performance benchmarks comparing Bun vs Node.js.
#
# Usage:
#   ./benchmark.sh [--iterations N] [--only bun|node]
#
# Requires both `bun` and `node` to be installed (unless --only is used).
# Creates temporary benchmark scripts, runs them, and reports results.

set -euo pipefail

ITERATIONS=5
ONLY=""
TMPDIR=$(mktemp -d)

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

# ── Parse arguments ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)
      ITERATIONS="${2:-5}"
      shift 2
      ;;
    --only)
      ONLY="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--iterations N] [--only bun|node]"
      echo ""
      echo "Options:"
      echo "  --iterations N   Number of iterations per benchmark (default: 5)"
      echo "  --only bun|node  Only run benchmarks for one runtime"
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'"
      exit 1
      ;;
  esac
done

# ── Validate runtimes ────────────────────────────────────────────
if [[ "$ONLY" != "node" ]]; then
  if ! command -v bun &>/dev/null; then
    echo "Error: bun is not installed"
    exit 1
  fi
  BUN_VERSION=$(bun --version 2>/dev/null || echo "unknown")
fi

if [[ "$ONLY" != "bun" ]]; then
  if ! command -v node &>/dev/null; then
    echo "Error: node is not installed"
    exit 1
  fi
  NODE_VERSION=$(node --version 2>/dev/null || echo "unknown")
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Bun vs Node.js Benchmark Suite                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
[[ "$ONLY" != "node" ]] && echo "Bun version:  $BUN_VERSION"
[[ "$ONLY" != "bun" ]] && echo "Node version: $NODE_VERSION"
echo "Iterations:   $ITERATIONS"
echo ""

# ── Benchmark scripts ────────────────────────────────────────────

# 1. Startup time (hello world)
cat > "$TMPDIR/startup.js" <<'EOF'
console.log("hello");
EOF

# 2. JSON serialization
cat > "$TMPDIR/json.js" <<'EOF'
const data = Array.from({ length: 10000 }, (_, i) => ({
  id: i,
  name: `user-${i}`,
  email: `user${i}@example.com`,
  active: i % 2 === 0,
  scores: [Math.random(), Math.random(), Math.random()],
}));
const iterations = 100;
const start = performance.now();
for (let i = 0; i < iterations; i++) {
  const json = JSON.stringify(data);
  JSON.parse(json);
}
const elapsed = performance.now() - start;
console.log(elapsed.toFixed(2));
EOF

# 3. File I/O
cat > "$TMPDIR/fileio.js" <<'EOF'
const fs = require("fs");
const path = require("path");
const tmpFile = path.join(require("os").tmpdir(), `bench-${process.pid}.txt`);
const data = "x".repeat(1024 * 1024); // 1 MB
const iterations = 50;
const start = performance.now();
for (let i = 0; i < iterations; i++) {
  fs.writeFileSync(tmpFile, data);
  fs.readFileSync(tmpFile, "utf-8");
}
const elapsed = performance.now() - start;
fs.unlinkSync(tmpFile);
console.log(elapsed.toFixed(2));
EOF

# 4. Crypto hashing
cat > "$TMPDIR/crypto.js" <<'EOF'
const crypto = require("crypto");
const data = "benchmark-data-".repeat(1000);
const iterations = 5000;
const start = performance.now();
for (let i = 0; i < iterations; i++) {
  crypto.createHash("sha256").update(data).digest("hex");
}
const elapsed = performance.now() - start;
console.log(elapsed.toFixed(2));
EOF

# 5. HTTP server throughput (start server, measure requests)
cat > "$TMPDIR/http-server-bun.ts" <<'EOF'
const server = Bun.serve({
  port: 0,
  fetch() {
    return Response.json({ ok: true });
  },
});
const url = `http://localhost:${server.port}`;
const N = 1000;
const start = performance.now();
for (let i = 0; i < N; i++) {
  await fetch(url);
}
const elapsed = performance.now() - start;
server.stop();
console.log(elapsed.toFixed(2));
EOF

cat > "$TMPDIR/http-server-node.js" <<'EOF'
const http = require("http");
const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ ok: true }));
});
server.listen(0, async () => {
  const port = server.address().port;
  const N = 1000;
  const start = performance.now();
  for (let i = 0; i < N; i++) {
    await fetch(`http://localhost:${port}`);
  }
  const elapsed = performance.now() - start;
  server.close();
  console.log(elapsed.toFixed(2));
});
EOF

# ── Runner ───────────────────────────────────────────────────────
run_benchmark() {
  local runtime="$1"
  local script="$2"
  local times=()

  for i in $(seq 1 "$ITERATIONS"); do
    local result
    if [[ "$runtime" == "bun" ]]; then
      result=$( { bun "$script" 2>/dev/null || echo "ERROR"; } )
    else
      result=$( { node "$script" 2>/dev/null || echo "ERROR"; } )
    fi
    if [[ "$result" == "ERROR" ]]; then
      echo "ERR"
      return
    fi
    times+=("$result")
  done

  # Calculate median
  local sorted
  sorted=$(printf '%s\n' "${times[@]}" | sort -n)
  local mid=$((ITERATIONS / 2))
  local median
  median=$(echo "$sorted" | sed -n "$((mid + 1))p")
  echo "$median"
}

format_result() {
  local name="$1"
  local bun_ms="$2"
  local node_ms="$3"

  printf "%-25s" "$name"

  if [[ "$bun_ms" == "ERR" || "$bun_ms" == "SKIP" ]]; then
    printf "%12s" "$bun_ms"
  else
    printf "%10s ms" "$bun_ms"
  fi

  if [[ "$node_ms" == "ERR" || "$node_ms" == "SKIP" ]]; then
    printf "%12s" "$node_ms"
  else
    printf "%10s ms" "$node_ms"
  fi

  if [[ "$bun_ms" != "ERR" && "$bun_ms" != "SKIP" && "$node_ms" != "ERR" && "$node_ms" != "SKIP" ]]; then
    local ratio
    ratio=$(echo "scale=2; $node_ms / $bun_ms" | bc 2>/dev/null || echo "N/A")
    if [[ "$ratio" != "N/A" ]]; then
      printf "%10sx" "$ratio"
    fi
  fi

  echo ""
}

# ── Run benchmarks ───────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-25s%12s%12s%10s\n" "Benchmark" "Bun" "Node.js" "Speedup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Startup
echo -n "Running: Startup..."
if [[ "$ONLY" != "node" ]]; then
  BUN_STARTUP=$( { time bun "$TMPDIR/startup.js" >/dev/null 2>&1; } 2>&1 | grep real | sed 's/[^0-9.]//g' || echo "ERR" )
  BUN_STARTUP_MS=$(echo "$BUN_STARTUP * 1000" | bc 2>/dev/null || echo "ERR")
else
  BUN_STARTUP_MS="SKIP"
fi
if [[ "$ONLY" != "bun" ]]; then
  NODE_STARTUP=$( { time node "$TMPDIR/startup.js" >/dev/null 2>&1; } 2>&1 | grep real | sed 's/[^0-9.]//g' || echo "ERR" )
  NODE_STARTUP_MS=$(echo "$NODE_STARTUP * 1000" | bc 2>/dev/null || echo "ERR")
else
  NODE_STARTUP_MS="SKIP"
fi
echo -ne "\r"
format_result "Startup (hello world)" "$BUN_STARTUP_MS" "$NODE_STARTUP_MS"

# JSON
echo -n "Running: JSON..."
BUN_JSON="SKIP"; NODE_JSON="SKIP"
[[ "$ONLY" != "node" ]] && BUN_JSON=$(run_benchmark bun "$TMPDIR/json.js")
[[ "$ONLY" != "bun" ]] && NODE_JSON=$(run_benchmark node "$TMPDIR/json.js")
echo -ne "\r"
format_result "JSON (10k objects x100)" "$BUN_JSON" "$NODE_JSON"

# File I/O
echo -n "Running: File I/O..."
BUN_FILE="SKIP"; NODE_FILE="SKIP"
[[ "$ONLY" != "node" ]] && BUN_FILE=$(run_benchmark bun "$TMPDIR/fileio.js")
[[ "$ONLY" != "bun" ]] && NODE_FILE=$(run_benchmark node "$TMPDIR/fileio.js")
echo -ne "\r"
format_result "File I/O (1MB x50)" "$BUN_FILE" "$NODE_FILE"

# Crypto
echo -n "Running: Crypto..."
BUN_CRYPTO="SKIP"; NODE_CRYPTO="SKIP"
[[ "$ONLY" != "node" ]] && BUN_CRYPTO=$(run_benchmark bun "$TMPDIR/crypto.js")
[[ "$ONLY" != "bun" ]] && NODE_CRYPTO=$(run_benchmark node "$TMPDIR/crypto.js")
echo -ne "\r"
format_result "SHA-256 (x5000)" "$BUN_CRYPTO" "$NODE_CRYPTO"

# HTTP
echo -n "Running: HTTP..."
BUN_HTTP="SKIP"; NODE_HTTP="SKIP"
[[ "$ONLY" != "node" ]] && BUN_HTTP=$(run_benchmark bun "$TMPDIR/http-server-bun.ts")
[[ "$ONLY" != "bun" ]] && NODE_HTTP=$(run_benchmark node "$TMPDIR/http-server-node.js")
echo -ne "\r"
format_result "HTTP (1k requests)" "$BUN_HTTP" "$NODE_HTTP"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Note: Results are median of $ITERATIONS runs. Lower is better."
echo "Speedup = Node.js time / Bun time (higher = Bun is faster)."
echo ""
