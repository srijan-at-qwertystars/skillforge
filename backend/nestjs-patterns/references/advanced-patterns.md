# NestJS Advanced Patterns Reference

> Dense, actionable reference for advanced NestJS architectural patterns. NestJS v10+.

## Table of Contents

- [Custom Providers](#custom-providers)
- [Dynamic Modules](#dynamic-modules)
- [Circular Dependency Resolution](#circular-dependency-resolution)
- [Request-Scoped Providers](#request-scoped-providers)
- [Lazy Loading Modules](#lazy-loading-modules)
- [Execution Context](#execution-context)
- [Reflection & Metadata](#reflection--metadata)
- [Custom Transports for Microservices](#custom-transports-for-microservices)
- [Hybrid Applications](#hybrid-applications)
- [CQRS Deep-Dive](#cqrs-deep-dive)
- [Event Sourcing](#event-sourcing)
- [Sagas](#sagas)

---

## Custom Providers

### useFactory — Dynamic provider creation

```typescript
// Sync factory
{ provide: 'HASH_ROUNDS', useFactory: () => (process.env.NODE_ENV === 'production' ? 12 : 4) }

// Async factory with injected dependencies
{
  provide: 'ASYNC_DB_CONNECTION',
  useFactory: async (config: ConfigService): Promise<Connection> => {
    const conn = await createConnection({
      type: 'postgres',
      url: config.get<string>('DATABASE_URL'),
      ssl: config.get('NODE_ENV') === 'production' ? { rejectUnauthorized: false } : false,
    });
    return conn;
  },
  inject: [ConfigService],
}

// Factory with multiple injected deps
{
  provide: 'S3_CLIENT',
  useFactory: (config: ConfigService, logger: LoggerService) => {
    logger.log('Initializing S3 client');
    return new S3Client({
      region: config.get('AWS_REGION'),
      credentials: {
        accessKeyId: config.get('AWS_ACCESS_KEY'),
        secretAccessKey: config.get('AWS_SECRET_KEY'),
      },
    });
  },
  inject: [ConfigService, LoggerService],
}
```

### useExisting — Provider aliasing

```typescript
// Alias a concrete service under an abstract token
{ provide: 'IUserRepository', useExisting: TypeOrmUserRepository }

// Strategy pattern: swap implementations without changing consumers
{ provide: 'IPaymentGateway', useExisting:
    process.env.PAYMENT_PROVIDER === 'stripe' ? StripeGateway : PayPalGateway }

// Multiple aliases for the same singleton instance
providers: [
  ConcreteLogger,
  { provide: 'APP_LOGGER', useExisting: ConcreteLogger },
  { provide: 'AUDIT_LOGGER', useExisting: ConcreteLogger },
]
```

### Async Providers — Initialization requiring awaited setup

```typescript
// Provider that fetches config from remote vault before being available
{
  provide: 'VAULT_SECRETS',
  useFactory: async () => {
    const client = new VaultClient({ endpoint: process.env.VAULT_ADDR });
    await client.authenticate();
    return client.readSecrets('app/config');
  },
}

// Provider depending on another async provider
{
  provide: 'EMAIL_SERVICE',
  useFactory: async (secrets: Record<string, string>) => {
    return new EmailService({ apiKey: secrets.SENDGRID_KEY });
  },
  inject: ['VAULT_SECRETS'],
}
```

**Key rules:**
- `useFactory` can return a Promise — NestJS awaits it during bootstrap
- Injection order follows the `inject` array positionally
- Async providers block module initialization until resolved
- Use `useFactory` over `useClass` when you need conditional logic or async setup

---

## Dynamic Modules

### forRoot / forRootAsync Pattern

```typescript
@Module({})
export class CacheModule {
  // Static synchronous config
  static forRoot(options: CacheModuleOptions): DynamicModule {
    return {
      module: CacheModule,
      global: true, // available everywhere without importing
      providers: [
        { provide: 'CACHE_OPTIONS', useValue: options },
        CacheService,
      ],
      exports: [CacheService],
    };
  }

  // Async config — supports useFactory, useClass, useExisting
  static forRootAsync(options: CacheModuleAsyncOptions): DynamicModule {
    return {
      module: CacheModule,
      global: true,
      imports: options.imports || [],
      providers: [
        {
          provide: 'CACHE_OPTIONS',
          useFactory: options.useFactory,
          inject: options.inject || [],
        },
        CacheService,
      ],
      exports: [CacheService],
    };
  }
}

// Usage
@Module({
  imports: [
    CacheModule.forRootAsync({
      imports: [ConfigModule],
      useFactory: (config: ConfigService) => ({
        ttl: config.get('CACHE_TTL', 60),
        host: config.get('REDIS_HOST'),
      }),
      inject: [ConfigService],
    }),
  ],
})
export class AppModule {}
```

### forFeature Pattern — Per-module registration

```typescript
@Module({})
export class EventEmitterModule {
  static forFeature(events: Type<any>[]): DynamicModule {
    const providers = events.map(event => ({
      provide: event,
      useClass: event,
    }));
    return {
      module: EventEmitterModule,
      providers,
      exports: providers,
    };
  }
}
```

### ConfigurableModuleBuilder (v10+)

```typescript
import { ConfigurableModuleBuilder } from '@nestjs/common';

export interface NotificationModuleOptions {
  provider: 'ses' | 'sendgrid';
  apiKey: string;
}

export const {
  ConfigurableModuleClass,
  MODULE_OPTIONS_TOKEN,
} = new ConfigurableModuleBuilder<NotificationModuleOptions>()
  .setClassMethodName('forRoot')
  .setExtras({ isGlobal: false }, (definition, extras) => ({
    ...definition,
    global: extras.isGlobal,
  }))
  .build();

@Module({
  providers: [NotificationService],
  exports: [NotificationService],
})
export class NotificationModule extends ConfigurableModuleClass {}

// NotificationService can inject MODULE_OPTIONS_TOKEN
@Injectable()
export class NotificationService {
  constructor(@Inject(MODULE_OPTIONS_TOKEN) private opts: NotificationModuleOptions) {}
}
```

---

## Circular Dependency Resolution

### forwardRef — Break circular references

```typescript
// Service-level circular dependency
@Injectable()
export class ServiceA {
  constructor(
    @Inject(forwardRef(() => ServiceB)) private serviceB: ServiceB,
  ) {}
}

@Injectable()
export class ServiceB {
  constructor(
    @Inject(forwardRef(() => ServiceA)) private serviceA: ServiceA,
  ) {}
}

// Module-level circular dependency
@Module({
  imports: [forwardRef(() => ModuleB)],
  providers: [ServiceA],
  exports: [ServiceA],
})
export class ModuleA {}

@Module({
  imports: [forwardRef(() => ModuleA)],
  providers: [ServiceB],
  exports: [ServiceB],
})
export class ModuleB {}
```

### ModuleRef — Runtime resolution (preferred for complex cases)

```typescript
@Injectable()
export class OrderService implements OnModuleInit {
  private paymentService: PaymentService;

  constructor(private moduleRef: ModuleRef) {}

  onModuleInit() {
    // Resolve at runtime, avoiding circular DI
    this.paymentService = this.moduleRef.get(PaymentService, { strict: false });
  }
}
```

### Architectural fixes (best long-term)

```
// BEFORE (circular): UserService ↔ AuthService
// AFTER: Extract shared logic into a third service
UserService → UserAuthBridge ← AuthService
// Or use events:
UserService --emits--> UserCreatedEvent --handles--> AuthService
```

**Rules:**
- `forwardRef` is a patch, not a solution — refactor when possible
- Avoid barrel files (`index.ts`) that re-export — they cause accidental cycles
- Use `madge --circular` to detect circular imports in your codebase
- NestJS v10+ gives clearer circular dependency error messages

---

## Request-Scoped Providers

```typescript
@Injectable({ scope: Scope.REQUEST })
export class RequestContextService {
  private tenantId: string;
  setTenant(id: string) { this.tenantId = id; }
  getTenant() { return this.tenantId; }
}

// Inject REQUEST object directly
@Injectable({ scope: Scope.REQUEST })
export class AuditService {
  constructor(@Inject(REQUEST) private request: Request) {}
  getCurrentUser() { return this.request['user']; }
}
```

### Scope Bubbling

```
Scope.DEFAULT (singleton) ← Scope.REQUEST ← Scope.TRANSIENT
```

**When a request-scoped provider is injected into a singleton, the singleton becomes request-scoped too (scope bubbles up the dependency chain).**

```typescript
// ⚠️ This makes UsersController request-scoped!
@Controller('users')
export class UsersController {
  constructor(private requestCtx: RequestContextService) {} // REQUEST scope bubbles up
}
```

### Performance implications

- Each request creates new instances of all request-scoped providers + their dependants
- ~5-15% latency overhead per request compared to singletons
- Higher memory usage and GC pressure
- **Mitigate:** Keep request-scoped provider chains short; use `Scope.TRANSIENT` for stateless per-injection instances

### Durable providers (v10+) — Multitenant optimization

```typescript
@Injectable({ scope: Scope.REQUEST, durable: true })
export class TenantService {
  constructor(@Inject(REQUEST) private request: Request) {}
}

// Implement ContextIdStrategy to reuse sub-trees per tenant
export class TenantContextIdStrategy implements ContextIdStrategy {
  attach(contextId: ContextId, request: Request) {
    const tenantId = request.headers['x-tenant-id'] as string;
    const tenantSubTreeId = ContextIdFactory.getByRequest(request, tenantId);
    return { resolve: (info) => info.isTreeDurable ? tenantSubTreeId : contextId };
  }
}
// Register in main.ts: ContextIdFactory.apply(new TenantContextIdStrategy());
```

---

## Lazy Loading Modules

```typescript
@Injectable()
export class AppService {
  constructor(private lazyLoader: LazyModuleLoader) {}

  async processReport() {
    // Module loaded only when this method is first called
    const { ReportModule } = await import('./report/report.module');
    const moduleRef = await this.lazyLoader.load(() => ReportModule);
    const reportService = moduleRef.get(ReportService);
    return reportService.generate();
  }
}
```

**Use cases:**
- Feature flags: load modules conditionally
- Reduce cold start time in serverless (Lambda)
- Plugin architectures: load plugins at runtime
- Admin-only features loaded on demand

**Limitations:**
- Lazy-loaded controllers/resolvers/gateways won't register routes — only providers work
- Lifecycle hooks (`onModuleInit`) fire when lazy module is loaded, not at bootstrap

---

## Execution Context

`ExecutionContext` extends `ArgumentsHost` — used in guards, interceptors, and filters to access handler metadata.

```typescript
@Injectable()
export class UniversalGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const type = context.getType<'http' | 'rpc' | 'ws'>(); // transport type

    if (type === 'http') {
      const req = context.switchToHttp().getRequest<Request>();
      return this.validateHttp(req);
    }
    if (type === 'rpc') {
      const data = context.switchToRpc().getData();
      return this.validateRpc(data);
    }
    if (type === 'ws') {
      const client = context.switchToWs().getClient<Socket>();
      return this.validateWs(client);
    }
    return false;
  }
}
```

### Key methods

| Method | Returns | Use |
|--------|---------|-----|
| `getClass()` | Controller class ref | Apply class-level metadata |
| `getHandler()` | Handler method ref | Apply method-level metadata |
| `getType()` | `'http' \| 'rpc' \| 'ws'` | Transport-aware logic |
| `switchToHttp()` | `HttpArgumentsHost` | Access req, res, next |
| `switchToRpc()` | `RpcArgumentsHost` | Access data, context |
| `switchToWs()` | `WsArgumentsHost` | Access client, data |
| `getArgs()` | `any[]` | Raw handler arguments |
| `getArgByIndex(i)` | `any` | Specific argument |

### GqlExecutionContext (GraphQL)

```typescript
import { GqlExecutionContext } from '@nestjs/graphql';

@Injectable()
export class GqlAuthGuard implements CanActivate {
  canActivate(context: ExecutionContext) {
    const gqlCtx = GqlExecutionContext.create(context);
    const { req } = gqlCtx.getContext();
    return !!req.user;
  }
}
```

---

## Reflection & Metadata

### Reflector API

```typescript
// Define metadata with a decorator
export const Roles = (...roles: string[]) => SetMetadata('roles', roles);
export const IS_PUBLIC = 'isPublic';
export const Public = () => SetMetadata(IS_PUBLIC, true);

// Read metadata in guards/interceptors
@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    // Check if route is public first
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    // Get roles from handler OR class (handler takes precedence)
    const roles = this.reflector.getAllAndOverride<string[]>('roles', [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!roles) return true;

    const { user } = context.switchToHttp().getRequest();
    return roles.some(role => user.roles?.includes(role));
  }
}
```

### Reflector methods

| Method | Behavior |
|--------|----------|
| `.get(key, target)` | Get metadata from one target |
| `.getAll(key, [targets])` | Get array of metadata from all targets |
| `.getAllAndMerge(key, [targets])` | Merge arrays from handler + class |
| `.getAllAndOverride(key, [targets])` | First non-undefined value wins (handler > class) |

### Custom metadata decorators with typed keys

```typescript
import { Reflector } from '@nestjs/core';

// Type-safe reflector key (v10+)
export const Throttle = Reflector.createDecorator<{ limit: number; ttl: number }>();

// Usage on handler
@Throttle({ limit: 10, ttl: 60 })
@Get('search')
search() {}

// Read in interceptor
const throttleConfig = this.reflector.get(Throttle, context.getHandler());
// throttleConfig is typed as { limit: number; ttl: number } | undefined
```

---

## Custom Transports for Microservices

```typescript
import { Server, CustomTransportStrategy } from '@nestjs/microservices';

export class MqttCustomServer extends Server implements CustomTransportStrategy {
  private client: MqttClient;

  async listen(callback: () => void) {
    this.client = mqtt.connect(this.options.url);
    this.client.on('connect', () => {
      // Register all message handlers
      this.messageHandlers.forEach((handler, pattern) => {
        this.client.subscribe(pattern);
      });
      callback();
    });
    this.client.on('message', async (topic, payload) => {
      const handler = this.messageHandlers.get(topic);
      if (handler) {
        const result = await handler(JSON.parse(payload.toString()));
        // Publish response if request-response pattern
        if (result) {
          this.client.publish(`${topic}/reply`, JSON.stringify(result));
        }
      }
    });
  }

  async close() {
    await this.client?.endAsync();
  }
}

// Register in main.ts
app.connectMicroservice({ strategy: new MqttCustomServer({ url: 'mqtt://broker:1883' }) });
```

---

## Hybrid Applications

Run HTTP + multiple microservice transports in a single process:

```typescript
async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  // TCP microservice for internal service-to-service
  app.connectMicroservice<MicroserviceOptions>({
    transport: Transport.TCP,
    options: { host: '0.0.0.0', port: 3001 },
  });

  // Redis microservice for pub/sub events
  app.connectMicroservice<MicroserviceOptions>({
    transport: Transport.REDIS,
    options: { host: 'redis', port: 6379 },
  });

  // gRPC microservice
  app.connectMicroservice<MicroserviceOptions>({
    transport: Transport.GRPC,
    options: {
      package: 'orders',
      protoPath: join(__dirname, 'orders/orders.proto'),
      url: '0.0.0.0:5000',
    },
  });

  await app.startAllMicroservices();
  await app.listen(3000); // HTTP
}
```

**Key points:**
- Global pipes/guards/interceptors from `app.useGlobal*()` apply only to HTTP
- Use `app.useGlobalPipes(pipe)` on the microservice ref for microservice pipes
- Shared modules work across all transports; use `ExecutionContext.getType()` to branch logic

---

## CQRS Deep-Dive

### Architecture overview

```
Controller → CommandBus.execute(cmd)  → CommandHandler → Repository (write)
                                       ↓ (publishes)
                                     EventBus
                                       ↓
                                     EventHandler(s) → side effects, projections
Controller → QueryBus.execute(query) → QueryHandler → Read model (query)
```

### Commands with validation

```typescript
export class CreateOrderCommand {
  constructor(
    public readonly userId: string,
    public readonly items: Array<{ productId: string; quantity: number }>,
    public readonly shippingAddress: Address,
  ) {
    if (!items.length) throw new BadRequestException('Order must have items');
  }
}

@CommandHandler(CreateOrderCommand)
export class CreateOrderHandler implements ICommandHandler<CreateOrderCommand> {
  constructor(
    private readonly orderRepo: OrderRepository,
    private readonly eventBus: EventBus,
  ) {}

  async execute(command: CreateOrderCommand): Promise<Order> {
    const order = Order.create(command.userId, command.items, command.shippingAddress);
    await this.orderRepo.save(order);

    // Publish domain events
    this.eventBus.publishAll([
      new OrderCreatedEvent(order.id, order.userId, order.total),
      new InventoryReservedEvent(order.id, command.items),
    ]);

    return order;
  }
}
```

### Multiple event handlers for a single event

```typescript
@EventsHandler(OrderCreatedEvent)
export class SendOrderConfirmation implements IEventHandler<OrderCreatedEvent> {
  constructor(private email: EmailService) {}
  handle(event: OrderCreatedEvent) {
    this.email.sendOrderConfirmation(event.userId, event.orderId);
  }
}

@EventsHandler(OrderCreatedEvent)
export class UpdateAnalytics implements IEventHandler<OrderCreatedEvent> {
  constructor(private analytics: AnalyticsService) {}
  handle(event: OrderCreatedEvent) {
    this.analytics.trackOrder(event.orderId, event.total);
  }
}

@EventsHandler(OrderCreatedEvent)
export class ProjectOrderToReadModel implements IEventHandler<OrderCreatedEvent> {
  constructor(private readDb: ReadModelRepository) {}
  handle(event: OrderCreatedEvent) {
    this.readDb.upsertOrderSummary({ id: event.orderId, total: event.total, status: 'created' });
  }
}
```

### Queries

```typescript
export class GetOrdersByUserQuery {
  constructor(public readonly userId: string, public readonly page: number = 1) {}
}

@QueryHandler(GetOrdersByUserQuery)
export class GetOrdersByUserHandler implements IQueryHandler<GetOrdersByUserQuery> {
  constructor(private readModel: OrderReadRepository) {}
  execute(query: GetOrdersByUserQuery) {
    return this.readModel.findByUser(query.userId, query.page);
  }
}
```

---

## Event Sourcing

Store state as a sequence of events rather than current state snapshots.

```typescript
// Aggregate root
export class OrderAggregate extends AggregateRoot {
  private status: string;
  private items: OrderItem[] = [];

  createOrder(userId: string, items: OrderItem[]) {
    // Validate business rules
    this.apply(new OrderCreatedEvent(this.id, userId, items));
  }

  confirmOrder() {
    if (this.status !== 'created') throw new Error('Cannot confirm');
    this.apply(new OrderConfirmedEvent(this.id));
  }

  // Event handlers rebuild state
  onOrderCreatedEvent(event: OrderCreatedEvent) {
    this.status = 'created';
    this.items = event.items;
  }

  onOrderConfirmedEvent(event: OrderConfirmedEvent) {
    this.status = 'confirmed';
  }
}

// Event store interface
@Injectable()
export class EventStore {
  constructor(@InjectRepository(StoredEvent) private repo: Repository<StoredEvent>) {}

  async saveEvents(aggregateId: string, events: IEvent[], expectedVersion: number) {
    const existingEvents = await this.repo.count({ where: { aggregateId } });
    if (existingEvents !== expectedVersion) {
      throw new ConflictException('Concurrency conflict');
    }
    const entities = events.map((event, i) => ({
      aggregateId,
      type: event.constructor.name,
      data: JSON.stringify(event),
      version: expectedVersion + i + 1,
      timestamp: new Date(),
    }));
    await this.repo.save(entities);
  }

  async getEvents(aggregateId: string): Promise<StoredEvent[]> {
    return this.repo.find({ where: { aggregateId }, order: { version: 'ASC' } });
  }
}
```

---

## Sagas

Sagas orchestrate multi-step workflows by listening to events and dispatching commands.

```typescript
@Injectable()
export class OrderSaga {
  @Saga()
  orderCreated = (events$: Observable<IEvent>): Observable<ICommand> => {
    return events$.pipe(
      ofType(OrderCreatedEvent),
      map(event => new ReserveInventoryCommand(event.orderId, event.items)),
    );
  };

  @Saga()
  inventoryReserved = (events$: Observable<IEvent>): Observable<ICommand> => {
    return events$.pipe(
      ofType(InventoryReservedEvent),
      map(event => new ProcessPaymentCommand(event.orderId)),
    );
  };

  @Saga()
  paymentProcessed = (events$: Observable<IEvent>): Observable<ICommand> => {
    return events$.pipe(
      ofType(PaymentProcessedEvent),
      map(event => new ConfirmOrderCommand(event.orderId)),
    );
  };

  // Compensating saga for failures
  @Saga()
  paymentFailed = (events$: Observable<IEvent>): Observable<ICommand> => {
    return events$.pipe(
      ofType(PaymentFailedEvent),
      map(event => new ReleaseInventoryCommand(event.orderId)),
    );
  };
}
```

**Register in module:**
```typescript
@Module({
  imports: [CqrsModule],
  providers: [
    ...CommandHandlers,
    ...EventHandlers,
    ...QueryHandlers,
    OrderSaga,
  ],
})
export class OrderModule {}
```
