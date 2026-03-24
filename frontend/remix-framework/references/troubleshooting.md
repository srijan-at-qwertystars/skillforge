# Remix / React Router v7 Troubleshooting Guide

## Table of Contents

- [Hydration Mismatches](#hydration-mismatches)
- [Loader/Action Type Inference Issues](#loaderaction-type-inference-issues)
- [Cookie Session Gotchas](#cookie-session-gotchas)
- [CORS with Resource Routes](#cors-with-resource-routes)
- [Deployment-Specific Issues](#deployment-specific-issues)
  - [Cloudflare Workers Limitations](#cloudflare-workers-limitations)
  - [Vercel Edge Runtime Caveats](#vercel-edge-runtime-caveats)
- [Vite Plugin Conflicts](#vite-plugin-conflicts)
- [CSS Bundling Issues](#css-bundling-issues)
- [Form Resubmission Handling](#form-resubmission-handling)
- [Migration from CJS to ESM](#migration-from-cjs-to-esm)

---

## Hydration Mismatches

**Symptom:** Console warning "Hydration failed because the initial UI does not match what was rendered on the server" or flickering content on page load.

### Cause 1: Browser-Only APIs in Render

```tsx
// ❌ BAD — window is undefined on the server
export default function MyComponent() {
  const width = window.innerWidth; // 💥 crashes on server
  return <p>Width: {width}</p>;
}

// ✅ GOOD — guard with useEffect or check environment
export default function MyComponent() {
  const [width, setWidth] = useState<number | null>(null);

  useEffect(() => {
    setWidth(window.innerWidth);
    const handler = () => setWidth(window.innerWidth);
    window.addEventListener("resize", handler);
    return () => window.removeEventListener("resize", handler);
  }, []);

  return <p>Width: {width ?? "..."}</p>;
}
```

### Cause 2: Date/Time Differences

```tsx
// ❌ BAD — Date.now() differs between server and client
export default function Timer() {
  return <span>{new Date().toLocaleString()}</span>;
}

// ✅ GOOD — pass timestamp from loader
export async function loader() {
  return { timestamp: new Date().toISOString() };
}

export default function Timer({ loaderData }: Route.ComponentProps) {
  return <span>{new Date(loaderData.timestamp).toLocaleString()}</span>;
}
```

### Cause 3: CSS-in-JS Libraries

Some CSS-in-JS libraries generate different class names on server vs client. Solutions:
- Use the library's SSR API (e.g., `ServerStyleSheet` for styled-components)
- Switch to CSS Modules or Tailwind CSS (no hydration issues)
- Use the library's Remix-specific integration if available

### Cause 4: Browser Extensions

Browser extensions can modify the DOM before React hydrates. This is usually a false positive. Suppress with:

```tsx
// Only in development — don't ship this
<html suppressHydrationWarning>
```

### Cause 5: Conditional Rendering Based on typeof window

```tsx
// ❌ BAD — mismatch between server (false) and client (true)
{typeof window !== "undefined" && <ClientOnlyWidget />}

// ✅ GOOD — use useEffect-based state
function ClientOnly({ children }: { children: React.ReactNode }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  return mounted ? <>{children}</> : null;
}
```

---

## Loader/Action Type Inference Issues

### Problem: Types Not Generated

```
Error: Cannot find module './+types/my-route'
```

**Solution:** Run the type generator:

```bash
npx react-router typegen        # one-shot
npx react-router typegen --watch # continuous
```

Ensure `react-router.config.ts` exists with `appDirectory` set.

### Problem: loaderData is `unknown`

Ensure you're using the generated `Route` types, not manual types:

```tsx
// ❌ BAD — manual types, won't infer loader return
import type { LoaderFunctionArgs } from "react-router";
export async function loader({ request }: LoaderFunctionArgs) { ... }

// ✅ GOOD — auto-generated types with full inference
import type { Route } from "./+types/my-route";
export async function loader({ request }: Route.LoaderArgs) { ... }

export default function MyPage({ loaderData }: Route.ComponentProps) {
  // loaderData is fully typed from loader return value
}
```

### Problem: Types Stale After Route File Changes

The `+types/` directory is auto-generated. If types are stale:

1. Delete `.react-router/types/` directory
2. Re-run `npx react-router typegen`
3. Restart your IDE's TypeScript server (VS Code: Cmd+Shift+P → "TypeScript: Restart TS Server")

### Problem: Circular Type References

If a loader imports types that depend on loader output:

```tsx
// ❌ Circular: type depends on loader, loader uses type
import type { Route } from "./+types/my-route";
type MyData = Route.ComponentProps["loaderData"];
export async function loader(): Promise<MyData> { ... } // Circular!

// ✅ Define the type independently
interface MyData { users: User[]; total: number; }
export async function loader({ request }: Route.LoaderArgs): Promise<MyData> { ... }
```

---

## Cookie Session Gotchas

### Problem: Session Not Persisting

**Cause:** Missing `Set-Cookie` header in the response.

```tsx
// ❌ BAD — session changes are not committed
export async function action({ request }: Route.ActionArgs) {
  const session = await getSession(request.headers.get("Cookie"));
  session.set("userId", userId);
  return redirect("/dashboard"); // Set-Cookie header missing!
}

// ✅ GOOD — commit the session
export async function action({ request }: Route.ActionArgs) {
  const session = await getSession(request.headers.get("Cookie"));
  session.set("userId", userId);
  return redirect("/dashboard", {
    headers: { "Set-Cookie": await commitSession(session) },
  });
}
```

### Problem: "Cookie too large" Error

Cookie storage has a 4KB limit per cookie. Solutions:

1. Store minimal data in the cookie (just user ID), fetch the rest in loaders
2. Use `createSessionStorage` with a database backend instead of cookies
3. Split data across multiple cookies (not recommended)

### Problem: Session Lost After Deploy

**Cause:** `SESSION_SECRET` environment variable changed or missing. Use a stable secret across deployments:

```bash
# Generate a stable secret
openssl rand -hex 32
# Set it as an environment variable in your hosting platform
```

### Problem: Flash Messages Not Showing

```tsx
// ❌ BAD — flash is set but session isn't committed in the loader
export async function loader({ request }: Route.LoaderArgs) {
  const session = await getSession(request.headers.get("Cookie"));
  const message = session.get("flash");
  return { message }; // Session not committed, flash persists!
}

// ✅ GOOD — commit session to clear the flash
export async function loader({ request }: Route.LoaderArgs) {
  const session = await getSession(request.headers.get("Cookie"));
  const message = session.get("flash");
  return data({ message }, {
    headers: { "Set-Cookie": await commitSession(session) },
  });
}
```

### Problem: Cookies Not Sent in Development (HTTPS)

When `secure: true` is set, cookies won't be sent over HTTP in local development:

```tsx
const sessionStorage = createCookieSessionStorage({
  cookie: {
    secure: process.env.NODE_ENV === "production", // false in dev
    // ...
  },
});
```

---

## CORS with Resource Routes

### Problem: CORS Errors When Calling Resource Routes from External Clients

Resource routes don't automatically set CORS headers. Add them explicitly:

```tsx
// app/routes/api.data.ts
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

export async function loader({ request }: Route.LoaderArgs) {
  // Handle preflight
  if (request.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }

  const data = await getData();
  return Response.json(data, { headers: CORS_HEADERS });
}

export async function action({ request }: Route.ActionArgs) {
  if (request.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }

  const result = await processData(await request.json());
  return Response.json(result, { headers: CORS_HEADERS });
}
```

### Reusable CORS Helper

```tsx
// app/lib/cors.server.ts
export function corsHeaders(origin?: string): HeadersInit {
  const allowedOrigins = process.env.ALLOWED_ORIGINS?.split(",") ?? [];
  const isAllowed = !origin || allowedOrigins.includes(origin) || allowedOrigins.includes("*");

  return {
    "Access-Control-Allow-Origin": isAllowed ? (origin ?? "*") : "",
    "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
  };
}

// Usage in route
import { corsHeaders } from "~/lib/cors.server";

export async function loader({ request }: Route.LoaderArgs) {
  const origin = request.headers.get("Origin") ?? undefined;
  return Response.json(await getData(), { headers: corsHeaders(origin) });
}
```

---

## Deployment-Specific Issues

### Cloudflare Workers Limitations

**Problem: Node.js APIs Not Available**

Cloudflare Workers use a V8-based runtime, not Node.js. Many Node.js APIs are unavailable:

```tsx
// ❌ These don't work on Cloudflare Workers
import fs from "fs";
import path from "path";
import crypto from "crypto";           // Partial support
import { Buffer } from "buffer";       // Limited

// ✅ Use Web APIs instead
const hash = await crypto.subtle.digest("SHA-256", data);
const encoded = btoa(string);
const response = await fetch(url);
```

**Problem: Bundle Size Limits**

Workers have a 1MB compressed / 10MB uncompressed limit. Solutions:
- Use tree-shaking-friendly libraries
- Lazy-load heavy dependencies
- Move heavy processing to Durable Objects or external APIs
- Check bundle size: `wrangler deploy --dry-run`

**Problem: No File System**

Workers have no filesystem. Use KV, R2, or D1 for storage:

```tsx
export async function loader({ context }: Route.LoaderArgs) {
  const { env } = context;
  const value = await env.MY_KV.get("key");
  return { value };
}
```

**Problem: Streaming Limitations**

Cloudflare Workers support streaming but with caveats:
- Response body must be consumed or canceled, not abandoned
- Large streaming responses may hit CPU time limits
- Use `waitUntil` for background processing after response

### Vercel Edge Runtime Caveats

**Problem: Edge Runtime Module Restrictions**

Vercel Edge runtime doesn't support all Node.js modules:

```tsx
// ❌ Not available in Edge runtime
import { readFile } from "fs/promises";

// ✅ Use fetch for remote resources
const data = await fetch("https://api.example.com/data").then((r) => r.json());
```

**Problem: Cold Start Timeouts**

Edge functions have a 25-second execution limit. For long-running tasks:
- Use Vercel Serverless Functions (not Edge) for heavy processing
- Stream responses to avoid timeout
- Offload to background jobs via Vercel Cron or external queues

**Problem: Environment Variables in Edge**

```tsx
// ❌ process.env may not be available at the edge
const secret = process.env.API_KEY;

// ✅ Use Vercel's edge config or ensure env vars are configured for edge
// In vercel.json or project settings, mark variables as available to Edge
```

---

## Vite Plugin Conflicts

### Problem: Plugin Ordering Issues

The Remix/React Router Vite plugin must be the first plugin:

```tsx
// ❌ BAD — other plugins before reactRouter
export default defineConfig({
  plugins: [somePlugin(), reactRouter(), tsconfigPaths()],
});

// ✅ GOOD — reactRouter first
export default defineConfig({
  plugins: [reactRouter(), tsconfigPaths(), somePlugin()],
});
```

### Problem: Tailwind CSS v4 + PostCSS Conflicts

```tsx
// ❌ If using Tailwind CSS v4 with Vite plugin, don't also use PostCSS
// tailwind.config.ts AND postcss.config.ts will conflict

// ✅ Choose one approach:
// Option A: Vite plugin (Tailwind v4)
import tailwindcss from "@tailwindcss/vite";
export default defineConfig({
  plugins: [reactRouter(), tailwindcss()],
});

// Option B: PostCSS (Tailwind v3)
// postcss.config.js — no Vite plugin needed
```

### Problem: MDX Plugin Compatibility

```tsx
import mdx from "@mdx-js/rollup";
import { reactRouter } from "@react-router/dev/vite";

export default defineConfig({
  plugins: [
    reactRouter(),
    mdx({
      remarkPlugins: [],
      rehypePlugins: [],
    }),
  ],
});
```

Note: Some MDX plugins may need to be configured to work with the Vite SSR build. Test both dev and production builds.

### Problem: HMR Not Working

If Hot Module Replacement stops working:

1. Clear the Vite cache: `rm -rf node_modules/.vite`
2. Ensure no conflicting HMR plugins
3. Check that `reactRouter()` plugin is first
4. Verify no custom `server.hmr` config conflicts

---

## CSS Bundling Issues

### Problem: Styles Not Applied in Production

**Cause:** CSS imported in server-only files isn't bundled for the client.

```tsx
// ❌ BAD — CSS in .server.ts files won't be in the client bundle
// app/routes/page.server.ts
import "./styles.css";

// ✅ GOOD — import CSS in the route component file
// app/routes/page.tsx
import "./styles.css";
```

### Problem: CSS Module Class Names Differ Between SSR and Client

Ensure consistent CSS Module config in Vite:

```tsx
export default defineConfig({
  css: {
    modules: {
      localsConvention: "camelCase",
      generateScopedName: "[name]__[local]__[hash:base64:5]",
    },
  },
});
```

### Problem: Global CSS Order Inconsistency

CSS import order matters. Use the `links` export for deterministic ordering:

```tsx
export function links(): Route.LinkDescriptors {
  return [
    { rel: "stylesheet", href: "/styles/reset.css" },
    { rel: "stylesheet", href: "/styles/global.css" },
    { rel: "stylesheet", href: "/styles/page-specific.css" },
  ];
}
```

### Problem: Tailwind Classes Not Purged

Check `content` paths in Tailwind config:

```ts
// tailwind.config.ts
export default {
  content: ["./app/**/{**,.client,.server}/**/*.{js,jsx,ts,tsx}"],
};
```

---

## Form Resubmission Handling

### Problem: Browser "Confirm Form Resubmission" Dialog

After a POST action, refreshing the page triggers resubmission. Use the POST/Redirect/GET pattern:

```tsx
// ❌ BAD — returns data after POST (resubmission on refresh)
export async function action({ request }: Route.ActionArgs) {
  const data = await request.formData();
  const result = await createItem(data);
  return { success: true, item: result };
}

// ✅ GOOD — redirect after successful POST
export async function action({ request }: Route.ActionArgs) {
  const data = await request.formData();
  const result = await createItem(data);
  return redirect(`/items/${result.id}`);
}
```

### Problem: Double Submission Prevention

```tsx
export default function CreateForm({ actionData }: Route.ComponentProps) {
  const navigation = useNavigation();
  const isSubmitting = navigation.state === "submitting";

  return (
    <Form method="post">
      {/* form fields */}
      <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? "Submitting..." : "Submit"}
      </button>
    </Form>
  );
}
```

### Problem: Multiple Actions in One Route

Use a hidden field or button name to distinguish actions:

```tsx
export async function action({ request }: Route.ActionArgs) {
  const formData = await request.formData();
  const intent = formData.get("intent");

  switch (intent) {
    case "create":
      return handleCreate(formData);
    case "delete":
      return handleDelete(formData);
    case "update":
      return handleUpdate(formData);
    default:
      return data({ error: "Invalid intent" }, { status: 400 });
  }
}

// In component
<Form method="post">
  <button type="submit" name="intent" value="create">Create</button>
  <button type="submit" name="intent" value="delete">Delete</button>
</Form>
```

---

## Migration from CJS to ESM

### Problem: `require` is Not Defined in ESM

```json
// package.json — set type to module
{
  "type": "module"
}
```

Then update all `require` calls:

```tsx
// ❌ CJS
const express = require("express");
const { json } = require("@remix-run/node");
module.exports = { loader };

// ✅ ESM
import express from "express";
import { json } from "react-router";
export { loader };
```

### Problem: __dirname / __filename Not Available in ESM

```tsx
// ❌ CJS globals don't exist in ESM
const configPath = path.join(__dirname, "config.json");

// ✅ ESM equivalent
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const configPath = join(__dirname, "config.json");
```

### Problem: JSON Imports

```tsx
// ❌ May not work without assertion
import data from "./data.json";

// ✅ Use import assertion (or type for newer runtimes)
import data from "./data.json" with { type: "json" };

// ✅ Alternative: read and parse
import { readFile } from "fs/promises";
const data = JSON.parse(await readFile("./data.json", "utf-8"));
```

### Problem: Dynamic Imports of CJS Modules

Some dependencies are CJS-only. Vite handles this automatically in most cases, but if you encounter issues:

```tsx
// ✅ Vite config — explicitly optimize CJS deps
export default defineConfig({
  optimizeDeps: {
    include: ["some-cjs-package"],
  },
  ssr: {
    noExternal: ["some-cjs-package"],
  },
});
```

### Problem: tsconfig.json Module Settings

```json
{
  "compilerOptions": {
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "target": "ES2022",
    "verbatimModuleSyntax": true
  }
}
```

Key: `"moduleResolution": "Bundler"` is required for Vite-based Remix/React Router v7 projects. `"Node"` or `"Node16"` will cause import resolution issues.
