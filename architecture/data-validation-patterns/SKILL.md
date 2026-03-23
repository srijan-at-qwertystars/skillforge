---
name: data-validation-patterns
description: |
  Use when user designs validation architecture, asks about input validation strategy, schema validation, form validation, API request validation, or comparing validation libraries (Zod, Pydantic, Joi, JSON Schema).
  Do NOT use for Zod-specific patterns (use zod-validation skill), TypeScript types without runtime validation, or database constraints.
---

# Data Validation Patterns

## Validation Philosophy

Follow three principles:

1. **Validate at boundaries.** Treat every system entry point as untrusted — HTTP handlers, message consumers, file imports, CLI args. Never validate deep inside business logic.
2. **Fail early.** Reject invalid data the moment it arrives. Do not propagate partially valid state through the call stack.
3. **Defense in depth.** Layer validation. Client-side validation improves UX; server-side validation enforces correctness; database constraints are the last safety net. Never rely on a single layer.

## Validation Layers

| Layer | What to Validate | Why |
|-------|-----------------|-----|
| **Client** | Format, required fields, ranges | Fast feedback, reduces server load |
| **API Gateway** | Auth tokens, rate limits, payload size, content-type | Reject garbage before it reaches services |
| **Server/Controller** | Full schema validation, type coercion, business format rules | Single source of truth for request shape |
| **Service/Domain** | Cross-field rules, business invariants, authorization-dependent logic | Domain-specific constraints |
| **Database** | NOT NULL, UNIQUE, CHECK, FK constraints | Final safety net against data corruption |

Never skip server validation because the client "already checked." Clients are attacker-controlled.

## Schema-First Validation

Define the schema first, derive everything else from it.

**JSON Schema** — language-agnostic contract:
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "email": { "type": "string", "format": "email" },
    "age": { "type": "integer", "minimum": 0, "maximum": 150 }
  },
  "required": ["email"]
}
```

**OpenAPI** — embed JSON Schema in API specs. Generate client SDKs and server stubs from a single definition.

**Protocol Buffers** — enforce schema at serialization. Use `proto3` field presence for required-field semantics. Share `.proto` files across services.

**Shared schemas** — store validation schemas in a shared package. Import them in both client and server. Zod, Pydantic, and Joi schemas all support this pattern.

## Library Comparison

### TypeScript / JavaScript

| Library | Bundle Size | Approach | Best For |
|---------|------------|----------|----------|
| **Zod** | ~12KB gzip | Method chaining, `z.infer` | Full-stack TS, tRPC, React Hook Form |
| **Valibot** | ~1KB gzip | Modular/tree-shakeable, pipeable | Edge, mobile, serverless |
| **ArkType** | ~5KB gzip | TS-native syntax strings | Perf-critical, complex hierarchies |
| **Yup** | ~12KB gzip | Method chaining | Legacy Formik projects |
| **TypeBox** | ~4KB gzip | JSON Schema compatible | JSON Schema + Ajv pipelines |

```typescript
// Zod
const UserSchema = z.object({
  name: z.string().min(1),
  email: z.string().email(),
  age: z.number().int().positive(),
});
type User = z.infer<typeof UserSchema>;

// Valibot — tree-shakeable
import * as v from "valibot";
const UserSchema = v.object({
  name: v.pipe(v.string(), v.minLength(1)),
  email: v.pipe(v.string(), v.email()),
  age: v.pipe(v.number(), v.integer(), v.minValue(1)),
});

// ArkType — TS-native syntax
import { type } from "arktype";
const User = type({
  name: "string>0",
  email: "string.email",
  age: "integer>0",
});
```

### Python

| Library | Approach | Best For |
|---------|----------|----------|
| **Pydantic** | Type-hint models, Rust core | FastAPI, config, data pipelines |
| **marshmallow** | Schema classes, dump/load | Flask, DRF-like serialization |
| **attrs + cattrs** | Lightweight dataclasses | Internal domain models |

```python
# Pydantic v2
from pydantic import BaseModel, EmailStr, Field

class User(BaseModel):
    name: str = Field(min_length=1)
    email: EmailStr
    age: int = Field(gt=0, le=150)

user = User.model_validate(request_data)  # raises ValidationError
```

### Node.js (plain JS)

| Library | Approach | Best For |
|---------|----------|----------|
| **Joi** | Fluent schema DSL | Express/Hapi, complex chains |
| **class-validator** | Decorators on classes | NestJS, OOP style |

```javascript
// Joi
const Joi = require("joi");
const userSchema = Joi.object({
  name: Joi.string().min(1).required(),
  email: Joi.string().email().required(),
  age: Joi.number().integer().positive().max(150).required(),
});
const { error, value } = userSchema.validate(req.body);
```

### Java

Use **Bean Validation** (Jakarta Validation / Hibernate Validator):
```java
public record CreateUserRequest(
    @NotBlank String name,
    @Email String email,
    @Min(1) @Max(150) int age
) {}
```
Combine with `@Valid` on controller parameters for automatic validation.

## Form Validation

- **Client-side:** Validate on blur and submit. Show inline errors next to fields. Use `novalidate` on `<form>` to control UX with JS.
- **Server-side:** Always re-validate. Never trust client state.
- **Progressive enhancement:** HTML5 `required`, `type="email"`, `pattern` attributes work without JS. Layer JS validation on top.
- **Error display:** Map field-level errors to the corresponding input. Show all errors at once, not one at a time.

```typescript
// React Hook Form + Zod
const { register, handleSubmit, formState: { errors } } = useForm({
  resolver: zodResolver(UserSchema),
});
```

## API Request Validation

**Middleware pattern** (Express + Zod):
```typescript
function validate(schema: z.ZodSchema) {
  return (req: Request, res: Response, next: NextFunction) => {
    const result = schema.safeParse(req.body);
    if (!result.success) {
      return res.status(422).json({ errors: result.error.flatten() });
    }
    req.body = result.data;
    next();
  };
}
app.post("/users", validate(UserSchema), createUser);
```

**Decorator pattern** (NestJS + class-validator):
```typescript
@Post("users")
createUser(@Body() dto: CreateUserDto) { /* dto already validated */ }
```

**FastAPI + Pydantic** — validation is automatic:
```python
@app.post("/users")
async def create_user(user: User):  # Pydantic model = auto-validated
    return user
```

**OpenAPI validation** — use middleware that validates against the OpenAPI spec at runtime (e.g., `express-openapi-validator`, `connexion` for Python).

## Validation Patterns

### Parse, Don't Validate

Transform raw input into a typed value at the boundary. If parsing succeeds, the value is guaranteed valid. All downstream code accepts only the parsed type.

```typescript
// Bad: validate then pass string around
function sendEmail(email: string) { /* hope it's valid */ }

// Good: parse into branded type
type Email = string & { readonly __brand: "Email" };
function parseEmail(input: string): Email {
  if (!EMAIL_REGEX.test(input)) throw new Error("Invalid email");
  return input as Email;
}
function sendEmail(email: Email) { /* guaranteed valid */ }
```

```python
# Pydantic — NewType pattern
from pydantic import TypeAdapter
from typing import NewType, Annotated
from pydantic import AfterValidator

Email = NewType("Email", str)
adapter = TypeAdapter(Annotated[str, AfterValidator(validate_email)])
email = adapter.validate_python(raw_input)
```

### Branded / Nominal Types

Prevent mixing structurally identical but semantically different values:
```typescript
type UserId = string & { __brand: "UserId" };
type OrderId = string & { __brand: "OrderId" };
// Cannot pass UserId where OrderId is expected
```

### Refinement Types

Add constraints beyond the base type:
```typescript
const PositiveInt = z.number().int().positive();
const Percentage = z.number().min(0).max(100);
```

## Error Aggregation

**Collect all errors** when validating forms or batch inputs — users need to see every problem at once:
```typescript
const result = schema.safeParse(data);
if (!result.success) {
  const fieldErrors = result.error.flatten().fieldErrors;
  // { name: ["Required"], email: ["Invalid email"], age: ["Too small"] }
}
```

**Fail-fast** for internal service calls or pipelines — stop on first error to avoid wasted work.

**Nested errors** — Zod, Pydantic, and Joi all support nested object error paths:
```python
# Pydantic nested error
# [{"loc": ["address", "zip"], "msg": "Invalid zip code", "type": "value_error"}]
```

Structure API error responses consistently:
```json
{
  "errors": [
    { "field": "email", "message": "Invalid email format" },
    { "field": "age", "message": "Must be between 1 and 150" }
  ]
}
```

## Sanitization vs Validation

Validation checks correctness. Sanitization transforms data to be safe. Do both, in order: **sanitize first, then validate.**

| Threat | Defense |
|--------|---------|
| **XSS** | Escape output (`&lt;` etc.), use CSP headers. Do NOT strip tags on input — escape on output. |
| **SQL injection** | Use parameterized queries. Never concatenate user input into SQL. |
| **Command injection** | Avoid shell execution. Use typed APIs. |
| **Encoding** | Normalize Unicode (NFC) before validation. Trim whitespace. |

```typescript
// Sanitize then validate
const cleanInput = input.trim().normalize("NFC");
const result = schema.safeParse(cleanInput);
```

Only sanitize when the transformation is semantically correct (trimming whitespace, normalizing unicode). Do not silently "fix" invalid data — reject it.

## Cross-Field Validation

Validate dependent fields together:

```typescript
// Zod — refine at object level
const DateRange = z.object({
  startDate: z.coerce.date(),
  endDate: z.coerce.date(),
}).refine(d => d.endDate > d.startDate, {
  message: "End date must be after start date",
  path: ["endDate"],
});
```

```python
# Pydantic — model_validator
from pydantic import model_validator

class DateRange(BaseModel):
    start_date: date
    end_date: date

    @model_validator(mode="after")
    def check_dates(self):
        if self.end_date <= self.start_date:
            raise ValueError("end_date must be after start_date")
        return self
```

```java
// Jakarta Validation — class-level constraint
@ValidDateRange
public record DateRange(LocalDate startDate, LocalDate endDate) {}
```

Handle conditional rules — e.g., "require phone if contact preference is SMS":
```typescript
const ContactForm = z.discriminatedUnion("contactMethod", [
  z.object({ contactMethod: z.literal("email"), email: z.string().email() }),
  z.object({ contactMethod: z.literal("sms"), phone: z.string().min(10) }),
]);
```

## Async Validation

Use async validation for checks that require I/O:

```typescript
// Zod — async refinement
const UniqueEmail = z.string().email().refine(
  async (email) => !(await db.users.exists({ email })),
  { message: "Email already taken" }
);
const result = await UniqueEmail.parseAsync(input);
```

```python
# Manual async check in FastAPI
@app.post("/users")
async def create_user(user: User):
    if await user_repo.email_exists(user.email):
        raise HTTPException(422, detail="Email already taken")
```

**Debounce** async validation on the client — wait 300-500ms after the user stops typing before calling the server.

Keep async validators separate from synchronous schema validation. Run sync checks first to fail fast on format errors before hitting the database.

## Custom Validators

Build reusable validators through composition:

```typescript
// Zod — reusable refinements
const nonEmpty = (msg = "Required") => z.string().min(1, msg);
const slug = z.string().regex(/^[a-z0-9-]+$/, "Invalid slug");
const money = z.number().multipleOf(0.01).nonnegative();

// Compose into schemas
const Product = z.object({
  name: nonEmpty(),
  slug,
  price: money,
});
```

```python
# Pydantic — reusable Annotated types
from typing import Annotated
from pydantic import Field

NonEmptyStr = Annotated[str, Field(min_length=1)]
Money = Annotated[float, Field(ge=0, decimal_places=2)]
Slug = Annotated[str, Field(pattern=r"^[a-z0-9-]+$")]

class Product(BaseModel):
    name: NonEmptyStr
    slug: Slug
    price: Money
```

**Validator factories** — create validators parameterized by configuration:
```typescript
function stringEnum<T extends string>(values: readonly T[]) {
  return z.enum(values as [T, ...T[]]);
}
const Status = stringEnum(["active", "inactive", "pending"] as const);
```

## Anti-Patterns

| Anti-Pattern | Problem | Fix |
|-------------|---------|-----|
| Validating only on the client | Attacker bypasses JS entirely | Always validate on server |
| Validation deep in business logic | Errors surface late, hard to trace | Validate at boundaries |
| Regex-only email validation | Complex RFCs, false negatives | Use library validators; send confirmation email |
| Silently coercing invalid data | Hides bugs, surprises users | Reject and return clear errors |
| Trusting deserialized objects | Pickle/JSON.parse yield untyped data | Parse into validated types |
| One giant validation function | Untestable, unreusable | Compose small validators |
| Validating the same data repeatedly | Performance waste, inconsistency | Validate once at entry, use typed values downstream |
| Different rules client vs server | Drift causes confusion | Share schemas or generate from single source |

<!-- tested: pass -->
