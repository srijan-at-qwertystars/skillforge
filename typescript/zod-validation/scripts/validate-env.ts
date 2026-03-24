#!/usr/bin/env npx tsx
// validate-env.ts — Environment variable validation script template with Zod
//
// Usage:
//   npx tsx validate-env.ts                     # Validate current environment
//   npx tsx validate-env.ts --env .env.local    # Validate a specific .env file
//   npx tsx validate-env.ts --strict            # Fail on unknown variables
//   npx tsx validate-env.ts --print             # Print parsed values (redacted)
//
// Customize the schema below for your project, then run at build time or
// in CI to catch missing/invalid environment variables early.
//
// Integration:
//   package.json: { "scripts": { "check-env": "tsx validate-env.ts" } }
//   CI: Add `npm run check-env` before `npm run build`

import { z } from "zod";

// ─── CUSTOMIZE THIS SCHEMA ──────────────────────────────────────────────────

const envSchema = z.object({
  // ── Core ──
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),
  PORT: z.coerce.number().int().positive().default(3000),
  HOST: z.string().default("0.0.0.0"),

  // ── Database ──
  DATABASE_URL: z.string().url().describe("PostgreSQL connection string"),
  DATABASE_POOL_SIZE: z.coerce.number().int().positive().default(10),

  // ── Auth ──
  JWT_SECRET: z.string().min(32, "JWT_SECRET must be at least 32 characters"),
  JWT_EXPIRES_IN: z.string().default("7d"),
  SESSION_SECRET: z.string().min(32).optional(),

  // ── External Services ──
  REDIS_URL: z.string().url().optional(),
  SMTP_HOST: z.string().optional(),
  SMTP_PORT: z.coerce.number().int().default(587),
  SMTP_USER: z.string().optional(),
  SMTP_PASS: z.string().optional(),

  // ── API Keys ──
  API_KEY: z.string().min(1).optional(),
  STRIPE_SECRET_KEY: z.string().startsWith("sk_").optional(),
  STRIPE_WEBHOOK_SECRET: z.string().startsWith("whsec_").optional(),

  // ── Observability ──
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  SENTRY_DSN: z.string().url().optional(),

  // ── Client-Side (Next.js pattern) ──
  NEXT_PUBLIC_API_URL: z.string().url().optional(),
  NEXT_PUBLIC_APP_NAME: z.string().default("MyApp"),
});

// ─── Conditional validation ─────────────────────────────────────────────────

const envSchemaWithRules = envSchema.superRefine((env, ctx) => {
  // Production requires stricter config
  if (env.NODE_ENV === "production") {
    if (!env.SESSION_SECRET) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "SESSION_SECRET is required in production", path: ["SESSION_SECRET"] });
    }
    if (!env.SENTRY_DSN) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "SENTRY_DSN is recommended in production", path: ["SENTRY_DSN"] });
    }
    if (env.LOG_LEVEL === "debug") {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "LOG_LEVEL should not be 'debug' in production", path: ["LOG_LEVEL"] });
    }
  }

  // SMTP requires all fields if any are set
  const smtpFields = [env.SMTP_HOST, env.SMTP_USER, env.SMTP_PASS];
  const smtpSet = smtpFields.filter(Boolean).length;
  if (smtpSet > 0 && smtpSet < 3) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "If any SMTP_* variable is set, SMTP_HOST, SMTP_USER, and SMTP_PASS are all required",
      path: ["SMTP_HOST"],
    });
  }
});

// ─── Script logic ───────────────────────────────────────────────────────────

const SENSITIVE_KEYS = new Set([
  "JWT_SECRET", "SESSION_SECRET", "DATABASE_URL", "REDIS_URL",
  "SMTP_PASS", "API_KEY", "STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "SENTRY_DSN",
]);

function redact(key: string, value: unknown): string {
  if (value === undefined || value === null) return "(not set)";
  const str = String(value);
  if (SENSITIVE_KEYS.has(key)) {
    if (str.length <= 8) return "****";
    return str.slice(0, 4) + "****" + str.slice(-4);
  }
  return str;
}

async function loadDotEnv(filepath: string): Promise<void> {
  const fs = await import("fs");
  const path = await import("path");
  const resolved = path.resolve(filepath);

  if (!fs.existsSync(resolved)) {
    console.error(`Error: File not found: ${resolved}`);
    process.exit(1);
  }

  const content = fs.readFileSync(resolved, "utf-8");
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eqIdx = trimmed.indexOf("=");
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    let value = trimmed.slice(eqIdx + 1).trim();
    // Strip surrounding quotes
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) {
      process.env[key] = value;
    }
  }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  let shouldPrint = false;

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--env":
        await loadDotEnv(args[++i]);
        break;
      case "--print":
        shouldPrint = true;
        break;
      case "--help":
        console.log("Usage: npx tsx validate-env.ts [--env <file>] [--print] [--help]");
        process.exit(0);
    }
  }

  const result = envSchemaWithRules.safeParse(process.env);

  if (!result.success) {
    console.error("\n❌ Environment validation failed:\n");
    for (const issue of result.error.issues) {
      const path = issue.path.join(".");
      console.error(`  ${path}: ${issue.message}`);
    }
    console.error(`\n${result.error.issues.length} error(s) found.\n`);
    process.exit(1);
  }

  console.log("✅ Environment variables are valid.\n");

  if (shouldPrint) {
    console.log("Parsed values (sensitive values redacted):\n");
    const entries = Object.entries(result.data as Record<string, unknown>);
    const maxKeyLen = Math.max(...entries.map(([k]) => k.length));
    for (const [key, value] of entries) {
      console.log(`  ${key.padEnd(maxKeyLen)}  ${redact(key, value)}`);
    }
    console.log();
  }
}

main().catch((err) => {
  console.error("Unexpected error:", err);
  process.exit(1);
});
