# TypeScript Type Narrowing Patterns

## Table of Contents

- [typeof Guards](#typeof-guards)
- [instanceof Checks](#instanceof-checks)
- [in Operator](#in-operator)
- [Discriminated Unions](#discriminated-unions)
- [Custom Type Guards (is/asserts)](#custom-type-guards-isasserts)
- [Truthiness Narrowing](#truthiness-narrowing)
- [Equality Narrowing](#equality-narrowing)
- [Control Flow Analysis Edge Cases](#control-flow-analysis-edge-cases)
- [Branded/Nominal Types](#brandednominal-types)
- [Template Literal Types for Validation](#template-literal-types-for-validation)
- [satisfies Operator](#satisfies-operator)
- [const Assertions](#const-assertions)

---

## typeof Guards

The `typeof` operator narrows to JavaScript primitive types. TypeScript recognizes these in `if`/`else`, ternary, and switch statements.

### Recognized typeof results

| `typeof x` | Narrows to |
|---|---|
| `"string"` | `string` |
| `"number"` | `number` |
| `"boolean"` | `boolean` |
| `"bigint"` | `bigint` |
| `"symbol"` | `symbol` |
| `"undefined"` | `undefined` |
| `"function"` | `Function` (or specific function type) |
| `"object"` | `object \| null` (**caveat: includes null**) |

### Basic narrowing

```ts
function format(value: string | number): string {
  if (typeof value === "string") {
    return value.toUpperCase(); // value: string
  }
  return value.toFixed(2); // value: number
}
```

### typeof with switch

```ts
function serialize(val: string | number | boolean | null): string {
  switch (typeof val) {
    case "string":  return `"${val}"`;          // val: string
    case "number":  return val.toString();       // val: number
    case "boolean": return val ? "true" : "false"; // val: boolean
    case "object":  return "null";               // val: null (typeof null === "object")
  }
}
```

### typeof "object" caveat

```ts
function process(val: object | null | string) {
  if (typeof val === "object") {
    // val: object | null — NOT narrowed to exclude null!
    // ❌ val.toString(); // Object is possibly null

    // ✅ Must add null check
    if (val !== null) {
      console.log(Object.keys(val)); // val: object
    }
  }
}
```

### typeof for undefined checks

```ts
// Preferred for checking optional parameters
function greet(name?: string) {
  if (typeof name === "undefined") {
    return "Hello, stranger";
  }
  return `Hello, ${name}`; // name: string
}

// Also works on global variables that may not be declared
if (typeof globalThis.MY_FLAG !== "undefined") {
  // MY_FLAG exists and is not undefined
}
```

### typeof with negation

```ts
function format(val: string | number | null) {
  if (typeof val !== "string") {
    // val: number | null (string excluded)
    if (typeof val !== "number") {
      // val: null
      return "N/A";
    }
    return val.toFixed(2); // val: number
  }
  return val.trim(); // val: string
}
```

---

## instanceof Checks

`instanceof` narrows to class instances and any constructor type. Works for built-in types (Date, RegExp, Error, Map, etc.) and user-defined classes.

### Basic instanceof

```ts
function formatDate(val: string | Date): string {
  if (val instanceof Date) {
    return val.toISOString(); // val: Date
  }
  return val; // val: string
}
```

### Error subclass narrowing

```ts
class NotFoundError extends Error {
  statusCode = 404;
  constructor(resource: string) {
    super(`${resource} not found`);
  }
}

class ValidationError extends Error {
  statusCode = 400;
  field: string;
  constructor(field: string, message: string) {
    super(message);
    this.field = field;
  }
}

function handleError(err: Error) {
  if (err instanceof NotFoundError) {
    return { status: err.statusCode, body: err.message }; // err: NotFoundError
  }
  if (err instanceof ValidationError) {
    return { status: err.statusCode, field: err.field }; // err: ValidationError
  }
  return { status: 500, body: "Internal error" };
}
```

### instanceof with arrays and built-ins

```ts
function getLength(val: string | string[] | Map<string, unknown>): number {
  if (val instanceof Array) {
    return val.length; // val: string[]
  }
  if (val instanceof Map) {
    return val.size; // val: Map<string, unknown>
  }
  return val.length; // val: string
}
```

### instanceof limitations

```ts
// ❌ instanceof does NOT work with interfaces or type aliases
interface Serializable { serialize(): string; }

function check(val: unknown) {
  if (val instanceof Serializable) {
    // Error: 'Serializable' only refers to a type, but is being used as a value
  }
}

// ✅ Use 'in' operator or custom type guard instead
function isSerializable(val: unknown): val is Serializable {
  return typeof val === "object" && val !== null && "serialize" in val;
}
```

```ts
// ❌ instanceof doesn't work across realms (iframes, Node vm modules)
// An object from another iframe won't be instanceof Array, even if it's an array
// ✅ Use Array.isArray() instead
function isArr(val: unknown): val is unknown[] {
  return Array.isArray(val);
}
```

---

## `in` Operator

The `in` operator checks if a property name exists on an object, narrowing the type to whichever union member contains that property.

### Basic in narrowing

```ts
interface Fish { swim: () => void; }
interface Bird { fly: () => void; }

function move(animal: Fish | Bird) {
  if ("swim" in animal) {
    animal.swim(); // animal: Fish
  } else {
    animal.fly(); // animal: Bird
  }
}
```

### in with shared properties

```ts
interface Circle { kind: "circle"; radius: number; }
interface Square { kind: "square"; side: number; }
interface Triangle { kind: "triangle"; base: number; height: number; }

type Shape = Circle | Square | Triangle;

function hasHeight(shape: Shape): shape is Triangle {
  return "height" in shape;
}

function describe(shape: Shape) {
  if ("radius" in shape) {
    console.log(`Circle with radius ${shape.radius}`); // shape: Circle
  } else if ("height" in shape) {
    console.log(`Triangle: base=${shape.base}`); // shape: Triangle
  } else {
    console.log(`Square: side=${shape.side}`); // shape: Square
  }
}
```

### in with unknown/any

```ts
function processResponse(data: unknown) {
  if (typeof data === "object" && data !== null) {
    if ("error" in data) {
      // data is narrowed to: object & Record<"error", unknown>
      console.log((data as { error: string }).error);
    }
    if ("result" in data) {
      console.log((data as { result: unknown }).result);
    }
  }
}
```

### in vs hasOwnProperty

```ts
// 'in' checks the prototype chain; hasOwnProperty checks own properties only
interface Base { id: number; }
interface Extended extends Base { extra: string; }

// For narrowing purposes, 'in' is preferred because TS understands it
function check(obj: Base | Extended) {
  if ("extra" in obj) {
    obj.extra; // ✅ narrowed to Extended
  }
}
```

---

## Discriminated Unions

A discriminated union has a common literal-type property (the "discriminant") that TypeScript uses to narrow the full union based on checking that property.

### Requirements for a discriminated union

1. Each member has a **common property** (the discriminant)
2. The discriminant has a **literal type** (string literal, number literal, boolean literal)
3. Each member's discriminant value is **unique**

### Basic pattern

```ts
type Result<T> =
  | { success: true; data: T }
  | { success: false; error: Error };

function handle(result: Result<string>) {
  if (result.success) {
    console.log(result.data); // result: { success: true; data: string }
  } else {
    console.error(result.error.message); // result: { success: false; error: Error }
  }
}
```

### Multi-member discriminated union

```ts
type Action =
  | { type: "SET_USER"; payload: { id: string; name: string } }
  | { type: "SET_LOADING"; payload: boolean }
  | { type: "SET_ERROR"; payload: string }
  | { type: "RESET" }; // no payload

function reducer(state: State, action: Action): State {
  switch (action.type) {
    case "SET_USER":
      return { ...state, user: action.payload }; // payload: { id, name }
    case "SET_LOADING":
      return { ...state, loading: action.payload }; // payload: boolean
    case "SET_ERROR":
      return { ...state, error: action.payload }; // payload: string
    case "RESET":
      return initialState; // no payload property
  }
}
```

### Exhaustive checking with never

```ts
type Shape =
  | { kind: "circle"; radius: number }
  | { kind: "square"; side: number }
  | { kind: "rectangle"; width: number; height: number };

function area(shape: Shape): number {
  switch (shape.kind) {
    case "circle":
      return Math.PI * shape.radius ** 2;
    case "square":
      return shape.side ** 2;
    case "rectangle":
      return shape.width * shape.height;
    default: {
      // If a new shape is added to the union but not handled here,
      // this line will produce a compile error
      const _exhaustive: never = shape;
      throw new Error(`Unhandled shape: ${JSON.stringify(_exhaustive)}`);
    }
  }
}
```

### Discriminated union with multiple discriminants

```ts
type Event =
  | { source: "mouse"; type: "click"; x: number; y: number }
  | { source: "mouse"; type: "move"; x: number; y: number; dx: number; dy: number }
  | { source: "keyboard"; type: "keydown"; key: string; code: number }
  | { source: "keyboard"; type: "keyup"; key: string; code: number };

function handle(event: Event) {
  if (event.source === "mouse") {
    // event: mouse click | mouse move
    if (event.type === "click") {
      console.log(`Clicked at ${event.x}, ${event.y}`);
    } else {
      console.log(`Moved by ${event.dx}, ${event.dy}`);
    }
  } else {
    // event: keyboard keydown | keyboard keyup
    console.log(`Key ${event.type}: ${event.key}`);
  }
}
```

### Extracting union members

```ts
type Action =
  | { type: "ADD"; item: string }
  | { type: "REMOVE"; id: number }
  | { type: "CLEAR" };

// Extract a specific member
type AddAction = Extract<Action, { type: "ADD" }>;
// { type: "ADD"; item: string }

// Exclude a specific member
type NonClearAction = Exclude<Action, { type: "CLEAR" }>;
// { type: "ADD"; item: string } | { type: "REMOVE"; id: number }
```

---

## Custom Type Guards (is/asserts)

Custom type guards let you define your own narrowing logic that TypeScript's control flow analysis can't infer automatically.

### Type predicate functions (is)

```ts
// Return type is `val is T` — narrows the input in the calling scope
function isString(val: unknown): val is string {
  return typeof val === "string";
}

function process(input: unknown) {
  if (isString(input)) {
    console.log(input.toUpperCase()); // input: string
  }
}
```

### Complex type guard

```ts
interface User {
  id: string;
  name: string;
  email: string;
}

function isUser(val: unknown): val is User {
  return (
    typeof val === "object" &&
    val !== null &&
    typeof (val as Record<string, unknown>).id === "string" &&
    typeof (val as Record<string, unknown>).name === "string" &&
    typeof (val as Record<string, unknown>).email === "string"
  );
}

// Usage with API response
async function fetchUser(id: string): Promise<User> {
  const data: unknown = await fetch(`/api/users/${id}`).then(r => r.json());
  if (!isUser(data)) throw new Error("Invalid user response");
  return data; // data: User
}
```

### Type guard for arrays

```ts
function isStringArray(val: unknown): val is string[] {
  return Array.isArray(val) && val.every(item => typeof item === "string");
}

function isNonEmpty<T>(arr: T[]): arr is [T, ...T[]] {
  return arr.length > 0;
}

const items: string[] = getItems();
if (isNonEmpty(items)) {
  const first: string = items[0]; // guaranteed to exist
}
```

### Assertion functions (asserts)

```ts
// Assertion functions throw if the condition is false.
// After the call, TypeScript narrows the type.

function assertDefined<T>(val: T | null | undefined, msg?: string): asserts val is T {
  if (val == null) throw new Error(msg ?? "Value is null or undefined");
}

function assertIsString(val: unknown): asserts val is string {
  if (typeof val !== "string") throw new TypeError(`Expected string, got ${typeof val}`);
}

// Usage
const el = document.getElementById("app");
assertDefined(el, "Missing #app element");
el.textContent = "Ready"; // el: HTMLElement (no null)

function handleInput(val: unknown) {
  assertIsString(val);
  console.log(val.toUpperCase()); // val: string
}
```

### Assertion with condition parameter

```ts
function assert(condition: unknown, msg?: string): asserts condition {
  if (!condition) throw new Error(msg ?? "Assertion failed");
}

function processOrder(order: Order | null) {
  assert(order !== null, "Order is required");
  // order: Order (null eliminated)
  console.log(order.id);
}
```

### Type guard for discriminated unions

```ts
type ApiResponse =
  | { status: "success"; data: unknown }
  | { status: "error"; message: string };

function isSuccess(res: ApiResponse): res is Extract<ApiResponse, { status: "success" }> {
  return res.status === "success";
}

function handle(res: ApiResponse) {
  if (isSuccess(res)) {
    console.log(res.data); // res: { status: "success"; data: unknown }
  } else {
    console.error(res.message); // res: { status: "error"; message: string }
  }
}
```

### Type guard pitfalls

```ts
// ❌ DANGER: Type guards can LIE. TypeScript trusts your implementation.
function isNumber(val: unknown): val is number {
  return true; // Always returns true — TypeScript doesn't verify correctness
}

const x: unknown = "hello";
if (isNumber(x)) {
  x.toFixed(2); // TypeScript thinks x is number — runtime crash!
}

// ✅ Always ensure the guard actually validates the type
```

---

## Truthiness Narrowing

TypeScript narrows types based on truthiness checks (`if (x)`, `!!x`, `Boolean(x)`). It eliminates `null`, `undefined`, `0`, `""`, `false`, `NaN` from the type.

### Basic truthiness narrowing

```ts
function greet(name: string | null | undefined) {
  if (name) {
    console.log(name.toUpperCase()); // name: string (null & undefined excluded)
  }
}
```

### Truthiness pitfalls

```ts
// ❌ PITFALL: Truthiness eliminates 0, "", and false too!
function printCount(count: number | null) {
  if (count) {
    console.log(`Count: ${count}`); // Misses count === 0!
  }
}

// ✅ Fix: Check explicitly for null/undefined
function printCount(count: number | null) {
  if (count !== null) {
    console.log(`Count: ${count}`); // Includes 0
  }
}

// ✅ Or use nullish coalescing
function printCount(count: number | null) {
  console.log(`Count: ${count ?? "N/A"}`);
}
```

```ts
// ❌ PITFALL: Empty string is falsy
function display(text: string | undefined) {
  if (text) {
    return text.trim(); // Misses empty string ""
  }
  return "default";
}

// ✅ Fix: Check for undefined explicitly
function display(text: string | undefined) {
  if (text !== undefined) {
    return text.trim(); // Includes ""
  }
  return "default";
}
```

### Double negation and Boolean()

```ts
function process(items: string[] | null) {
  // All three are equivalent for narrowing:
  if (items) { /* items: string[] */ }
  if (!!items) { /* items: string[] */ }
  if (Boolean(items)) { /* items: string[] — only in TS 5.5+ */ }
}
```

### Truthiness with optional chaining

```ts
interface Config {
  features?: {
    darkMode?: boolean;
    beta?: {
      enabled?: boolean;
    };
  };
}

function isDarkMode(config: Config): boolean {
  // Optional chain returns undefined if any link is missing
  // Truthiness narrows undefined out
  if (config.features?.darkMode) {
    return true; // We know features exists and darkMode is true
  }
  return false;
}
```

### Narrowing with logical operators

```ts
function format(val: string | null | undefined): string {
  // && narrows left side, returns right if left is truthy
  return val && val.trim() || "empty";
  // But this has the "" pitfall too

  // ✅ Better:
  return val != null ? val.trim() : "empty";
}
```

---

## Equality Narrowing

TypeScript narrows types when you compare values with `===`, `!==`, `==`, `!=`.

### Strict equality (===)

```ts
function process(val: string | number | null) {
  if (val === null) {
    return; // val: null
  }
  // val: string | number (null eliminated)

  if (val === "special") {
    return val.toUpperCase(); // val: "special" (literal type)
  }
}
```

### Loose equality (==) for null/undefined

```ts
function clean(val: string | null | undefined) {
  // == null catches BOTH null and undefined
  if (val == null) {
    return ""; // val: null | undefined
  }
  return val.trim(); // val: string
}

// This is one of the few cases where == is idiomatic in strict TypeScript
```

### Equality between variables

```ts
function compare(a: string | number, b: string | boolean) {
  if (a === b) {
    // a and b must be the common type: string
    console.log(a.toUpperCase()); // a: string
    console.log(b.toUpperCase()); // b: string
  }
}
```

### Switch with literal types

```ts
type Status = "idle" | "loading" | "success" | "error";

function getColor(status: Status): string {
  switch (status) {
    case "idle":    return "gray";    // status: "idle"
    case "loading": return "blue";    // status: "loading"
    case "success": return "green";   // status: "success"
    case "error":   return "red";     // status: "error"
  }
}
```

### Comparing against constants

```ts
const ADMIN_ROLE = "admin" as const;
const USER_ROLE = "user" as const;

type Role = typeof ADMIN_ROLE | typeof USER_ROLE;

function checkPermission(role: Role) {
  if (role === ADMIN_ROLE) {
    // role: "admin"
    grantFullAccess();
  }
}
```

---

## Control Flow Analysis Edge Cases

TypeScript's control flow analysis (CFA) tracks type narrowing through branches, assignments, and returns. But it has limitations.

### Narrowing doesn't survive callbacks

```ts
function process(val: string | null) {
  if (val !== null) {
    // val: string ✅
    setTimeout(() => {
      // val: string | null ❌ — CFA can't guarantee val hasn't changed
      // (even though it can't in this case)
      console.log(val.toUpperCase()); // Error with strictNullChecks
    }, 100);
  }
}

// ✅ Fix A: Capture in a const
function process(val: string | null) {
  if (val !== null) {
    const confirmed: string = val; // captured as string
    setTimeout(() => {
      console.log(confirmed.toUpperCase()); // ✅
    }, 100);
  }
}

// ✅ Fix B: Use const parameter (if applicable)
function process(val: string | null) {
  if (val === null) return;
  // val is string from here, but still lost in callbacks
  const safeVal = val;
  setTimeout(() => console.log(safeVal.toUpperCase()), 100);
}
```

### Narrowing doesn't survive reassignment

```ts
let val: string | number = "hello";
// val: string

val = 42;
// val: number

if (typeof val === "string") {
  // val: string (re-narrowed)
}
```

### Narrowing with mutable object properties

```ts
interface State {
  status: "idle" | "loading" | "done";
  data?: string;
}

const state: State = { status: "idle" };

function check() {
  state.status = "done";
  state.data = "result";

  if (state.status === "done") {
    // state.data: string | undefined — TS doesn't link status to data
    // Even though we just set both
  }
}

// ✅ Fix: Use discriminated unions with a single object
type State =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "done"; data: string };
```

### Narrowing in loops

```ts
// TS re-evaluates types at loop entry points
function findFirst(items: (string | number)[]): string | undefined {
  for (const item of items) {
    if (typeof item === "string") {
      return item; // item: string ✅
    }
  }
  return undefined;
}
```

### Narrowing with destructuring

```ts
type Result = { ok: true; value: string } | { ok: false; error: Error };

function process(result: Result) {
  const { ok } = result;
  if (ok) {
    // ❌ result is NOT narrowed by destructured 'ok'
    // console.log(result.value); // Error

    // ✅ Fix: Check on the original object
  }

  if (result.ok) {
    console.log(result.value); // ✅ Works
  }
}
```

### Narrowing across function boundaries

```ts
// TS does NOT narrow based on function calls (unless they are type guards)
function isValid(val: string | null): boolean {
  return val !== null;
}

function process(val: string | null) {
  if (isValid(val)) {
    // val: string | null — NOT narrowed!
    // TS doesn't trace into isValid's implementation
  }
}

// ✅ Fix: Make it a type guard
function isValid(val: string | null): val is string {
  return val !== null;
}
```

### Never type and dead code detection

```ts
function fail(msg: string): never {
  throw new Error(msg);
}

function process(val: "a" | "b") {
  switch (val) {
    case "a": return 1;
    case "b": return 2;
    default:
      fail(`Unexpected: ${val}`); // val: never
      // Code after this is unreachable — TS knows fail() returns never
  }
}
```

---

## Branded/Nominal Types

TypeScript uses **structural typing** — two types with the same shape are interchangeable. Branded types add a phantom property to create distinct types that are structurally incompatible.

### Basic branded type

```ts
type UserId = string & { readonly __brand: "UserId" };
type OrderId = string & { readonly __brand: "OrderId" };

// Constructor functions
function UserId(id: string): UserId { return id as UserId; }
function OrderId(id: string): OrderId { return id as OrderId; }

// ❌ Can't mix up IDs
function getUser(id: UserId) { /* ... */ }
function getOrder(id: OrderId) { /* ... */ }

const userId = UserId("u-123");
const orderId = OrderId("o-456");

getUser(userId);   // ✅
getUser(orderId);  // ❌ Error: OrderId is not assignable to UserId
getUser("u-123");  // ❌ Error: string is not assignable to UserId
```

### Branded type with validation

```ts
type Email = string & { readonly __brand: "Email" };
type PositiveInt = number & { readonly __brand: "PositiveInt" };

function Email(value: string): Email {
  if (!/^[^@]+@[^@]+\.[^@]+$/.test(value)) {
    throw new Error(`Invalid email: ${value}`);
  }
  return value as Email;
}

function PositiveInt(value: number): PositiveInt {
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`Not a positive integer: ${value}`);
  }
  return value as PositiveInt;
}

// Use in domain models
interface User {
  id: UserId;
  email: Email;
  age: PositiveInt;
}
```

### Brand narrowing with type guards

```ts
type ValidatedInput = string & { readonly __brand: "ValidatedInput" };

function isValidInput(input: string): input is ValidatedInput {
  return input.length > 0 && input.length <= 255 && !input.includes("<script>");
}

function processInput(raw: string) {
  if (isValidInput(raw)) {
    saveToDb(raw); // raw: ValidatedInput — proven safe
  }
}

function saveToDb(input: ValidatedInput) {
  // Only accepts validated input
}
```

### Generic branded type utility

```ts
declare const __brand: unique symbol;

type Brand<T, B extends string> = T & { readonly [__brand]: B };

type USD = Brand<number, "USD">;
type EUR = Brand<number, "EUR">;
type Kg = Brand<number, "Kg">;
type Meters = Brand<number, "Meters">;

function usd(amount: number): USD { return amount as USD; }
function eur(amount: number): EUR { return amount as EUR; }

function addUSD(a: USD, b: USD): USD {
  return (a + b) as USD;
}

const price = usd(10);
const tax = usd(2);
const cost = eur(5);

addUSD(price, tax);  // ✅
addUSD(price, cost); // ❌ Error: EUR not assignable to USD
addUSD(price, 3);    // ❌ Error: number not assignable to USD
```

---

## Template Literal Types for Validation

Template literal types create types from string patterns, enabling compile-time validation of string formats.

### Basic template literal types

```ts
type EventName = `on${Capitalize<string>}`;
// Matches: "onClick", "onHover", "onSubmit", etc.

type CssUnit = `${number}${"px" | "em" | "rem" | "%"}`;
// Matches: "16px", "1.5em", "100%", etc.

type HexColor = `#${string}`;
// Matches: "#fff", "#ff0000", etc.
```

### Type-safe event emitter

```ts
type EventMap = {
  click: { x: number; y: number };
  keydown: { key: string; code: number };
  resize: { width: number; height: number };
};

type EventCallback<K extends keyof EventMap> = (data: EventMap[K]) => void;

class TypedEmitter {
  private listeners: Partial<{
    [K in keyof EventMap]: EventCallback<K>[];
  }> = {};

  on<K extends keyof EventMap>(event: K, callback: EventCallback<K>) {
    const list = this.listeners[event] ?? [];
    (list as EventCallback<K>[]).push(callback);
    this.listeners[event] = list as any;
  }

  emit<K extends keyof EventMap>(event: K, data: EventMap[K]) {
    this.listeners[event]?.forEach(cb => (cb as EventCallback<K>)(data));
  }
}

const emitter = new TypedEmitter();
emitter.on("click", (data) => console.log(data.x)); // ✅ data: { x, y }
emitter.on("click", (data) => console.log(data.key)); // ❌ Property 'key' does not exist
```

### Path parameter extraction

```ts
type ExtractParams<T extends string> =
  T extends `${infer _Start}:${infer Param}/${infer Rest}`
    ? Param | ExtractParams<`/${Rest}`>
    : T extends `${infer _Start}:${infer Param}`
      ? Param
      : never;

type Params = ExtractParams<"/users/:userId/posts/:postId">;
// "userId" | "postId"

function createRoute<T extends string>(
  path: T,
  handler: (params: Record<ExtractParams<T>, string>) => void
) {
  // ...
}

createRoute("/users/:userId/posts/:postId", (params) => {
  params.userId; // ✅ string
  params.postId; // ✅ string
  params.other;  // ❌ Error
});
```

### String validation types

```ts
type Uppercase<S extends string> = intrinsic;
type Lowercase<S extends string> = intrinsic;
type Capitalize<S extends string> = intrinsic;
type Uncapitalize<S extends string> = intrinsic;

// Enforce snake_case keys
type SnakeCaseKey = `${Lowercase<string>}_${Lowercase<string>}`;
type Config = Record<SnakeCaseKey, unknown>;

// Enforce environment variable naming
type EnvVar = `${Uppercase<string>}_${Uppercase<string>}`;
```

### Dot-notation path types

```ts
type NestedPaths<T, Prefix extends string = ""> = T extends object
  ? {
      [K in keyof T & string]: T[K] extends object
        ? `${Prefix}${K}` | NestedPaths<T[K], `${Prefix}${K}.`>
        : `${Prefix}${K}`;
    }[keyof T & string]
  : never;

interface AppConfig {
  db: { host: string; port: number };
  cache: { ttl: number };
}

type ConfigPath = NestedPaths<AppConfig>;
// "db" | "db.host" | "db.port" | "cache" | "cache.ttl"

function getConfig(path: ConfigPath): unknown {
  // Type-safe config access by dot notation
  return path;
}

getConfig("db.host"); // ✅
getConfig("db.foo");  // ❌ Error
```

---

## `satisfies` Operator

The `satisfies` operator (TypeScript 4.9+) validates that an expression matches a type **without widening** the inferred type. It provides type checking at assignment while preserving the most specific type.

### satisfies vs type annotation

```ts
// Type annotation: WIDENS to the annotation type
const colors: Record<string, string | number[]> = {
  red: "#ff0000",
  green: [0, 255, 0],
};
colors.red.toUpperCase(); // ❌ Error: Property 'toUpperCase' does not exist on string | number[]

// satisfies: CHECKS the type but PRESERVES the inferred type
const colors = {
  red: "#ff0000",
  green: [0, 255, 0],
} satisfies Record<string, string | number[]>;

colors.red.toUpperCase();  // ✅ TypeScript knows red is string
colors.green.map(x => x);  // ✅ TypeScript knows green is number[]
```

### Catching typos in config objects

```ts
type Route = {
  path: string;
  method: "GET" | "POST" | "PUT" | "DELETE";
};

// Without satisfies: typos in method are not caught until runtime
const routes = {
  getUser: { path: "/user", method: "GET" },
  createUser: { path: "/user", method: "POSTT" }, // typo!
};

// With satisfies: caught at compile time
const routes = {
  getUser: { path: "/user", method: "GET" },
  createUser: { path: "/user", method: "POSTT" }, // ❌ Error: "POSTT" not assignable
} satisfies Record<string, Route>;

// AND you still get specific types:
routes.getUser.method; // type: "GET" (not "GET" | "POST" | "PUT" | "DELETE")
```

### satisfies with as const

```ts
// Combining satisfies with as const for maximum type safety
const PERMISSIONS = {
  admin: ["read", "write", "delete"],
  viewer: ["read"],
} as const satisfies Record<string, readonly string[]>;

// Type of PERMISSIONS.admin: readonly ["read", "write", "delete"]
// Type of PERMISSIONS.viewer: readonly ["read"]
// Keys are validated against Record<string, readonly string[]>
```

### satisfies for exhaustive checking

```ts
type ColorConfig = Record<"primary" | "secondary" | "accent", string>;

// ❌ Missing "accent" — caught by satisfies
const theme = {
  primary: "#007bff",
  secondary: "#6c757d",
} satisfies ColorConfig;

// ✅ All required keys present
const theme = {
  primary: "#007bff",
  secondary: "#6c757d",
  accent: "#28a745",
} satisfies ColorConfig;
```

### satisfies with union narrowing

```ts
type Value = string | number | boolean;
type Config = Record<string, Value>;

const config = {
  name: "app",
  port: 3000,
  debug: true,
  host: "localhost",
} satisfies Config;

// Each property retains its literal type:
config.name;  // type: string (not string | number | boolean)
config.port;  // type: number
config.debug; // type: boolean
```

---

## `const` Assertions

`as const` makes TypeScript infer the **narrowest possible type** — literal types, readonly arrays, and readonly properties.

### Without vs with const assertion

```ts
// Without as const
const config = {
  endpoint: "/api",
  retries: 3,
  methods: ["GET", "POST"],
};
// Type: { endpoint: string; retries: number; methods: string[] }

// With as const
const config = {
  endpoint: "/api",
  retries: 3,
  methods: ["GET", "POST"],
} as const;
// Type: {
//   readonly endpoint: "/api";
//   readonly retries: 3;
//   readonly methods: readonly ["GET", "POST"];
// }
```

### Literal string/number types

```ts
// Without as const
const direction = "north"; // type: string

// With as const
const direction = "north" as const; // type: "north"

// Useful for function parameters expecting literals
function move(dir: "north" | "south" | "east" | "west") { /* ... */ }
move(direction); // ✅ Works because direction is "north", not string
```

### Enum-like patterns with const assertions

```ts
const Status = {
  Pending: "PENDING",
  Active: "ACTIVE",
  Closed: "CLOSED",
} as const;

type Status = (typeof Status)[keyof typeof Status];
// "PENDING" | "ACTIVE" | "CLOSED"

function setStatus(s: Status) { /* ... */ }
setStatus(Status.Active);  // ✅
setStatus("ACTIVE");       // ✅
setStatus("INVALID");      // ❌ Error
```

### Readonly tuples

```ts
// Without as const: number[] (mutable, element type is number)
const point = [10, 20];

// With as const: readonly [10, 20] (immutable tuple with literal types)
const point = [10, 20] as const;

// Useful for function args that expect tuples
function translate(coords: readonly [number, number]) {
  const [x, y] = coords;
  return [x + 1, y + 1] as const;
}

translate(point); // ✅
```

### const assertion with satisfies

```ts
// Best of both worlds: validated AND maximally narrow
const ROUTES = {
  home: { path: "/", method: "GET" },
  login: { path: "/login", method: "POST" },
  logout: { path: "/logout", method: "POST" },
} as const satisfies Record<string, { path: string; method: "GET" | "POST" }>;

// ROUTES.home.method is "GET" (literal), not "GET" | "POST" (union)
// All routes are validated to have path and valid method
```

### const type parameters (TypeScript 5.0+)

```ts
// Without const type parameter: T inferred as string[]
function createList<T extends readonly string[]>(items: T): T {
  return items;
}
const list = createList(["a", "b", "c"]); // string[]

// With const type parameter: T inferred as readonly ["a", "b", "c"]
function createList<const T extends readonly string[]>(items: T): T {
  return items;
}
const list = createList(["a", "b", "c"]); // readonly ["a", "b", "c"]
```

### const assertion limitations

```ts
// ❌ as const doesn't work on mutable expressions
let x = "hello" as const; // x is still type "hello" but can be reassigned
x = "world"; // ❌ Error: "world" is not assignable to "hello"
// This is usually what you want, but be aware

// ❌ as const on a class instance doesn't deeply freeze
const user = new User("Alice") as const;
// Still User type — as const only affects object/array literals

// ❌ as const doesn't validate — it just narrows
const bad = { port: "not-a-number" } as const;
// Type: { readonly port: "not-a-number" } — no error
// Use satisfies for validation
```

### Deriving types from const objects

```ts
const HTTP_METHODS = ["GET", "POST", "PUT", "DELETE", "PATCH"] as const;
type HttpMethod = (typeof HTTP_METHODS)[number];
// "GET" | "POST" | "PUT" | "DELETE" | "PATCH"

const ERROR_CODES = {
  NOT_FOUND: 404,
  UNAUTHORIZED: 401,
  FORBIDDEN: 403,
  SERVER_ERROR: 500,
} as const;

type ErrorCode = (typeof ERROR_CODES)[keyof typeof ERROR_CODES];
// 404 | 401 | 403 | 500

type ErrorName = keyof typeof ERROR_CODES;
// "NOT_FOUND" | "UNAUTHORIZED" | "FORBIDDEN" | "SERVER_ERROR"
```
