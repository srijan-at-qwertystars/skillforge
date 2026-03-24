# Clean Architecture Troubleshooting Guide

## Table of Contents

- [Over-Abstraction Symptoms](#over-abstraction-symptoms)
- [When Layers Become Ceremony](#when-layers-become-ceremony)
- [Mapping Fatigue (Too Many DTOs)](#mapping-fatigue-too-many-dtos)
- [Circular Dependency Detection](#circular-dependency-detection)
- [Testing Pyramid Imbalance](#testing-pyramid-imbalance)
- [Performance Overhead of Abstraction Layers](#performance-overhead-of-abstraction-layers)
- [DI Container Configuration Complexity](#di-container-configuration-complexity)
- [When to Break the Rules Pragmatically](#when-to-break-the-rules-pragmatically)

---

## Over-Abstraction Symptoms

### Red Flags

1. **Interface mirroring** — Every class has a 1:1 interface with identical methods,
   even when there is only one implementation and no testing need.

   ```typescript
   // ❌ Unnecessary — only one implementation, no test double needed
   interface ILogger { log(msg: string): void; }
   class Logger implements ILogger { log(msg: string) { console.log(msg); } }

   // ✅ Direct use is fine for cross-cutting concerns with one impl
   class Logger { log(msg: string) { console.log(msg); } }
   ```

2. **Pass-through layers** — A use case that just calls the repository with no
   added logic. The layer exists but adds no value.

   ```typescript
   // ❌ This use case adds nothing
   class GetUserUseCase {
     constructor(private repo: IUserRepository) {}
     async execute(id: string) {
       return this.repo.findById(id); // Just forwarding
     }
   }
   ```

3. **Abstraction for hypothetical futures** — Interfaces created for "what if we
   switch databases" when the team has no plans to switch.

4. **6+ files to add one field** — Entity → DTO → Request → Response → Mapper →
   Presenter. If a trivial change touches many files, you're over-abstracted.

### Diagnosis Checklist

| Question | If Yes |
|----------|--------|
| Does this interface have exactly one implementation? | Consider removing the interface |
| Does this use case just forward to repository? | Consider direct repository access for queries |
| Would removing this layer break any test? | If not, the layer may be ceremonial |
| Do team members copy-paste boilerplate to add features? | Reduce layers or add code generation |
| Has anyone actually swapped an implementation? | If never, the abstraction may not be earning its keep |

### Fixes

- **Remove single-implementation interfaces** for things unlikely to change
- **Collapse pass-through use cases** for simple reads (keep for writes)
- **Use CQRS selectively**: queries can bypass domain layer, commands go through it
- **Count files-per-feature**: if >8 files for a simple CRUD operation, reduce layers

---

## When Layers Become Ceremony

### Symptoms

- New developers spend more time learning the architecture than the domain
- PRs for trivial features have 10+ files changed
- "Where does this code go?" is asked multiple times per week
- Architecture diagrams take longer to explain than the business logic

### The Ceremony Spectrum

```
Simple MVC      Pragmatic Clean Arch      Over-Engineered
    │                  │                       │
    ▼                  ▼                       ▼
  3 files/feature    5-7 files/feature      12+ files/feature
  No boundaries      Clear boundaries       Boundaries for boundaries
  Fast delivery      Balanced               Slow delivery
  Hard to test       Easy to test           Easy to test, hard to ship
```

### Right-Sizing Your Architecture

**For CRUD endpoints with no business logic:**
```typescript
// Skip use case layer — controller talks to repository directly
class UserController {
  constructor(private readonly repo: IUserRepository) {}

  async getUser(req: Request): Promise<Response> {
    const user = await this.repo.findById(req.params.id);
    if (!user) return { status: 404 };
    return { status: 200, body: user.toJSON() };
  }
}
```

**For operations with real business logic:**
```typescript
// Use case layer adds value here — validation, invariants, coordination
class TransferFundsUseCase {
  // This use case coordinates multiple aggregates, enforces business rules,
  // and handles failure scenarios — it earns its existence
}
```

### Guideline

If a feature requires only: validate input → save to DB → return result, with
no domain rules, skip the use case layer for that feature. Add it when rules
emerge. This is not breaking Clean Architecture — it's applying YAGNI.

---

## Mapping Fatigue (Too Many DTOs)

### The Problem

A typical over-mapped flow:

```
HTTP Body → RequestDTO → CommandDTO → Entity → PersistenceModel → Entity → ResponseDTO → ViewModel → JSON
     (1)         (2)          (3)       (4)          (5)           (6)        (7)          (8)
```

8 transformations for one operation. Each mapping requires a mapper function,
tests for the mapper, and maintenance when fields change.

### Pragmatic Reduction

```
HTTP Body → Input DTO → Entity → Persistence Model
                          │
                    Response DTO → JSON
```

**Combine where types align:**

1. **Request DTO = Command DTO** — Merge if the controller doesn't transform data
2. **Response DTO = View Model** — Merge if JSON is the only output format
3. **Skip persistence model** — If the entity can be serialized/deserialized
   directly (no ORM entity mapped to domain entity), use same class with
   serialization annotations in the infrastructure layer

### Smart Mapping Strategies

```typescript
// ❌ Manual mapper classes for every entity
class OrderMapper {
  static toDomain(dto: OrderDTO): Order { /* 20 lines */ }
  static toDTO(entity: Order): OrderDTO { /* 20 lines */ }
  static toPersistence(entity: Order): OrderModel { /* 20 lines */ }
  static fromPersistence(model: OrderModel): Order { /* 20 lines */ }
}

// ✅ Use factory methods on the entity itself
class Order {
  static fromDTO(dto: CreateOrderInput): Order {
    return new Order(dto.id, dto.items.map(OrderItem.fromDTO));
  }

  toResponse(): OrderResponse {
    return { id: this.id, total: this.total.amount, status: this.status };
  }
}

// ✅ For persistence, use repository's internal concern
class PostgresOrderRepository implements IOrderRepository {
  async save(order: Order): Promise<void> {
    // Mapping is private to repository — domain doesn't know
    const row = this.toRow(order);
    await this.db.upsert('orders', row);
  }

  private toRow(order: Order): OrderRow { /* ... */ }
  private toDomain(row: OrderRow): Order { /* ... */ }
}
```

### Rules of Thumb

- Max 3 mapping steps per request/response cycle
- If two DTOs have identical fields, merge them
- Persistence mapping belongs inside the repository, not in a separate mapper
- Use code generation (e.g., `class-transformer`, `dataclass` converters) for
  repetitive mappings

---

## Circular Dependency Detection

### Common Circular Dependency Patterns

**1. Entity imports Use Case type:**
```
domain/Order.ts → import { CreateOrderUseCase } from 'application/...'
                   ❌ Domain depends on Application
```
Fix: Entity should never know about use cases. Extract shared types to domain.

**2. Use Case imports Controller type:**
```
application/CreateOrder.ts → import { HttpRequest } from 'presentation/...'
                              ❌ Application depends on Presentation
```
Fix: Use case accepts a plain DTO, not framework types.

**3. Cross-module circular import:**
```
modules/ordering/ → import from modules/billing/
modules/billing/  → import from modules/ordering/
                    ❌ Circular module dependency
```
Fix: Introduce domain events or a shared kernel.

### Detection Script (Conceptual)

Define allowed dependency direction:
```
presentation → application → domain
infrastructure → application → domain
infrastructure → domain
```

Any import that violates this direction is a circular dependency or layer
violation. See `scripts/check-dependencies.sh` for automated detection.

### Manual Detection

```bash
# Find domain files importing from application/infrastructure/presentation
grep -rn "from.*application\|from.*infrastructure\|from.*presentation" src/domain/

# Find application files importing from presentation
grep -rn "from.*presentation" src/application/

# Find circular imports between modules
# Look for: module A imports B AND module B imports A
```

### Prevention

1. **Enforce with linting** — ESLint `import/no-restricted-paths`, Go `internal/`
2. **CI checks** — Run `check-dependencies.sh` in CI pipeline
3. **Architecture tests** — Use ArchUnit (Java), NetArchTest (.NET), or custom
   test that validates import directions
4. **Barrel exports** — Each layer exports only its public API through an
   `index.ts` barrel file

---

## Testing Pyramid Imbalance

### Healthy Pyramid for Clean Architecture

```
         ╱╲
        ╱  ╲         E2E Tests: 5-10%
       ╱    ╲        (Full stack, docker-compose, slow)
      ╱──────╲
     ╱        ╲      Integration Tests: 20-30%
    ╱          ╲     (Repository + DB, HTTP controllers)
   ╱────────────╲
  ╱              ╲   Unit Tests: 60-75%
 ╱                ╲  (Entities, value objects, use cases)
╱──────────────────╲
```

### Common Imbalances

**Inverted Pyramid (too many E2E, few unit):**
- Cause: Testing through the UI/API because unit testing "seems hard"
- Symptom: Test suite takes 30+ minutes, flaky tests
- Fix: Test use cases with in-memory repos, test entities with no deps

**Missing Middle (unit + E2E, no integration):**
- Cause: Skipping repository/adapter tests
- Symptom: "Works in unit tests, fails in production"
- Fix: Add repository tests with testcontainers or SQLite, test mappers

**Mock-Heavy Unit Tests:**
- Cause: Mocking everything including domain objects
- Symptom: Tests pass but don't catch real bugs, brittle test code
- Fix: Use real entities, in-memory repos. Only mock external services.

### Testing Each Layer

| Layer | What to Test | How | Mocks |
|-------|-------------|-----|-------|
| Entity | Invariants, calculations, state transitions | Pure unit tests | None |
| Value Object | Equality, validation, immutability | Pure unit tests | None |
| Use Case | Orchestration, error handling, output | Unit with in-memory repos | External services only |
| Repository | CRUD operations, query correctness | Integration with real DB | None |
| Controller | Request parsing, status codes, response format | Integration with supertest | Use cases (optional) |

### Anti-Pattern: Testing Implementation, Not Behavior

```typescript
// ❌ Testing implementation — brittle
it('should call repository.save once', () => {
  expect(mockRepo.save).toHaveBeenCalledTimes(1);
});

// ✅ Testing behavior — resilient
it('should persist the order', async () => {
  await useCase.execute(validRequest);
  const saved = await repo.findById('order-1');
  expect(saved).not.toBeNull();
  expect(saved!.status).toBe('pending');
});
```

---

## Performance Overhead of Abstraction Layers

### Where Overhead Occurs

1. **Object mapping** — Converting between DTOs, entities, persistence models
2. **Virtual dispatch** — Interface-based calls (negligible in most languages)
3. **Memory allocation** — Creating intermediate objects at each layer boundary
4. **Over-fetching** — Repository loads full aggregate when query needs 2 fields

### Measuring Impact

Before optimizing, measure. Most "Clean Architecture is slow" claims are about:
- N+1 query problems (repository implementation issue, not architecture)
- Loading full aggregates for list views (misapplied pattern)
- Unnecessary mapping for simple pass-through operations

### Solutions

**For read-heavy endpoints:**
```typescript
// ✅ Use a dedicated read model — bypass domain layer
interface OrderListReadModel {
  findOrderSummaries(filters: OrderFilters): Promise<OrderSummaryDTO[]>;
}

// Implementation queries directly — no entity hydration
class PostgresOrderListReadModel implements OrderListReadModel {
  async findOrderSummaries(filters: OrderFilters): Promise<OrderSummaryDTO[]> {
    const rows = await this.db.query(
      'SELECT id, status, total, created_at FROM orders WHERE ...',
      [filters]
    );
    return rows; // Return DTOs directly — no entity mapping
  }
}
```

**For hot paths:**
```typescript
// ✅ Cache at the use case level
class GetOrderUseCase {
  constructor(
    private repo: IOrderRepository,
    private cache: ICacheService
  ) {}

  async execute(id: string): Promise<OrderResponse> {
    const cached = await this.cache.get<OrderResponse>(`order:${id}`);
    if (cached) return cached;

    const order = await this.repo.findById(id);
    const response = OrderMapper.toResponse(order);
    await this.cache.set(`order:${id}`, response, 300);
    return response;
  }
}
```

**For bulk operations:**
```typescript
// ❌ Loading aggregates one by one
for (const id of orderIds) {
  const order = await repo.findById(id);
  order.archive();
  await repo.save(order);
}

// ✅ Batch repository method
await repo.archiveAll(orderIds);
// Acceptable to bypass domain for bulk ops if business rules are simple
```

### Rule

The domain layer should be fast — it's just objects and logic. If you have
performance issues, look at the infrastructure layer (queries, I/O, mapping),
not the architecture pattern.

---

## DI Container Configuration Complexity

### Symptoms

- Container setup file exceeds 200 lines
- Adding a new use case requires editing 3+ container config files
- Runtime errors from missing bindings discovered only at startup
- Circular dependency errors from the DI container, not your code

### Solutions by Complexity Level

**Small projects (< 10 use cases): Manual wiring**

```typescript
// main.ts — just wire it manually
const db = new PostgresConnection(config.db);
const orderRepo = new PostgresOrderRepository(db);
const createOrder = new CreateOrderUseCase(orderRepo, new UuidGenerator());
const orderController = new OrderController(createOrder);
app.post('/orders', orderController.handle.bind(orderController));
```

Advantages: No container, explicit, type-safe, easy to debug.

**Medium projects (10-30 use cases): Module-based registration**

```typescript
// Each module registers its own bindings
function registerOrderModule(container: Container): void {
  container.bind(IOrderRepository).to(PostgresOrderRepository).inSingletonScope();
  container.bind(CreateOrderUseCase).toSelf();
  container.bind(GetOrderUseCase).toSelf();
  container.bind(OrderController).toSelf();
}

// main.ts
const container = new Container();
registerOrderModule(container);
registerBillingModule(container);
registerShippingModule(container);
```

**Large projects (30+ use cases): Convention-based with validation**

```typescript
// Auto-register by naming convention
container.loadAsync(
  new ContainerModule(async (bind) => {
    const useCases = await glob('src/application/use-cases/**/*UseCase.ts');
    for (const uc of useCases) {
      const module = await import(uc);
      bind(module.default).toSelf();
    }
  })
);

// Add startup validation
container.validateBinding(); // Throws if any dependency is unresolved
```

### Debugging DI Issues

```typescript
// 1. Log all registered bindings at startup
console.log('Registered bindings:', container.getAll());

// 2. Validate eagerly — don't wait for first request
try {
  container.get(OrderController); // Force resolution at startup
} catch (e) {
  console.error('DI misconfiguration:', e.message);
  process.exit(1);
}

// 3. Use typed tokens instead of string tokens
const ORDER_REPO = Symbol.for('IOrderRepository');
container.bind<IOrderRepository>(ORDER_REPO).to(PostgresOrderRepository);
```

---

## When to Break the Rules Pragmatically

### Acceptable Exceptions

**1. Simple CRUD with no domain logic:**
Skip the use case layer. Controller → Repository → Response.
```
Why: The use case would be pure pass-through, adding no value.
Risk: Low. Add use case later if business rules emerge.
```

**2. Query endpoints reading denormalized data:**
Bypass domain entities. Query handler → read-optimized DB view → DTO.
```
Why: Hydrating domain objects just to serialize them is wasteful.
Risk: None. Reads don't modify state, so no invariants to protect.
```

**3. Bulk operations:**
Use direct SQL in the repository instead of loading/saving aggregates.
```
Why: Loading 10,000 entities to set a flag is impractical.
Risk: Medium. Document which business rules are bypassed and why.
```

**4. Performance-critical paths:**
Allow inner layers to know about caching or batching concerns.
```
Why: Strict layering may introduce unacceptable latency.
Risk: Medium. Isolate the optimization and document the trade-off.
```

**5. Prototyping / MVP:**
Use simplified architecture. Refactor to Clean Architecture when domain
complexity justifies it.
```
Why: Architecture is an investment; ensure the project warrants it.
Risk: Low if you refactor before complexity makes it painful.
```

### Decision Framework

```
Does this feature have business rules beyond validate-save-return?
├── YES → Full Clean Architecture (entity → use case → controller)
└── NO
    ├── Will it likely gain business rules soon?
    │   ├── YES → Use case layer (lightweight, ready for rules)
    │   └── NO → Controller → Repository (skip use case)
    └── Is it a read-only query?
        ├── YES → Direct read model (skip domain entities)
        └── NO → Use case layer (writes always need orchestration)
```

### The Golden Rule

**Every layer must earn its existence.** If you can't articulate what value a
layer adds for a specific feature, don't add it for that feature. Clean
Architecture is a guideline for managing complexity, not a religion to follow
regardless of cost.

### Documentation Requirement

When breaking a rule, add a brief comment:
```typescript
// ARCH-DEVIATION: Direct repository access — no business logic in this query.
// Revisit if discount rules are added to order listing.
class OrderListController {
  constructor(private readonly repo: IOrderReadRepository) {}
  // ...
}
```
