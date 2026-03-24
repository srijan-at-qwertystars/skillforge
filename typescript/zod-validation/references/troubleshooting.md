# Zod Troubleshooting Guide

## Table of Contents

- [Type Inference Issues](#type-inference-issues)
- [Circular Reference Errors](#circular-reference-errors)
- [Performance with Large Schemas](#performance-with-large-schemas)
- [ESM/CJS Module Issues](#esmcjs-module-issues)
- [Bundle Size Optimization](#bundle-size-optimization)
- [Error Formatting Gotchas](#error-formatting-gotchas)
- [Async Validation Pitfalls](#async-validation-pitfalls)
- [Transform Breaking Refine](#transform-breaking-refine)
- [Coercion Edge Cases](#coercion-edge-cases)
- [Zod 3 to 4 Migration Issues](#zod-3-to-4-migration-issues)

---

## Type Inference Issues

### z.infer vs z.input — When Types Diverge

```ts
const Schema = z.object({
  age: z.string().transform(Number),        // input: string, output: number
  role: z.enum(["admin", "user"]).default("user"), // input: optional, output: required
});

type Output = z.infer<typeof Schema>;  // { age: number; role: "admin" | "user" }
type Input = z.input<typeof Schema>;   // { age: string; role?: "admin" | "user" }
```

**Rule:** Use `z.infer` (output) for internal logic. Use `z.input` for form types, API request bodies, and anything representing data *before* parsing.

### "Type instantiation is excessively deep"

This occurs with complex nested schemas. Fixes:

```ts
// BAD — deep chain causes infinite type expansion
const DeepSchema = BaseSchema.extend({...}).merge({...}).pick({...}).partial();

// FIX 1: Break into intermediate types
const Step1 = BaseSchema.extend({ extra: z.string() });
type Step1 = z.infer<typeof Step1>;
const Step2 = Step1.pick({ extra: true });

// FIX 2: Annotate with explicit type
const Schema: z.ZodType<MyExplicitType> = z.object({...});

// FIX 3: Use satisfies to check without deep inference
const Schema = z.object({...}) satisfies z.ZodType<ExpectedShape>;
```

### Generic Schema Functions

```ts
// Wrong — T is not constrained
function validate<T>(schema: z.ZodSchema, data: unknown): T {
  return schema.parse(data); // Returns unknown, not T
}

// Correct — constrain with ZodType
function validate<T>(schema: z.ZodType<T>, data: unknown): T {
  return schema.parse(data); // Returns T
}

// Even better — preserve schema type for composition
function withDefaults<T extends z.ZodRawShape>(schema: z.ZodObject<T>) {
  return schema.extend({ id: z.string().uuid().default(crypto.randomUUID()) });
}
```

---

## Circular Reference Errors

### "ReferenceError: Cannot access before initialization"

```ts
// BAD — schema references itself before initialization
const NodeSchema = z.object({
  children: z.array(NodeSchema), // ReferenceError!
});

// FIX — use z.lazy
interface TreeNode { value: string; children: TreeNode[] }
const NodeSchema: z.ZodType<TreeNode> = z.object({
  value: z.string(),
  children: z.lazy(() => NodeSchema.array()),
});
```

### Mutual Recursion Between Files

```ts
// user-schema.ts
import { PostSchema } from "./post-schema";
export const UserSchema: z.ZodType<User> = z.object({
  posts: z.lazy(() => PostSchema.array()), // Must wrap in z.lazy
});

// post-schema.ts
import { UserSchema } from "./user-schema";
export const PostSchema: z.ZodType<Post> = z.object({
  author: z.lazy(() => UserSchema), // Must wrap in z.lazy
});
```

**Key rule:** Any cross-file schema reference in a recursive structure must use `z.lazy()` or you'll get circular import errors.

---

## Performance with Large Schemas

### Schema Definition Overhead

```ts
// BAD — creates new schema on every call
function validateUser(data: unknown) {
  const schema = z.object({ name: z.string(), email: z.string().email() });
  return schema.parse(data);
}

// GOOD — define once, reuse
const UserSchema = z.object({ name: z.string(), email: z.string().email() });
function validateUser(data: unknown) {
  return UserSchema.parse(data);
}
```

### Union Performance

```ts
// BAD — union tries each schema in order: O(n) worst case
const EventSchema = z.union([
  z.object({ type: z.literal("a"), ...manyFields }),
  z.object({ type: z.literal("b"), ...manyFields }),
  z.object({ type: z.literal("c"), ...manyFields }),
  // ... 20+ variants
]);

// GOOD — discriminatedUnion uses discriminator key: O(1)
const EventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("a"), ...manyFields }),
  z.object({ type: z.literal("b"), ...manyFields }),
  z.object({ type: z.literal("c"), ...manyFields }),
]);
```

### Avoiding Redundant Parsing

```ts
// BAD — parses entire schema just to check one field
if (FullSchema.safeParse(data).success) {
  const typed = FullSchema.parse(data); // Double parse!
}

// GOOD — parse once, use result
const result = FullSchema.safeParse(data);
if (result.success) {
  doSomething(result.data);
}
```

### Hot Path Optimization

```ts
// For extremely hot paths, consider pre-checking before Zod
function validateHotPath(input: unknown) {
  // Quick type check before full schema validation
  if (typeof input !== "object" || input === null) return null;
  if (!("type" in input) || typeof (input as any).type !== "string") return null;
  // Full validation only for plausible inputs
  return EventSchema.safeParse(input);
}
```

---

## ESM/CJS Module Issues

### "ERR_REQUIRE_ESM" or "Must use import"

```jsonc
// tsconfig.json — ensure module resolution matches
{
  "compilerOptions": {
    "module": "ESNext",        // or "Node16" / "NodeNext"
    "moduleResolution": "bundler" // or "Node16" / "NodeNext"
  }
}
```

### Dual Package Hazard

If Zod is loaded as both ESM and CJS (e.g., in a monorepo), `instanceof z.ZodError` may fail because there are two different `ZodError` classes.

```ts
// FIX — check by name instead of instanceof
function isZodError(err: unknown): err is z.ZodError {
  return err instanceof Error && err.name === "ZodError";
}
```

### Next.js / Turbopack Issues

```ts
// If "zod" import fails in edge runtime or server components:
// 1. Check zod is in dependencies, not devDependencies
// 2. Use explicit import path for Zod 4:
import { z } from "zod/v4";
// 3. Ensure serverExternalPackages doesn't exclude zod in next.config.js
```

---

## Bundle Size Optimization

### Tree-Shaking (Zod 4)

```ts
// Zod 3: everything imported (no tree-shaking)
import { z } from "zod"; // ~13KB gzipped

// Zod 4: use @zod/mini for minimal bundle
import { z } from "@zod/mini"; // ~1.9KB gzipped

// @zod/mini differences:
// - No .describe(), .brand(), .catch()
// - Error messages via functions only: z.string(err => "must be string")
// - Use z.string().check(z.minLength(3)) instead of z.string().min(3)
```

### Lazy Loading Schemas

```ts
// For admin-only schemas, lazy load to reduce initial bundle
const AdminSchemas = {
  get userManagement() {
    return import("./schemas/admin").then((m) => m.UserManagementSchema);
  },
};
```

### Analyzing Bundle Impact

```bash
# Check Zod's contribution to bundle
npx source-map-explorer dist/main.js
# or
npx @next/bundle-analyzer
```

---

## Error Formatting Gotchas

### flatten() vs format() vs issues

```ts
const result = schema.safeParse(badData);
if (!result.success) {
  // .issues — raw ZodIssue array, full detail
  result.error.issues;
  // [{ code: "too_small", minimum: 1, path: ["name"], message: "..." }]

  // .flatten() — simple field → messages mapping (loses nested paths)
  result.error.flatten();
  // { formErrors: ["top-level error"], fieldErrors: { name: ["msg"], email: ["msg"] } }

  // .format() — nested object matching schema shape
  result.error.format();
  // { name: { _errors: ["msg"] }, address: { city: { _errors: ["msg"] } } }
}
```

**Pitfall:** `.flatten()` drops nested paths. For `path: ["address", "city"]`, flatten puts the error under `"address"`, not `"address.city"`.

```ts
// For nested forms, use format() or build custom flattener:
function deepFlatten(error: z.ZodError): Record<string, string[]> {
  const result: Record<string, string[]> = {};
  for (const issue of error.issues) {
    const key = issue.path.join(".");
    (result[key] ??= []).push(issue.message);
  }
  return result;
}
// { "address.city": ["Required"], "items.0.quantity": ["Too small"] }
```

### Custom Error Messages Ignored

```ts
// BAD — message param doesn't work on chained validators the way you'd expect
z.string().email().min(5, "Too short");
// If input is not a string at all, the email() message won't appear — invalid_type fires first

// The validation chain short-circuits: type check → format checks → refinements
// To customize the type error:
z.string({ invalid_type_error: "Must be text" }).email("Invalid email").min(5, "Too short");
```

---

## Async Validation Pitfalls

### Forgetting parseAsync

```ts
const schema = z.string().refine(async (val) => {
  return await checkDatabase(val);
});

// BAD — silently returns a Promise<boolean> as truthy (always passes!)
schema.safeParse("test"); // Always succeeds — refine got a Promise object (truthy)

// GOOD — must use async parse
await schema.safeParseAsync("test");
```

**Rule:** If *any* refinement or transform in the schema chain is async, you *must* use `parseAsync` / `safeParseAsync`. Zod does not warn you.

### Async in superRefine

```ts
const schema = z.object({
  username: z.string(),
  email: z.string().email(),
}).superRefine(async (data, ctx) => {
  // These run sequentially — consider Promise.all for parallel checks
  const [userExists, emailExists] = await Promise.all([
    checkUsername(data.username),
    checkEmail(data.email),
  ]);

  if (userExists) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Username taken", path: ["username"] });
  if (emailExists) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Email taken", path: ["email"] });
});
```

### Async Transform Ordering

```ts
// Transforms run in chain order — async transforms must maintain order
const schema = z.string()
  .transform(async (val) => {
    const user = await lookupUser(val);
    return user;
  })
  .refine((user) => user.isActive, "User is inactive");
// This works: transform resolves first, then refine checks the result
// But MUST use safeParseAsync
```

---

## Transform Breaking Refine

### Ordering Matters: refine → transform → refine

```ts
// BAD — refine after transform receives transformed type
z.string()
  .transform((s) => parseInt(s, 10))
  .refine((s) => s.length > 0); // Error! s is number, not string

// The chain works as a pipeline:
// 1. z.string() validates input is string
// 2. .transform() converts string → number
// 3. .refine() receives number (not string!)

// GOOD — put string refinements before transform
z.string()
  .min(1)                          // validates string
  .transform((s) => parseInt(s, 10)) // converts to number
  .refine((n) => !isNaN(n))        // validates number
  .refine((n) => n > 0);           // validates number
```

### Transform + safeParse Type Confusion

```ts
const schema = z.string().transform((s) => s.length);

const result = schema.safeParse("hello");
if (result.success) {
  // result.data is number (5), NOT string
  // z.infer<typeof schema> = number
  // z.input<typeof schema> = string
}
```

---

## Coercion Edge Cases

### z.coerce.boolean() Truthy Trap

```ts
z.coerce.boolean().parse("false"); // => true! ("false" is a truthy string)
z.coerce.boolean().parse("");       // => false (empty string is falsy)
z.coerce.boolean().parse(0);        // => false
z.coerce.boolean().parse("0");      // => true! ("0" is a truthy string)

// FIX — use manual transform or Zod 4's z.stringbool()
const StringBool = z.enum(["true", "false", "1", "0"]).transform((v) => v === "true" || v === "1");

// Zod 4:
// z.stringbool() — handles "true"/"false"/"1"/"0"/"yes"/"no"
```

### z.coerce.number() with Empty Strings

```ts
z.coerce.number().parse("");  // => 0 (Number("") === 0, passes validation!)

// FIX — preprocess to catch empty strings
const SafeNumber = z.preprocess(
  (val) => (val === "" ? undefined : val),
  z.coerce.number()
);

// Or use pipe
const SafeNumber2 = z.string().min(1, "Required").pipe(z.coerce.number());
```

### z.coerce.date() Gotchas

```ts
z.coerce.date().parse(null);        // => new Date(null) => Date(0) => 1970-01-01 — valid!
z.coerce.date().parse(undefined);   // => new Date(undefined) => Invalid Date — fails
z.coerce.date().parse(true);        // => new Date(true) => new Date(1) — valid!

// FIX — validate the string/number before coercing
const SafeDate = z.union([
  z.string().datetime(),
  z.string().date(),
]).pipe(z.coerce.date());
```

---

## Zod 3 to 4 Migration Issues

### Import Path Changes

```ts
// Zod 3
import { z } from "zod";

// Zod 4 — both work during transition
import { z } from "zod";      // v4 API when zod@4 installed
import { z } from "zod/v4";   // explicit v4 import
import { z } from "zod/v3";   // compatibility import for gradual migration
```

### Error Handling Changes

```ts
// Zod 3 — multiple error config keys
z.string({
  required_error: "Required",
  invalid_type_error: "Not a string",
});

// Zod 4 — unified error parameter
z.string({ error: "Must be a string" });
z.string({ error: (issue) => `Got ${issue.input}, expected string` });
```

### New Built-in Validators

```ts
// Zod 3 — string method
z.string().email()
z.string().uuid()

// Zod 4 — also available as top-level
z.email()    // shorthand for z.string().email()
z.uuid()     // shorthand for z.string().uuid()
z.url()      // shorthand for z.string().url()
z.ip()
```

### .toJSONSchema() (New in Zod 4)

```ts
// Zod 3 — required zod-to-json-schema third-party library
import { zodToJsonSchema } from "zod-to-json-schema";
const jsonSchema = zodToJsonSchema(MySchema);

// Zod 4 — native
const jsonSchema = z.toJSONSchema(MySchema);
```

### Key Breaking Changes Checklist

| Zod 3 | Zod 4 | Action |
|--------|--------|--------|
| `z.ZodType<T>` for recursive | Often unnecessary | Remove if not needed |
| `required_error` / `invalid_type_error` | `error` (unified) | Update error configs |
| `zod-to-json-schema` | `.toJSONSchema()` | Remove dep, use native |
| No tree-shaking | `@zod/mini` available | Consider for bundle size |
| `.describe()` | Still available (not in mini) | Check if using mini |
| `z.preprocess()` | Prefer `z.pipe()` | Migrate preprocessors |

### Running the Codemod

```bash
# Official Zod 4 codemod for automated migration
npx @zod/codemod
# Handles: import paths, error config, deprecated APIs
# Manual review still needed for: custom error maps, edge cases, z.preprocess → z.pipe
```
