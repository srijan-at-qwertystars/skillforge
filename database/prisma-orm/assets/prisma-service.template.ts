// ==============================================================================
// PrismaService — Singleton Prisma Client
//
// Works with:
//   - NestJS (implements OnModuleInit/OnModuleDestroy)
//   - Standalone Node.js apps
//   - Next.js (with global singleton for hot-reload)
//
// Features:
//   - Connection lifecycle management
//   - Query logging (configurable)
//   - Graceful shutdown hooks
//   - Slow query warnings
//   - Health check method
//
// Usage (NestJS):
//   @Module({ providers: [PrismaService], exports: [PrismaService] })
//   export class PrismaModule {}
//
// Usage (standalone):
//   import { prisma } from './prisma-service'
// ==============================================================================

import { PrismaClient, Prisma } from '@prisma/client'

// =============================================================================
// Configuration
// =============================================================================

const LOG_LEVELS: Prisma.LogLevel[] =
  process.env.NODE_ENV === 'production'
    ? ['warn', 'error']
    : ['query', 'info', 'warn', 'error']

const SLOW_QUERY_THRESHOLD_MS = Number(process.env.PRISMA_SLOW_QUERY_MS ?? 500)

// =============================================================================
// PrismaService — NestJS compatible
// =============================================================================

// NestJS lifecycle interfaces (inline to avoid @nestjs/common dependency)
interface OnModuleInit {
  onModuleInit(): Promise<void> | void
}
interface OnModuleDestroy {
  onModuleDestroy(): Promise<void> | void
}

export class PrismaService
  extends PrismaClient
  implements OnModuleInit, OnModuleDestroy
{
  constructor() {
    super({
      log: LOG_LEVELS.map((level) => ({
        level,
        emit: level === 'query' ? ('event' as const) : ('stdout' as const),
      })),
      errorFormat: 'pretty',
    })

    this.setupQueryLogging()
  }

  async onModuleInit(): Promise<void> {
    await this.$connect()
    console.log('[PrismaService] Connected to database')
  }

  async onModuleDestroy(): Promise<void> {
    await this.$disconnect()
    console.log('[PrismaService] Disconnected from database')
  }

  /**
   * Health check — verifies database connectivity.
   * Use in /health endpoint.
   */
  async healthCheck(): Promise<{ status: 'ok' | 'error'; latencyMs: number; error?: string }> {
    const start = Date.now()
    try {
      await this.$queryRaw`SELECT 1`
      return { status: 'ok', latencyMs: Date.now() - start }
    } catch (e) {
      return {
        status: 'error',
        latencyMs: Date.now() - start,
        error: e instanceof Error ? e.message : String(e),
      }
    }
  }

  /**
   * Enable graceful shutdown on SIGINT/SIGTERM.
   * Call once at app startup (not needed for NestJS — handled by lifecycle hooks).
   */
  enableShutdownHooks(): void {
    const shutdown = async (signal: string) => {
      console.log(`[PrismaService] Received ${signal}, disconnecting...`)
      await this.$disconnect()
      process.exit(0)
    }
    process.on('SIGINT', () => shutdown('SIGINT'))
    process.on('SIGTERM', () => shutdown('SIGTERM'))
  }

  private setupQueryLogging(): void {
    // Log slow queries in all environments
    this.$on('query' as never, ((e: Prisma.QueryEvent) => {
      if (e.duration > SLOW_QUERY_THRESHOLD_MS) {
        console.warn(
          `[PrismaService] Slow query (${e.duration}ms):`,
          e.query,
          '\nParams:',
          e.params,
        )
      }
    }) as never)
  }
}

// =============================================================================
// Singleton for standalone / Next.js usage
// =============================================================================

const globalForPrisma = globalThis as unknown as {
  __prisma: PrismaService | undefined
}

/**
 * Singleton PrismaService instance.
 * In development, survives hot-reload via globalThis caching.
 */
export const prisma: PrismaService =
  globalForPrisma.__prisma ??
  (() => {
    const service = new PrismaService()
    service.enableShutdownHooks()
    return service
  })()

if (process.env.NODE_ENV !== 'production') {
  globalForPrisma.__prisma = prisma
}

export default prisma
