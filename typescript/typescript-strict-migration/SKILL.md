---
name: typescript-strict-migration
description: >
  Positive triggers: "Use when user wants to enable TypeScript strict mode, fix strict-mode errors
  (strictNullChecks, noImplicitAny, strictFunctionTypes), migrate a JS/TS codebase to stricter types,
  or adopt incremental strict-mode with ts-strict-check or typescript-strict-plugin."
  Negative: "Do NOT use for general TypeScript syntax, basic type annotations, or JavaScript-only
  projects without TypeScript."
---

# TypeScript Strict Mode Migration

## Strict Flags Reference

Enable `"strict": true` in `tsconfig.json` to activate all flags below. Enable individually for incremental adoption.

### `strict`
Master switch. Enables all flags in this section. Equivalent to setting each one to `true`.

### `strictNullChecks`
Make `null` and `undefined` distinct types. Variables no longer implicitly accept `null`/`undefined`.

```ts
// BEFORE: compiles, crashes at runtime
function getLength(s: string) { return s.length; }
getLength(null); // runtime TypeError

// AFTER: caught at compile time
function getLength(s: string) { return s.length; }
getLength(null); // Error: Argument of type 'null' is not assignable to parameter of type 'string'
```

### `noImplicitAny`
Error when TypeScript infers `any` for a parameter or variable.

```ts
// BEFORE: parameter is implicitly 'any'
function double(x) { return x * 2; }

// AFTER: explicit annotation required
function double(x: number): number { return x * 2; }
```

### `strictBindCallApply`
Check that `bind`, `call`, `apply` match the target function's signature.

```ts
function add(a: number, b: number) { return a + b; }
add.call(undefined, "hello", "world"); // Error: 'string' not assignable to 'number'
```

### `strictFunctionTypes`
Enforce contravariant parameter checking. Disallow unsafe covariant parameter assignment.

```ts
type Handler = (e: MouseEvent) => void;
// Error: '(e: Event) => void' not assignable to 'Handler' — Event ≠ MouseEvent
const handler: Handler = (e: Event) => { console.log(e.target); };
```

### `strictPropertyInitialization`
Require class properties to be initialized in the constructor or at declaration. Requires `strictNullChecks`.

```ts
// BEFORE: undefined access at runtime
class User { name: string; constructor() {} }

// AFTER
class User {
  name: string;
  constructor(name: string) { this.name = name; }
}
```

### `noImplicitThis`
Error when `this` has an implicit `any` type.

```ts
// BEFORE
const obj = { value: 42, getValue: function() { return this.value; } };

// AFTER: explicit this parameter
const obj = { value: 42, getValue: function(this: { value: number }) { return this.value; } };
```

### `alwaysStrict`
Emit `"use strict"` in every output file. Parse in strict mode.

### `useUnknownInCatchVariables`
Type `catch` clause variables as `unknown` instead of `any`. Must narrow before use.

```ts
// BEFORE: err is 'any'
try { riskyOp(); } catch (err) { console.log(err.message); }

// AFTER: err is 'unknown', narrow first
try { riskyOp(); } catch (err) {
  if (err instanceof Error) console.log(err.message);
}
```

---

## Incremental Migration Strategy

### Option 1: typescript-strict-plugin (file-by-file)

Install and configure the plugin to enforce strict mode per-file while keeping `strict: false` globally.

```bash
npm install -D typescript-strict-plugin
```

```jsonc
// tsconfig.json
{
  "compilerOptions": {
    "strict": false,
    "plugins": [{ "name": "typescript-strict-plugin" }]
  }
}
```

Mark files as strict-ready with a comment at the top:

```ts
//@ts-strict
import { User } from './models';
// This file is now checked under strict rules
```

Auto-annotate all legacy files to opt out:

```bash
npx update-strict-comments
```

Each legacy file gets `//@ts-strict-ignore`. Remove the comment as you fix each file.

Run CI enforcement:

```bash
npx tsc-strict
```

### Option 2: Separate tsconfig for strict files

```jsonc
// tsconfig.strict.json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "strict": true,
    "noEmit": true
  },
  "include": ["src/strict-ready/**/*.ts"]
}
```

```bash
# CI step: check strict files
tsc --project tsconfig.strict.json
```

Move files into `include` as they pass strict checks.

### Option 3: Flag-by-flag rollout

Enable one flag at a time across the whole codebase. Recommended order:

1. `noImplicitAny` — add missing annotations
2. `strictNullChecks` — add null guards (generates most errors)
3. `strictBindCallApply` — usually few errors
4. `strictFunctionTypes` — fix callback signatures
5. `strictPropertyInitialization` — fix class constructors
6. `noImplicitThis` — add `this` parameters
7. `useUnknownInCatchVariables` — narrow catch variables
8. `alwaysStrict` — usually zero errors

---

## Common Error Patterns and Fixes

### "Object is possibly 'null' or 'undefined'" (`strictNullChecks`)

```ts
// BEFORE
const el = document.getElementById('app');
el.textContent = 'Hello'; // Error

// FIX 1: null check
const el = document.getElementById('app');
if (el) {
  el.textContent = 'Hello';
}

// FIX 2: non-null assertion (use when guaranteed)
const el = document.getElementById('app')!;
el.textContent = 'Hello';

// FIX 3: optional chaining
document.getElementById('app')?.focus();
```

### "Parameter implicitly has an 'any' type" (`noImplicitAny`)

```ts
// BEFORE
function process(data) { return data.map(item => item.id); }

// AFTER
function process(data: Array<{ id: string }>): string[] {
  return data.map(item => item.id);
}
```

### "Property has no initializer" (`strictPropertyInitialization`)

```ts
// BEFORE
class Config { apiUrl: string; timeout: number; }

// FIX 1: initialize in constructor
class Config {
  apiUrl: string;
  timeout: number;
  constructor(apiUrl: string, timeout: number) {
    this.apiUrl = apiUrl;
    this.timeout = timeout;
  }
}

// FIX 2: definite assignment (set in lifecycle hook)
class Config { apiUrl!: string; timeout = 3000; }

// FIX 3: make optional
class Config { apiUrl?: string; timeout?: number; }
```

### "'this' implicitly has type 'any'" (`noImplicitThis`)

```ts
// BEFORE
function setup() { this.name = 'app'; }

// AFTER: explicit this parameter, or use arrow function / class method
function setup(this: { name: string }) { this.name = 'app'; }
```

### "Catch variable is 'unknown'" (`useUnknownInCatchVariables`)

```ts
// BEFORE
catch (err) { sendError(err.message); }

// AFTER
catch (err) {
  const message = err instanceof Error ? err.message : String(err);
  sendError(message);
}
```

---

## Narrowing Patterns

### Type guards

```ts
function isString(val: unknown): val is string {
  return typeof val === 'string';
}

function process(input: string | number) {
  if (isString(input)) {
    return input.toUpperCase(); // input is string
  }
  return input.toFixed(2); // input is number
}
```

### Discriminated unions

```ts
type Result<T> =
  | { ok: true; value: T }
  | { ok: false; error: Error };

function handle(result: Result<string>) {
  if (result.ok) {
    console.log(result.value); // narrowed to { ok: true; value: string }
  } else {
    console.error(result.error.message); // narrowed to { ok: false; error: Error }
  }
}
```

### Assertion functions

```ts
function assertDefined<T>(val: T | null | undefined, msg?: string): asserts val is T {
  if (val == null) throw new Error(msg ?? 'Value is null or undefined');
}

const el = document.getElementById('root');
assertDefined(el, 'Root element not found');
el.textContent = 'Ready'; // el is HTMLElement, no null check needed
```

### `in` operator narrowing

```ts
type Fish = { swim: () => void };
type Bird = { fly: () => void };

function move(animal: Fish | Bird) {
  if ('swim' in animal) {
    animal.swim();
  } else {
    animal.fly();
  }
}
```

---

## Utility Type Patterns for Strict Migrations

### `NonNullable<T>` — strip null/undefined

```ts
type MaybeUser = User | null | undefined;
type DefiniteUser = NonNullable<MaybeUser>; // User

function greet(user: NonNullable<MaybeUser>) {
  console.log(user.name); // safe, no null check needed
}
```

### `Required<T>` — make all properties required

```ts
interface Config {
  host?: string;
  port?: number;
}

function startServer(config: Required<Config>) {
  // config.host and config.port are guaranteed
  listen(config.host, config.port);
}
```

### `Record<K, V>` — typed dictionaries

```ts
// BEFORE: implicit any on access
const cache = {};
// AFTER: typed record
const cache: Record<string, User> = {};
```

### `Partial<T>` — for update/patch operations

```ts
function updateUser(id: string, updates: Partial<User>): User {
  return { ...getUser(id), ...updates };
}
```

### `Extract` / `Exclude` — filter union members

```ts
type Events = 'click' | 'scroll' | 'keydown' | 'keyup';
type KeyEvents = Extract<Events, `key${string}`>; // 'keydown' | 'keyup'
type NonKeyEvents = Exclude<Events, `key${string}`>; // 'click' | 'scroll'
```

---

## tsconfig.json Configuration Examples

### Full strict (new projects)

```jsonc
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noFallthroughCasesInSwitch": true,
    "forceConsistentCasingInFileNames": true,
    "skipLibCheck": true
  }
}
```

### Incremental strict (migrating projects)

```jsonc
{
  "compilerOptions": {
    "strict": false,
    "noImplicitAny": true,
    "strictNullChecks": true,
    // Enable these next:
    // "strictBindCallApply": true,
    // "strictFunctionTypes": true,
    // "strictPropertyInitialization": true,
    // "noImplicitThis": true,
    // "useUnknownInCatchVariables": true,
    "plugins": [{ "name": "typescript-strict-plugin" }]
  }
}
```

### With typescript-strict-plugin paths

```jsonc
{
  "compilerOptions": {
    "strict": false,
    "plugins": [{
      "name": "typescript-strict-plugin",
      "paths": ["src/new-modules/", "src/core/"],
      "excludePaths": ["src/legacy/"]
    }]
  }
}
```

---

## CI Integration

### Block new non-strict code

```yaml
# .github/workflows/strict-check.yml
name: Strict Type Check
on: [pull_request]
jobs:
  strict:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22 }
      - run: npm ci
      - run: npx tsc-strict          # fails if strict errors in opted-in files
      - run: npx tsc --noEmit        # standard type check
```

### Track progress over time

```bash
# count-strict-progress.sh
TOTAL=$(find src -name '*.ts' -o -name '*.tsx' | wc -l)
IGNORED=$(grep -rl '@ts-strict-ignore' src | wc -l)
STRICT=$((TOTAL - IGNORED))
echo "Strict: $STRICT / $TOTAL files ($(( STRICT * 100 / TOTAL ))%)"
```

Add to CI to prevent regression:

```yaml
      - name: Check strict coverage
        run: |
          TOTAL=$(find src -name '*.ts' -o -name '*.tsx' | wc -l)
          IGNORED=$(grep -rl '@ts-strict-ignore' src | wc -l)
          PERCENT=$(( (TOTAL - IGNORED) * 100 / TOTAL ))
          echo "Strict coverage: ${PERCENT}%"
          if [ "$PERCENT" -lt "$MIN_STRICT_PERCENT" ]; then
            echo "::error::Strict coverage dropped below ${MIN_STRICT_PERCENT}%"
            exit 1
          fi
        env:
          MIN_STRICT_PERCENT: 60
```

---

## Migration Checklist

1. **Audit** — run `tsc --strict --noEmit` and count errors per flag
2. **Choose strategy** — flag-by-flag (small codebases) or file-by-file with `typescript-strict-plugin` (large codebases)
3. **Install tooling** — `npm install -D typescript-strict-plugin` if using file-by-file approach
4. **Enable first flag** — start with `noImplicitAny` (easiest to fix mechanically)
5. **Fix errors** — annotate parameters, add type guards, initialize properties
6. **Enable `strictNullChecks`** — largest batch of errors; use narrowing patterns above
7. **Enable remaining flags** — `strictBindCallApply`, `strictFunctionTypes`, `strictPropertyInitialization`, `noImplicitThis`, `useUnknownInCatchVariables`
8. **Flip to `strict: true`** — replace individual flags with the master switch
9. **Add CI gates** — block PRs that introduce new strict errors
10. **Enable bonus flags** — `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`
11. **Remove escape hatches** — search for `@ts-ignore`, `@ts-expect-error`, `as any` and eliminate
12. **Document** — update contributor guide with strict-mode expectations

## References

| File | When to read |
|------|-------------|
| `references/strict-flags-deep-dive.md` | Detailed reference for each strict flag with error patterns and before/after fixes |
| `references/migration-strategies.md` | File-by-file, project references, ts-migrate, monorepo, team workflow approaches |
| `references/type-narrowing-patterns.md` | All narrowing patterns: typeof, instanceof, discriminated unions, type guards, branded types, satisfies |

## Scripts

| Script | Usage |
|--------|-------|
| `scripts/strict-progress.sh` | Track migration progress — file counts, error grouping, suggests next files to tackle |
| `scripts/enable-strict-incremental.sh <flag> [--dry-run\|--suppress]` | Enable a strict flag incrementally with optional `@ts-expect-error` suppression |
| `scripts/find-any-types.sh` | Find all explicit/implicit `any` usage, categorize, suggest typed alternatives |

## Assets

| File | Description |
|------|-------------|
| `assets/tsconfig.strict.json` | Maximally strict tsconfig with all flags explicit and commented |
| `assets/tsconfig.migration.json` | Migration-friendly tsconfig with flags commented out in recommended order |
| `assets/type-utils.ts` | Utility types: branded types, assertNever, Result<T,E>, DeepRequired/Partial/Readonly |
| `assets/eslint-strict.config.mjs` | ESLint flat config with strictTypeChecked, no-explicit-any, naming conventions |
| `assets/migration-checklist.md` | Step-by-step 5-phase migration checklist |

<!-- tested: pass -->
