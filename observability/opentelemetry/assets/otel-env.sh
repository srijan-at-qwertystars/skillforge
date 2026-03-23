#!/usr/bin/env bash
# otel-env.sh — Environment variables template for OpenTelemetry SDK configuration
#
# Usage:
#   source otel-env.sh                  # Load defaults (local development)
#   OTEL_ENV=production source otel-env.sh  # Load production settings
#
# Customize values below, then source this file before starting your application.

# =============================================================================
# Core Settings
# =============================================================================

# Service identity (REQUIRED — always set this)
export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-my-service}"
export OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES:-service.version=0.0.0,deployment.environment=${OTEL_ENV:-development}}"

# =============================================================================
# Exporter Configuration
# =============================================================================

# Collector endpoint — where telemetry is sent
# gRPC uses port 4317, HTTP uses port 4318
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}"
export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"

# Compression (recommended for production)
export OTEL_EXPORTER_OTLP_COMPRESSION="${OTEL_EXPORTER_OTLP_COMPRESSION:-gzip}"

# Authentication headers (uncomment and set for your backend)
# export OTEL_EXPORTER_OTLP_HEADERS="x-api-key=your-key-here"

# Per-signal endpoint overrides (uncomment if backends differ)
# export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://tempo:4318/v1/traces"
# export OTEL_EXPORTER_OTLP_METRICS_ENDPOINT="http://mimir:4318/v1/metrics"
# export OTEL_EXPORTER_OTLP_LOGS_ENDPOINT="http://loki:4318/v1/logs"

# =============================================================================
# Exporter Selection
# =============================================================================

export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-otlp}"

# =============================================================================
# Sampling
# =============================================================================

# Production: parentbased_traceidratio with 10% sampling
# Development: always_on for full visibility
if [ "${OTEL_ENV:-development}" = "production" ]; then
  export OTEL_TRACES_SAMPLER="${OTEL_TRACES_SAMPLER:-parentbased_traceidratio}"
  export OTEL_TRACES_SAMPLER_ARG="${OTEL_TRACES_SAMPLER_ARG:-0.1}"
else
  export OTEL_TRACES_SAMPLER="${OTEL_TRACES_SAMPLER:-always_on}"
  export OTEL_TRACES_SAMPLER_ARG="${OTEL_TRACES_SAMPLER_ARG:-}"
fi

# =============================================================================
# Context Propagation
# =============================================================================

export OTEL_PROPAGATORS="${OTEL_PROPAGATORS:-tracecontext,baggage}"

# =============================================================================
# Batch Processor Tuning
# =============================================================================

# Traces
export OTEL_BSP_SCHEDULE_DELAY="${OTEL_BSP_SCHEDULE_DELAY:-5000}"
export OTEL_BSP_MAX_QUEUE_SIZE="${OTEL_BSP_MAX_QUEUE_SIZE:-2048}"
export OTEL_BSP_MAX_EXPORT_BATCH_SIZE="${OTEL_BSP_MAX_EXPORT_BATCH_SIZE:-512}"
export OTEL_BSP_EXPORT_TIMEOUT="${OTEL_BSP_EXPORT_TIMEOUT:-30000}"

# Metrics export interval (ms)
export OTEL_METRIC_EXPORT_INTERVAL="${OTEL_METRIC_EXPORT_INTERVAL:-60000}"

# =============================================================================
# SDK Logging
# =============================================================================

# Set to 'debug' for troubleshooting, 'warn' or 'error' for production
if [ "${OTEL_ENV:-development}" = "production" ]; then
  export OTEL_LOG_LEVEL="${OTEL_LOG_LEVEL:-warn}"
else
  export OTEL_LOG_LEVEL="${OTEL_LOG_LEVEL:-info}"
fi

# =============================================================================
# Exemplars
# =============================================================================

export OTEL_METRICS_EXEMPLAR_FILTER="${OTEL_METRICS_EXEMPLAR_FILTER:-trace_based}"

# =============================================================================
# Runtime-specific settings
# =============================================================================

# Node.js
# export NODE_OPTIONS="--require ./instrumentation.js"

# Python
# export OTEL_PYTHON_LOG_CORRELATION="true"

# Java
# export JAVA_TOOL_OPTIONS="-javaagent:opentelemetry-javaagent.jar"

# =============================================================================
# Summary
# =============================================================================

echo "[otel-env] Loaded OpenTelemetry environment for: ${OTEL_SERVICE_NAME}"
echo "[otel-env] Endpoint: ${OTEL_EXPORTER_OTLP_ENDPOINT}"
echo "[otel-env] Sampler: ${OTEL_TRACES_SAMPLER} (${OTEL_TRACES_SAMPLER_ARG:-n/a})"
echo "[otel-env] Environment: ${OTEL_ENV:-development}"
