# Framework Recipes — Zod Integration Patterns

## Table of Contents

- [React Hook Form + Zod](#react-hook-form--zod)
- [Conform + Zod (Server Actions)](#conform--zod-server-actions)
- [tRPC Input Validation](#trpc-input-validation)
- [Next.js Server Actions](#nextjs-server-actions)
- [Remix Action Validation](#remix-action-validation)
- [Environment Validation (t3-env Pattern)](#environment-validation-t3-env-pattern)
- [API Route Validation Middleware](#api-route-validation-middleware)
- [Form Builder Patterns](#form-builder-patterns)
- [OpenAPI Schema Generation from Zod](#openapi-schema-generation-from-zod)

---

## React Hook Form + Zod

### Basic Setup

```bash
npm install react-hook-form @hookform/resolvers zod
```

```tsx
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";

const SignupSchema = z.object({
  name: z.string().min(2, "Name must be at least 2 characters"),
  email: z.string().email("Invalid email address"),
  age: z.coerce.number().int().positive("Age must be positive"),
  role: z.enum(["user", "admin"], { errorMap: () => ({ message: "Select a role" }) }),
});

type SignupForm = z.infer<typeof SignupSchema>;

export function SignupForm() {
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<SignupForm>({
    resolver: zodResolver(SignupSchema),
    defaultValues: { role: "user" },
  });

  const onSubmit = async (data: SignupForm) => {
    // data is fully typed and validated
    await createUser(data);
  };

  return (
    <form onSubmit={handleSubmit(onSubmit)}>
      <input {...register("name")} />
      {errors.name && <span>{errors.name.message}</span>}

      <input {...register("email")} />
      {errors.email && <span>{errors.email.message}</span>}

      <input type="number" {...register("age")} />
      {errors.age && <span>{errors.age.message}</span>}

      <select {...register("role")}>
        <option value="user">User</option>
        <option value="admin">Admin</option>
      </select>
      {errors.role && <span>{errors.role.message}</span>}

      <button type="submit" disabled={isSubmitting}>Sign Up</button>
    </form>
  );
}
```

### Dynamic Schema with Watch

```tsx
function DynamicForm() {
  const schema = z.object({
    accountType: z.enum(["personal", "business"]),
    companyName: z.string().optional(),
    taxId: z.string().optional(),
  }).superRefine((data, ctx) => {
    if (data.accountType === "business") {
      if (!data.companyName) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Required for business", path: ["companyName"] });
      if (!data.taxId) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Required for business", path: ["taxId"] });
    }
  });

  const { register, handleSubmit, watch, formState: { errors } } = useForm({
    resolver: zodResolver(schema),
  });

  const accountType = watch("accountType");

  return (
    <form onSubmit={handleSubmit(console.log)}>
      <select {...register("accountType")}>
        <option value="personal">Personal</option>
        <option value="business">Business</option>
      </select>
      {accountType === "business" && (
        <>
          <input {...register("companyName")} placeholder="Company Name" />
          {errors.companyName && <span>{errors.companyName.message}</span>}
          <input {...register("taxId")} placeholder="Tax ID" />
          {errors.taxId && <span>{errors.taxId.message}</span>}
        </>
      )}
      <button type="submit">Submit</button>
    </form>
  );
}
```

### Multi-Step Form with Shared Schema

```tsx
const FullSchema = z.object({
  // Step 1
  name: z.string().min(1),
  email: z.string().email(),
  // Step 2
  address: z.string().min(1),
  city: z.string().min(1),
  zipCode: z.string().regex(/^\d{5}$/),
  // Step 3
  cardNumber: z.string().regex(/^\d{16}$/),
  expiry: z.string().regex(/^\d{2}\/\d{2}$/),
});

// Split into step schemas for per-step validation
const Step1Schema = FullSchema.pick({ name: true, email: true });
const Step2Schema = FullSchema.pick({ address: true, city: true, zipCode: true });
const Step3Schema = FullSchema.pick({ cardNumber: true, expiry: true });

const stepSchemas = [Step1Schema, Step2Schema, Step3Schema] as const;

function MultiStepForm() {
  const [step, setStep] = useState(0);
  const [formData, setFormData] = useState({});

  const { register, handleSubmit, formState: { errors } } = useForm({
    resolver: zodResolver(stepSchemas[step]),
    defaultValues: formData,
  });

  const onStepSubmit = (data: any) => {
    const merged = { ...formData, ...data };
    if (step < stepSchemas.length - 1) {
      setFormData(merged);
      setStep(step + 1);
    } else {
      // Final submission — validate with full schema
      const result = FullSchema.safeParse(merged);
      if (result.success) submitForm(result.data);
    }
  };

  return <form onSubmit={handleSubmit(onStepSubmit)}>...</form>;
}
```

---

## Conform + Zod (Server Actions)

### Basic Server Action

```bash
npm install @conform-to/react @conform-to/zod zod
```

```tsx
// schema.ts
import { z } from "zod";

export const ContactSchema = z.object({
  name: z.string().min(1, "Name is required"),
  email: z.string().email("Invalid email"),
  message: z.string().min(10, "Message must be at least 10 characters"),
});
```

```tsx
// action.ts
"use server";
import { parseWithZod } from "@conform-to/zod";
import { ContactSchema } from "./schema";

export async function submitContact(prevState: unknown, formData: FormData) {
  const submission = parseWithZod(formData, { schema: ContactSchema });

  if (submission.status !== "success") {
    return submission.reply();
  }

  // submission.value is typed: { name: string; email: string; message: string }
  await sendEmail(submission.value);
  return submission.reply({ resetForm: true });
}
```

```tsx
// form.tsx
"use client";
import { useForm } from "@conform-to/react";
import { parseWithZod } from "@conform-to/zod";
import { useActionState } from "react";
import { submitContact } from "./action";
import { ContactSchema } from "./schema";

export function ContactForm() {
  const [lastResult, action] = useActionState(submitContact, undefined);
  const [form, fields] = useForm({
    lastResult,
    onValidate({ formData }) {
      return parseWithZod(formData, { schema: ContactSchema });
    },
    shouldValidate: "onBlur",
    shouldRevalidate: "onInput",
  });

  return (
    <form id={form.id} onSubmit={form.onSubmit} action={action} noValidate>
      <input name={fields.name.name} />
      <div>{fields.name.errors}</div>

      <input name={fields.email.name} type="email" />
      <div>{fields.email.errors}</div>

      <textarea name={fields.message.name} />
      <div>{fields.message.errors}</div>

      <button type="submit">Send</button>
    </form>
  );
}
```

### Conform with Async Validation

```tsx
// Server-side async validation (e.g., unique email check)
export async function submitSignup(prevState: unknown, formData: FormData) {
  const submission = await parseWithZod(formData, {
    schema: SignupSchema.superRefine(async (data, ctx) => {
      const exists = await db.user.findUnique({ where: { email: data.email } });
      if (exists) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: "Email already registered",
          path: ["email"],
        });
      }
    }),
    async: true, // Required for async refinements
  });

  if (submission.status !== "success") return submission.reply();
  await db.user.create({ data: submission.value });
  return submission.reply({ resetForm: true });
}
```

---

## tRPC Input Validation

### Router with Full CRUD

```ts
import { z } from "zod";
import { router, publicProcedure, protectedProcedure } from "./trpc";

const UserSchema = z.object({
  name: z.string().min(1).max(100),
  email: z.string().email(),
  role: z.enum(["user", "admin"]).default("user"),
});

const PaginationInput = z.object({
  page: z.number().int().positive().default(1),
  limit: z.number().int().positive().max(100).default(20),
  search: z.string().optional(),
});

export const userRouter = router({
  list: publicProcedure
    .input(PaginationInput)
    .query(async ({ input }) => {
      // input: { page: number; limit: number; search?: string }
      const offset = (input.page - 1) * input.limit;
      return db.user.findMany({
        where: input.search ? { name: { contains: input.search } } : undefined,
        skip: offset,
        take: input.limit,
      });
    }),

  getById: publicProcedure
    .input(z.object({ id: z.string().uuid() }))
    .query(async ({ input }) => {
      return db.user.findUniqueOrThrow({ where: { id: input.id } });
    }),

  create: protectedProcedure
    .input(UserSchema)
    .mutation(async ({ input, ctx }) => {
      return db.user.create({ data: { ...input, createdBy: ctx.user.id } });
    }),

  update: protectedProcedure
    .input(z.object({ id: z.string().uuid(), data: UserSchema.partial() }))
    .mutation(async ({ input }) => {
      return db.user.update({ where: { id: input.id }, data: input.data });
    }),

  delete: protectedProcedure
    .input(z.object({ id: z.string().uuid() }))
    .mutation(async ({ input }) => {
      return db.user.delete({ where: { id: input.id } });
    }),
});
```

### tRPC with Output Validation

```ts
const PublicUserSchema = z.object({
  id: z.string().uuid(),
  name: z.string(),
  avatarUrl: z.string().url().nullable(),
  // Deliberately omit email, role — not public
});

export const publicRouter = router({
  getProfile: publicProcedure
    .input(z.object({ id: z.string().uuid() }))
    .output(PublicUserSchema) // Validates AND strips extra fields from response
    .query(async ({ input }) => {
      return db.user.findUniqueOrThrow({ where: { id: input.id } });
      // If db returns { id, name, email, role, avatarUrl },
      // .output strips email and role before sending to client
    }),
});
```

---

## Next.js Server Actions

### Type-Safe Server Action with Return Type

```ts
// lib/actions.ts
"use server";
import { z } from "zod";

const CreatePostSchema = z.object({
  title: z.string().min(1, "Title is required").max(200),
  content: z.string().min(1, "Content is required").max(50000),
  tags: z.array(z.string().max(30)).max(10).default([]),
  published: z.boolean().default(false),
});

type ActionResult<T> =
  | { success: true; data: T }
  | { success: false; errors: Record<string, string[]> };

export async function createPost(formData: FormData): Promise<ActionResult<{ id: string }>> {
  const result = CreatePostSchema.safeParse({
    title: formData.get("title"),
    content: formData.get("content"),
    tags: formData.getAll("tags"),
    published: formData.get("published") === "on",
  });

  if (!result.success) {
    return { success: false, errors: result.error.flatten().fieldErrors as Record<string, string[]> };
  }

  const post = await db.post.create({ data: result.data });
  revalidatePath("/posts");
  return { success: true, data: { id: post.id } };
}
```

### Server Action with File Upload

```ts
"use server";

const UploadSchema = z.object({
  file: z.instanceof(File)
    .refine((f) => f.size <= 5 * 1024 * 1024, "File must be under 5MB")
    .refine((f) => ["image/jpeg", "image/png", "image/webp"].includes(f.type), "Must be an image"),
  alt: z.string().max(200).optional(),
});

export async function uploadImage(formData: FormData) {
  const result = UploadSchema.safeParse({
    file: formData.get("file"),
    alt: formData.get("alt"),
  });

  if (!result.success) return { errors: result.error.flatten().fieldErrors };

  const buffer = Buffer.from(await result.data.file.arrayBuffer());
  const key = `uploads/${crypto.randomUUID()}.${result.data.file.type.split("/")[1]}`;
  await s3.putObject({ Bucket: "my-bucket", Key: key, Body: buffer });

  return { success: true, url: `https://cdn.example.com/${key}` };
}
```

---

## Remix Action Validation

### Loader + Action Pattern

```tsx
// app/routes/contacts.new.tsx
import { z } from "zod";
import { json, redirect, type ActionFunctionArgs } from "@remix-run/node";
import { useActionData, Form } from "@remix-run/react";

const ContactSchema = z.object({
  firstName: z.string().min(1, "First name required"),
  lastName: z.string().min(1, "Last name required"),
  email: z.string().email("Invalid email"),
  phone: z.string().regex(/^\+?[\d\s-()]+$/, "Invalid phone").optional().or(z.literal("")),
});

export async function action({ request }: ActionFunctionArgs) {
  const formData = await request.formData();
  const result = ContactSchema.safeParse(Object.fromEntries(formData));

  if (!result.success) {
    return json({ errors: result.error.flatten().fieldErrors }, { status: 400 });
  }

  const contact = await db.contact.create({ data: result.data });
  return redirect(`/contacts/${contact.id}`);
}

export default function NewContact() {
  const actionData = useActionData<typeof action>();
  const errors = actionData?.errors;

  return (
    <Form method="post">
      <input name="firstName" />
      {errors?.firstName && <p>{errors.firstName[0]}</p>}

      <input name="lastName" />
      {errors?.lastName && <p>{errors.lastName[0]}</p>}

      <input name="email" type="email" />
      {errors?.email && <p>{errors.email[0]}</p>}

      <input name="phone" type="tel" />
      {errors?.phone && <p>{errors.phone[0]}</p>}

      <button type="submit">Create Contact</button>
    </Form>
  );
}
```

### Remix with zod-form-data

```ts
// Handle FormData quirks (checkbox = "on"/missing, multi-select, etc.)
import { zfd } from "zod-form-data";

const FormSchema = zfd.formData({
  name: zfd.text(z.string().min(1)),
  age: zfd.numeric(z.number().int().positive()),
  newsletter: zfd.checkbox(), // "on" → true, missing → false
  tags: zfd.repeatable(z.array(z.string()).min(1)),
  avatar: zfd.file(z.instanceof(File).optional()),
});

export async function action({ request }: ActionFunctionArgs) {
  const result = FormSchema.safeParse(await request.formData());
  if (!result.success) return json({ errors: result.error.flatten() }, 400);
  // result.data is fully typed
}
```

---

## Environment Validation (t3-env Pattern)

### Basic Pattern

```ts
// env.ts — import this instead of process.env
import { z } from "zod";

const envSchema = z.object({
  // Server-only
  DATABASE_URL: z.string().url(),
  JWT_SECRET: z.string().min(32),
  REDIS_URL: z.string().url().optional(),
  SMTP_HOST: z.string().optional(),
  SMTP_PORT: z.coerce.number().int().default(587),

  // Client-safe (Next.js NEXT_PUBLIC_ prefix)
  NEXT_PUBLIC_API_URL: z.string().url(),
  NEXT_PUBLIC_APP_NAME: z.string().default("MyApp"),

  // Runtime config
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),
  PORT: z.coerce.number().int().positive().default(3000),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
});

// Parse at module load — fail fast on invalid config
export const env = envSchema.parse(process.env);
export type Env = z.infer<typeof envSchema>;
```

### Using @t3-oss/env-nextjs

```ts
// env.mjs — with client/server separation enforced
import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

export const env = createEnv({
  server: {
    DATABASE_URL: z.string().url(),
    JWT_SECRET: z.string().min(32),
    NODE_ENV: z.enum(["development", "production", "test"]),
  },
  client: {
    NEXT_PUBLIC_API_URL: z.string().url(),
  },
  // Destructure all env vars to opt into validation
  runtimeEnv: {
    DATABASE_URL: process.env.DATABASE_URL,
    JWT_SECRET: process.env.JWT_SECRET,
    NODE_ENV: process.env.NODE_ENV,
    NEXT_PUBLIC_API_URL: process.env.NEXT_PUBLIC_API_URL,
  },
});
// Importing env.DATABASE_URL in client code → build error (server-only)
```

---

## API Route Validation Middleware

### Express Middleware

```ts
import { z, ZodSchema } from "zod";
import { Request, Response, NextFunction } from "express";

function validate(schema: { body?: ZodSchema; query?: ZodSchema; params?: ZodSchema }) {
  return (req: Request, res: Response, next: NextFunction) => {
    const errors: Record<string, z.ZodError> = {};

    if (schema.body) {
      const result = schema.body.safeParse(req.body);
      if (!result.success) errors.body = result.error;
      else req.body = result.data;
    }
    if (schema.query) {
      const result = schema.query.safeParse(req.query);
      if (!result.success) errors.query = result.error;
      else req.query = result.data;
    }
    if (schema.params) {
      const result = schema.params.safeParse(req.params);
      if (!result.success) errors.params = result.error;
      else req.params = result.data;
    }

    if (Object.keys(errors).length > 0) {
      return res.status(400).json({
        error: "Validation failed",
        details: Object.fromEntries(
          Object.entries(errors).map(([k, v]) => [k, v.flatten().fieldErrors])
        ),
      });
    }
    next();
  };
}

// Usage
app.post(
  "/api/users",
  validate({
    body: z.object({ name: z.string().min(1), email: z.string().email() }),
  }),
  (req, res) => {
    // req.body is typed and validated
    res.json({ user: createUser(req.body) });
  }
);
```

### Hono Middleware with Zod Validator

```ts
import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";

const app = new Hono();

const CreateUserSchema = z.object({
  name: z.string().min(1),
  email: z.string().email(),
});

// Built-in integration — validates and types in one step
app.post(
  "/users",
  zValidator("json", CreateUserSchema),
  async (c) => {
    const data = c.req.valid("json"); // Typed: { name: string; email: string }
    const user = await db.user.create({ data });
    return c.json(user, 201);
  }
);

// Multiple validators on one route
app.get(
  "/users/:id/posts",
  zValidator("param", z.object({ id: z.string().uuid() })),
  zValidator("query", z.object({
    page: z.coerce.number().int().positive().default(1),
    limit: z.coerce.number().int().positive().max(100).default(20),
  })),
  async (c) => {
    const { id } = c.req.valid("param");
    const { page, limit } = c.req.valid("query");
    return c.json(await getPosts(id, page, limit));
  }
);
```

---

## Form Builder Patterns

### Schema-Driven Form Generation

```tsx
import { z } from "zod";

// Schema metadata for UI generation
type FieldMeta = {
  label: string;
  placeholder?: string;
  type?: "text" | "email" | "number" | "select" | "textarea" | "checkbox";
  options?: { label: string; value: string }[];
};

const fieldMeta = new Map<string, FieldMeta>();

function field<T extends z.ZodTypeAny>(schema: T, meta: FieldMeta): T {
  fieldMeta.set(schema._def.description ?? "", meta);
  return schema.describe(meta.label);
}

const FormSchema = z.object({
  name: field(z.string().min(1), { label: "Full Name", placeholder: "John Doe" }),
  email: field(z.string().email(), { label: "Email", type: "email", placeholder: "john@example.com" }),
  role: field(z.enum(["user", "admin", "editor"]), {
    label: "Role",
    type: "select",
    options: [
      { label: "User", value: "user" },
      { label: "Admin", value: "admin" },
      { label: "Editor", value: "editor" },
    ],
  }),
  bio: field(z.string().max(500).optional(), { label: "Bio", type: "textarea" }),
});
```

### Reusable Form Field Components

```tsx
import { FieldError, UseFormRegister, Path } from "react-hook-form";

interface FormFieldProps<T extends Record<string, any>> {
  name: Path<T>;
  label: string;
  register: UseFormRegister<T>;
  error?: FieldError;
  type?: string;
}

function FormField<T extends Record<string, any>>({
  name, label, register, error, type = "text",
}: FormFieldProps<T>) {
  return (
    <div>
      <label htmlFor={name}>{label}</label>
      <input id={name} type={type} {...register(name)} aria-invalid={!!error} />
      {error && <p role="alert">{error.message}</p>}
    </div>
  );
}

// Usage with any Zod-backed form
function UserForm() {
  const { register, handleSubmit, formState: { errors } } = useForm({
    resolver: zodResolver(UserSchema),
  });

  return (
    <form onSubmit={handleSubmit(onSubmit)}>
      <FormField name="name" label="Name" register={register} error={errors.name} />
      <FormField name="email" label="Email" register={register} error={errors.email} type="email" />
      <button type="submit">Submit</button>
    </form>
  );
}
```

---

## OpenAPI Schema Generation from Zod

### Using zod-openapi

```bash
npm install zod-openapi
```

```ts
import { z } from "zod";
import { extendZodWithOpenApi, createDocument } from "zod-openapi";

extendZodWithOpenApi(z);

const UserSchema = z.object({
  id: z.string().uuid().openapi({ description: "Unique user identifier", example: "123e4567-e89b-12d3-a456-426614174000" }),
  name: z.string().min(1).openapi({ description: "User's display name", example: "Jane Doe" }),
  email: z.string().email().openapi({ description: "Email address", example: "jane@example.com" }),
  role: z.enum(["user", "admin"]).openapi({ description: "User role" }),
  createdAt: z.string().datetime().openapi({ description: "Creation timestamp" }),
}).openapi("User");

const CreateUserSchema = UserSchema.omit({ id: true, createdAt: true }).openapi("CreateUser");

const document = createDocument({
  openapi: "3.1.0",
  info: { title: "My API", version: "1.0.0" },
  paths: {
    "/users": {
      post: {
        requestBody: { content: { "application/json": { schema: CreateUserSchema } } },
        responses: {
          "201": {
            description: "User created",
            content: { "application/json": { schema: UserSchema } },
          },
        },
      },
    },
  },
});
```

### Zod 4 Native JSON Schema

```ts
// Zod 4 — no third-party library needed
import { z } from "zod/v4";

const UserSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1),
  email: z.email(),
});

const jsonSchema = z.toJSONSchema(UserSchema);
// {
//   type: "object",
//   properties: {
//     id: { type: "string", format: "uuid" },
//     name: { type: "string", minLength: 1 },
//     email: { type: "string", format: "email" }
//   },
//   required: ["id", "name", "email"]
// }

// Use with Swagger, OpenAPI spec generators, or any JSON Schema consumer
```

### Fastify with zod-to-json-schema (Zod 3)

```ts
import fastify from "fastify";
import { zodToJsonSchema } from "zod-to-json-schema";

const app = fastify();

const BodySchema = z.object({
  name: z.string().min(1),
  email: z.string().email(),
});

app.post("/users", {
  schema: {
    body: zodToJsonSchema(BodySchema),         // For Swagger docs
    response: { 201: zodToJsonSchema(UserResponseSchema) },
  },
  handler: async (req, reply) => {
    const body = BodySchema.parse(req.body);   // Runtime validation with Zod
    const user = await createUser(body);
    reply.status(201).send(user);
  },
});
```
