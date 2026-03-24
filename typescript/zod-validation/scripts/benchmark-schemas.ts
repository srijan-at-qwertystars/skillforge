#!/usr/bin/env npx tsx
// benchmark-schemas.ts — Benchmark Zod schema parsing performance
//
// Usage:
//   npx tsx benchmark-schemas.ts                  # Run all benchmarks
//   npx tsx benchmark-schemas.ts --iterations 50000  # Custom iteration count
//   npx tsx benchmark-schemas.ts --filter object   # Run only matching benchmarks
//   npx tsx benchmark-schemas.ts --json            # Output results as JSON
//
// Measures: parse throughput (ops/sec), average latency, and relative performance
// across different schema types and complexities.

import { z } from "zod";

// ─── Configuration ──────────────────────────────────────────────────────────

interface BenchmarkResult {
  name: string;
  opsPerSec: number;
  avgNs: number;
  iterations: number;
  passed: number;
  failed: number;
}

const DEFAULT_ITERATIONS = 10_000;

// ─── Schemas Under Test ─────────────────────────────────────────────────────

const StringSchema = z.string().email();
const NumberSchema = z.number().int().positive().max(1_000_000);

const SimpleObjectSchema = z.object({
  name: z.string().min(1),
  email: z.string().email(),
  age: z.number().int().positive(),
});

const NestedObjectSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1).max(100),
  email: z.string().email(),
  profile: z.object({
    bio: z.string().max(500),
    avatar: z.string().url().optional(),
    social: z.object({
      twitter: z.string().optional(),
      github: z.string().optional(),
    }),
  }),
  settings: z.object({
    theme: z.enum(["light", "dark"]),
    notifications: z.boolean(),
    language: z.string().default("en"),
  }),
});

const ArraySchema = z.array(
  z.object({
    id: z.number().int(),
    value: z.string(),
    active: z.boolean(),
  })
);

const UnionSchema = z.union([
  z.object({ type: z.literal("text"), content: z.string() }),
  z.object({ type: z.literal("image"), url: z.string().url(), width: z.number() }),
  z.object({ type: z.literal("video"), url: z.string().url(), duration: z.number() }),
]);

const DiscriminatedUnionSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("text"), content: z.string() }),
  z.object({ type: z.literal("image"), url: z.string().url(), width: z.number() }),
  z.object({ type: z.literal("video"), url: z.string().url(), duration: z.number() }),
]);

const TransformSchema = z.object({
  name: z.string().trim().toLowerCase(),
  email: z.string().trim().toLowerCase().email(),
  tags: z.string().transform((s) => s.split(",").map((t) => t.trim())),
});

const CoercionSchema = z.object({
  id: z.coerce.number().int(),
  active: z.coerce.boolean(),
  createdAt: z.coerce.date(),
});

const RefinementSchema = z.object({
  password: z.string().min(8),
  confirmPassword: z.string(),
}).refine((d) => d.password === d.confirmPassword, {
  message: "Passwords must match",
  path: ["confirmPassword"],
});

// ─── Test Data ──────────────────────────────────────────────────────────────

const validData: Record<string, unknown> = {
  "string (email)": "user@example.com",
  "number (int+positive)": 42,
  "simple object": { name: "John", email: "john@example.com", age: 30 },
  "nested object": {
    id: "550e8400-e29b-41d4-a716-446655440000",
    name: "Jane Doe",
    email: "jane@example.com",
    profile: {
      bio: "Software engineer",
      avatar: "https://example.com/avatar.jpg",
      social: { twitter: "@jane", github: "janedoe" },
    },
    settings: { theme: "dark", notifications: true, language: "en" },
  },
  "array (10 items)": Array.from({ length: 10 }, (_, i) => ({
    id: i, value: `item-${i}`, active: i % 2 === 0,
  })),
  "array (100 items)": Array.from({ length: 100 }, (_, i) => ({
    id: i, value: `item-${i}`, active: i % 2 === 0,
  })),
  "union (trial)": { type: "video", url: "https://example.com/v.mp4", duration: 120 },
  "discriminatedUnion": { type: "video", url: "https://example.com/v.mp4", duration: 120 },
  "transforms": { name: "  John DOE  ", email: "  JOHN@EXAMPLE.COM  ", tags: "ts, zod, validation" },
  "coercion": { id: "42", active: "true", createdAt: "2024-01-15" },
  "refinement (cross-field)": { password: "MyStr0ngP@ss", confirmPassword: "MyStr0ngP@ss" },
};

const schemas: Record<string, z.ZodSchema> = {
  "string (email)": StringSchema,
  "number (int+positive)": NumberSchema,
  "simple object": SimpleObjectSchema,
  "nested object": NestedObjectSchema,
  "array (10 items)": ArraySchema,
  "array (100 items)": ArraySchema,
  "union (trial)": UnionSchema,
  "discriminatedUnion": DiscriminatedUnionSchema,
  "transforms": TransformSchema,
  "coercion": CoercionSchema,
  "refinement (cross-field)": RefinementSchema,
};

// ─── Benchmark Engine ───────────────────────────────────────────────────────

function runBenchmark(
  name: string,
  schema: z.ZodSchema,
  data: unknown,
  iterations: number,
): BenchmarkResult {
  let passed = 0;
  let failed = 0;

  // Warmup
  for (let i = 0; i < Math.min(100, iterations); i++) {
    schema.safeParse(data);
  }

  const start = performance.now();
  for (let i = 0; i < iterations; i++) {
    const result = schema.safeParse(data);
    if (result.success) passed++;
    else failed++;
  }
  const elapsed = performance.now() - start;

  const opsPerSec = Math.round((iterations / elapsed) * 1000);
  const avgNs = Math.round((elapsed / iterations) * 1_000_000);

  return { name, opsPerSec, avgNs, iterations, passed, failed };
}

// ─── Output Formatting ─────────────────────────────────────────────────────

function printResults(results: BenchmarkResult[]): void {
  const maxName = Math.max(...results.map((r) => r.name.length), 4);
  const header = [
    "Schema".padEnd(maxName),
    "ops/sec".padStart(12),
    "avg (ns)".padStart(12),
    "status".padStart(8),
  ].join("  ");

  console.log("\n" + "─".repeat(header.length));
  console.log(header);
  console.log("─".repeat(header.length));

  const maxOps = Math.max(...results.map((r) => r.opsPerSec));

  for (const r of results) {
    const bar = "█".repeat(Math.round((r.opsPerSec / maxOps) * 20));
    const status = r.failed === 0 ? "✅ pass" : "⚠️  fail";
    console.log([
      r.name.padEnd(maxName),
      r.opsPerSec.toLocaleString().padStart(12),
      r.avgNs.toLocaleString().padStart(12),
      status.padStart(8),
      ` ${bar}`,
    ].join("  "));
  }

  console.log("─".repeat(header.length));
  console.log(`\nIterations per benchmark: ${results[0]?.iterations.toLocaleString()}\n`);
}

// ─── Main ───────────────────────────────────────────────────────────────────

function main(): void {
  const args = process.argv.slice(2);
  let iterations = DEFAULT_ITERATIONS;
  let filter: string | null = null;
  let jsonOutput = false;

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--iterations":
        iterations = parseInt(args[++i], 10);
        break;
      case "--filter":
        filter = args[++i].toLowerCase();
        break;
      case "--json":
        jsonOutput = true;
        break;
      case "--help":
        console.log("Usage: npx tsx benchmark-schemas.ts [--iterations N] [--filter pattern] [--json]");
        process.exit(0);
    }
  }

  console.log(`\n🔬 Zod Schema Benchmark`);
  console.log(`   Zod version: ${z.ZodString ? "3.x" : "4.x"}`);
  console.log(`   Iterations: ${iterations.toLocaleString()}`);
  if (filter) console.log(`   Filter: "${filter}"`);

  const results: BenchmarkResult[] = [];

  for (const [name, schema] of Object.entries(schemas)) {
    if (filter && !name.toLowerCase().includes(filter)) continue;
    const data = validData[name];
    if (data === undefined) {
      console.warn(`  ⚠ No test data for "${name}", skipping`);
      continue;
    }

    process.stdout.write(`  Running: ${name}...`);
    const result = runBenchmark(name, schema, data, iterations);
    results.push(result);
    process.stdout.write(` ${result.opsPerSec.toLocaleString()} ops/sec\n`);
  }

  if (jsonOutput) {
    console.log(JSON.stringify(results, null, 2));
  } else {
    printResults(results);

    // Highlight union vs discriminatedUnion comparison
    const unionResult = results.find((r) => r.name === "union (trial)");
    const discResult = results.find((r) => r.name === "discriminatedUnion");
    if (unionResult && discResult) {
      const speedup = (discResult.opsPerSec / unionResult.opsPerSec).toFixed(1);
      console.log(`💡 discriminatedUnion is ${speedup}x faster than union for this test case.\n`);
    }
  }
}

main();
