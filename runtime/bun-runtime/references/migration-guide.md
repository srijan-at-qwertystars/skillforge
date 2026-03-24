# Node.js to Bun Migration Guide

## Table of Contents

- [Overview](#overview)
- [Quick Start Migration](#quick-start-migration)
- [Package Manager: npm/yarn → bun](#package-manager-npmyarn--bun)
  - [package.json Scripts → bun run](#packagejson-scripts--bun-run)
  - [npx → bunx](#npx--bunx)
  - [Lockfile Migration](#lockfile-migration)
- [Test Runner: Jest → bun test](#test-runner-jest--bun-test)
  - [Test Syntax Changes](#test-syntax-changes)
  - [Mocking Differences](#mocking-differences)
  - [Configuration Migration](#configuration-migration)
  - [Coverage](#coverage)
- [Bundler: webpack/esbuild → bun build](#bundler-webpackesbuild--bun-build)
  - [webpack Migration](#webpack-migration)
  - [esbuild Migration](#esbuild-migration)
  - [Vite Projects](#vite-projects)
- [HTTP Server: Express → Bun.serve](#http-server-express--bunserve)
  - [Direct Bun.serve Migration](#direct-bunserve-migration)
  - [Hono Framework Alternative](#hono-framework-alternative)
  - [Elysia Framework Alternative](#elysia-framework-alternative)
  - [Middleware Mapping](#middleware-mapping)
- [File System: fs → Bun.file/Bun.write](#file-system-fs--bunfilebunwrite)
- [Crypto: crypto → Bun.password/CryptoHasher](#crypto-crypto--bunpasswordcryptohasher)
- [Workers: worker_threads → Web Workers](#workers-worker_threads--web-workers)
- [Shell: child_process → Bun Shell](#shell-child_process--bun-shell)
- [Environment: dotenv → Built-in .env](#environment-dotenv--built-in-env)
- [TypeScript Configuration](#typescript-configuration)
- [Docker Migration](#docker-migration)
- [Step-by-Step Migration Checklist](#step-by-step-migration-checklist)

---

## Overview

Bun is designed as a drop-in replacement for Node.js. Most Node.js code works in Bun unchanged. This guide covers the differences and how to take advantage of Bun-specific features for better performance.

**Migration strategy**:
1. **Phase 1**: Run existing code with Bun (zero changes needed for most projects)
2. **Phase 2**: Replace npm with bun as package manager
3. **Phase 3**: Adopt Bun-specific APIs for performance gains
4. **Phase 4**: Replace test runner and bundler

---

## Quick Start Migration

The simplest migration — just switch the runtime:

```bash
# Before (Node.js)
npm install
node src/index.js
npm test
npm run build

# After (Bun) — works immediately for most projects
bun install
bun run src/index.ts   # TypeScript works out of the box
bun test
bun run build
```

That's it for many projects. The sections below cover deeper migration for specific tools and APIs.

---

## Package Manager: npm/yarn → bun

### package.json Scripts → bun run

All existing `package.json` scripts work unchanged:

```json
{
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "eslint .",
    "test": "bun test"
  }
}
```

```bash
# npm run dev → bun run dev
# npm run build → bun run build
# npm start → bun run start

# Speed advantage: bun run starts scripts ~30x faster than npm run
# because it doesn't spin up a separate shell process
```

**Command mapping**:

| npm / yarn | bun | Notes |
|-----------|-----|-------|
| `npm install` | `bun install` | 30x faster, uses global cache |
| `npm install pkg` | `bun add pkg` | |
| `npm install -D pkg` | `bun add -d pkg` | |
| `npm uninstall pkg` | `bun remove pkg` | |
| `npm update` | `bun update` | |
| `npm run script` | `bun run script` | |
| `npm start` | `bun run start` | |
| `npm test` | `bun test` | Uses built-in test runner |
| `npm init` | `bun init` | |
| `npm create vite` | `bun create vite` | |
| `npm ci` | `bun install --frozen-lockfile` | For CI |
| `npm pack` | `bun pm pack` | |
| `npm publish` | `bunx npm publish` | Use npm for publishing |

### npx → bunx

```bash
# npx → bunx (or bun x)
npx create-react-app my-app  →  bunx create-react-app my-app
npx prisma generate          →  bunx prisma generate
npx tsc --noEmit             →  bunx tsc --noEmit
npx eslint .                 →  bunx eslint .

# bunx is faster — downloads and caches packages more efficiently
```

### Lockfile Migration

```bash
# Bun reads package-lock.json and yarn.lock automatically
# Just run bun install to generate bun.lock

cd my-project
bun install
# Creates bun.lock (text-based, human-readable)

# Commit the new lockfile
git add bun.lock
git commit -m "Switch to Bun lockfile"

# Optionally remove old lockfiles
rm package-lock.json yarn.lock
```

---

## Test Runner: Jest → bun test

### Test Syntax Changes

Most Jest tests work unchanged with `bun test`. Key differences:

```typescript
// ========================================
// BEFORE: Jest
// ========================================
// jest.config.js needed
// @types/jest for types

import { jest } from "@jest/globals";

describe("math", () => {
  it("adds", () => {
    expect(1 + 1).toBe(2);
  });
});

// ========================================
// AFTER: bun test
// ========================================
// No config file needed
// Types included with bun-types

import { describe, it, expect } from "bun:test";

describe("math", () => {
  it("adds", () => {
    expect(1 + 1).toBe(2);
  });
});
```

**File naming**: `bun test` finds tests in `*.test.ts`, `*.test.js`, `*.spec.ts`, `*.spec.js` — same as Jest.

### Mocking Differences

```typescript
// ========================================
// Jest mocking
// ========================================
jest.mock("./database", () => ({
  query: jest.fn().mockResolvedValue([]),
}));

const fn = jest.fn();
jest.spyOn(console, "log");

// ========================================
// Bun test mocking
// ========================================
import { mock, spyOn } from "bun:test";

mock.module("./database", () => ({
  query: mock(() => Promise.resolve([])),
}));

const fn = mock();
spyOn(console, "log");

// Key differences:
// - jest.fn() → mock()
// - jest.mock() → mock.module()
// - jest.spyOn() → spyOn()
// - jest.useFakeTimers() → not available (use manual mocking)
```

### Configuration Migration

```bash
# ========================================
# BEFORE: jest.config.js
# ========================================
# module.exports = {
#   testEnvironment: "node",
#   transform: { "^.+\\.tsx?$": "ts-jest" },
#   moduleNameMapper: { "@/(.*)": "<rootDir>/src/$1" },
#   coverageThreshold: { global: { branches: 80 } },
#   setupFiles: ["./test/setup.ts"],
# };

# ========================================
# AFTER: bunfig.toml
# ========================================
```

```toml
[test]
# No transform needed — Bun runs TypeScript natively
preload = ["./test/setup.ts"]
coverage = true
coverageThreshold = 0.8

# For DOM testing
# preload = ["happy-dom"]
```

Path aliases work automatically from `tsconfig.json` — no `moduleNameMapper` needed.

### Coverage

```bash
# Jest
npx jest --coverage

# Bun
bun test --coverage
```

---

## Bundler: webpack/esbuild → bun build

### webpack Migration

```javascript
// ========================================
// BEFORE: webpack.config.js
// ========================================
module.exports = {
  entry: "./src/index.ts",
  output: { path: path.resolve("dist"), filename: "bundle.js" },
  module: {
    rules: [
      { test: /\.tsx?$/, use: "ts-loader" },
      { test: /\.css$/, use: ["style-loader", "css-loader"] },
    ],
  },
  resolve: { extensions: [".ts", ".tsx", ".js"] },
  plugins: [new HtmlWebpackPlugin({ template: "./index.html" })],
  optimization: { splitChunks: { chunks: "all" } },
};
```

```typescript
// ========================================
// AFTER: build.ts (run with bun run build.ts)
// ========================================
const result = await Bun.build({
  entrypoints: ["./src/index.ts"],
  outdir: "./dist",
  target: "browser",
  splitting: true,
  sourcemap: "external",
  minify: true,
  // TypeScript and CSS handled natively — no loaders needed
});

if (!result.success) {
  console.error("Build failed:", result.logs);
  process.exit(1);
}
console.log(`Built ${result.outputs.length} files`);
```

```json
// package.json
{
  "scripts": {
    "build": "bun run build.ts"
  }
}
```

**webpack features not in bun build** (use alternatives):
- HMR/dev server → use `--hot` flag with `bun run`
- HTML plugin → use HTML entry points or manual copy
- Asset modules → supported via `file` loader
- Module federation → not supported (use import maps)

### esbuild Migration

The migration is nearly 1:1 since Bun's bundler API is esbuild-inspired:

```typescript
// ========================================
// BEFORE: esbuild
// ========================================
import { build } from "esbuild";
await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  outdir: "dist",
  platform: "browser",
  splitting: true,
  format: "esm",
  minify: true,
  sourcemap: true,
  plugins: [myPlugin],
});

// ========================================
// AFTER: Bun.build
// ========================================
await Bun.build({
  entrypoints: ["src/index.ts"],       // entryPoints → entrypoints
  outdir: "dist",
  target: "browser",                    // platform → target
  splitting: true,
  // format is always ESM
  minify: true,
  sourcemap: "external",               // true → "external"
  plugins: [myBunPlugin],              // Similar API, slight differences
});
```

**Key differences from esbuild**:
- `entryPoints` → `entrypoints`
- `platform` → `target` (`"browser"`, `"bun"`, `"node"`)
- `format` — always ESM in Bun
- `sourcemap: true` → `sourcemap: "external"` or `"inline"`
- Plugin hooks are similar but not identical

### Vite Projects

Vite projects work with Bun as-is — just use `bun` as the runtime:

```bash
# Vite continues to handle dev server and HMR
bun run dev       # Uses Vite dev server
bun run build     # Uses Vite build (esbuild + Rollup)
bun run preview   # Uses Vite preview server
```

---

## HTTP Server: Express → Bun.serve

### Direct Bun.serve Migration

```typescript
// ========================================
// BEFORE: Express
// ========================================
import express from "express";
import cors from "cors";

const app = express();
app.use(cors());
app.use(express.json());

app.get("/api/users", async (req, res) => {
  const users = await db.getUsers();
  res.json(users);
});

app.post("/api/users", async (req, res) => {
  const user = await db.createUser(req.body);
  res.status(201).json(user);
});

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: "Internal server error" });
});

app.listen(3000, () => console.log("Server on :3000"));

// ========================================
// AFTER: Bun.serve
// ========================================
const server = Bun.serve({
  port: 3000,
  async fetch(req) {
    const url = new URL(req.url);

    // CORS preflight
    if (req.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    // Routes
    if (url.pathname === "/api/users") {
      if (req.method === "GET") {
        const users = await db.getUsers();
        return Response.json(users);
      }
      if (req.method === "POST") {
        const body = await req.json();
        const user = await db.createUser(body);
        return Response.json(user, { status: 201 });
      }
    }

    return new Response("Not Found", { status: 404 });
  },
  error(err) {
    console.error(err);
    return Response.json({ error: "Internal server error" }, { status: 500 });
  },
});

console.log(`Server on ${server.url}`);
```

### Hono Framework Alternative

Hono is the recommended framework for Bun — lightweight, fast, Express-like middleware:

```typescript
import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { validator } from "hono/validator";

const app = new Hono();

// Middleware (Express-like)
app.use("*", cors());
app.use("*", logger());

// Routes
app.get("/api/users", async (c) => {
  const users = await db.getUsers();
  return c.json(users);
});

app.post("/api/users", async (c) => {
  const body = await c.req.json();
  const user = await db.createUser(body);
  return c.json(user, 201);
});

// Error handling
app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "Internal server error" }, 500);
});

// Bun auto-serves default export
export default app;
```

```bash
bun add hono
```

### Elysia Framework Alternative

Elysia offers end-to-end type safety and schema validation:

```typescript
import { Elysia, t } from "elysia";
import { cors } from "@elysiajs/cors";

const app = new Elysia()
  .use(cors())
  .get("/api/users", async () => {
    return await db.getUsers();
  })
  .post("/api/users", async ({ body }) => {
    return await db.createUser(body);
  }, {
    body: t.Object({
      name: t.String(),
      email: t.String({ format: "email" }),
    }),
  })
  .listen(3000);

console.log(`Server on ${app.server?.url}`);
```

```bash
bun add elysia @elysiajs/cors
```

### Middleware Mapping

| Express Middleware | Bun Equivalent |
|-------------------|----------------|
| `express.json()` | `await req.json()` (built-in) |
| `express.static()` | `Bun.file()` or `static` option |
| `cors` | Manual headers or Hono `cors()` |
| `helmet` | Manual security headers |
| `morgan` / `winston` | `console.log` or Hono `logger()` |
| `multer` (file upload) | `req.formData()` (built-in) |
| `cookie-parser` | `req.headers.get("cookie")` |
| `express-rate-limit` | Manual implementation or Hono plugin |
| `passport` | Manual auth or framework plugins |

---

## File System: fs → Bun.file/Bun.write

```typescript
// ========================================
// BEFORE: Node.js fs
// ========================================
import fs from "node:fs/promises";

const text = await fs.readFile("data.txt", "utf-8");
const json = JSON.parse(await fs.readFile("config.json", "utf-8"));
const buffer = await fs.readFile("image.png");

await fs.writeFile("output.txt", "hello");
await fs.writeFile("config.json", JSON.stringify(data, null, 2));

const exists = await fs.access("file.txt").then(() => true).catch(() => false);
const stats = await fs.stat("file.txt");

// ========================================
// AFTER: Bun APIs (faster, simpler)
// ========================================
const text = await Bun.file("data.txt").text();
const json = await Bun.file("config.json").json();
const buffer = await Bun.file("image.png").arrayBuffer();
const bytes = await Bun.file("image.png").bytes(); // Uint8Array

await Bun.write("output.txt", "hello");
await Bun.write("config.json", JSON.stringify(data, null, 2));

const exists = await Bun.file("file.txt").exists();
const size = Bun.file("file.txt").size;
const type = Bun.file("file.txt").type; // MIME type

// Copy file
await Bun.write("copy.txt", Bun.file("original.txt"));

// Glob (replaces glob/fast-glob packages)
const glob = new Bun.Glob("**/*.ts");
for await (const path of glob.scan({ cwd: "./src" })) {
  console.log(path);
}
```

**Note**: `node:fs` still works in Bun. Migration to Bun APIs is optional but faster.

---

## Crypto: crypto → Bun.password/CryptoHasher

```typescript
// ========================================
// BEFORE: Node.js crypto + bcrypt package
// ========================================
import bcrypt from "bcrypt";
import crypto from "node:crypto";

const hash = await bcrypt.hash("password", 10);
const valid = await bcrypt.compare("password", hash);

const sha256 = crypto.createHash("sha256").update("data").digest("hex");
const hmac = crypto.createHmac("sha256", "key").update("data").digest("hex");

// ========================================
// AFTER: Bun built-in (no packages needed)
// ========================================
// Password hashing — replaces bcrypt, argon2 packages
const hash = await Bun.password.hash("password", {
  algorithm: "bcrypt",  // or "argon2id"
  cost: 10,
});
const valid = await Bun.password.verify("password", hash);

// Hashing
const sha256 = new Bun.CryptoHasher("sha256").update("data").digest("hex");
const hmac = new Bun.CryptoHasher("sha256", "key").update("data").digest("hex");

// Random values
const uuid = crypto.randomUUID(); // Web Crypto — works in Bun
const bytes = crypto.getRandomValues(new Uint8Array(32));
```

---

## Workers: worker_threads → Web Workers

```typescript
// ========================================
// BEFORE: Node.js worker_threads
// ========================================
import { Worker, isMainThread, parentPort } from "node:worker_threads";

if (isMainThread) {
  const worker = new Worker("./worker.js");
  worker.postMessage({ task: "compute" });
  worker.on("message", (result) => console.log(result));
} else {
  parentPort!.on("message", (msg) => {
    parentPort!.postMessage({ result: doWork(msg) });
  });
}

// ========================================
// AFTER: Web Workers (standard API)
// ========================================
// main.ts
const worker = new Worker(new URL("./worker.ts", import.meta.url));
worker.postMessage({ task: "compute" });
worker.addEventListener("message", (e) => console.log(e.data));

// worker.ts
self.addEventListener("message", (e: MessageEvent) => {
  self.postMessage({ result: doWork(e.data) });
});
```

**Advantages**: Web Workers are the standard API, work in browsers too, and TypeScript is supported natively in Bun workers.

---

## Shell: child_process → Bun Shell

```typescript
// ========================================
// BEFORE: Node.js child_process
// ========================================
import { execSync, exec, spawn } from "node:child_process";

// Synchronous
const output = execSync("ls -la", { encoding: "utf-8" });

// Async with callback
exec("git status", (err, stdout, stderr) => {
  console.log(stdout);
});

// Spawn with streams
const child = spawn("npm", ["run", "build"]);
child.stdout.on("data", (data) => console.log(data.toString()));
child.on("close", (code) => console.log(`Exit: ${code}`));

// ========================================
// AFTER: Bun Shell ($)
// ========================================
import { $ } from "bun";

// Simple and clean
const output = await $`ls -la`.text();

// Git status
const status = await $`git status`.text();

// Build with output
await $`bun run build`;

// Check exit code without throwing
const { exitCode } = await $`grep -r "TODO" src/`.nothrow();

// Pipe commands
const count = await $`find . -name "*.ts" | wc -l`.text();

// Environment and working directory
$.cwd("./packages/api");
await $`bun run dev`;
```

---

## Environment: dotenv → Built-in .env

```typescript
// ========================================
// BEFORE: Node.js + dotenv
// ========================================
import dotenv from "dotenv";
dotenv.config();  // Must be called before accessing env vars

const dbUrl = process.env.DATABASE_URL;

// ========================================
// AFTER: Bun (no package needed)
// ========================================
// .env files loaded automatically — no import needed

const dbUrl = Bun.env.DATABASE_URL;  // Bun-specific
// process.env.DATABASE_URL also works

// Load order (automatic):
// 1. .env.local
// 2. .env.development / .env.production (based on NODE_ENV)
// 3. .env

// Custom env file
// bun --env-file=.env.staging run server.ts
```

**Migration**: Remove `dotenv` from dependencies, remove `dotenv.config()` calls.

---

## TypeScript Configuration

Update `tsconfig.json` for Bun:

```jsonc
{
  "compilerOptions": {
    // ✅ Bun-optimized settings
    "target": "esnext",
    "module": "esnext",
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "noEmit": true,

    // ✅ Enable Bun types (install: bun add -d @types/bun)
    "types": ["bun-types"],

    // ✅ Keep these as-is
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,

    // ✅ Path aliases work natively in Bun
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"]
    },

    // ❌ Remove these Node.js-specific settings
    // "module": "commonjs",
    // "moduleResolution": "node",
    // "outDir": "./dist",  // Only needed if using tsc to compile
    // "declaration": true,  // Only for libraries
  },
  "include": ["src/**/*.ts", "src/**/*.tsx"],
  "exclude": ["node_modules", "dist"]
}
```

```bash
# Install Bun types
bun add -d @types/bun
```

---

## Docker Migration

```dockerfile
# ========================================
# BEFORE: Node.js Dockerfile
# ========================================
# FROM node:20-slim
# WORKDIR /app
# COPY package*.json ./
# RUN npm ci --production
# COPY . .
# RUN npm run build
# EXPOSE 3000
# CMD ["node", "dist/index.js"]

# ========================================
# AFTER: Bun Dockerfile
# ========================================
FROM oven/bun:1 AS base
WORKDIR /app

# Install dependencies (cached layer)
FROM base AS deps
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

# Build
FROM base AS build
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun build ./src/index.ts --outdir ./dist --target bun --minify

# Production
FROM base AS production
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

USER bun
EXPOSE 3000
CMD ["bun", "run", "dist/index.js"]
```

Key changes:
- `node:20-slim` → `oven/bun:1`
- `npm ci` → `bun install --frozen-lockfile`
- `node dist/index.js` → `bun run dist/index.js`
- No TypeScript build step needed (or use `bun build` for optimization)

---

## Step-by-Step Migration Checklist

### Phase 1: Drop-in Replacement (Low Risk)

- [ ] Install Bun: `curl -fsSL https://bun.sh/install | bash`
- [ ] Run `bun install` in your project (reads existing lockfile)
- [ ] Test with `bun run start` (or your start script)
- [ ] Run tests with `bun test` (if using Jest-compatible syntax)
- [ ] Commit `bun.lock` to version control
- [ ] Add `@types/bun` as a dev dependency

### Phase 2: Package Manager Migration

- [ ] Replace `npm install` with `bun install` in CI/CD
- [ ] Replace `npm run <script>` with `bun run <script>`
- [ ] Replace `npx` with `bunx` in scripts
- [ ] Remove `package-lock.json` or `yarn.lock`
- [ ] Update `.dockerignore` if needed
- [ ] Update team documentation

### Phase 3: Adopt Bun APIs (Optional, Performance)

- [ ] Replace `dotenv` with built-in .env support
- [ ] Replace `fs.readFile` / `fs.writeFile` with `Bun.file()` / `Bun.write()`
- [ ] Replace `bcrypt` / `argon2` packages with `Bun.password`
- [ ] Replace `crypto.createHash` with `Bun.CryptoHasher`
- [ ] Replace Express with `Bun.serve()` or Hono/Elysia
- [ ] Replace `child_process` with `Bun.$` shell
- [ ] Use `bun:sqlite` for SQLite instead of `better-sqlite3`
- [ ] Update tsconfig.json for Bun

### Phase 4: Test and Build Migration (Optional)

- [ ] Migrate Jest config to `bunfig.toml`
- [ ] Update test imports from `@jest/globals` to `bun:test`
- [ ] Replace `jest.fn()` with `mock()`, `jest.mock()` with `mock.module()`
- [ ] Replace webpack/esbuild with `bun build`
- [ ] Update CI/CD pipelines to use `oven-sh/setup-bun` action
- [ ] Update Dockerfile to use `oven/bun:1` base image

### Verification

- [ ] All tests pass with `bun test`
- [ ] Application starts with `bun run start`
- [ ] Docker image builds and runs correctly
- [ ] CI/CD pipeline passes
- [ ] Performance benchmarks show improvement (or at least parity)
