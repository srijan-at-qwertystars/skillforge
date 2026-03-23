# TypeScript Strict Migration Checklist

A step-by-step guide for migrating an existing TypeScript project to full strict mode. Each phase is designed to be merged independently so the migration can proceed incrementally without blocking feature work.

---

## Phase 1 — Pre-Migration Setup

- [ ] **Establish a baseline error count.**
  Run `tsc --noEmit 2>&1 | grep "error TS" | wc -l` and record the number. This is your "zero" — you should not go above it during migration.

- [ ] **Pin the TypeScript version.**
  Migration behavior can change between TS versions. Pin in `package.json` (e.g., `"typescript": "5.5.4"`) and update deliberately later.

- [ ] **Add a CI type-check job.**
  Ensure `tsc --noEmit` runs on every PR. This prevents regressions while you migrate.
  ```yaml
  # Example GitHub Actions step
  - name: Type check
    run: npx tsc --noEmit
  ```

- [ ] **Copy `tsconfig.migration.json` into the project.**
  Use it as your working config during migration. It starts with `strict: false` and has each flag commented out with instructions.

- [ ] **Set up error tracking (optional but recommended).**
  Use a script or tool (e.g., `tsc --noEmit | grep "error TS" | sort | uniq -c | sort -rn`) to categorize errors by code. This helps prioritize work.

- [ ] **Communicate the plan to your team.**
  Strict migration touches many files. Let the team know which flags are coming and when, so they can avoid conflicts and understand new CI failures.

---

## Phase 2 — Flag-by-Flag Enabling (Recommended Order)

Enable one flag at a time. For each flag: uncomment it in `tsconfig.migration.json`, fix all errors, merge, then move to the next flag.

### Flag 1: `noImplicitAny`

**Impact: Medium-High** — Typically 30-60% of total migration errors.

- [ ] Enable the flag.
- [ ] Fix errors — common patterns:
  - Add type annotations to function parameters.
  - Type callback parameters explicitly (e.g., `.map((item: Item) => ...)`).
  - Replace `any` with `unknown` and add narrowing logic.
  - For third-party libs missing types: install `@types/` packages or declare modules.
- [ ] Run tests, merge.

### Flag 2: `strictNullChecks`

**Impact: High** — Often the largest single batch of errors.

- [ ] Enable the flag.
- [ ] Fix errors — common patterns:
  - Add null guards (`if (x != null)`), optional chaining (`x?.prop`), or nullish coalescing (`x ?? default`).
  - Update function signatures: add `| null` or `| undefined` to return types.
  - Use `assertDefined()` from `type-utils.ts` for values guaranteed at runtime.
  - DOM lookups (`getElementById`, `querySelector`) now return `T | null`.
- [ ] Run tests, merge.

### Flag 3: `strictFunctionTypes`

**Impact: Low-Medium** — Usually few errors.

- [ ] Enable the flag.
- [ ] Fix errors — common patterns:
  - Update callback types to match expected signatures.
  - Fix contravariant parameter mismatches (usually in event handlers).
- [ ] Run tests, merge.

### Flag 4: `strictBindCallApply`

**Impact: Low** — Usually very few errors.

- [ ] Enable the flag.
- [ ] Fix errors — ensure `.bind()`, `.call()`, `.apply()` arguments match function signatures.
- [ ] Run tests, merge.

### Flag 5: `strictPropertyInitialization`

**Impact: Medium** — Depends on class usage; heavy OOP codebases see more errors.

**Prerequisite:** `strictNullChecks` must be enabled first.

- [ ] Enable the flag.
- [ ] Fix errors — common patterns:
  - Initialize properties in the constructor or with a default value.
  - Use definite assignment assertion (`!`) for properties set by frameworks/DI: `@Inject() private service!: Service`.
  - Convert optional properties to `prop?: Type` when they are truly optional.
- [ ] Run tests, merge.

### Flag 6: `noImplicitThis`

**Impact: Low-Medium** — Mostly affects legacy callback-style code.

- [ ] Enable the flag.
- [ ] Fix errors — common patterns:
  - Add an explicit `this` parameter: `function handler(this: HTMLElement, e: Event)`.
  - Convert to arrow functions where appropriate.
- [ ] Run tests, merge.

### Flag 7: `useUnknownInCatchVariables`

**Impact: Low** — Usually straightforward.

- [ ] Enable the flag.
- [ ] Fix errors — wrap catch blocks:
  ```typescript
  catch (error: unknown) {
    if (error instanceof Error) {
      console.error(error.message);
    }
  }
  ```
- [ ] Run tests, merge.

### Flag 8: `alwaysStrict`

**Impact: Very Low** — Rarely causes errors in modern code.

- [ ] Enable the flag.
- [ ] Fix any errors (unusual — mostly legacy scripts using `with` or duplicate params).
- [ ] Run tests, merge.

### ✅ Checkpoint: Replace individual flags with `"strict": true`

- [ ] Remove all individual strict sub-flags from tsconfig.
- [ ] Add `"strict": true`.
- [ ] Verify `tsc --noEmit` still passes.
- [ ] Merge.

---

## Phase 3 — Additional Strictness (Beyond `strict: true`)

### Flag 9: `noUncheckedIndexedAccess`

**Impact: Medium-High** — Catches a very common class of bugs.

- [ ] Enable the flag.
- [ ] Fix errors — common patterns:
  - Add undefined checks after array/object indexing: `const item = arr[i]; if (item !== undefined) { ... }`.
  - Use `.find()`, `.at()`, or `Map.get()` which already return `T | undefined`.
  - Destructuring with defaults: `const { x = 0 } = obj;`.
- [ ] Run tests, merge.

### Flag 10: `exactOptionalPropertyTypes`

**Impact: Low-Medium** — Usually a small number of errors.

- [ ] Enable the flag.
- [ ] Fix errors — common patterns:
  - Don't assign `undefined` to optional properties — use `delete obj.prop` instead.
  - Distinguish `{ x?: string }` from `{ x: string | undefined }` in type definitions.
- [ ] Run tests, merge.

### Flag 11: `noImplicitOverride`

**Impact: Low** — Mechanical fix, easy to batch.

- [ ] Enable the flag.
- [ ] Fix errors — add the `override` keyword to methods that override a parent:
  ```typescript
  class Child extends Parent {
    override render() { ... }
  }
  ```
- [ ] Run tests, merge.

---

## Phase 4 — Testing Strategy During Migration

- [ ] **Run the full test suite after each flag.**
  Strict mode can change runtime behavior in subtle ways (e.g., null checks that now throw instead of silently proceeding).

- [ ] **Add type-level tests for critical paths.**
  Use `tsd` or `expect-type` to assert that key types resolve as expected:
  ```typescript
  import { expectTypeOf } from 'expect-type';
  expectTypeOf(getUser(id)).toEqualTypeOf<User | null>();
  ```

- [ ] **Monitor for runtime regressions.**
  Strict mode is compile-time only, but the fixes you make (adding guards, changing signatures) can alter runtime behavior. Watch error rates in staging.

- [ ] **Use `// @ts-expect-error` sparingly for known issues.**
  Prefer fixing errors, but when a fix is too risky mid-migration, mark it:
  ```typescript
  // @ts-expect-error — legacy API, tracked in JIRA-1234
  legacyCall(untypedArg);
  ```
  Set up a lint rule or script to count `@ts-expect-error` comments and track them down to zero.

---

## Phase 5 — Post-Migration Hardening

- [ ] **Switch to `tsconfig.strict.json`.**
  Replace the migration config with the fully strict config. Verify no new errors appear.

- [ ] **Add ESLint strict rules.**
  Adopt `eslint-strict.config.mjs` (or equivalent) to catch issues the compiler doesn't:
  - `no-explicit-any` as error
  - `no-unsafe-*` family
  - `strict-boolean-expressions`
  - `switch-exhaustiveness-check`

- [ ] **Audit and remove all `@ts-expect-error` / `@ts-ignore` comments.**
  Search: `grep -rn "@ts-expect-error\|@ts-ignore" src/`
  Each one is a hole in the type system. Fix or document every instance.

- [ ] **Audit and remove all `as any` / `as unknown as X` casts.**
  Search: `grep -rn "as any\|as unknown as" src/`
  Replace with proper type narrowing, generics, or overloads.

- [ ] **Enable `noUnusedLocals` and `noUnusedParameters`.**
  Clean up dead code exposed by the migration.

- [ ] **Set up a "strict budget" CI check (optional).**
  Count remaining type suppressions and fail CI if the count increases:
  ```bash
  count=$(grep -rn "@ts-expect-error\|@ts-ignore\|as any" src/ | wc -l)
  if [ "$count" -gt "$MAX_SUPPRESSIONS" ]; then
    echo "Type suppressions exceeded budget: $count > $MAX_SUPPRESSIONS"
    exit 1
  fi
  ```

- [ ] **Update `type-utils.ts` for your domain.**
  Add branded types, Result wrappers, and type guards specific to your application's domain model.

- [ ] **Document the strict policy.**
  Add a note to your contributing guide: all new code must pass strict mode with zero `any` usage. PRs introducing `@ts-ignore` or `as any` require explicit approval.

- [ ] **Celebrate! 🎉**
  A fully strict TypeScript codebase is a significant achievement. Runtime null-reference errors and type-related bugs should drop dramatically.
