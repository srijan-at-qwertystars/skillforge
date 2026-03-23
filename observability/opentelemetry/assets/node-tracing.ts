/**
 * OpenTelemetry Node.js Tracing Setup Module
 *
 * MUST be loaded before any application code:
 *   node --require ./dist/node-tracing.js app.js
 *
 * Or import as the first line in your entry point:
 *   import './node-tracing';
 *
 * Configuration via environment variables:
 *   OTEL_SERVICE_NAME             — Service name (required)
 *   OTEL_EXPORTER_OTLP_ENDPOINT   — Collector endpoint (default: http://localhost:4318)
 *   OTEL_EXPORTER_OTLP_PROTOCOL   — Protocol: grpc | http/protobuf (default: http/protobuf)
 *   OTEL_TRACES_SAMPLER            — Sampler (default: parentbased_traceidratio)
 *   OTEL_TRACES_SAMPLER_ARG        — Sample ratio (default: 1.0)
 *   OTEL_LOG_LEVEL                 — SDK log level: debug | info | warn | error
 */

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
import {
  envDetector,
  hostDetector,
  processDetector,
} from '@opentelemetry/resources';

// ---------------------------------------------------------------------------
// Resource — identifies this service in telemetry backends
// ---------------------------------------------------------------------------
const resource = new Resource({
  [ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME ?? 'unknown-service',
  [ATTR_SERVICE_VERSION]: process.env.npm_package_version ?? '0.0.0',
  'deployment.environment': process.env.NODE_ENV ?? 'development',
});

// ---------------------------------------------------------------------------
// Exporters
// ---------------------------------------------------------------------------
const traceExporter = new OTLPTraceExporter();

const metricReader = new PeriodicExportingMetricReader({
  exporter: new OTLPMetricExporter(),
  exportIntervalMillis: Number(process.env.OTEL_METRIC_EXPORT_INTERVAL ?? 60_000),
});

const logRecordProcessor = new BatchLogRecordProcessor(
  new OTLPLogExporter(),
);

// ---------------------------------------------------------------------------
// Auto-instrumentation configuration
// ---------------------------------------------------------------------------
const instrumentations = [
  getNodeAutoInstrumentations({
    // Disable noisy low-value instrumentations
    '@opentelemetry/instrumentation-fs': { enabled: false },
    '@opentelemetry/instrumentation-dns': { enabled: false },
    '@opentelemetry/instrumentation-net': { enabled: false },

    // Filter out health check spans
    '@opentelemetry/instrumentation-http': {
      ignoreIncomingRequestHook: (req) => {
        const url = req.url ?? '';
        return (
          url === '/healthz' ||
          url === '/readyz' ||
          url === '/livez' ||
          url === '/favicon.ico'
        );
      },
    },
  }),
];

// ---------------------------------------------------------------------------
// SDK initialization
// ---------------------------------------------------------------------------
const sdk = new NodeSDK({
  resource,
  traceExporter,
  metricReader,
  logRecordProcessor,
  instrumentations,
  resourceDetectors: [envDetector, hostDetector, processDetector],
});

sdk.start();

// ---------------------------------------------------------------------------
// Graceful shutdown — flush pending telemetry on process exit
// ---------------------------------------------------------------------------
const shutdown = async (signal: string) => {
  console.log(`[otel] Received ${signal}, shutting down SDK...`);
  try {
    await sdk.shutdown();
    console.log('[otel] SDK shut down successfully');
  } catch (err) {
    console.error('[otel] Error during SDK shutdown:', err);
  } finally {
    process.exit(0);
  }
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// Log startup confirmation
console.log(
  `[otel] Initialized: service=${resource.attributes[ATTR_SERVICE_NAME]}, ` +
  `endpoint=${process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? 'http://localhost:4318'}`
);
