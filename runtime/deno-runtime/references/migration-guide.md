# Node.js to Deno Migration Guide

## Table of Contents

- [Overview and Strategy](#overview-and-strategy)
- [package.json → deno.json](#packagejson--denojson)
- [require → import (CommonJS → ESM)](#require--import-commonjs--esm)
- [Express → Oak / Hono / Fresh](#express--oak--hono--fresh)
- [Jest → Deno.test](#jest--denotest)
- [dotenv → Deno.env](#dotenv--denoenv)
- [fs → Deno File APIs](#fs--deno-file-apis)
- [child_process → Deno.Command](#child_process--denocommand)
- [node_modules → vendor](#node_modules--vendor)
- [CI/CD Pipeline Changes](#cicd-pipeline-changes)
- [Docker Multi-Stage Builds](#docker-multi-stage-builds)
- [Migration Checklist](#migration-checklist)

---

## Overview and Strategy

### Migration Approaches

**Incremental (recommended):** Migrate file by file, using Deno's Node.js
compatibility layer (`node:` specifiers, `npm:` imports) as a bridge.

**Big bang:** Convert the entire project at once. Works for small projects.

### Compatibility Bridge

Deno 2.x supports most Node.js APIs. Start by running your existing code:

```bash
# Try running your Node.js entry point directly
deno run --allow-all --node-modules-dir=auto main.js

# If it works, gradually tighten permissions and replace Node.js APIs
```

---

## package.json → deno.json

### Basic Conversion

**Before (package.json):**
```json
{
  "name": "my-api",
  "version": "1.0.0",
  "type": "module",
  "main": "src/index.js",
  "scripts": {
    "dev": "nodemon --watch src src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "test": "jest --coverage",
    "lint": "eslint src/",
    "format": "prettier --write src/"
  },
  "dependencies": {
    "express": "^4.18.0",
    "zod": "^3.22.0",
    "dotenv": "^16.0.0",
    "pg": "^8.11.0"
  },
  "devDependencies": {
    "typescript": "^5.3.0",
    "@types/express": "^4.17.0",
    "@types/node": "^20.0.0",
    "jest": "^29.0.0",
    "ts-jest": "^29.0.0",
    "eslint": "^8.0.0",
    "prettier": "^3.0.0",
    "nodemon": "^3.0.0"
  }
}
```

**After (deno.json):**
```jsonc
{
  "compilerOptions": {
    "strict": true,
    "jsx": "react-jsx",
    "jsxImportSource": "preact"
  },
  "imports": {
    "hono": "jsr:@hono/hono@^4",
    "zod": "npm:zod@^3.22.0",
    "postgres": "jsr:@db/postgres@^0.19.0",
    "~/": "./src/"
  },
  "tasks": {
    "dev": "deno run --watch --allow-net --allow-read --allow-env src/main.ts",
    "start": "deno run --allow-net --allow-read --allow-env src/main.ts",
    "test": "deno test --allow-read --allow-net --coverage",
    "lint": "deno lint",
    "fmt": "deno fmt",
    "check": "deno check src/main.ts"
  },
  "fmt": {
    "indentWidth": 2,
    "singleQuote": true,
    "semiColons": false
  },
  "lint": {
    "rules": {
      "tags": ["recommended"]
    }
  }
}
```

### Key Differences

| Node.js                         | Deno                                 |
|---------------------------------|--------------------------------------|
| `tsconfig.json`                 | `deno.json` → `compilerOptions`      |
| `.eslintrc`                     | `deno.json` → `lint`                 |
| `.prettierrc`                   | `deno.json` → `fmt`                  |
| `package.json` dependencies     | `deno.json` → `imports`              |
| `package.json` scripts          | `deno.json` → `tasks`               |
| `nodemon`                       | `deno run --watch`                   |
| `tsc` build step                | Not needed — Deno runs TS natively   |
| `@types/*` packages             | Not needed — Deno has built-in types |
| `ts-node` / `tsx`               | Not needed — native TS execution     |

### What You Can Remove

After migration, delete these files:
- `tsconfig.json` — replaced by `deno.json` compilerOptions
- `.eslintrc*` / `eslint.config.*` — replaced by `deno lint`
- `.prettierrc*` — replaced by `deno fmt`
- `jest.config.*` — replaced by built-in test runner
- `nodemon.json` — replaced by `--watch` flag
- `.babelrc` / `babel.config.*` — not needed
- `node_modules/` — not needed (unless using `nodeModulesDir`)
- `package-lock.json` / `yarn.lock` — replaced by `deno.lock`

---

## require → import (CommonJS → ESM)

### Basic Conversions

```typescript
// ❌ Node.js CommonJS
const express = require("express");
const { readFileSync } = require("fs");
const path = require("path");
const config = require("./config.json");
module.exports = { handler };
module.exports.default = app;

// ✅ Deno ESM
import express from "npm:express@4";        // or use Hono/Oak instead
import { readFileSync } from "node:fs";      // or use Deno.readTextFileSync
import * as path from "node:path";           // or use jsr:@std/path
const config = JSON.parse(await Deno.readTextFile("./config.json"));
export { handler };
export default app;
```

### Dynamic require → Dynamic import

```typescript
// ❌ Node.js
const plugin = require(`./plugins/${name}.js`);

// ✅ Deno
const plugin = await import(`./plugins/${name}.ts`);
```

### Conditional require → Conditional import

```typescript
// ❌ Node.js
let sharp;
try {
  sharp = require("sharp");
} catch {
  sharp = null;
}

// ✅ Deno
let sharp: typeof import("npm:sharp") | null;
try {
  sharp = await import("npm:sharp");
} catch {
  sharp = null;
}
```

### __dirname / __filename Replacement

```typescript
// ❌ Node.js
const configPath = path.join(__dirname, "config.json");

// ✅ Deno
const configPath = new URL("./config.json", import.meta.url).pathname;

// ✅ Helper if used frequently
import { dirname, fromFileUrl, join } from "jsr:@std/path";
const __dirname = dirname(fromFileUrl(import.meta.url));
const __filename = fromFileUrl(import.meta.url);
const configPath2 = join(__dirname, "config.json");
```

---

## Express → Oak / Hono / Fresh

### Express → Hono (Recommended for APIs)

**Before (Express):**
```typescript
import express from "express";
import cors from "cors";

const app = express();
app.use(cors());
app.use(express.json());

app.get("/api/users", (req, res) => {
  res.json([{ id: 1, name: "Alice" }]);
});

app.post("/api/users", (req, res) => {
  const user = req.body;
  res.status(201).json({ created: user });
});

app.get("/api/users/:id", (req, res) => {
  res.json({ id: req.params.id });
});

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: "Internal Server Error" });
});

app.listen(3000, () => console.log("Server on :3000"));
```

**After (Hono):**
```typescript
import { Hono } from "jsr:@hono/hono";
import { cors } from "jsr:@hono/hono/cors";

const app = new Hono();
app.use("*", cors());

app.get("/api/users", (c) => {
  return c.json([{ id: 1, name: "Alice" }]);
});

app.post("/api/users", async (c) => {
  const user = await c.req.json();
  return c.json({ created: user }, 201);
});

app.get("/api/users/:id", (c) => {
  return c.json({ id: c.req.param("id") });
});

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "Internal Server Error" }, 500);
});

Deno.serve({ port: 3000 }, app.fetch);
```

### Express → Oak

```typescript
import { Application, Router } from "jsr:@oak/oak";

const router = new Router();
router.get("/api/users", (ctx) => {
  ctx.response.body = [{ id: 1, name: "Alice" }];
});

router.post("/api/users", async (ctx) => {
  const body = await ctx.request.body.json();
  ctx.response.status = 201;
  ctx.response.body = { created: body };
});

const app = new Application();
app.use(router.routes());
app.use(router.allowedMethods());

await app.listen({ port: 3000 });
```

### Express Middleware → Hono Middleware

```typescript
// Express
app.use((req, res, next) => {
  const start = Date.now();
  res.on("finish", () => {
    console.log(`${req.method} ${req.path} - ${Date.now() - start}ms`);
  });
  next();
});

// Hono
app.use("*", async (c, next) => {
  const start = Date.now();
  await next();
  console.log(`${c.req.method} ${c.req.path} - ${Date.now() - start}ms`);
});
```

---

## Jest → Deno.test

### Basic Test Conversion

**Before (Jest):**
```typescript
import { describe, it, expect, beforeEach, afterEach } from "@jest/globals";
import { UserService } from "../src/user-service";

describe("UserService", () => {
  let service: UserService;

  beforeEach(() => {
    service = new UserService();
  });

  it("should create a user", async () => {
    const user = await service.create({ name: "Alice" });
    expect(user.name).toBe("Alice");
    expect(user.id).toBeDefined();
  });

  it("should throw on duplicate email", async () => {
    await service.create({ name: "Alice", email: "a@b.com" });
    await expect(service.create({ name: "Bob", email: "a@b.com" }))
      .rejects.toThrow("Email already exists");
  });

  it("should return null for unknown user", async () => {
    const user = await service.findById("unknown");
    expect(user).toBeNull();
  });
});
```

**After (Deno.test):**
```typescript
import { describe, it, beforeEach } from "jsr:@std/testing/bdd";
import { assertEquals, assertRejects } from "jsr:@std/assert";
import { UserService } from "../src/user-service.ts";

describe("UserService", () => {
  let service: UserService;

  beforeEach(() => {
    service = new UserService();
  });

  it("should create a user", async () => {
    const user = await service.create({ name: "Alice" });
    assertEquals(user.name, "Alice");
    assertEquals(typeof user.id, "string");
  });

  it("should throw on duplicate email", async () => {
    await service.create({ name: "Alice", email: "a@b.com" });
    await assertRejects(
      () => service.create({ name: "Bob", email: "a@b.com" }),
      Error,
      "Email already exists",
    );
  });

  it("should return null for unknown user", async () => {
    const user = await service.findById("unknown");
    assertEquals(user, null);
  });
});
```

### Jest Assertions → Deno Assertions

| Jest                            | Deno (`jsr:@std/assert`)            |
|---------------------------------|-------------------------------------|
| `expect(x).toBe(y)`            | `assertEquals(x, y)`               |
| `expect(x).toEqual(y)`         | `assertEquals(x, y)` (deep equal)  |
| `expect(x).toBeTruthy()`       | `assert(x)`                        |
| `expect(x).toBeFalsy()`        | `assert(!x)`                       |
| `expect(x).toBeNull()`         | `assertEquals(x, null)`            |
| `expect(x).toBeUndefined()`    | `assertEquals(x, undefined)`       |
| `expect(x).toContain(y)`       | `assertStringIncludes(x, y)`       |
| `expect(x).toThrow()`          | `assertThrows(() => x())`          |
| `expect(x).rejects.toThrow()`  | `await assertRejects(() => x())`   |
| `expect(x).toMatch(/re/)`      | `assertMatch(x, /re/)`             |
| `expect(x).toBeGreaterThan(y)` | `assert(x > y)`                    |

### Jest Mocks → Deno Mocks

```typescript
// Jest
jest.spyOn(service, "save").mockResolvedValue({ id: "1" });
expect(service.save).toHaveBeenCalledTimes(1);

// Deno
import { stub, assertSpyCalls } from "jsr:@std/testing/mock";

const saveStub = stub(service, "save", () => Promise.resolve({ id: "1" }));
try {
  await service.process();
  assertSpyCalls(saveStub, 1);
} finally {
  saveStub.restore();
}
```

---

## dotenv → Deno.env

**Before (Node.js with dotenv):**
```typescript
import dotenv from "dotenv";
dotenv.config();

const dbUrl = process.env.DATABASE_URL;
const port = parseInt(process.env.PORT || "3000");
```

**After (Deno):**
```typescript
// Option 1: Use @std/dotenv (loads .env file)
import "jsr:@std/dotenv/load";

const dbUrl = Deno.env.get("DATABASE_URL");
const port = parseInt(Deno.env.get("PORT") ?? "3000");

// Option 2: No library needed — Deno reads .env natively
// Just use Deno.env.get() — Deno 2.x auto-loads .env files
const apiKey = Deno.env.get("API_KEY");
```

**Permission required:** `--allow-env` (or `--allow-env=DATABASE_URL,PORT`)

### process.env → Deno.env Mapping

```typescript
// ❌ Node.js
process.env.NODE_ENV
process.env.HOME
process.cwd()
process.exit(1)
process.argv

// ✅ Deno
Deno.env.get("DENO_ENV") // or any custom env var
Deno.env.get("HOME")
Deno.cwd()
Deno.exit(1)
Deno.args  // Note: doesn't include the executable path
```

---

## fs → Deno File APIs

### Common Conversions

```typescript
// ── Reading Files ──
// Node.js
import { readFile, readFileSync } from "fs";
import { readFile as readFileAsync } from "fs/promises";
const data = await readFileAsync("./file.txt", "utf-8");

// Deno
const data = await Deno.readTextFile("./file.txt");
const bytes = await Deno.readFile("./image.png");  // Uint8Array

// ── Writing Files ──
// Node.js
import { writeFile } from "fs/promises";
await writeFile("./out.txt", "content", "utf-8");

// Deno
await Deno.writeTextFile("./out.txt", "content");
await Deno.writeFile("./out.bin", new Uint8Array([1, 2, 3]));

// ── Check if File Exists ──
// Node.js
import { existsSync } from "fs";
if (existsSync("./config.json")) { /* ... */ }

// Deno
try {
  await Deno.stat("./config.json");
  // exists
} catch (e) {
  if (e instanceof Deno.errors.NotFound) { /* doesn't exist */ }
}
// Or use @std/fs
import { exists } from "jsr:@std/fs";
if (await exists("./config.json")) { /* ... */ }

// ── Directory Operations ──
// Node.js
import { mkdir, readdir, rm } from "fs/promises";
await mkdir("./dir", { recursive: true });
const entries = await readdir("./src", { withFileTypes: true });
await rm("./temp", { recursive: true, force: true });

// Deno
await Deno.mkdir("./dir", { recursive: true });
for await (const entry of Deno.readDir("./src")) {
  console.log(entry.name, entry.isFile);
}
await Deno.remove("./temp", { recursive: true });

// ── File Watching ──
// Node.js
import { watch } from "fs";
watch("./src", { recursive: true }, (event, filename) => {
  console.log(event, filename);
});

// Deno
const watcher = Deno.watchFs("./src");
for await (const event of watcher) {
  console.log(event.kind, event.paths);
}

// ── Streams ──
// Node.js
import { createReadStream } from "fs";
const stream = createReadStream("./large.txt");

// Deno
const file = await Deno.open("./large.txt");
const stream = file.readable;  // ReadableStream (Web API)
```

---

## child_process → Deno.Command

```typescript
// ── exec / execSync ──
// Node.js
import { execSync, exec } from "child_process";
const output = execSync("git status", { encoding: "utf-8" });
exec("git push", (err, stdout) => console.log(stdout));

// Deno
const cmd = new Deno.Command("git", {
  args: ["status"],
  stdout: "piped",
});
const { stdout } = await cmd.output();
const output = new TextDecoder().decode(stdout);

// ── spawn (long-running process) ──
// Node.js
import { spawn } from "child_process";
const child = spawn("npm", ["run", "dev"], { stdio: "inherit" });
child.on("exit", (code) => console.log(`Exited: ${code}`));

// Deno
const proc = new Deno.Command("deno", {
  args: ["task", "dev"],
  stdout: "inherit",
  stderr: "inherit",
}).spawn();
const status = await proc.status;
console.log(`Exited: ${status.code}`);

// ── Piping stdin ──
// Node.js
const child2 = spawn("wc", ["-l"], { stdio: ["pipe", "pipe", "inherit"] });
child2.stdin.write("line1\nline2\nline3\n");
child2.stdin.end();

// Deno
const proc2 = new Deno.Command("wc", {
  args: ["-l"],
  stdin: "piped",
  stdout: "piped",
}).spawn();
const writer = proc2.stdin.getWriter();
await writer.write(new TextEncoder().encode("line1\nline2\nline3\n"));
await writer.close();
const result = await proc2.output();
```

**Permission required:** `--allow-run` (or `--allow-run=git,deno`)

---

## node_modules → vendor

### Vendor Directory

Instead of `node_modules`, Deno can vendor dependencies into a local directory:

```bash
# Vendor all dependencies
deno vendor main.ts

# Creates vendor/ directory with all dependencies
# and vendor/import_map.json
```

### Import Map vs node_modules

```jsonc
// deno.json — no node_modules needed
{
  "imports": {
    "hono": "jsr:@hono/hono@^4",
    "zod": "npm:zod@^3"
  }
}
// Dependencies are cached globally in ~/.cache/deno/

// For npm packages that need node_modules layout:
{
  "nodeModulesDir": "auto"
}
// Creates node_modules/ automatically
```

### Lock File

```bash
# Generate lock file (like package-lock.json)
deno cache --lock=deno.lock --lock-write main.ts

# Verify lock file integrity in CI
deno cache --lock=deno.lock --frozen main.ts
```

---

## CI/CD Pipeline Changes

### GitHub Actions: Node.js → Deno

**Before (Node.js):**
```yaml
name: CI
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npm run build
      - run: npm test -- --coverage
```

**After (Deno):**
```yaml
name: CI
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: denoland/setup-deno@v2
        with:
          deno-version: v2.x
      - run: deno fmt --check
      - run: deno lint
      - run: deno check src/main.ts
      - run: deno test --allow-read --allow-net --coverage=cov
      - run: deno coverage cov --lcov > coverage.lcov
```

### GitLab CI

```yaml
deno:
  image: denoland/deno:latest
  script:
    - deno fmt --check
    - deno lint
    - deno test --allow-read --coverage=cov
    - deno coverage cov
```

---

## Docker Multi-Stage Builds

### Node.js Dockerfile → Deno Dockerfile

**Before (Node.js):**
```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --production=false
COPY . .
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --production
COPY --from=builder /app/dist ./dist
EXPOSE 3000
CMD ["node", "dist/index.js"]
```

**After (Deno — interpreted):**
```dockerfile
FROM denoland/deno:latest AS base

WORKDIR /app

# Cache dependencies
COPY deno.json deno.lock ./
RUN deno install

# Copy source and cache
COPY . .
RUN deno cache main.ts

# Runtime
FROM denoland/deno:latest
WORKDIR /app
COPY --from=base /app .
COPY --from=base /root/.cache/deno /root/.cache/deno

EXPOSE 8000
USER deno

CMD ["run", "--allow-net=0.0.0.0:8000", "--allow-env", "--allow-read=.", "--cached-only", "main.ts"]
```

**After (Deno — compiled to binary):**
```dockerfile
FROM denoland/deno:latest AS builder

WORKDIR /app
COPY . .
RUN deno compile \
  --allow-net=0.0.0.0:8000 \
  --allow-env \
  --allow-read=. \
  --output=server \
  main.ts

FROM gcr.io/distroless/cc-debian12
COPY --from=builder /app/server /server
EXPOSE 8000
ENTRYPOINT ["/server"]
```

### Docker Compose

```yaml
services:
  api:
    build: .
    ports:
      - "8000:8000"
    environment:
      - DATABASE_URL=postgres://db:5432/myapp
      - DENO_ENV=production
    depends_on:
      - db

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: myapp
      POSTGRES_PASSWORD: secret
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

---

## Migration Checklist

### Phase 1: Setup
- [ ] Install Deno: `curl -fsSL https://deno.land/install.sh | sh`
- [ ] Create `deno.json` with compiler options, imports, tasks
- [ ] Convert `package.json` scripts to `deno.json` tasks
- [ ] Set up import map for all dependencies

### Phase 2: Code Changes
- [ ] Replace all `require()` with `import`
- [ ] Add `node:` prefix to Node.js built-in imports
- [ ] Replace `__dirname`/`__filename` with `import.meta.url`
- [ ] Replace `process.env` with `Deno.env.get()`
- [ ] Replace `process.exit()` with `Deno.exit()`
- [ ] Replace `process.argv` with `Deno.args`
- [ ] Replace `Buffer` usage with `Uint8Array` where possible
- [ ] Replace `module.exports` with `export`
- [ ] Add `.ts` extensions to relative imports
- [ ] Replace `fs` calls with `Deno.*` file APIs
- [ ] Replace `child_process` with `Deno.Command`

### Phase 3: Framework Migration
- [ ] Replace Express/Fastify with Hono/Oak/Fresh
- [ ] Convert middleware patterns
- [ ] Update route definitions
- [ ] Replace body parsing (built into Hono/Oak)

### Phase 4: Testing
- [ ] Replace Jest/Mocha with `Deno.test` or `@std/testing/bdd`
- [ ] Convert assertions to `@std/assert`
- [ ] Convert mocks to `@std/testing/mock`
- [ ] Add permission flags to test commands
- [ ] Set up coverage reporting

### Phase 5: Infrastructure
- [ ] Update CI/CD pipelines
- [ ] Update Dockerfile
- [ ] Update deploy scripts
- [ ] Configure permission flags for production
- [ ] Generate and commit `deno.lock`
- [ ] Remove `node_modules/`, `package-lock.json`, `tsconfig.json`, etc.

### Phase 6: Validation
- [ ] Run `deno lint` — fix all issues
- [ ] Run `deno fmt --check` — format code
- [ ] Run `deno check` — verify TypeScript
- [ ] Run full test suite
- [ ] Performance test under load
- [ ] Verify all API endpoints work
- [ ] Test in staging environment
