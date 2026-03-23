---
name: zod-validation
description:
  positive: "Use when user validates data with Zod, asks about Zod schemas, z.object, z.array, z.enum, z.union, z.discriminatedUnion, .transform, .refine, .superRefine, Zod error handling, or Zod integration with React Hook Form, tRPC, or Next.js server actions."
  negative: "Do NOT use for Joi, Yup, io-ts, or other validation libraries. Do NOT use for general TypeScript types without Zod."
---

# Zod Schema Validation

## Schema Primitives

Use Zod primitives as building blocks for all schemas.

```ts
import { z } from "zod";

z.string();    z.number();    z.boolean();    z.bigint();
z.date();      z.undefined(); z.null();       z.void();
z.any();       z.unknown();   z.never();

z.enum(["admin", "user", "guest"]); // string literal union
z.nativeEnum(MyTsEnum);             // use existing TS enum
z.literal("active");                 // literal type
```

## String Validators

Chain validators on `z.string()`. Each returns a new schema.

```ts
z.string().min(1, "Required")        // non-empty
z.string().max(255)
z.string().length(5)
z.string().email("Invalid email")
z.string().url()
z.string().uuid()
z.string().cuid()
z.string().ulid()
z.string().regex(/^[A-Z]{3}-\d{4}$/, "Invalid format")
z.string().trim()                    // strip whitespace before validation
z.string().toLowerCase()
z.string().toUpperCase()
z.string().datetime()                // ISO 8601
z.string().ip()                      // IPv4 or IPv6
z.string().startsWith("https://")
z.string().endsWith(".com")
z.string().includes("@")
```

## Number Validators

```ts
z.number().int()           z.number().positive()
z.number().nonnegative()   z.number().min(0).max(100)
z.number().multipleOf(5)   z.number().finite()
z.number().safe()          // Number.MIN_SAFE_INTEGER..MAX_SAFE_INTEGER
```

## Object Schemas

```ts
const userSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1),
  email: z.string().email(),
  age: z.number().int().positive().optional(),
});

// Shape manipulation
userSchema.pick({ name: true, email: true });   // keep only listed keys
userSchema.omit({ id: true });                   // drop listed keys
userSchema.partial();                            // all fields optional
userSchema.required();                           // all fields required
userSchema.deepPartial();                        // recursive partial

// Extend and merge
const adminSchema = userSchema.extend({
  role: z.literal("admin"),
  permissions: z.array(z.string()),
});

const merged = schemaA.merge(schemaB);           // combine two object schemas

// Unknown keys
userSchema.strict();                  // error on unknown keys
userSchema.passthrough();             // keep unknown keys
userSchema.strip();                   // remove unknown keys (default)

// Key-value records
z.record(z.string(), z.number());     // Record<string, number>
```

## Array and Tuple Schemas

```ts
z.array(z.string());                  // string[]
z.array(z.string()).nonempty();       // [string, ...string[]]
z.array(z.number()).min(1).max(10);

// Tuples — fixed-length arrays with per-position types
z.tuple([z.string(), z.number()]);                     // [string, number]
z.tuple([z.string(), z.number()]).rest(z.boolean());   // [string, number, ...boolean[]]
```

## Union Types

```ts
// Standard union — tries each schema in order
z.union([z.string(), z.number()]);

// Discriminated union — fast lookup on a discriminator key
const eventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("click"), x: z.number(), y: z.number() }),
  z.object({ type: z.literal("scroll"), offset: z.number() }),
  z.object({ type: z.literal("keypress"), key: z.string() }),
]);

// Intersection — combine two schemas (both must match)
z.intersection(z.object({ a: z.string() }), z.object({ b: z.number() }));
// Shorthand:
z.object({ a: z.string() }).and(z.object({ b: z.number() }));
```

Prefer `z.discriminatedUnion` over `z.union` for tagged objects — it gives better error messages and performance.

## Nullable, Optional, and Defaults

```ts
z.string().optional();                // string | undefined
z.string().nullable();                // string | null
z.string().nullish();                 // string | null | undefined
z.string().default("fallback");       // fills in if undefined
z.string().catch("fallback");         // fills in if validation fails
```

## Transforms

Use `.transform()` to reshape data after validation. Use `.preprocess()` to coerce before.

```ts
const emailSchema = z.string().email().transform(v => v.toLowerCase().trim());

// Coerce string to number
const coercedNumber = z.preprocess(
  (val) => (typeof val === "string" ? Number(val) : val), z.number()
);

// Built-in coercion (simpler)
z.coerce.number();   z.coerce.boolean();  z.coerce.date();
z.coerce.string();   z.coerce.bigint();

// Pipeline — chain schema -> transform -> schema
const percentSchema = z.string()
  .transform(v => parseFloat(v))
  .pipe(z.number().min(0).max(100));

// Multi-step transform
const idSchema = z.number()
  .transform(n => n.toString())
  .transform(s => s.padStart(6, "0"));
```

## Refinements

Use `.refine()` for simple checks. Use `.superRefine()` for cross-field validation, multiple errors, or custom paths.

```ts
// Simple refinement
const adultAge = z.number().refine(n => n >= 18, {
  message: "Must be 18 or older",
});

// Async refinement
const uniqueEmail = z.string().email().refine(
  async (email) => !(await db.users.exists({ email })),
  { message: "Email already registered" }
);

// superRefine — full control over error reporting
const signupSchema = z.object({
  password: z.string().min(8),
  confirmPassword: z.string(),
}).superRefine((data, ctx) => {
  if (data.password !== data.confirmPassword) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Passwords do not match",
      path: ["confirmPassword"],
    });
  }
});

// Multiple issues in one pass
const complexSchema = z.string().superRefine((val, ctx) => {
  if (val.length < 8) {
    ctx.addIssue({
      code: z.ZodIssueCode.too_small,
      minimum: 8,
      type: "string",
      inclusive: true,
      message: "At least 8 characters",
    });
  }
  if (!/[A-Z]/.test(val)) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Must contain an uppercase letter",
    });
  }
});
```

## Type Inference

Derive TypeScript types from schemas. Never duplicate types manually.

```ts
const userSchema = z.object({
  id: z.string().uuid(),
  name: z.string(),
  createdAt: z.string().datetime().transform(v => new Date(v)),
});

type UserInput = z.input<typeof userSchema>;   // before transforms
type UserOutput = z.output<typeof userSchema>; // after transforms
type User = z.infer<typeof userSchema>;        // alias for z.output
```

## Error Handling

Prefer `.safeParse()` for untrusted data. Use `.parse()` only when errors should throw.

```ts
const result = schema.safeParse(data);

if (!result.success) {
  // Flat field-level errors — ideal for forms
  const flat = result.error.flatten();
  // { formErrors: string[], fieldErrors: { name?: string[], email?: string[] } }

  // Nested tree — useful for deeply nested schemas
  const formatted = result.error.format();
  // { name: { _errors: ["Required"] }, address: { zip: { _errors: [...] } } }

  // Raw issues array
  result.error.issues;
  // [{ code, path, message, ... }]
}

// Custom error map — global default messages
const customErrorMap: z.ZodErrorMap = (issue, ctx) => {
  if (issue.code === z.ZodIssueCode.invalid_type) {
    if (issue.expected === "string") return { message: "Must be text" };
  }
  return { message: ctx.defaultError };
};
z.setErrorMap(customErrorMap);
```

## Recursive and Lazy Schemas

```ts
interface Category {
  name: string;
  subcategories: Category[];
}

const categorySchema: z.ZodType<Category> = z.object({
  name: z.string(),
  subcategories: z.lazy(() => z.array(categorySchema)),
});
```

## Branded Types

Use `.brand()` to create nominal types that prevent accidental mixing.

```ts
const UserId = z.string().uuid().brand<"UserId">();
const OrderId = z.string().uuid().brand<"OrderId">();

type UserId = z.infer<typeof UserId>;    // string & { __brand: "UserId" }
type OrderId = z.infer<typeof OrderId>;

function getUser(id: UserId) { /* ... */ }

const uid = UserId.parse("550e8400-e29b-41d4-a716-446655440000");
getUser(uid);       // OK
// getUser(orderId) // compile error — branded types are incompatible
```

## Integration: React Hook Form

Share the same Zod schema on client and server.

```ts
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";

const contactSchema = z.object({
  name: z.string().min(2, "Name too short"),
  email: z.string().email(),
  message: z.string().min(10),
});
type ContactForm = z.infer<typeof contactSchema>;

function ContactPage() {
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<ContactForm>({ resolver: zodResolver(contactSchema) });

  return (
    <form onSubmit={handleSubmit(onSubmit)}>
      <input {...register("name")} />
      {errors.name && <span>{errors.name.message}</span>}
      <input {...register("email")} />
      {errors.email && <span>{errors.email.message}</span>}
      <textarea {...register("message")} />
      {errors.message && <span>{errors.message.message}</span>}
      <button type="submit">Send</button>
    </form>
  );
}
```

Install: `npm install @hookform/resolvers zod`.

## Integration: Next.js Server Actions

Re-validate on the server with the same schema. Return structured errors.

```ts
// lib/schemas.ts — shared
export const contactSchema = z.object({
  name: z.string().min(2),
  email: z.string().email(),
  message: z.string().min(10),
});

// app/actions.ts
"use server";
import { contactSchema } from "@/lib/schemas";

export async function submitContact(formData: unknown) {
  const result = contactSchema.safeParse(formData);
  if (!result.success) {
    return { ok: false as const, errors: result.error.flatten().fieldErrors };
  }
  await db.contacts.create({ data: result.data });
  return { ok: true as const };
}
```

## Integration: tRPC

Define input schemas on procedures. tRPC validates automatically.

```ts
import { initTRPC } from "@trpc/server";

const t = initTRPC.create();

const appRouter = t.router({
  createUser: t.procedure
    .input(z.object({
      name: z.string().min(1),
      email: z.string().email(),
    }))
    .mutation(async ({ input }) => {
      // input is fully typed — { name: string; email: string }
      return db.users.create({ data: input });
    }),

  getUser: t.procedure
    .input(z.object({ id: z.string().uuid() }))
    .query(async ({ input }) => {
      return db.users.findUnique({ where: { id: input.id } });
    }),
});
```

## API Request/Response Validation Middleware

Validate at application boundaries. Trust types internally after parsing.

```ts
// Express middleware
import { z, ZodSchema } from "zod";
import type { Request, Response, NextFunction } from "express";

function validate(schema: ZodSchema) {
  return (req: Request, res: Response, next: NextFunction) => {
    const result = schema.safeParse(req.body);
    if (!result.success) return res.status(400).json({ errors: result.error.flatten().fieldErrors });
    req.body = result.data;
    next();
  };
}

const createUserBody = z.object({ name: z.string().min(1), email: z.string().email() });
app.post("/users", validate(createUserBody), (req, res) => { /* req.body is validated */ });
```

## Schema Composition Patterns

Build domain schemas from reusable atoms.

```ts
// Base schemas
const id = z.string().uuid();
const timestamps = z.object({
  createdAt: z.coerce.date(),
  updatedAt: z.coerce.date(),
});

// Compose
const userSchema = z.object({ id, name: z.string(), email: z.string().email() }).merge(timestamps);
const createUserSchema = userSchema.omit({ id: true, createdAt: true, updatedAt: true });
const updateUserSchema = createUserSchema.partial();

// Factory for CRUD schemas
function crudSchemas<T extends z.ZodRawShape>(base: z.ZodObject<T>) {
  return {
    full: base.merge(z.object({ id }).merge(timestamps)),
    create: base,
    update: base.partial(),
  };
}
```

## Common Patterns

### Environment Variables

```ts
const envSchema = z.object({
  DATABASE_URL: z.string().url(),
  PORT: z.coerce.number().default(3000),
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),
  API_KEY: z.string().min(1),
});

export const env = envSchema.parse(process.env);
```

Validate at startup. Crash early on missing config.

### Form Schemas with Conditional Fields

```ts
const paymentSchema = z.discriminatedUnion("method", [
  z.object({
    method: z.literal("credit_card"),
    cardNumber: z.string().regex(/^\d{16}$/),
    cvv: z.string().regex(/^\d{3,4}$/),
  }),
  z.object({
    method: z.literal("bank_transfer"),
    iban: z.string().min(15).max(34),
  }),
  z.object({
    method: z.literal("paypal"),
    paypalEmail: z.string().email(),
  }),
]);
```

### Date Range Validation

```ts
const dateRange = z.object({
  startDate: z.coerce.date(),
  endDate: z.coerce.date(),
}).refine(d => d.endDate > d.startDate, {
  message: "End date must be after start date",
  path: ["endDate"],
});
```

## Anti-Patterns

- **Duplicating types alongside schemas.** Use `z.infer` instead.
- **Calling `.parse()` in hot loops.** Define schemas once at module level.
- **Recreating schemas on every render.** Declare outside React components.
- **Using `z.any()` as a shortcut.** Be specific — loose schemas defeat the purpose.
- **Skipping server-side validation.** Client validation is UX-only; always re-validate server-side.
- **Over-nesting `.refine()`.** Use `.superRefine()` for multiple issues or cross-field logic.
- **Ignoring `.strict()` on API inputs.** Unknown keys can hide bugs or injection attacks.

## Performance Tips

- Define schemas at module scope — construction is the expensive part.
- Use `z.discriminatedUnion` over `z.union` for tagged objects (O(1) vs O(n)).
- Prefer `.safeParse()` over `.parse()` + try/catch — avoids stack trace overhead.
- Use `z.lazy()` only for truly recursive types — it defers compilation.
- Validate arrays with `z.array(schema)`, not per-element `.parse()` calls.
- Strip deeply nested optional chains — each adds validation overhead.
