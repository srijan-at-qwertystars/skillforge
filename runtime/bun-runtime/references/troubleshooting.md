# Bun Troubleshooting Guide

## Table of Contents

- [npm Package Compatibility](#npm-package-compatibility)
  - [Native Modules and node-gyp](#native-modules-and-node-gyp)
  - [Packages That Don't Work](#packages-that-dont-work)
  - [Polyfill and Shim Issues](#polyfill-and-shim-issues)
- [Node.js API Gaps](#nodejs-api-gaps)
  - [Missing net.createServer Features](#missing-netcreateserver-features)
  - [Incomplete Stream Support](#incomplete-stream-support)
  - [Other Partial Implementations](#other-partial-implementations)
- [Bundler vs Runtime Behavior Differences](#bundler-vs-runtime-behavior-differences)
- [TypeScript Config Gotchas](#typescript-config-gotchas)
  - [Module Resolution](#module-resolution)
  - [Path Aliases](#path-aliases)
  - [JSX Configuration](#jsx-configuration)
- [Workspace Dependency Hoisting](#workspace-dependency-hoisting)
- [bun.lockb / bun.lock Merge Conflicts](#bunlockb--bunlock-merge-conflicts)
- [Memory Leaks in Long-Running Servers](#memory-leaks-in-long-running-servers)
- [Docker Build Optimization](#docker-build-optimization)
- [CI/CD Integration Issues](#cicd-integration-issues)
  - [GitHub Actions](#github-actions)
  - [GitLab CI](#gitlab-ci)
  - [General CI Tips](#general-ci-tips)
- [Bun.serve vs Express Migration Pitfalls](#bunserve-vs-express-migration-pitfalls)
- [Common Error Messages](#common-error-messages)

---

## npm Package Compatibility

### Native Modules and node-gyp

**Problem**: Packages with native C/C++ addons using `node-gyp` may fail to install or load.

```
error: could not resolve "node-gyp-build"
error: native module compilation failed
```

**Solutions**:

1. **Check for Bun-compatible alternatives**:
   ```bash
   # Instead of bcrypt (native), use:
   # Bun has built-in Bun.password.hash() with bcrypt/argon2
   const hash = await Bun.password.hash("password", { algorithm: "bcrypt" });

   # Instead of better-sqlite3 (native), use built-in bun:sqlite
   import { Database } from "bun:sqlite";

   # Instead of sharp, check if the package offers a WASM variant
   ```

2. **Install build dependencies** (if you must use a native module):
   ```bash
   # macOS
   xcode-select --install

   # Ubuntu/Debian
   apt-get install -y python3 make g++ build-essential

   # Alpine
   apk add python3 make g++ gcc libc-dev
   ```

3. **Use `--backend=copyfile`** or `--backend=symlink`** if linking fails:
   ```bash
   bun install --backend=copyfile
   ```

4. **Pre-built binaries**: Some packages (like `esbuild`, `@swc/core`) ship platform-specific prebuilt binaries. Ensure the correct `optionalDependencies` for your platform are installed.

### Packages That Don't Work

Known incompatible patterns:

| Package/Pattern | Issue | Workaround |
|----------------|-------|------------|
| `node-gyp` native addons | Compilation may fail | Use Bun built-ins or WASM alternatives |
| `vm` module heavy use | Partial `vm` support | Limit `vm` usage or use `eval` |
| `inspector` protocol | Not implemented | Use `--inspect` flag for debugging |
| `cluster` module | Partial support | Use `reusePort` + Workers instead |
| `dgram` (UDP) | Partial support | Check Bun release notes for updates |

**Diagnosis**: Run `bun install` first. If install succeeds but runtime fails:

```bash
# Check which module is failing
bun run --inspect-brk your-app.ts
# Or add error boundaries to isolate the failing module
```

### Polyfill and Shim Issues

**Problem**: Some packages depend on Node.js polyfills that behave differently in Bun.

```typescript
// ❌ This may fail — some polyfill packages are unnecessary in Bun
import { Buffer } from "buffer"; // npm polyfill package

// ✅ Use Node.js built-in directly — Bun supports it
import { Buffer } from "node:buffer";
// Or just use Buffer global directly — it's available
```

**Fix**: Remove browser polyfill packages and use Node.js built-in modules directly:
- Remove `buffer`, `process`, `events`, `stream`, `util` polyfill packages
- Use `node:` prefix imports instead

---

## Node.js API Gaps

### Missing net.createServer Features

**Problem**: `net.createServer` works for basic TCP but some advanced features are missing.

```typescript
// ✅ Works — basic TCP server
import { createServer } from "node:net";
const server = createServer((socket) => {
  socket.write("hello");
  socket.end();
});
server.listen(8080);

// ⚠️ May not work — advanced options
server.maxConnections = 100;    // May not be enforced
server.ref() / server.unref();  // Partial support
```

**Workaround**: For HTTP servers, use `Bun.serve()` which is fully supported and faster. For raw TCP, test your specific use case — basic send/receive works.

### Incomplete Stream Support

**Problem**: Node.js `stream` module is partially implemented. Complex stream patterns may fail.

```typescript
// ✅ Works — basic readable/writable streams
import { Readable, Writable } from "node:stream";

// ✅ Works — pipeline
import { pipeline } from "node:stream/promises";

// ⚠️ May have issues — Transform streams with complex backpressure
import { Transform } from "node:stream";

// ✅ Preferred — use Web Streams API instead
const stream = new ReadableStream({
  start(controller) {
    controller.enqueue("data");
    controller.close();
  },
});
```

**Best practice**: Prefer Web Streams API (`ReadableStream`, `WritableStream`, `TransformStream`) over Node.js streams. Bun's Web Streams implementation is complete and performant.

### Other Partial Implementations

| Module | Status | Notes |
|--------|--------|-------|
| `worker_threads` | Partial | Use Web `Worker` API instead |
| `cluster` | Partial | Use `reusePort` for multi-core |
| `dgram` (UDP) | Partial | Basic functionality works |
| `dns.resolve` | Works | `dns.lookup` also works |
| `vm` | Partial | `vm.runInNewContext` has limitations |
| `async_hooks` | Partial | `AsyncLocalStorage` works |
| `perf_hooks` | Partial | Basic `performance.now()` works |
| `diagnostics_channel` | Not yet | Use standard logging |

---

## Bundler vs Runtime Behavior Differences

**Problem**: Code works with `bun run` but fails after `bun build`, or vice versa.

Common causes:

1. **Runtime-only APIs used in browser bundle**:
   ```typescript
   // ❌ This fails when target is "browser"
   const result = await Bun.build({
     entrypoints: ["./app.ts"],
     target: "browser",  // Bun.file, Bun.serve, etc. are not available in browsers
   });

   // ✅ Set correct target
   target: "bun"  // for Bun server code
   target: "node"  // for Node.js
   ```

2. **Dynamic require/import**:
   ```typescript
   // ❌ Bundler can't resolve dynamic paths
   const mod = require(`./plugins/${name}.js`);

   // ✅ Use explicit imports or import.meta.glob (if supported)
   const plugins = {
     auth: await import("./plugins/auth.js"),
     cache: await import("./plugins/cache.js"),
   };
   ```

3. **`__dirname` / `__filename` differences**:
   ```typescript
   // In runtime: works (Bun polyfills these)
   console.log(__dirname);

   // After bundling: may point to bundle output dir, not source dir
   // ✅ Use import.meta.dir and import.meta.file instead
   console.log(import.meta.dir);   // directory of current file
   console.log(import.meta.file);  // current file name
   console.log(import.meta.path);  // full path of current file
   ```

4. **Environment variables at build time vs runtime**:
   ```typescript
   // ❌ Bundler inlines process.env.NODE_ENV at build time
   if (process.env.NODE_ENV === "development") { ... }

   // ✅ Use Bun.env for runtime-only access (not inlined by bundler)
   if (Bun.env.NODE_ENV === "development") { ... }
   ```

---

## TypeScript Config Gotchas

### Module Resolution

**Problem**: TypeScript module resolution doesn't match Bun's resolution.

```jsonc
// tsconfig.json — recommended for Bun projects
{
  "compilerOptions": {
    // ✅ Use bundler resolution — matches Bun's behavior
    "moduleResolution": "bundler",
    "module": "esnext",
    "target": "esnext",

    // ❌ Don't use these — they don't match Bun's resolver
    // "moduleResolution": "node",
    // "moduleResolution": "node16",

    // ✅ Enable Bun types
    "types": ["bun-types"],

    // ✅ Allow importing .ts files without extensions
    "allowImportingTsExtensions": true,
    "noEmit": true
  }
}
```

### Path Aliases

**Problem**: Path aliases in `tsconfig.json` don't resolve at runtime.

```jsonc
// tsconfig.json
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"],
      "@lib/*": ["src/lib/*"]
    }
  }
}
```

**Solution**: Bun respects `tsconfig.json` paths natively — no additional configuration needed. But ensure:
1. `baseUrl` is set correctly (usually `"."`)
2. The paths map to actual files
3. You're running with `bun run`, not building with `bun build` (bundler handles paths differently)

For `bun build`, paths are resolved during bundling automatically.

### JSX Configuration

```jsonc
{
  "compilerOptions": {
    // For React
    "jsx": "react-jsx",
    "jsxImportSource": "react",

    // For Preact
    // "jsx": "react-jsx",
    // "jsxImportSource": "preact",

    // For custom JSX runtime
    // "jsx": "react-jsx",
    // "jsxImportSource": "my-jsx-lib"
  }
}
```

**Gotcha**: If JSX doesn't work, ensure `@types/react` is installed and `tsconfig.json` has the correct `jsx` setting. Bun reads the config file automatically.

---

## Workspace Dependency Hoisting

**Problem**: Monorepo workspace packages can't find dependencies.

```
error: Cannot find module "shared-utils"
```

**Solutions**:

1. **Check workspace config** in root `package.json`:
   ```json
   {
     "workspaces": ["packages/*", "apps/*"]
   }
   ```

2. **Reference workspace packages correctly**:
   ```json
   // apps/web/package.json
   {
     "dependencies": {
       "shared-utils": "workspace:*"
     }
   }
   ```

3. **Re-install after workspace changes**:
   ```bash
   bun install  # from workspace root
   ```

4. **Hoisting issues**: If a package needs to be in a specific `node_modules`:
   ```toml
   # bunfig.toml
   [install]
   # Disable hoisting for specific packages
   ```

---

## bun.lockb / bun.lock Merge Conflicts

**Problem**: `bun.lockb` (binary) or `bun.lock` (text) has merge conflicts.

### For bun.lock (text-based, Bun 1.2+)

```bash
# Text-based lockfile — resolve like any text file merge
git checkout --theirs bun.lock  # or --ours
bun install  # regenerate
```

### For bun.lockb (legacy binary)

```bash
# Binary lockfile — cannot be merged manually
# Option 1: Accept one side and regenerate
git checkout --theirs bun.lockb
bun install

# Option 2: Delete and regenerate
rm bun.lockb
bun install

# Prevent future conflicts with .gitattributes
echo "bun.lockb binary" >> .gitattributes
echo "bun.lockb -diff -merge" >> .gitattributes
```

**Best practice**: Upgrade to `bun.lock` (text-based) by running `bun install` with Bun 1.2+. It automatically creates the text lockfile.

---

## Memory Leaks in Long-Running Servers

**Symptoms**: Memory usage grows over time, eventual OOM kill.

### Debugging

```typescript
// Log memory usage periodically
setInterval(() => {
  const mem = process.memoryUsage();
  console.log({
    rss: `${(mem.rss / 1024 / 1024).toFixed(1)}MB`,
    heap: `${(mem.heapUsed / 1024 / 1024).toFixed(1)}MB`,
    heapTotal: `${(mem.heapTotal / 1024 / 1024).toFixed(1)}MB`,
  });
}, 30_000);
```

### Common Causes and Fixes

1. **Unbounded caches**:
   ```typescript
   // ❌ Map grows without limit
   const cache = new Map();

   // ✅ Use an LRU cache or WeakMap
   // For object keys:
   const cache = new WeakMap();

   // For string keys, limit size:
   const MAX_CACHE = 10_000;
   function setCache(key: string, value: any) {
     if (cache.size >= MAX_CACHE) {
       const firstKey = cache.keys().next().value;
       cache.delete(firstKey);
     }
     cache.set(key, value);
   }
   ```

2. **Event listener accumulation**:
   ```typescript
   // ❌ Listeners added on every request
   server.on("request", (req) => {
     req.on("data", handler);  // Never removed
   });

   // ✅ Remove listeners when done
   req.on("data", handler);
   req.on("end", () => req.removeListener("data", handler));
   ```

3. **Unclosed resources**:
   ```typescript
   // ❌ Database connections opened but not closed
   async function query(sql: string) {
     const db = new Database("app.db");
     return db.prepare(sql).all();
     // db never closed!
   }

   // ✅ Reuse a single connection or close properly
   const db = new Database("app.db");
   process.on("SIGTERM", () => db.close());
   ```

4. **Large response buffering**:
   ```typescript
   // ❌ Loading entire file into memory
   const data = await Bun.file("huge.json").text();
   return new Response(data);

   // ✅ Stream the response
   return new Response(Bun.file("huge.json"));
   ```

5. **Use `--smol` flag** for reduced memory baseline:
   ```bash
   bun --smol run server.ts
   ```

---

## Docker Build Optimization

### Slow Builds

**Problem**: Docker builds are slow due to reinstalling dependencies.

```dockerfile
# ❌ Bad — copies everything before install
FROM oven/bun:1
WORKDIR /app
COPY . .
RUN bun install

# ✅ Good — leverage Docker layer caching
FROM oven/bun:1
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production
COPY . .
```

### Large Images

```dockerfile
# ✅ Multi-stage build for minimal production image
FROM oven/bun:1 AS build
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun build ./src/index.ts --outdir ./dist --target bun --minify

FROM oven/bun:1-slim AS production
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
USER bun
CMD ["bun", "run", "dist/index.js"]
```

### Alpine Base Image

```dockerfile
# oven/bun:1-alpine for smaller base (~50MB vs ~150MB)
FROM oven/bun:1-alpine
# Note: Alpine uses musl libc — some native modules may not work
```

### .dockerignore

Always create a `.dockerignore`:

```
node_modules
.git
dist
*.md
.env*
.vscode
coverage
```

### Health Checks

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bun -e "fetch('http://localhost:3000/health').then(r => process.exit(r.ok ? 0 : 1))"
```

---

## CI/CD Integration Issues

### GitHub Actions

```yaml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: latest

      - name: Install
        run: bun install --frozen-lockfile

      - name: Type check
        run: bun x tsc --noEmit

      - name: Test
        run: bun test

      - name: Build
        run: bun build ./src/index.ts --outdir ./dist --target bun
```

**Common CI Issues**:

1. **`--frozen-lockfile` fails**: Lockfile is outdated. Run `bun install` locally and commit `bun.lock`.

2. **Tests pass locally but fail in CI**:
   - Check for timezone-dependent tests
   - Check for file system case sensitivity (macOS vs Linux)
   - Ensure `.env` files aren't in `.gitignore` if tests need them
   - Use `--bail` to stop on first failure for faster debugging

3. **Cache setup**:
   ```yaml
   - uses: actions/cache@v4
     with:
       path: ~/.bun/install/cache
       key: ${{ runner.os }}-bun-${{ hashFiles('bun.lock') }}
       restore-keys: ${{ runner.os }}-bun-
   ```

### GitLab CI

```yaml
image: oven/bun:1

stages:
  - test
  - build

test:
  stage: test
  script:
    - bun install --frozen-lockfile
    - bun test
  cache:
    key: $CI_COMMIT_REF_SLUG
    paths:
      - node_modules/

build:
  stage: build
  script:
    - bun install --frozen-lockfile
    - bun build ./src/index.ts --outdir ./dist --target bun
  artifacts:
    paths:
      - dist/
```

### General CI Tips

- Always use `--frozen-lockfile` in CI
- Cache `~/.bun/install/cache` for faster installs
- Set `CI=true` environment variable (Bun checks this)
- Use `bun test --bail` for fail-fast in CI
- Pin Bun version for reproducible builds

---

## Bun.serve vs Express Migration Pitfalls

### Middleware Pattern Differences

```typescript
// ❌ Express middleware chain doesn't exist in Bun.serve
// app.use(cors());
// app.use(express.json());
// app.get("/api", handler);

// ✅ Bun.serve — handle everything in fetch
Bun.serve({
  fetch(req) {
    // Manual CORS
    if (req.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE",
          "Access-Control-Allow-Headers": "Content-Type, Authorization",
        },
      });
    }

    // Manual body parsing
    const url = new URL(req.url);
    if (url.pathname === "/api" && req.method === "POST") {
      const body = await req.json();
      // ...
    }
  },
});
```

**Recommendation**: Use a lightweight framework on top of `Bun.serve()`:

```typescript
// Hono — lightweight, works great with Bun
import { Hono } from "hono";
import { cors } from "hono/cors";

const app = new Hono();
app.use("*", cors());
app.get("/api", (c) => c.json({ hello: "world" }));

export default app;  // Bun auto-detects and serves Hono apps
```

### Request/Response API Differences

```typescript
// Express: req.params, req.query, req.body
// Bun.serve: Web standard Request/Response

// ❌ Express patterns that don't work
// req.params.id
// req.query.search
// res.json({ data })
// res.status(404).send("Not found")

// ✅ Web API equivalents
const url = new URL(req.url);
const searchParam = url.searchParams.get("search");
const body = await req.json();

// For route params, parse URL pathname or use a framework
return Response.json({ data });
return new Response("Not found", { status: 404 });
```

### Error Handling

```typescript
// Express: app.use((err, req, res, next) => ...)
// Bun.serve: use error handler option

Bun.serve({
  fetch(req) {
    throw new Error("Something broke");
  },
  error(err) {
    console.error(err);
    return new Response("Internal Server Error", { status: 500 });
  },
});
```

---

## Common Error Messages

### `error: Cannot find module`

```
error: Cannot find module "some-package"
```

**Fix**: Run `bun install`. If the package is a workspace dependency, ensure it's listed with `workspace:*` protocol.

### `error: expected module to have a default export`

**Fix**: The module uses CommonJS. Use named import:
```typescript
// ❌ import pkg from "cjs-package";
// ✅ import * as pkg from "cjs-package";
// ✅ const pkg = require("cjs-package");
```

### `TypeError: fetch is not a function` in tests

**Fix**: Ensure you're running with `bun test`, not `node`. Bun provides global `fetch`.

### `EACCES: permission denied`

**Fix**: Check file permissions. In Docker, ensure the `bun` user has access:
```dockerfile
RUN chown -R bun:bun /app
USER bun
```

### `bun install` hangs

**Possible causes**:
- Network issues with registry
- Lockfile corruption
- Postinstall scripts hanging

**Fix**:
```bash
rm -rf node_modules bun.lock
bun install --verbose
```

### `SIGKILL` in production (OOM)

**Fix**: 
- Use `--smol` flag to reduce memory
- Check for memory leaks (see [Memory Leaks](#memory-leaks-in-long-running-servers))
- Increase container memory limits
- Stream large files instead of buffering

### `TypeError: Bun.serve is not a function`

**Fix**: You're running the code with Node.js instead of Bun. Use `bun run` or check your Docker CMD.
