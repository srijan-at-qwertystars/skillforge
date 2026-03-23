# Troubleshooting — Remix / React Router v7

> Common issues, root causes, and fixes for production React Router v7 apps.

## Table of Contents

- [Hydration Mismatches](#hydration-mismatches)
- [Loader/Action Type Errors](#loaderaction-type-errors)
- [Cookie Handling Gotchas](#cookie-handling-gotchas)
- [CORS with Resource Routes](#cors-with-resource-routes)
- [Build Failures](#build-failures)
- [Vite Plugin Conflicts](#vite-plugin-conflicts)
- [Module Resolution Issues](#module-resolution-issues)
- [Deployment-Specific Problems](#deployment-specific-problems)
- [Debugging Techniques](#debugging-techniques)

---

## Hydration Mismatches

### Symptom
Console warning: `Hydration failed because the server-rendered HTML didn't match the client.`
Page may flash, re-mount, or lose state on load.

### Common Causes

| Cause | Fix |
|-------|-----|
| `Date.now()`, `Math.random()` in render | Move to `useEffect` or pass from loader |
| Accessing `window`, `localStorage` during SSR | Guard with `typeof window !== "undefined"` |
| Browser extensions injecting DOM nodes | Cannot fix — suppress in known cases |
| Locale-dependent formatting (dates, numbers) | Use `Intl` with explicit locale from loader |
| Invalid HTML nesting (`<p>` inside `<p>`) | Fix the markup — React is strict about this |
| CSS-in-JS generating different class names | Ensure SSR and client use same seed/config |
| Third-party components rendering differently | Wrap in `ClientOnly` component (see below) |

### ClientOnly wrapper

```tsx
import { useEffect, useState, type ReactNode } from "react";

export function ClientOnly({ children, fallback }: {
  children: () => ReactNode;
  fallback?: ReactNode;
}) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  return mounted ? <>{children()}</> : <>{fallback}</>;
}

// Usage
<ClientOnly fallback={<Skeleton />}>
  {() => <BrowserOnlyChart data={data} />}
</ClientOnly>
```

### Debugging hydration mismatches

1. Disable JavaScript in browser → view the SSR-only output.
2. Compare with JS-enabled output in React DevTools.
3. Add `suppressHydrationWarning` to specific elements as last resort.
4. Check `entry.server.tsx` — ensure `ServerRouter` receives correct context.

---

## Loader/Action Type Errors

### `react-router typegen` not generating types

```bash
# Ensure you're running typegen
npx react-router typegen --watch

# Types generate into app/routes/+types/ directories
# Check tsconfig.json includes the rootDirs:
{
  "compilerOptions": {
    "rootDirs": [".", ".react-router/types"]
  }
}
```

### Loader return type mismatch

```tsx
// ❌ ERROR: Type 'Response' is not assignable to type ...
export async function loader() {
  return json({ data: "hello" }); // json() removed in v7
}

// ✅ FIX: Return plain objects
export async function loader() {
  return { data: "hello" };
}
```

### Action returns `undefined`

Every code path in an action must return a value or throw. Returning `undefined`
causes `actionData` to be `undefined` even on success:

```tsx
// ❌ BAD
export async function action({ request }: Route.ActionArgs) {
  await doSomething();
  // implicit return undefined
}

// ✅ FIX
export async function action({ request }: Route.ActionArgs) {
  await doSomething();
  return redirect("/success");
  // or: return { ok: true };
}
```

### Component props not typed

In v7, route components receive data as props, not via hooks:

```tsx
// ❌ OLD (still works but not idiomatic)
export default function Page() {
  const data = useLoaderData<typeof loader>();
}

// ✅ NEW
export default function Page({ loaderData }: Route.ComponentProps) {
  // loaderData is auto-typed
}
```

---

## Cookie Handling Gotchas

### Cookie not being set

1. **Missing `Set-Cookie` header in response**:
```tsx
// ❌ Forgot to commit session
return redirect("/dashboard");

// ✅ Include the header
return redirect("/dashboard", {
  headers: { "Set-Cookie": await commitSession(session) },
});
```

2. **`secure: true` on non-HTTPS** — cookies won't set on `http://localhost`:
```tsx
cookie: {
  secure: process.env.NODE_ENV === "production", // false in dev
}
```

3. **`sameSite: "strict"` blocking cross-origin redirects** — use `"lax"` for OAuth flows.

### Cookie too large (>4KB)

Use `createFileSessionStorage` or `createDatabaseSessionStorage` instead of
cookie session storage for large session data. The cookie then only holds a
session ID.

### Multiple Set-Cookie headers

```tsx
// Use Headers object to append multiple cookies
const headers = new Headers();
headers.append("Set-Cookie", await commitSession(session));
headers.append("Set-Cookie", await themeStorage.serialize(theme));
return redirect("/", { headers });
```

---

## CORS with Resource Routes

### Preflight (OPTIONS) not handled

Browsers send OPTIONS preflight for non-simple requests. Resource routes need
to handle this explicitly:

```ts
export async function loader({ request }: Route.LoaderArgs) {
  if (request.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "https://your-frontend.com",
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
        "Access-Control-Max-Age": "86400",
      },
    });
  }

  const data = await getData();
  return Response.json(data, {
    headers: {
      "Access-Control-Allow-Origin": "https://your-frontend.com",
    },
  });
}
```

### Credentials with CORS

```ts
// Server: include credentials header
"Access-Control-Allow-Credentials": "true",
// Client: fetch with credentials
fetch("/api/data", { credentials: "include" });
```

**Note:** `Access-Control-Allow-Origin` cannot be `"*"` when credentials are
included. Use the specific origin.

---

## Build Failures

### `Cannot find module '@react-router/dev/vite'`

```bash
# Ensure correct packages are installed
npm install -D @react-router/dev
npm install react-router @react-router/node @react-router/serve
```

### `routes.ts` not found

React Router v7 framework mode requires `app/routes.ts`:
```ts
import { flatRoutes } from "@react-router/fs-routes";
import type { RouteConfig } from "@react-router/dev/routes";
export default flatRoutes() satisfies RouteConfig;
```

### Build OOM (Out of Memory)

```bash
NODE_OPTIONS="--max-old-space-size=8192" react-router build
```

### TypeScript errors after migration

```bash
# Regenerate types
npx react-router typegen
# Then check for errors
npx tsc --noEmit
```

---

## Vite Plugin Conflicts

### Plugin ordering matters

The `reactRouter()` plugin must come before most other plugins:
```ts
export default defineConfig({
  plugins: [
    reactRouter(),    // FIRST
    tsconfigPaths(),  // path aliases
    // other plugins after
  ],
});
```

### Known conflicts

| Plugin | Issue | Fix |
|--------|-------|-----|
| `vite-plugin-pwa` | Conflicts with SSR build | Use `injectManifest` strategy, exclude SSR entry |
| `@vanilla-extract/vite-plugin` | Order-dependent | Place after `reactRouter()` |
| `vite-plugin-svgr` | May break in SSR | Use `?react` suffix import |
| `vite-plugin-inspect` | Dev-only conflicts | Conditionally include |

### `optimizeDeps` issues in dev

```ts
export default defineConfig({
  optimizeDeps: {
    include: ["react", "react-dom", "react-router"],
  },
});
```

### HMR not working

- Ensure you're using `react-router dev` (not plain `vite dev`).
- Check for circular dependencies — they break HMR silently.
- Clear `.react-router/` and `node_modules/.vite/` cache dirs.

---

## Module Resolution Issues

### `Cannot resolve './+types/...'`

Types are auto-generated. Run `react-router typegen` first:
```bash
npx react-router typegen
```
Add to `tsconfig.json`:
```json
{
  "compilerOptions": {
    "rootDirs": [".", ".react-router/types"]
  },
  "include": [".react-router/types/**/*", "app/**/*"]
}
```

### Path aliases not resolving

Ensure `vite-tsconfig-paths` is installed and in your Vite config:
```bash
npm install -D vite-tsconfig-paths
```

### `.server.ts` files imported from client

Files ending in `.server.ts` are stripped from client bundles. Importing them
from a client component causes a build error:
```
Error: Cannot import server-only module "~/utils/db.server" from client
```
Fix: Move the import into a loader/action, never into a component.

---

## Deployment-Specific Problems

### Node.js (default adapter)

| Problem | Fix |
|---------|-----|
| `EADDRINUSE` on port 3000 | Set `PORT` env var or kill existing process |
| Static assets 404 | Ensure `express.static("build/client")` is configured |
| Memory leaks on long-running | Use `--max-old-space-size` and monitor with `clinic.js` |

### Cloudflare Workers / Pages

| Problem | Fix |
|---------|-----|
| Node.js APIs unavailable | Use `node_compat = true` in `wrangler.toml` or polyfill |
| Module size > 1MB | Tree-shake, split routes, reduce dependencies |
| `crypto` not available | Use `globalThis.crypto` (Web Crypto API) |
| KV/D1 bindings undefined | Access via `context.cloudflare.env` in loaders |

### Vercel

| Problem | Fix |
|---------|-----|
| Serverless function timeout | Increase `maxDuration` in `vercel.json` |
| ISR not working | Use `prerender` in `react-router.config.ts` instead |
| Edge runtime incompatibility | Ensure deps are edge-compatible |

### Fly.io / Docker

| Problem | Fix |
|---------|-----|
| Health check fails | Add `GET /healthcheck` resource route |
| Cold start slow | Use `min_machines_running = 1` |
| Volume mounts for file storage | Use persistent volumes for uploads |

---

## Debugging Techniques

### 1. React Router Dev Tools

Install from npm and add to your root:
```bash
npm install -D react-router-devtools
```
Shows route hierarchy, loader data, active params, and pending navigations.

### 2. Network waterfall analysis

In Chrome DevTools → Network tab, filter by "Doc" to see SSR responses.
Check the response body for streamed data boundaries.

### 3. Loader/action logging

```tsx
export async function loader({ request, params }: Route.LoaderArgs) {
  console.time(`loader:${request.url}`);
  const data = await fetchData(params.id);
  console.timeEnd(`loader:${request.url}`);
  return data;
}
```

### 4. Request signal for cancellation debugging

```tsx
export async function loader({ request }: Route.LoaderArgs) {
  if (request.signal.aborted) {
    console.log("Request was cancelled before loader ran");
    throw new Response("Request cancelled", { status: 499 });
  }
  // Pass signal to downstream fetches
  const res = await fetch("https://api.example.com/data", {
    signal: request.signal,
  });
  return res.json();
}
```

### 5. Catch revalidation loops

If your app makes infinite loader calls after an action, check:
- `shouldRevalidate` returning `true` unconditionally
- Actions redirecting to the same URL
- `useFetcher` in an `useEffect` without proper deps

### 6. SSR vs client rendering diff

```bash
# Fetch raw server HTML
curl -s http://localhost:3000/my-route | head -200

# Compare with client-rendered DOM in browser console
document.documentElement.outerHTML
```

### 7. Verbose build output

```bash
DEBUG="react-router:*" react-router build 2>&1 | tee build.log
```
