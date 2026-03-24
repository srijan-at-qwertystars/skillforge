---
name: zod-validation
description: >
  USE when writing Zod schemas, TypeScript runtime validation, schema-based parsing, z.object, z.string, z.infer,
  safeParse, zodResolver, form validation with Zod, tRPC input validation, env validation with Zod, coercion,
  discriminated unions, branded types, Zod error handling, ZodError, Zod transforms, Zod refinements, z.coerce,
  z.lazy recursive types, Zod + React Hook Form, Zod + Next.js server actions, API request/response validation,
  schema composition with extend/merge/pick/omit/partial. DO NOT USE for Yup, Joi, Valibot, ArkType, io-ts,
  class-validator, or non-Zod validation libraries. DO NOT USE for JSON Schema authoring without Zod.
---

# Zod Validation — TypeScript-First Schema Declaration & Parsing

## Philosophy

Zod follows "parse, don't validate." Every schema is a parser that transforms unknown input into typed output. Never assert types—parse at system boundaries and propagate typed data inward. Zod infers static TypeScript types from runtime schemas, eliminating type/validation drift. One schema = one source of truth for both runtime checks and compile-time types.

```ts
import { z } from "zod";
// Zod 4: also available as `import { z } from "zod/v4";`
```

## Primitives

```ts
z.string()    z.number()    z.boolean()    z.date()
z.bigint()    z.undefined() z.null()       z.void()
z.any()       z.unknown()   z.never()      z.nan()
z.symbol()    z.literal("exact")           z.literal(42)
```

Use `z.unknown()` over `z.any()` — it forces narrowing before use.

## String Validators

```ts
z.string().email()              // RFC-compliant email
z.string().url()                // valid URL
z.string().uuid()               // UUID v4
z.string().cuid()               // CUID
z.string().cuid2()              // CUID2
z.string().ulid()               // ULID
z.string().regex(/^[A-Z]+$/)   // custom regex
z.string().min(1)               // non-empty (prefer .min(1) over .nonempty())
z.string().max(255)             // max length
z.string().length(10)           // exact length
z.string().trim()               // trim whitespace before validation
z.string().toLowerCase()        // coerce to lowercase
z.string().toUpperCase()        // coerce to uppercase
z.string().startsWith("https")
z.string().endsWith(".com")
z.string().includes("@")
z.string().datetime()           // ISO 8601 datetime
z.string().ip()                 // IPv4 or IPv6
z.string().emoji()
```

Chain validators: `z.string().trim().toLowerCase().email().max(254)`.

## Number Validators

```ts
z.number().int()                // integer only
z.number().positive()           // > 0
z.number().nonnegative()        // >= 0
z.number().negative()           // < 0
z.number().min(1)               // alias: .gte(1)
z.number().max(100)             // alias: .lte(100)
z.number().gt(0)                // exclusive lower bound
z.number().lt(100)              // exclusive upper bound
z.number().multipleOf(5)        // divisible by 5
z.number().finite()             // excludes Infinity
z.number().safe()               // Number.MIN_SAFE_INTEGER..MAX_SAFE_INTEGER
```

## Objects

```ts
const UserSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1),
  email: z.string().email(),
  age: z.number().int().positive().optional(),
});
type User = z.infer<typeof UserSchema>; // { id: string; name: string; email: string; age?: number }

// Access shape
UserSchema.shape.email; // => z.ZodString

// Derive key union type
UserSchema.keyof(); // => z.ZodEnum<["id", "name", "email", "age"]>
```

### Object Manipulation

```ts
// Extend — add fields
const AdminSchema = UserSchema.extend({ role: z.literal("admin") });

// Merge — combine two object schemas (second wins on conflict)
const merged = SchemaA.merge(SchemaB);

// Pick / Omit — select or exclude fields
const LoginSchema = UserSchema.pick({ email: true });
const PublicUser = UserSchema.omit({ email: true });

// Partial / Required
UserSchema.partial();                    // all fields optional
UserSchema.partial({ name: true });      // only name optional
UserSchema.required();                   // all fields required
UserSchema.deepPartial();               // recursive partial

// Unknown key handling
UserSchema.passthrough();  // allow and preserve unknown keys
UserSchema.strict();       // reject unknown keys (throws)
UserSchema.strip();        // silently remove unknown keys (default)

// Catchall — type for unknown keys
UserSchema.catchall(z.string());
```

## Arrays

```ts
z.array(z.string())                // string[]
z.string().array()                 // equivalent shorthand
z.array(z.number()).nonempty()     // [number, ...number[]]
z.array(z.string()).min(1)         // at least 1 element
z.array(z.string()).max(10)        // at most 10
z.array(z.string()).length(3)      // exactly 3

// Access element schema
const arr = z.array(z.string());
arr.element; // => z.ZodString
```

## Unions & Intersections

```ts
z.union([z.string(), z.number()])   // value matches any member
z.string().or(z.number())           // shorthand

// Discriminated union — O(1) lookup via shared discriminator key
const EventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("click"), x: z.number(), y: z.number() }),
  z.object({ type: z.literal("keypress"), key: z.string() }),
]);
// { type: "hover" } => error: "Invalid discriminator value"

z.intersection(SchemaA, SchemaB)    // value must match all members
```

Prefer `discriminatedUnion` over `union` for tagged objects — O(1) vs O(n) trial parsing.

## Tuples, Records, Maps, Sets

```ts
z.tuple([z.string(), z.number(), z.boolean()])  // fixed-length typed array
z.tuple([z.string()]).rest(z.number())           // ["hello", 1, 2, 3] => valid

z.record(z.string())                     // Record<string, string>
z.record(z.string(), z.number())         // Record<string, number>
z.record(z.enum(["a", "b"]), z.number()) // { a: number; b: number }

z.map(z.string(), z.number())
z.set(z.string()).min(1).max(10)
```

## Enums

```ts
const StatusEnum = z.enum(["active", "inactive", "pending"]);
type Status = z.infer<typeof StatusEnum>; // "active" | "inactive" | "pending"
StatusEnum.enum.active;  // autocomplete-friendly access
StatusEnum.options;      // ["active", "inactive", "pending"]

// Native TypeScript enum
enum Direction { Up = "UP", Down = "DOWN" }
z.nativeEnum(Direction)

// Const object as enum
const ROLES = { Admin: "admin", User: "user" } as const;
z.nativeEnum(ROLES)
```

## Type Inference

```ts
type ApiResponse = z.infer<typeof ResponseSchema>;  // output type (after transforms)
type ApiInput = z.input<typeof ResponseSchema>;      // input type (before transforms)
```

Always derive types from schemas with `z.infer` — never duplicate type definitions.

## Transforms

```ts
const trimmed = z.string().transform((s) => s.trim());          // "  hello  " => "hello"
const toNum = z.string().transform((s) => parseInt(s, 10));     // type: number

z.string().default("N/A")      // fallback when undefined
z.number().catch(0)             // fallback on any parse error
z.preprocess((v) => String(v), z.string())  // transform BEFORE parsing

// Pipe — chain schemas: validate with first, feed output into second
z.string().pipe(z.coerce.number().int().positive())
// "42" => validates string, then coerces to number, then checks positive int
```

## Coercion

Use `z.coerce.*` to auto-convert input types. Applies the type constructor before validation.

```ts
z.coerce.string()   // String(input) — then validate
z.coerce.number()   // Number(input) — "42" => 42, "abc" => NaN (fails)
z.coerce.boolean()  // Boolean(input) — "false" => true (truthy string!)
z.coerce.bigint()   // BigInt(input)
z.coerce.date()     // new Date(input)
```

**Warning:** `z.coerce.boolean()` uses JavaScript truthiness — `"false"` coerces to `true`. For string booleans, use a transform or Zod 4's `z.stringbool()`.

## Refinements

```ts
// Simple refinement — custom predicate
const even = z.number().refine((n) => n % 2 === 0, {
  message: "Must be even",
});

// Refinement with path (for objects)
const PasswordSchema = z.object({
  password: z.string().min(8),
  confirm: z.string(),
}).refine((data) => data.password === data.confirm, {
  message: "Passwords don't match",
  path: ["confirm"], // attach error to confirm field
});

// superRefine — add multiple issues, control flow
const UniqueList = z.array(z.string()).superRefine((items, ctx) => {
  const seen = new Set<string>();
  for (let i = 0; i < items.length; i++) {
    if (seen.has(items[i])) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `Duplicate at index ${i}: "${items[i]}"`,
        path: [i],
      });
    }
    seen.add(items[i]);
  }
});
// Input: ["a", "b", "a"] => ZodError with path [2]

// Abort early in superRefine
ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Fatal", fatal: true });
return z.NEVER; // signals TypeScript that subsequent code is unreachable
```

## Error Handling

```ts
// safeParse never throws — prefer in production
const result = schema.safeParse(data);
if (result.success) {
  result.data; // fully typed
} else {
  result.error.issues;                    // ZodIssue[]
  result.error.format();                  // nested object matching schema shape
  result.error.flatten().fieldErrors;     // { fieldName: ["error msg"] }
}

// parse throws ZodError on failure
try { schema.parse(data); }
catch (e) { if (e instanceof z.ZodError) console.log(e.flatten()); }
```

### Custom Error Maps

```ts
z.string({ required_error: "Required", invalid_type_error: "Must be string" })
z.string().min(3, { message: "At least 3 chars" })

// Global error map — i18n or app-wide formatting
z.setErrorMap((issue, ctx) => {
  if (issue.code === z.ZodIssueCode.invalid_type)
    return { message: `Expected ${issue.expected}, got ${issue.received}` };
  return { message: ctx.defaultError };
});
```

## Async Validation

```ts
const UniqueEmail = z.string().email().refine(
  async (email) => !(await db.user.findByEmail(email)),
  { message: "Email already taken" }
);
const result = await UniqueEmail.safeParseAsync("user@example.com");
```

Always use `parseAsync`/`safeParseAsync` when schema contains async refinements or transforms.

## Recursive Types

```ts
interface Category { name: string; children: Category[] }
const CategorySchema: z.ZodType<Category> = z.object({
  name: z.string(),
  children: z.lazy(() => CategorySchema.array()),
});

// JSON type
type Json = string | number | boolean | null | Json[] | { [k: string]: Json };
const JsonSchema: z.ZodType<Json> = z.lazy(() =>
  z.union([z.string(), z.number(), z.boolean(), z.null(), z.array(JsonSchema), z.record(JsonSchema)])
);
```

Annotate with `z.ZodType<T>` for recursive type inference.

## Branded Types

```ts
const UserId = z.string().uuid().brand<"UserId">();
const OrderId = z.string().uuid().brand<"OrderId">();
type UserId = z.infer<typeof UserId>;   // string & { __brand: "UserId" }

function getUser(id: UserId) { /* ... */ }
// getUser(orderId) => compile error — brands don't match
// getUser(UserId.parse("...")) => OK
```

## Optional / Nullable

```ts
z.string().optional()   // string | undefined
z.string().nullable()   // string | null
z.string().nullish()    // string | null | undefined
z.string().optional().unwrap() // => z.ZodString
```

## Framework Integration

### React Hook Form + Zod

```ts
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";

const FormSchema = z.object({
  email: z.string().email(),
  age: z.coerce.number().int().positive(),
});
type FormData = z.infer<typeof FormSchema>;

function MyForm() {
  const { register, handleSubmit, formState: { errors } } = useForm<FormData>({
    resolver: zodResolver(FormSchema),
  });
  // errors.email?.message, errors.age?.message are typed and populated by Zod
}
```

Install: `npm install @hookform/resolvers zod`

### tRPC Input Validation

```ts
const appRouter = router({
  createUser: publicProcedure
    .input(z.object({
      name: z.string().min(1),
      email: z.string().email(),
    }))
    .mutation(async ({ input }) => {
      // input is fully typed: { name: string; email: string }
      return db.user.create({ data: input });
    }),
});
```

### Next.js Server Actions

```ts
"use server";
const ActionSchema = z.object({
  title: z.string().min(1).max(200),
  body: z.string().max(10000),
});

export async function createPost(formData: FormData) {
  const result = ActionSchema.safeParse({
    title: formData.get("title"),
    body: formData.get("body"),
  });
  if (!result.success) return { errors: result.error.flatten().fieldErrors };
  await db.post.create({ data: result.data });
  return { success: true };
}
```

### Conform (progressive enhancement forms)

```ts
import { parseWithZod } from "@conform-to/zod";
const submission = parseWithZod(formData, { schema: FormSchema });
if (submission.status !== "success") return submission.reply();
```

## Common Patterns

### Environment Variable Validation

```ts
const EnvSchema = z.object({
  DATABASE_URL: z.string().url(),
  PORT: z.coerce.number().int().default(3000),
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),
  API_KEY: z.string().min(1),
  REDIS_URL: z.string().url().optional(),
});
export const env = EnvSchema.parse(process.env);
// Throws at startup if env is invalid — fail fast
```

### API Request / Response Validation

```ts
const CreateOrderRequest = z.object({
  items: z.array(z.object({
    productId: z.string().uuid(),
    quantity: z.number().int().positive().max(999),
  })).nonempty(),
  couponCode: z.string().toUpperCase().optional(),
});

// External API — passthrough allows unknown fields
const ApiResponse = z.object({
  results: z.array(z.object({ id: z.number(), title: z.string() })),
  next: z.string().url().nullable(),
}).passthrough();
```

### Form Validation with Cross-Field Rules

```ts
const SignupSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8).regex(/[A-Z]/, "Need uppercase").regex(/[0-9]/, "Need digit"),
  confirmPassword: z.string(),
  birthDate: z.coerce.date().max(new Date(), "Cannot be in the future"),
  terms: z.literal(true, { errorMap: () => ({ message: "Must accept terms" }) }),
}).refine((d) => d.password === d.confirmPassword, {
  message: "Passwords must match",
  path: ["confirmPassword"],
});
```

## Zod 4 Changes (May 2025)

Key differences from Zod 3 — be aware when targeting Zod 4:

- **Performance:** 14x faster string parsing, 7x faster arrays, 6.5x faster objects.
- **Bundle size:** 2.3x smaller core; `@zod/mini` (~1.9KB gzipped) for tree-shaking.
- **Top-level format validators:** `z.email()`, `z.uuid()`, `z.url()`, `z.ip()` available directly.
- **`.toJSONSchema()`:** Native JSON Schema conversion — no third-party libs needed.
- **Unified `error` parameter:** Replaces `message`, `required_error`, `invalid_type_error`.
- **`z.stringbool()`:** Properly parses `"true"/"false"/"1"/"0"/"yes"/"no"`.
- **Simpler recursive types:** No more `z.ZodType<T>` annotation hacks for many cases.
- **Metadata & Registry:** Attach strongly-typed metadata to schemas; global schema registry.
- **Internationalized errors:** Built-in locale system for error message translation.

Migration: use the official Zod 4 codemod for automated updates from Zod 3.

## Performance Considerations

- Prefer `discriminatedUnion` over `union` for tagged objects — avoids trial parsing.
- Use `safeParse` over `parse` + try/catch — avoids exception overhead.
- Avoid `.refine()` when a built-in validator exists (e.g., use `.email()` not `.refine(isEmail)`).
- Place `.transform()` last in chains — validators run first, transforms after.
- For hot paths, consider `@zod/mini` (Zod 4) or Valibot for smaller bundle.
- Cache compiled schemas — define once at module level, not inside functions.
- `.passthrough()` is cheaper than `.strict()` — strict must enumerate and reject unknown keys.

## Comparison with Alternatives

| Feature | Zod | Yup | Joi | Valibot | ArkType |
|---|---|---|---|---|---|
| TypeScript-first | Yes | Partial | No | Yes | Yes |
| Type inference | `z.infer` | Limited | No | Yes | Yes |
| Bundle size (core) | ~13KB | ~16KB | ~30KB | ~1KB | ~6KB |
| Async validation | Yes | Yes | Yes | Yes | No |
| Tree-shaking | Zod 4 | No | No | Yes | Partial |
| Ecosystem/community | Largest | Large | Legacy | Growing | Small |
| Error messages | Customizable | Customizable | Customizable | Basic | Basic |

**Choose Zod** when: you need the largest ecosystem, best docs, first-class TypeScript inference, and integration with tRPC/React Hook Form/Next.js. **Consider Valibot** for bundle-critical apps. **Avoid Yup/Joi** in new TypeScript projects — they lack proper type inference.
