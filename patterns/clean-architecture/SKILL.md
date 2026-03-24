---
name: clean-architecture
description: >
  Apply Clean Architecture (Robert C. Martin) to structure applications with strict
  dependency rules and layered separation. Use when: designing new backend services,
  refactoring monoliths into layered architecture, implementing domain-driven design,
  structuring use cases/interactors, setting up repository pattern, adding CQRS,
  organizing TypeScript/Python/Go projects by architectural boundaries, writing
  testable business logic, or decoupling infrastructure from domain.
  Do NOT use for: simple scripts, CLI tools under 200 LOC, static sites, pure frontend
  SPA components, serverless single-function lambdas, prototypes/throwaway code,
  CRUD apps with no business logic, or projects where vertical slice or simple MVC
  suffices. Avoid when team lacks experience with layered patterns or project scope
  does not justify the abstraction overhead.
---

# Clean Architecture

## Core Principles

Enforce the **Dependency Rule**: source code dependencies point inward only. Inner layers
never import, reference, or know about outer layers. Data crossing boundaries flows
through simple DTOs or value objects—never framework-specific types.

Four concentric layers (inside → outside):
1. **Entities** — enterprise business rules, domain objects, value objects
2. **Use Cases** — application-specific business rules, interactors, input/output ports
3. **Interface Adapters** — controllers, presenters, gateways, repository implementations
4. **Frameworks & Drivers** — web frameworks, databases, external APIs, UI

Principles to enforce at every layer boundary:
- Dependency Inversion: depend on abstractions, not concretions
- Interface Segregation: small, focused interfaces per consumer
- Single Responsibility: each module has one reason to change
- Open/Closed: extend behavior without modifying existing code

## Layer Details

### Entities (Domain Layer)

Encode enterprise-wide business rules. Entities are plain objects with behavior—never anemic data bags. They have zero dependencies on any other layer.

Rules:
- Entities contain validation logic, invariant enforcement, domain calculations
- Use Value Objects for identifiers, money, dates, emails—immutable, equality by value
- Domain Events signal state changes without coupling to handlers
- Never import ORM decorators, HTTP types, or framework code into entity files
- Throw domain-specific errors (e.g., `InsufficientFundsError`), not generic exceptions

### Use Cases (Application Layer)

Orchestrate entity interactions to fulfill a single application operation. Each use case is a standalone class/function with one public `execute` method.

Rules:
- Define Input Port (interface the controller calls) and Output Port (interface for
  presenting results) per use case
- Accept a request DTO, return a response DTO—never entities directly
- Inject repository and service interfaces via constructor
- Contain no HTTP, SQL, or framework logic
- Handle application-level errors: not found, authorization, validation failures
- Keep use cases focused: one file per use case, 50-150 lines max

### Interface Adapters

Convert between external formats and use-case formats.

**Controllers**: receive HTTP/gRPC/CLI input → map to use case request DTO → invoke
use case → pass result to presenter.

**Presenters**: receive use case response DTO → format into view model (JSON, HTML,
protocol buffer). Never contain business logic.

**Gateways/Repositories**: implement domain-defined interfaces using concrete
infrastructure (SQL, HTTP clients, file system).

Rules:
- Controllers must not contain business logic—delegate to use cases immediately
- Repository implementations live here, interfaces live in domain/use-case layer
- Map between persistence models and domain entities explicitly—no shared ORM models
- Presenters format output; they do not decide what to output

### Frameworks & Drivers

Outermost layer. All framework configuration, database drivers, web server setup,
third-party SDK wrappers.

Rules:
- Keep this layer as thin as possible—only glue code
- Framework-specific code never leaks inward
- Configuration and dependency injection wiring happens here
- Replace any component in this layer without touching business logic

## TypeScript/Node.js Implementation

### Folder Structure

```
src/
├── domain/
│   ├── entities/           # User.ts, Order.ts
│   ├── value-objects/      # Email.ts, Money.ts, OrderId.ts
│   ├── repositories/       # IUserRepository.ts (interfaces only)
│   ├── services/           # IDomainService.ts (interfaces only)
│   └── errors/             # DomainError.ts, InsufficientFundsError.ts
├── application/
│   ├── use-cases/
│   │   ├── create-order/
│   │   │   ├── CreateOrderUseCase.ts
│   │   │   ├── CreateOrderRequest.ts
│   │   │   └── CreateOrderResponse.ts
│   │   └── get-order/
│   ├── ports/              # IOutputPort.ts, IInputPort.ts
│   └── services/           # Application service interfaces
├── infrastructure/
│   ├── persistence/        # TypeOrmUserRepository.ts, PrismaOrderRepository.ts
│   ├── external/           # PaymentGatewayAdapter.ts, EmailServiceAdapter.ts
│   └── config/             # database.ts, env.ts
├── presentation/
│   ├── http/
│   │   ├── controllers/    # OrderController.ts
│   │   ├── middleware/     # auth.ts, validation.ts
│   │   └── routes/         # orderRoutes.ts
│   └── presenters/         # OrderPresenter.ts, ErrorPresenter.ts
└── main.ts                 # Composition root: wire DI container
```

### TypeScript Example

```typescript
// domain/entities/Order.ts
export class Order {
  private constructor(
    public readonly id: string,
    public readonly items: OrderItem[],
    private _status: OrderStatus
  ) {
    if (items.length === 0) throw new EmptyOrderError();
  }

  static create(id: string, items: OrderItem[]): Order {
    return new Order(id, items, OrderStatus.Pending);
  }

  get total(): Money {
    return this.items.reduce((sum, i) => sum.add(i.subtotal), Money.zero());
  }

  confirm(): void {
    if (this._status !== OrderStatus.Pending)
      throw new InvalidOrderTransitionError(this._status, OrderStatus.Confirmed);
    this._status = OrderStatus.Confirmed;
  }
}

// domain/repositories/IOrderRepository.ts
export interface IOrderRepository {
  findById(id: string): Promise<Order | null>;
  save(order: Order): Promise<void>;
}

// application/use-cases/create-order/CreateOrderUseCase.ts
export class CreateOrderUseCase {
  constructor(
    private readonly orderRepo: IOrderRepository,
    private readonly idGenerator: IIdGenerator
  ) {}

  async execute(req: CreateOrderRequest): Promise<CreateOrderResponse> {
    const order = Order.create(this.idGenerator.generate(), req.items);
    await this.orderRepo.save(order);
    return { orderId: order.id, total: order.total.amount };
  }
}

// presentation/http/controllers/OrderController.ts
export class OrderController {
  constructor(private readonly createOrder: CreateOrderUseCase) {}

  async handle(req: HttpRequest): Promise<HttpResponse> {
    const result = await this.createOrder.execute({
      items: req.body.items.map(mapToOrderItem),
    });
    return { status: 201, body: OrderPresenter.toJson(result) };
  }
}
```

## Python Implementation

### Project Layout

```
src/
├── domain/
│   ├── entities/           # order.py, user.py
│   ├── value_objects/      # money.py, email.py
│   ├── repositories/       # order_repository.py (ABC interfaces)
│   └── errors.py           # DomainError, InsufficientFundsError
├── application/
│   ├── use_cases/
│   │   ├── create_order.py
│   │   └── get_order.py
│   └── dto/                # request/response dataclasses
├── infrastructure/
│   ├── persistence/        # sqlalchemy_order_repo.py
│   ├── external/           # stripe_payment_gateway.py
│   └── config.py
├── presentation/
│   ├── api/                # FastAPI/Flask routes
│   └── presenters/         # order_presenter.py
└── main.py                 # Composition root
```

### Python Example

```python
# domain/repositories/order_repository.py
from abc import ABC, abstractmethod

class OrderRepository(ABC):
    @abstractmethod
    async def find_by_id(self, order_id: str) -> Order | None: ...
    @abstractmethod
    async def save(self, order: Order) -> None: ...

# application/use_cases/create_order.py
@dataclass(frozen=True)
class CreateOrderRequest:
    items: list[OrderItemDTO]

class CreateOrderUseCase:
    def __init__(self, order_repo: OrderRepository, id_gen: IdGenerator):
        self._repo = order_repo
        self._id_gen = id_gen

    async def execute(self, req: CreateOrderRequest) -> CreateOrderResponse:
        order = Order.create(self._id_gen.generate(), req.items)
        await self._repo.save(order)
        return CreateOrderResponse(order_id=order.id, total=order.total.amount)
```

## Go Implementation

### Package Structure

```
cmd/
├── api/main.go             # Entry point, wiring
internal/
├── domain/
│   ├── entity/             # order.go, user.go
│   ├── valueobject/        # money.go, email.go
│   └── repository/         # interfaces: order_repository.go
├── usecase/                # create_order.go, get_order.go
├── adapter/
│   ├── handler/            # http_order_handler.go
│   ├── presenter/          # order_presenter.go
│   └── repository/         # postgres_order_repo.go
└── infrastructure/
    ├── db/                 # connection, migrations
    └── config/             # config.go
```

### Go Example

```go
// internal/domain/repository/order_repository.go
type OrderRepository interface {
    FindByID(ctx context.Context, id string) (*entity.Order, error)
    Save(ctx context.Context, order *entity.Order) error
}

// internal/usecase/create_order.go
type CreateOrderUseCase struct {
    repo   repository.OrderRepository
    idGen  IDGenerator
}

func (uc *CreateOrderUseCase) Execute(ctx context.Context, req CreateOrderRequest) (*CreateOrderResponse, error) {
    order, err := entity.NewOrder(uc.idGen.Generate(), req.Items)
    if err != nil {
        return nil, fmt.Errorf("create order: %w", err)
    }
    if err := uc.repo.Save(ctx, order); err != nil {
        return nil, fmt.Errorf("save order: %w", err)
    }
    return &CreateOrderResponse{OrderID: order.ID, Total: order.Total()}, nil
}
```

Go idiom: define interfaces where they are consumed (use case layer), not where
they are implemented. Keep interfaces small (1-3 methods). Use `internal/` to
enforce package boundaries at the compiler level.

## Dependency Injection

Wire dependencies at the composition root (main.ts/main.py/main.go). Never use
service locators or global singletons for cross-layer dependencies.

Steps: instantiate infrastructure (repos, gateways) → inject into use cases →
inject use cases into controllers → register controllers with router.

For large projects, use a DI container (tsyringe, inversify, injector, wire) but
keep container configuration in the outermost layer only.

## Repository Pattern

Define repository interfaces in the domain layer. Implement in infrastructure.

Rules:
- Repository interface methods use domain types, not ORM/DB types
- One repository per aggregate root
- For testing, create in-memory implementations storing entities in a Map/dict/slice
- Never expose query builders or raw SQL through the repository interface
- Repositories handle persistence mapping—converting between domain entities and DB rows

```typescript
// In-memory for testing
export class InMemoryOrderRepository implements IOrderRepository {
  private orders = new Map<string, Order>();
  async findById(id: string): Promise<Order | null> {
    return this.orders.get(id) ?? null;
  }
  async save(order: Order): Promise<void> {
    this.orders.set(order.id, order);
  }
}
```

## Presenter Pattern

Presenters transform use case output into view-specific formats. Separate the
"what" (use case decides what data) from the "how" (presenter decides format).

```typescript
export class OrderPresenter {
  static toJson(res: CreateOrderResponse): object {
    return { order_id: res.orderId, total: `$${res.total.toFixed(2)}` };
  }
  static toCsv(res: CreateOrderResponse): string {
    return `${res.orderId},${res.total}`;
  }
}
```

## CQRS Integration

Separate command (write) and query (read) paths within Clean Architecture.

```
application/
├── commands/
│   ├── create-order/
│   │   ├── CreateOrderCommand.ts      # { items: OrderItemDTO[] }
│   │   └── CreateOrderHandler.ts      # Mutates state via repos
│   └── cancel-order/
├── queries/
│   ├── get-order/
│   │   ├── GetOrderQuery.ts           # { orderId: string }
│   │   └── GetOrderHandler.ts         # Reads via read-optimized repo
│   └── list-orders/
```

Rules:
- Commands return void or a minimal result (ID). They mutate state.
- Queries return data. They never mutate state.
- Query handlers may bypass domain entities and read directly from optimized views
- Use a command/query bus for dispatch if you have >15 handlers
- Commands validate input, enforce invariants, emit domain events
- Queries can use denormalized read models for performance

## Error Handling Strategy

Define three error categories aligned with layers:

| Layer | Error Type | Example | HTTP Status |
|-------|-----------|---------|-------------|
| Domain | `DomainError` | `InsufficientFundsError` | 422 |
| Application | `ApplicationError` | `OrderNotFoundError` | 404 |
| Infrastructure | `InfrastructureError` | `DatabaseConnectionError` | 500 |

Rules:
- Domain errors are thrown by entities/value objects for invariant violations
- Application errors are thrown by use cases for business rule violations
- Infrastructure errors are caught at the adapter boundary and mapped to application errors
- Never let infrastructure exceptions propagate to domain or use case layers
- Use a global error handler in the presentation layer to map error types to HTTP/gRPC codes
- Include error codes (not just messages) for machine-readable error handling

```typescript
// domain/errors/DomainError.ts
export abstract class DomainError extends Error {
  abstract readonly code: string;
}

export class InsufficientFundsError extends DomainError {
  readonly code = "INSUFFICIENT_FUNDS";
  constructor(available: Money, required: Money) {
    super(`Available ${available} < required ${required}`);
  }
}
```

## Testing Strategy

### Unit Tests (Domain + Use Cases)
- Test entities and value objects with pure functions—no mocks needed
- Test use cases with in-memory repository implementations and stub services
- Assert on response DTOs, not internal state
- Cover domain invariants: invalid construction, state transitions, edge cases
- Target: 90%+ coverage on domain and use case layers

### Integration Tests (Adapters)
- Test repository implementations against a real database (use testcontainers or
  SQLite in-memory for speed)
- Test HTTP controllers with supertest/httptest/TestClient—verify request parsing,
  response formatting, status codes
- Test external service adapters against sandbox APIs or wiremock stubs

### E2E Tests
- Test complete flows through the composition root
- Use a test-specific DI configuration
- Cover critical user journeys only—keep suite small and fast
- Run against docker-compose or similar isolated environment

```typescript
// Unit test for use case
describe("CreateOrderUseCase", () => {
  it("creates order and returns id", async () => {
    const repo = new InMemoryOrderRepository();
    const idGen = { generate: () => "order-1" };
    const uc = new CreateOrderUseCase(repo, idGen);

    const result = await uc.execute({ items: [{ productId: "p1", qty: 2, price: 10 }] });

    expect(result.orderId).toBe("order-1");
    expect(result.total).toBe(20);
    expect(await repo.findById("order-1")).not.toBeNull();
  });
});
```

## Common Mistakes

1. **Over-engineering**: Adding all four layers to a 200-line CRUD app. Start with
   simpler patterns; refactor into Clean Architecture when complexity justifies it.
2. **Anemic domain models**: Entities that are just data bags with getters/setters.
   Push behavior INTO entities—validation, calculations, state transitions.
3. **Leaky abstractions**: Repository interfaces exposing query builder methods,
   ORM-specific types, or SQL fragments. Keep interfaces domain-pure.
4. **Shared ORM models across layers**: Using the same class as entity AND persistence
   model. Create separate models and map between them.
5. **Business logic in controllers**: Controllers should only map input → call use
   case → map output. Zero conditionals on business rules.
6. **Skipping the presenter**: Formatting response data inside use cases couples
   business logic to presentation format.
7. **God use cases**: A single use case doing too much. Split into focused, single-
   purpose interactors.
8. **Circular dependencies**: Usually caused by entities importing from use case
   layer. Fix by extracting shared interfaces.
9. **Injecting concrete classes**: Always inject interfaces, never implementations.
10. **No composition root**: Scattering DI wiring across multiple files instead of
    centralizing in main/bootstrap.

## When to Use Clean Architecture

**Use when**:
- Application has significant business logic (>10 use cases)
- Multiple delivery mechanisms (REST + gRPC + CLI + events)
- Long-lived project with evolving requirements
- Team needs clear boundaries and parallel development
- Testability of business logic is a priority
- Infrastructure may change (database migration, vendor swap)

**Use simpler alternatives when**:
- **MVC**: Small-to-medium CRUD apps, rapid prototyping, <5 use cases
- **Hexagonal/Ports & Adapters**: Same goals but less prescriptive about inner
  layer divisions. Prefer when you want flexibility.
- **Vertical Slices**: Feature-centric organization. Better when features are
  independent and cross-cutting domain logic is minimal.

## Example: Applying the Skill

**User asks**: "Set up a new order management service in TypeScript"

**Response**: Create folder structure per TypeScript layout above. Define `Order`
entity with business rules (create, confirm, cancel, total). Define `IOrderRepository`
in domain. Create `CreateOrderUseCase` with request/response DTOs. Implement
`PostgresOrderRepository` in infrastructure. Create `OrderController` in presentation
wired to Express routes. Set up composition root in `main.ts`. Add
`InMemoryOrderRepository` and write use case unit tests.

**User asks**: "Refactor this Flask app to use Clean Architecture"

**Response**: Identify business rules in route handlers. Extract domain entities into
`domain/entities/`. Define repository ABCs in `domain/repositories/`. Move logic into
use cases in `application/use_cases/`. Wrap SQLAlchemy queries in repository
implementations. Slim route handlers to: parse → call use case → format. Create
`main.py` composition root. Add use case tests with in-memory repos.
