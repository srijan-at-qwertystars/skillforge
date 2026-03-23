#!/usr/bin/env bash
set -euo pipefail

# hono-benchmark.sh — Benchmark a Hono app (requests/sec, latency) using wrk or autocannon
# Usage: ./hono-benchmark.sh [url] [options]

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

URL="http://localhost:3000"
DURATION=10
CONNECTIONS=50
THREADS=4
TOOL=""
WARMUP=true
ENDPOINTS=()
METHOD="GET"
BODY=""
HEADERS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [url] [options]

Benchmark a Hono application using wrk (preferred) or autocannon.

Options:
  -u, --url <url>           Target URL (default: http://localhost:3000)
  -d, --duration <secs>     Test duration in seconds (default: 10)
  -c, --connections <n>     Number of concurrent connections (default: 50)
  -t, --threads <n>         Number of threads for wrk (default: 4)
  --tool <wrk|autocannon>   Force a specific benchmark tool
  --no-warmup               Skip warmup phase
  -e, --endpoint <path>     Add endpoint to test (can be repeated; default: /)
  -m, --method <METHOD>     HTTP method (default: GET)
  -b, --body <json>         Request body for POST/PUT
  -H, --header <header>     Add header (can be repeated, format: "Key: Value")
  -h, --help                Show this help

Examples:
  $(basename "$0")                                    # Benchmark GET http://localhost:3000/
  $(basename "$0") -u http://localhost:8787 -d 30      # 30s test on port 8787
  $(basename "$0") -e / -e /api/users -e /health       # Test multiple endpoints
  $(basename "$0") -m POST -b '{"name":"test"}' -e /api/users  # POST benchmark
  $(basename "$0") --tool autocannon -c 100 -d 20      # Force autocannon, 100 connections
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url) URL="$2"; shift 2 ;;
    -d|--duration) DURATION="$2"; shift 2 ;;
    -c|--connections) CONNECTIONS="$2"; shift 2 ;;
    -t|--threads) THREADS="$2"; shift 2 ;;
    --tool) TOOL="$2"; shift 2 ;;
    --no-warmup) WARMUP=false; shift ;;
    -e|--endpoint) ENDPOINTS+=("$2"); shift 2 ;;
    -m|--method) METHOD="$2"; shift 2 ;;
    -b|--body) BODY="$2"; shift 2 ;;
    -H|--header) HEADERS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    http*) URL="$1"; shift ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) URL="$1"; shift ;;
  esac
done

# Default endpoint
if [[ ${#ENDPOINTS[@]} -eq 0 ]]; then
  ENDPOINTS=("/")
fi

# Detect benchmark tool
detect_tool() {
  if [[ -n "$TOOL" ]]; then
    if ! command -v "$TOOL" &>/dev/null; then
      echo -e "${RED}Error: '$TOOL' not found. Install it first.${NC}"
      echo ""
      case "$TOOL" in
        wrk) echo "  brew install wrk  # macOS"
             echo "  apt-get install wrk  # Ubuntu/Debian" ;;
        autocannon) echo "  npm install -g autocannon" ;;
      esac
      exit 1
    fi
    return
  fi

  if command -v wrk &>/dev/null; then
    TOOL="wrk"
  elif command -v autocannon &>/dev/null; then
    TOOL="autocannon"
  else
    echo -e "${RED}Error: No benchmark tool found. Install one:${NC}"
    echo ""
    echo "  wrk (recommended):"
    echo "    brew install wrk          # macOS"
    echo "    apt-get install wrk       # Ubuntu/Debian"
    echo ""
    echo "  autocannon (Node.js):"
    echo "    npm install -g autocannon"
    exit 1
  fi
}

detect_tool

# Check server is reachable
echo -e "${BLUE}Checking server at ${URL}...${NC}"
if ! curl -sf --max-time 5 "${URL}${ENDPOINTS[0]}" > /dev/null 2>&1; then
  echo -e "${RED}Error: Cannot reach ${URL}${ENDPOINTS[0]}${NC}"
  echo "Make sure your Hono server is running."
  exit 1
fi
echo -e "${GREEN}✔ Server is reachable${NC}"
echo ""

# System info
echo -e "${BLUE}═══════════════════════════════════════${NC}"
echo -e "${BLUE}  Hono Benchmark${NC}"
echo -e "${BLUE}═══════════════════════════════════════${NC}"
echo "  Tool:        $TOOL"
echo "  Target:      $URL"
echo "  Duration:    ${DURATION}s"
echo "  Connections: $CONNECTIONS"
[[ "$TOOL" == "wrk" ]] && echo "  Threads:     $THREADS"
echo "  Method:      $METHOD"
echo "  Endpoints:   ${ENDPOINTS[*]}"
[[ -n "$BODY" ]] && echo "  Body:        $BODY"
echo -e "${BLUE}═══════════════════════════════════════${NC}"
echo ""

# Warmup phase
if $WARMUP; then
  echo -e "${YELLOW}Warming up (2s)...${NC}"
  for ep in "${ENDPOINTS[@]}"; do
    case "$TOOL" in
      wrk)
        wrk -t1 -c10 -d2s "${URL}${ep}" > /dev/null 2>&1 || true
        ;;
      autocannon)
        autocannon -c 10 -d 2 --no-progress "${URL}${ep}" > /dev/null 2>&1 || true
        ;;
    esac
  done
  echo ""
fi

# Run benchmark
run_wrk() {
  local endpoint="$1"
  local full_url="${URL}${endpoint}"

  local wrk_args=("-t${THREADS}" "-c${CONNECTIONS}" "-d${DURATION}s" "--latency")

  # Build Lua script for non-GET or custom headers
  if [[ "$METHOD" != "GET" ]] || [[ ${#HEADERS[@]} -gt 0 ]] || [[ -n "$BODY" ]]; then
    local lua_script
    lua_script=$(mktemp /tmp/hono-bench-XXXXXX.lua)
    {
      echo "wrk.method = \"$METHOD\""
      if [[ -n "$BODY" ]]; then
        echo "wrk.body = [[$BODY]]"
        echo 'wrk.headers["Content-Type"] = "application/json"'
      fi
      for h in "${HEADERS[@]}"; do
        local key="${h%%:*}"
        local val="${h#*: }"
        echo "wrk.headers[\"$key\"] = \"$val\""
      done
    } > "$lua_script"
    wrk_args+=("-s" "$lua_script")
  fi

  echo -e "${GREEN}▶ $METHOD $endpoint${NC}"
  echo "  wrk ${wrk_args[*]} $full_url"
  echo ""
  wrk "${wrk_args[@]}" "$full_url"
  echo ""

  # Cleanup lua script
  [[ -n "${lua_script:-}" ]] && rm -f "$lua_script"
}

run_autocannon() {
  local endpoint="$1"
  local full_url="${URL}${endpoint}"

  local ac_args=("-c" "$CONNECTIONS" "-d" "$DURATION")

  if [[ "$METHOD" != "GET" ]]; then
    ac_args+=("-m" "$METHOD")
  fi

  if [[ -n "$BODY" ]]; then
    ac_args+=("-b" "$BODY" "-H" "Content-Type=application/json")
  fi

  for h in "${HEADERS[@]}"; do
    ac_args+=("-H" "${h}")
  done

  echo -e "${GREEN}▶ $METHOD $endpoint${NC}"
  echo "  autocannon ${ac_args[*]} $full_url"
  echo ""
  autocannon "${ac_args[@]}" "$full_url"
  echo ""
}

for ep in "${ENDPOINTS[@]}"; do
  case "$TOOL" in
    wrk) run_wrk "$ep" ;;
    autocannon) run_autocannon "$ep" ;;
  esac
done

echo -e "${BLUE}═══════════════════════════════════════${NC}"
echo -e "${GREEN}✔ Benchmark complete${NC}"
echo -e "${BLUE}═══════════════════════════════════════${NC}"
echo ""
echo "Tips for better benchmarks:"
echo "  • Run on the same machine as the server to minimize network variance"
echo "  • Increase duration (-d 30) for more stable results"
echo "  • Try different connection counts to find saturation point"
echo "  • Compare runtimes: bun vs node vs deno with same app code"
echo "  • Use --no-warmup for cold-start testing"
