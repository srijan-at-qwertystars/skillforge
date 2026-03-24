# Advanced Zod Patterns

## Table of Contents

- [Recursive Schemas Deep Dive](#recursive-schemas-deep-dive)
- [Branded Types for Domain Modeling](#branded-types-for-domain-modeling)
- [Discriminated Unions for State Machines](#discriminated-unions-for-state-machines)
- [z.pipe for Transform Chains](#zpipe-for-transform-chains)
- [Custom Error Maps](#custom-error-maps)
- [Schema Composition Patterns](#schema-composition-patterns)
- [Dynamic Schemas with z.lazy](#dynamic-schemas-with-zlazy)
- [Conditional Validation](#conditional-validation)
- [Dependent Field Validation](#dependent-field-validation)
- [Array Item Validation with Refinements](#array-item-validation-with-refinements)
- [File and Blob Validation](#file-and-blob-validation)

---

## Recursive Schemas Deep Dive

### Basic Recursion

```ts
// Tree structure — annotate with z.ZodType<T> for correct inference
interface TreeNode {
  value: string;
  children: TreeNode[];
}

const TreeNodeSchema: z.ZodType<TreeNode> = z.object({
  value: z.string(),
  children: z.lazy(() => TreeNodeSchema.array()),
});
```

### Mutually Recursive Schemas

```ts
interface Expr {
  type: "binary";
  left: Expr | Literal;
  right: Expr | Literal;
  op: "+" | "-" | "*" | "/";
}
interface Literal {
  type: "literal";
  value: number;
}

const LiteralSchema: z.ZodType<Literal> = z.object({
  type: z.literal("literal"),
  value: z.number(),
});

const ExprSchema: z.ZodType<Expr> = z.object({
  type: z.literal("binary"),
  left: z.lazy(() => z.union([ExprSchema, LiteralSchema])),
  right: z.lazy(() => z.union([ExprSchema, LiteralSchema])),
  op: z.enum(["+", "-", "*", "/"]),
});
```

### Depth-Limited Recursion

```ts
// Prevent infinite nesting — limit recursion depth with superRefine
function createBoundedTree(maxDepth: number): z.ZodType<TreeNode> {
  function checkDepth(node: TreeNode, depth: number, ctx: z.RefinementCtx) {
    if (depth > maxDepth) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `Max nesting depth of ${maxDepth} exceeded`,
      });
      return;
    }
    node.children.forEach((child) => checkDepth(child, depth + 1, ctx));
  }

  return TreeNodeSchema.superRefine((node, ctx) => checkDepth(node, 0, ctx));
}
```

### JSON Schema (Complete)

```ts
type JsonValue = string | number | boolean | null | JsonValue[] | { [k: string]: JsonValue };

const JsonSchema: z.ZodType<JsonValue> = z.lazy(() =>
  z.union([
    z.string(),
    z.number(),
    z.boolean(),
    z.null(),
    z.array(JsonSchema),
    z.record(z.string(), JsonSchema),
  ])
);

// Parse arbitrary JSON safely
const parsed = JsonSchema.safeParse(JSON.parse(untrustedInput));
```

---

## Branded Types for Domain Modeling

### Type-Safe Identifiers

```ts
const UserId = z.string().uuid().brand<"UserId">();
const OrderId = z.string().uuid().brand<"OrderId">();
const ProductId = z.string().uuid().brand<"ProductId">();

type UserId = z.infer<typeof UserId>;
type OrderId = z.infer<typeof OrderId>;

// Compile-time safety: can't mix up IDs
function getOrder(userId: UserId, orderId: OrderId) { /* ... */ }

const uid = UserId.parse("550e8400-e29b-41d4-a716-446655440000");
const oid = OrderId.parse("660e8400-e29b-41d4-a716-446655440000");
getOrder(uid, oid);  // OK
// getOrder(oid, uid);  // Compile error!
```

### Validated Value Objects

```ts
// Positive integer brand — proves validation happened
const PositiveInt = z.number().int().positive().brand<"PositiveInt">();
type PositiveInt = z.infer<typeof PositiveInt>;

// Email that's been validated and normalized
const ValidEmail = z.string().trim().toLowerCase().email().brand<"ValidEmail">();
type ValidEmail = z.infer<typeof ValidEmail>;

// Use in function signatures to enforce validation at boundaries
function sendEmail(to: ValidEmail, subject: string) {
  // `to` is guaranteed to be a valid, normalized email
}

// Must parse before calling — can't pass raw string
sendEmail(ValidEmail.parse(userInput), "Welcome!");
```

### Currency with Brand

```ts
const USD = z.number().nonnegative().multipleOf(0.01).brand<"USD">();
const EUR = z.number().nonnegative().multipleOf(0.01).brand<"EUR">();
type USD = z.infer<typeof USD>;
type EUR = z.infer<typeof EUR>;

// Prevents accidental currency mixing
function chargeCard(amount: USD) { /* ... */ }
// chargeCard(EUR.parse(10.50));  // Compile error
```

---

## Discriminated Unions for State Machines

### Request Lifecycle

```ts
const RequestState = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("idle"),
  }),
  z.object({
    status: z.literal("loading"),
    startedAt: z.date(),
  }),
  z.object({
    status: z.literal("success"),
    data: z.unknown(),
    completedAt: z.date(),
  }),
  z.object({
    status: z.literal("error"),
    error: z.string(),
    retryCount: z.number().int().nonnegative(),
    lastAttempt: z.date(),
  }),
]);

type RequestState = z.infer<typeof RequestState>;

// TypeScript narrows correctly
function render(state: RequestState) {
  switch (state.status) {
    case "idle": return "Ready";
    case "loading": return `Loading since ${state.startedAt}`;
    case "success": return `Data: ${JSON.stringify(state.data)}`;
    case "error": return `Error: ${state.error} (retry ${state.retryCount})`;
  }
}
```

### Multi-Discriminator Pattern

```ts
// Nested discriminated unions for complex state
const PaymentEvent = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("payment"),
    method: z.discriminatedUnion("kind", [
      z.object({ kind: z.literal("card"), last4: z.string().length(4) }),
      z.object({ kind: z.literal("bank"), routingNumber: z.string() }),
      z.object({ kind: z.literal("crypto"), walletAddress: z.string() }),
    ]),
    amount: z.number().positive(),
  }),
  z.object({
    type: z.literal("refund"),
    originalPaymentId: z.string().uuid(),
    reason: z.string(),
  }),
]);
```

---

## z.pipe for Transform Chains

### String to Validated Number

```ts
// Parse string input → coerce to number → validate constraints
const StringToPositiveInt = z.string()
  .pipe(z.coerce.number().int().positive());

StringToPositiveInt.parse("42");    // => 42
StringToPositiveInt.parse("-1");    // ZodError: not positive
StringToPositiveInt.parse("abc");   // ZodError: NaN
```

### Multi-Stage Parsing

```ts
// Raw CSV field → trimmed string → parsed date → validated range
const CSVDateField = z.string()
  .transform((s) => s.trim())
  .pipe(z.coerce.date())
  .pipe(z.date().min(new Date("2020-01-01")).max(new Date()));

// Comma-separated IDs → array of validated UUIDs
const CSVIds = z.string()
  .transform((s) => s.split(",").map((id) => id.trim()))
  .pipe(z.array(z.string().uuid()).nonempty());
```

### Preprocessing External API Data

```ts
// API returns numbers as strings — normalize before validation
const ApiPrice = z.string()
  .transform((s) => s.replace(/[$,]/g, ""))
  .pipe(z.coerce.number().positive().multipleOf(0.01));

ApiPrice.parse("$1,234.56"); // => 1234.56
```

---

## Custom Error Maps

### Per-Schema Error Map

```ts
const UserSchema = z.object({
  name: z.string({
    required_error: "Name is required",
    invalid_type_error: "Name must be text",
  }).min(2, "Name must be at least 2 characters"),
  age: z.number({
    required_error: "Age is required",
    invalid_type_error: "Age must be a number",
  }).int("Age must be a whole number").positive("Age must be positive"),
});
```

### Global Error Map for i18n

```ts
const errorMessages: Record<string, Record<string, string>> = {
  en: { required: "This field is required", invalid_type: "Invalid type" },
  es: { required: "Este campo es obligatorio", invalid_type: "Tipo inválido" },
};

function createI18nErrorMap(locale: string): z.ZodErrorMap {
  const messages = errorMessages[locale] ?? errorMessages.en;
  return (issue, ctx) => {
    switch (issue.code) {
      case z.ZodIssueCode.invalid_type:
        if (issue.received === "undefined") return { message: messages.required };
        return { message: messages.invalid_type };
      default:
        return { message: ctx.defaultError };
    }
  };
}

z.setErrorMap(createI18nErrorMap("es"));
```

---

## Schema Composition Patterns

### Mixins

```ts
// Reusable schema fragments
const WithTimestamps = z.object({
  createdAt: z.coerce.date(),
  updatedAt: z.coerce.date(),
});

const WithSoftDelete = z.object({
  deletedAt: z.coerce.date().nullable().default(null),
  isDeleted: z.boolean().default(false),
});

const WithPagination = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().positive().max(100).default(20),
});

// Compose into final schemas
const UserRecord = z.object({
  id: z.string().uuid(),
  name: z.string(),
  email: z.string().email(),
}).merge(WithTimestamps).merge(WithSoftDelete);
```

### Input/Output Schema Pairs

```ts
// Define once, derive CRUD variants
const UserBase = z.object({
  name: z.string().min(1).max(100),
  email: z.string().email(),
  role: z.enum(["user", "admin"]).default("user"),
});

const CreateUserInput = UserBase;
const UpdateUserInput = UserBase.partial();
const UserResponse = UserBase.extend({
  id: z.string().uuid(),
  createdAt: z.date(),
});

type CreateUserInput = z.infer<typeof CreateUserInput>;
type UpdateUserInput = z.infer<typeof UpdateUserInput>;
type UserResponse = z.infer<typeof UserResponse>;
```

---

## Dynamic Schemas with z.lazy

### Polymorphic Config

```ts
// Config schema that varies by provider
function createProviderSchema(provider: string) {
  const base = z.object({ provider: z.literal(provider), enabled: z.boolean() });

  const configs: Record<string, z.ZodObject<any>> = {
    aws: base.extend({ region: z.string(), accessKeyId: z.string() }),
    gcp: base.extend({ projectId: z.string(), zone: z.string() }),
    azure: base.extend({ tenantId: z.string(), subscriptionId: z.string() }),
  };

  return configs[provider] ?? base.passthrough();
}
```

### Schema Registry

```ts
// Dynamic schema selection at runtime
const schemaRegistry = new Map<string, z.ZodSchema>();

function registerSchema(name: string, schema: z.ZodSchema) {
  schemaRegistry.set(name, schema);
}

function validateWithSchema(name: string, data: unknown) {
  const schema = schemaRegistry.get(name);
  if (!schema) throw new Error(`Unknown schema: ${name}`);
  return schema.safeParse(data);
}
```

---

## Conditional Validation

### Conditional Fields with superRefine

```ts
const ShippingSchema = z.object({
  method: z.enum(["pickup", "delivery", "digital"]),
  address: z.string().optional(),
  city: z.string().optional(),
  zipCode: z.string().optional(),
  email: z.string().email().optional(),
}).superRefine((data, ctx) => {
  if (data.method === "delivery") {
    if (!data.address) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Address required for delivery", path: ["address"] });
    if (!data.city) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "City required for delivery", path: ["city"] });
    if (!data.zipCode) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Zip code required for delivery", path: ["zipCode"] });
  }
  if (data.method === "digital" && !data.email) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Email required for digital delivery", path: ["email"] });
  }
});
```

### Union-Based Conditional (Preferred)

```ts
// Better approach: model each case explicitly with discriminatedUnion
const ShippingV2 = z.discriminatedUnion("method", [
  z.object({
    method: z.literal("pickup"),
    storeId: z.string(),
  }),
  z.object({
    method: z.literal("delivery"),
    address: z.string().min(1),
    city: z.string().min(1),
    zipCode: z.string().regex(/^\d{5}(-\d{4})?$/),
  }),
  z.object({
    method: z.literal("digital"),
    email: z.string().email(),
  }),
]);
```

---

## Dependent Field Validation

### Date Range Validation

```ts
const DateRangeSchema = z.object({
  startDate: z.coerce.date(),
  endDate: z.coerce.date(),
}).refine((d) => d.endDate > d.startDate, {
  message: "End date must be after start date",
  path: ["endDate"],
});
```

### Price Range with Min/Max

```ts
const PriceFilterSchema = z.object({
  minPrice: z.number().nonnegative().optional(),
  maxPrice: z.number().nonnegative().optional(),
}).refine(
  (d) => {
    if (d.minPrice !== undefined && d.maxPrice !== undefined) {
      return d.maxPrice >= d.minPrice;
    }
    return true;
  },
  { message: "Max price must be >= min price", path: ["maxPrice"] }
);
```

### Multi-Field Business Rules

```ts
const OrderSchema = z.object({
  items: z.array(z.object({
    productId: z.string().uuid(),
    quantity: z.number().int().positive(),
    unitPrice: z.number().positive(),
  })).nonempty(),
  discountPercent: z.number().min(0).max(100).optional(),
  couponCode: z.string().optional(),
}).superRefine((order, ctx) => {
  const total = order.items.reduce((sum, i) => sum + i.quantity * i.unitPrice, 0);
  if (order.discountPercent && order.discountPercent > 50 && total < 100) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Discounts over 50% require order total >= $100",
      path: ["discountPercent"],
    });
  }
  if (order.couponCode && order.discountPercent) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Cannot combine coupon with percentage discount",
      path: ["couponCode"],
    });
  }
});
```

---

## Array Item Validation with Refinements

### Unique Items

```ts
const UniqueEmails = z.array(z.string().email()).superRefine((emails, ctx) => {
  const seen = new Set<string>();
  emails.forEach((email, i) => {
    const lower = email.toLowerCase();
    if (seen.has(lower)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `Duplicate email: ${email}`,
        path: [i],
      });
    }
    seen.add(lower);
  });
});
```

### Ordered Items

```ts
const SortedNumbers = z.array(z.number()).superRefine((nums, ctx) => {
  for (let i = 1; i < nums.length; i++) {
    if (nums[i] < nums[i - 1]) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `Array must be sorted: ${nums[i]} < ${nums[i - 1]} at index ${i}`,
        path: [i],
      });
    }
  }
});
```

### Array with Cross-Item Constraints

```ts
// Budget line items must sum to 100%
const BudgetSchema = z.array(
  z.object({ category: z.string(), percentage: z.number().positive() })
).nonempty().superRefine((items, ctx) => {
  const total = items.reduce((sum, i) => sum + i.percentage, 0);
  if (Math.abs(total - 100) > 0.01) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: `Percentages must sum to 100%, got ${total.toFixed(2)}%`,
    });
  }
});
```

---

## File and Blob Validation

### Browser File Input

```ts
const MAX_FILE_SIZE = 5 * 1024 * 1024; // 5MB
const ACCEPTED_IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp", "image/svg+xml"];

const ImageFileSchema = z.instanceof(File)
  .refine((f) => f.size <= MAX_FILE_SIZE, "Max file size is 5MB")
  .refine((f) => ACCEPTED_IMAGE_TYPES.includes(f.type), "Only .jpg, .png, .webp, .svg accepted");

// Multiple files
const FileListSchema = z.array(ImageFileSchema).min(1, "Upload at least one image").max(5, "Max 5 images");
```

### FormData File Validation

```ts
const UploadSchema = z.object({
  file: z.instanceof(File).refine((f) => f.size > 0, "File cannot be empty"),
  description: z.string().max(500).optional(),
});

// Usage in form handler
export async function handleUpload(formData: FormData) {
  const result = UploadSchema.safeParse({
    file: formData.get("file"),
    description: formData.get("description"),
  });
  if (!result.success) return { errors: result.error.flatten().fieldErrors };
  // Process result.data.file
}
```

### Server-Side File Metadata Validation

```ts
// Validate file metadata without reading content (e.g., from multipart parser)
const FileMetaSchema = z.object({
  filename: z.string().min(1).regex(/^[\w\-. ]+$/, "Invalid filename characters"),
  mimetype: z.string().regex(/^(image|application|text)\//),
  size: z.number().int().positive().max(50 * 1024 * 1024), // 50MB
  encoding: z.enum(["7bit", "8bit", "binary", "base64", "quoted-printable"]),
});
```
