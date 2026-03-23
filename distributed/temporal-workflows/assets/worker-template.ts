/**
 * Temporal Worker Template — TypeScript
 *
 * Production-ready worker configuration with:
 * - Graceful shutdown handling
 * - mTLS support (Temporal Cloud)
 * - Configurable concurrency limits
 * - OpenTelemetry tracing integration
 * - Health check endpoint
 *
 * Usage: Copy and adapt for your deployment.
 */
import { Worker, NativeConnection, Runtime } from '@temporalio/worker';
import * as activities from './activities';
import { createServer } from 'http';
import { readFileSync } from 'fs';

// --- Configuration ---

interface WorkerConfig {
  address: string;
  namespace: string;
  taskQueue: string;
  // mTLS (for Temporal Cloud or secured self-hosted)
  tlsCertPath?: string;
  tlsKeyPath?: string;
  // Tuning
  maxConcurrentActivities: number;
  maxConcurrentWorkflows: number;
  maxCachedWorkflows: number;
  // Health check
  healthCheckPort: number;
}

function loadConfig(): WorkerConfig {
  return {
    address: process.env.TEMPORAL_ADDRESS ?? 'localhost:7233',
    namespace: process.env.TEMPORAL_NAMESPACE ?? 'default',
    taskQueue: process.env.TEMPORAL_TASK_QUEUE ?? 'default-queue',
    tlsCertPath: process.env.TEMPORAL_TLS_CERT,
    tlsKeyPath: process.env.TEMPORAL_TLS_KEY,
    maxConcurrentActivities: parseInt(process.env.MAX_CONCURRENT_ACTIVITIES ?? '100', 10),
    maxConcurrentWorkflows: parseInt(process.env.MAX_CONCURRENT_WORKFLOWS ?? '40', 10),
    maxCachedWorkflows: parseInt(process.env.MAX_CACHED_WORKFLOWS ?? '600', 10),
    healthCheckPort: parseInt(process.env.HEALTH_CHECK_PORT ?? '8081', 10),
  };
}

// --- Health Check Server ---

function startHealthCheck(port: number, isHealthy: () => boolean): void {
  const server = createServer((req, res) => {
    if (req.url === '/health' || req.url === '/healthz') {
      if (isHealthy()) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'healthy', timestamp: new Date().toISOString() }));
      } else {
        res.writeHead(503, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'unhealthy', timestamp: new Date().toISOString() }));
      }
    } else if (req.url === '/ready') {
      res.writeHead(200);
      res.end('ok');
    } else {
      res.writeHead(404);
      res.end();
    }
  });

  server.listen(port, () => {
    console.log(`Health check endpoint: http://localhost:${port}/health`);
  });
}

// --- Main ---

async function run(): Promise<void> {
  const config = loadConfig();
  let workerRunning = false;

  // Configure runtime (call before creating connection/worker)
  Runtime.install({
    logger: {
      // Forward Temporal SDK logs to your logging framework
      log: (level, message, meta) => {
        const ts = new Date().toISOString();
        console.log(`[${ts}] [${level}] ${message}`, meta ?? '');
      },
      trace: () => {},
      debug: () => {},
      info: (message, meta) => console.log(`[INFO] ${message}`, meta ?? ''),
      warn: (message, meta) => console.warn(`[WARN] ${message}`, meta ?? ''),
      error: (message, meta) => console.error(`[ERROR] ${message}`, meta ?? ''),
    },
    // Telemetry options (uncomment for OpenTelemetry)
    // telemetryOptions: {
    //   metrics: {
    //     prometheus: { bindAddress: '0.0.0.0:9464' },
    //   },
    //   tracing: {
    //     otel: {
    //       url: 'http://localhost:4317',
    //       headers: {},
    //     },
    //   },
    // },
  });

  // Build TLS config if certificates are provided
  const tls = config.tlsCertPath && config.tlsKeyPath
    ? {
        clientCertPair: {
          crt: readFileSync(config.tlsCertPath),
          key: readFileSync(config.tlsKeyPath),
        },
      }
    : undefined;

  // Connect to Temporal server
  const connection = await NativeConnection.connect({
    address: config.address,
    tls,
  });

  console.log(`Connected to Temporal at ${config.address}`);

  // Create worker
  const worker = await Worker.create({
    connection,
    namespace: config.namespace,
    workflowsPath: require.resolve('./workflows'),
    activities,
    taskQueue: config.taskQueue,

    // Concurrency tuning
    maxConcurrentActivityTaskExecutions: config.maxConcurrentActivities,
    maxConcurrentWorkflowTaskExecutions: config.maxConcurrentWorkflows,
    maxCachedWorkflows: config.maxCachedWorkflows,

    // Activity task polling
    maxConcurrentActivityTaskPolls: 5,
    maxConcurrentWorkflowTaskPolls: 5,

    // Graceful shutdown — allow in-flight tasks to complete
    shutdownGraceTime: '30s',

    // Enable sticky execution (default, for performance)
    enableSDKTracing: false,

    // Interceptors (uncomment to enable)
    // interceptors: {
    //   workflowModules: [require.resolve('./interceptors')],
    //   activityInbound: [(ctx) => new MyActivityInterceptor(ctx)],
    // },

    // Data converter for payload encryption (uncomment to enable)
    // dataConverter: {
    //   payloadCodecPath: require.resolve('./encryption-codec'),
    // },
  });

  workerRunning = true;

  // Start health check
  startHealthCheck(config.healthCheckPort, () => workerRunning);

  // Graceful shutdown
  const shutdown = async (signal: string) => {
    console.log(`Received ${signal}, shutting down gracefully...`);
    workerRunning = false;
    worker.shutdown();
    // Worker.run() will resolve after in-flight tasks complete
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  console.log(`Worker started on task queue: ${config.taskQueue}`);
  console.log(`  Namespace: ${config.namespace}`);
  console.log(`  Max concurrent activities: ${config.maxConcurrentActivities}`);
  console.log(`  Max concurrent workflows: ${config.maxConcurrentWorkflows}`);
  console.log(`  Max cached workflows: ${config.maxCachedWorkflows}`);

  // Run the worker (blocks until shutdown)
  await worker.run();

  console.log('Worker stopped');
  await connection.close();
}

run().catch((err) => {
  console.error('Worker failed to start:', err);
  process.exit(1);
});
