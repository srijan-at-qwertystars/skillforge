# TypeScript Strict Flags Deep Dive

## Table of Contents

- [strict (Umbrella Flag)](#strict-umbrella-flag)
- [strictNullChecks](#strictnullchecks)
- [noImplicitAny](#noimplicitany)
- [strictFunctionTypes](#strictfunctiontypes)
- [strictBindCallApply](#strictbindcallapply)
- [strictPropertyInitialization](#strictpropertyinitialization)
- [noImplicitThis](#noimplicitthis)
- [useUnknownInCatchVariables](#useunknownincatchvariables)
- [noUncheckedIndexedAccess](#nouncheckedindexedaccess)
- [exactOptionalPropertyTypes](#exactoptionalpropertytypes)
- [noImplicitReturns](#noimplicitreturns)
- [noFallthroughCasesInSwitch](#nofallthroughcasesinswitch)
- [noImplicitOverride](#noimplicitoverride)

---

## `strict` (Umbrella Flag)

`"strict": true` enables all strict-family flags as a single switch. As of TypeScript 5.x it activates:

| Flag | Effect |
|---|---|
| `strictNullChecks` | `null`/`undefined` are distinct types |
| `noImplicitAny` | Error on inferred `any` |
| `strictFunctionTypes` | Contravariant parameter checks |
| `strictBindCallApply` | Typed `bind`/`call`/`apply` |
| `strictPropertyInitialization` | Class properties must be initialized |
| `noImplicitThis` | Error on `this` typed as `any` |
| `alwaysStrict` | Emit `"use strict"` in all files |
| `useUnknownInCatchVariables` | `catch(e)` types `e` as `unknown` |

Flags **not** included in `strict` but recommended alongside it:

- `noUncheckedIndexedAccess`
- `exactOptionalPropertyTypes`
- `noImplicitReturns`
- `noFallthroughCasesInSwitch`
- `noImplicitOverride`

Setting `"strict": true` then overriding individual flags still works:

```jsonc
{
  "compilerOptions": {
    "strict": true,
    "strictNullChecks": false // override just this one
  }
}
```

**Migration tip**: Start with `"strict": false` and enable flags one at a time. When all are `true`, replace them with `"strict": true`.

---

## `strictNullChecks`

**What it catches**: Every place where `null` or `undefined` can flow into a non-nullable position. Without this flag, `null` and `undefined` are assignable to every type, hiding a massive class of runtime `TypeError`s.

### Error Pattern 1: Nullable return values

```ts
// ❌ Error: Object is possibly 'null'
const el = document.getElementById("root");
el.textContent = "Hello";

// ✅ Fix A: Null guard
const el = document.getElementById("root");
if (el) {
  el.textContent = "Hello";
}

// ✅ Fix B: Non-null assertion (use only when guaranteed by context)
const el = document.getElementById("root")!;
el.textContent = "Hello";

// ✅ Fix C: Early return
function init() {
  const el = document.getElementById("root");
  if (!el) throw new Error("Missing #root element");
  el.textContent = "Hello"; // el: HTMLElement
}
```

### Error Pattern 2: Optional properties

```ts
interface User {
  name: string;
  email?: string;
}

// ❌ Error: Object is possibly 'undefined'
function sendEmail(user: User) {
  sendTo(user.email.toLowerCase());
}

// ✅ Fix: Guard or default
function sendEmail(user: User) {
  if (!user.email) return;
  sendTo(user.email.toLowerCase()); // email: string
}
```

### Error Pattern 3: Array.find returns T | undefined

```ts
const users: User[] = [{ name: "Alice", id: 1 }];

// ❌ Error: Object is possibly 'undefined'
const admin = users.find(u => u.id === 1);
console.log(admin.name);

// ✅ Fix: Guard the result
const admin = users.find(u => u.id === 1);
if (!admin) throw new Error("Admin not found");
console.log(admin.name);
```

### Error Pattern 4: Map.get returns V | undefined

```ts
const cache = new Map<string, number>();
cache.set("count", 42);

// ❌ Error: Object is possibly 'undefined'
const val: number = cache.get("count");

// ✅ Fix A: Nullish coalescing
const val: number = cache.get("count") ?? 0;

// ✅ Fix B: Type guard
const val = cache.get("count");
if (val !== undefined) {
  doSomething(val); // val: number
}
```

### Error Pattern 5: Function parameters accepting null

```ts
// ❌ Error: Argument of type 'null' is not assignable to parameter of type 'string'
function greet(name: string) { return `Hello, ${name}`; }
greet(null);

// ✅ Fix: Accept nullable explicitly
function greet(name: string | null) {
  return `Hello, ${name ?? "stranger"}`;
}
```

### Error Pattern 6: Uninitialized variables

```ts
// ❌ Error: Variable 'result' is used before being assigned
let result: string;
if (condition) result = "yes";
console.log(result);

// ✅ Fix: Initialize or widen type
let result: string | undefined;
if (condition) result = "yes";
console.log(result ?? "no");
```

### Error Pattern 7: Callback parameters that may be undefined

```ts
// ❌ Error with strict APIs
const nums = [1, 2, 3];
nums.forEach((val, idx) => {
  // val is number, no issue here
});

// But with record iteration:
const config: Record<string, string> = {};
Object.keys(config).forEach(key => {
  // ❌ If noUncheckedIndexedAccess is also on:
  const val: string = config[key]; // string | undefined
});
```

### Utility types for strict null checks

```ts
// NonNullable<T> strips null and undefined
type MaybeUser = User | null | undefined;
type DefiniteUser = NonNullable<MaybeUser>; // User

// Required<T> makes all properties non-optional
type FullConfig = Required<Partial<Config>>;
```

---

## `noImplicitAny`

**What it catches**: Parameters, variables, and return types where TypeScript infers `any` because it cannot determine a more specific type. Implicit `any` silently disables type checking wherever it appears.

### Error Pattern 1: Untyped function parameters

```ts
// ❌ Error: Parameter 'x' implicitly has an 'any' type
function double(x) { return x * 2; }

// ✅ Fix
function double(x: number): number { return x * 2; }
```

### Error Pattern 2: Callback parameters

```ts
// ❌ Error: Parameter 'item' implicitly has an 'any' type
const items = JSON.parse(data);
items.forEach(item => console.log(item.name));

// ✅ Fix: Type the parsed data
interface Item { name: string; id: number; }
const items: Item[] = JSON.parse(data);
items.forEach(item => console.log(item.name));
```

### Error Pattern 3: Destructured parameters

```ts
// ❌ Error: Binding element 'name' implicitly has an 'any' type
function greet({ name, age }) { return `${name} is ${age}`; }

// ✅ Fix
function greet({ name, age }: { name: string; age: number }) {
  return `${name} is ${age}`;
}
```

### Error Pattern 4: Rest parameters

```ts
// ❌ Error: Rest parameter 'args' implicitly has an 'any[]' type
function log(...args) { console.log(...args); }

// ✅ Fix
function log(...args: unknown[]) { console.log(...args); }
```

### Error Pattern 5: Dynamic object access

```ts
// ❌ Error: Element implicitly has an 'any' type because expression of type 'string'
// can't be used to index type '{}'
const obj = { a: 1, b: 2 };
function getValue(key: string) { return obj[key]; }

// ✅ Fix A: Narrow key type
function getValue(key: keyof typeof obj) { return obj[key]; }

// ✅ Fix B: Index signature
const obj: Record<string, number> = { a: 1, b: 2 };
function getValue(key: string) { return obj[key]; }
```

### Error Pattern 6: Empty array inference

```ts
// ❌ Error: Variable 'items' implicitly has type 'any[]'
const items = [];
items.push("hello");

// ✅ Fix
const items: string[] = [];
items.push("hello");
```

### Error Pattern 7: Third-party libraries without types

```ts
// ❌ Error: Could not find a declaration file for module 'legacy-lib'
import legacy from 'legacy-lib';

// ✅ Fix A: Install @types
// npm install -D @types/legacy-lib

// ✅ Fix B: Declare module (src/types/legacy-lib.d.ts)
declare module 'legacy-lib' {
  export function doThing(input: string): string;
  export default doThing;
}

// ✅ Fix C (last resort): Declare as any
declare module 'legacy-lib';
```

### Error Pattern 8: Event handlers

```ts
// ❌ Error: Parameter 'e' implicitly has an 'any' type
document.addEventListener("click", function(e) {
  console.log(e.target);
});

// ✅ Fix: TypeScript infers correctly with addEventListener,
// but explicit typing helps in extracted handlers:
function handleClick(e: MouseEvent) {
  console.log(e.target);
}
document.addEventListener("click", handleClick);
```

---

## `strictFunctionTypes`

**What it catches**: Unsafe covariant function parameter assignments. Function parameter types must be **contravariant** — a function accepting a supertype cannot be assigned where a function accepting a subtype is expected.

### Contravariance explained

```
If Dog extends Animal:
  (animal: Animal) => void  IS assignable to  (dog: Dog) => void     ✅ (contravariant)
  (dog: Dog) => void        IS NOT assignable to  (animal: Animal) => void  ❌ (unsafe)
```

Without `strictFunctionTypes`, TypeScript uses **bivariant** checking for function parameters, allowing unsafe assignments.

### Error Pattern 1: Event handler assignment

```ts
interface Event { type: string; }
interface MouseEvent extends Event { x: number; y: number; }

type EventHandler = (e: Event) => void;
type MouseHandler = (e: MouseEvent) => void;

// ❌ Error: Type 'EventHandler' is not assignable to type 'MouseHandler'
// Types of parameters 'e' and 'e' are incompatible.
const mouseHandler: MouseHandler = (e: Event) => {
  // e.x would be undefined at runtime!
  console.log(e.type);
};

// ✅ Fix: Match the expected parameter type
const mouseHandler: MouseHandler = (e: MouseEvent) => {
  console.log(e.x, e.y);
};
```

### Error Pattern 2: Callback arrays

```ts
class Animal { name = "animal"; }
class Dog extends Animal { breed = "unknown"; }
class Cat extends Animal { indoor = true; }

// ❌ Error: Type '(a: Animal) => void' not assignable to '(d: Dog) => void'
const dogHandlers: ((d: Dog) => void)[] = [];
const animalLogger = (a: Animal) => console.log(a.name);
dogHandlers.push(animalLogger); // Actually safe, but flagged

// ✅ Fix: Widen the array type if the callback is legitimately compatible
const handlers: ((a: Animal) => void)[] = [];
handlers.push(animalLogger);
```

### Error Pattern 3: Generic function types

```ts
interface Comparer<T> {
  compare: (a: T, b: T) => number;  // strict: contravariant
}

// ❌ Error: Dog comparer can't be used as Animal comparer
const dogComparer: Comparer<Dog> = {
  compare: (a, b) => a.breed.localeCompare(b.breed)
};
const animalComparer: Comparer<Animal> = dogComparer; // Error

// ✅ Fix: Use Animal-level comparison
const animalComparer: Comparer<Animal> = {
  compare: (a, b) => a.name.localeCompare(b.name)
};
```

### Method vs function syntax distinction

```ts
// Method syntax uses BIVARIANT checking (even with strictFunctionTypes)
interface BivariantHandler {
  handle(event: MouseEvent): void; // method syntax — bivariant
}

// Function property syntax uses CONTRAVARIANT checking
interface StrictHandler {
  handle: (event: MouseEvent) => void; // function syntax — contravariant
}
```

**Best practice**: Use function property syntax (`handle: (e: T) => void`) for strict checking. Use method syntax (`handle(e: T): void`) only when bivariance is intentionally needed (e.g., in array method definitions).

### React event handler pattern

```ts
// ❌ Error
interface Props {
  onClick: (e: React.MouseEvent<HTMLButtonElement>) => void;
}
const MyComponent = ({ onClick }: Props) => (
  <button onClick={onClick}>Click</button>
);
// Passing (e: React.SyntheticEvent) => void as onClick will error

// ✅ Fix: Match the exact event type
const handler = (e: React.MouseEvent<HTMLButtonElement>) => {
  console.log(e.clientX);
};
<MyComponent onClick={handler} />;
```

---

## `strictBindCallApply`

**What it catches**: Incorrect arguments passed to `Function.prototype.bind`, `.call`, and `.apply`. Without this flag, these methods accept `any` arguments.

### Error Pattern 1: Wrong argument types with call

```ts
function add(a: number, b: number): number { return a + b; }

// ❌ Error: Argument of type 'string' is not assignable to parameter of type 'number'
add.call(undefined, "1", "2");

// ✅ Fix
add.call(undefined, 1, 2);
```

### Error Pattern 2: Wrong argument count with apply

```ts
function greet(name: string, greeting: string) {
  return `${greeting}, ${name}!`;
}

// ❌ Error: Expected 2 arguments, but got 1
greet.apply(undefined, ["Alice"]);

// ✅ Fix
greet.apply(undefined, ["Alice", "Hello"]);
```

### Error Pattern 3: bind with partial application

```ts
function multiply(a: number, b: number) { return a * b; }

// ❌ Error: Argument of type 'string' is not assignable to parameter of type 'number'
const double = multiply.bind(null, "2");

// ✅ Fix
const double = multiply.bind(null, 2);
double(5); // 10 — TypeScript knows this takes one number arg
```

### Error Pattern 4: Class method binding

```ts
class Logger {
  prefix: string;
  constructor(prefix: string) { this.prefix = prefix; }
  log(msg: string) { console.log(`${this.prefix}: ${msg}`); }
}

const logger = new Logger("APP");

// ❌ Error: Argument of type 'number' is not assignable to parameter of type 'string'
const boundLog = logger.log.bind(logger);
boundLog(42);

// ✅ Fix
boundLog("Starting up");
```

### When bind/call/apply appear in legacy code

```ts
// Common legacy pattern — apply with arguments object
function legacyWrapper() {
  // ❌ 'arguments' has implicit any type; apply has wrong types
  return someFunction.apply(this, arguments);
}

// ✅ Fix: Use rest parameters
function modernWrapper(...args: Parameters<typeof someFunction>) {
  return someFunction.apply(this, args);
}

// ✅ Better fix: Use spread
function modernWrapper(...args: Parameters<typeof someFunction>) {
  return someFunction(...args);
}
```

---

## `strictPropertyInitialization`

**What it catches**: Class properties declared without an initializer and not definitely assigned in the constructor. Requires `strictNullChecks` to be enabled.

### Error Pattern 1: Missing constructor initialization

```ts
// ❌ Error: Property 'name' has no initializer and is not definitely assigned in the constructor
class User {
  name: string;
  age: number;
}

// ✅ Fix A: Initialize in constructor
class User {
  name: string;
  age: number;
  constructor(name: string, age: number) {
    this.name = name;
    this.age = age;
  }
}

// ✅ Fix B: Default values at declaration
class User {
  name: string = "";
  age: number = 0;
}

// ✅ Fix C: Parameter properties
class User {
  constructor(public name: string, public age: number) {}
}
```

### Error Pattern 2: Properties set in lifecycle hooks (Angular, etc.)

```ts
// ❌ Error: Property 'data' has no initializer
class MyComponent {
  data: string[];

  ngOnInit() {
    this.data = fetchData(); // set here, but TS doesn't see it
  }
}

// ✅ Fix: Definite assignment assertion
class MyComponent {
  data!: string[]; // ! tells TS "I guarantee this is assigned before use"

  ngOnInit() {
    this.data = fetchData();
  }
}
```

### Error Pattern 3: Properties set by dependency injection

```ts
// ❌ Error: Property 'service' has no initializer
class Controller {
  service: UserService;  // Injected by framework
}

// ✅ Fix A: Definite assignment
class Controller {
  service!: UserService;
}

// ✅ Fix B: Constructor injection (preferred)
class Controller {
  constructor(private service: UserService) {}
}
```

### Error Pattern 4: Optional properties

```ts
// ❌ Error: Property 'middleName' has no initializer
class Person {
  firstName: string;
  middleName: string; // not everyone has one

  constructor(first: string) {
    this.firstName = first;
  }
}

// ✅ Fix: Mark as optional
class Person {
  firstName: string;
  middleName?: string;

  constructor(first: string) {
    this.firstName = first;
  }
}
```

### Error Pattern 5: Conditional initialization in constructor

```ts
// ❌ Error: 'role' is not definitely assigned — TS can't prove all branches assign it
class User {
  role: string;
  constructor(isAdmin: boolean) {
    if (isAdmin) {
      this.role = "admin";
    }
    // missing else branch
  }
}

// ✅ Fix: Ensure all branches assign
class User {
  role: string;
  constructor(isAdmin: boolean) {
    this.role = isAdmin ? "admin" : "user";
  }
}
```

---

## `noImplicitThis`

**What it catches**: Uses of `this` where its type is implicitly `any`, typically in standalone functions, object literals, and callbacks.

### Error Pattern 1: Object method using function keyword

```ts
// ❌ Error: 'this' implicitly has type 'any'
const counter = {
  count: 0,
  increment: function() {
    this.count++; // 'this' is any
  }
};

// ✅ Fix A: Explicit this parameter
const counter = {
  count: 0,
  increment: function(this: { count: number }) {
    this.count++;
  }
};

// ✅ Fix B: Use a class
class Counter {
  count = 0;
  increment() { this.count++; } // 'this' is Counter
}
```

### Error Pattern 2: Callbacks losing this context

```ts
class Timer {
  elapsed = 0;

  start() {
    // ❌ Error: 'this' implicitly has type 'any' inside the callback
    setInterval(function() {
      this.elapsed++;
    }, 1000);
  }
}

// ✅ Fix A: Arrow function (captures lexical this)
class Timer {
  elapsed = 0;
  start() {
    setInterval(() => {
      this.elapsed++; // this is Timer
    }, 1000);
  }
}

// ✅ Fix B: Bind
class Timer {
  elapsed = 0;
  start() {
    setInterval(this.tick.bind(this), 1000);
  }
  tick() { this.elapsed++; }
}

// ✅ Fix C: Arrow function property
class Timer {
  elapsed = 0;
  tick = () => { this.elapsed++; };
  start() { setInterval(this.tick, 1000); }
}
```

### Error Pattern 3: Standalone functions with this

```ts
// ❌ Error: 'this' implicitly has type 'any'
function getFullName() {
  return `${this.firstName} ${this.lastName}`;
}

// ✅ Fix: Declare this parameter
interface Person { firstName: string; lastName: string; }
function getFullName(this: Person) {
  return `${this.firstName} ${this.lastName}`;
}
// Usage:
const person = { firstName: "Jane", lastName: "Doe", getFullName };
person.getFullName(); // "Jane Doe"
```

### Error Pattern 4: Event handler this

```ts
// ❌ Error: 'this' implicitly has type 'any'
document.querySelector("button")?.addEventListener("click", function() {
  this.disabled = true; // 'this' is the element, but TS doesn't know
});

// ✅ Fix: Use explicit this type
document.querySelector("button")?.addEventListener("click", function(this: HTMLButtonElement) {
  this.disabled = true;
});

// ✅ Alt: Use arrow function with event.currentTarget
document.querySelector("button")?.addEventListener("click", (e) => {
  (e.currentTarget as HTMLButtonElement).disabled = true;
});
```

---

## `useUnknownInCatchVariables`

**What it catches**: Catch clause variables typed as `any`, allowing unsafe property access on error objects without checking the type first. With this flag, catch variables become `unknown`.

### Error Pattern 1: Direct property access on error

```ts
// ❌ Error: 'err' is of type 'unknown'
try {
  JSON.parse(input);
} catch (err) {
  console.log(err.message); // can't access .message on unknown
}

// ✅ Fix A: instanceof narrowing
try {
  JSON.parse(input);
} catch (err) {
  if (err instanceof Error) {
    console.log(err.message);
  } else {
    console.log("Unknown error:", String(err));
  }
}

// ✅ Fix B: Type assertion with guard
try {
  JSON.parse(input);
} catch (err) {
  const message = err instanceof Error ? err.message : String(err);
  console.log(message);
}
```

### Error Pattern 2: Re-throwing typed errors

```ts
// ❌ Error: 'err' is of type 'unknown'
try {
  await fetchData();
} catch (err) {
  if (err.status === 404) { // can't access .status
    return null;
  }
  throw err;
}

// ✅ Fix: Narrow with a type guard
interface HttpError { status: number; message: string; }

function isHttpError(err: unknown): err is HttpError {
  return typeof err === "object" && err !== null && "status" in err;
}

try {
  await fetchData();
} catch (err) {
  if (isHttpError(err) && err.status === 404) {
    return null;
  }
  throw err;
}
```

### Error Pattern 3: Logging structured errors

```ts
// ❌ Error: 'err' is of type 'unknown'
try {
  await processQueue();
} catch (err) {
  logger.error({ err, stack: err.stack }); // can't access properties
}

// ✅ Fix: Utility function
function toError(err: unknown): Error {
  if (err instanceof Error) return err;
  return new Error(String(err));
}

try {
  await processQueue();
} catch (err) {
  const error = toError(err);
  logger.error({ message: error.message, stack: error.stack });
}
```

### Error Pattern 4: Explicit annotation to opt out

```ts
// If you need the old behavior in a specific catch:
try {
  riskyCall();
} catch (err: any) {
  // explicitly typed as any — suppresses the error
  // Use sparingly; prefer narrowing
  console.log(err.message);
}
```

---

## `noUncheckedIndexedAccess`

**What it catches**: Index signature access (`obj[key]`, `arr[i]`) that assumes the result is always defined. With this flag, every indexed access on a type with an index signature includes `| undefined` in the result type.

**Not included in `strict`** — must be enabled separately.

### Error Pattern 1: Array element access

```ts
const names: string[] = ["Alice", "Bob"];

// ❌ Error: 'name' is 'string | undefined', not 'string'
const name: string = names[0];

// ✅ Fix A: Non-null assertion (when index is guaranteed valid)
const name: string = names[0]!;

// ✅ Fix B: Guard
const name = names[0];
if (name !== undefined) {
  console.log(name.toUpperCase()); // name: string
}

// ✅ Fix C: Nullish coalescing
const name: string = names[0] ?? "Unknown";
```

### Error Pattern 2: Record/dictionary access

```ts
const env: Record<string, string> = process.env as Record<string, string>;

// ❌ Error: Type 'string | undefined' is not assignable to type 'string'
const port: string = env["PORT"];

// ✅ Fix
const port: string = env["PORT"] ?? "3000";
```

### Error Pattern 3: Iterating with index

```ts
const items: number[] = [1, 2, 3];

// ❌ Error inside loop body
for (let i = 0; i < items.length; i++) {
  const item: number = items[i]; // number | undefined
  console.log(item.toFixed(2));
}

// ✅ Fix A: Use for-of (no indexed access needed)
for (const item of items) {
  console.log(item.toFixed(2)); // item: number ✅
}

// ✅ Fix B: Non-null assertion in indexed loop
for (let i = 0; i < items.length; i++) {
  const item = items[i]!;
  console.log(item.toFixed(2));
}
```

### Error Pattern 4: Tuple types are NOT affected

```ts
// Tuples with known indices are fine
const pair: [string, number] = ["age", 30];
const label: string = pair[0]; // ✅ no error — TS knows index 0 exists

// But out-of-bounds tuple access IS caught
const third = pair[2]; // Error: Tuple type has no element at index '2'
```

### Error Pattern 5: Object.entries / Object.keys iteration

```ts
const config: Record<string, number> = { timeout: 30, retries: 3 };

// ❌ entries gives [string, number] but direct access adds undefined
Object.keys(config).forEach(key => {
  const val: number = config[key]; // number | undefined
});

// ✅ Fix: Use Object.entries directly
Object.entries(config).forEach(([key, val]) => {
  console.log(key, val.toFixed(0)); // val: number ✅
});
```

---

## `exactOptionalPropertyTypes`

**What it catches**: Assigning `undefined` explicitly to an optional property. With this flag, `prop?: string` means "the property may be absent" but does **not** mean "the property may be `undefined`". To allow `undefined`, you must write `prop?: string | undefined`.

**Not included in `strict`** — must be enabled separately.

### The distinction

```ts
interface Settings {
  theme?: string; // "theme" might not exist as a key
}

// Without exactOptionalPropertyTypes:
const s: Settings = { theme: undefined }; // ✅ allowed

// With exactOptionalPropertyTypes:
const s: Settings = { theme: undefined }; // ❌ Error
```

### Error Pattern 1: Explicitly setting optional property to undefined

```ts
interface Config {
  debug?: boolean;
}

// ❌ Error: Type 'undefined' is not assignable to type 'boolean'
const config: Config = { debug: undefined };

// ✅ Fix A: Omit the property entirely
const config: Config = {};

// ✅ Fix B: Allow undefined explicitly
interface Config {
  debug?: boolean | undefined;
}
const config: Config = { debug: undefined }; // ✅
```

### Error Pattern 2: Spread/merge operations

```ts
interface Options {
  color?: string;
  size?: number;
}

function applyDefaults(opts: Options): Options {
  return {
    color: "blue",
    size: 12,
    ...opts // may spread { color: undefined } — Error
  };
}

// ✅ Fix: Filter undefined values or adjust the type
function applyDefaults(opts: Options): Required<Options> {
  return {
    color: opts.color ?? "blue",
    size: opts.size ?? 12,
  };
}
```

### Error Pattern 3: Conditional property assignment

```ts
interface User {
  name: string;
  nickname?: string;
}

// ❌ Error
function updateUser(user: User, newNick: string | undefined) {
  user.nickname = newNick; // can't assign undefined to optional
}

// ✅ Fix A: Delete the property instead
function updateUser(user: User, newNick?: string) {
  if (newNick !== undefined) {
    user.nickname = newNick;
  } else {
    delete user.nickname;
  }
}

// ✅ Fix B: Widen the type
interface User {
  name: string;
  nickname?: string | undefined;
}
```

### When to use this flag

Enable `exactOptionalPropertyTypes` when you need to distinguish between "property is absent" (`"key" in obj === false`) and "property is present but undefined" (`obj.key === undefined`). This matters for:

- Serialization (JSON.stringify omits missing keys but includes `undefined` values)
- `Object.keys()` / `Object.entries()` iteration
- `hasOwnProperty` / `in` checks
- Database ORMs where `undefined` means "don't update" vs missing means "use default"

---

## `noImplicitReturns`

**What it catches**: Functions where some code paths return a value and others fall through without an explicit `return`. This flag does **not** require functions that never return to add `return undefined`.

### Error Pattern: Missing return in branch

```ts
// ❌ Error: Not all code paths return a value
function getDiscount(tier: string): number {
  if (tier === "gold") return 0.2;
  if (tier === "silver") return 0.1;
  // falls through without returning for other tiers
}

// ✅ Fix A: Add default return
function getDiscount(tier: string): number {
  if (tier === "gold") return 0.2;
  if (tier === "silver") return 0.1;
  return 0;
}

// ✅ Fix B: Switch with exhaustive check
type Tier = "gold" | "silver" | "bronze";
function getDiscount(tier: Tier): number {
  switch (tier) {
    case "gold": return 0.2;
    case "silver": return 0.1;
    case "bronze": return 0.05;
    default: {
      const _exhaustive: never = tier;
      throw new Error(`Unknown tier: ${_exhaustive}`);
    }
  }
}
```

### Void functions are not affected

```ts
// ✅ No error — void functions don't need explicit returns
function log(msg: string): void {
  if (!msg) return;
  console.log(msg);
}
```

---

## `noFallthroughCasesInSwitch`

**What it catches**: `switch` cases that fall through to the next case without a `break`, `return`, or `throw`. Intentional fallthrough requires explicit annotation.

### Error Pattern

```ts
// ❌ Error: Fallthrough case in switch
function describe(status: number): string {
  switch (status) {
    case 200:
      console.log("OK");
    case 301: // falls through from 200!
      return "redirect";
    case 404:
      return "not found";
  }
  return "unknown";
}

// ✅ Fix A: Add break
switch (status) {
  case 200:
    console.log("OK");
    break;
  case 301:
    return "redirect";
  case 404:
    return "not found";
}

// ✅ Fix B: Return from each case
switch (status) {
  case 200: return "ok";
  case 301: return "redirect";
  case 404: return "not found";
}

// ✅ Fix C: Intentional fallthrough — empty case bodies are allowed
switch (status) {
  case 200:
  case 201:
  case 204:
    return "success"; // intentional grouping, no error
}
```

---

## `noImplicitOverride`

**What it catches**: Subclass methods that override a base class method without the `override` keyword. This prevents accidentally overriding a method when the base class changes.

### Error Pattern

```ts
class Base {
  greet() { return "hello"; }
  farewell() { return "goodbye"; }
}

// ❌ Error: This member must have an 'override' modifier because it overrides
// a member in the base class 'Base'
class Derived extends Base {
  greet() { return "hi"; }
}

// ✅ Fix: Add override keyword
class Derived extends Base {
  override greet() { return "hi"; }
}
```

### Why it matters

```ts
// Without noImplicitOverride, renaming in base silently breaks override:
class Base {
  initialize() { /* ... */ } // renamed from init()
}

class Plugin extends Base {
  init() { /* ... */ } // was overriding init(), now it's a new method — silent bug
}

// With noImplicitOverride:
class Plugin extends Base {
  override init() { /* ... */ } // ❌ Error: no 'init' in base class to override
  // Forces you to update to:
  override initialize() { /* ... */ }
}
```

### Virtual modifier (stylistic complement)

```ts
// Some teams pair noImplicitOverride with a virtual comment convention:
class Base {
  /** @virtual */ greet() { return "hello"; }
  farewell() { return "goodbye"; } // not intended for override
}

class Derived extends Base {
  override greet() { return "hi"; } // ✅ clearly overrides a virtual method
}
```
