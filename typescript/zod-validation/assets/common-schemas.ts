// common-schemas.ts — Library of reusable Zod schemas for common validation patterns
//
// Usage:
//   import { emailSchema, passwordSchema, paginationSchema } from "./common-schemas";

import { z } from "zod";

// ─── String Formats ─────────────────────────────────────────────────────────

/** Trimmed, lowercased, RFC-compliant email. Max 254 chars per spec. */
export const emailSchema = z.string().trim().toLowerCase().email().max(254);

/** Strong password: 8+ chars, uppercase, lowercase, digit, special char. */
export const passwordSchema = z
  .string()
  .min(8, "Password must be at least 8 characters")
  .max(128, "Password must be at most 128 characters")
  .regex(/[A-Z]/, "Password must contain at least one uppercase letter")
  .regex(/[a-z]/, "Password must contain at least one lowercase letter")
  .regex(/[0-9]/, "Password must contain at least one digit")
  .regex(/[^A-Za-z0-9]/, "Password must contain at least one special character");

/** E.164 international phone number: +1234567890 */
export const phoneSchema = z
  .string()
  .regex(/^\+[1-9]\d{1,14}$/, "Phone must be in E.164 format: +1234567890");

/** URL with http or https only. */
export const urlSchema = z.string().url().regex(/^https?:\/\//, "URL must use http or https");

/** Slug: lowercase letters, numbers, hyphens. 1-100 chars. */
export const slugSchema = z
  .string()
  .min(1)
  .max(100)
  .regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/, "Must be a valid slug (lowercase, hyphens)");

/** Non-empty trimmed string. Use for required text fields. */
export const requiredStringSchema = z.string().trim().min(1, "This field is required");

/** UUID v4 string. */
export const uuidSchema = z.string().uuid();

/** Hex color code: #RGB or #RRGGBB. */
export const hexColorSchema = z
  .string()
  .regex(/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/, "Must be a valid hex color");

/** Semantic version: 1.2.3, 1.0.0-beta.1 */
export const semverSchema = z
  .string()
  .regex(
    /^\d+\.\d+\.\d+(-[a-zA-Z0-9]+(\.[a-zA-Z0-9]+)*)?$/,
    "Must be a valid semantic version"
  );

/** ISO 8601 date string (YYYY-MM-DD) */
export const dateStringSchema = z.string().date();

/** ISO 8601 datetime string */
export const datetimeStringSchema = z.string().datetime();

// ─── Numeric Types ──────────────────────────────────────────────────────────

/** Positive integer ID (database-style). */
export const idSchema = z.number().int().positive();

/** Non-negative integer for counts, quantities. */
export const countSchema = z.number().int().nonnegative();

/** Percentage: 0-100, allows decimals. */
export const percentageSchema = z.number().min(0).max(100);

/** Monetary amount: non-negative, two decimal places max. */
export const moneySchema = z.number().nonnegative().multipleOf(0.01);

/** Port number: 1-65535. */
export const portSchema = z.number().int().min(1).max(65535);

// ─── Date Ranges ────────────────────────────────────────────────────────────

/** Date range with start <= end validation. */
export const dateRangeSchema = z
  .object({
    startDate: z.coerce.date(),
    endDate: z.coerce.date(),
  })
  .refine((d) => d.endDate >= d.startDate, {
    message: "End date must be on or after start date",
    path: ["endDate"],
  });

/** Optional date range — both dates must be provided, or neither. */
export const optionalDateRangeSchema = z
  .object({
    startDate: z.coerce.date().optional(),
    endDate: z.coerce.date().optional(),
  })
  .refine(
    (d) => {
      if (d.startDate && !d.endDate) return false;
      if (!d.startDate && d.endDate) return false;
      if (d.startDate && d.endDate) return d.endDate >= d.startDate;
      return true;
    },
    { message: "Both dates must be provided, and end must be after start" }
  );

// ─── Pagination ─────────────────────────────────────────────────────────────

/** Standard cursor-based pagination params. */
export const cursorPaginationSchema = z.object({
  cursor: z.string().optional(),
  limit: z.coerce.number().int().positive().max(100).default(20),
  direction: z.enum(["forward", "backward"]).default("forward"),
});

/** Standard offset-based pagination params. */
export const offsetPaginationSchema = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().positive().max(100).default(20),
  sortBy: z.string().optional(),
  sortOrder: z.enum(["asc", "desc"]).default("desc"),
});

export type CursorPagination = z.infer<typeof cursorPaginationSchema>;
export type OffsetPagination = z.infer<typeof offsetPaginationSchema>;

// ─── Search & Filtering ─────────────────────────────────────────────────────

/** Search query with pagination. */
export const searchQuerySchema = z.object({
  q: z.string().trim().min(1, "Search query is required").max(200),
  ...offsetPaginationSchema.shape,
  filters: z.record(z.string(), z.string().or(z.array(z.string()))).optional(),
});

// ─── Address ────────────────────────────────────────────────────────────────

/** US mailing address. */
export const usAddressSchema = z.object({
  line1: z.string().min(1).max(200),
  line2: z.string().max(200).optional(),
  city: z.string().min(1).max(100),
  state: z.string().length(2).toUpperCase(),
  zipCode: z.string().regex(/^\d{5}(-\d{4})?$/, "Must be a valid ZIP code"),
  country: z.literal("US").default("US"),
});

/** Generic international address. */
export const addressSchema = z.object({
  line1: z.string().min(1).max(200),
  line2: z.string().max(200).optional(),
  city: z.string().min(1).max(100),
  region: z.string().max(100).optional(),
  postalCode: z.string().max(20).optional(),
  country: z.string().length(2).toUpperCase(), // ISO 3166-1 alpha-2
});

// ─── Auth Schemas ───────────────────────────────────────────────────────────

/** Login credentials. */
export const loginSchema = z.object({
  email: emailSchema,
  password: z.string().min(1, "Password is required"),
  rememberMe: z.boolean().default(false),
});

/** Registration with password confirmation. */
export const registrationSchema = z
  .object({
    name: requiredStringSchema.max(100),
    email: emailSchema,
    password: passwordSchema,
    confirmPassword: z.string(),
    acceptTerms: z.literal(true, {
      errorMap: () => ({ message: "You must accept the terms" }),
    }),
  })
  .refine((d) => d.password === d.confirmPassword, {
    message: "Passwords do not match",
    path: ["confirmPassword"],
  });

/** Password change with current password verification. */
export const changePasswordSchema = z
  .object({
    currentPassword: z.string().min(1, "Current password is required"),
    newPassword: passwordSchema,
    confirmNewPassword: z.string(),
  })
  .refine((d) => d.newPassword === d.confirmNewPassword, {
    message: "Passwords do not match",
    path: ["confirmNewPassword"],
  })
  .refine((d) => d.currentPassword !== d.newPassword, {
    message: "New password must differ from current password",
    path: ["newPassword"],
  });

// ─── File Upload Metadata ───────────────────────────────────────────────────

/** File upload constraints (browser File API). */
export const fileUploadSchema = z.object({
  name: z.string().min(1),
  size: z.number().int().positive().max(50 * 1024 * 1024, "File must be under 50MB"),
  type: z.string().regex(/^[a-z]+\/[a-z0-9.+-]+$/, "Invalid MIME type"),
});

/** Image file constraints. */
export const imageUploadSchema = fileUploadSchema.extend({
  type: z.enum(["image/jpeg", "image/png", "image/webp", "image/gif", "image/svg+xml"]),
  size: z.number().int().positive().max(10 * 1024 * 1024, "Image must be under 10MB"),
});

// ─── API Response Wrappers ──────────────────────────────────────────────────

/** Standard success response wrapper. */
export function successResponseSchema<T extends z.ZodTypeAny>(dataSchema: T) {
  return z.object({
    success: z.literal(true),
    data: dataSchema,
    meta: z.object({
      requestId: z.string().optional(),
      timestamp: z.string().datetime().optional(),
    }).optional(),
  });
}

/** Standard error response wrapper. */
export const errorResponseSchema = z.object({
  success: z.literal(false),
  error: z.object({
    code: z.string(),
    message: z.string(),
    details: z.array(z.object({
      field: z.string().optional(),
      message: z.string(),
    })).optional(),
  }),
});

/** Paginated response wrapper. */
export function paginatedResponseSchema<T extends z.ZodTypeAny>(itemSchema: T) {
  return z.object({
    data: z.array(itemSchema),
    pagination: z.object({
      page: z.number().int().positive(),
      limit: z.number().int().positive(),
      total: z.number().int().nonnegative(),
      totalPages: z.number().int().nonnegative(),
      hasNext: z.boolean(),
      hasPrevious: z.boolean(),
    }),
  });
}

// ─── Type Exports ───────────────────────────────────────────────────────────

export type Email = z.infer<typeof emailSchema>;
export type Password = z.infer<typeof passwordSchema>;
export type Phone = z.infer<typeof phoneSchema>;
export type DateRange = z.infer<typeof dateRangeSchema>;
export type SearchQuery = z.infer<typeof searchQuerySchema>;
export type USAddress = z.infer<typeof usAddressSchema>;
export type Address = z.infer<typeof addressSchema>;
export type LoginInput = z.infer<typeof loginSchema>;
export type RegistrationInput = z.infer<typeof registrationSchema>;
export type ChangePasswordInput = z.infer<typeof changePasswordSchema>;
