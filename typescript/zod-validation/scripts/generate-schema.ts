#!/usr/bin/env npx tsx
// generate-schema.ts — Generate Zod schemas from JSON sample data or TypeScript interfaces
//
// Usage:
//   npx tsx generate-schema.ts --json '{"name":"John","age":30,"email":"john@test.com"}'
//   npx tsx generate-schema.ts --json-file ./sample.json
//   npx tsx generate-schema.ts --json-file ./sample.json --name UserSchema
//   cat data.json | npx tsx generate-schema.ts --stdin
//
// Output: Prints a Zod schema definition to stdout.

const args = process.argv.slice(2);

function printUsage(): void {
  console.log(`
Usage:
  npx tsx generate-schema.ts --json '<json_string>'
  npx tsx generate-schema.ts --json-file <path>
  npx tsx generate-schema.ts --stdin
  npx tsx generate-schema.ts --json '...' --name MySchema

Options:
  --json <string>     Inline JSON data
  --json-file <path>  Path to a JSON file
  --stdin             Read JSON from stdin
  --name <name>       Schema variable name (default: GeneratedSchema)
  --export            Add export keyword
  --help              Show this help
`);
}

function inferZodType(value: unknown, indent: number = 0): string {
  const pad = "  ".repeat(indent);

  if (value === null) return "z.null()";
  if (value === undefined) return "z.undefined()";

  switch (typeof value) {
    case "string":
      return inferStringType(value);
    case "number":
      if (Number.isInteger(value)) return "z.number().int()";
      return "z.number()";
    case "boolean":
      return "z.boolean()";
    case "bigint":
      return "z.bigint()";
    default:
      break;
  }

  if (Array.isArray(value)) {
    if (value.length === 0) return "z.array(z.unknown())";

    // Infer element type from first element, check homogeneity
    const types = new Set(value.map((v) => typeof v));
    if (types.size === 1 && typeof value[0] !== "object") {
      return `z.array(${inferZodType(value[0], indent)})`;
    }

    if (value.every((v) => typeof v === "object" && v !== null && !Array.isArray(v))) {
      // Array of objects — merge all keys for a comprehensive schema
      const allKeys = new Map<string, unknown>();
      const requiredKeys = new Set<string>();

      // First pass: collect all keys
      for (const obj of value as Record<string, unknown>[]) {
        for (const [key, val] of Object.entries(obj)) {
          if (!allKeys.has(key)) allKeys.set(key, val);
        }
      }

      // Second pass: determine which keys appear in all objects
      for (const key of allKeys.keys()) {
        if ((value as Record<string, unknown>[]).every((obj) => key in obj)) {
          requiredKeys.add(key);
        }
      }

      const fields: string[] = [];
      for (const [key, val] of allKeys) {
        const fieldType = inferZodType(val, indent + 2);
        const optional = requiredKeys.has(key) ? "" : ".optional()";
        fields.push(`${"  ".repeat(indent + 2)}${safeName(key)}: ${fieldType}${optional},`);
      }

      return `z.array(z.object({\n${fields.join("\n")}\n${"  ".repeat(indent + 1)}}))`;
    }

    // Mixed array
    return `z.array(z.unknown())`;
  }

  if (typeof value === "object" && value !== null) {
    const entries = Object.entries(value as Record<string, unknown>);
    if (entries.length === 0) return "z.object({})";

    const fields = entries.map(([key, val]) => {
      const fieldType = inferZodType(val, indent + 1);
      return `${"  ".repeat(indent + 1)}${safeName(key)}: ${fieldType},`;
    });

    return `z.object({\n${fields.join("\n")}\n${"  ".repeat(indent)}})`;
  }

  return "z.unknown()";
}

function inferStringType(value: string): string {
  // Email pattern
  if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) return "z.string().email()";
  // UUID
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) return "z.string().uuid()";
  // URL
  if (/^https?:\/\/.+/.test(value)) return "z.string().url()";
  // ISO datetime
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(value)) return "z.string().datetime()";
  // ISO date
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return "z.string().date()";
  // IP address
  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(value)) return "z.string().ip()";

  return "z.string()";
}

function safeName(key: string): string {
  return /^[a-zA-Z_$][a-zA-Z0-9_$]*$/.test(key) ? key : `"${key}"`;
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf-8");
}

async function main(): Promise<void> {
  if (args.includes("--help") || args.length === 0) {
    printUsage();
    process.exit(0);
  }

  let jsonStr = "";
  let schemaName = "GeneratedSchema";
  let useExport = args.includes("--export");

  // Parse args
  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--json":
        jsonStr = args[++i];
        break;
      case "--json-file": {
        const fs = await import("fs");
        jsonStr = fs.readFileSync(args[++i], "utf-8");
        break;
      }
      case "--stdin":
        jsonStr = await readStdin();
        break;
      case "--name":
        schemaName = args[++i];
        break;
    }
  }

  if (!jsonStr.trim()) {
    console.error("Error: No JSON input provided.");
    process.exit(1);
  }

  let data: unknown;
  try {
    data = JSON.parse(jsonStr);
  } catch {
    console.error("Error: Invalid JSON input.");
    process.exit(1);
  }

  const zodExpr = inferZodType(data, 0);
  const exportKw = useExport ? "export " : "";

  console.log(`import { z } from "zod";\n`);
  console.log(`${exportKw}const ${schemaName} = ${zodExpr};\n`);
  console.log(`${exportKw}type ${schemaName} = z.infer<typeof ${schemaName}>;\n`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
