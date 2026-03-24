#!/usr/bin/env bash
# ============================================================================
# setup-otel.sh — Set up OpenTelemetry SDK with auto-instrumentation
# ============================================================================
#
# Usage:
#   ./setup-otel.sh [node|python] [--service-name NAME] [--collector-endpoint URL]
#
# Examples:
#   ./setup-otel.sh node --service-name order-service
#   ./setup-otel.sh python --service-name payment-service --collector-endpoint http://localhost:4317
#   ./setup-otel.sh node  # Uses defaults: service-name from package.json, collector at localhost:4317
#
# What it does:
#   1. Detects project type (Node.js or Python) if not specified
#   2. Installs OpenTelemetry SDK packages for the detected runtime
#   3. Creates a tracing setup file (tracing.js or tracing_setup.py)
#   4. Prints instructions for running with auto-instrumentation
#
# Requirements:
#   - Node.js: npm/yarn/pnpm installed, package.json present
#   - Python: pip installed, in a virtualenv recommended
# ============================================================================

set -euo pipefail

# --- Defaults ---
RUNTIME=""
SERVICE_NAME=""
COLLECTOR_ENDPOINT="http://localhost:4317"
FORCE=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    echo "Usage: $0 [node|python] [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --service-name NAME         Service name for OTel resource (default: from package.json/directory)"
    echo "  --collector-endpoint URL    OTel Collector endpoint (default: http://localhost:4317)"
    echo "  --force                     Overwrite existing tracing setup files"
    echo "  -h, --help                  Show this help"
    exit 0
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        node|python) RUNTIME="$1"; shift ;;
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --collector-endpoint) COLLECTOR_ENDPOINT="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

# --- Auto-detect runtime ---
if [[ -z "$RUNTIME" ]]; then
    if [[ -f "package.json" ]]; then
        RUNTIME="node"
        info "Detected Node.js project (package.json found)"
    elif [[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" || -f "Pipfile" ]]; then
        RUNTIME="python"
        info "Detected Python project"
    else
        error "Cannot detect project type. Specify 'node' or 'python' as first argument."
        exit 1
    fi
fi

# --- Auto-detect service name ---
if [[ -z "$SERVICE_NAME" ]]; then
    if [[ "$RUNTIME" == "node" && -f "package.json" ]]; then
        SERVICE_NAME=$(python3 -c "import json; print(json.load(open('package.json')).get('name', ''))" 2>/dev/null || echo "")
    fi
    if [[ -z "$SERVICE_NAME" ]]; then
        SERVICE_NAME=$(basename "$(pwd)")
    fi
    info "Using service name: $SERVICE_NAME"
fi

# ============================================================================
# Node.js Setup
# ============================================================================
setup_node() {
    info "Setting up OpenTelemetry for Node.js..."

    # Detect package manager
    local pm="npm"
    if [[ -f "yarn.lock" ]]; then pm="yarn"; fi
    if [[ -f "pnpm-lock.yaml" ]]; then pm="pnpm"; fi
    info "Using package manager: $pm"

    # Install OTel packages
    local packages=(
        "@opentelemetry/sdk-node"
        "@opentelemetry/api"
        "@opentelemetry/auto-instrumentations-node"
        "@opentelemetry/exporter-trace-otlp-grpc"
        "@opentelemetry/exporter-metrics-otlp-grpc"
        "@opentelemetry/sdk-metrics"
        "@opentelemetry/resources"
        "@opentelemetry/semantic-conventions"
    )

    info "Installing OpenTelemetry packages..."
    case $pm in
        npm)  npm install --save "${packages[@]}" ;;
        yarn) yarn add "${packages[@]}" ;;
        pnpm) pnpm add "${packages[@]}" ;;
    esac
    ok "Packages installed"

    # Create tracing.js
    local tracefile="tracing.js"
    if [[ -f "$tracefile" && "$FORCE" != true ]]; then
        warn "$tracefile already exists. Use --force to overwrite."
        return
    fi

    cat > "$tracefile" << NODEJS_EOF
// tracing.js — OpenTelemetry SDK initialization
// Load BEFORE app code: node --require ./tracing.js app.js
'use strict';

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-grpc');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { Resource } = require('@opentelemetry/resources');
const {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} = require('@opentelemetry/semantic-conventions');

const resource = new Resource({
  [ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || '${SERVICE_NAME}',
  [ATTR_SERVICE_VERSION]: process.env.npm_package_version || '0.0.0',
  'deployment.environment': process.env.NODE_ENV || 'development',
});

const collectorEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || '${COLLECTOR_ENDPOINT}';

const sdk = new NodeSDK({
  resource,
  traceExporter: new OTLPTraceExporter({ url: collectorEndpoint }),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter({ url: collectorEndpoint }),
    exportIntervalMillis: 15000,
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false },
      '@opentelemetry/instrumentation-dns': { enabled: false },
    }),
  ],
});

sdk.start();
console.log('[OTel] Tracing initialized for', resource.attributes[ATTR_SERVICE_NAME]);

const shutdown = async () => {
  try {
    await sdk.shutdown();
    console.log('[OTel] SDK shut down successfully');
  } catch (err) {
    console.error('[OTel] Error shutting down SDK:', err);
  }
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
NODEJS_EOF

    ok "Created $tracefile"
    echo ""
    info "Run your app with tracing:"
    echo "  node --require ./tracing.js app.js"
    echo ""
    info "Environment variables (override defaults):"
    echo "  OTEL_SERVICE_NAME=${SERVICE_NAME}"
    echo "  OTEL_EXPORTER_OTLP_ENDPOINT=${COLLECTOR_ENDPOINT}"
    echo "  OTEL_LOG_LEVEL=debug  # for troubleshooting"
}

# ============================================================================
# Python Setup
# ============================================================================
setup_python() {
    info "Setting up OpenTelemetry for Python..."

    local packages=(
        "opentelemetry-api"
        "opentelemetry-sdk"
        "opentelemetry-exporter-otlp-proto-grpc"
        "opentelemetry-instrumentation"
        "opentelemetry-distro"
    )

    info "Installing core OpenTelemetry packages..."
    pip install "${packages[@]}"
    ok "Core packages installed"

    # Auto-detect and install instrumentations
    info "Detecting available instrumentations..."
    opentelemetry-bootstrap -a install 2>/dev/null || warn "Auto-instrumentation detection skipped (run 'opentelemetry-bootstrap -a install' manually)"
    ok "Instrumentations installed"

    # Create tracing_setup.py
    local tracefile="tracing_setup.py"
    if [[ -f "$tracefile" && "$FORCE" != true ]]; then
        warn "$tracefile already exists. Use --force to overwrite."
        return
    fi

    cat > "$tracefile" << PYTHON_EOF
"""OpenTelemetry SDK initialization for Python.

Usage (programmatic):
    from tracing_setup import init_tracing
    init_tracing()  # Call BEFORE importing instrumented libraries

Usage (auto-instrumentation — preferred):
    opentelemetry-instrument --service_name ${SERVICE_NAME} python app.py
"""

import os
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource, SERVICE_NAME


def init_tracing(
    service_name: str = None,
    collector_endpoint: str = None,
    environment: str = None,
):
    """Initialize OpenTelemetry tracing and metrics.

    Args:
        service_name: Service name (default: OTEL_SERVICE_NAME env or '${SERVICE_NAME}')
        collector_endpoint: Collector gRPC endpoint (default: OTEL_EXPORTER_OTLP_ENDPOINT or '${COLLECTOR_ENDPOINT}')
        environment: Deployment environment (default: DEPLOY_ENV env or 'development')
    """
    service_name = service_name or os.getenv("OTEL_SERVICE_NAME", "${SERVICE_NAME}")
    collector_endpoint = collector_endpoint or os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "${COLLECTOR_ENDPOINT}")
    environment = environment or os.getenv("DEPLOY_ENV", "development")

    resource = Resource.create({
        SERVICE_NAME: service_name,
        "deployment.environment": environment,
    })

    # Traces
    tp = TracerProvider(resource=resource)
    tp.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(endpoint=collector_endpoint, insecure=True),
            max_queue_size=4096,
            max_export_batch_size=512,
            schedule_delay_millis=5000,
        )
    )
    trace.set_tracer_provider(tp)

    # Metrics
    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=collector_endpoint, insecure=True),
        export_interval_millis=15000,
    )
    metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[reader]))

    print(f"[OTel] Tracing initialized for {service_name}")


if __name__ == "__main__":
    init_tracing()
    print("[OTel] Setup complete. Import this module at app startup.")
PYTHON_EOF

    ok "Created $tracefile"
    echo ""
    info "Option 1 — Auto-instrumentation (recommended):"
    echo "  opentelemetry-instrument --service_name ${SERVICE_NAME} python app.py"
    echo ""
    info "Option 2 — Programmatic setup:"
    echo "  # At the TOP of your app entrypoint, before other imports:"
    echo "  from tracing_setup import init_tracing"
    echo "  init_tracing()"
    echo ""
    info "Environment variables (override defaults):"
    echo "  OTEL_SERVICE_NAME=${SERVICE_NAME}"
    echo "  OTEL_EXPORTER_OTLP_ENDPOINT=${COLLECTOR_ENDPOINT}"
    echo "  OTEL_LOG_LEVEL=debug  # for troubleshooting"
}

# ============================================================================
# Main
# ============================================================================
echo "================================================"
echo " OpenTelemetry SDK Setup"
echo " Runtime:   $RUNTIME"
echo " Service:   $SERVICE_NAME"
echo " Collector: $COLLECTOR_ENDPOINT"
echo "================================================"
echo ""

case "$RUNTIME" in
    node)   setup_node ;;
    python) setup_python ;;
    *)      error "Unsupported runtime: $RUNTIME"; exit 1 ;;
esac

echo ""
ok "OpenTelemetry setup complete!"
echo ""
info "Next steps:"
echo "  1. Start an OTel Collector (see assets/docker-compose.template.yml)"
echo "  2. Run your app with the tracing setup"
echo "  3. View traces in Jaeger: http://localhost:16686"
echo "  4. View metrics in Grafana: http://localhost:3000"
