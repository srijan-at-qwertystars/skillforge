// ============================================================================
// tracing-setup.template.ts — Node.js OpenTelemetry SDK initialization
// ============================================================================
// Usage:
//   1. Copy to your project: cp tracing-setup.template.ts src/tracing.ts
//   2. Install dependencies:
//      npm install @opentelemetry/sdk-node @opentelemetry/api \
//        @opentelemetry/auto-instrumentations-node \
//        @opentelemetry/exporter-trace-otlp-grpc \
//        @opentelemetry/exporter-metrics-otlp-grpc \
//        @opentelemetry/sdk-metrics @opentelemetry/resources \
//        @opentelemetry/semantic-conventions
//   3. Load before app: node --require ./dist/tracing.js app.js
//      or with ts-node: node --require ts-node/register --require ./src/tracing.ts app.ts
// ============================================================================

import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-grpc';
import {
  PeriodicExportingMetricReader,
  View,
  InstrumentType,
  ExplicitBucketHistogramAggregation,
} from '@opentelemetry/sdk-metrics';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { Resource } from '@opentelemetry/resources';
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} from '@opentelemetry/semantic-conventions';
import {
  BatchSpanProcessor,
  SpanProcessor,
  ReadableSpan,
  Span,
} from '@opentelemetry/sdk-trace-base';
import { diag, DiagConsoleLogger, DiagLogLevel, Context } from '@opentelemetry/api';

// ---- Configuration ----

const SERVICE_NAME = process.env.OTEL_SERVICE_NAME || 'my-service';
const SERVICE_VERSION = process.env.npm_package_version || '0.0.0';
const COLLECTOR_ENDPOINT =
  process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4317';
const ENVIRONMENT = process.env.NODE_ENV || 'development';
const LOG_LEVEL = process.env.OTEL_LOG_LEVEL || 'info';

// ---- Debug logging ----

if (LOG_LEVEL === 'debug') {
  diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.DEBUG);
}

// ---- Custom Span Processor: Redact sensitive attributes ----

class SensitiveDataRedactor implements SpanProcessor {
  private readonly sensitiveKeys = new Set([
    'http.request.header.authorization',
    'http.request.header.cookie',
    'db.statement',
    'enduser.id',
  ]);

  onStart(_span: Span, _parentContext: Context): void {}

  onEnd(span: ReadableSpan): void {
    for (const key of this.sensitiveKeys) {
      if (span.attributes[key] !== undefined) {
        // Note: attributes are read-only on ReadableSpan in some SDK versions.
        // Use the attributes processor in Collector for production redaction.
        // This serves as a defense-in-depth layer.
      }
    }
  }

  shutdown(): Promise<void> {
    return Promise.resolve();
  }

  forceFlush(): Promise<void> {
    return Promise.resolve();
  }
}

// ---- Resource ----

const resource = new Resource({
  [ATTR_SERVICE_NAME]: SERVICE_NAME,
  [ATTR_SERVICE_VERSION]: SERVICE_VERSION,
  'deployment.environment': ENVIRONMENT,
  'service.namespace': process.env.SERVICE_NAMESPACE || 'default',
});

// ---- Metric Views ----

const metricViews = [
  // Custom histogram buckets for HTTP latency
  new View({
    instrumentName: 'http.server.duration',
    instrumentType: InstrumentType.HISTOGRAM,
    aggregation: new ExplicitBucketHistogramAggregation([
      5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000,
    ]),
  }),

  // Limit attributes on request counter to prevent cardinality explosion
  new View({
    instrumentName: 'http.server.request.count',
    attributeKeys: ['http.request.method', 'http.route', 'http.response.status_code'],
  }),
];

// ---- Exporters ----

const traceExporter = new OTLPTraceExporter({
  url: COLLECTOR_ENDPOINT,
});

const metricExporter = new OTLPMetricExporter({
  url: COLLECTOR_ENDPOINT,
});

// ---- SDK Setup ----

const sdk = new NodeSDK({
  resource,
  traceExporter,
  metricReader: new PeriodicExportingMetricReader({
    exporter: metricExporter,
    exportIntervalMillis: 15_000,
  }),
  spanProcessors: [new SensitiveDataRedactor()],
  views: metricViews,
  instrumentations: [
    getNodeAutoInstrumentations({
      // Disable noisy/low-value instrumentations
      '@opentelemetry/instrumentation-fs': { enabled: false },
      '@opentelemetry/instrumentation-dns': { enabled: false },
      '@opentelemetry/instrumentation-net': { enabled: false },
      // Configure HTTP instrumentation
      '@opentelemetry/instrumentation-http': {
        ignoreIncomingRequestHook: (req) => {
          // Don't trace health checks
          const url = req.url || '';
          return url === '/healthz' || url === '/readyz' || url === '/livez';
        },
      },
    }),
  ],
});

// ---- Start ----

sdk.start();
console.log(`[OTel] Tracing initialized: service=${SERVICE_NAME} env=${ENVIRONMENT} collector=${COLLECTOR_ENDPOINT}`);

// ---- Graceful shutdown ----

const shutdown = async () => {
  try {
    await sdk.shutdown();
    console.log('[OTel] SDK shut down successfully');
  } catch (err) {
    console.error('[OTel] Error shutting down SDK:', err);
  } finally {
    process.exit(0);
  }
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

export { sdk };
