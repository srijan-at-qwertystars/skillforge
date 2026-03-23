# Migrating from Node.js to Bun

## Table of Contents

- [Pre-Migration Assessment](#pre-migration-assessment)
- [Step 1: Install Bun](#step-1-install-bun)
- [Step 2: Switch Package Management](#step-2-switch-package-management)
- [Step 3: Update package.json Scripts](#step-3-update-packagejson-scripts)
- [Step 4: Replace Dev Tools](#step-4-replace-dev-tools)
- [Step 5: Migrate Test Runner](#step-5-migrate-test-runner)
- [Step 6: Migrate HTTP Server](#step-6-migrate-http-server)
- [Step 7: Replace File I/O](#step-7-replace-file-io)
- [Step 8: Replace child_process](#step-8-replace-child_process)
- [Step 9: Update TypeScript Config](#step-9-update-typescript-config)
- [Step 10: Compatibility Shims](#step-10-compatibility-shims)
- [Post-Migration Checklist](#post-migration-checklist)

---

## Pre-Migration Assessment

Before migrating, audit your project for compatibility:

```sh
# Check for native addons (blockers)
find node_modules -name "binding.gyp" -o -name "*.node" 2>/dev/null | head -20

# List postinstall scripts that may compile native code
grep -r '"postinstall"' node_modules/*/package.json 2>/dev/null | head -10

# Check Node.js version requirements
node -e "console.log(process.version)"
cat .node-version .nvmrc 2>/dev/null
```

### Compatibility Decision Matrix

| Dependency Type | Action |
|---|---|
| Pure JS/TS packages | ✅ Safe to migrate |
| N-API native addons | ❌ Blocked — find JS alternatives |
| `node:inspector` usage | ❌ Replace with `--inspect` flag |
| Express/Fastify/Koa | ✅ Works on Bun (or migrate to Bun.serve) |
| Jest/Vitest tests | ✅ Bun test runner is Jest-compatible |
| Webpack/esbuild/Vite | ✅ Works, or replace with Bun.build |

---

## Step 1: Install Bun

```sh
# macOS / Linux
curl -fsSL https://bun.sh/install | bash

# Windows (PowerShell)
powershell -c "irm bun.sh/install.ps1 | iex"

# Via npm (if needed)
npm install -g bun

# Verify
bun --version
```

Add to PATH if not already:
```sh
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
```

---

## Step 2: Switch Package Management

```sh
# Remove old lockfiles and node_modules
rm -rf node_modules package-lock.json yarn.lock pnpm-lock.yaml

# Install with Bun
bun install

# This creates bun.lockb (binary lockfile)
# For human-readable lockfile, also generate yarn.lock:
bun install --yarn
```

### package.json Changes

No changes required for most projects. Bun reads `package.json` identically to npm.

If you use scoped registries, configure in `bunfig.toml`:

```toml
[install.scopes]
"@myorg" = { url = "https://npm.pkg.github.com/", token = "$GITHUB_TOKEN" }
```

---

## Step 3: Update package.json Scripts

### Before (Node.js)

```json
{
  "scripts": {
    "start": "node dist/index.js",
    "dev": "nodemon --watch src --exec ts-node src/index.ts",
    "build": "tsc && webpack --mode production",
    "test": "jest --coverage",
    "lint": "eslint src/",
    "typecheck": "tsc --noEmit"
  }
}
```

### After (Bun)

```json
{
  "scripts": {
    "start": "bun run src/index.ts",
    "dev": "bun --watch src/index.ts",
    "build": "bun build ./src/index.ts --outdir ./dist --minify",
    "test": "bun test --coverage",
    "lint": "bun run eslint src/",
    "typecheck": "bun run tsc --noEmit"
  }
}
```

Key changes:
- `node` → `bun run` (runs TS directly)
- `nodemon --exec ts-node` → `bun --watch` (built-in)
- `jest` → `bun test` (built-in, Jest-compatible)
- `npx` → `bunx` (faster)

---

## Step 4: Replace Dev Tools

### nodemon → bun --watch

```sh
# Before
nodemon --watch src --ext ts,json --exec ts-node src/index.ts

# After
bun --watch src/index.ts
```

`--watch` restarts on file changes. For hot-reload without restart (preserves state):

```sh
bun --hot src/index.ts
```

### ts-node → Direct Execution

```sh
# Before
npx ts-node src/script.ts
ts-node-esm src/script.ts

# After — just run it
bun src/script.ts
```

No `tsconfig.json` changes needed. Bun reads it automatically.

### npx → bunx

```sh
# Before
npx prisma generate
npx create-next-app

# After
bunx prisma generate
bunx create-next-app
```

---

## Step 5: Migrate Test Runner

### Jest → bun:test

Most Jest tests work with zero changes. Key differences:

```ts
// Before (Jest)
import { describe, it, expect, jest } from "@jest/globals";

const mockFn = jest.fn();
jest.mock("./db");

// After (bun:test)
import { describe, it, expect, mock, spyOn } from "bun:test";

const mockFn = mock(() => {});
mock.module("./db", () => ({
  query: mock(() => []),
}));
```

### Migration Checklist

| Jest Feature | Bun Equivalent | Notes |
|---|---|---|
| `jest.fn()` | `mock()` | Same API surface |
| `jest.mock()` | `mock.module()` | Different syntax |
| `jest.spyOn()` | `spyOn()` | Identical API |
| `jest.useFakeTimers()` | `mock.setSystemTime()` | Similar |
| `jest.setTimeout()` | `bun test --timeout` | CLI flag |
| `.toMatchSnapshot()` | `.toMatchSnapshot()` | Works identically |
| `jest.config.js` | `bunfig.toml [test]` | Different config format |
| `@jest/globals` | `bun:test` | Import source change |

### Test Configuration

```toml
# bunfig.toml
[test]
coverage = true
coverageReporter = ["text", "lcov"]
coverageThreshold = { line = 80, function = 80, statement = 80 }
timeout = 10000
preload = ["./tests/setup.ts"]
```

### Running Tests

```sh
bun test                           # Run all tests
bun test --watch                   # Re-run on changes
bun test --coverage                # Coverage report
bun test --bail 1                  # Stop on first failure
bun test src/auth                  # Run tests in directory
bun test --update-snapshots        # Update snapshots
```

---

## Step 6: Migrate HTTP Server

### Express → Bun.serve (Optional)

You can keep Express (it works on Bun), but Bun.serve is faster:

#### Express (still works)

```ts
// Keep using Express if migration cost is too high
import express from "express";
const app = express();
app.get("/", (req, res) => res.json({ ok: true }));
app.listen(3000);
// Just run with: bun src/server.ts
```

#### Bun.serve (native, faster)

```ts
Bun.serve({
  port: 3000,
  async fetch(req) {
    const url = new URL(req.url);

    // GET /
    if (req.method === "GET" && url.pathname === "/") {
      return Response.json({ ok: true });
    }

    // POST /api/users
    if (req.method === "POST" && url.pathname === "/api/users") {
      const body = await req.json();
      return Response.json({ created: true, ...body }, { status: 201 });
    }

    // Static files
    if (url.pathname.startsWith("/public/")) {
      const file = Bun.file(`./static${url.pathname.replace("/public", "")}`);
      if (await file.exists()) return new Response(file);
    }

    return new Response("Not Found", { status: 404 });
  },
});
```

### Middleware Pattern for Bun.serve

```ts
type Handler = (req: Request) => Response | Promise<Response> | null | Promise<null>;

function compose(...handlers: Handler[]) {
  return async (req: Request): Promise<Response> => {
    for (const handler of handlers) {
      const result = await handler(req);
      if (result) return result;
    }
    return new Response("Not Found", { status: 404 });
  };
}

// Usage
const cors: Handler = (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, POST" },
    });
  }
  return null; // pass to next handler
};

const api: Handler = async (req) => {
  if (new URL(req.url).pathname === "/api/health") {
    return Response.json({ status: "ok" });
  }
  return null;
};

Bun.serve({ port: 3000, fetch: compose(cors, api) });
```

---

## Step 7: Replace File I/O

### fs → Bun.file / Bun.write

```ts
// Before (Node.js)
import { readFile, writeFile, stat } from "fs/promises";
const data = await readFile("config.json", "utf-8");
const parsed = JSON.parse(data);
await writeFile("output.txt", "hello");
const info = await stat("file.txt");

// After (Bun)
const parsed = await Bun.file("config.json").json();
await Bun.write("output.txt", "hello");
const file = Bun.file("file.txt");
const size = file.size;
const exists = await file.exists();
```

### Stream Reading

```ts
// Before
import { createReadStream } from "fs";
const stream = createReadStream("large.csv");

// After — Bun.file is lazy, no streaming needed for most cases
const text = await Bun.file("large.csv").text();

// For truly large files, use the stream API
const file = Bun.file("huge.csv");
const reader = file.stream().getReader();
while (true) {
  const { done, value } = await reader.read();
  if (done) break;
  process.stdout.write(value);
}
```

### Glob/Directory Walking

```ts
// Before
import { glob } from "glob";
const files = await glob("src/**/*.ts");

// After
const glob = new Bun.Glob("src/**/*.ts");
for await (const file of glob.scan(".")) {
  console.log(file);
}
```

---

## Step 8: Replace child_process

### exec/spawn → Bun.$

```ts
// Before (Node.js)
import { exec, execSync, spawn } from "child_process";

exec("ls -la", (err, stdout, stderr) => {
  console.log(stdout);
});

const result = execSync("git status").toString();

const child = spawn("npm", ["install"], { stdio: "inherit" });

// After (Bun)
import { $ } from "bun";

const output = await $`ls -la`.text();

const status = await $`git status`.text();

await $`bun install`;  // stdio inherited by default

// Advanced: capture exit code without throwing
const { exitCode, stdout, stderr } = await $`git diff --exit-code`.nothrow().quiet();
```

### Process Spawning (when $ isn't enough)

```ts
// Bun.spawn for full control
const proc = Bun.spawn(["ffmpeg", "-i", "input.mp4", "output.webm"], {
  cwd: "/tmp",
  env: { ...process.env, FFMPEG_THREADS: "4" },
  stdout: "pipe",
  stderr: "pipe",
  onExit(proc, exitCode, signal) {
    console.log(`Exited: ${exitCode}`);
  },
});

const output = await new Response(proc.stdout).text();
```

---

## Step 9: Update TypeScript Config

### Install Bun Types

```sh
bun add -d @types/bun
```

### tsconfig.json Updates

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "types": ["@types/bun"],
    "strict": true,
    "skipLibCheck": true,
    "noEmit": true
  }
}
```

Remove `@types/node` if only running on Bun. Keep it if you need dual-runtime support.

---

## Step 10: Compatibility Shims

### For Gradual Migration

If you need code to work on both Node.js and Bun:

```ts
// runtime detection
const isBun = typeof Bun !== "undefined";

// File reading
async function readJSON(path: string) {
  if (isBun) return Bun.file(path).json();
  const { readFile } = await import("fs/promises");
  return JSON.parse(await readFile(path, "utf-8"));
}

// Environment variables
const env = (key: string) =>
  isBun ? Bun.env[key] : process.env[key];

// Password hashing
async function hashPassword(password: string) {
  if (isBun) return Bun.password.hash(password);
  const bcrypt = await import("bcryptjs");
  return bcrypt.hash(password, 10);
}
```

### Removing Node.js Dev Dependencies

After full migration, remove these from `devDependencies`:

```sh
bun remove ts-node nodemon ts-jest @jest/globals jest @types/jest webpack webpack-cli
```

---

## Post-Migration Checklist

- [ ] `bun install` succeeds with no native addon errors
- [ ] `bun test` passes all existing tests
- [ ] `bun run dev` starts dev server with hot reload
- [ ] `bun run build` produces production artifacts
- [ ] All environment variables load correctly (`.env` files)
- [ ] Docker build works with Bun base image
- [ ] CI/CD pipeline updated (lockfile, setup action, test command)
- [ ] Performance benchmarks show expected improvement
- [ ] No `require()` of `.node` native addons remains
- [ ] `tsconfig.json` includes `@types/bun`
- [ ] Team is trained on Bun-specific commands and patterns

### Quick Reference: Command Equivalents

| Node.js Command | Bun Equivalent |
|---|---|
| `node script.js` | `bun script.js` |
| `node --inspect` | `bun --inspect` |
| `npm install` | `bun install` |
| `npm run dev` | `bun run dev` |
| `npx create-app` | `bunx create-app` |
| `npm test` | `bun test` |
| `nodemon app.ts` | `bun --watch app.ts` |
| `ts-node app.ts` | `bun app.ts` |
| `jest --coverage` | `bun test --coverage` |
| `node -e "code"` | `bun -e "code"` |
