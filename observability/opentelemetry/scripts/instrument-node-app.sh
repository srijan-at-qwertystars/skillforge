#!/usr/bin/env bash
# instrument-node-app.sh — Add OpenTelemetry auto-instrumentation to a Node.js project
#
# Installs OTel SDK packages, creates an instrumentation bootstrap file,
# and updates package.json scripts to load it before the app.
#
# Usage:
#   ./instrument-node-app.sh [--project-dir /path/to/project] [--service-name my-api] [--typescript]
#
# Requirements: node >= 18, npm

set -euo pipefail

PROJECT_DIR="."
SERVICE_NAME=""
USE_TYPESCRIPT=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --project-dir DIR     Path to Node.js project (default: current directory)"
  echo "  --service-name NAME   Service name for OTel (default: from package.json)"
  echo "  --typescript          Generate TypeScript instrumentation file"
  echo "  -h, --help            Show this help"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-dir)  PROJECT_DIR="$2"; shift 2 ;;
      --service-name) SERVICE_NAME="$2"; shift 2 ;;
      --typescript)   USE_TYPESCRIPT=true; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

check_prereqs() {
  if ! command -v node &>/dev/null; then
    log_error "Node.js is required but not found"
    exit 1
  fi

  local node_major
  node_major=$(node -v | sed 's/v//' | cut -d. -f1)
  if [ "$node_major" -lt 18 ]; then
    log_error "Node.js >= 18 required (found: $(node -v))"
    exit 1
  fi

  if ! command -v npm &>/dev/null; then
    log_error "npm is required but not found"
    exit 1
  fi

  if [ ! -f "$PROJECT_DIR/package.json" ]; then
    log_error "No package.json found in $PROJECT_DIR"
    exit 1
  fi
}

detect_service_name() {
  if [ -z "$SERVICE_NAME" ]; then
    SERVICE_NAME=$(node -e "console.log(require('$PROJECT_DIR/package.json').name || 'my-service')" 2>/dev/null || echo "my-service")
  fi
  log_info "Service name: $SERVICE_NAME"
}

install_packages() {
  log_info "Installing OpenTelemetry packages..."
  cd "$PROJECT_DIR"

  local packages=(
    "@opentelemetry/sdk-node"
    "@opentelemetry/api"
    "@opentelemetry/auto-instrumentations-node"
    "@opentelemetry/exporter-trace-otlp-http"
    "@opentelemetry/exporter-metrics-otlp-http"
    "@opentelemetry/exporter-logs-otlp-http"
    "@opentelemetry/sdk-metrics"
    "@opentelemetry/sdk-logs"
    "@opentelemetry/resources"
    "@opentelemetry/semantic-conventions"
  )

  npm install --save "${packages[@]}"

  if [ "$USE_TYPESCRIPT" = true ]; then
    # Ensure TypeScript types are available
    npm install --save-dev "@types/node" 2>/dev/null || true
  fi

  log_info "Packages installed successfully"
}

create_instrumentation_file() {
  local ext="js"
  local comment_style="//"
  if [ "$USE_TYPESCRIPT" = true ]; then
    ext="ts"
  fi

  local filepath="$PROJECT_DIR/instrumentation.$ext"

  if [ -f "$filepath" ]; then
    log_warn "instrumentation.$ext already exists — backing up to instrumentation.$ext.bak"
    cp "$filepath" "$filepath.bak"
  fi

  log_info "Creating instrumentation.$ext..."

  if [ "$USE_TYPESCRIPT" = true ]; then
    cat > "$filepath" << TYPESCRIPT
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-http';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-http';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { BatchLogRecordProcessor } from '@opentelemetry/sdk-logs';
import { Resource } from '@opentelemetry/resources';
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} from '@opentelemetry/semantic-conventions';

const resource = new Resource({
  [ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME ?? '${SERVICE_NAME}',
  [ATTR_SERVICE_VERSION]: process.env.npm_package_version ?? '0.0.0',
});

const sdk = new NodeSDK({
  resource,
  traceExporter: new OTLPTraceExporter(),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter(),
    exportIntervalMillis: 60_000,
  }),
  logRecordProcessor: new BatchLogRecordProcessor(new OTLPLogExporter()),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false },
      '@opentelemetry/instrumentation-dns': { enabled: false },
    }),
  ],
});

sdk.start();

const shutdown = async () => {
  try {
    await sdk.shutdown();
    console.log('OpenTelemetry SDK shut down successfully');
  } catch (err) {
    console.error('Error shutting down OpenTelemetry SDK', err);
  } finally {
    process.exit(0);
  }
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

console.log(\`OpenTelemetry initialized for \${resource.attributes[ATTR_SERVICE_NAME]}\`);
TYPESCRIPT
  else
    cat > "$filepath" << JAVASCRIPT
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
const { OTLPLogExporter } = require('@opentelemetry/exporter-logs-otlp-http');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
const { BatchLogRecordProcessor } = require('@opentelemetry/sdk-logs');
const { Resource } = require('@opentelemetry/resources');
const {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} = require('@opentelemetry/semantic-conventions');

const resource = new Resource({
  [ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME ?? '${SERVICE_NAME}',
  [ATTR_SERVICE_VERSION]: process.env.npm_package_version ?? '0.0.0',
});

const sdk = new NodeSDK({
  resource,
  traceExporter: new OTLPTraceExporter(),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter(),
    exportIntervalMillis: 60_000,
  }),
  logRecordProcessor: new BatchLogRecordProcessor(new OTLPLogExporter()),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false },
      '@opentelemetry/instrumentation-dns': { enabled: false },
    }),
  ],
});

sdk.start();

const shutdown = async () => {
  try {
    await sdk.shutdown();
    console.log('OpenTelemetry SDK shut down successfully');
  } catch (err) {
    console.error('Error shutting down OpenTelemetry SDK', err);
  } finally {
    process.exit(0);
  }
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

console.log(\`OpenTelemetry initialized for \${resource.attributes[ATTR_SERVICE_NAME]}\`);
JAVASCRIPT
  fi

  log_info "Created $filepath"
}

show_next_steps() {
  local ext="js"
  if [ "$USE_TYPESCRIPT" = true ]; then
    ext="ts"
  fi

  echo ""
  log_info "Setup complete! Next steps:"
  echo ""
  echo "  1. Set the Collector endpoint:"
  echo "     export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318"
  echo ""

  if [ "$USE_TYPESCRIPT" = true ]; then
    echo "  2. Compile and run with instrumentation loaded first:"
    echo "     npx tsc && node --require ./dist/instrumentation.js ./dist/app.js"
    echo ""
    echo "     Or for ts-node:"
    echo "     node --require ./instrumentation.ts ./app.ts  # with ts-node/register"
  else
    echo "  2. Run with instrumentation loaded first:"
    echo "     node --require ./instrumentation.js app.js"
  fi

  echo ""
  echo "  3. Or add to package.json scripts:"
  echo "     \"start\": \"node --require ./instrumentation.$ext app.$ext\""
  echo ""
  echo "  4. Verify traces appear in your backend (e.g., Jaeger at http://localhost:16686)"
  echo ""
}

main() {
  parse_args "$@"
  check_prereqs
  detect_service_name
  install_packages
  create_instrumentation_file
  show_next_steps
}

main "$@"
