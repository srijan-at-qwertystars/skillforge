#!/usr/bin/env bash
# validate-collector-config.sh — Validate an OpenTelemetry Collector configuration file
#
# Performs multi-level validation:
#   1. YAML syntax check
#   2. Required sections check (receivers, exporters, service, pipelines)
#   3. Pipeline reference consistency (components referenced exist)
#   4. Native otelcol validate (if Collector binary or Docker image available)
#
# Usage:
#   ./validate-collector-config.sh <config-file>
#   ./validate-collector-config.sh --docker <config-file>    # Use Docker image for validation
#
# Requirements: python3 (for YAML parsing), optionally docker or otelcol/otelcol-contrib

set -euo pipefail

CONFIG_FILE=""
USE_DOCKER=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[PASS]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[FAIL]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[CHECK]${NC} $*"; }

ERRORS=0
WARNINGS=0

usage() {
  echo "Usage: $0 [OPTIONS] <config-file>"
  echo ""
  echo "Options:"
  echo "  --docker    Use Docker image for native Collector validation"
  echo "  -h, --help  Show this help"
  echo ""
  echo "Examples:"
  echo "  $0 collector-config.yaml"
  echo "  $0 --docker /etc/otel/config.yaml"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --docker) USE_DOCKER=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) log_error "Unknown option: $1"; usage; exit 1 ;;
      *)  CONFIG_FILE="$1"; shift ;;
    esac
  done

  if [ -z "$CONFIG_FILE" ]; then
    log_error "Config file path is required"
    usage
    exit 1
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    log_error "File not found: $CONFIG_FILE"
    exit 1
  fi
}

check_yaml_syntax() {
  log_step "YAML syntax validation"

  if command -v python3 &>/dev/null; then
    if python3 -c "
import yaml, sys
try:
    with open('$CONFIG_FILE') as f:
        data = yaml.safe_load(f)
    if data is None:
        print('File is empty or contains only comments', file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
except yaml.YAMLError as e:
    print(f'YAML parse error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
      log_info "YAML syntax is valid"
    else
      log_error "YAML syntax error in $CONFIG_FILE"
      # Show the actual error
      python3 -c "
import yaml, sys
try:
    with open('$CONFIG_FILE') as f:
        yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f'  {e}', file=sys.stderr)
" 2>&1 || true
      ERRORS=$((ERRORS + 1))
    fi
  else
    log_warn "python3 not found — skipping YAML syntax check"
    WARNINGS=$((WARNINGS + 1))
  fi
}

check_required_sections() {
  log_step "Required sections"

  python3 << 'PYEOF'
import yaml, sys

with open(sys.argv[1]) as f:
    config = yaml.safe_load(f)

errors = 0

# Check top-level required sections
for section in ['receivers', 'exporters', 'service']:
    if section not in config or config[section] is None:
        print(f"  MISSING: '{section}' section is required", file=sys.stderr)
        errors += 1
    else:
        print(f"  FOUND: '{section}'")

# Check service.pipelines
if 'service' in config and config['service']:
    if 'pipelines' not in config['service'] or not config['service']['pipelines']:
        print(f"  MISSING: 'service.pipelines' is required", file=sys.stderr)
        errors += 1
    else:
        pipelines = config['service']['pipelines']
        print(f"  FOUND: {len(pipelines)} pipeline(s): {', '.join(pipelines.keys())}")

# Processors are optional but recommended
if 'processors' not in config or config['processors'] is None:
    print(f"  WARNING: no 'processors' section — consider adding memory_limiter and batch")
else:
    print(f"  FOUND: 'processors'")

sys.exit(errors)
PYEOF
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    log_info "All required sections present"
  else
    log_error "Missing required sections"
    ERRORS=$((ERRORS + exit_code))
  fi
}

check_pipeline_references() {
  log_step "Pipeline reference consistency"

  python3 << 'PYEOF'
import yaml, sys

with open(sys.argv[1]) as f:
    config = yaml.safe_load(f)

errors = 0
warnings = 0

receivers = set(config.get('receivers', {}).keys()) if config.get('receivers') else set()
processors = set(config.get('processors', {}).keys()) if config.get('processors') else set()
exporters = set(config.get('exporters', {}).keys()) if config.get('exporters') else set()
extensions = set(config.get('extensions', {}).keys()) if config.get('extensions') else set()
connectors = set(config.get('connectors', {}).keys()) if config.get('connectors') else set()

service = config.get('service', {})
pipelines = service.get('pipelines', {}) if service else {}

for pipe_name, pipe_cfg in (pipelines or {}).items():
    if not pipe_cfg:
        print(f"  WARN: pipeline '{pipe_name}' is empty", file=sys.stderr)
        warnings += 1
        continue

    # Check receivers
    for r in (pipe_cfg.get('receivers') or []):
        if r not in receivers and r not in connectors:
            print(f"  ERROR: pipeline '{pipe_name}' references undefined receiver: '{r}'", file=sys.stderr)
            errors += 1

    # Check processors
    for p in (pipe_cfg.get('processors') or []):
        if p not in processors:
            print(f"  ERROR: pipeline '{pipe_name}' references undefined processor: '{p}'", file=sys.stderr)
            errors += 1

    # Check exporters
    for e in (pipe_cfg.get('exporters') or []):
        if e not in exporters and e not in connectors:
            print(f"  ERROR: pipeline '{pipe_name}' references undefined exporter: '{e}'", file=sys.stderr)
            errors += 1

    if not pipe_cfg.get('receivers'):
        print(f"  WARN: pipeline '{pipe_name}' has no receivers", file=sys.stderr)
        warnings += 1
    if not pipe_cfg.get('exporters'):
        print(f"  WARN: pipeline '{pipe_name}' has no exporters", file=sys.stderr)
        warnings += 1

# Check extensions
for ext in (service.get('extensions') or []):
    if ext not in extensions:
        print(f"  ERROR: service references undefined extension: '{ext}'", file=sys.stderr)
        errors += 1

if errors == 0:
    print(f"  All pipeline references resolve correctly")

sys.exit(errors)
PYEOF
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    log_info "Pipeline references are consistent"
  else
    log_error "Found $exit_code reference error(s)"
    ERRORS=$((ERRORS + exit_code))
  fi
}

check_best_practices() {
  log_step "Best practices"

  python3 << 'PYEOF'
import yaml, sys

with open(sys.argv[1]) as f:
    config = yaml.safe_load(f)

warnings = 0
service = config.get('service', {})
pipelines = service.get('pipelines', {}) if service else {}
processors = config.get('processors', {}) if config.get('processors') else {}

# Check memory_limiter is present and first
has_memory_limiter = 'memory_limiter' in processors
if not has_memory_limiter:
    print("  WARN: No memory_limiter processor — risk of OOM in production")
    warnings += 1

for pipe_name, pipe_cfg in (pipelines or {}).items():
    procs = pipe_cfg.get('processors') or []

    if has_memory_limiter and procs and procs[0] != 'memory_limiter':
        print(f"  WARN: pipeline '{pipe_name}': memory_limiter should be the FIRST processor")
        warnings += 1

    # Check batch is present
    if not any(p.startswith('batch') for p in procs):
        print(f"  WARN: pipeline '{pipe_name}': no batch processor — consider adding one")
        warnings += 1

# Check for debug exporter in production (just a note)
exporters = config.get('exporters', {})
if exporters:
    for exp_name in exporters:
        if exp_name == 'debug' or exp_name.startswith('debug/'):
            print(f"  NOTE: debug exporter '{exp_name}' is present — disable in production")

# Check TLS configuration
for exp_name, exp_cfg in (exporters or {}).items():
    if exp_cfg and isinstance(exp_cfg, dict):
        tls = exp_cfg.get('tls', {})
        if tls and tls.get('insecure') is True:
            print(f"  WARN: exporter '{exp_name}' has TLS disabled (insecure: true)")
            warnings += 1

if warnings == 0:
    print("  All best practice checks passed")

sys.exit(0)  # Warnings don't fail validation
PYEOF
  log_info "Best practice checks complete"
}

run_native_validation() {
  log_step "Native Collector validation"

  if [ "$USE_DOCKER" = true ]; then
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
      local abs_path
      abs_path=$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")
      if docker run --rm -v "$abs_path:/etc/otelcol/config.yaml:ro" \
        otel/opentelemetry-collector-contrib:latest validate \
        --config=/etc/otelcol/config.yaml 2>&1; then
        log_info "Native Collector validation passed"
      else
        log_error "Native Collector validation failed"
        ERRORS=$((ERRORS + 1))
      fi
    else
      log_warn "Docker not available — skipping native validation"
    fi
  elif command -v otelcol-contrib &>/dev/null; then
    if otelcol-contrib validate --config="$CONFIG_FILE" 2>&1; then
      log_info "Native Collector validation passed (otelcol-contrib)"
    else
      log_error "Native Collector validation failed"
      ERRORS=$((ERRORS + 1))
    fi
  elif command -v otelcol &>/dev/null; then
    if otelcol validate --config="$CONFIG_FILE" 2>&1; then
      log_info "Native Collector validation passed (otelcol)"
    else
      log_error "Native Collector validation failed"
      ERRORS=$((ERRORS + 1))
    fi
  else
    log_warn "No Collector binary found — use --docker flag or install otelcol-contrib"
    log_warn "  Install: https://opentelemetry.io/docs/collector/installation/"
    WARNINGS=$((WARNINGS + 1))
  fi
}

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Validation Summary: $CONFIG_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [ "$ERRORS" -eq 0 ]; then
    echo -e "  Result:   ${GREEN}VALID${NC}"
  else
    echo -e "  Result:   ${RED}INVALID${NC}"
  fi

  echo "  Errors:   $ERRORS"
  echo "  Warnings: $WARNINGS"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
  parse_args "$@"

  echo "Validating: $CONFIG_FILE"
  echo ""

  check_yaml_syntax
  check_required_sections
  check_pipeline_references
  check_best_practices
  run_native_validation

  print_summary

  exit "$ERRORS"
}

main "$@"
