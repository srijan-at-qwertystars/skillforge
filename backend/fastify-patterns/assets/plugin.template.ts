/**
 * Fastify Plugin Template
 *
 * This template shows a production-quality plugin with:
 * - Typed options interface
 * - Instance and request decorators
 * - Lifecycle hooks (onRequest, onClose)
 * - TypeScript declaration merging
 * - Dependency declaration
 *
 * Usage:
 *   1. Copy this file to src/plugins/<your-plugin-name>.ts
 *   2. Rename the interface, plugin, and decorator names
 *   3. Implement your logic
 *   4. Keep the declaration merging at the bottom
 */

import fp from 'fastify-plugin';
import { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';

// ── Plugin Options ──────────────────────────────────────────────────────────

export interface MyPluginOptions {
  /** Connection string or URL for the service */
  connectionString: string;
  /** Maximum number of retries on failure (default: 3) */
  maxRetries?: number;
  /** Enable request-scoped context (default: true) */
  enableRequestContext?: boolean;
}

// ── Service Class (optional — encapsulate complex logic) ────────────────────

class MyService {
  private connectionString: string;
  private maxRetries: number;

  constructor(opts: Required<Pick<MyPluginOptions, 'connectionString' | 'maxRetries'>>) {
    this.connectionString = opts.connectionString;
    this.maxRetries = opts.maxRetries;
  }

  async connect(): Promise<void> {
    // Initialize connections, verify connectivity
    // await client.connect(this.connectionString);
  }

  async close(): Promise<void> {
    // Clean up connections
    // await client.close();
  }

  async query(sql: string, params?: unknown[]): Promise<unknown> {
    // Execute query with retry logic
    let lastError: Error | undefined;
    for (let attempt = 0; attempt < this.maxRetries; attempt++) {
      try {
        // return await client.query(sql, params);
        return { rows: [], sql, params };
      } catch (err) {
        lastError = err as Error;
        if (attempt < this.maxRetries - 1) {
          await new Promise((r) => setTimeout(r, 100 * Math.pow(2, attempt)));
        }
      }
    }
    throw lastError;
  }
}

// ── Plugin Implementation ───────────────────────────────────────────────────

export default fp<MyPluginOptions>(
  async (fastify: FastifyInstance, opts) => {
    const { connectionString, maxRetries = 3, enableRequestContext = true } = opts;

    // Create and connect service
    const service = new MyService({ connectionString, maxRetries });
    await service.connect();
    fastify.log.info('my-plugin: connected');

    // Decorate instance — accessible as fastify.myService
    fastify.decorate('myService', service);

    // Decorate request — set per-request in hook
    if (enableRequestContext) {
      fastify.decorateRequest('requestContext', null);

      fastify.addHook('onRequest', async (request: FastifyRequest) => {
        request.requestContext = {
          requestId: request.id,
          startedAt: Date.now(),
        };
      });
    }

    // Clean up on server close
    fastify.addHook('onClose', async () => {
      fastify.log.info('my-plugin: closing');
      await service.close();
    });
  },
  {
    name: 'my-plugin',
    // Uncomment to declare dependencies on other plugins:
    // dependencies: ['config'],
    fastify: '5.x',
  },
);

// ── TypeScript Declaration Merging ──────────────────────────────────────────
// Move this to src/types/fastify.d.ts in a real project

declare module 'fastify' {
  interface FastifyInstance {
    myService: InstanceType<typeof MyService>;
  }
  interface FastifyRequest {
    requestContext: {
      requestId: string;
      startedAt: number;
    } | null;
  }
}
