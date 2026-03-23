# Migration Guide — Remix v1 → v2 → React Router v7

> Step-by-step migration paths with breaking changes, codemods, and gotchas
> at each stage. Covers file conventions, deprecated APIs, and adapter changes.

## Table of Contents

- [Overview: The Remix → React Router v7 Journey](#overview-the-remix--react-router-v7-journey)
- [Phase 1: Remix v1 → Remix v2](#phase-1-remix-v1--remix-v2)
  - [Future Flags Strategy](#future-flags-strategy)
  - [File Convention Changes (v1 Nested → v2 Flat)](#file-convention-changes-v1-nested--v2-flat)
  - [API Breaking Changes in v2](#api-breaking-changes-in-v2)
- [Phase 2: Remix v2 → React Router v7](#phase-2-remix-v2--react-router-v7)
  - [Running the Codemod](#running-the-codemod)
  - [Package Mapping](#package-mapping)
  - [API Changes](#api-changes)
  - [Config Migration](#config-migration)
  - [Route File Changes](#route-file-changes)
  - [Adapter Changes](#adapter-changes)
- [Post-Migration Checklist](#post-migration-checklist)
- [Common Migration Errors](#common-migration-errors)

---

## Overview: The Remix → React Router v7 Journey

```
Remix v1  ──(future flags)──▶  Remix v2  ──(codemod)──▶  React Router v7
                                                          (framework mode)
```

- **Remix v1 → v2**: Incremental via future flags. Enable flags one at a time,
  fix code, test, repeat. The v2 upgrade should be trivial if all flags were
  already enabled.
- **Remix v2 → React Router v7**: Automated via codemod. This is primarily a
  package rename + API simplification. React Router v7 IS Remix v3 under a
  unified name.

---

## Phase 1: Remix v1 → Remix v2

### Future Flags Strategy

Enable each flag in `remix.config.js`, fix resulting issues, then enable the next.
Order doesn't matter, but this sequence minimizes churn:

```js
// remix.config.js (Remix v1)
module.exports = {
  future: {
    // 1. Start with non-breaking behavioral changes
    v2_normalizeFormMethod: true,   // formMethod is uppercase: "POST" not "post"
    v2_fetcherPersist: true,        // fetchers persist until idle after unmount

    // 2. Route convention (biggest change)
    v2_routeConvention: true,       // flat file routes (dot notation)

    // 3. Error handling
    v2_errorBoundary: true,         // single ErrorBoundary replaces CatchBoundary

    // 4. Meta
    v2_meta: true,                  // new meta function signature

    // 5. Other
    v2_headers: true,               // nested route headers behavior
    v2_dev: true,                   // new dev server
  },
};
```

### File Convention Changes (v1 Nested → v2 Flat)

This is the largest structural change. Remix v1 used nested directories;
v2 uses flat files with dot-separated segments.

#### Side-by-side comparison

```
v1 (Nested Directories)             v2 (Flat Files)
─────────────────────               ────────────────
routes/                             routes/
  index.tsx                           _index.tsx
  about.tsx                           about.tsx
  blog/                               blog.tsx          (layout)
    index.tsx                         blog._index.tsx
    $slug.tsx                         blog.$slug.tsx
  dashboard/                          dashboard.tsx     (layout)
    index.tsx                         dashboard._index.tsx
    settings.tsx                      dashboard.settings.tsx
    settings/
      profile.tsx                     dashboard.settings.profile.tsx
  __auth/                            _auth.tsx          (pathless layout)
    login.tsx                         _auth.login.tsx
    register.tsx                      _auth.register.tsx
```

#### Key rules for v2 flat routes

| Pattern | Example File | URL | Notes |
|---------|-------------|-----|-------|
| Index route | `_index.tsx` | `/` | Underscore prefix for index |
| Static segment | `about.tsx` | `/about` | Simple |
| Dynamic param | `blog.$slug.tsx` | `/blog/:slug` | `$` prefix for params |
| Nested route | `blog.$slug.tsx` | `/blog/:slug` | Dots = path separators |
| Layout route | `dashboard.tsx` | `/dashboard` | Must render `<Outlet />` |
| Pathless layout | `_auth.tsx` | (no URL segment) | Underscore prefix |
| Splat/catch-all | `docs.$.tsx` | `/docs/*` | `$` alone = splat |
| Route group | `(marketing).about.tsx` | `/about` | Parens for org only |

#### Keeping v1 convention temporarily

If you can't migrate all routes at once:
```bash
npm install @remix-run/v1-route-convention
```
```js
// remix.config.js
const { createRoutesFromFolders } = require("@remix-run/v1-route-convention");
module.exports = {
  future: { v2_routeConvention: true },
  routes: (defineRoutes) => createRoutesFromFolders(defineRoutes),
};
```

### API Breaking Changes in v2

#### ErrorBoundary replaces CatchBoundary

```tsx
// ❌ v1: Two separate boundaries
export function CatchBoundary() {
  const caught = useCatch();
  return <p>{caught.status}: {caught.data}</p>;
}
export function ErrorBoundary({ error }: { error: Error }) {
  return <p>Error: {error.message}</p>;
}

// ✅ v2: Single unified ErrorBoundary
export function ErrorBoundary() {
  const error = useRouteError();
  if (isRouteErrorResponse(error)) {
    return <p>{error.status}: {error.data}</p>;
  }
  return <p>Error: {error instanceof Error ? error.message : "Unknown"}</p>;
}
```

#### Meta function signature

```tsx
// ❌ v1 meta (returns object)
export const meta: MetaFunction = () => ({
  title: "My Page",
  description: "A page",
});

// ✅ v2 meta (returns array of descriptors)
export const meta: V2_MetaFunction = () => [
  { title: "My Page" },
  { name: "description", content: "A page" },
];
```

#### formMethod normalization

```tsx
// v1: formMethod is lowercase — "post", "delete"
// v2: formMethod is uppercase — "POST", "DELETE"
// Update any code that checks: if (formMethod === "post") → "POST"
```

#### Headers function

```tsx
// v2: headers function receives both parent and child headers
export function headers({ loaderHeaders, parentHeaders }: Route.HeadersArgs) {
  return {
    "Cache-Control": loaderHeaders.get("Cache-Control") ?? "max-age=300",
  };
}
```

---

## Phase 2: Remix v2 → React Router v7

### Prerequisites

1. All future flags enabled in Remix v2 and app works correctly.
2. Node.js v20+ installed.
3. All code committed (codemod modifies files in place).

### Running the Codemod

```bash
npx codemod remix/2/react-router/upgrade
```

The codemod handles:
- ✅ `package.json` dependency swaps
- ✅ Import path rewrites (`@remix-run/*` → `react-router` / `@react-router/*`)
- ✅ `vite.config.ts` plugin name change
- ✅ `tsconfig.json` updates
- ✅ Entry file updates (`entry.server.tsx`, `entry.client.tsx`)
- ✅ Script name changes in `package.json`

The codemod does NOT handle:
- ❌ `json()` / `defer()` removal (returns plain objects now)
- ❌ `useLoaderData()` → component props migration
- ❌ Custom server adapter code
- ❌ `routes.ts` creation (if not using file-based routing)

### Package Mapping

| Remix v2 Package | React Router v7 Package | Notes |
|------------------|------------------------|-------|
| `@remix-run/node` | `react-router` | Unified package |
| `@remix-run/react` | `react-router` | Unified package |
| `@remix-run/serve` | `@react-router/serve` | Server runtime |
| `@remix-run/dev` | `@react-router/dev` | Dev tooling |
| `@remix-run/express` | `@react-router/express` | Express adapter |
| `@remix-run/cloudflare` | `@react-router/cloudflare` | CF adapter |
| `@remix-run/architect` | `@react-router/architect` | AWS adapter |
| `@remix-run/testing` | (use `createRoutesStub`) | Built into react-router |
| `@remix-run/css-bundle` | (removed) | Vite handles CSS |

### API Changes

#### `json()` removed

```tsx
// ❌ Remix v2
import { json } from "@remix-run/node";
export async function loader() {
  return json({ user }, { status: 200 });
}

// ✅ React Router v7
export async function loader() {
  return { user };
  // For custom status/headers:
  // return Response.json({ user }, { status: 200 });
}
```

#### `defer()` removed

```tsx
// ❌ Remix v2
import { defer } from "@remix-run/node";
export async function loader() {
  return defer({
    critical: await getCritical(),
    lazy: getLazy(), // promise
  });
}

// ✅ React Router v7 — just return promises directly
export async function loader() {
  return {
    critical: await getCritical(),
    lazy: getLazy(), // un-awaited promise streams automatically
  };
}
```

#### Component data access

```tsx
// ❌ Remix v2
import { useLoaderData, useActionData } from "@remix-run/react";
export default function Page() {
  const data = useLoaderData<typeof loader>();
  const actionData = useActionData<typeof action>();
}

// ✅ React Router v7 (preferred)
export default function Page({ loaderData, actionData }: Route.ComponentProps) {
  // auto-typed, no hook needed
}
```

#### Vite config

```ts
// ❌ Remix v2
import { vitePlugin as remix } from "@remix-run/dev";
export default defineConfig({
  plugins: [remix({ future: { /* flags */ } })],
});

// ✅ React Router v7
import { reactRouter } from "@react-router/dev/vite";
export default defineConfig({
  plugins: [reactRouter()],
});
```

### Config Migration

```ts
// ❌ remix.config.js (Remix v2 with Vite already)
// This file is deleted — config moves into vite.config.ts and react-router.config.ts

// ✅ react-router.config.ts
import type { Config } from "@react-router/dev/config";
export default {
  ssr: true,
  // prerender: ["/", "/about"],  // optional static generation
} satisfies Config;
```

### Route File Changes

Create `app/routes.ts` (required in v7 framework mode):

```ts
// app/routes.ts
import { flatRoutes } from "@react-router/fs-routes";
import type { RouteConfig } from "@react-router/dev/routes";

export default flatRoutes() satisfies RouteConfig;
```

### Adapter Changes

#### Node.js

```diff
// package.json scripts
- "dev": "remix vite:dev",
+ "dev": "react-router dev",
- "build": "remix vite:build",
+ "build": "react-router build",
- "start": "remix-serve ./build/server/index.js",
+ "start": "react-router-serve ./build/server/index.js",
```

#### Cloudflare

```diff
- import { createRequestHandler } from "@remix-run/cloudflare";
+ import { createRequestHandler } from "react-router";
```

Bindings access remains: `context.cloudflare.env.MY_KV`.

#### Express / Custom Server

```diff
- import { createRequestHandler } from "@remix-run/express";
+ import { createRequestHandler } from "@react-router/express";
```

#### Vercel

```diff
// react-router.config.ts
- import { vercelPreset } from "@vercel/remix";
+ import { vercelPreset } from "@vercel/react-router/vite";
```

---

## Post-Migration Checklist

```
[ ] All `@remix-run/*` imports replaced with `react-router` / `@react-router/*`
[ ] `json()` calls removed — return plain objects
[ ] `defer()` calls removed — return un-awaited promises
[ ] `app/routes.ts` exists with route configuration
[ ] `vite.config.ts` uses `reactRouter()` plugin
[ ] `react-router.config.ts` created with SSR/prerender settings
[ ] `package.json` scripts updated (dev/build/start)
[ ] `react-router typegen` runs without errors
[ ] `tsc --noEmit` passes
[ ] All routes render correctly (SSR + client navigation)
[ ] Forms submit and revalidate properly
[ ] Error boundaries catch errors at correct levels
[ ] Streaming/deferred data resolves correctly
[ ] Auth flows (login/logout/session) work end-to-end
[ ] Deployment pipeline updated with new build commands
[ ] CI/CD scripts reference correct packages
```

---

## Common Migration Errors

### `Module '"react-router"' has no exported member 'json'`
`json()` is removed. Return plain objects from loaders/actions.

### `Cannot find module '@remix-run/react'`
Codemod didn't catch all imports. Search and replace manually:
```bash
grep -r "@remix-run/" app/ --include="*.ts" --include="*.tsx"
```

### `Property 'loaderData' does not exist on type '{}'`
Run `react-router typegen` to generate route types. Ensure `tsconfig.json`
includes `rootDirs: [".", ".react-router/types"]`.

### `Route module ... does not export a component`
In v7, if a route has `loader`/`action` but no default export AND no
`Component` export, it's treated as a resource route. Add `export default`
if it should render UI.

### `Headers is not defined` / `Request is not defined`
Ensure Node.js v20+ (has built-in Web API globals). For older Node versions,
install `undici` or use `@react-router/node`.

### Remix v1 `getCookie` / `setCookie` patterns broken
v2+ uses `getSession(request.headers.get("Cookie"))` pattern. Update all
cookie access to use session storage APIs.

### `flatRoutes is not a function`
Install the fs-routes package:
```bash
npm install @react-router/fs-routes
```

### Build works but pages 404 in production
Check that `app/routes.ts` correctly exports routes. Verify the build output
in `build/server/` contains the route modules.
