/**
 * Node.js Logging Configuration — Pino
 *
 * Production-ready structured logging with:
 *   - JSON output with consistent schema
 *   - PII redaction
 *   - Request context via child loggers
 *   - Pretty printing in development
 *   - Log level from environment
 *
 * Install: npm install pino pino-pretty
 *
 * Usage:
 *   import { logger, createRequestLogger } from './nodejs-pino.js';
 *   logger.info({ userId: '123' }, 'User logged in');
 */

import pino from 'pino';
import crypto from 'node:crypto';

// ---- Base Logger ----
export const logger = pino({
  level: process.env.LOG_LEVEL || 'info',

  // Use label instead of numeric level
  formatters: {
    level: (label) => ({ level: label }),
    bindings: (bindings) => ({
      service: process.env.SERVICE_NAME || 'app',
      environment: process.env.NODE_ENV || 'development',
      version: process.env.APP_VERSION || '0.0.0',
      pid: bindings.pid,
      hostname: bindings.hostname,
    }),
  },

  // ISO timestamp
  timestamp: pino.stdTimeFunctions.isoTime,

  // Redact sensitive fields
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers.cookie',
      'user.email',
      'user.ssn',
      '*.password',
      '*.token',
      '*.secret',
      '*.creditCard',
    ],
    censor: '[REDACTED]',
  },

  // Pretty print in development only
  transport:
    process.env.NODE_ENV === 'development'
      ? { target: 'pino-pretty', options: { colorize: true, translateTime: 'HH:MM:ss.l' } }
      : undefined,
});

// ---- Request Logger (Express/Fastify middleware) ----
export function createRequestLogger(req) {
  return logger.child({
    request_id: req.headers['x-request-id'] || crypto.randomUUID(),
    trace_id: req.headers['x-trace-id'] || req.headers.traceparent?.split('-')[1],
    user_id: req.user?.id,
    method: req.method,
    path: req.url,
  });
}

// ---- Express Middleware ----
export function loggingMiddleware(req, res, next) {
  const start = process.hrtime.bigint();
  req.log = createRequestLogger(req);

  // Log response on finish
  res.on('finish', () => {
    const duration_ms = Number(process.hrtime.bigint() - start) / 1e6;
    const logFn = res.statusCode >= 500 ? req.log.error : res.statusCode >= 400 ? req.log.warn : req.log.info;
    logFn.call(req.log, {
      status: res.statusCode,
      duration_ms: Math.round(duration_ms * 100) / 100,
      content_length: res.getHeader('content-length'),
    }, 'Request completed');
  });

  next();
}

// ---- Usage Example ----
// import express from 'express';
// const app = express();
// app.use(loggingMiddleware);
// app.get('/', (req, res) => {
//   req.log.info({ action: 'homepage' }, 'Serving homepage');
//   res.send('OK');
// });
