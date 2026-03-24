#!/usr/bin/env bash
set -euo pipefail

# federation-health.sh — Check health of a running federation stack
# Usage: ./federation-health.sh [router-url] [--subgraphs url1,url2,...] [--compose supergraph.yaml]
#
# Examples:
#   ./federation-health.sh
#   ./federation-health.sh http://localhost:4000
#   ./federation-health.sh http://localhost:4000 --subgraphs http://localhost:4001,http://localhost:4002
#   ./federation-health.sh http://localhost:4000 --compose supergraph.yaml

ROUTER_URL="${1:-http://localhost:4000}"
HEALTH_PORT="${HEALTH_PORT:-8088}"
SUBGRAPH_URLS=""
COMPOSE_CONFIG=""
EXIT_CODE=0
TIMEOUT=5

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subgraphs)  SUBGRAPH_URLS="$2"; shift 2 ;;
    --compose)    COMPOSE_CONFIG="$2"; shift 2 ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    *)            echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[  OK]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; EXIT_CODE=1; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

echo "═══════════════════════════════════════════════════════════"
echo "  Federation Health Check"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── 1. Router health endpoint ────────────────────────────────────────────────

info "1. Router Health Endpoint"

ROUTER_HOST=$(echo "${ROUTER_URL}" | sed -E 's|^https?://([^:/]+).*|\1|')
HEALTH_URL="http://${ROUTER_HOST}:${HEALTH_PORT}/health"

HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" "${HEALTH_URL}" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" == "200" ]]; then
  ok "Router health endpoint: ${HEALTH_URL} → HTTP ${HTTP_CODE}"
else
  fail "Router health endpoint: ${HEALTH_URL} → HTTP ${HTTP_CODE}"
  warn "  Router may not be running or health check is disabled"
fi

# ── 2. Router GraphQL endpoint ────────────────────────────────────────────────

info "2. Router GraphQL Endpoint"

GRAPHQL_URL="${ROUTER_URL}/graphql"
RESPONSE=$(curl -sf --max-time "${TIMEOUT}" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ __typename }"}' \
  "${GRAPHQL_URL}" 2>/dev/null || echo "")

if echo "${RESPONSE}" | grep -q "__typename" 2>/dev/null; then
  ok "Router GraphQL: ${GRAPHQL_URL} → responding"
else
  fail "Router GraphQL: ${GRAPHQL_URL} → not responding"
  if [[ -n "${RESPONSE}" ]]; then
    warn "  Response: ${RESPONSE}"
  fi
fi

# ── 3. Introspection check ───────────────────────────────────────────────────

info "3. Schema Introspection"

SCHEMA_RESPONSE=$(curl -sf --max-time "${TIMEOUT}" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ __schema { queryType { name } types { name } } }"}' \
  "${GRAPHQL_URL}" 2>/dev/null || echo "")

if echo "${SCHEMA_RESPONSE}" | grep -q "queryType" 2>/dev/null; then
  if command -v jq &>/dev/null; then
    TYPE_COUNT=$(echo "${SCHEMA_RESPONSE}" | jq '.data.__schema.types | length' 2>/dev/null || echo "?")
    ok "Schema available — ${TYPE_COUNT} types"
  else
    ok "Schema available via introspection"
  fi
else
  warn "Introspection may be disabled (common in production)"
fi

# ── 4. Subgraph reachability ─────────────────────────────────────────────────

info "4. Subgraph Reachability"

# Build subgraph list from --subgraphs flag or --compose config
SUBGRAPHS=()

if [[ -n "${SUBGRAPH_URLS}" ]]; then
  IFS=',' read -ra SUBGRAPHS <<< "${SUBGRAPH_URLS}"
elif [[ -n "${COMPOSE_CONFIG}" && -f "${COMPOSE_CONFIG}" ]]; then
  if command -v python3 &>/dev/null; then
    while IFS= read -r url; do
      [[ -n "${url}" ]] && SUBGRAPHS+=("${url}")
    done < <(python3 -c "
import yaml
with open('${COMPOSE_CONFIG}') as f:
    config = yaml.safe_load(f)
for name, sg in config.get('subgraphs', {}).items():
    url = sg.get('routing_url', '')
    if url:
        print(f'{name}={url}')
" 2>/dev/null || true)
  fi
fi

if [[ ${#SUBGRAPHS[@]} -eq 0 ]]; then
  # Default: try common local ports
  SUBGRAPHS=("products=http://localhost:4001/graphql" "reviews=http://localhost:4002/graphql")
  warn "No subgraphs specified — checking defaults"
fi

for entry in "${SUBGRAPHS[@]}"; do
  if [[ "${entry}" == *"="* ]]; then
    SG_NAME="${entry%%=*}"
    SG_URL="${entry#*=}"
  else
    SG_NAME="subgraph"
    SG_URL="${entry}"
  fi

  # Ensure URL has /graphql path
  [[ "${SG_URL}" != */graphql ]] && SG_URL="${SG_URL%/}/graphql"

  SG_RESPONSE=$(curl -sf --max-time "${TIMEOUT}" \
    -H "Content-Type: application/json" \
    -d '{"query":"{ __typename }"}' \
    "${SG_URL}" 2>/dev/null || echo "")

  if echo "${SG_RESPONSE}" | grep -q "__typename" 2>/dev/null; then
    ok "${SG_NAME}: ${SG_URL} → reachable"

    # Check _service SDL (federation subgraph indicator)
    SDL_RESPONSE=$(curl -sf --max-time "${TIMEOUT}" \
      -H "Content-Type: application/json" \
      -d '{"query":"{ _service { sdl } }"}' \
      "${SG_URL}" 2>/dev/null || echo "")

    if echo "${SDL_RESPONSE}" | grep -q "_service" 2>/dev/null; then
      ok "  Federation SDL available"
    else
      warn "  No federation SDL — may not be a subgraph"
    fi
  else
    fail "${SG_NAME}: ${SG_URL} → unreachable"
  fi
done

# ── 5. Composition status (if rover available) ───────────────────────────────

info "5. Composition Status"

if [[ -n "${COMPOSE_CONFIG}" && -f "${COMPOSE_CONFIG}" ]]; then
  if command -v rover &>/dev/null; then
    COMPOSE_RESULT=$(rover supergraph compose --config "${COMPOSE_CONFIG}" --output /dev/null 2>&1 || true)
    if echo "${COMPOSE_RESULT}" | grep -qi "error"; then
      fail "Composition has errors"
      echo "${COMPOSE_RESULT}" | grep -i "error" | head -5 | sed 's/^/         /'
    else
      ok "Composition succeeds"
    fi
  else
    warn "Rover CLI not available — skipping composition check"
  fi
else
  warn "No --compose config provided — skipping composition check"
fi

# ── 6. Response latency ──────────────────────────────────────────────────────

info "6. Response Latency"

LATENCY=$(curl -sf -o /dev/null -w "%{time_total}" --max-time "${TIMEOUT}" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ __typename }"}' \
  "${GRAPHQL_URL}" 2>/dev/null || echo "timeout")

if [[ "${LATENCY}" != "timeout" ]]; then
  LATENCY_MS=$(echo "${LATENCY}" | awk '{printf "%.0f", $1 * 1000}')
  if [[ "${LATENCY_MS}" -lt 100 ]]; then
    ok "Router latency: ${LATENCY_MS}ms (excellent)"
  elif [[ "${LATENCY_MS}" -lt 500 ]]; then
    ok "Router latency: ${LATENCY_MS}ms (good)"
  elif [[ "${LATENCY_MS}" -lt 2000 ]]; then
    warn "Router latency: ${LATENCY_MS}ms (slow)"
  else
    fail "Router latency: ${LATENCY_MS}ms (very slow)"
  fi
else
  fail "Router latency: timeout (>${TIMEOUT}s)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════"
if [[ "${EXIT_CODE}" -eq 0 ]]; then
  ok "All health checks passed ✓"
else
  fail "Some checks failed — review output above"
fi
echo "═══════════════════════════════════════════════════════════"

exit "${EXIT_CODE}"
