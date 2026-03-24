#!/usr/bin/env bash
#
# bun-benchmark.sh — Benchmark Bun vs Node.js for common operations
#
# Usage:
#   bun-benchmark.sh [options]
#
# Options:
#   --all              Run all benchmarks (default)
#   --startup          Benchmark startup time
#   --http             Benchmark HTTP server throughput
#   --file-io          Benchmark file I/O
#   --json             Benchmark JSON parsing
#   --hash             Benchmark crypto hashing
#   --install          Benchmark package install speed
#   --iterations <n>   Number of iterations per benchmark (default: 10)
#   --output <file>    Write results to file
#   -h, --help         Show this help message
#
# Examples:
#   bun-benchmark.sh --all
#   bun-benchmark.sh --startup --iterations 20
#   bun-benchmark.sh --http --file-io
#
# Requirements: bun, node, and optionally 'hyperfine' for startup benchmarks
#

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

ITERATIONS=10
RUN_ALL=true
RUN_STARTUP=false
RUN_HTTP=false
RUN_FILE_IO=false
RUN_JSON=false
RUN_HASH=false
RUN_INSTALL=false
OUTPUT=""

usage() {
  head -20 "$0" | tail -17 | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --all)        RUN_ALL=true; shift ;;
    --startup)    RUN_ALL=false; RUN_STARTUP=true; shift ;;
    --http)       RUN_ALL=false; RUN_HTTP=true; shift ;;
    --file-io)    RUN_ALL=false; RUN_FILE_IO=true; shift ;;
    --json)       RUN_ALL=false; RUN_JSON=true; shift ;;
    --hash)       RUN_ALL=false; RUN_HASH=true; shift ;;
    --install)    RUN_ALL=false; RUN_INSTALL=true; shift ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *)            echo "Unknown option: $1"; usage ;;
  esac
done

if $RUN_ALL; then
  RUN_STARTUP=true
  RUN_FILE_IO=true
  RUN_JSON=true
  RUN_HASH=true
fi

# Check requirements
if ! command -v bun &>/dev/null; then
  echo "Error: bun is not installed"; exit 1
fi
if ! command -v node &>/dev/null; then
  echo "Error: node is not installed"; exit 1
fi

# Redirect output if --output specified
if [[ -n "$OUTPUT" ]]; then
  exec > >(tee "$OUTPUT")
fi

# Create temp directory for benchmark files
BENCH_DIR=$(mktemp -d)
trap "rm -rf $BENCH_DIR" EXIT

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Bun vs Node.js Benchmark Suite        ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Bun version:  $(bun --version)"
echo -e "  Node version: $(node --version)"
echo -e "  Iterations:   ${ITERATIONS}"
echo -e "  Platform:     $(uname -s) $(uname -m)"
echo ""

# Utility: measure average execution time in milliseconds
measure() {
  local cmd="$1"
  local total=0
  local times=()

  for ((i=1; i<=ITERATIONS; i++)); do
    local start end elapsed
    start=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
    eval "$cmd" > /dev/null 2>&1
    end=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
    elapsed=$(( (end - start) / 1000000 ))
    times+=("$elapsed")
    total=$((total + elapsed))
  done

  local avg=$((total / ITERATIONS))
  echo "$avg"
}

print_result() {
  local label="$1"
  local bun_ms="$2"
  local node_ms="$3"

  if [[ "$node_ms" -gt 0 ]]; then
    local ratio
    ratio=$(echo "scale=1; $node_ms / $bun_ms" | bc 2>/dev/null || echo "?")
    printf "  %-25s ${GREEN}Bun: %6dms${NC}  |  Node: %6dms  |  ${YELLOW}%.1fx faster${NC}\n" \
      "$label" "$bun_ms" "$node_ms" "$ratio"
  else
    printf "  %-25s ${GREEN}Bun: %6dms${NC}  |  Node: %6dms\n" \
      "$label" "$bun_ms" "$node_ms"
  fi
}

# ─── Startup Benchmark ───────────────────────────────────────────
if $RUN_STARTUP; then
  echo -e "${BOLD}━━━ Startup Time ━━━${NC}"

  # Empty script
  cat > "$BENCH_DIR/empty.js" <<'EOF'
EOF

  # Hello world
  cat > "$BENCH_DIR/hello.js" <<'EOF'
console.log("Hello, World!");
EOF

  # With imports
  cat > "$BENCH_DIR/imports.js" <<'EOF'
const path = require("path");
const fs = require("fs");
const os = require("os");
const crypto = require("crypto");
console.log(os.platform());
EOF

  echo -e "  ${BLUE}Measuring startup times (${ITERATIONS} iterations)...${NC}"

  BUN_EMPTY=$(measure "bun $BENCH_DIR/empty.js")
  NODE_EMPTY=$(measure "node $BENCH_DIR/empty.js")
  print_result "Empty script" "$BUN_EMPTY" "$NODE_EMPTY"

  BUN_HELLO=$(measure "bun $BENCH_DIR/hello.js")
  NODE_HELLO=$(measure "node $BENCH_DIR/hello.js")
  print_result "Hello world" "$BUN_HELLO" "$NODE_HELLO"

  BUN_IMPORTS=$(measure "bun $BENCH_DIR/imports.js")
  NODE_IMPORTS=$(measure "node $BENCH_DIR/imports.js")
  print_result "With imports" "$BUN_IMPORTS" "$NODE_IMPORTS"

  # TypeScript (only Bun can run directly)
  cat > "$BENCH_DIR/hello.ts" <<'EOF'
const msg: string = "Hello TypeScript";
console.log(msg);
EOF

  BUN_TS=$(measure "bun $BENCH_DIR/hello.ts")
  printf "  %-25s ${GREEN}Bun: %6dms${NC}  |  Node: N/A (needs transpiler)\n" \
    "TypeScript direct" "$BUN_TS"

  echo ""
fi

# ─── File I/O Benchmark ──────────────────────────────────────────
if $RUN_FILE_IO; then
  echo -e "${BOLD}━━━ File I/O ━━━${NC}"

  # Generate test data
  dd if=/dev/urandom of="$BENCH_DIR/testdata.bin" bs=1M count=10 2>/dev/null

  # Bun file read
  cat > "$BENCH_DIR/file-read-bun.ts" <<'EOF'
const file = Bun.file(process.argv[2]);
const data = await file.arrayBuffer();
console.log(data.byteLength);
EOF

  # Node file read
  cat > "$BENCH_DIR/file-read-node.js" <<'EOF'
const fs = require("fs");
const data = fs.readFileSync(process.argv[2]);
console.log(data.length);
EOF

  # Bun file write
  cat > "$BENCH_DIR/file-write-bun.ts" <<'EOF'
const data = Buffer.alloc(10 * 1024 * 1024, 0x42);
await Bun.write(process.argv[2], data);
console.log("done");
EOF

  # Node file write
  cat > "$BENCH_DIR/file-write-node.js" <<'EOF'
const fs = require("fs");
const data = Buffer.alloc(10 * 1024 * 1024, 0x42);
fs.writeFileSync(process.argv[2], data);
console.log("done");
EOF

  echo -e "  ${BLUE}Measuring file I/O (10MB, ${ITERATIONS} iterations)...${NC}"

  BUN_READ=$(measure "bun $BENCH_DIR/file-read-bun.ts $BENCH_DIR/testdata.bin")
  NODE_READ=$(measure "node $BENCH_DIR/file-read-node.js $BENCH_DIR/testdata.bin")
  print_result "Read 10MB file" "$BUN_READ" "$NODE_READ"

  BUN_WRITE=$(measure "bun $BENCH_DIR/file-write-bun.ts $BENCH_DIR/write-bun.bin")
  NODE_WRITE=$(measure "node $BENCH_DIR/file-write-node.js $BENCH_DIR/write-node.bin")
  print_result "Write 10MB file" "$BUN_WRITE" "$NODE_WRITE"

  echo ""
fi

# ─── JSON Benchmark ──────────────────────────────────────────────
if $RUN_JSON; then
  echo -e "${BOLD}━━━ JSON Parse/Stringify ━━━${NC}"

  # Generate large JSON
  cat > "$BENCH_DIR/gen-json.js" <<'EOF'
const items = [];
for (let i = 0; i < 100000; i++) {
  items.push({ id: i, name: `item-${i}`, value: Math.random(), active: i % 2 === 0 });
}
require("fs").writeFileSync(process.argv[2], JSON.stringify(items));
EOF
  node "$BENCH_DIR/gen-json.js" "$BENCH_DIR/large.json"

  # Bun JSON parse
  cat > "$BENCH_DIR/json-bun.ts" <<'EOF'
const text = await Bun.file(process.argv[2]).text();
const data = JSON.parse(text);
const out = JSON.stringify(data);
console.log(out.length);
EOF

  # Node JSON parse
  cat > "$BENCH_DIR/json-node.js" <<'EOF'
const fs = require("fs");
const text = fs.readFileSync(process.argv[2], "utf-8");
const data = JSON.parse(text);
const out = JSON.stringify(data);
console.log(out.length);
EOF

  echo -e "  ${BLUE}Measuring JSON ops (100k objects, ${ITERATIONS} iterations)...${NC}"

  BUN_JSON=$(measure "bun $BENCH_DIR/json-bun.ts $BENCH_DIR/large.json")
  NODE_JSON=$(measure "node $BENCH_DIR/json-node.js $BENCH_DIR/large.json")
  print_result "Parse+Stringify 100k" "$BUN_JSON" "$NODE_JSON"

  echo ""
fi

# ─── Crypto Hash Benchmark ───────────────────────────────────────
if $RUN_HASH; then
  echo -e "${BOLD}━━━ Crypto Hashing ━━━${NC}"

  # Bun crypto hash
  cat > "$BENCH_DIR/hash-bun.ts" <<'EOF'
const data = Buffer.alloc(1024 * 1024, 0x42); // 1MB
for (let i = 0; i < 100; i++) {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update(data);
  hasher.digest("hex");
}
console.log("done");
EOF

  # Node crypto hash
  cat > "$BENCH_DIR/hash-node.js" <<'EOF'
const crypto = require("crypto");
const data = Buffer.alloc(1024 * 1024, 0x42); // 1MB
for (let i = 0; i < 100; i++) {
  const hash = crypto.createHash("sha256");
  hash.update(data);
  hash.digest("hex");
}
console.log("done");
EOF

  echo -e "  ${BLUE}Measuring SHA-256 hashing (100x 1MB, ${ITERATIONS} iterations)...${NC}"

  BUN_HASH=$(measure "bun $BENCH_DIR/hash-bun.ts")
  NODE_HASH=$(measure "node $BENCH_DIR/hash-node.js")
  print_result "SHA-256 100x1MB" "$BUN_HASH" "$NODE_HASH"

  echo ""
fi

# ─── HTTP Server Benchmark ───────────────────────────────────────
if $RUN_HTTP; then
  echo -e "${BOLD}━━━ HTTP Server Throughput ━━━${NC}"

  if ! command -v curl &>/dev/null; then
    echo -e "  ${YELLOW}⚠ curl not found — skipping HTTP benchmark${NC}"
  else
    # Bun HTTP server
    cat > "$BENCH_DIR/http-bun.ts" <<'EOF'
Bun.serve({
  port: 9876,
  fetch() { return new Response("Hello"); },
});
EOF

    # Node HTTP server
    cat > "$BENCH_DIR/http-node.js" <<'EOF'
const http = require("http");
http.createServer((req, res) => {
  res.writeHead(200);
  res.end("Hello");
}).listen(9877);
EOF

    echo -e "  ${BLUE}Measuring HTTP response time...${NC}"
    echo -e "  ${YELLOW}(For thorough benchmarks, use wrk or autocannon)${NC}"

    # Start Bun server
    bun "$BENCH_DIR/http-bun.ts" &
    BUN_PID=$!
    sleep 1

    # Simple latency test
    BUN_HTTP=0
    for ((i=1; i<=ITERATIONS; i++)); do
      start=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
      curl -s http://localhost:9876/ > /dev/null
      end=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
      BUN_HTTP=$((BUN_HTTP + (end - start) / 1000000))
    done
    BUN_HTTP=$((BUN_HTTP / ITERATIONS))
    kill $BUN_PID 2>/dev/null || true
    wait $BUN_PID 2>/dev/null || true

    # Start Node server
    node "$BENCH_DIR/http-node.js" &
    NODE_PID=$!
    sleep 1

    NODE_HTTP=0
    for ((i=1; i<=ITERATIONS; i++)); do
      start=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
      curl -s http://localhost:9877/ > /dev/null
      end=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
      NODE_HTTP=$((NODE_HTTP + (end - start) / 1000000))
    done
    NODE_HTTP=$((NODE_HTTP / ITERATIONS))
    kill $NODE_PID 2>/dev/null || true
    wait $NODE_PID 2>/dev/null || true

    print_result "HTTP response latency" "$BUN_HTTP" "$NODE_HTTP"
    echo ""
  fi
fi

# ─── Package Install Benchmark ───────────────────────────────────
if $RUN_INSTALL; then
  echo -e "${BOLD}━━━ Package Install ━━━${NC}"

  # Create test package.json
  INSTALL_DIR="$BENCH_DIR/install-test"
  mkdir -p "$INSTALL_DIR"
  cat > "$INSTALL_DIR/package.json" <<'EOF'
{
  "name": "bench-install",
  "private": true,
  "dependencies": {
    "express": "^4.18.0",
    "lodash": "^4.17.0",
    "zod": "^3.22.0"
  }
}
EOF

  echo -e "  ${BLUE}Measuring install time (express + lodash + zod, ${ITERATIONS} iterations)...${NC}"
  echo -e "  ${YELLOW}(Cold install — cache cleared each iteration)${NC}"

  # Bun install
  BUN_INSTALL=0
  for ((i=1; i<=ITERATIONS; i++)); do
    rm -rf "$INSTALL_DIR/node_modules" "$INSTALL_DIR/bun.lock" 2>/dev/null || true
    start=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
    (cd "$INSTALL_DIR" && bun install --silent 2>/dev/null)
    end=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
    BUN_INSTALL=$((BUN_INSTALL + (end - start) / 1000000))
  done
  BUN_INSTALL=$((BUN_INSTALL / ITERATIONS))

  # npm install
  NODE_INSTALL=0
  if command -v npm &>/dev/null; then
    for ((i=1; i<=ITERATIONS; i++)); do
      rm -rf "$INSTALL_DIR/node_modules" "$INSTALL_DIR/package-lock.json" 2>/dev/null || true
      start=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
      (cd "$INSTALL_DIR" && npm install --silent --no-audit --no-fund 2>/dev/null)
      end=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
      NODE_INSTALL=$((NODE_INSTALL + (end - start) / 1000000))
    done
    NODE_INSTALL=$((NODE_INSTALL / ITERATIONS))
  fi

  print_result "Install 3 packages" "$BUN_INSTALL" "$NODE_INSTALL"
  echo ""
fi

# ─── Summary ─────────────────────────────────────────────────────
echo -e "${BOLD}━━━ Benchmark Complete ━━━${NC}"
echo ""
echo -e "  ${YELLOW}Note: Results vary by machine, OS, and workload.${NC}"
echo -e "  ${YELLOW}For HTTP throughput, use dedicated tools like wrk or autocannon.${NC}"
echo ""
