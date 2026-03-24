# Deno Troubleshooting Guide

## Table of Contents

- [Permission Denied Errors](#permission-denied-errors)
- [Import Resolution Errors](#import-resolution-errors)
- [npm Package Compatibility Issues](#npm-package-compatibility-issues)
- [TypeScript Strict Mode Issues](#typescript-strict-mode-issues)
- [Debugging with --inspect](#debugging-with---inspect)
- [VS Code Integration](#vs-code-integration)
- [Caching Issues (DENO_DIR)](#caching-issues-deno_dir)
- [Lock File Conflicts](#lock-file-conflicts)
- [Migration from Node.js](#migration-from-nodejs)
- [Deno Deploy Failures](#deno-deploy-failures)
- [Common Runtime Errors](#common-runtime-errors)
- [Performance Issues](#performance-issues)
- [Deno KV Issues](#deno-kv-issues)
- [Testing Troubleshooting](#testing-troubleshooting)

---

## Permission Denied Errors

### Symptom: `PermissionDenied: Requires read access to "..."`

```
error: Uncaught (in promise) PermissionDenied: Requires read access to "./config.json",
run again with the --allow-read flag
```

**Fix**: Grant the specific permission needed.

```bash
# Too broad (avoid in production)
deno run -A script.ts

# Grant specific paths
deno run --allow-read=./config.json,./data script.ts

# Grant directory access
deno run --allow-read=./data/ script.ts
```

### Symptom: Network Permission for npm Packages

```
error: Uncaught (in promise) PermissionDenied: Requires net access to "registry.npmjs.org"
```

**Fix**: npm specifiers require network access during first resolution.

```bash
# Allow npm registry access
deno run --allow-net=registry.npmjs.org script.ts

# Or cache deps first, then run offline
deno cache script.ts
deno run --cached-only script.ts
```

### Symptom: Permission Denied Inside Tests

```typescript
// Bad: No permissions declared
Deno.test("reads config", async () => {
  await Deno.readTextFile("./config.json"); // PermissionDenied!
});

// Good: Declare permissions in test options
Deno.test({
  name: "reads config",
  permissions: { read: ["./config.json"] },
  fn: async () => {
    await Deno.readTextFile("./config.json");
  },
});
```

### Symptom: Permission Denied for Env Variables

```bash
# Grant specific env vars
deno run --allow-env=DATABASE_URL,API_KEY script.ts

# Check which env vars are needed
deno run --deny-all script.ts 2>&1 | grep "PermissionDenied"
```

### Using Deny Flags to Audit Permissions

```bash
# Allow net but deny specific hosts
deno run --allow-net --deny-net=evil.com script.ts

# Allow read but deny sensitive paths
deno run --allow-read --deny-read=/etc/passwd,/etc/shadow script.ts
```

---

## Import Resolution Errors

### Symptom: `Module not found`

```
error: Module not found "jsr:@std/assert"
```

**Fixes**:

```bash
# 1. Add the dependency explicitly
deno add jsr:@std/assert

# 2. Check deno.json imports section exists
cat deno.json | grep -A5 '"imports"'

# 3. Reload dependency cache
deno cache --reload script.ts
```

### Symptom: `Cannot find module` for Bare Specifiers

```
error: Relative import path "zod" not prefixed with / or ./ or ../
```

**Fix**: Use import map in `deno.json` or prefix with `npm:`.

```jsonc
// deno.json
{
  "imports": {
    "zod": "npm:zod@^3.23"
  }
}
```

Or use inline specifier:

```typescript
import { z } from "npm:zod@^3.23";
```

### Symptom: HTTPS Import Redirect Errors

```
error: error sending request: redirect not allowed
```

**Fix**: Use the final URL or switch to JSR/npm specifiers.

```typescript
// Bad: May redirect
import { serve } from "https://deno.land/std/http/server.ts";

// Good: Pin version
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

// Better: Use JSR
import { serve } from "jsr:@std/http@^1/server";
```

### Symptom: Circular Import Errors

```
error: Cannot load module ... circular dependency detected
```

**Fix**: Refactor shared types into a separate file that doesn't import from circular modules.

```
// Before (circular):
// a.ts imports from b.ts
// b.ts imports from a.ts

// After:
// types.ts — shared types (no imports from a or b)
// a.ts imports from types.ts
// b.ts imports from types.ts
```

---

## npm Package Compatibility Issues

### Symptom: `__dirname is not defined`

Node.js globals like `__dirname`, `__filename`, `require` are not available by default.

```typescript
// Replace __dirname
const __dirname = new URL(".", import.meta.url).pathname;

// Replace __filename
const __filename = new URL(import.meta.url).pathname;

// Replace require()
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const pkg = require("./package.json");
```

### Symptom: npm Package Uses Node Built-ins

```
error: Could not resolve "fs" or "path"
```

**Fix**: Deno maps `node:` built-in modules automatically. Most packages work, but some may need explicit polyfills.

```typescript
// These work in Deno 2.x
import fs from "node:fs";
import path from "node:path";
import { Buffer } from "node:buffer";
import { EventEmitter } from "node:events";
import crypto from "node:crypto";
```

### Symptom: npm Package Uses Native Addons (.node files)

```
error: Unsupported ... native addons are not supported
```

**Fix**: Native addons (`.node` files compiled with node-gyp) are not supported. Use alternatives:

| Package with native addon | Pure JS/Wasm alternative |
|--------------------------|-------------------------|
| bcrypt | `npm:bcryptjs` or `jsr:@std/crypto` |
| sharp | `npm:sharp` (partial Wasm support) |
| better-sqlite3 | Use Deno.openKv() or `npm:sql.js` |
| canvas | `npm:@napi-rs/canvas` |

### Symptom: npm Package Requires `node_modules`

```bash
# Enable node_modules mode
echo '{ "nodeModulesDir": "auto" }' > deno.json

# Or set explicitly
deno run --node-modules-dir=auto script.ts
```

### Symptom: Package Version Conflict

```
error: Failed to resolve npm package ... version conflict
```

**Fix**:

```bash
# Clear cache and re-resolve
rm deno.lock
deno cache --reload script.ts

# Or pin exact versions
deno add npm:package@5.2.1  # Exact version
```

---

## TypeScript Strict Mode Issues

### Symptom: Strict Null Checks

```typescript
// Error: Object is possibly 'undefined'
const user = users.find(u => u.id === id);
console.log(user.name);  // Error!

// Fix: Guard against undefined
const user = users.find(u => u.id === id);
if (!user) throw new Error("User not found");
console.log(user.name);  // OK

// Or use optional chaining
console.log(user?.name ?? "Unknown");
```

### Symptom: Implicit Any

```typescript
// Error: Parameter 'x' implicitly has an 'any' type
function double(x) { return x * 2; }

// Fix: Add type annotation
function double(x: number): number { return x * 2; }
```

### Configuring TypeScript in Deno

```jsonc
// deno.json
{
  "compilerOptions": {
    "strict": true,              // Recommended: keep on
    "noImplicitAny": true,
    "strictNullChecks": true,
    "noUnusedLocals": false,     // Can disable if noisy
    "noUnusedParameters": false
  }
}
```

### Symptom: Type Errors with npm Packages

```typescript
// Some npm packages lack type declarations
// Fix: Use @types package or declare manually
import express from "npm:express@^4";
// If types missing: deno add npm:@types/express

// Or create a declaration file
// types/express.d.ts
declare module "npm:express" {
  export default function(): any;
}
```

---

## Debugging with --inspect

### Start Debugger

```bash
# Start with debugger (pauses on first line)
deno run --inspect-brk --allow-all script.ts

# Start without pausing
deno run --inspect --allow-all script.ts

# Custom port
deno run --inspect=127.0.0.1:9230 --allow-all script.ts

# Debug tests
deno test --inspect-brk test.ts
```

### Connect Chrome DevTools

1. Run with `--inspect-brk`
2. Open `chrome://inspect` in Chrome
3. Click "inspect" under Remote Target
4. Use Sources panel for breakpoints, Console for evaluation

### Programmatic Debugging

```typescript
// Insert debugger statement in code
function processData(data: unknown[]) {
  debugger; // Execution pauses here when --inspect-brk is used
  return data.map(item => transform(item));
}
```

### Log-Based Debugging

```typescript
// Structured logging
console.log("%c[DEBUG]", "color: blue", "Request:", req.url);
console.table({ method: req.method, url: req.url, headers: Object.fromEntries(req.headers) });
console.time("db-query");
const result = await db.query(sql);
console.timeEnd("db-query");
console.trace("Call stack");
```

---

## VS Code Integration

### Setup

1. Install the **Deno** extension (`denoland.vscode-deno`)
2. Enable Deno for the workspace:

```jsonc
// .vscode/settings.json
{
  "deno.enable": true,
  "deno.lint": true,
  "deno.unstable": ["kv", "cron"],
  "deno.importMap": "./deno.json",
  "editor.defaultFormatter": "denoland.vscode-deno",
  "[typescript]": {
    "editor.defaultFormatter": "denoland.vscode-deno"
  },
  "[typescriptreact]": {
    "editor.defaultFormatter": "denoland.vscode-deno"
  }
}
```

### Common VS Code Issues

**Problem**: TypeScript errors show but `deno check` passes.

**Fix**: Ensure the Deno extension is enabled and TypeScript extension is disabled for the workspace.

```jsonc
// .vscode/settings.json
{
  "deno.enable": true,
  "typescript.validate.enable": false  // Disable built-in TS validation
}
```

**Problem**: Import suggestions don't work.

**Fix**: Cache dependencies first:

```bash
deno cache src/main.ts
```

### Debug Configuration

```jsonc
// .vscode/launch.json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Deno: Run",
      "request": "launch",
      "type": "node",
      "runtimeExecutable": "deno",
      "runtimeArgs": ["run", "--inspect-wait", "--allow-all"],
      "program": "${workspaceFolder}/src/main.ts",
      "attachSimplePort": 9229
    },
    {
      "name": "Deno: Test",
      "request": "launch",
      "type": "node",
      "runtimeExecutable": "deno",
      "runtimeArgs": ["test", "--inspect-wait", "--allow-all"],
      "program": "${workspaceFolder}/tests/",
      "attachSimplePort": 9229
    }
  ]
}
```

---

## Caching Issues (DENO_DIR)

### Where Deno Stores Cache

```bash
# Show cache location
deno info

# Default locations:
# Linux:   ~/.cache/deno
# macOS:   ~/Library/Caches/deno
# Windows: %LOCALAPPDATA%/deno
```

### Common Cache Problems

**Problem**: Stale cached module (remote file changed).

```bash
# Reload specific module
deno cache --reload=https://example.com/mod.ts script.ts

# Reload all modules
deno cache --reload script.ts

# Force fresh resolution of npm packages
rm deno.lock
deno cache --reload script.ts
```

**Problem**: Cache corruption.

```bash
# Clear entire cache
rm -rf $(deno info --json | jq -r .denoDir)

# Or set custom cache directory
export DENO_DIR=/tmp/deno_cache
deno run script.ts
```

**Problem**: CI caching.

```yaml
# GitHub Actions — cache Deno dependencies
- uses: actions/cache@v4
  with:
    path: |
      ~/.cache/deno
      ~/.deno
    key: deno-${{ runner.os }}-${{ hashFiles('deno.lock') }}
    restore-keys: deno-${{ runner.os }}-
```

### Custom DENO_DIR

```bash
# Set for the session
export DENO_DIR=/custom/path/deno

# Set per-command
DENO_DIR=/tmp/deno-test deno test
```

---

## Lock File Conflicts

### Understanding deno.lock

Deno automatically generates `deno.lock` to pin dependency versions. This ensures reproducible builds.

### Common Issues

**Problem**: Lock file out of date after adding deps.

```bash
# Regenerate lock file
deno cache --lock=deno.lock --lock-write src/main.ts

# Or simply delete and recreate
rm deno.lock
deno cache src/main.ts
```

**Problem**: Lock file conflicts in git merge.

```bash
# Accept current and regenerate
git checkout --ours deno.lock
rm deno.lock
deno cache src/main.ts
git add deno.lock
```

**Problem**: Lock file check fails in CI.

```bash
# CI should verify lock file integrity
deno cache --lock=deno.lock src/main.ts
# Fails if lock file doesn't match resolved versions

# To skip lock file verification (not recommended)
deno run --no-lock script.ts
```

### Disabling Lock File

```jsonc
// deno.json — disable lock file (not recommended for production)
{
  "lock": false
}
```

---

## Migration from Node.js

### Step-by-Step Migration

1. **Keep `package.json`** — Deno reads it automatically
2. **Add `deno.json`** — Configure tasks, imports, compiler options
3. **Update imports** — Replace Node built-ins with `node:` prefix
4. **Run with Deno** — Most code works without changes

### Common Import Changes

```typescript
// Before (Node.js)
const fs = require("fs");
const path = require("path");
import express from "express";

// After (Deno)
import fs from "node:fs";
import path from "node:path";
import express from "npm:express@^4";
// Or if using import map:
import express from "express";
```

### Replacing Node.js APIs

```typescript
// Node: process.env
// Deno:
Deno.env.get("DATABASE_URL");

// Node: process.argv
// Deno:
Deno.args; // (without node/deno binary path)

// Node: process.cwd()
// Deno:
Deno.cwd();

// Node: process.exit(1)
// Deno:
Deno.exit(1);

// Node: setTimeout/setInterval (same in Deno)
// Node: Buffer
// Deno:
import { Buffer } from "node:buffer";

// Node: child_process.exec
// Deno:
const cmd = new Deno.Command("ls", { args: ["-la"], stdout: "piped" });
const output = await cmd.output();
```

### package.json Scripts → deno.json Tasks

```jsonc
// Before: package.json
{
  "scripts": {
    "start": "node src/index.js",
    "dev": "nodemon src/index.js",
    "test": "jest",
    "lint": "eslint src/"
  }
}

// After: deno.json
{
  "tasks": {
    "start": "deno run --allow-net --allow-read --allow-env src/main.ts",
    "dev": "deno run --watch --allow-net --allow-read --allow-env src/main.ts",
    "test": "deno test",
    "lint": "deno lint"
  }
}
```

### Jest → Deno.test

```typescript
// Before: Jest
describe("math", () => {
  test("adds numbers", () => {
    expect(add(1, 2)).toBe(3);
  });
});

// After: Deno.test
import { assertEquals } from "@std/assert";

Deno.test("math - adds numbers", () => {
  assertEquals(add(1, 2), 3);
});
```

---

## Deno Deploy Failures

### Symptom: Deploy Command Not Found

```bash
# Install deployctl
deno install -gArf jsr:@deno/deployctl

# Verify
deployctl --version
```

### Symptom: `Unsupported API` on Deno Deploy

Not all Deno APIs are available on Deploy. Unsupported APIs include:

- `Deno.Command` (no subprocesses)
- `Deno.dlopen` (no FFI)
- `Deno.readFile` (limited filesystem)
- `Deno.listen` (use `Deno.serve` instead)
- Workers with filesystem access

**Fix**: Use Deploy-compatible alternatives.

```typescript
// Instead of Deno.readFile for static assets:
// Embed files at deploy time or use fetch() for remote assets

// Instead of Deno.Command:
// Use HTTP APIs to communicate with external services

// Instead of Deno.listen:
Deno.serve({ port: 8000 }, handler);
```

### Symptom: Environment Variables Missing

```bash
# Set via deployctl
deployctl deploy --env=DATABASE_URL=postgres://... --prod src/main.ts

# Or use Deno Deploy dashboard: Settings → Environment Variables
```

### Symptom: KV Not Working on Deploy

```typescript
// Deno KV is available on Deploy but requires no path argument
const kv = await Deno.openKv();  // Correct — auto-connects to managed KV

// This FAILS on Deploy:
const kv = await Deno.openKv("./local.db");  // Error: path not supported on Deploy
```

### Symptom: Module Too Large

Deno Deploy has a module size limit. To reduce bundle size:

```bash
# Check module graph size
deno info src/main.ts

# Use tree-shaking-friendly imports
import { just, whatYouNeed } from "large-package";
```

---

## Common Runtime Errors

### `TypeError: Cannot read properties of undefined`

```typescript
// Common in async contexts — check if resource is available
const kv = await Deno.openKv();
const entry = await kv.get(["users", id]);

// entry.value may be null if key doesn't exist
if (entry.value === null) {
  return new Response("Not Found", { status: 404 });
}
const user = entry.value as User;
```

### `TypeError: response body object should not be disturbed or locked`

```typescript
// Don't read the body twice
const body = await req.json(); // First read — OK
const body2 = await req.json(); // Error! Body already consumed

// Fix: Clone the request if you need to read body multiple times
const clone = req.clone();
const body = await req.json();
const body2 = await clone.json();
```

### `Error: Top-level await is not allowed`

```typescript
// This only fails in non-module contexts
// Fix: Ensure file is treated as module (has import/export or .ts extension)
export {}; // Add empty export to make it a module
const data = await fetchData();
```

### `Uncaught (in promise)` — Unhandled Promise Rejection

```typescript
// Deno terminates on unhandled rejections by default
// Always handle promise errors

// Bad:
fetch("https://may-fail.com/api"); // Unhandled if it rejects

// Good:
try {
  const res = await fetch("https://may-fail.com/api");
} catch (err) {
  console.error("Fetch failed:", err);
}

// Global handler for debugging
globalThis.addEventListener("unhandledrejection", (event) => {
  console.error("Unhandled rejection:", event.reason);
  event.preventDefault(); // Prevents termination
});
```

---

## Performance Issues

### Slow Startup

```bash
# Pre-cache all dependencies
deno cache src/main.ts

# Use --cached-only to avoid network on startup
deno run --cached-only --allow-net src/main.ts

# Check dependency graph size
deno info src/main.ts
```

### Memory Issues

```bash
# Increase V8 heap
deno run --v8-flags=--max-old-space-size=4096 script.ts

# Monitor memory in code
console.log(Deno.memoryUsage());
// { rss: ..., heapTotal: ..., heapUsed: ..., external: ... }
```

### Slow HTTP Server

```bash
# Use multi-threaded serving
deno serve --parallel main.ts

# Profile with timing
deno run --v8-flags=--prof --allow-net main.ts
```

---

## Deno KV Issues

### Symptom: KV Operations Are Slow

```typescript
// Batch reads with getMany
const [user, settings, prefs] = await kv.getMany([
  ["users", id],
  ["settings", id],
  ["preferences", id],
]);

// Batch writes with atomic
await kv.atomic()
  .set(["users", id], userData)
  .set(["settings", id], settingsData)
  .commit();
```

### Symptom: Atomic Transaction Fails

```typescript
// Check for version conflicts
const entry = await kv.get(["users", id]);
const result = await kv.atomic()
  .check(entry) // Fails if entry was modified since read
  .set(["users", id], { ...entry.value, updated: true })
  .commit();

if (!result.ok) {
  console.log("Conflict — retry with fresh data");
}
```

---

## Testing Troubleshooting

### Symptom: Tests Hang

```typescript
// Leaked async resources cause tests to hang
Deno.test({
  name: "might hang",
  sanitizeResources: false,  // Disable resource leak detection
  sanitizeOps: false,        // Disable async op leak detection
  fn: async () => {
    // test code
  },
});
```

### Symptom: Tests Interfere with Each Other

```typescript
// Use test steps for ordered execution
Deno.test("isolated tests", async (t) => {
  const kv = await Deno.openKv(":memory:");

  await t.step("step 1", async () => {
    await kv.set(["test"], "value");
  });

  await t.step("step 2", async () => {
    const entry = await kv.get(["test"]);
    assertEquals(entry.value, "value");
  });

  kv.close();
});
```

### Running Specific Tests

```bash
# Filter by name
deno test --filter="user service"

# Run single file
deno test tests/user_test.ts

# Run with verbose output
deno test --trace-leaks

# Fail fast on first error
deno test --fail-fast
```
