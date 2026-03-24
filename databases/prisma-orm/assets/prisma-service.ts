// =============================================================================
// PrismaClient Singleton Service
//
// Features:
//   - Singleton pattern (safe for Next.js hot reload, serverless)
//   - Configurable logging per environment
//   - Graceful shutdown handling
//   - Health check method
//   - Query event logging (optional)
//
// Usage:
//   import { prisma, PrismaService } from './prisma-service';
//
//   // Use the singleton client directly
//   const users = await prisma.user.findMany();
//
//   // Or use the service class for lifecycle management
//   const service = PrismaService.getInstance();
//   await service.healthCheck();
//   await service.disconnect();
// =============================================================================

import { PrismaClient, Prisma } from '@prisma/client';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

type LogLevel = Prisma.LogLevel;
type LogDefinition = Prisma.LogDefinition;

function getLogConfig(): LogDefinition[] {
  const env = process.env.NODE_ENV ?? 'development';

  switch (env) {
    case 'production':
      return [
        { level: 'error', emit: 'stdout' },
        { level: 'warn', emit: 'stdout' },
      ];
    case 'test':
      return [{ level: 'error', emit: 'stdout' }];
    default:
      return [
        { level: 'query', emit: 'event' },
        { level: 'error', emit: 'stdout' },
        { level: 'warn', emit: 'stdout' },
        { level: 'info', emit: 'stdout' },
      ];
  }
}

// ---------------------------------------------------------------------------
// Singleton Client
// ---------------------------------------------------------------------------

const globalForPrisma = globalThis as unknown as {
  __prisma: PrismaClient | undefined;
};

function createPrismaClient(): PrismaClient {
  const client = new PrismaClient({
    log: getLogConfig(),
    errorFormat: process.env.NODE_ENV === 'production' ? 'minimal' : 'pretty',
  });

  // Log slow queries in development
  if (process.env.NODE_ENV !== 'production') {
    client.$on('query' as never, (e: any) => {
      if (e.duration > 100) {
        console.warn(`⚠ Slow query (${e.duration}ms): ${e.query}`);
      }
    });
  }

  return client;
}

/** Singleton PrismaClient instance — safe for hot reload and serverless. */
export const prisma: PrismaClient =
  globalForPrisma.__prisma ?? createPrismaClient();

if (process.env.NODE_ENV !== 'production') {
  globalForPrisma.__prisma = prisma;
}

// ---------------------------------------------------------------------------
// PrismaService — lifecycle & health checks
// ---------------------------------------------------------------------------

export class PrismaService {
  private static instance: PrismaService;
  private readonly client: PrismaClient;
  private isConnected = false;

  private constructor(client: PrismaClient) {
    this.client = client;
    this.setupShutdownHooks();
  }

  static getInstance(): PrismaService {
    if (!PrismaService.instance) {
      PrismaService.instance = new PrismaService(prisma);
    }
    return PrismaService.instance;
  }

  /** Get the underlying PrismaClient. */
  getClient(): PrismaClient {
    return this.client;
  }

  /** Connect to the database explicitly (optional — Prisma lazy-connects). */
  async connect(): Promise<void> {
    if (!this.isConnected) {
      await this.client.$connect();
      this.isConnected = true;
    }
  }

  /** Disconnect from the database. */
  async disconnect(): Promise<void> {
    if (this.isConnected) {
      await this.client.$disconnect();
      this.isConnected = false;
    }
  }

  /**
   * Health check — verifies the database connection is alive.
   * Returns an object with status and latency.
   */
  async healthCheck(): Promise<{
    status: 'ok' | 'error';
    latencyMs: number;
    message?: string;
  }> {
    const start = performance.now();
    try {
      await this.client.$queryRaw`SELECT 1`;
      return {
        status: 'ok',
        latencyMs: Math.round(performance.now() - start),
      };
    } catch (error) {
      return {
        status: 'error',
        latencyMs: Math.round(performance.now() - start),
        message: error instanceof Error ? error.message : 'Unknown error',
      };
    }
  }

  /** Register graceful shutdown hooks for SIGINT/SIGTERM. */
  private setupShutdownHooks(): void {
    const shutdown = async (signal: string) => {
      console.log(`\n${signal} received — disconnecting Prisma...`);
      await this.disconnect();
      process.exit(0);
    };

    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));

    // Handle uncaught errors gracefully
    process.on('beforeExit', async () => {
      await this.disconnect();
    });
  }
}

// ---------------------------------------------------------------------------
// Default export for convenience
// ---------------------------------------------------------------------------

export default prisma;
