# Deno Troubleshooting Guide

## Table of Contents

- [Node.js Compatibility Gaps](#nodejs-compatibility-gaps)
- [npm Package Compatibility Problems](#npm-package-compatibility-problems)
- [Permission Denied Debugging](#permission-denied-debugging)
- [Import Map Resolution Issues](#import-map-resolution-issues)
- [Lock File Conflicts](#lock-file-conflicts)
- [deno.json vs package.json Conflicts](#denojson-vs-packagejson-conflicts)
- [TypeScript Strict Mode Issues](#typescript-strict-mode-issues)
- [Deploy Cold Start Optimization](#deploy-cold-start-optimization)
- [KV Consistency Gotchas](#kv-consistency-gotchas)
- [Common Error Messages Reference](#common-error-messages-reference)

---

## Node.js Compatibility Gaps

### node:* Polyfills That Don't Fully Work

Deno provides `node:*` built-in polyfills, but some have incomplete implementations:

**`node:cluster`** — Not supported. Deno uses a single-process model with Web Workers.

```typescript
// ❌ Will not work
import cluster from "node:cluster";
// Error: Module not found "node:cluster"

// ✅ Alternative: use Deno Web Workers
const worker = new Worker(new URL("./worker.ts", import.meta.url).href, {
  type: "module",
});
```

**`node:dgram`** — UDP sockets have limited support.

```typescript
// ❌ Partial support — may fail in some scenarios
import dgram from "node:dgram";

// ✅ Use Deno native API instead
const listener = Deno.listenDatagram({ port: 8080, transport: "udp" });
```

**`node:vm`** — The `vm` module is partially implemented. `vm.createContext` and
`vm.runInContext` may not fully isolate like Node.js.

**`node:worker_threads`** — Supported but with differences in shared memory behavior.
`SharedArrayBuffer` transfer works, but `Atomics.waitAsync` may differ.

**`node:child_process`** — Use `Deno.Command` instead for better integration:

```typescript
// ❌ Works but loses Deno permission benefits
import { exec } from "node:child_process";

// ✅ Preferred — integrates with permission system
const cmd = new Deno.Command("ls", {
  args: ["-la"],
  stdout: "piped",
});
const { stdout } = await cmd.output();
console.log(new TextDecoder().decode(stdout));
```

**`node:crypto`** — Most functions work, but some OpenSSL-specific features
(custom engines, some cipher modes) are missing. `crypto.subtle` (Web Crypto)
is always available and preferred.

**`node:dns`** — `dns.resolve` works but custom resolvers (`dns.setServers`)
may not fully work on all platforms.

**`node:net`** — TCP sockets work but Unix domain sockets have limited support
on some platforms.

### Checking Compatibility

```bash
# Run the Deno Node.js compatibility checker
deno info --node-modules-dir npm:your-package
```

---

## npm Package Compatibility Problems

### Packages That Require Native Addons

Packages using `node-gyp` or native C++ addons won't work:

```typescript
// ❌ These require native compilation — will fail
import sharp from "npm:sharp";       // C++ image processing
import bcrypt from "npm:bcrypt";     // C++ bcrypt
import sqlite3 from "npm:sqlite3";   // C++ SQLite bindings

// ✅ Alternatives
import { ImageMagick } from "npm:@imagemagick/magick-wasm";  // WASM-based
import * as bcryptjs from "npm:bcryptjs";                     // Pure JS
// Use Deno.openKv() for SQLite or npm:better-sqlite3 (FFI-based)
```

### Packages with Postinstall Scripts

Some npm packages depend on `postinstall` scripts that run native builds:

```bash
# If npm package fails with "lifecycle script" errors:
# Try using --node-modules-dir to force a node_modules layout
deno run --node-modules-dir=auto --allow-read main.ts

# Or add to deno.json
# { "nodeModulesDir": "auto" }
```

### CommonJS-Only Packages

Some packages only ship CommonJS and may fail:

```typescript
// ❌ CJS-only packages may cause issues
import pkg from "npm:old-cjs-package";
// Error: require() is not a function

// ✅ Try with nodeModulesDir
// In deno.json: { "nodeModulesDir": "auto" }
// Then: deno run --allow-read main.ts
```

### Packages Using `__dirname` or `__filename`

```typescript
// ❌ Not available in Deno ESM context
console.log(__dirname);  // ReferenceError

// ✅ Deno equivalent
const __dirname = new URL(".", import.meta.url).pathname;
const __filename = new URL("", import.meta.url).pathname;

// ✅ For npm packages — Deno auto-shims these in node: compat mode
// Usually works transparently, but if not:
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
const __filename2 = fileURLToPath(import.meta.url);
const __dirname2 = dirname(__filename2);
```

### Version Resolution Issues

```bash
# Check what version Deno resolved
deno info npm:express@4
# Shows the dependency tree

# Force a specific version
deno cache --reload npm:express@4.18.2

# Clear the npm cache entirely
rm -rf ~/.cache/deno/npm/
```

---

## Permission Denied Debugging

### Identifying Missing Permissions

When you get `PermissionDenied`, Deno tells you exactly what's needed:

```
error: Uncaught (in promise) PermissionDenied: Requires read access to "./config",
run again with the --allow-read flag
```

### Common Permission Mistakes

**Forgetting the path separator:**
```bash
# ❌ Tries to read literally "./data" — won't match "./data/file.txt"
deno run --allow-read=./data main.ts

# ✅ Both work — Deno allows subdirectory access
deno run --allow-read=./data main.ts
# ./data/file.txt ← allowed
# ./data/sub/file.txt ← allowed
# ./other/file.txt ← denied
```

**Network permissions need port:**
```bash
# ❌ Allows connecting to api.example.com on any port, but your code
# may also need localhost for the server
deno run --allow-net=api.example.com main.ts
# Error: requires net access to "0.0.0.0:8000"

# ✅ Include both the server bind address and external APIs
deno run --allow-net=0.0.0.0:8000,api.example.com main.ts
```

**Env variable permissions:**
```bash
# ❌ Allows all env vars — security risk
deno run --allow-env main.ts

# ✅ Scope to specific variables
deno run --allow-env=DATABASE_URL,API_KEY,PORT main.ts
```

### Permission Debugging Script

```typescript
// debug-permissions.ts — run to check what permissions your app needs
const checks: Array<{ name: string; check: () => Promise<Deno.PermissionStatus> }> = [
  { name: "read:./config", check: () => Deno.permissions.query({ name: "read", path: "./config" }) },
  { name: "write:./output", check: () => Deno.permissions.query({ name: "write", path: "./output" }) },
  { name: "net:0.0.0.0:8000", check: () => Deno.permissions.query({ name: "net", host: "0.0.0.0:8000" }) },
  { name: "env:DATABASE_URL", check: () => Deno.permissions.query({ name: "env", variable: "DATABASE_URL" }) },
];

for (const { name, check } of checks) {
  const status = await check();
  const icon = status.state === "granted" ? "✅" : status.state === "prompt" ? "⚠️" : "❌";
  console.log(`${icon} ${name}: ${status.state}`);
}
```

### Deny Flag Gotchas

```bash
# Deny flags override allow flags
deno run --allow-read --deny-read=./secrets main.ts
# Can read everything EXCEPT ./secrets

# ❌ Common mistake — deny overrides even specific allows
deno run --allow-read=./secrets --deny-read=./secrets main.ts
# ./secrets is DENIED (deny wins)
```

---

## Import Map Resolution Issues

### Import Map Not Found

```
error: Relative import path "~/utils.ts" not prefixed with / or ./ or ../ and
not in import map
```

**Cause:** deno.json import map not being picked up.

```bash
# Check that deno.json is in the working directory or parent
deno info  # Shows which config file Deno found

# Explicitly specify config
deno run --config=./deno.json main.ts
```

### Conflicting Specifiers

```jsonc
// ❌ Ambiguous — both could match "@std/http"
{
  "imports": {
    "@std/http": "jsr:@std/http@^1.0.0",
    "@std/http/": "jsr:@std/http@^0.224.0/"
  }
}

// ✅ Use consistent versions
{
  "imports": {
    "@std/http": "jsr:@std/http@^1.0.0"
  }
}
```

### Trailing Slash Matters

```jsonc
{
  "imports": {
    // Without trailing slash — exact match only
    "mylib": "./src/mylib/mod.ts",
    // With trailing slash — prefix match (allows subpath imports)
    "mylib/": "./src/mylib/"
  }
}
```

```typescript
import { main } from "mylib";           // → ./src/mylib/mod.ts
import { helper } from "mylib/utils.ts"; // → ./src/mylib/utils.ts (needs trailing slash entry)
```

### Resolving Version Conflicts

```bash
# See the full resolution of all imports
deno info main.ts

# Force re-resolution
deno cache --reload main.ts

# Check for duplicate versions
deno info main.ts 2>&1 | grep -i "duplicate"
```

---

## Lock File Conflicts

### Lock File Integrity Errors

```
error: The source code is invalid, as it does not match the expected hash in
the lock file.
```

**Causes and fixes:**

```bash
# 1. Dependencies were updated upstream — regenerate lock file
deno cache --lock=deno.lock --lock-write main.ts

# 2. Lock file conflicts after merge
git checkout --theirs deno.lock  # Accept incoming
deno cache --reload --lock=deno.lock --lock-write main.ts

# 3. Corrupted cache — clear and rebuild
rm -rf ~/.cache/deno/
deno cache --lock=deno.lock --lock-write main.ts
```

### Lock File in CI

```yaml
# GitHub Actions — verify lock file integrity
- name: Verify dependencies
  run: deno cache --lock=deno.lock --frozen main.ts
  # --frozen prevents any modifications to the lock file
```

### Disabling Lock File

```jsonc
// deno.json — disable lock file (not recommended for production)
{
  "lock": false
}
```

```bash
# Or per-command
deno run --no-lock main.ts
```

---

## deno.json vs package.json Conflicts

### Both Files Present

When both `deno.json` and `package.json` exist, Deno uses `deno.json` as the
primary config but reads `package.json` for npm dependencies.

**Common conflicts:**

```jsonc
// ❌ Conflicting TypeScript settings
// deno.json
{ "compilerOptions": { "strict": true, "jsx": "react-jsx" } }
// tsconfig.json (from package.json project)
{ "compilerOptions": { "strict": false, "jsx": "react" } }
// Fix: Remove tsconfig.json — deno.json takes precedence

// ❌ Conflicting scripts/tasks
// package.json
{ "scripts": { "test": "jest" } }
// deno.json
{ "tasks": { "test": "deno test" } }
// Fix: "deno task test" uses deno.json, "npm test" uses package.json
```

### Migration Strategy

```jsonc
// Step 1: Keep package.json for npm deps, add deno.json for config
// deno.json
{
  "nodeModulesDir": "auto",
  "tasks": {
    "dev": "deno run --allow-net --watch main.ts",
    "test": "deno test --allow-read"
  }
}

// Step 2: Move deps from package.json to deno.json imports
{
  "imports": {
    "express": "npm:express@4",
    "zod": "npm:zod@3"
  }
}

// Step 3: Once migrated, remove package.json
```

### nodeModulesDir Modes

```jsonc
// "none" — no node_modules directory (default for Deno projects)
{ "nodeModulesDir": "none" }

// "auto" — creates node_modules when npm: packages are used
{ "nodeModulesDir": "auto" }

// "manual" — you manage node_modules with npm/yarn
{ "nodeModulesDir": "manual" }
```

---

## TypeScript Strict Mode Issues

### Common Strict Mode Errors

**Implicit any:**
```typescript
// ❌ Error: Parameter 'x' implicitly has an 'any' type
function double(x) { return x * 2; }

// ✅ Add type annotation
function double(x: number): number { return x * 2; }
```

**Strict null checks:**
```typescript
// ❌ Error: Object is possibly 'undefined'
const value = map.get("key");
console.log(value.toUpperCase());

// ✅ Handle undefined
const value = map.get("key");
if (value !== undefined) {
  console.log(value.toUpperCase());
}
// Or use non-null assertion (only when you're certain)
console.log(value!.toUpperCase());
```

**Index signatures:**
```typescript
// ❌ Error: Element implicitly has an 'any' type because type '{}' has no index signature
const obj: Record<string, unknown> = {};
const val = obj["key"];

// ✅ Use proper typing
interface Config {
  [key: string]: string | number | boolean;
}
const config: Config = {};
```

### Relaxing Strict Mode for Migration

```jsonc
// deno.json — temporarily relax for migration
{
  "compilerOptions": {
    "strict": false,
    // Or be granular:
    "noImplicitAny": false,
    "strictNullChecks": true,
    "strictFunctionTypes": true
  }
}
```

### JSX TypeScript Issues

```jsonc
// ❌ Wrong JSX config for Preact/Fresh
{
  "compilerOptions": {
    "jsx": "react"  // Wrong — generates React.createElement calls
  }
}

// ✅ Correct for Preact/Fresh
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "preact"
  }
}

// ✅ Correct for React
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "react"
  }
}
```

---

## Deploy Cold Start Optimization

### Understanding Cold Starts

Deno Deploy isolates start fresh when idle. First request after idle period
experiences a cold start (typically 50–200ms).

### Minimizing Cold Start Time

**Keep top-level code minimal:**
```typescript
// ❌ Heavy work at module load time
const db = await connectToDatabase();  // Blocks cold start
const cache = await loadEntireCache();  // Blocks cold start

Deno.serve((req) => handleRequest(req, db, cache));

// ✅ Lazy initialization
let db: Database | null = null;
async function getDb(): Promise<Database> {
  if (!db) db = await connectToDatabase();
  return db;
}

Deno.serve(async (req) => {
  const database = await getDb();
  return handleRequest(req, database);
});
```

**Minimize imports:**
```typescript
// ❌ Import everything
import * as std from "jsr:@std/all";

// ✅ Import only what you need
import { join } from "jsr:@std/path/join";
```

**Use dynamic imports for rare code paths:**
```typescript
Deno.serve(async (req) => {
  const url = new URL(req.url);

  if (url.pathname === "/admin/report") {
    // Only loaded when admin report is requested
    const { generateReport } = await import("./admin/report.ts");
    return Response.json(await generateReport());
  }

  return handleNormalRequest(req);
});
```

### Monitoring Cold Starts

```typescript
const startTime = performance.now();

Deno.serve((req) => {
  const uptime = performance.now() - startTime;
  return Response.json({
    uptime_ms: uptime,
    cold_start: uptime < 1000,  // Heuristic
  });
});
```

---

## KV Consistency Gotchas

### Eventual Consistency on Reads

On Deno Deploy, KV reads default to "eventual" consistency for performance.
This means you may read stale data:

```typescript
const kv = await Deno.openKv();

// ❌ May read stale data after a write
await kv.set(["counter"], 42);
const entry = await kv.get(["counter"]);
// entry.value might be an older value on Deploy!

// ✅ Use strong consistency when you need it
const entry2 = await kv.get(["counter"], { consistency: "strong" });
// Guaranteed to read the latest value
```

### Atomic Check Failures

```typescript
// ❌ Not handling check failures
const entry = await kv.get(["config"]);
const result = await kv.atomic()
  .check(entry)
  .set(["config"], newConfig)
  .commit();
// result.ok might be false!

// ✅ Always check result and retry
async function updateConfig(newConfig: unknown): Promise<void> {
  for (let i = 0; i < 10; i++) {
    const entry = await kv.get(["config"], { consistency: "strong" });
    const result = await kv.atomic()
      .check(entry)
      .set(["config"], newConfig)
      .commit();
    if (result.ok) return;
    // Another writer changed it — retry
    await new Promise((r) => setTimeout(r, Math.random() * 100));
  }
  throw new Error("Failed to update config after 10 retries");
}
```

### Key Size and Value Limits

```typescript
// Key: max 2048 bytes total across all parts
// Value: max 64 KiB per entry

// ❌ Storing large objects
await kv.set(["data"], hugeObject);  // May exceed 64 KiB

// ✅ Chunk large data
async function setLargeValue(kv: Deno.Kv, key: Deno.KvKey, data: Uint8Array) {
  const CHUNK_SIZE = 60_000; // Leave room for overhead
  const chunks = Math.ceil(data.length / CHUNK_SIZE);
  const op = kv.atomic();

  for (let i = 0; i < chunks; i++) {
    op.set([...key, "chunk", i], data.slice(i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE));
  }
  op.set([...key, "meta"], { chunks, totalSize: data.length });
  await op.commit();
}
```

### List Ordering

```typescript
// KV list returns keys in lexicographic byte order
// Numbers are NOT ordered numerically as strings:
// "1", "10", "11", "2", "3" — wrong order!

// ❌ Using plain numbers as key parts
await kv.set(["items", "1"], "first");
await kv.set(["items", "2"], "second");
await kv.set(["items", "10"], "tenth");
// List order: "1", "10", "2" — wrong!

// ✅ Pad numbers for correct ordering
function padKey(n: number): string {
  return n.toString().padStart(10, "0");
}
await kv.set(["items", padKey(1)], "first");    // "0000000001"
await kv.set(["items", padKey(2)], "second");   // "0000000002"
await kv.set(["items", padKey(10)], "tenth");   // "0000000010"
// List order: correct!

// ✅ Or use Uint8Array keys with big-endian encoding for numbers
```

### Watch Limitations

```typescript
// watch() only works on specific keys — not prefixes
// ❌ Cannot watch a prefix
const stream = kv.watch([["users"]]);  // Only watches the EXACT key ["users"]

// ✅ Watch specific keys you care about
const stream2 = kv.watch([
  ["users", "alice"],
  ["users", "bob"],
  ["config", "feature_flags"],
]);

// ✅ For prefix watching, use polling
async function pollPrefix(prefix: Deno.KvKey, intervalMs: number) {
  let lastVersions = new Map<string, string>();
  setInterval(async () => {
    for await (const entry of kv.list({ prefix })) {
      const keyStr = JSON.stringify(entry.key);
      if (lastVersions.get(keyStr) !== entry.versionstamp) {
        console.log("Changed:", entry.key, entry.value);
        lastVersions.set(keyStr, entry.versionstamp);
      }
    }
  }, intervalMs);
}
```

---

## Common Error Messages Reference

### "Module not found"

```
error: Module not found "jsr:@std/assert@^1.0.0"
```

```bash
# Fix: Add the dependency
deno add jsr:@std/assert

# Or cache it
deno cache main.ts
```

### "Top-level await is not allowed"

```
error: Top-level await is not allowed in a non-module context
```

Ensure your file has `.ts` or `.mts` extension, not `.cts`. Deno treats all
`.ts` files as ES modules.

### "Unsupported scheme"

```
error: Unsupported scheme "file" for module
```

Use `import.meta.url` with `new URL()`:

```typescript
// ❌
import config from "file:///absolute/path/config.json";

// ✅
const config = JSON.parse(
  await Deno.readTextFile(new URL("./config.json", import.meta.url)),
);
```

### "Cannot find name 'Deno'"

If TypeScript complains about `Deno` not being defined:

```jsonc
// deno.json
{
  "compilerOptions": {
    "lib": ["deno.window"]  // Usually automatic
  }
}
```

Or ensure you're running with `deno run`, not `node` or `ts-node`.

### "ERR_PACKAGE_PATH_NOT_EXPORTED"

```
error: [ERR_PACKAGE_PATH_NOT_EXPORTED]: Package subpath './internal' is not
defined by "exports"
```

The npm package's `exports` map doesn't expose that subpath. Check the
package's `package.json` exports field. You may need to use the package's
public API instead of reaching into internals.

### "Requires ... access" during tests

```bash
# Individual test permission
deno test --allow-read --allow-net tests/

# Or use per-test permissions
Deno.test({ permissions: { read: true, net: true }, fn: async () => {
  // test code
}});
```
