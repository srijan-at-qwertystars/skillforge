// env-schema.ts — Complete environment validation setup (development/production)
//
// Usage:
//   import { env } from "./env-schema";
//   console.log(env.DATABASE_URL); // Typed, validated
//
// This module validates process.env at import time. If validation fails,
// it throws immediately with a clear error message listing all issues.
// This ensures your app fails fast on startup rather than at runtime.

import { z } from "zod";

// ─── Schema Definition ──────────────────────────────────────────────────────

const serverSchema = z.object({
  // ── Runtime ──
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),
  PORT: z.coerce.number().int().positive().default(3000),
  HOST: z.string().default("0.0.0.0"),

  // ── Database ──
  DATABASE_URL: z.string().url(),
  DATABASE_DIRECT_URL: z.string().url().optional(), // For Prisma direct connection
  DATABASE_POOL_MIN: z.coerce.number().int().nonnegative().default(2),
  DATABASE_POOL_MAX: z.coerce.number().int().positive().default(10),

  // ── Auth ──
  JWT_SECRET: z.string().min(32),
  JWT_ACCESS_EXPIRES: z.string().default("15m"),
  JWT_REFRESH_EXPIRES: z.string().default("7d"),
  SESSION_SECRET: z.string().min(32).optional(),
  BCRYPT_ROUNDS: z.coerce.number().int().min(10).max(15).default(12),

  // ── Redis / Cache ──
  REDIS_URL: z.string().url().optional(),
  CACHE_TTL_SECONDS: z.coerce.number().int().positive().default(300),

  // ── Email ──
  SMTP_HOST: z.string().optional(),
  SMTP_PORT: z.coerce.number().int().default(587),
  SMTP_USER: z.string().optional(),
  SMTP_PASS: z.string().optional(),
  SMTP_FROM: z.string().email().optional(),
  SMTP_SECURE: z
    .enum(["true", "false", "1", "0"])
    .transform((v) => v === "true" || v === "1")
    .default("false"),

  // ── Storage ──
  S3_BUCKET: z.string().optional(),
  S3_REGION: z.string().default("us-east-1"),
  S3_ACCESS_KEY_ID: z.string().optional(),
  S3_SECRET_ACCESS_KEY: z.string().optional(),
  S3_ENDPOINT: z.string().url().optional(), // For MinIO/R2

  // ── External APIs ──
  STRIPE_SECRET_KEY: z.string().startsWith("sk_").optional(),
  STRIPE_WEBHOOK_SECRET: z.string().startsWith("whsec_").optional(),
  OPENAI_API_KEY: z.string().startsWith("sk-").optional(),

  // ── Observability ──
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  LOG_FORMAT: z.enum(["json", "pretty"]).default("pretty"),
  SENTRY_DSN: z.string().url().optional(),
  OTEL_EXPORTER_ENDPOINT: z.string().url().optional(),

  // ── Feature Flags ──
  ENABLE_SIGNUP: z
    .enum(["true", "false", "1", "0"])
    .transform((v) => v === "true" || v === "1")
    .default("true"),
  ENABLE_MAINTENANCE_MODE: z
    .enum(["true", "false", "1", "0"])
    .transform((v) => v === "true" || v === "1")
    .default("false"),
  RATE_LIMIT_MAX: z.coerce.number().int().positive().default(100),
  RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
});

const clientSchema = z.object({
  NEXT_PUBLIC_API_URL: z.string().url().optional(),
  NEXT_PUBLIC_APP_NAME: z.string().default("MyApp"),
  NEXT_PUBLIC_APP_VERSION: z.string().default("0.0.0"),
  NEXT_PUBLIC_SENTRY_DSN: z.string().url().optional(),
  NEXT_PUBLIC_POSTHOG_KEY: z.string().optional(),
  NEXT_PUBLIC_GA_ID: z.string().optional(),
});

// ─── Cross-Field Validation ─────────────────────────────────────────────────

const fullSchema = serverSchema.merge(clientSchema).superRefine((env, ctx) => {
  // Production requirements
  if (env.NODE_ENV === "production") {
    if (!env.SESSION_SECRET) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "SESSION_SECRET is required in production",
        path: ["SESSION_SECRET"],
      });
    }
    if (env.LOG_LEVEL === "debug") {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "LOG_LEVEL should not be 'debug' in production",
        path: ["LOG_LEVEL"],
      });
    }
    if (env.LOG_FORMAT === "pretty") {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "LOG_FORMAT should be 'json' in production for structured logging",
        path: ["LOG_FORMAT"],
      });
    }
  }

  // Database pool constraints
  if (env.DATABASE_POOL_MIN > env.DATABASE_POOL_MAX) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "DATABASE_POOL_MIN cannot exceed DATABASE_POOL_MAX",
      path: ["DATABASE_POOL_MIN"],
    });
  }

  // SMTP: all-or-nothing
  const smtpConfigured = [env.SMTP_HOST, env.SMTP_USER, env.SMTP_PASS, env.SMTP_FROM];
  const smtpSetCount = smtpConfigured.filter(Boolean).length;
  if (smtpSetCount > 0 && smtpSetCount < smtpConfigured.length) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "All SMTP variables (HOST, USER, PASS, FROM) must be set together",
      path: ["SMTP_HOST"],
    });
  }

  // S3: all-or-nothing
  const s3Configured = [env.S3_BUCKET, env.S3_ACCESS_KEY_ID, env.S3_SECRET_ACCESS_KEY];
  const s3SetCount = s3Configured.filter(Boolean).length;
  if (s3SetCount > 0 && s3SetCount < s3Configured.length) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "All S3 variables (BUCKET, ACCESS_KEY_ID, SECRET_ACCESS_KEY) must be set together",
      path: ["S3_BUCKET"],
    });
  }

  // Stripe: if secret key is set, webhook secret should be too
  if (env.STRIPE_SECRET_KEY && !env.STRIPE_WEBHOOK_SECRET) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "STRIPE_WEBHOOK_SECRET should be set when STRIPE_SECRET_KEY is configured",
      path: ["STRIPE_WEBHOOK_SECRET"],
    });
  }
});

// ─── Parse & Export ─────────────────────────────────────────────────────────

function parseEnv() {
  const result = fullSchema.safeParse(process.env);

  if (!result.success) {
    const formatted = result.error.issues
      .map((issue) => `  ✗ ${issue.path.join(".")}: ${issue.message}`)
      .join("\n");

    console.error("\n╔══════════════════════════════════════════════╗");
    console.error("║  ❌ Invalid environment variables             ║");
    console.error("╚══════════════════════════════════════════════╝\n");
    console.error(formatted);
    console.error(`\n${result.error.issues.length} error(s) found. Fix your .env file.\n`);

    // In test environment, throw instead of exiting
    if (process.env.NODE_ENV === "test") {
      throw new Error(`Environment validation failed:\n${formatted}`);
    }
    process.exit(1);
  }

  return result.data;
}

/** Validated environment variables. Parsed at module load time. */
export const env = parseEnv();
export type Env = z.infer<typeof fullSchema>;

// ─── Type-Safe Access Helpers ───────────────────────────────────────────────

/** Check if running in production. */
export const isProduction = env.NODE_ENV === "production";
export const isDevelopment = env.NODE_ENV === "development";
export const isTest = env.NODE_ENV === "test";

/** Check if a service is configured. */
export const hasRedis = !!env.REDIS_URL;
export const hasSmtp = !!env.SMTP_HOST;
export const hasS3 = !!env.S3_BUCKET;
export const hasStripe = !!env.STRIPE_SECRET_KEY;
export const hasSentry = !!env.SENTRY_DSN;

// ─── .env.example Generator ─────────────────────────────────────────────────

/**
 * Generate a .env.example file from the schema.
 * Run: npx tsx -e "import { generateEnvExample } from './env-schema'; console.log(generateEnvExample())"
 */
export function generateEnvExample(): string {
  const lines: string[] = [
    "# ─── Auto-generated from env-schema.ts ───",
    "# Required variables are marked, optional have default or '(optional)' note.",
    "",
  ];

  const shape = serverSchema.merge(clientSchema).shape;

  for (const [key, zodType] of Object.entries(shape)) {
    const def = (zodType as any)._def;
    const isOptional = zodType.isOptional?.() || def.typeName === "ZodDefault";
    const description = def.description;

    let example = "";
    if (key.includes("SECRET") || key.includes("KEY") || key.includes("PASS")) {
      example = "change-me-to-a-secure-value";
    } else if (key.includes("URL")) {
      example = "http://localhost:5432/mydb";
    } else if (key.includes("PORT")) {
      example = "3000";
    }

    const comment = isOptional ? "# (optional) " : "# ";
    if (description) lines.push(`${comment}${description}`);
    lines.push(`${key}=${example}`);
    lines.push("");
  }

  return lines.join("\n");
}
