/**
 * Production Fastify Application Template
 *
 * Features:
 * - App factory pattern (testable, no listen in buildApp)
 * - Graceful shutdown with drain period
 * - Structured logging (pino)
 * - Global error handling
 * - Health check endpoint
 * - Autoloaded plugins and routes
 * - TypeScript with strict mode
 *
 * Usage:
 *   Copy to src/app.ts and src/server.ts (split as shown).
 *   Adjust plugin/route paths and configuration to your project.
 */

// ═══════════════════════════════════════════════════════════════════════════
// src/app.ts — Application Factory
// ═══════════════════════════════════════════════════════════════════════════

import Fastify, { FastifyInstance, FastifyServerOptions } from 'fastify';
import autoLoad from '@fastify/autoload';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export function buildApp(opts: FastifyServerOptions = {}): FastifyInstance {
  const app = Fastify({
    // Logging
    logger: opts.logger ?? {
      level: process.env.LOG_LEVEL || 'info',
      ...(process.env.NODE_ENV !== 'production' && {
        transport: { target: 'pino-pretty', options: { translateTime: 'HH:MM:ss' } },
      }),
    },

    // Security
    trustProxy: process.env.TRUST_PROXY === 'true',
    onProtoPoisoning: 'error',
    onConstructorPoisoning: 'error',

    // Performance
    caseSensitive: true,
    ignoreTrailingSlash: false,
    forceCloseConnections: true,

    // Timeouts
    requestTimeout: 30_000,
    pluginTimeout: 15_000,

    // Request ID for distributed tracing
    requestIdHeader: 'x-request-id',
    genReqId: (req) =>
      (req.headers['x-request-id'] as string) || crypto.randomUUID(),

    ...opts,
  });

  // ── Global Error Handler ──────────────────────────────────────────────────
  app.setErrorHandler((error, request, reply) => {
    request.log.error({ err: error }, 'request error');

    if (error.validation) {
      return reply.code(400).send({
        error: 'Validation Error',
        message: error.message,
        details: error.validation,
      });
    }

    const statusCode = error.statusCode ?? 500;
    reply.code(statusCode).send({
      error: statusCode >= 500 ? 'Internal Server Error' : error.message,
      statusCode,
      requestId: request.id,
    });
  });

  // ── Not Found Handler ─────────────────────────────────────────────────────
  app.setNotFoundHandler((request, reply) => {
    reply.code(404).send({
      error: 'Not Found',
      message: `Route ${request.method} ${request.url} not found`,
      statusCode: 404,
    });
  });

  // ── Health Check (registered before autoload) ─────────────────────────────
  let isShuttingDown = false;

  app.get('/health', {
    logLevel: 'warn',
    schema: {
      response: {
        200: {
          type: 'object',
          properties: {
            status: { type: 'string' },
            uptime: { type: 'number' },
            timestamp: { type: 'string' },
          },
        },
      },
    },
  }, async (_request, reply) => {
    if (isShuttingDown) {
      return reply.code(503).send({ status: 'draining' });
    }
    return {
      status: 'ok',
      uptime: process.uptime(),
      timestamp: new Date().toISOString(),
    };
  });

  // Expose shutdown flag setter for server.ts
  app.decorate('setShuttingDown', () => { isShuttingDown = true; });

  // ── Autoload Plugins ──────────────────────────────────────────────────────
  app.register(autoLoad, {
    dir: join(__dirname, 'plugins'),
    forceESM: true,
  });

  // ── Autoload Routes ───────────────────────────────────────────────────────
  app.register(autoLoad, {
    dir: join(__dirname, 'routes'),
    dirNameRoutePrefix: true,
    forceESM: true,
    options: { prefix: '/api' },
  });

  return app;
}

// ═══════════════════════════════════════════════════════════════════════════
// src/server.ts — Entry Point (Graceful Startup + Shutdown)
// ═══════════════════════════════════════════════════════════════════════════

async function start() {
  const app = buildApp();

  const port = parseInt(process.env.PORT || '3000', 10);
  const host = process.env.HOST || '0.0.0.0';

  await app.listen({ port, host });

  // ── Graceful Shutdown ───────────────────────────────────────────────────
  async function shutdown(signal: string) {
    app.log.info({ signal }, 'shutdown signal received');

    // Mark as draining so health checks return 503
    (app as any).setShuttingDown();

    // Wait for load balancer to detect unhealthy
    const drainMs = parseInt(process.env.SHUTDOWN_DRAIN_MS || '5000', 10);
    await new Promise((resolve) => setTimeout(resolve, drainMs));

    // Close server (stops new connections, drains existing)
    await app.close();
    app.log.info('server shut down cleanly');
    process.exit(0);
  }

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => shutdown(signal));
  }

  process.on('uncaughtException', (err) => {
    app.log.fatal(err, 'uncaught exception');
    process.exit(1);
  });

  process.on('unhandledRejection', (reason) => {
    app.log.fatal({ reason }, 'unhandled rejection');
    process.exit(1);
  });
}

start();
