# NestJS API Reference

> Complete reference for core NestJS decorators, types, lifecycle hooks, and CLI commands. NestJS v10+.

## Table of Contents

- [Core Decorators](#core-decorators)
  - [Module Decorators](#module-decorators)
  - [Controller & Route Decorators](#controller--route-decorators)
  - [Provider Decorators](#provider-decorators)
  - [Parameter Decorators](#parameter-decorators)
  - [Metadata Decorators](#metadata-decorators)
- [Module Metadata Options](#module-metadata-options)
- [Provider Types](#provider-types)
- [Lifecycle Hooks](#lifecycle-hooks)
- [Execution Context API](#execution-context-api)
- [HttpException Hierarchy](#httpexception-hierarchy)
- [Built-in Pipes](#built-in-pipes)
- [Platform-Specific Adapters](#platform-specific-adapters)
- [CLI Commands Reference](#cli-commands-reference)

---

## Core Decorators

### Module Decorators

| Decorator | Import | Purpose |
|-----------|--------|---------|
| `@Module(metadata)` | `@nestjs/common` | Declares a module with providers, controllers, imports, exports |
| `@Global()` | `@nestjs/common` | Makes module's providers available globally without importing |

### Controller & Route Decorators

| Decorator | Purpose | Example |
|-----------|---------|---------|
| `@Controller(prefix?)` | Declare a controller | `@Controller('users')` |
| `@Get(path?)` | HTTP GET handler | `@Get(':id')` |
| `@Post(path?)` | HTTP POST handler | `@Post()` |
| `@Put(path?)` | HTTP PUT handler | `@Put(':id')` |
| `@Patch(path?)` | HTTP PATCH handler | `@Patch(':id')` |
| `@Delete(path?)` | HTTP DELETE handler | `@Delete(':id')` |
| `@Options(path?)` | HTTP OPTIONS handler | `@Options()` |
| `@Head(path?)` | HTTP HEAD handler | `@Head()` |
| `@All(path?)` | All HTTP methods | `@All('*')` |
| `@HttpCode(code)` | Set response status code | `@HttpCode(204)` |
| `@Header(name, value)` | Set response header | `@Header('Cache-Control', 'max-age=60')` |
| `@Redirect(url, code?)` | Redirect response | `@Redirect('https://example.com', 301)` |
| `@Render(template)` | Render view template | `@Render('index')` |
| `@Version(version)` | API versioning | `@Version('2')` |

### Provider Decorators

| Decorator | Purpose | Example |
|-----------|---------|---------|
| `@Injectable(options?)` | Mark class as injectable provider | `@Injectable()` |
| `@Injectable({ scope })` | Set provider scope | `@Injectable({ scope: Scope.REQUEST })` |
| `@Inject(token)` | Inject by token | `@Inject('API_KEY')` |
| `@Optional()` | Mark dependency as optional | `@Optional() @Inject('LOGGER')` |

### Parameter Decorators

| Decorator | Extracts | Example |
|-----------|----------|---------|
| `@Body(key?)` | Request body (or nested key) | `@Body('name') name: string` |
| `@Param(key?)` | Route params | `@Param('id') id: string` |
| `@Query(key?)` | Query string params | `@Query('page') page: string` |
| `@Headers(name?)` | Request headers | `@Headers('authorization') auth: string` |
| `@Req()` / `@Request()` | Full request object | `@Req() req: Request` |
| `@Res()` / `@Response()` | Full response object | `@Res() res: Response` |
| `@Next()` | Next function | `@Next() next: NextFunction` |
| `@Ip()` | Client IP address | `@Ip() ip: string` |
| `@HostParam(key?)` | Host params (subdomain) | `@HostParam('tenant') tenant: string` |
| `@Session()` | Session object | `@Session() session: Record<string, any>` |
| `@UploadedFile()` | Single uploaded file | `@UploadedFile() file: Express.Multer.File` |
| `@UploadedFiles()` | Multiple uploaded files | `@UploadedFiles() files: Express.Multer.File[]` |

### Metadata Decorators

| Decorator | Purpose | Example |
|-----------|---------|---------|
| `@SetMetadata(key, val)` | Set custom metadata | `@SetMetadata('roles', ['admin'])` |
| `@UseGuards(...guards)` | Attach guards | `@UseGuards(AuthGuard)` |
| `@UseInterceptors(...i)` | Attach interceptors | `@UseInterceptors(LoggingInterceptor)` |
| `@UsePipes(...pipes)` | Attach pipes | `@UsePipes(ValidationPipe)` |
| `@UseFilters(...filters)` | Attach exception filters | `@UseFilters(HttpExceptionFilter)` |

### WebSocket Decorators

| Decorator | Purpose |
|-----------|---------|
| `@WebSocketGateway(opts?)` | Declare WebSocket gateway |
| `@WebSocketServer()` | Inject server instance |
| `@SubscribeMessage(event)` | Handle socket event |
| `@MessageBody()` | Extract message payload |
| `@ConnectedSocket()` | Inject client socket |

### Microservice Decorators

| Decorator | Purpose |
|-----------|---------|
| `@MessagePattern(pattern)` | Request-response message handler |
| `@EventPattern(pattern)` | Fire-and-forget event handler |
| `@Payload()` | Extract message payload |
| `@Ctx()` | Inject transport context |

### GraphQL Decorators (`@nestjs/graphql`)

| Decorator | Purpose |
|-----------|---------|
| `@Resolver(of?)` | Declare resolver |
| `@Query(returns?)` | Query handler |
| `@Mutation(returns?)` | Mutation handler |
| `@Subscription(returns?)` | Subscription handler |
| `@Args(name?, opts?)` | Extract argument |
| `@ResolveField(name?)` | Field resolver |
| `@Parent()` | Inject parent object |
| `@Context()` | Inject GQL context |

### Swagger/OpenAPI Decorators (`@nestjs/swagger`)

| Decorator | Purpose |
|-----------|---------|
| `@ApiTags(tag)` | Group endpoints |
| `@ApiOperation({ summary })` | Describe endpoint |
| `@ApiResponse({ status, type })` | Document response |
| `@ApiProperty(opts?)` | Document DTO property |
| `@ApiPropertyOptional()` | Optional DTO property |
| `@ApiBearerAuth()` | Requires bearer token |
| `@ApiBody({ type })` | Document request body |
| `@ApiParam({ name })` | Document route param |
| `@ApiQuery({ name })` | Document query param |
| `@ApiHeader({ name })` | Document required header |
| `@ApiExcludeEndpoint()` | Hide from docs |
| `@ApiExcludeController()` | Hide controller from docs |

---

## Module Metadata Options

```typescript
@Module({
  imports: [],       // Other modules whose exported providers are needed
  controllers: [],   // Controllers to instantiate within this module
  providers: [],     // Providers available within this module via DI
  exports: [],       // Subset of providers available to importing modules
})
```

### DynamicModule additional fields

```typescript
interface DynamicModule {
  module: Type<any>;         // The module class
  imports?: Array<...>;      // Same as @Module
  controllers?: Type<any>[]; // Same as @Module
  providers?: Provider[];    // Same as @Module
  exports?: Array<...>;      // Same as @Module
  global?: boolean;          // If true, registers globally
}
```

---

## Provider Types

```typescript
// Standard class provider (shorthand)
providers: [UsersService]
// Equivalent to:
providers: [{ provide: UsersService, useClass: UsersService }]

// Value provider
{ provide: 'CONFIG', useValue: { debug: true } }

// Class provider (interface swap)
{ provide: 'ILogger', useClass: process.env.NODE_ENV === 'prod' ? ProdLogger : DevLogger }

// Factory provider (sync or async)
{ provide: 'DB_CONN', useFactory: async (config: ConfigService) => createConn(config.get('DB')), inject: [ConfigService] }

// Alias provider (existing)
{ provide: 'LogAlias', useExisting: LoggerService }
```

### Provider Scopes

| Scope | Behavior | Use Case |
|-------|----------|----------|
| `Scope.DEFAULT` | Singleton — one instance for entire app | Stateless services, repositories |
| `Scope.REQUEST` | New instance per request | Request-scoped context, user data |
| `Scope.TRANSIENT` | New instance per injection | Stateful per-consumer services |

---

## Lifecycle Hooks

Called in this order during startup and shutdown:

### Startup Sequence

| Hook | Interface | When Called |
|------|-----------|------------|
| `onModuleInit()` | `OnModuleInit` | After the host module's dependencies are resolved |
| `onApplicationBootstrap()` | `OnApplicationBootstrap` | After all modules are initialized |

### Shutdown Sequence (requires `app.enableShutdownHooks()`)

| Hook | Interface | When Called |
|------|-----------|------------|
| `onModuleDestroy()` | `OnModuleDestroy` | After receiving shutdown signal |
| `beforeApplicationShutdown(signal)` | `BeforeApplicationShutdown` | After `onModuleDestroy()`, before connections close |
| `onApplicationShutdown(signal)` | `OnApplicationShutdown` | After all connections are closed |

```typescript
@Injectable()
export class DatabaseService implements OnModuleInit, OnModuleDestroy, OnApplicationShutdown {
  async onModuleInit() {
    await this.connect();
  }
  async onModuleDestroy() {
    await this.pool.drain();
  }
  async onApplicationShutdown(signal: string) {
    console.log(`Shutdown signal: ${signal}`);
    await this.pool.clear();
  }
}
```

---

## Execution Context API

### ArgumentsHost

```typescript
interface ArgumentsHost {
  getArgs<T extends any[] = any[]>(): T;
  getArgByIndex<T = any>(index: number): T;
  switchToRpc(): RpcArgumentsHost;
  switchToHttp(): HttpArgumentsHost;
  switchToWs(): WsArgumentsHost;
  getType<T extends string = ContextType>(): T;
}
```

### HttpArgumentsHost

```typescript
interface HttpArgumentsHost {
  getRequest<T = any>(): T;     // Express: Request
  getResponse<T = any>(): T;    // Express: Response
  getNext<T = any>(): T;        // Express: NextFunction
}
```

### ExecutionContext (extends ArgumentsHost)

```typescript
interface ExecutionContext extends ArgumentsHost {
  getClass<T = any>(): Type<T>;        // Controller class
  getHandler(): Function;               // Handler method
}
```

### Context type detection

```typescript
const type = context.getType();         // 'http' | 'rpc' | 'ws'
const type = context.getType<GqlContextType>(); // 'graphql' for GQL
```

---

## HttpException Hierarchy

All extend `HttpException` from `@nestjs/common`. Throw directly or subclass.

| Exception | Status | Code |
|-----------|--------|------|
| `BadRequestException` | 400 | Bad Request |
| `UnauthorizedException` | 401 | Unauthorized |
| `ForbiddenException` | 403 | Forbidden |
| `NotFoundException` | 404 | Not Found |
| `MethodNotAllowedException` | 405 | Method Not Allowed |
| `NotAcceptableException` | 406 | Not Acceptable |
| `RequestTimeoutException` | 408 | Request Timeout |
| `ConflictException` | 409 | Conflict |
| `GoneException` | 410 | Gone |
| `PayloadTooLargeException` | 413 | Payload Too Large |
| `UnsupportedMediaTypeException` | 415 | Unsupported Media Type |
| `UnprocessableEntityException` | 422 | Unprocessable Entity |
| `InternalServerErrorException` | 500 | Internal Server Error |
| `NotImplementedException` | 501 | Not Implemented |
| `BadGatewayException` | 502 | Bad Gateway |
| `ServiceUnavailableException` | 503 | Service Unavailable |
| `GatewayTimeoutException` | 504 | Gateway Timeout |
| `HttpVersionNotSupportedException` | 505 | HTTP Version Not Supported |

### Custom exception with response object

```typescript
throw new HttpException(
  { statusCode: 403, message: 'Custom forbidden', error: 'Forbidden' },
  HttpStatus.FORBIDDEN,
);

// Custom exception class
export class UserNotFoundException extends NotFoundException {
  constructor(userId: string) {
    super(`User with ID "${userId}" not found`);
  }
}
```

---

## Built-in Pipes

| Pipe | Purpose | Example |
|------|---------|---------|
| `ValidationPipe` | Validate DTOs with class-validator | `@Body(new ValidationPipe()) dto` |
| `ParseIntPipe` | Parse string to integer | `@Param('id', ParseIntPipe) id: number` |
| `ParseFloatPipe` | Parse string to float | `@Query('lat', ParseFloatPipe) lat: number` |
| `ParseBoolPipe` | Parse to boolean | `@Query('active', ParseBoolPipe) active: boolean` |
| `ParseArrayPipe` | Parse to array | `@Query('ids', new ParseArrayPipe({ items: Number }))` |
| `ParseUUIDPipe` | Validate UUID format | `@Param('id', ParseUUIDPipe) id: string` |
| `ParseEnumPipe` | Validate enum value | `@Query('role', new ParseEnumPipe(UserRole))` |
| `DefaultValuePipe` | Provide default value | `@Query('page', new DefaultValuePipe(1), ParseIntPipe)` |
| `ParseFilePipe` | Validate uploaded files | `@UploadedFile(new ParseFilePipe({ validators: [...] }))` |

### ParseFilePipe validators

```typescript
@UploadedFile(new ParseFilePipe({
  validators: [
    new MaxFileSizeValidator({ maxSize: 5 * 1024 * 1024 }), // 5MB
    new FileTypeValidator({ fileType: /^image\/(png|jpeg|gif)$/ }),
  ],
}))
file: Express.Multer.File
```

---

## Platform-Specific Adapters

### Express (default)

```typescript
import { NestFactory } from '@nestjs/core';
import { ExpressAdapter } from '@nestjs/platform-express';

const app = await NestFactory.create(AppModule);
// or explicitly:
const app = await NestFactory.create(AppModule, new ExpressAdapter());
```

- Package: `@nestjs/platform-express`
- Full Express middleware ecosystem
- `req`, `res` are Express types

### Fastify

```typescript
import { NestFactory } from '@nestjs/core';
import { FastifyAdapter, NestFastifyApplication } from '@nestjs/platform-fastify';

const app = await NestFactory.create<NestFastifyApplication>(
  AppModule,
  new FastifyAdapter({ logger: true }),
);
await app.listen(3000, '0.0.0.0'); // Fastify requires explicit host
```

- Package: `@nestjs/platform-fastify`
- ~2x throughput vs Express for JSON-heavy APIs
- Native HTTP/2 and schema-based validation
- Some Express middleware won't work — use Fastify plugins

### Key differences

| Feature | Express | Fastify |
|---------|---------|---------|
| Performance | Baseline | ~2x throughput |
| Middleware | `(req, res, next)` | Plugins / hooks |
| File upload | `multer` | `@fastify/multipart` |
| Static files | `express.static()` | `@fastify/static` |
| CORS | `cors` middleware | `@fastify/cors` |
| Session | `express-session` | `@fastify/session` |
| Req/Res types | Express types | Fastify types |

---

## CLI Commands Reference

### Project management

```bash
nest new <project>                   # Create new project
  --strict                           # Enable strict TypeScript
  --skip-git                         # Skip git init
  --skip-install                     # Skip npm install
  --package-manager pnpm|yarn|npm    # Choose package manager

nest info                            # Show NestJS version info
nest add <package>                   # Install and configure NestJS module
```

### Code generation

```bash
nest generate|g <schematic> <name> [options]

# Schematics:
nest g resource <name>    # Full CRUD (module + controller + service + DTOs + entity)
  --no-spec               # Skip test files
  --type rest|graphql|microservice|ws

nest g module <name>      # Module
nest g controller <name>  # Controller
nest g service <name>     # Service
nest g middleware <name>  # Middleware
nest g guard <name>       # Guard
nest g interceptor <name> # Interceptor
nest g pipe <name>        # Pipe
nest g filter <name>      # Exception filter
nest g gateway <name>     # WebSocket gateway
nest g resolver <name>    # GraphQL resolver
nest g decorator <name>   # Custom decorator
nest g class <name>       # Plain class
nest g interface <name>   # TypeScript interface
nest g library <name>     # Monorepo library

# Common options:
  --flat                  # Don't create subdirectory
  --no-spec               # Skip test file
  --project <name>        # Target project in monorepo
  --dry-run               # Preview without creating
```

### Build & Run

```bash
nest build                           # Compile TypeScript
  --webpack                          # Use webpack bundler
  --tsc                              # Use tsc (default)
  --watch                            # Watch mode
  --builder swc                      # Use SWC compiler (fast)
  --type-check                       # Type checking with SWC

nest start                           # Start application
  --watch                            # Watch mode (auto-reload)
  --debug [port]                     # Debug mode (default 9229)
  --exec <binary>                    # Custom Node binary
  -b swc                             # Use SWC compiler
  --type-check                       # Type checking with SWC
  --preserveWatchOutput              # Don't clear console on rebuild
```

### nest-cli.json options

```json
{
  "collection": "@nestjs/schematics",
  "sourceRoot": "src",
  "compilerOptions": {
    "builder": "swc",
    "typeCheck": true,
    "assets": ["**/*.graphql", "**/*.proto"],
    "watchAssets": true,
    "deleteOutDir": true
  },
  "generateOptions": {
    "spec": false,
    "flat": false
  },
  "monorepo": false,
  "projects": {}
}
```
