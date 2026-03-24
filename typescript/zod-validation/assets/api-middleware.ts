// api-middleware.ts — Express/Hono middleware for Zod request validation
//
// Usage:
//   Express: app.post("/users", validate({ body: UserSchema }), handler)
//   Hono:    app.post("/users", zValidate("json", UserSchema), handler)
//
// Both middlewares parse and replace request data with validated output,
// return 400 with structured errors on validation failure.

import { z, type ZodSchema, type ZodError } from "zod";

// ─── Error Formatting ───────────────────────────────────────────────────────

interface ValidationErrorResponse {
  success: false;
  error: {
    code: "VALIDATION_ERROR";
    message: string;
    details: {
      target: "body" | "query" | "params" | "headers";
      issues: {
        path: string;
        message: string;
        code: string;
      }[];
    }[];
  };
}

function formatZodError(error: ZodError, target: string): ValidationErrorResponse["error"]["details"][0] {
  return {
    target: target as any,
    issues: error.issues.map((issue) => ({
      path: issue.path.join("."),
      message: issue.message,
      code: issue.code,
    })),
  };
}

function createErrorResponse(details: ValidationErrorResponse["error"]["details"]): ValidationErrorResponse {
  const totalIssues = details.reduce((sum, d) => sum + d.issues.length, 0);
  return {
    success: false,
    error: {
      code: "VALIDATION_ERROR",
      message: `Validation failed with ${totalIssues} error(s)`,
      details,
    },
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// EXPRESS MIDDLEWARE
// ═══════════════════════════════════════════════════════════════════════════

// Type augmentation for validated request data
declare global {
  namespace Express {
    interface Request {
      validated?: {
        body?: unknown;
        query?: unknown;
        params?: unknown;
      };
    }
  }
}

interface ValidateOptions {
  body?: ZodSchema;
  query?: ZodSchema;
  params?: ZodSchema;
  headers?: ZodSchema;
  /** If true, validation errors call next(error) instead of sending response */
  passthrough?: boolean;
}

/**
 * Express middleware for Zod request validation.
 *
 * Validates body, query, params, and/or headers against Zod schemas.
 * Replaces req.body/query/params with parsed (and potentially transformed) data.
 *
 * @example
 * const CreateUserSchema = z.object({
 *   name: z.string().min(1),
 *   email: z.string().email(),
 * });
 *
 * app.post("/users", validate({ body: CreateUserSchema }), (req, res) => {
 *   const user = req.body; // Typed and validated
 *   res.json({ user });
 * });
 *
 * // Multiple targets
 * app.get("/users/:id/posts",
 *   validate({
 *     params: z.object({ id: z.string().uuid() }),
 *     query: z.object({
 *       page: z.coerce.number().int().positive().default(1),
 *       limit: z.coerce.number().int().max(100).default(20),
 *     }),
 *   }),
 *   (req, res) => {
 *     const { id } = req.params;        // string (validated UUID)
 *     const { page, limit } = req.query; // numbers (coerced from query string)
 *   }
 * );
 */
export function validate(options: ValidateOptions) {
  return (req: any, res: any, next: any) => {
    const errorDetails: ValidationErrorResponse["error"]["details"] = [];

    const targets: [string, ZodSchema | undefined, () => unknown, (data: unknown) => void][] = [
      ["body", options.body, () => req.body, (d) => { req.body = d; }],
      ["query", options.query, () => req.query, (d) => { req.query = d; }],
      ["params", options.params, () => req.params, (d) => { req.params = d; }],
      ["headers", options.headers, () => req.headers, () => {}],
    ];

    req.validated = {};

    for (const [target, schema, getData, setData] of targets) {
      if (!schema) continue;

      const result = schema.safeParse(getData());
      if (result.success) {
        setData(result.data);
        (req.validated as any)[target] = result.data;
      } else {
        errorDetails.push(formatZodError(result.error, target));
      }
    }

    if (errorDetails.length > 0) {
      if (options.passthrough) {
        const err = new Error("Validation failed") as any;
        err.status = 400;
        err.details = errorDetails;
        return next(err);
      }
      return res.status(400).json(createErrorResponse(errorDetails));
    }

    next();
  };
}

/**
 * Express error handler for validation errors.
 * Use with `passthrough: true` option.
 *
 * @example
 * app.use(validationErrorHandler);
 */
export function validationErrorHandler(err: any, _req: any, res: any, next: any) {
  if (err.status === 400 && err.details) {
    return res.status(400).json(createErrorResponse(err.details));
  }
  next(err);
}

// ═══════════════════════════════════════════════════════════════════════════
// HONO MIDDLEWARE
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Hono-style middleware for Zod validation.
 *
 * Unlike the official @hono/zod-validator, this version:
 * - Returns structured error responses matching our API format
 * - Supports header validation
 * - Stores validated data on context for downstream access
 *
 * @example
 * import { Hono } from "hono";
 *
 * const app = new Hono();
 *
 * app.post(
 *   "/users",
 *   zValidate("json", z.object({ name: z.string(), email: z.string().email() })),
 *   async (c) => {
 *     const data = c.get("validatedBody");
 *     return c.json({ user: data }, 201);
 *   }
 * );
 *
 * app.get(
 *   "/users",
 *   zValidate("query", z.object({
 *     page: z.coerce.number().default(1),
 *     limit: z.coerce.number().default(20),
 *   })),
 *   async (c) => {
 *     const { page, limit } = c.get("validatedQuery");
 *     return c.json(await getUsers(page, limit));
 *   }
 * );
 */
export function zValidate<T extends ZodSchema>(
  target: "json" | "query" | "param" | "header",
  schema: T,
) {
  return async (c: any, next: any) => {
    let data: unknown;

    switch (target) {
      case "json":
        data = await c.req.json().catch(() => ({}));
        break;
      case "query":
        data = Object.fromEntries(new URL(c.req.url).searchParams);
        break;
      case "param":
        data = c.req.param();
        break;
      case "header":
        data = Object.fromEntries(c.req.raw.headers);
        break;
    }

    const result = schema.safeParse(data);

    if (!result.success) {
      const targetMap = { json: "body", query: "query", param: "params", header: "headers" } as const;
      return c.json(
        createErrorResponse([formatZodError(result.error, targetMap[target])]),
        400,
      );
    }

    // Store validated data on context
    const contextKey = `validated${target.charAt(0).toUpperCase()}${target.slice(1)}`;
    c.set(contextKey, result.data);
    await next();
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// GENERIC VALIDATION HELPERS
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Type-safe schema validation wrapper for any framework.
 *
 * @example
 * const result = validateRequest(UserSchema, requestBody);
 * if (!result.success) return Response.json(result.error, { status: 400 });
 * const user = result.data;
 */
export function validateRequest<T>(
  schema: z.ZodType<T>,
  data: unknown,
): { success: true; data: T } | { success: false; error: ValidationErrorResponse } {
  const result = schema.safeParse(data);
  if (result.success) {
    return { success: true, data: result.data };
  }
  return {
    success: false,
    error: createErrorResponse([formatZodError(result.error, "body")]),
  };
}

/**
 * Validate and throw on failure. Use in trusted contexts (server actions, scripts).
 */
export function parseOrThrow<T>(schema: z.ZodType<T>, data: unknown, context?: string): T {
  const result = schema.safeParse(data);
  if (result.success) return result.data;

  const message = result.error.issues
    .map((i) => `${i.path.join(".")}: ${i.message}`)
    .join("; ");
  throw new Error(`${context ? `[${context}] ` : ""}Validation failed: ${message}`);
}
