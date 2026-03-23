# Bun Troubleshooting Guide

## Table of Contents

- [Node.js Compatibility Issues](#nodejs-compatibility-issues)
- [npm Package Compatibility](#npm-package-compatibility)
- [Native Addon Problems](#native-addon-problems)
- [Memory Issues](#memory-issues)
- [Debugging with --inspect](#debugging-with---inspect)
- [Common Errors](#common-errors)
- [Docker Setup Gotchas](#docker-setup-gotchas)
- [CI/CD with Bun](#cicd-with-bun)

---

## Node.js Compatibility Issues

### Fully Supported Core Modules

These work identically or near-identically to Node.js:

`assert`, `buffer`, `child_process` (most APIs), `console`, `crypto` (most), `dgram`, `dns`,
`events`, `fs`, `http`, `https`, `net`, `os`, `path`, `querystring`, `readline`, `stream`,
`string_decoder`, `timers`, `tls`, `url`, `util`, `zlib`.

### Partially Supported — Watch For These

| Module | What Works | What Doesn't |
|---|---|---|
| `http2` | Most client/server APIs | `pushStream`, `ALTSVC` frames |
| `async_hooks` | `AsyncLocalStorage`, `AsyncResource` | `createHook`, `executionAsyncId` |
| `cluster` | Basic forking | Full IPC, `SO_REUSEPORT` only Linux |
| `worker_threads` | Basic workers | Sending socket handles via IPC |
| `vm` | `runInNewContext` (basic) | Full sandbox isolation, `measureMemory` |
| `crypto` | Hash, HMAC, sign/verify, random | `secureHeapUsed`, `setEngine`, some TLS |
| `child_process` | `spawn`, `exec`, `execFile` | Some edge-case stdio configurations |
| `node:module` | `createRequire` | Overriding require cache internals |

### Not Supported

- `node:inspector` — not implemented. Use `--inspect` flag instead.
- `node:trace_events` — not available.
- `node:domain` — deprecated in Node.js and unimplemented in Bun.
- Native C++ addons (non-N-API) — must use N-API or Bun alternatives.

### Behavioral Differences

```ts
// __dirname and __filename work in ESM (unlike Node.js)
console.log(__dirname);  // works in Bun ESM
console.log(__filename); // works in Bun ESM

// Bun-idiomatic alternatives
console.log(import.meta.dir);   // same as __dirname
console.log(import.meta.file);  // same as __filename

// process.exit() flushes I/O before exiting (Node.js may not)
// This can cause subtle timing differences in tests
```

---

## npm Package Compatibility

### Packages That Work

Most pure JavaScript/TypeScript packages work without changes:
- **Web frameworks**: Express, Fastify, Koa, Hono, Elysia
- **ORMs**: Prisma, Drizzle, TypeORM (with caveats)
- **Validation**: Zod, Joi, Yup
- **Utilities**: Lodash, date-fns, uuid, nanoid
- **HTTP clients**: Axios, ky, got (mostly)

### Packages That May Not Work

| Package | Issue | Alternative |
|---|---|---|
| `bcrypt` | Native C++ addon | `bcryptjs` (pure JS) |
| `sharp` | Native addon (libvips) | — (wait for N-API) |
| `canvas` | Native addon (cairo) | — |
| `better-sqlite3` | Native addon | `bun:sqlite` (built-in) |
| `cpu-features` | V8-specific | — |
| `v8-profiler` | V8-specific | Bun's built-in profiler |
| `isolated-vm` | V8-specific sandbox | — |

### Checking Compatibility

Before adopting a package, check for native dependencies:

```sh
# Look for native addons in node_modules
find node_modules -name "*.node" -o -name "binding.gyp" | head -20

# Check if a package has postinstall scripts that compile native code
grep -r '"postinstall"' node_modules/*/package.json | grep -v __
```

---

## Native Addon Problems

### Symptoms

- `Error: Could not load native module` or similar load errors
- `Module not found` for `.node` files
- Segfaults or crashes during package install
- `node-gyp` or `prebuild-install` failures

### Root Cause

Bun does not support Node.js N-API native addons (as of 2024). Any package that ships or compiles `.node` binary files will fail.

### Solutions

1. **Find pure-JS alternatives**: `bcryptjs` instead of `bcrypt`, `bun:sqlite` instead of `better-sqlite3`
2. **Use Bun's built-in equivalents**: `bun:sqlite`, `bun:ffi`, `Bun.password`
3. **Use bun:ffi** to call shared libraries directly:
   ```ts
   import { dlopen, FFIType } from "bun:ffi";
   const lib = dlopen("libsodium.so", {
     crypto_hash_sha256: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.i32 },
   });
   ```
4. **Keep Node.js for specific scripts** that require native addons

### Checking if a Dependency Uses Native Addons

```sh
# In your project root
bun install 2>&1 | grep -i "error\|warn\|native\|gyp"

# Check direct dependencies
for dir in node_modules/*/; do
  if [ -f "$dir/binding.gyp" ] || ls "$dir"/*.node 2>/dev/null | grep -q .; then
    echo "NATIVE: $dir"
  fi
done
```

---

## Memory Issues

### Diagnosing Memory Leaks

```ts
// Take heap snapshots at intervals
import { writeHeapSnapshot } from "v8";

// Periodic snapshot (use in dev only)
setInterval(() => {
  const filename = `heap-${Date.now()}.heapsnapshot`;
  writeHeapSnapshot(filename);
  console.log(`Snapshot written: ${filename}`);
}, 60_000);
```

Load `.heapsnapshot` files in Chrome DevTools → Memory tab → Load to compare.

### Common Memory Leak Causes

1. **Unbounded caches**: Maps/Sets that grow without eviction
2. **Event listener accumulation**: Not removing listeners on WebSocket close
3. **Global state with --hot**: Modules re-execute but `globalThis` persists
4. **Large request bodies**: Not streaming large uploads

### Mitigation

```ts
// Guard initialization with --hot
globalThis.cache ??= new Map();

// Set limits on caches
const MAX_CACHE = 10_000;
if (globalThis.cache.size > MAX_CACHE) {
  const oldest = globalThis.cache.keys().next().value;
  globalThis.cache.delete(oldest);
}

// Monitor memory usage
setInterval(() => {
  const usage = process.memoryUsage();
  console.log(`RSS: ${(usage.rss / 1024 / 1024).toFixed(1)} MB`);
  console.log(`Heap: ${(usage.heapUsed / 1024 / 1024).toFixed(1)} MB`);
}, 30_000);
```

### Docker Memory Spikes

Bun in Docker may consume more memory than Node.js for the same workload. Mitigations:

- Set container memory limits with headroom: `--memory=512m`
- Use `oven/bun:alpine` for smaller base image
- Avoid `--hot` in production — use `--watch` or process manager restart
- Profile with heap snapshots before and after migration

---

## Debugging with --inspect

### Starting the Debugger

```sh
bun --inspect server.ts          # Start debug server, run immediately
bun --inspect-brk server.ts      # Pause at first line
bun --inspect-wait server.ts     # Wait for debugger to attach before running

# Custom debug port
bun --inspect=0.0.0.0:9229 server.ts
```

### Connecting a Debugger

1. **Bun's web debugger**: Open the URL printed to console (e.g., `https://debug.bun.sh/...`)
2. **VS Code**: Add launch configuration:
   ```json
   {
     "type": "bun",
     "request": "launch",
     "name": "Debug Bun",
     "program": "${workspaceFolder}/src/index.ts",
     "stopOnEntry": false
   }
   ```
   Requires the [Bun VS Code extension](https://marketplace.visualstudio.com/items?itemName=oven.bun-vscode).
3. **Chrome DevTools**: Navigate to `chrome://inspect`, add `localhost:6499`

### Known Debugging Quirks

- Breakpoints may hit at unexpected lines with some frameworks (ElysiaJS, Hono)
- Step-over (F10) occasionally acts like continue (F8) in complex async code
- Source maps for bundled code may not always align — debug unbundled when possible

---

## Common Errors

### Module Resolution Errors

```
error: Cannot find module "./utils"
```

**Causes & fixes:**
- Bun resolves `tsconfig.json` paths — check `paths` and `baseUrl` config
- Missing file extension: Bun resolves `.ts` → `.tsx` → `.js` → `.jsx` → `/index.ts`
- Case sensitivity: Linux is case-sensitive, macOS is not

### TypeScript Quirks

```
error: Unexpected "export"
```

**Fixes:**
- Ensure `tsconfig.json` has `"module": "esnext"` or `"nodenext"`
- For libraries using `declare module`, ensure `bun-types` is in `types`:
  ```json
  { "compilerOptions": { "types": ["bun-types"] } }
  ```

### Import Assertion Errors

```
error: Import attribute "type" is not supported for this module
```

- Use `with` syntax: `import data from "./file" with { type: "json" }`
- The deprecated `assert` syntax is not supported in newer Bun versions

### EACCES / Permission Errors

```sh
# Global installs require ~/.bun/bin in PATH
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
```

### Lockfile Conflicts

```
error: lockfile had changes, but is frozen
```

- CI should use `bun install --frozen-lockfile` to catch dependency drift
- Locally: delete `bun.lockb` and `node_modules`, then `bun install`

---

## Docker Setup Gotchas

### Base Image Selection

| Image | Size | Use Case |
|---|---|---|
| `oven/bun:latest` | ~150 MB | Development, full tooling |
| `oven/bun:alpine` | ~90 MB | Production, smaller footprint |
| `oven/bun:slim` | ~100 MB | Production, Debian-based minimal |
| `oven/bun:distroless` | ~80 MB | Production, maximum security |

### Common Docker Issues

1. **Binary lockfile**: `bun.lockb` is binary — `COPY bun.lockb .` works fine but diffs are meaningless
2. **Cache invalidation**: Copy `package.json` + `bun.lockb` before source code for layer caching
3. **Alpine compatibility**: Some native packages need `apk add --no-cache build-base`
4. **Permissions**: `oven/bun` runs as `bun` user (UID 1000) — ensure volumes are writable
5. **Health checks**: Use `curl` or Bun's built-in `fetch` for health probes

### Multi-Stage Build Pattern

```dockerfile
FROM oven/bun:1 AS deps
WORKDIR /app
COPY package.json bun.lockb ./
RUN bun install --frozen-lockfile --production

FROM oven/bun:1-alpine AS runtime
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
USER bun
EXPOSE 3000
CMD ["bun", "run", "src/index.ts"]
```

---

## CI/CD with Bun

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
      - run: bun install --frozen-lockfile
      - run: bun test
      - run: bun run build

  # Cache for faster CI
  test-cached:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
      - uses: actions/cache@v4
        with:
          path: ~/.bun/install/cache
          key: bun-${{ runner.os }}-${{ hashFiles('bun.lockb') }}
      - run: bun install --frozen-lockfile
      - run: bun test --coverage
```

### GitLab CI

```yaml
image: oven/bun:1

stages: [test, build]

test:
  stage: test
  script:
    - bun install --frozen-lockfile
    - bun test --coverage
  cache:
    key: bun-${CI_COMMIT_REF_SLUG}
    paths: [node_modules/]

build:
  stage: build
  script:
    - bun install --frozen-lockfile
    - bun run build
  artifacts:
    paths: [dist/]
```

### Pinning Bun Versions

Always pin Bun versions in CI to avoid breaking changes:

```yaml
# GitHub Actions
- uses: oven-sh/setup-bun@v2
  with:
    bun-version: "1.1.38"

# Docker
FROM oven/bun:1.1.38-alpine

# Direct install
curl -fsSL https://bun.sh/install | bash -s "bun-v1.1.38"
```

### Common CI Issues

- **Frozen lockfile failures**: Ensure `bun.lockb` is committed and up to date
- **OOM in CI**: Bun may use more memory than Node.js — increase runner memory
- **Binary lockfile diffs**: Use `bun install --yarn` to generate text lockfile for review
- **ARM runners**: Use `bun-linux-arm64` target for ARM-based CI runners
