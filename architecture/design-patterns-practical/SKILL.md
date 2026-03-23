---
name: design-patterns-practical
description:
  positive: "Use when user asks about design patterns, asks about factory, strategy, observer, builder, adapter, decorator, repository, or when to apply which pattern in real code."
  negative: "Do NOT use for architecture patterns (microservices, event-driven — use dedicated skills), API design patterns, or database-specific patterns."
---

# Practical Software Design Patterns

Apply patterns to solve real problems. Never introduce a pattern without concrete justification.

## Creational Patterns

### Factory Method / Abstract Factory

Use when object creation is conditional, complex, or must be extensible without modifying callers.
Skip when a simple constructor call suffices.

- **Factory vs Constructor:** Use constructors for single-variant objects. Use factories when the concrete type depends on runtime data or you need to return an interface.
- **Factory vs DI Container:** Factories encode creation *logic* ("which processor for this country?"). DI containers wire dependencies at startup. Use both — the container injects the factory.

```typescript
interface Notifier { send(msg: string): void; }

class NotifierFactory {
  static create(channel: "email" | "sms" | "push"): Notifier {
    const map: Record<string, () => Notifier> = {
      email: () => new EmailNotifier(),
      sms: () => new SmsNotifier(),
      push: () => new PushNotifier(),
    };
    const fn = map[channel];
    if (!fn) throw new Error(`Unknown channel: ${channel}`);
    return fn();
  }
}
```

```python
# Abstract Factory — family of related objects
class UIFactory(Protocol):
    def create_button(self) -> Button: ...
    def create_modal(self) -> Modal: ...

class DarkThemeFactory:
    def create_button(self) -> Button: return DarkButton()
    def create_modal(self) -> Modal: return DarkModal()
```

### Builder

Use when an object has many optional parameters, requires step-by-step construction, or must be immutable.

- **Fluent builder:** Method chaining returning `this`.
- **Step builder:** Enforces required fields via type-narrowing interfaces.

```typescript
class HttpRequestBuilder {
  private url = ""; private method = "GET";
  private headers: Record<string, string> = {};
  private body?: string; private timeout?: number;

  setUrl(url: string) { this.url = url; return this; }
  setMethod(m: string) { this.method = m; return this; }
  addHeader(k: string, v: string) { this.headers[k] = v; return this; }
  setBody(b: string) { this.body = b; return this; }
  setTimeout(ms: number) { this.timeout = ms; return this; }

  build(): HttpRequest {
    if (!this.url) throw new Error("URL required");
    return new HttpRequest(this.url, this.method, this.headers, this.body, this.timeout);
  }
}

const req = new HttpRequestBuilder()
  .setUrl("https://api.example.com/users").setMethod("POST")
  .addHeader("Content-Type", "application/json")
  .setBody(JSON.stringify({ name: "Ada" })).build();
```

### Singleton

**Usually bad.** Creates hidden global state, hinders testing, couples consumers to a concrete instance.

**When acceptable:** Hardware resource handles, read-only config loaded once, logger instances.
**Preferred alternative:** Register as singleton in your DI container — consumers depend on an interface.

```python
# Module-level singleton (Python modules are cached)
_config: dict | None = None

def get_config() -> dict:
    global _config
    if _config is None:
        _config = json.loads(Path("config.json").read_text())
    return _config
```

## Structural Patterns

### Adapter

Use when integrating a third-party library or legacy system whose interface doesn't match your domain. Place adapters at system boundaries.

```typescript
interface PaymentGateway {
  charge(amount: number, currency: string): Promise<PaymentResult>;
}

class StripeAdapter implements PaymentGateway {
  constructor(private stripe: StripeClient) {}
  async charge(amount: number, currency: string): Promise<PaymentResult> {
    const intent = await this.stripe.paymentIntents.create({
      amount: Math.round(amount * 100), currency,
    });
    return { id: intent.id, status: intent.status === "succeeded" ? "ok" : "failed" };
  }
}
```

### Decorator

Use when adding behavior dynamically without subclassing. Compose multiple decorators for layered behavior.

**Python `@decorator` vs GoF Decorator:** Python decorators wrap functions (syntactic sugar). GoF Decorator wraps objects implementing the same interface. Both share composition; different levels.

```typescript
// Composable logger decorators
interface Logger { log(msg: string): void; }

class TimestampDecorator implements Logger {
  constructor(private inner: Logger) {}
  log(msg: string) { this.inner.log(`[${new Date().toISOString()}] ${msg}`); }
}

class PrefixDecorator implements Logger {
  constructor(private inner: Logger, private prefix: string) {}
  log(msg: string) { this.inner.log(`${this.prefix} ${msg}`); }
}

const logger = new PrefixDecorator(new TimestampDecorator(new ConsoleLogger()), "[APP]");
```

```python
import functools, time

def retry(max_attempts: int = 3, delay: float = 1.0):
    def decorator(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            for attempt in range(max_attempts):
                try:
                    return fn(*args, **kwargs)
                except Exception:
                    if attempt == max_attempts - 1: raise
                    time.sleep(delay * (2 ** attempt))
        return wrapper
    return decorator
```

### Facade

Use when a subsystem is complex and callers need a simplified entry point. API gateways and service classes are facades.

```python
class OrderFacade:
    def __init__(self, inventory: InventoryService, payment: PaymentService, shipping: ShippingService):
        self._inv, self._pay, self._ship = inventory, payment, shipping

    def place_order(self, user_id: str, items: list[CartItem]) -> OrderConfirmation:
        self._inv.reserve(items)
        receipt = self._pay.charge(user_id, sum(i.price for i in items))
        tracking = self._ship.schedule(user_id, items)
        return OrderConfirmation(receipt=receipt, tracking=tracking)
```

### Proxy

Use for lazy loading, caching, access control, or logging — transparent interception.

```typescript
class CachingUserRepo implements UserRepository {
  private cache = new Map<string, User>();
  constructor(private repo: UserRepository) {}

  async findById(id: string): Promise<User | null> {
    if (this.cache.has(id)) return this.cache.get(id)!;
    const user = await this.repo.findById(id);
    if (user) this.cache.set(id, user);
    return user;
  }
}
```

## Behavioral Patterns

### Strategy

Use when swapping algorithms at runtime. Eliminates switch/case blocks. In modern languages, a strategy is often just a function parameter.

```typescript
type PricingStrategy = (base: number, qty: number) => number;

const standard: PricingStrategy = (base, qty) => base * qty;
const bulk: PricingStrategy = (base, qty) => base * qty * (qty > 100 ? 0.8 : 1);
const member: PricingStrategy = (base, qty) => base * qty * 0.9;

function total(items: CartItem[], strategy: PricingStrategy): number {
  return items.reduce((sum, i) => sum + strategy(i.price, i.qty), 0);
}
```

```python
# Config-driven strategy
STRATEGIES: dict[str, Callable[[float], float]] = {
    "flat": lambda amount: 5.0,
    "percentage": lambda amount: amount * 0.02,
    "free": lambda _: 0.0,
}

def calc_shipping(amount: float, method: str) -> float:
    strategy = STRATEGIES.get(method)
    if not strategy: raise ValueError(f"Unknown method: {method}")
    return strategy(amount)
```

### Observer

Use for one-to-many dependency — changes in one object notify multiple dependents. Implementations: EventEmitter, RxJS, `blinker`.

Avoid when <3 observers that rarely change — direct calls are simpler. Watch for cascading update chains.

```typescript
type EventMap = {
  userCreated: { userId: string; email: string };
  orderPlaced: { orderId: string; total: number };
};

class TypedEmitter<T extends Record<string, any>> {
  private listeners = new Map<keyof T, Set<(data: any) => void>>();

  on<K extends keyof T>(event: K, handler: (data: T[K]) => void) {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(handler);
    return () => this.listeners.get(event)!.delete(handler);
  }

  emit<K extends keyof T>(event: K, data: T[K]) {
    this.listeners.get(event)?.forEach((fn) => fn(data));
  }
}
```

### Command

Use for undo/redo, task queues, audit logs, deferred execution. CQRS connection: commands represent the write side — named intents with validation.

```python
from abc import ABC, abstractmethod

class Command(ABC):
    @abstractmethod
    def execute(self) -> None: ...
    @abstractmethod
    def undo(self) -> None: ...

class MoveCommand(Command):
    def __init__(self, entity: Entity, dx: int, dy: int):
        self.entity, self.dx, self.dy = entity, dx, dy
    def execute(self): self.entity.x += self.dx; self.entity.y += self.dy
    def undo(self): self.entity.x -= self.dx; self.entity.y -= self.dy

class CommandHistory:
    def __init__(self): self._history: list[Command] = []
    def execute(self, cmd: Command): cmd.execute(); self._history.append(cmd)
    def undo(self):
        if self._history: self._history.pop().undo()
```

### Chain of Responsibility

Use when a request passes through a series of handlers. Real-world: Express middleware, Django middleware, validation pipelines.

```typescript
type Validator<T> = (data: T) => string | null; // null = pass

function validate<T>(data: T, validators: Validator<T>[]): string | null {
  for (const v of validators) {
    const err = v(data);
    if (err) return err;
  }
  return null;
}

const userValidators: Validator<CreateUserInput>[] = [
  (d) => (!d.email ? "Email required" : null),
  (d) => (!d.email.includes("@") ? "Invalid email" : null),
  (d) => (d.password.length < 8 ? "Password too short" : null),
];
```

### State

Use when object behavior changes with internal state. Eliminates if/else sprawl on state. XState formalizes this for complex UI flows.

```python
from enum import Enum, auto

class OrderStatus(Enum):
    PENDING = auto(); PAID = auto(); SHIPPED = auto()
    DELIVERED = auto(); CANCELLED = auto()

TRANSITIONS: dict[OrderStatus, dict[str, OrderStatus]] = {
    OrderStatus.PENDING:  {"pay": OrderStatus.PAID, "cancel": OrderStatus.CANCELLED},
    OrderStatus.PAID:     {"ship": OrderStatus.SHIPPED, "cancel": OrderStatus.CANCELLED},
    OrderStatus.SHIPPED:  {"deliver": OrderStatus.DELIVERED},
    OrderStatus.DELIVERED: {}, OrderStatus.CANCELLED: {},
}

class Order:
    def __init__(self, order_id: str):
        self.id, self.status = order_id, OrderStatus.PENDING

    def transition(self, action: str) -> None:
        next_s = TRANSITIONS.get(self.status, {}).get(action)
        if next_s is None: raise ValueError(f"Cannot '{action}' from {self.status.name}")
        self.status = next_s
```

## Modern / Functional Patterns

### Repository

Decouple domain logic from data access. Expose collection-like semantics; swap implementations for testing.

```typescript
interface UserRepository {
  findById(id: string): Promise<User | null>;
  save(user: User): Promise<void>;
  delete(id: string): Promise<void>;
}

class PostgresUserRepo implements UserRepository { /* SQL queries */ }
class InMemoryUserRepo implements UserRepository {
  private users = new Map<string, User>();
  async findById(id: string) { return this.users.get(id) ?? null; }
  async save(user: User) { this.users.set(user.id, user); }
  async delete(id: string) { this.users.delete(id); }
}
```

### Result / Option

Make failure explicit in the type system. Chain operations without nested try/catch.

```typescript
type Result<T, E = Error> = { ok: true; value: T } | { ok: false; error: E };
function ok<T>(value: T): Result<T, never> { return { ok: true, value }; }
function err<E>(error: E): Result<never, E> { return { ok: false, error }; }

function parseAge(input: string): Result<number, string> {
  const n = parseInt(input, 10);
  if (isNaN(n)) return err("Not a number");
  if (n < 0 || n > 150) return err("Age out of range");
  return ok(n);
}
```

```python
from dataclasses import dataclass
from typing import Generic, TypeVar, Union
T = TypeVar("T"); E = TypeVar("E")

@dataclass
class Ok(Generic[T]): value: T
@dataclass
class Err(Generic[E]): error: E
Result = Union[Ok[T], Err[E]]

def parse_email(raw: str) -> Result[str, str]:
    if "@" not in raw: return Err("Invalid email")
    return Ok(raw.strip().lower())
```

### Specification

Compose business rules dynamically. Each specification encapsulates one rule; combine with `and`/`or`/`not`.

```typescript
interface Spec<T> { isSatisfiedBy(item: T): boolean; }

const and = <T>(...specs: Spec<T>[]): Spec<T> =>
  ({ isSatisfiedBy: (item) => specs.every((s) => s.isSatisfiedBy(item)) });
const or = <T>(...specs: Spec<T>[]): Spec<T> =>
  ({ isSatisfiedBy: (item) => specs.some((s) => s.isSatisfiedBy(item)) });
const not = <T>(spec: Spec<T>): Spec<T> =>
  ({ isSatisfiedBy: (item) => !spec.isSatisfiedBy(item) });

const isActive: Spec<User> = { isSatisfiedBy: (u) => u.status === "active" };
const isPremium: Spec<User> = { isSatisfiedBy: (u) => u.plan === "premium" };
const eligible = users.filter((u) => and(isActive, isPremium).isSatisfiedBy(u));
```

## Pattern Selection Guide

| Problem | Pattern | Why |
|---|---|---|
| Complex/conditional object creation | Factory | Decouple callers from concrete types |
| Many optional constructor params | Builder | Readable step-by-step construction |
| One shared resource | Singleton (via DI) | Controlled lifecycle, testable |
| Incompatible third-party interface | Adapter | Translate at the boundary |
| Add behavior without subclassing | Decorator | Composable stackable wrappers |
| Simplify complex subsystem | Facade | One entry point, hide internals |
| Lazy-load / cache / access control | Proxy | Transparent interception |
| Swap algorithms at runtime | Strategy | Functions or interface implementations |
| Notify multiple dependents | Observer | Loose coupling, event-driven |
| Undo/redo, deferred execution | Command | Encapsulate action as object |
| Request through handler chain | Chain of Responsibility | Middleware, validation pipeline |
| Behavior changes with state | State | Explicit transitions, no if/else |
| Decouple domain from data access | Repository | Swappable, testable |
| Make failure explicit in types | Result/Option | No hidden exceptions |
| Composable business rules | Specification | Dynamic filter/rule composition |

## Anti-Patterns: When Patterns Hurt

**Pattern for pattern's sake.** Factory that creates one class, observer with one listener, strategy that never changes. Fix: delete the pattern. Introduce it when a second variant appears.

**Premature abstraction.** Interface with one implementation and no test mock. Fix: write concrete code first. Extract interfaces when polymorphism or testability demands it.

**Speculative generality.** Plugin systems nobody uses, event hooks nobody subscribes to. Fix: follow YAGNI. Add extension points when a real requirement demands them.

**Singleton abuse.** Global mutable state, hidden dependencies, untestable. Fix: use dependency injection.

**God decorator.** 6+ stacked middleware layers with untraceable execution. Fix: limit depth to 4-5; redesign if exceeded.

> **Golden rule:** If removing the pattern makes the code simpler and you lose nothing, remove it. Patterns are tools, not goals.
