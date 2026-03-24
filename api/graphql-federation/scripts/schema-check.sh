#!/usr/bin/env bash
set -euo pipefail

# schema-check.sh — Validate subgraph schemas and supergraph composition
# Usage: ./schema-check.sh [supergraph-config] [--graph-ref GRAPH_REF] [--subgraph NAME]
#
# Modes:
#   Local:   ./schema-check.sh supergraph.yaml
#   Remote:  ./schema-check.sh supergraph.yaml --graph-ref my-graph@prod --subgraph products

SUPERGRAPH_CONFIG="${1:-supergraph.yaml}"
GRAPH_REF=""
SUBGRAPH_NAME=""
EXIT_CODE=0

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --graph-ref)  GRAPH_REF="$2"; shift 2 ;;
    --subgraph)   SUBGRAPH_NAME="$2"; shift 2 ;;
    *)            echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[PASS]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; EXIT_CODE=1; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

# ── Pre-flight ────────────────────────────────────────────────────────────────

if ! command -v rover &>/dev/null; then
  echo "Error: rover CLI is required. Install: curl -sSL https://rover.apollo.dev/nix/latest | sh" >&2
  exit 1
fi

info "Rover version: $(rover --version 2>/dev/null || echo 'unknown')"
echo ""

# ── Step 1: Validate supergraph config exists ────────────────────────────────

info "Step 1: Checking supergraph config..."
if [[ -f "${SUPERGRAPH_CONFIG}" ]]; then
  ok "Config found: ${SUPERGRAPH_CONFIG}"
else
  fail "Config not found: ${SUPERGRAPH_CONFIG}"
  exit 1
fi

# ── Step 2: Local composition check ──────────────────────────────────────────

info "Step 2: Local supergraph composition..."
COMPOSE_OUTPUT=$(mktemp)
COMPOSE_ERRORS=$(mktemp)
trap 'rm -f "${COMPOSE_OUTPUT}" "${COMPOSE_ERRORS}"' EXIT

if rover supergraph compose --config "${SUPERGRAPH_CONFIG}" --output "${COMPOSE_OUTPUT}" 2>"${COMPOSE_ERRORS}"; then
  TYPES=$(grep -c "^type " "${COMPOSE_OUTPUT}" 2>/dev/null || echo "0")
  LINES=$(wc -l < "${COMPOSE_OUTPUT}")
  ok "Composition succeeded — ${LINES} lines, ${TYPES} types"
else
  fail "Composition failed"
  cat "${COMPOSE_ERRORS}" >&2
fi

# ── Step 3: Validate individual subgraph schemas ─────────────────────────────

info "Step 3: Validating individual subgraph schemas..."

# Extract subgraph schema paths from the config
if command -v python3 &>/dev/null; then
  SUBGRAPH_FILES=$(python3 -c "
import yaml, sys
with open('${SUPERGRAPH_CONFIG}') as f:
    config = yaml.safe_load(f)
for name, sg in config.get('subgraphs', {}).items():
    schema = sg.get('schema', {})
    path = schema.get('file', '')
    if path:
        print(f'{name}:{path}')
" 2>/dev/null || true)
elif command -v yq &>/dev/null; then
  SUBGRAPH_FILES=$(yq -r '.subgraphs | to_entries[] | "\(.key):\(.value.schema.file // "")"' "${SUPERGRAPH_CONFIG}" 2>/dev/null || true)
fi

if [[ -n "${SUBGRAPH_FILES:-}" ]]; then
  while IFS=: read -r sg_name sg_path; do
    [[ -z "${sg_path}" ]] && continue
    if [[ -f "${sg_path}" ]]; then
      ok "Schema exists: ${sg_name} → ${sg_path}"
      # Basic validation: check for federation directive
      if grep -q "@link.*federation" "${sg_path}" 2>/dev/null; then
        ok "  Federation v2 link directive found"
      elif grep -q "@key" "${sg_path}" 2>/dev/null; then
        warn "  Has @key but missing federation v2 link directive"
      else
        warn "  No federation directives found — may not be a subgraph"
      fi
    else
      fail "Schema missing: ${sg_name} → ${sg_path}"
    fi
  done <<< "${SUBGRAPH_FILES}"
else
  warn "Could not parse subgraph config (install python3 + pyyaml or yq)"
fi

# ── Step 4: Remote schema check (if graph ref provided) ─────────────────────

if [[ -n "${GRAPH_REF}" ]]; then
  info "Step 4: Remote schema check against ${GRAPH_REF}..."

  if [[ -z "${APOLLO_KEY:-}" ]]; then
    fail "APOLLO_KEY environment variable not set"
  else
    if [[ -n "${SUBGRAPH_NAME}" ]]; then
      # Check a specific subgraph
      SCHEMA_FILE=""
      while IFS=: read -r sg_name sg_path; do
        [[ "${sg_name}" == "${SUBGRAPH_NAME}" ]] && SCHEMA_FILE="${sg_path}"
      done <<< "${SUBGRAPH_FILES:-}"

      if [[ -z "${SCHEMA_FILE}" ]]; then
        fail "Subgraph '${SUBGRAPH_NAME}' not found in config"
      else
        info "  Checking ${SUBGRAPH_NAME} against ${GRAPH_REF}..."
        if rover subgraph check "${GRAPH_REF}" --name "${SUBGRAPH_NAME}" --schema "${SCHEMA_FILE}" 2>&1; then
          ok "Schema check passed for ${SUBGRAPH_NAME}"
        else
          fail "Schema check failed for ${SUBGRAPH_NAME}"
        fi
      fi
    else
      # Check all subgraphs
      while IFS=: read -r sg_name sg_path; do
        [[ -z "${sg_path}" || ! -f "${sg_path}" ]] && continue
        info "  Checking ${sg_name} against ${GRAPH_REF}..."
        if rover subgraph check "${GRAPH_REF}" --name "${sg_name}" --schema "${sg_path}" 2>&1; then
          ok "Schema check passed for ${sg_name}"
        else
          fail "Schema check failed for ${sg_name}"
        fi
      done <<< "${SUBGRAPH_FILES:-}"
    fi
  fi
else
  info "Step 4: Skipped remote check (no --graph-ref provided)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
if [[ "${EXIT_CODE}" -eq 0 ]]; then
  ok "All checks passed ✓"
else
  fail "Some checks failed — see output above"
fi

exit "${EXIT_CODE}"
