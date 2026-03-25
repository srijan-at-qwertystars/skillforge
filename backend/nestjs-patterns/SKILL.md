---
name: nestjs-patterns
description: >
  Use when working with NestJS framework: modules, controllers, providers, dependency injection,
  guards, interceptors, pipes, middleware, custom decorators, NestJS CLI scaffolding, microservices,
  WebSocket gateways, GraphQL resolvers, NestJS testing (unit/e2e), ConfigModule, TypeORM/Prisma/Mongoose
  integration, authentication with Passport/JWT, CQRS, OpenAPI/Swagger, health checks, exception filters.
  Do NOT use for: Express.js without NestJS, standalone Fastify apps, Angular frontend code,
  general TypeScript without NestJS context, Spring Boot, Django, or other non-NestJS backends.
---

# NestJS Patterns (v10+)

## Lifecycle: Middleware → Guards → Interceptors (pre) → Pipes → Handler → Interceptors (post) → Exception Filters

## CLI & Setup
```bash
npm i -g @nestjs/cli
nest new my-app                      # scaffold project
nest g resource users                # full CRUD: module+controller+service+DTOs
nest g module|controller|service X   # generate individual pieces
nest start -b swc --type-check       # fast SWC compiler (v10+)
```

## Modules
```typescript
@Module({
  imports: [DatabaseModule, ConfigModule],
  controllers: [UsersController],
  providers: [UsersService, UsersRepository],
  exports: [UsersService],                    // expose to other modules
})
export class UsersModule {}

// Dynamic module (e.g., configurable DB connection)
@Module({})
export class DatabaseModule {
  static forRoot(opts: DbOpts): DynamicModule {
    return { module: DatabaseModule, global: true,
      providers: [{ provide: 'DB_OPTS', useValue: opts }, DbService], exports: [DbService] };
  }
}
```

## Controllers
```typescript
@Controller('users')
export class UsersController {
  constructor(private readonly svc: UsersService) {}
  @Get()
  findAll(@Query('page', new DefaultValuePipe(1), ParseIntPipe) page: number) { return this.svc.findAll(page); }
  @Get(':id')
  findOne(@Param('id', ParseIntPipe) id: number) { return this.svc.findOne(id); }
  @Post() @HttpCode(201)
  create(@Body() dto: CreateUserDto) { return this.svc.create(dto); }
  @Put(':id')
  update(@Param('id', ParseIntPipe) id: number, @Body() dto: UpdateUserDto) { return this.svc.update(id, dto); }
  @Delete(':id') @HttpCode(204)
  remove(@Param('id', ParseIntPipe) id: number) { return this.svc.remove(id); }
}
// POST /users {"name":"Alice","email":"a@b.com"} → 201 {"id":1,"name":"Alice","email":"a@b.com"}
```

## Providers & DI
```typescript
@Injectable()
export class UsersService {
  constructor(@InjectRepository(User) private repo: Repository<User>, private config: ConfigService) {}
  findAll() { return this.repo.find(); }
}

// Custom providers
providers: [
  { provide: 'API_KEY', useValue: 'secret' },                  // value
  { provide: 'LOGGER', useClass: ProdLogger },                  // class swap
  { provide: 'DB', useFactory: async (c: ConfigService) =>      // async factory
      createConnection(c.get('DB_URL')), inject: [ConfigService] },
  { provide: 'Alias', useExisting: UsersService },              // alias
]
// Inject: constructor(@Inject('API_KEY') private key: string) {}
// Scopes: @Injectable({ scope: Scope.REQUEST })  // or Scope.TRANSIENT
```

## Middleware
```typescript
@Injectable()
export class LoggerMiddleware implements NestMiddleware {
  use(req: Request, res: Response, next: NextFunction) {
    console.log(`${req.method} ${req.url}`); next();
  }
}
export class AppModule implements NestModule {
  configure(c: MiddlewareConsumer) {
    c.apply(LoggerMiddleware).exclude({ path: 'health', method: RequestMethod.GET }).forRoutes('*');
  }
}
```

## Exception Filters
```typescript
@Catch(HttpException)
export class HttpFilter implements ExceptionFilter {
  catch(ex: HttpException, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const status = ex.getStatus();
    ctx.getResponse<Response>().status(status).json({
      statusCode: status, message: ex.message, timestamp: new Date().toISOString(),
      path: ctx.getRequest<Request>().url,
    });
  }
}
// Apply: @UseFilters(HttpFilter) or app.useGlobalFilters(new HttpFilter())
// GET /users/999 → 404 {"statusCode":404,"message":"User not found","timestamp":"...","path":"/users/999"}
```

## Pipes (Validation)
```typescript
// Global (main.ts)
app.useGlobalPipes(new ValidationPipe({
  whitelist: true, forbidNonWhitelisted: true, transform: true,
  transformOptions: { enableImplicitConversion: true },
}));
// DTO
export class CreateUserDto {
  @IsString() @MinLength(2) name: string;
  @IsEmail() email: string;
  @IsOptional() @IsInt() @Min(0) @Max(150) age?: number;
}
// POST {"name":"A","email":"bad"} → 400 {message:["name must be ≥ 2 chars","email must be an email"]}

// Custom pipe
@Injectable()
export class ParseDatePipe implements PipeTransform<string, Date> {
  transform(value: string) {
    const d = new Date(value);
    if (isNaN(d.getTime())) throw new BadRequestException('Invalid date');
    return d;
  }
}
```

## Guards
```typescript
@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private reflector: Reflector) {}
  canActivate(ctx: ExecutionContext): boolean {
    const roles = this.reflector.getAllAndOverride<string[]>('roles', [ctx.getHandler(), ctx.getClass()]);
    if (!roles) return true;
    const { user } = ctx.switchToHttp().getRequest();
    return roles.some(r => user.roles?.includes(r));
  }
}
export const Roles = (...roles: string[]) => SetMetadata('roles', roles);
// Usage: @UseGuards(JwtAuthGuard, RolesGuard) + @Roles('admin')
```

## Interceptors
```typescript
// Logging
@Injectable()
export class LoggingInterceptor implements NestInterceptor {
  intercept(ctx: ExecutionContext, next: CallHandler) {
    const now = Date.now();
    return next.handle().pipe(tap(() => console.log(`${ctx.getClass().name} ${Date.now()-now}ms`)));
  }
}
// Response transform
@Injectable()
export class WrapInterceptor<T> implements NestInterceptor<T> {
  intercept(ctx: ExecutionContext, next: CallHandler) {
    return next.handle().pipe(map(data => ({ data, timestamp: new Date().toISOString() })));
  }
}
// GET /users → {"data":[{"id":1}],"timestamp":"..."}
// Timeout
@Injectable()
export class TimeoutInterceptor implements NestInterceptor {
  intercept(_, next: CallHandler) {
    return next.handle().pipe(timeout(5000), catchError(e =>
      e instanceof TimeoutError ? throwError(() => new RequestTimeoutException()) : throwError(() => e)));
  }
}
// Cache: @UseInterceptors(CacheInterceptor) @CacheTTL(30)
```

## Custom Decorators
```typescript
// Extract current user from request
export const CurrentUser = createParamDecorator((data: string, ctx: ExecutionContext) => {
  const user = ctx.switchToHttp().getRequest().user;
  return data ? user?.[data] : user;
});
// @Get('me') profile(@CurrentUser() user: User) {}
// @Get('me') email(@CurrentUser('email') email: string) {}

// Composed decorator
export const Auth = (...roles: string[]) => applyDecorators(
  SetMetadata('roles', roles), UseGuards(JwtAuthGuard, RolesGuard), ApiBearerAuth());
// @Auth('admin') replaces 3 decorators

export const Public = () => SetMetadata('isPublic', true); // skip auth
```

## Configuration
```typescript
ConfigModule.forRoot({
  isGlobal: true, envFilePath: ['.env.local', '.env'],
  validationSchema: Joi.object({
    DATABASE_URL: Joi.string().required(), JWT_SECRET: Joi.string().required(),
    PORT: Joi.number().default(3000),
  }),
});
// Typed config namespace
export default registerAs('database', () => ({
  host: process.env.DB_HOST || 'localhost', port: +process.env.DB_PORT || 5432,
}));
// config.get('database.host')
```

## Database Integration
```typescript
// TypeORM
TypeOrmModule.forRootAsync({
  useFactory: (c: ConfigService) => ({ type: 'postgres', url: c.get('DATABASE_URL'),
    entities: [__dirname + '/**/*.entity{.ts,.js}'], synchronize: false,
    migrations: [__dirname + '/migrations/*{.ts,.js}'] }), inject: [ConfigService],
});
@Entity()
export class User {
  @PrimaryGeneratedColumn() id: number;
  @Column({ unique: true }) email: string;
  @Column() name: string;
  @CreateDateColumn() createdAt: Date;
  @OneToMany(() => Post, p => p.author) posts: Post[];
}
// Prisma
@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit {
  async onModuleInit() { await this.$connect(); }
  async onModuleDestroy() { await this.$disconnect(); }
}
// Mongoose
@Schema({ timestamps: true })
export class Cat { @Prop({ required: true }) name: string; @Prop() age: number; }
export const CatSchema = SchemaFactory.createForClass(Cat);
// MongooseModule.forFeature([{ name: Cat.name, schema: CatSchema }])
```

## Authentication (Passport + JWT)
```typescript
@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  constructor(config: ConfigService) {
    super({ jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(), secretOrKey: config.get('JWT_SECRET') });
  }
  validate(payload: { sub: number; email: string }) { return { id: payload.sub, email: payload.email }; }
}
@Module({
  imports: [PassportModule, JwtModule.registerAsync({
    useFactory: (c: ConfigService) => ({ secret: c.get('JWT_SECRET'), signOptions: { expiresIn: '1h' } }),
    inject: [ConfigService],
  })],
  providers: [AuthService, JwtStrategy], exports: [AuthService],
})
export class AuthModule {}
@Injectable()
export class AuthService {
  constructor(private jwt: JwtService, private users: UsersService) {}
  login(user: User) { return { access_token: this.jwt.sign({ sub: user.id, email: user.email }) }; }
}
// POST /auth/login → {"access_token":"eyJhbGci..."}
```

## Testing
```typescript
// Unit test
describe('UsersService', () => {
  let svc: UsersService; let repo: jest.Mocked<Repository<User>>;
  beforeEach(async () => {
    const mod = await Test.createTestingModule({ providers: [UsersService,
      { provide: getRepositoryToken(User), useValue: { find: jest.fn(), findOne: jest.fn(), save: jest.fn() } },
    ] }).compile();
    svc = mod.get(UsersService); repo = mod.get(getRepositoryToken(User));
  });
  it('returns users', async () => {
    repo.find.mockResolvedValue([{ id: 1, name: 'Alice' } as User]);
    expect(await svc.findAll()).toHaveLength(1);
  });
});
// E2E test
describe('Users (e2e)', () => {
  let app: INestApplication;
  beforeAll(async () => {
    const mod = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(UsersService).useValue({ findAll: () => [{ id: 1 }] }).compile();
    app = mod.createNestApplication();
    app.useGlobalPipes(new ValidationPipe({ whitelist: true }));
    await app.init();
  });
  it('GET /users', () => request(app.getHttpServer()).get('/users').expect(200).expect([{ id: 1 }]));
  afterAll(() => app.close());
});
// v10: override entire module
Test.createTestingModule({ imports: [AppModule] })
  .overrideModule(DatabaseModule).useModule(TestDbModule).compile();
```

## Microservices
```typescript
// Hybrid app (HTTP + microservice)
const app = await NestFactory.create(AppModule);
app.connectMicroservice<MicroserviceOptions>({ transport: Transport.REDIS,
  options: { host: 'localhost', port: 6379 } });
await app.startAllMicroservices();
await app.listen(3000);

@Controller()
export class OrdersController {
  @MessagePattern({ cmd: 'get_order' })              // request-response
  getOrder(@Payload() data: { id: number }) { return this.svc.findOne(data.id); }
  @EventPattern('order_created')                      // fire-and-forget
  handleCreated(@Payload() data: OrderDto) { this.analytics.track(data); }
}
// Client: @Inject('ORDERS') private client: ClientProxy
// client.send({ cmd: 'get_order' }, { id: 1 })   → Observable<Order>
// client.emit('order_created', order)             → fire-and-forget
// Register: ClientsModule.register([{ name: 'ORDERS', transport: Transport.TCP }])
```

## WebSocket Gateways
```typescript
@WebSocketGateway({ cors: true, namespace: '/chat' })
export class ChatGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer() server: Server;
  handleConnection(client: Socket) { console.log(`Connected: ${client.id}`); }
  handleDisconnect(client: Socket) { console.log(`Disconnected: ${client.id}`); }
  @SubscribeMessage('message')
  handleMsg(@MessageBody() data: { room: string; text: string }, @ConnectedSocket() client: Socket) {
    this.server.to(data.room).emit('message', { sender: client.id, text: data.text });
    return { event: 'message', data: 'sent' };
  }
}
// Client: socket.emit('message',{room:'general',text:'hi'}) → all in room get {sender:'abc',text:'hi'}
```

## OpenAPI / Swagger
```typescript
// main.ts
const doc = SwaggerModule.createDocument(app, new DocumentBuilder()
  .setTitle('API').setVersion('1.0').addBearerAuth().build());
SwaggerModule.setup('api', app, doc);
// DTO
export class CreateUserDto {
  @ApiProperty({ example: 'Alice' }) @IsString() name: string;
  @ApiProperty({ example: 'a@b.com' }) @IsEmail() email: string;
  @ApiPropertyOptional() @IsOptional() @IsInt() age?: number;
}
// Controller
@ApiTags('users') @ApiBearerAuth() @Controller('users')
export class UsersController {
  @Post() @ApiOperation({ summary: 'Create user' })
  @ApiResponse({ status: 201, type: User }) @ApiResponse({ status: 400 })
  create(@Body() dto: CreateUserDto) {}
}
```

## CQRS
```typescript
// imports: [CqrsModule]
export class CreateOrderCmd { constructor(public userId: number, public items: Item[]) {} }
@CommandHandler(CreateOrderCmd)
export class CreateOrderHandler implements ICommandHandler<CreateOrderCmd> {
  constructor(private repo: OrderRepo, private events: EventBus) {}
  async execute(cmd: CreateOrderCmd) {
    const order = await this.repo.create(cmd.userId, cmd.items);
    this.events.publish(new OrderCreatedEvent(order.id));
    return order;
  }
}
export class GetOrderQuery { constructor(public orderId: number) {} }
@QueryHandler(GetOrderQuery)
export class GetOrderHandler implements IQueryHandler<GetOrderQuery> {
  constructor(private repo: OrderRepo) {}
  execute(q: GetOrderQuery) { return this.repo.findById(q.orderId); }
}
export class OrderCreatedEvent { constructor(public orderId: number) {} }
@EventsHandler(OrderCreatedEvent)
export class OnOrderCreated implements IEventHandler<OrderCreatedEvent> {
  handle(e: OrderCreatedEvent) { console.log(`Order ${e.orderId} created`); }
}
// Controller: this.commandBus.execute(new CreateOrderCmd(userId, items))
```

## Health Checks
```typescript
@Controller('health')
export class HealthController {
  constructor(private health: HealthCheckService, private db: TypeOrmHealthIndicator,
    private http: HttpHealthIndicator, private mem: MemoryHealthIndicator) {}
  @Get() @HealthCheck()
  check() { return this.health.check([
    () => this.db.pingCheck('database'),
    () => this.http.pingCheck('api', 'https://api.example.com'),
    () => this.mem.checkHeap('memory', 200 * 1024 * 1024),
  ]); }
}
// → {"status":"ok","details":{"database":{"status":"up"},"api":{"status":"up"}}}
```

## Bootstrap
```typescript
async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  app.useLogger(app.get(Logger));
  app.enableCors({ origin: process.env.CORS_ORIGIN });
  app.setGlobalPrefix('api/v1');
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));
  app.useGlobalInterceptors(new WrapInterceptor());
  app.useGlobalFilters(new HttpFilter());
  app.enableShutdownHooks();
  await app.listen(process.env.PORT || 3000);
}
bootstrap();
```
