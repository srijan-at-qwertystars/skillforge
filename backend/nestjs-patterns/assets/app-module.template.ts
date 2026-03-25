// =============================================================================
// Production AppModule Template
//
// Features:
//   - ConfigModule with validation (Joi)
//   - TypeORM database connection (async)
//   - JWT authentication
//   - Global validation pipe, exception filter, logging interceptor
//   - Swagger setup
//   - Health checks
//   - Rate limiting
//   - Graceful shutdown
//
// Usage: Copy and adapt to your project. Replace placeholder module imports.
// =============================================================================

import { Module, MiddlewareConsumer, NestModule } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { TerminusModule } from '@nestjs/terminus';
import { APP_GUARD, APP_FILTER, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import * as Joi from 'joi';

// ── Feature modules (replace with your own) ──────────────────────────────────
import { AuthModule } from './auth/auth.module';
import { UsersModule } from './users/users.module';
import { HealthModule } from './health/health.module';

// ── Common (guards, filters, interceptors) ───────────────────────────────────
import { JwtAuthGuard } from './common/guards/jwt-auth.guard';
import { AllExceptionsFilter } from './common/filters/all-exceptions.filter';
import { LoggingInterceptor } from './common/interceptors/logging.interceptor';
import { LoggerMiddleware } from './common/middleware/logger.middleware';

// ── Config namespaces ────────────────────────────────────────────────────────
import databaseConfig from './config/database.config';
import authConfig from './config/auth.config';

@Module({
  imports: [
    // ── Configuration ────────────────────────────────────────────────────────
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: [`.env.${process.env.NODE_ENV}`, '.env'],
      load: [databaseConfig, authConfig],
      validationSchema: Joi.object({
        NODE_ENV: Joi.string().valid('development', 'production', 'test').default('development'),
        PORT: Joi.number().default(3000),
        DATABASE_URL: Joi.string().required(),
        JWT_SECRET: Joi.string().required().min(32),
        JWT_EXPIRATION: Joi.string().default('1h'),
        CORS_ORIGIN: Joi.string().default('http://localhost:3000'),
        THROTTLE_TTL: Joi.number().default(60),
        THROTTLE_LIMIT: Joi.number().default(100),
      }),
      validationOptions: {
        abortEarly: false,
      },
    }),

    // ── Database ─────────────────────────────────────────────────────────────
    TypeOrmModule.forRootAsync({
      useFactory: (config: ConfigService) => ({
        type: 'postgres',
        url: config.get<string>('DATABASE_URL'),
        entities: [__dirname + '/**/*.entity{.ts,.js}'],
        synchronize: config.get('NODE_ENV') === 'development',
        migrations: [__dirname + '/database/migrations/*{.ts,.js}'],
        logging: config.get('NODE_ENV') === 'development' ? ['query', 'error'] : ['error'],
        ssl: config.get('NODE_ENV') === 'production'
          ? { rejectUnauthorized: false }
          : false,
        extra: {
          max: config.get('NODE_ENV') === 'production' ? 20 : 5,
          idleTimeoutMillis: 10000,
        },
      }),
      inject: [ConfigService],
    }),

    // ── Rate limiting ────────────────────────────────────────────────────────
    ThrottlerModule.forRootAsync({
      useFactory: (config: ConfigService) => ([{
        ttl: config.get<number>('THROTTLE_TTL', 60) * 1000,
        limit: config.get<number>('THROTTLE_LIMIT', 100),
      }]),
      inject: [ConfigService],
    }),

    // ── Health checks ────────────────────────────────────────────────────────
    TerminusModule,

    // ── Feature modules ──────────────────────────────────────────────────────
    AuthModule,
    UsersModule,
    HealthModule,
  ],

  providers: [
    // Global JWT auth guard (use @Public() decorator to skip)
    { provide: APP_GUARD, useClass: JwtAuthGuard },

    // Global rate limiting
    { provide: APP_GUARD, useClass: ThrottlerGuard },

    // Global validation pipe
    {
      provide: APP_PIPE,
      useValue: new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
        transformOptions: { enableImplicitConversion: true },
      }),
    },

    // Global exception filter
    { provide: APP_FILTER, useClass: AllExceptionsFilter },

    // Global logging interceptor
    { provide: APP_INTERCEPTOR, useClass: LoggingInterceptor },
  ],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    consumer.apply(LoggerMiddleware).forRoutes('*');
  }
}

// =============================================================================
// main.ts bootstrap (place in src/main.ts)
// =============================================================================
/*
import { NestFactory } from '@nestjs/core';
import { ConfigService } from '@nestjs/config';
import { SwaggerModule, DocumentBuilder } from '@nestjs/swagger';
import { Logger } from 'nestjs-pino'; // or nest-winston
import helmet from 'helmet';
import compression from 'compression';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  const config = app.get(ConfigService);

  // Security
  app.use(helmet());
  app.use(compression());
  app.enableCors({ origin: config.get('CORS_ORIGIN') });

  // API prefix
  app.setGlobalPrefix('api/v1', { exclude: ['health'] });

  // Swagger (non-production only)
  if (config.get('NODE_ENV') !== 'production') {
    const swaggerConfig = new DocumentBuilder()
      .setTitle('API Documentation')
      .setVersion('1.0')
      .addBearerAuth()
      .build();
    const document = SwaggerModule.createDocument(app, swaggerConfig);
    SwaggerModule.setup('docs', app, document);
  }

  // Graceful shutdown
  app.enableShutdownHooks();

  const port = config.get<number>('PORT', 3000);
  await app.listen(port);
  console.log(`🚀 Application running on port ${port}`);
}
bootstrap();
*/
