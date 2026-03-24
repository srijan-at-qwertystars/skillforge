# Advanced Clean Architecture Patterns

## Table of Contents

- [CQRS with Event Sourcing](#cqrs-with-event-sourcing)
- [Domain Events](#domain-events)
- [Aggregate Roots](#aggregate-roots)
- [Value Objects](#value-objects)
- [Specification Pattern](#specification-pattern)
- [Unit of Work](#unit-of-work)
- [Bounded Contexts](#bounded-contexts)
- [Anti-Corruption Layer](#anti-corruption-layer)
- [Hexagonal Architecture Comparison](#hexagonal-architecture-comparison)
- [Vertical Slice Architecture Comparison](#vertical-slice-architecture-comparison)
- [Modular Monolith with Clean Architecture](#modular-monolith-with-clean-architecture)

---

## CQRS with Event Sourcing

CQRS separates read and write models. Event Sourcing stores state changes as
an immutable sequence of domain events rather than overwriting current state.

### Architecture

```
Command Side                          Query Side
┌──────────────┐                     ┌──────────────┐
│  Command     │                     │  Query       │
│  Handler     │                     │  Handler     │
└──────┬───────┘                     └──────┬───────┘
       │                                    │
       ▼                                    ▼
┌──────────────┐    Projection       ┌──────────────┐
│  Event Store │───────────────────▶ │  Read Model  │
│  (append)    │    (denormalize)    │  (optimized) │
└──────────────┘                     └──────────────┘
```

### Implementation (TypeScript)

```typescript
// domain/events/DomainEvent.ts
export interface DomainEvent {
  readonly eventType: string;
  readonly aggregateId: string;
  readonly occurredAt: Date;
  readonly payload: Record<string, unknown>;
}

// domain/entities/EventSourcedAggregate.ts
export abstract class EventSourcedAggregate {
  private uncommittedEvents: DomainEvent[] = [];
  private version = 0;

  protected apply(event: DomainEvent): void {
    this.when(event);
    this.uncommittedEvents.push(event);
    this.version++;
  }

  protected abstract when(event: DomainEvent): void;

  getUncommittedEvents(): DomainEvent[] {
    return [...this.uncommittedEvents];
  }

  clearUncommittedEvents(): void {
    this.uncommittedEvents = [];
  }

  loadFromHistory(events: DomainEvent[]): void {
    for (const event of events) {
      this.when(event);
      this.version++;
    }
  }
}

// domain/entities/Order.ts — event-sourced
export class Order extends EventSourcedAggregate {
  private _id!: string;
  private _status!: string;
  private _items: OrderItem[] = [];

  static create(id: string, items: OrderItem[]): Order {
    const order = new Order();
    order.apply({
      eventType: 'OrderCreated',
      aggregateId: id,
      occurredAt: new Date(),
      payload: { items },
    });
    return order;
  }

  confirm(): void {
    if (this._status !== 'pending') throw new Error('Cannot confirm');
    this.apply({
      eventType: 'OrderConfirmed',
      aggregateId: this._id,
      occurredAt: new Date(),
      payload: {},
    });
  }

  protected when(event: DomainEvent): void {
    switch (event.eventType) {
      case 'OrderCreated':
        this._id = event.aggregateId;
        this._status = 'pending';
        this._items = event.payload.items as OrderItem[];
        break;
      case 'OrderConfirmed':
        this._status = 'confirmed';
        break;
    }
  }
}

// infrastructure/persistence/EventStore.ts
export interface EventStore {
  append(aggregateId: string, events: DomainEvent[], expectedVersion: number): Promise<void>;
  getEvents(aggregateId: string): Promise<DomainEvent[]>;
}

// infrastructure/persistence/PostgresEventStore.ts
export class PostgresEventStore implements EventStore {
  constructor(private readonly pool: Pool) {}

  async append(aggregateId: string, events: DomainEvent[], expectedVersion: number): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      // Optimistic concurrency: check current version
      const { rows } = await client.query(
        'SELECT MAX(version) as ver FROM events WHERE aggregate_id = $1',
        [aggregateId]
      );
      const currentVersion = rows[0]?.ver ?? 0;
      if (currentVersion !== expectedVersion) {
        throw new ConcurrencyError(aggregateId, expectedVersion, currentVersion);
      }
      let version = expectedVersion;
      for (const event of events) {
        version++;
        await client.query(
          `INSERT INTO events (aggregate_id, version, event_type, payload, occurred_at)
           VALUES ($1, $2, $3, $4, $5)`,
          [aggregateId, version, event.eventType, JSON.stringify(event.payload), event.occurredAt]
        );
      }
      await client.query('COMMIT');
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    } finally {
      client.release();
    }
  }

  async getEvents(aggregateId: string): Promise<DomainEvent[]> {
    const { rows } = await this.pool.query(
      'SELECT * FROM events WHERE aggregate_id = $1 ORDER BY version ASC',
      [aggregateId]
    );
    return rows.map(r => ({
      eventType: r.event_type,
      aggregateId: r.aggregate_id,
      occurredAt: r.occurred_at,
      payload: r.payload,
    }));
  }
}
```

### Projection Pattern

```typescript
// infrastructure/projections/OrderProjection.ts
export class OrderProjection {
  constructor(private readonly readDb: Pool) {}

  async handle(event: DomainEvent): Promise<void> {
    switch (event.eventType) {
      case 'OrderCreated':
        await this.readDb.query(
          `INSERT INTO order_read_model (id, status, item_count, created_at)
           VALUES ($1, 'pending', $2, $3)`,
          [event.aggregateId, (event.payload.items as any[]).length, event.occurredAt]
        );
        break;
      case 'OrderConfirmed':
        await this.readDb.query(
          `UPDATE order_read_model SET status = 'confirmed', updated_at = $1 WHERE id = $2`,
          [event.occurredAt, event.aggregateId]
        );
        break;
    }
  }
}
```

### When to Use

- **Use**: Audit requirements, complex state transitions, multi-model read optimization
- **Avoid**: Simple CRUD, small teams unfamiliar with event sourcing, when eventual
  consistency is unacceptable for all reads

---

## Domain Events

Domain events capture something meaningful that happened in the domain. They are
past-tense facts, not commands.

### Naming Convention

- `OrderPlaced`, `PaymentReceived`, `UserRegistered` — past tense, domain language
- Never: `CreateOrder`, `HandlePayment` — those are commands

### Implementation

```typescript
// domain/events/DomainEvent.ts
export abstract class DomainEvent {
  readonly occurredAt: Date = new Date();
  abstract readonly eventType: string;
}

export class OrderPlaced extends DomainEvent {
  readonly eventType = 'OrderPlaced';
  constructor(
    public readonly orderId: string,
    public readonly total: number,
    public readonly itemCount: number
  ) {
    super();
  }
}

// domain/entities/Entity.ts — base with event collection
export abstract class AggregateRoot {
  private _domainEvents: DomainEvent[] = [];

  protected addDomainEvent(event: DomainEvent): void {
    this._domainEvents.push(event);
  }

  pullDomainEvents(): DomainEvent[] {
    const events = [...this._domainEvents];
    this._domainEvents = [];
    return events;
  }
}
```

### Dispatching Events

```typescript
// application/services/EventDispatcher.ts
export interface EventDispatcher {
  dispatch(events: DomainEvent[]): Promise<void>;
}

// Dispatch after saving — in the use case
export class PlaceOrderUseCase {
  constructor(
    private readonly repo: IOrderRepository,
    private readonly dispatcher: EventDispatcher
  ) {}

  async execute(req: PlaceOrderRequest): Promise<void> {
    const order = Order.create(req.id, req.items);
    await this.repo.save(order);
    // Dispatch events AFTER successful persistence
    await this.dispatcher.dispatch(order.pullDomainEvents());
  }
}
```

### Event Handlers

```typescript
// application/handlers/SendOrderConfirmationHandler.ts
export class SendOrderConfirmationHandler implements EventHandler<OrderPlaced> {
  constructor(private readonly emailService: IEmailService) {}

  async handle(event: OrderPlaced): Promise<void> {
    await this.emailService.sendOrderConfirmation(event.orderId);
  }
}
```

### Rules

1. Events are immutable records of what happened
2. Dispatch after persistence succeeds — never before
3. Handlers must be idempotent (safe to replay)
4. Cross-aggregate communication uses events, not direct references
5. Keep event payloads minimal — include IDs, not full objects

---

## Aggregate Roots

An aggregate is a cluster of domain objects treated as a single unit for data
changes. The root entity is the only entry point.

### Design Rules

1. **One repository per aggregate** — never for child entities
2. **Transactional boundary** — all changes within an aggregate are saved atomically
3. **Reference other aggregates by ID only** — never hold object references
4. **Keep aggregates small** — large aggregates cause concurrency bottlenecks
5. **Invariant enforcement** — the root guards all business rules for the cluster

### Example

```typescript
// Order is the aggregate root
// OrderItem is a child entity — no separate repository
export class Order extends AggregateRoot {
  private _items: OrderItem[] = [];

  addItem(product: ProductId, quantity: number, price: Money): void {
    if (this._status !== 'draft')
      throw new OrderLockedError(this._id);
    const existing = this._items.find(i => i.productId.equals(product));
    if (existing) {
      existing.increaseQuantity(quantity);
    } else {
      this._items.push(new OrderItem(product, quantity, price));
    }
    this.addDomainEvent(new ItemAddedToOrder(this._id, product.value, quantity));
  }

  // Reference to Customer aggregate by ID only
  private _customerId: CustomerId;

  // NOT this — never hold aggregate references:
  // private _customer: Customer; // ❌
}
```

### Sizing Guidelines

| Symptom | Fix |
|---------|-----|
| Frequent optimistic concurrency failures | Split into smaller aggregates |
| Loading an aggregate requires 10+ queries | Too many children — extract aggregates |
| Two users can't edit "different parts" concurrently | Aggregate boundary is too wide |
| Aggregate has >7 child entity types | Almost certainly too big — decompose |

---

## Value Objects

Immutable objects defined by their attributes, not an identity. Two value
objects with the same attributes are equal.

### Implementation

```typescript
export class Money {
  private constructor(
    public readonly amount: number,
    public readonly currency: string
  ) {
    if (amount < 0) throw new NegativeAmountError(amount);
    if (!['USD', 'EUR', 'GBP'].includes(currency))
      throw new UnsupportedCurrencyError(currency);
  }

  static of(amount: number, currency: string): Money {
    return new Money(amount, currency);
  }

  static zero(currency = 'USD'): Money {
    return new Money(0, currency);
  }

  add(other: Money): Money {
    if (this.currency !== other.currency)
      throw new CurrencyMismatchError(this.currency, other.currency);
    return new Money(this.amount + other.amount, this.currency);
  }

  multiply(factor: number): Money {
    return new Money(Math.round(this.amount * factor * 100) / 100, this.currency);
  }

  equals(other: Money): boolean {
    return this.amount === other.amount && this.currency === other.currency;
  }

  toString(): string {
    return `${this.currency} ${this.amount.toFixed(2)}`;
  }
}

export class Email {
  private constructor(public readonly value: string) {
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(value))
      throw new InvalidEmailError(value);
  }

  static create(value: string): Email {
    return new Email(value.toLowerCase().trim());
  }

  equals(other: Email): boolean {
    return this.value === other.value;
  }
}
```

### When to Use Value Objects

- Monetary amounts, currencies
- Email addresses, phone numbers, URLs
- Date ranges, time periods
- Coordinates, addresses
- Measurements (weight, distance, temperature)
- Entity identifiers (typed IDs instead of raw strings)

---

## Specification Pattern

Encapsulate query/filtering criteria as composable, reusable objects. Keeps
business rules out of repositories and controllers.

### Implementation

```typescript
// domain/specifications/Specification.ts
export abstract class Specification<T> {
  abstract isSatisfiedBy(candidate: T): boolean;

  and(other: Specification<T>): Specification<T> {
    return new AndSpecification(this, other);
  }

  or(other: Specification<T>): Specification<T> {
    return new OrSpecification(this, other);
  }

  not(): Specification<T> {
    return new NotSpecification(this);
  }
}

class AndSpecification<T> extends Specification<T> {
  constructor(private left: Specification<T>, private right: Specification<T>) { super(); }
  isSatisfiedBy(candidate: T): boolean {
    return this.left.isSatisfiedBy(candidate) && this.right.isSatisfiedBy(candidate);
  }
}

class OrSpecification<T> extends Specification<T> {
  constructor(private left: Specification<T>, private right: Specification<T>) { super(); }
  isSatisfiedBy(candidate: T): boolean {
    return this.left.isSatisfiedBy(candidate) || this.right.isSatisfiedBy(candidate);
  }
}

class NotSpecification<T> extends Specification<T> {
  constructor(private spec: Specification<T>) { super(); }
  isSatisfiedBy(candidate: T): boolean {
    return !this.spec.isSatisfiedBy(candidate);
  }
}

// domain/specifications/OrderSpecifications.ts
export class HighValueOrder extends Specification<Order> {
  constructor(private threshold: Money) { super(); }
  isSatisfiedBy(order: Order): boolean {
    return order.total.amount >= this.threshold.amount;
  }
}

export class PendingOrder extends Specification<Order> {
  isSatisfiedBy(order: Order): boolean {
    return order.status === 'pending';
  }
}

// Usage in use case
const highValuePending = new HighValueOrder(Money.of(1000, 'USD')).and(new PendingOrder());
const flaggedOrders = orders.filter(o => highValuePending.isSatisfiedBy(o));
```

### Repository Integration

```typescript
// Extend repository interface to accept specifications
export interface IOrderRepository {
  findById(id: string): Promise<Order | null>;
  findAll(spec: Specification<Order>): Promise<Order[]>;
  save(order: Order): Promise<void>;
}

// Implementation translates specifications to SQL WHERE clauses
// or filters in-memory for testing
```

---

## Unit of Work

Tracks changes to multiple aggregates and commits them in a single transaction.
Prevents partial saves across related operations.

### Implementation

```typescript
// domain/ports/UnitOfWork.ts
export interface UnitOfWork {
  orderRepository: IOrderRepository;
  customerRepository: ICustomerRepository;
  commit(): Promise<void>;
  rollback(): Promise<void>;
}

// infrastructure/persistence/TypeOrmUnitOfWork.ts
export class TypeOrmUnitOfWork implements UnitOfWork {
  private queryRunner: QueryRunner;

  constructor(private dataSource: DataSource) {
    this.queryRunner = dataSource.createQueryRunner();
  }

  get orderRepository(): IOrderRepository {
    return new TypeOrmOrderRepository(this.queryRunner.manager);
  }

  get customerRepository(): ICustomerRepository {
    return new TypeOrmCustomerRepository(this.queryRunner.manager);
  }

  async commit(): Promise<void> {
    await this.queryRunner.commitTransaction();
    await this.queryRunner.release();
  }

  async rollback(): Promise<void> {
    await this.queryRunner.rollbackTransaction();
    await this.queryRunner.release();
  }
}

// Usage in use case
export class TransferOrderUseCase {
  constructor(private readonly uowFactory: () => UnitOfWork) {}

  async execute(req: TransferOrderRequest): Promise<void> {
    const uow = this.uowFactory();
    try {
      const order = await uow.orderRepository.findById(req.orderId);
      const newCustomer = await uow.customerRepository.findById(req.newCustomerId);
      order.transferTo(newCustomer.id);
      await uow.orderRepository.save(order);
      await uow.commit();
    } catch (e) {
      await uow.rollback();
      throw e;
    }
  }
}
```

---

## Bounded Contexts

A bounded context is a boundary within which a particular domain model is
defined and applicable. Different contexts can have different models for the
same real-world concept.

### Example: "User" in Different Contexts

```
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│   Identity Context  │  │   Billing Context    │  │  Shipping Context   │
│                     │  │                      │  │                     │
│   User              │  │   Customer           │  │   Recipient         │
│   - id              │  │   - id               │  │   - id              │
│   - email           │  │   - customerId       │  │   - recipientId     │
│   - passwordHash    │  │   - billingAddress   │  │   - shippingAddress │
│   - roles           │  │   - paymentMethod    │  │   - phoneNumber     │
│   - lastLogin       │  │   - creditLimit      │  │   - deliveryNotes   │
└─────────────────────┘  └─────────────────────┘  └─────────────────────┘
```

### Communication Between Contexts

1. **Shared Kernel** — Shared code library (use sparingly, couples contexts)
2. **Customer/Supplier** — One context provides, other consumes. Clear contract.
3. **Anti-Corruption Layer** — Translator between contexts (see next section)
4. **Published Language** — Shared schema/protocol (e.g., Protobuf, JSON Schema)
5. **Domain Events** — Async communication via event bus (preferred for loose coupling)

### Clean Architecture Alignment

Each bounded context gets its own Clean Architecture stack:

```
service-identity/
├── src/domain/          # User, Role, Permission
├── src/application/     # RegisterUser, Login
├── src/infrastructure/
└── src/presentation/

service-billing/
├── src/domain/          # Customer, Invoice, Payment
├── src/application/     # ChargeCustomer, GenerateInvoice
├── src/infrastructure/
└── src/presentation/
```

---

## Anti-Corruption Layer

A translation layer that prevents external or legacy models from contaminating
your domain model. Essential when integrating with third-party APIs, legacy
systems, or other bounded contexts with different models.

### Implementation

```typescript
// The external system's model — you don't control this
interface LegacyOrderDTO {
  order_num: string;
  cust_id: number;
  line_items: { sku: string; qty: number; unit_price_cents: number }[];
  order_date: string; // "MM/DD/YYYY"
  status_code: 'A' | 'P' | 'C' | 'X';
}

// Anti-corruption layer — translates to your domain
export class LegacyOrderTranslator {
  toDomain(legacy: LegacyOrderDTO): Order {
    const items = legacy.line_items.map(li =>
      new OrderItem(
        ProductId.from(li.sku),
        li.qty,
        Money.of(li.unit_price_cents / 100, 'USD')
      )
    );
    const status = this.mapStatus(legacy.status_code);
    return Order.reconstitute(legacy.order_num, items, status);
  }

  private mapStatus(code: string): OrderStatus {
    const map: Record<string, OrderStatus> = {
      'A': OrderStatus.Active,
      'P': OrderStatus.Pending,
      'C': OrderStatus.Completed,
      'X': OrderStatus.Cancelled,
    };
    return map[code] ?? OrderStatus.Unknown;
  }
}

// Gateway uses the ACL
export class LegacyOrderGateway implements IOrderImportGateway {
  constructor(
    private readonly client: LegacyApiClient,
    private readonly translator: LegacyOrderTranslator
  ) {}

  async importOrder(orderNumber: string): Promise<Order> {
    const legacy = await this.client.getOrder(orderNumber);
    return this.translator.toDomain(legacy);
  }
}
```

### When to Build an ACL

- Integrating with a legacy system you can't modify
- Consuming a third-party API with a different domain language
- Merging two systems with overlapping but different models
- Wrapping an external service whose API may change

---

## Hexagonal Architecture Comparison

Hexagonal (Ports & Adapters) and Clean Architecture share the same core
principle: business logic at the center, infrastructure at the edges.

### Side-by-Side

| Aspect | Clean Architecture | Hexagonal |
|--------|-------------------|-----------|
| Layers | 4 concentric (entities, use cases, adapters, frameworks) | 2 (inside: application, outside: adapters) |
| Ports | Implicit (repository interfaces, input/output DTOs) | Explicit: driving ports (API) and driven ports (SPI) |
| Prescriptiveness | More prescriptive about inner layer divisions | Flexible — doesn't prescribe internal structure |
| Visualization | Concentric circles | Hexagon with ports on edges |
| Testing | Test use cases with mock adapters | Test through ports with stub adapters |
| Best for | Teams wanting clear layer guidelines | Teams wanting flexibility in internal organization |

### Practical Equivalences

```
Hexagonal                      Clean Architecture
─────────────────────────────  ──────────────────────────
Driving Port (primary)     →   Use Case Input Port / Controller interface
Driven Port (secondary)    →   Repository/Gateway interface (in domain)
Driving Adapter            →   Controller / Presenter
Driven Adapter             →   Repository implementation / External service adapter
Application Core           →   Entities + Use Cases
```

### Recommendation

Use Clean Architecture when you want prescriptive guidance on internal layering.
Use Hexagonal when your team is experienced and wants to decide internal
structure per-context. They are compatible — Clean Architecture is essentially
Hexagonal with more internal structure.

---

## Vertical Slice Architecture Comparison

Vertical Slice organizes code by feature, not by layer. Each "slice" contains
everything needed for one operation: handler, validation, persistence, response.

### Side-by-Side

| Aspect | Clean Architecture | Vertical Slice |
|--------|-------------------|----------------|
| Organization | By layer (domain/, application/, infrastructure/) | By feature (features/create-order/, features/get-order/) |
| Shared code | Entities and interfaces shared across use cases | Minimal sharing — each slice owns its code |
| Consistency | Uniform structure across all features | Each slice can use different patterns |
| Refactoring | Change an entity → touch many use cases | Change a feature → touch one folder |
| Best for | Strong domain model, many cross-cutting rules | Independent features, CRUD-heavy, varying complexity |

### Vertical Slice Structure

```
src/features/
├── create-order/
│   ├── CreateOrderHandler.ts    # Includes validation, persistence, response
│   ├── CreateOrderRequest.ts
│   └── CreateOrderValidator.ts
├── get-order/
│   ├── GetOrderHandler.ts
│   └── GetOrderQuery.ts
└── shared/
    └── db.ts                    # Minimal shared infrastructure
```

### Hybrid Approach

Use Clean Architecture for the domain core and vertical slices for the
application layer. Entities and value objects remain shared; use cases are
organized by feature.

```
src/
├── domain/                     # Shared entities, value objects, interfaces
├── features/                   # Vertical slices
│   ├── create-order/
│   │   ├── handler.ts
│   │   └── dto.ts
│   └── get-order/
└── infrastructure/             # Shared adapters
```

---

## Modular Monolith with Clean Architecture

A modular monolith applies bounded context separation within a single
deployable unit. Each module has its own Clean Architecture stack but shares
a process and database.

### Structure

```
src/
├── modules/
│   ├── ordering/
│   │   ├── domain/
│   │   │   ├── entities/       # Order, OrderItem
│   │   │   └── repositories/   # IOrderRepository
│   │   ├── application/
│   │   │   └── use-cases/      # CreateOrder, CancelOrder
│   │   ├── infrastructure/
│   │   │   └── persistence/    # PostgresOrderRepository
│   │   ├── presentation/
│   │   │   └── controllers/    # OrderController
│   │   └── module.ts           # Module registration, exports
│   ├── billing/
│   │   ├── domain/
│   │   ├── application/
│   │   ├── infrastructure/
│   │   ├── presentation/
│   │   └── module.ts
│   └── shipping/
│       └── ...
├── shared/
│   ├── kernel/                 # Shared value objects, base classes
│   └── infrastructure/         # Database connection, event bus, logging
└── main.ts                     # Compose all modules
```

### Module Communication Rules

1. **No direct imports between modules** — modules communicate through:
   - Published interfaces (module's public API)
   - Domain events via in-process event bus
   - Shared kernel (minimal, versioned carefully)
2. **Each module owns its database tables** — no cross-module joins
3. **Module boundaries are future microservice boundaries** — extract when needed

### Module Registration

```typescript
// modules/ordering/module.ts
export class OrderingModule {
  static register(container: Container): void {
    container.bind(IOrderRepository).to(PostgresOrderRepository);
    container.bind(CreateOrderUseCase).toSelf();
    container.bind(OrderController).toSelf();
  }

  // Public API — only these can be called from other modules
  static readonly publicApi = {
    getOrderStatus: GetOrderStatusUseCase,
    onOrderPlaced: OrderPlaced, // Event type
  };
}

// main.ts
OrderingModule.register(container);
BillingModule.register(container);
ShippingModule.register(container);
```

### Migration to Microservices

When a module needs independent scaling or deployment:

1. Replace in-process event bus with message broker (RabbitMQ, Kafka)
2. Replace direct database access with separate database
3. Replace module API calls with HTTP/gRPC clients + ACL
4. Deploy module as independent service

The Clean Architecture structure within each module makes this migration
straightforward — boundaries are already defined.
