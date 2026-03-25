# NestJS Troubleshooting Reference

> Diagnosis and fixes for common NestJS errors, performance issues, and production problems.

## Table of Contents

- [Common Errors](#common-errors)
  - [Circular Dependency Detected](#circular-dependency-detected)
  - [Nest Can't Resolve Dependencies](#nest-cant-resolve-dependencies)
  - [Scope Bubbling Issues](#scope-bubbling-issues)
  - [Unknown Element / Missing Module](#unknown-element--missing-module)
- [Performance Bottlenecks](#performance-bottlenecks)
- [Memory Leaks](#memory-leaks)
- [Testing Pitfalls](#testing-pitfalls)
- [Migration from Express](#migration-from-express)
- [Debugging Techniques](#debugging-techniques)
- [Production Deployment Issues](#production-deployment-issues)

---

## Common Errors

### Circular Dependency Detected

**Error message:**
```
Error: Nest cannot create the <ModuleName> instance.
A circular dependency has been detected.
```

**Root causes:**
1. Module A imports Module B which imports Module A
2. Service A injects Service B which injects Service A
3. Barrel files (`index.ts`) re-exporting cause accidental cycles

**Diagnosis:**
```bash
# Detect circular imports in your codebase
npx madge --circular --extensions ts src/
# Visual dependency graph
npx madge --image graph.svg --extensions ts src/
```

**Fixes (in order of preference):**

1. **Refactor** — Extract shared logic into a third module/service
```typescript
// BEFORE: UserService ↔ AuthService (circular)
// AFTER:  UserService → SharedAuthHelper ← AuthService
```

2. **Use events** — Decouple with EventEmitter or CQRS EventBus
```typescript
// Instead of AuthService calling UserService directly:
this.eventEmitter.emit('auth.login', { userId });
// UserService listens for the event independently
```

3. **forwardRef** — Last resort patch
```typescript
// Both sides must use forwardRef
@Module({
  imports: [forwardRef(() => AuthModule)],
})
export class UserModule {}
```

4. **ModuleRef** — Runtime resolution
```typescript
@Injectable()
export class UserService implements OnModuleInit {
  private authService: AuthService;
  constructor(private moduleRef: ModuleRef) {}
  onModuleInit() {
    this.authService = this.moduleRef.get(AuthService, { strict: false });
  }
}
```

**Prevention:**
- Import classes directly, not through barrel files
- Follow unidirectional dependency flow
- Run `madge --circular` in CI

---

### Nest Can't Resolve Dependencies

**Error message:**
```
Nest can't resolve dependencies of the UsersService (?).
Please make sure that the argument "UserRepository" at index [0]
is available in the UsersModule context.
```

**Checklist:**

| Check | Fix |
|-------|-----|
| Provider not in `providers` array | Add it to the declaring module's `providers` |
| Provider not exported from source module | Add it to `exports` array |
| Source module not imported | Add source module to `imports` array |
| Missing `@Injectable()` decorator | Add decorator to the class |
| Wrong injection token | Use `@Inject('TOKEN')` for string tokens |
| TypeORM entity not registered | Use `TypeOrmModule.forFeature([Entity])` in the module |
| Mongoose schema not registered | Use `MongooseModule.forFeature([...])` |
| Scope mismatch | Check if injecting REQUEST-scoped into singleton |

**Debug helper — Print the DI tree:**
```typescript
// In main.ts after creating the app
const app = await NestFactory.create(AppModule);
const modulesContainer = app.get(ModulesContainer);
for (const [key, module] of modulesContainer) {
  console.log(`Module: ${module.metatype?.name}`);
  for (const [token, provider] of module.providers) {
    console.log(`  Provider: ${token}`);
  }
}
```

**Common mistake — Service in `imports` instead of `providers`:**
```typescript
// ❌ WRONG
@Module({ imports: [UsersService] })

// ✅ CORRECT
@Module({ providers: [UsersService] })
```

---

### Scope Bubbling Issues

**Symptom:** Unexpected behavior where singleton providers share state across requests, or unexpected latency.

**Root cause:** When a REQUEST-scoped provider is injected anywhere in the chain, all providers up the chain become REQUEST-scoped.

```
Singleton Controller
  └→ injects Singleton ServiceA
       └→ injects REQUEST-scoped ServiceB
            (!) ServiceA is now REQUEST-scoped too
            (!) Controller is now REQUEST-scoped too
```

**Diagnosis:**
```typescript
@Injectable({ scope: Scope.REQUEST })
export class RequestContext {
  constructor() {
    console.log('RequestContext created'); // fires per request
  }
}
// If you see this log for every request on a "singleton" service,
// scope has bubbled up.
```

**Fixes:**
- Minimize request-scoped provider dependencies
- Use `Scope.TRANSIENT` if you need per-injection but not per-request
- Use `durable: true` for multitenant caching of provider sub-trees
- Access `REQUEST` via `ModuleRef` instead of injecting it directly

---

### Unknown Element / Missing Module

**Error:**
```
Nest could not find UsersController element
(this provider does not exist in the current context)
```

**Causes:**
- Controller not listed in module's `controllers` array
- Module not imported into the root module chain
- Typo in controller class name
- File not saved / TypeScript compilation error

---

## Performance Bottlenecks

### Diagnosis

```typescript
// 1. Measure middleware/interceptor overhead
@Injectable()
export class PerformanceInterceptor implements NestInterceptor {
  intercept(context: ExecutionContext, next: CallHandler) {
    const start = process.hrtime.bigint();
    return next.handle().pipe(
      tap(() => {
        const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
        const handler = context.getHandler().name;
        if (elapsed > 100) { // log slow handlers
          console.warn(`SLOW: ${handler} took ${elapsed.toFixed(1)}ms`);
        }
      }),
    );
  }
}

// 2. Event loop lag monitoring
const lag = require('event-loop-lag');
lag(1000, (ms) => {
  if (ms > 100) console.warn(`Event loop lag: ${ms}ms`);
});
```

### Common bottlenecks and fixes

| Bottleneck | Symptom | Fix |
|-----------|---------|-----|
| N+1 queries | Slow list endpoints | Use `leftJoinAndSelect()` or DataLoader |
| Sync crypto operations | High event loop lag | Use `scrypt` async or worker threads |
| Request-scoped provider chains | Latency increase per request | Minimize scope usage |
| Large payload serialization | High CPU on responses | Use streaming or pagination |
| Missing DB indexes | Slow queries | Add indexes to frequently queried columns |
| No connection pooling | Connection timeouts | Configure pool size in TypeORM/Prisma |
| Unoptimized ValidationPipe | Overhead on every request | Use `whitelist: true` and `skipMissingProperties` selectively |

### Connection pool tuning

```typescript
TypeOrmModule.forRoot({
  type: 'postgres',
  url: process.env.DATABASE_URL,
  // Pool configuration
  extra: {
    max: 20,              // max pool size
    idleTimeoutMillis: 10000,
    connectionTimeoutMillis: 5000,
  },
});
```

---

## Memory Leaks

### Detection

```bash
# Start with heap inspection
node --inspect --max-old-space-size=512 dist/main.js
# Open chrome://inspect → take heap snapshots at intervals

# CLI heap snapshot
node -e "require('v8').writeHeapSnapshot()" # or use process.memoryUsage()

# In production: use clinic.js
npx clinic doctor -- node dist/main.js
```

### Common leak sources in NestJS

| Source | Cause | Fix |
|--------|-------|-----|
| Event listeners | Not removing listeners on destroy | Implement `OnModuleDestroy`, call `removeListener` |
| Intervals/Timeouts | Not cleared on shutdown | Clear in `onModuleDestroy()` or `onApplicationShutdown()` |
| Singleton caching | Unbounded Map/Set growth | Use LRU cache with max size |
| Request-scoped leaks | Storing request refs in singletons | Never store request objects in singleton providers |
| Observable subscriptions | Unsubscribed observables | Use `takeUntil` pattern or `firstValueFrom` |
| TypeORM query builder | Listeners not removed | Use `createQueryRunner()` and release after use |

### Cleanup pattern

```typescript
@Injectable()
export class MetricsService implements OnModuleDestroy {
  private intervalId: NodeJS.Timeout;
  private readonly cache = new Map<string, any>();

  onModuleInit() {
    this.intervalId = setInterval(() => this.flush(), 60000);
  }

  onModuleDestroy() {
    clearInterval(this.intervalId);
    this.cache.clear();
  }
}
```

### Enable shutdown hooks

```typescript
// main.ts — required for onModuleDestroy/onApplicationShutdown to fire
app.enableShutdownHooks();

// Handle graceful shutdown
@Injectable()
export class GracefulShutdown implements OnApplicationShutdown {
  onApplicationShutdown(signal: string) {
    console.log(`Received ${signal}, shutting down...`);
    // Close DB connections, flush queues, etc.
  }
}
```

---

## Testing Pitfalls

### Mocking complex DI trees

**Problem:** Deep dependency chains require mocking many providers.

```typescript
// ❌ Manually mocking every dependency
const module = await Test.createTestingModule({
  providers: [
    OrderService,
    { provide: UserService, useValue: mockUserSvc },
    { provide: PaymentService, useValue: mockPaymentSvc },
    { provide: InventoryService, useValue: mockInventorySvc },
    { provide: getRepositoryToken(Order), useValue: mockRepo },
    { provide: ConfigService, useValue: mockConfig },
    // ... 10 more mocks
  ],
}).compile();

// ✅ Use overrideProvider for targeted mocking with full module
const module = await Test.createTestingModule({
  imports: [OrderModule],
})
  .overrideProvider(PaymentService).useValue(mockPaymentSvc)
  .overrideProvider(getRepositoryToken(Order)).useValue(mockRepo)
  .compile();
```

### Common testing mistakes

| Mistake | Fix |
|---------|-----|
| Not calling `app.init()` in e2e tests | Always await `app.init()` after `createNestApplication()` |
| Missing `ValidationPipe` in e2e tests | Apply the same pipes as production |
| Mocking with `{}` instead of full interface | Use `createMock<T>()` or define all required methods |
| Not closing app after tests | Add `afterAll(() => app.close())` |
| Testing implementation instead of behavior | Test inputs/outputs, not internal method calls |
| Forgetting to override DB module | Use `overrideModule` or in-memory DB for e2e |

### Testing request-scoped providers

```typescript
// Request-scoped providers need contextId
const contextId = ContextIdFactory.create();
const module = await Test.createTestingModule({
  providers: [RequestScopedService],
}).compile();

// Register request object for the context
const request = { user: { id: 1 } };
module.registerRequestByContextId(request, contextId);
const service = await module.resolve(RequestScopedService, contextId);
```

### Auto-mocking with @golevelup/ts-jest

```typescript
import { createMock } from '@golevelup/ts-jest';

const module = await Test.createTestingModule({
  providers: [
    UsersService,
    { provide: getRepositoryToken(User), useValue: createMock<Repository<User>>() },
  ],
}).compile();
```

---

## Migration from Express

### Concept mapping

| Express | NestJS |
|---------|--------|
| `app.get('/route', handler)` | `@Get('route') handler()` on `@Controller` |
| `app.use(middleware)` | `consumer.apply(Middleware).forRoutes('*')` |
| `req.params.id` | `@Param('id') id: string` |
| `req.body` | `@Body() dto: CreateDto` |
| `req.query` | `@Query() query: QueryDto` |
| `res.status(201).json(data)` | `@HttpCode(201)` + return data |
| `express.Router()` | `@Controller('prefix')` |
| `app.locals` | `ConfigService` or custom provider |
| Error middleware `(err, req, res, next)` | `@Catch() ExceptionFilter` |
| `passport.authenticate()` | `@UseGuards(AuthGuard('jwt'))` |

### Migration strategy (incremental)

1. **Scaffold NestJS app** alongside existing Express app
2. **Mount Express app** inside NestJS as middleware (escape hatch):
```typescript
// main.ts — use existing express app
import * as express from 'express';
import { legacyApp } from './legacy/app';

const server = express();
server.use('/legacy', legacyApp); // old routes

const app = await NestFactory.create(AppModule, new ExpressAdapter(server));
await app.listen(3000);
```
3. **Migrate routes incrementally** — one controller at a time
4. **Replace middleware** with NestJS guards/pipes/interceptors
5. **Remove legacy mount** when migration is complete

### Common gotchas

- NestJS wraps `@Res()` usage: if you use `@Res()`, you must manually send the response
- NestJS `@Body()` requires `class-validator` DTOs; raw body access needs `rawBody: true` in create options
- Express middleware order matters — NestJS lifecycle is different (see SKILL.md lifecycle)

---

## Debugging Techniques

### Node.js inspector

```bash
# Start with debugger
nest start --debug --watch
# Or manually
node --inspect-brk dist/main.js

# Then open chrome://inspect in Chrome
```

### VS Code launch.json

```json
{
  "type": "node",
  "request": "launch",
  "name": "Debug NestJS",
  "runtimeArgs": ["--nolazy", "-r", "ts-node/register"],
  "args": ["${workspaceFolder}/src/main.ts"],
  "sourceMaps": true,
  "envFile": "${workspaceFolder}/.env"
}
```

### Logging DI resolution

```typescript
// Enable verbose logging to see module/provider resolution
const app = await NestFactory.create(AppModule, {
  logger: ['error', 'warn', 'log', 'debug', 'verbose'],
});
```

### Inspect registered routes

```typescript
const server = app.getHttpServer();
const router = server._events.request._router;
console.log(router.stack.filter(r => r.route).map(r => ({
  path: r.route.path,
  methods: Object.keys(r.route.methods),
})));

// Or use nest-router-viewer / swagger UI to see all routes
```

### Debug provider resolution

```typescript
import { ModulesContainer } from '@nestjs/core';

const modulesContainer = app.get(ModulesContainer);
for (const [, module] of modulesContainer) {
  console.log(`\n=== ${module.metatype?.name} ===`);
  for (const [token] of module.providers) {
    console.log(`  [Provider] ${typeof token === 'function' ? token.name : token}`);
  }
  for (const [token] of module.controllers) {
    console.log(`  [Controller] ${token.name}`);
  }
}
```

---

## Production Deployment Issues

### Dockerfile (multi-stage, optimized)

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
RUN npm prune --production

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "dist/main.js"]
```

### PM2 ecosystem config

```javascript
// ecosystem.config.js
module.exports = {
  apps: [{
    name: 'nestjs-app',
    script: 'dist/main.js',
    instances: 'max',      // cluster mode
    exec_mode: 'cluster',
    max_memory_restart: '500M',
    env_production: {
      NODE_ENV: 'production',
      PORT: 3000,
    },
    // Graceful shutdown
    kill_timeout: 5000,
    listen_timeout: 10000,
    // Logs
    error_file: './logs/error.log',
    out_file: './logs/out.log',
    merge_logs: true,
  }],
};
```

### Common production issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `ECONNRESET` on deploy | No graceful shutdown | `app.enableShutdownHooks()` + drain connections |
| 502 on startup | App not ready when LB starts sending traffic | Add health check endpoint + readiness probe |
| High memory under load | No connection pooling / unbounded caches | Configure pool sizes, add cache TTLs |
| `ENFILE: too many open files` | File descriptor limit | Increase `ulimit -n` in container/systemd |
| Slow cold starts | Large bundle size | Use lazy loading, tree-shake imports, SWC compiler |
| `Cannot find module` | Missing build artifacts | Ensure `npm run build` runs before `node dist/main.js` |
| CORS errors in production | Misconfigured origins | Use explicit `origin` array, not `*` |
| JWT validation fails | Clock skew between servers | Use NTP, set `clockTolerance` in JWT options |

### Graceful shutdown pattern

```typescript
async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.enableShutdownHooks();

  // Kubernetes: handle SIGTERM
  process.on('SIGTERM', async () => {
    // Stop accepting new connections
    console.log('SIGTERM received, starting graceful shutdown...');
    await app.close();
    process.exit(0);
  });

  await app.listen(3000);
}
```
