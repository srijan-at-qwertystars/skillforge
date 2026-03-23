---
name: typescript-generics
description:
  positive: "Use when user writes TypeScript generics, asks about conditional types, mapped types, template literal types, infer keyword, type constraints, generic utility types, or type-level programming."
  negative: "Do NOT use for basic TypeScript setup (use typescript-strict-migration skill), Zod runtime validation (use zod-validation skill), or JavaScript without TypeScript types."
---

# TypeScript Advanced Generics & Type-Level Programming

## Generic Fundamentals

Declare type parameters with angle brackets. Constrain with `extends`. Provide defaults with `=`.

```typescript
// Single type parameter with default
type Container<T = unknown> = { value: T };

// Multiple type parameters with constraints
type Result<T, E extends Error = Error> =
  | { ok: true; data: T }
  | { ok: false; error: E };

// Constrained to objects with an id
function getById<T extends { id: string }>(items: T[], id: string): T | undefined {
  return items.find((item) => item.id === id);
}
```

## Generic Functions

Let TypeScript infer type arguments when possible. Use explicit arguments only when inference fails.

```typescript
// Inference works — no need to specify <number>
const doubled = [1, 2, 3].map((n) => n * 2);

// Explicit type argument when inference is ambiguous
function parseAs<T>(raw: string): T {
  return JSON.parse(raw) as T;
}
const config = parseAs<{ port: number }>(rawJson);

// Generic arrow function (JSX-safe with trailing comma)
const identity = <T,>(value: T): T => value;

// Multiple type params with relationship
function merge<T extends object, U extends object>(a: T, b: U): T & U {
  return { ...a, ...b };
}
```

## Generic Classes and Interfaces

```typescript
// Generic container with type-safe methods
class TypedMap<K extends string, V> {
  private store = new Map<K, V>();
  set(key: K, value: V): void { this.store.set(key, value); }
  get(key: K): V | undefined { return this.store.get(key); }
}

// Generic interface for factory pattern
interface Factory<T> {
  create(params: Partial<T>): T;
}

// Builder pattern with generic chaining
class QueryBuilder<T extends Record<string, unknown>> {
  private filters: Partial<T> = {};
  where<K extends keyof T>(key: K, value: T[K]): this {
    this.filters[key] = value;
    return this;
  }
  build(): Partial<T> { return { ...this.filters }; }
}
```

## Constraints and `keyof`

```typescript
// keyof constraint for property access
function pluck<T, K extends keyof T>(obj: T, keys: K[]): T[K][] {
  return keys.map((k) => obj[k]);
}

// Conditional constraint narrowing
type StringKeys<T> = {
  [K in keyof T]: T[K] extends string ? K : never;
}[keyof T];

// Constrain to types that have a .length
function longest<T extends { length: number }>(a: T, b: T): T {
  return a.length >= b.length ? a : b;
}
```

## Conditional Types

Use `T extends U ? X : Y` for type-level branching. Unions distribute by default.

```typescript
// Basic conditional
type IsString<T> = T extends string ? true : false;

// Distributive over unions: IsString<string | number> => true | false
type A = IsString<string | number>; // boolean (true | false)

// Prevent distribution with wrapping
type IsStringStrict<T> = [T] extends [string] ? true : false;
type B = IsStringStrict<string | number>; // false

// infer to extract types
type UnpackPromise<T> = T extends Promise<infer U> ? U : T;
type Data = UnpackPromise<Promise<string>>; // string

// Nested infer
type FirstArg<T> = T extends (first: infer A, ...rest: any[]) => any ? A : never;
type Arg = FirstArg<(name: string, age: number) => void>; // string
```

## Mapped Types

Iterate over keys with `in keyof`. Use `+`/`-` modifiers. Remap keys with `as`.

```typescript
// Make all properties nullable
type Nullable<T> = { [K in keyof T]: T[K] | null };

// Remove readonly
type Mutable<T> = { -readonly [K in keyof T]: T[K] };

// Remove optionality
type Concrete<T> = { [K in keyof T]-?: T[K] };

// Key remapping with as
type Getters<T> = {
  [K in keyof T as `get${Capitalize<string & K>}`]: () => T[K];
};

// Filter keys by value type
type OnlyStrings<T> = {
  [K in keyof T as T[K] extends string ? K : never]: T[K];
};
```

## Template Literal Types

Build types from string patterns. Use intrinsic string manipulation types.

```typescript
type EventName = "click" | "focus" | "blur";
type Handler = `on${Capitalize<EventName>}`; // "onClick" | "onFocus" | "onBlur"

// Pattern matching with infer
type ExtractRoute<T> = T extends `/${infer Segment}/${infer Rest}`
  ? Segment | ExtractRoute<`/${Rest}`>
  : T extends `/${infer Segment}`
    ? Segment
    : never;

type Segments = ExtractRoute<"/api/users/profile">; // "api" | "users" | "profile"

// Intrinsic string types: Uppercase, Lowercase, Capitalize, Uncapitalize
type Screaming<T extends string> = Uppercase<T>;
type Loud = Screaming<"hello">; // "HELLO"

// Dotted path keys
type DottedKeys<T, Prefix extends string = ""> = T extends object
  ? { [K in keyof T & string]:
      | `${Prefix}${K}`
      | DottedKeys<T[K], `${Prefix}${K}.`>
    }[keyof T & string]
  : never;
```

## Utility Types Deep Dive

```typescript
// Partial<T> — all optional
// Required<T> — all required
// Readonly<T> — all readonly
// Pick<T, K> — subset of keys
// Omit<T, K> — exclude keys
// Record<K, V> — object with keys K and values V

// Extract / Exclude — operate on union members
type Numbers = Extract<string | number | boolean, number>; // number
type NoStrings = Exclude<string | number | boolean, string>; // number | boolean

// ReturnType / Parameters
type Fn = (a: string, b: number) => boolean;
type Ret = ReturnType<Fn>;     // boolean
type Params = Parameters<Fn>;  // [string, number]

// Awaited — unwrap Promise (recursive)
type Inner = Awaited<Promise<Promise<string>>>; // string
```

## Custom Utility Types

```typescript
// Deep partial — recursively make all properties optional
type DeepPartial<T> = T extends object
  ? { [K in keyof T]?: DeepPartial<T[K]> }
  : T;

// Deep readonly
type DeepReadonly<T> = T extends object
  ? { readonly [K in keyof T]: DeepReadonly<T[K]> }
  : T;

// Prettify — flatten intersections for readable hover info
type Prettify<T> = { [K in keyof T]: T[K] } & {};

// Strict omit — constrain keys to actual properties of T
type StrictOmit<T, K extends keyof T> = Omit<T, K>;

// Make specific keys required
type RequireKeys<T, K extends keyof T> = Prettify<
  Omit<T, K> & Required<Pick<T, K>>
>;
```

## Variadic Tuple Types

```typescript
// Spread in tuple types
type Concat<A extends unknown[], B extends unknown[]> = [...A, ...B];
type AB = Concat<[1, 2], [3, 4]>; // [1, 2, 3, 4]

// Labeled tuples for clarity
type Address = [street: string, city: string, zip: string];

// Typed function composition
function pipe<A, B, C>(f: (a: A) => B, g: (b: B) => C): (a: A) => C {
  return (a) => g(f(a));
}

// Infer rest params
type Tail<T extends unknown[]> = T extends [unknown, ...infer Rest] ? Rest : [];
type Head<T extends unknown[]> = T extends [infer H, ...unknown[]] ? H : never;
```

## Type Inference Patterns

```typescript
// Recursive type — JSON value
type JsonValue = string | number | boolean | null | JsonValue[] | { [k: string]: JsonValue };

// Branded types for nominal typing
type Brand<T, B extends string> = T & { readonly __brand: B };
type UserId = Brand<string, "UserId">;
type OrderId = Brand<string, "OrderId">;

function fetchUser(id: UserId): Promise<unknown> { /* ... */ return fetch(`/users/${id}`); }
const uid = "abc" as UserId;
// fetchUser("abc") — ERROR: string is not UserId
fetchUser(uid); // OK

// Type guard with infer
type Unbox<T> = T extends ReadonlyArray<infer U> ? U :
                T extends Set<infer U> ? U :
                T extends Map<any, infer U> ? U : T;
```

## Generic Patterns

```typescript
// Discriminated union with exhaustive switch
type Shape =
  | { kind: "circle"; radius: number }
  | { kind: "rect"; width: number; height: number };

function area(s: Shape): number {
  switch (s.kind) {
    case "circle": return Math.PI * s.radius ** 2;
    case "rect": return s.width * s.height;
    default: const _exhaustive: never = s; return _exhaustive;
  }
}

// Type-safe event emitter
type EventMap = { login: { userId: string }; logout: undefined };

class Emitter<E extends Record<string, unknown>> {
  private listeners = new Map<keyof E, Set<Function>>();

  on<K extends keyof E>(event: K, fn: (payload: E[K]) => void): void {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(fn);
  }

  emit<K extends keyof E>(event: K, ...[payload]: E[K] extends undefined ? [] : [E[K]]): void {
    this.listeners.get(event)?.forEach((fn) => fn(payload));
  }
}

// Factory with generic return
function createFactory<T>(defaults: T): Factory<T> {
  return { create: (params) => ({ ...defaults, ...params }) };
}
```

## `satisfies` Operator

Check a value conforms to a type without widening. Combine with `as const` for precision.

```typescript
// satisfies checks shape, preserves literal types
const routes = {
  home: "/",
  about: "/about",
  user: "/user/:id",
} satisfies Record<string, string>;

// routes.home is type "/" — not widened to string

// as const + satisfies — immutable AND validated
const config = {
  port: 3000,
  host: "localhost",
} as const satisfies { port: number; host: string };

// config.port is type 3000, config.host is type "localhost"
```

## Performance

- **Type instantiation limits**: TypeScript caps at ~50 depth for recursive types. Keep recursion shallow.
- **Simplify complex types**: Break large conditional/mapped types into smaller named aliases.
- **Avoid deep recursion**: Prefer iterative tuple manipulation over recursive when possible.
- **Use `Prettify<T>`**: Flatten intersections to improve IDE hover info without runtime cost.
- **Measure**: Use `tsc --generateTrace` to profile type-checking performance.

```typescript
// BAD: unbounded recursion
type DeepFlatten<T> = T extends Array<infer U> ? DeepFlatten<U> : T;

// BETTER: bounded with depth counter
type DeepFlattenN<T, D extends number[] = []> =
  D["length"] extends 10 ? T :
  T extends Array<infer U> ? DeepFlattenN<U, [...D, 0]> : T;
```

## Anti-Patterns

Avoid these common mistakes:

```typescript
// ❌ Over-generic — adds complexity without value
function bad<T>(x: T): T { return x; } // identity has no business logic

// ✅ Use generics only when relating inputs to outputs
function good<T extends HTMLElement>(el: T, cls: string): T {
  el.classList.add(cls);
  return el;
}

// ❌ any as escape hatch
function parse(data: any) { return data.foo.bar; }

// ✅ Use unknown + narrowing
function parse(data: unknown): string {
  if (typeof data === "object" && data !== null && "foo" in data) {
    return String((data as { foo: string }).foo);
  }
  throw new Error("Invalid data");
}

// ❌ Unnecessary type assertion
const el = document.getElementById("app") as HTMLDivElement;

// ✅ Narrow with type guard
const el = document.getElementById("app");
if (el instanceof HTMLDivElement) {
  el.style.color = "red";
}

// ❌ Redundant generic constraint
function f<T extends unknown>(x: T) {} // T extends unknown is always true

// ✅ Remove meaningless constraints
function f<T>(x: T) {}
```
