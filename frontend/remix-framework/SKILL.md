---
name: remix-framework
description: >
  Build full-stack web apps with Remix (v2+) and React Router v7 framework mode.
  Use when: building Remix applications, using loaders/actions for data loading and mutations,
  implementing nested routing with Outlet, progressive enhancement with Form,
  streaming with defer/Await, resource routes for API endpoints, error boundaries,
  migrating Remix v2 to React Router v7, deploying to Vercel/Cloudflare/Node.
  Do NOT use for: Next.js or Nuxt projects, plain React SPA without server rendering,
  Vue/Svelte/Astro frameworks, Express-only APIs without Remix routing,
  static site generators, or React Native applications.
---

# Remix / React Router v7 Framework Skill

Remix v2 has merged into React Router v7. New projects use React Router v7 in framework mode. Existing Remix v2 apps should migrate. All guidance below applies to both.

## Project Setup with Vite

```bash
npx create-react-router@latest my-app
cd my-app && npm install && npm run dev
```

Configure `vite.config.ts`:

```ts
import { reactRouter } from "@react-router/dev/vite";
import { defineConfig } from "vite";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig({
  plugins: [reactRouter(), tsconfigPaths()],
});
```

Configure `react-router.config.ts`:

```ts
import type { Config } from "@react-router/dev/config";
export default { appDirectory: "app", ssr: true } satisfies Config;
```

Package scripts:

```json
{
  "dev": "react-router dev",
  "build": "react-router build",
  "start": "react-router-serve build/server/index.js",
  "typecheck": "react-router typegen && tsc"
}
```

Run `react-router typegen --watch` during development for continuous type generation.

## Route Modules

Every route file can export `loader`, `action`, `default` (component), `meta`, `links`, `headers`, and `ErrorBoundary`:

```ts
// app/routes/posts.$postId.tsx
import type { Route } from "./+types/posts.$postId";

export async function loader({ params, request }: Route.LoaderArgs) {
  const post = await db.post.findUnique({ where: { id: params.postId } });
  if (!post) throw new Response("Not Found", { status: 404 });
  return { post };
}

export async function action({ params, request }: Route.ActionArgs) {
  const formData = await request.formData();
  await db.post.update({ where: { id: params.postId }, data: { title: formData.get("title") as string } });
  return { success: true };
}

export function meta({ data }: Route.MetaArgs) {
  return [{ title: data.post.title }, { name: "description", content: data.post.excerpt }];
}

export function links(): Route.LinkDescriptors {
  return [{ rel: "stylesheet", href: "/styles/post.css" }];
}

export function headers({ loaderHeaders }: Route.HeadersArgs) {
  return { "Cache-Control": loaderHeaders.get("Cache-Control") ?? "max-age=300" };
}

export default function Post({ loaderData }: Route.ComponentProps) {
  return (
    <article>
      <h1>{loaderData.post.title}</h1>
      <p>{loaderData.post.content}</p>
    </article>
  );
}
```

## Routing Configuration

Define routes in `app/routes.ts`:

```ts
import { type RouteConfig, route, index, layout, prefix } from "@react-router/dev/routes";

export default [
  index("routes/home.tsx"),
  route("about", "routes/about.tsx"),
  ...prefix("blog", [
    index("routes/blog/index.tsx"),
    route(":slug", "routes/blog/post.tsx"),
  ]),
  layout("routes/dashboard/layout.tsx", [
    index("routes/dashboard/index.tsx"),
    route("settings", "routes/dashboard/settings.tsx"),
  ]),
] satisfies RouteConfig;
```

Or use convention-based flat routes:

```ts
import { flatRoutes } from "@react-router/fs-routes";
export default flatRoutes() satisfies RouteConfig;
```

Flat routes naming: `_index.tsx` → index, `about.tsx` → `/about`, `blog.$slug.tsx` → `/blog/:slug`, `blog_.tsx` → pathless layout, `$.tsx` → splat/catch-all, `_auth.login.tsx` → `/login` under pathless `_auth` layout.

## Nested Routing and Outlet

Parent layouts render child routes via `<Outlet>`:

```tsx
// app/routes/dashboard/layout.tsx
import { Outlet, NavLink } from "react-router";

export default function DashboardLayout() {
  return (
    <div className="dashboard">
      <nav>
        <NavLink to="/dashboard" end>Overview</NavLink>
        <NavLink to="/dashboard/settings">Settings</NavLink>
      </nav>
      <main><Outlet /></main>
    </div>
  );
}
```

Parent and child loaders run in parallel. Use `useMatches()` to access parent data. Use `useRouteLoaderData("route-id")` for cross-route data access.

## Data Loading with Loaders

Loaders run server-side for SSR and on client navigation. Return plain objects:

```tsx
export async function loader({ request }: Route.LoaderArgs) {
  const url = new URL(request.url);
  const q = url.searchParams.get("q") ?? "";
  const results = await searchProducts(q);
  return { results, q };
}

export default function Search({ loaderData }: Route.ComponentProps) {
  const { results, q } = loaderData;
  return (
    <Form method="get">
      <input type="search" name="q" defaultValue={q} />
      <button type="submit">Search</button>
    </Form>
  );
}
```

Type safety comes from auto-generated `Route.ComponentProps` via `react-router typegen`. The `loaderData` property is fully typed from your loader return value.

## Form Handling with Actions

Use `<Form>` for progressive enhancement — forms work without JavaScript:

```tsx
import { Form, useNavigation, redirect, data } from "react-router";

export async function action({ request }: Route.ActionArgs) {
  const formData = await request.formData();
  const email = formData.get("email") as string;
  const password = formData.get("password") as string;
  const errors: Record<string, string> = {};
  if (!email) errors.email = "Email required";
  if (password.length < 8) errors.password = "Min 8 chars";
  if (Object.keys(errors).length) return data({ errors }, { status: 400 });
  const user = await createUser({ email, password });
  return redirect(`/users/${user.id}`);
}

export default function Signup({ actionData }: Route.ComponentProps) {
  const navigation = useNavigation();
  const isSubmitting = navigation.state === "submitting";
  return (
    <Form method="post">
      <input name="email" type="email" required />
      {actionData?.errors?.email && <span>{actionData.errors.email}</span>}
      <input name="password" type="password" required />
      {actionData?.errors?.password && <span>{actionData.errors.password}</span>}
      <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? "Creating..." : "Sign Up"}
      </button>
    </Form>
  );
}
```

Use `useFetcher()` for mutations without navigation (inline edits, toggles):

```tsx
function LikeButton({ postId }: { postId: string }) {
  const fetcher = useFetcher();
  return (
    <fetcher.Form method="post" action={`/posts/${postId}/like`}>
      <button disabled={fetcher.state !== "idle"}>♥</button>
    </fetcher.Form>
  );
}
```

## Error Boundaries

Export `ErrorBoundary` from any route. Catches loader, action, and render errors:

```tsx
import { isRouteErrorResponse, useRouteError } from "react-router";

export function ErrorBoundary() {
  const error = useRouteError();
  if (isRouteErrorResponse(error)) {
    return <div><h1>{error.status} {error.statusText}</h1><p>{error.data}</p></div>;
  }
  return <div><h1>Error</h1><p>{error instanceof Error ? error.message : "Unknown error"}</p></div>;
}
```

Place a root `ErrorBoundary` in `app/root.tsx` as last-resort catch. Each nested route can have its own — errors bubble up to the nearest ancestor boundary, preserving surrounding layout.

Throw `Response` for expected errors (404, 403). Throw `Error` for unexpected failures:

```ts
export async function loader({ params }: Route.LoaderArgs) {
  const user = await getUser(params.id);
  if (!user) throw new Response("Not found", { status: 404 });
  return { user };
}
```

## Streaming with defer and Await

Return promises from loaders without awaiting to stream non-critical data:

```tsx
import { Suspense } from "react";
import { Await } from "react-router";

export async function loader({ params }: Route.LoaderArgs) {
  const product = await getProduct(params.id);  // critical — await
  const reviews = getReviews(params.id);         // non-critical — don't await
  return { product, reviews };
}

export default function Product({ loaderData }: Route.ComponentProps) {
  return (
    <div>
      <h1>{loaderData.product.name}</h1>
      <Suspense fallback={<p>Loading reviews...</p>}>
        <Await resolve={loaderData.reviews}>
          {(reviews) => <ul>{reviews.map((r) => <li key={r.id}>{r.text}</li>)}</ul>}
        </Await>
      </Suspense>
    </div>
  );
}
```

Initiate all deferred promises before any `await` to maximize parallelism. Add `key` prop to `<Suspense>` when re-rendering with different params. Streaming requires a compatible runtime — some serverless platforms buffer responses.

## Resource Routes

Routes without a default component export serve as API endpoints, file downloads, or webhooks:

```ts
// app/routes/api.users.ts — JSON API
export async function loader({ request }: Route.LoaderArgs) {
  const q = new URL(request.url).searchParams.get("q") ?? "";
  return Response.json(await searchUsers(q));
}

export async function action({ request }: Route.ActionArgs) {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  return Response.json(await createUser(await request.json()), { status: 201 });
}
```

```ts
// app/routes/reports.$id[.csv].ts — File download
export async function loader({ params }: Route.LoaderArgs) {
  return new Response(await generateReport(params.id), {
    headers: {
      "Content-Type": "text/csv",
      "Content-Disposition": `attachment; filename="report-${params.id}.csv"`,
    },
  });
}
```

```ts
// app/routes/webhooks.stripe.ts
export async function action({ request }: Route.ActionArgs) {
  const payload = await request.text();
  const sig = request.headers.get("stripe-signature")!;
  await handleStripeEvent(stripe.webhooks.constructEvent(payload, sig, WEBHOOK_SECRET));
  return new Response("ok", { status: 200 });
}
```

## Authentication Patterns

Use cookie-based sessions with `createCookieSessionStorage`:

```ts
// app/services/session.server.ts
import { createCookieSessionStorage, redirect } from "react-router";

const sessionStorage = createCookieSessionStorage({
  cookie: {
    name: "__session", httpOnly: true, sameSite: "lax", maxAge: 60 * 60 * 24 * 30,
    secure: process.env.NODE_ENV === "production",
    secrets: [process.env.SESSION_SECRET!],
  },
});

export async function requireUser(request: Request) {
  const session = await sessionStorage.getSession(request.headers.get("Cookie"));
  const userId = session.get("userId");
  if (!userId) throw redirect("/login");
  return await getUser(userId) ?? (() => { throw redirect("/login"); })();
}

export async function createUserSession(userId: string, redirectTo: string) {
  const session = await sessionStorage.getSession();
  session.set("userId", userId);
  return redirect(redirectTo, {
    headers: { "Set-Cookie": await sessionStorage.commitSession(session) },
  });
}

export async function destroySession(request: Request) {
  const session = await sessionStorage.getSession(request.headers.get("Cookie"));
  return redirect("/login", {
    headers: { "Set-Cookie": await sessionStorage.destroySession(session) },
  });
}
```

Protect routes by calling `requireUser` in loaders. For API resource routes, authenticate via Authorization header with Bearer tokens instead of cookies.

## Deployment

### Node.js (default)

```bash
npm run build && NODE_ENV=production npm start
```

Uses `@react-router/serve` (wraps Express). For custom servers, use `createRequestHandler` from `@react-router/express`.

### Vercel

```ts
// vite.config.ts
import { vercelPreset } from "@vercel/react-router/vite";
export default defineConfig({
  plugins: [reactRouter({ presets: [vercelPreset()] })],
});
```

Deploy with `vercel` CLI. Streaming and serverless functions work automatically.

### Cloudflare Workers/Pages

```ts
// worker.ts
import { createRequestHandler } from "@react-router/cloudflare";
export default {
  async fetch(request, env, ctx) {
    return createRequestHandler(() => import("./build/server/index.js"), "production")(request, { env, ctx });
  },
};
```

Deploy with `wrangler deploy`. Access KV/D1/R2 bindings via `context.env` in loaders.

## Migration: Remix v2 → React Router v7

1. Enable all future flags in Remix v2 config (`v3_fetcherPersist`, `v3_relativeSplatPath`, `v3_throwAbortReason`, `v3_routeConfig`, `v3_singleFetch`, `v3_lazyRouteDiscovery`).
2. Run codemod: `npx codemod remix/2/react-router/upgrade`
3. Replace dependencies: `@remix-run/react` → `react-router`, `@remix-run/node` → `@react-router/node`, `@remix-run/serve` → `@react-router/serve`, `@remix-run/dev` → `@react-router/dev`.
4. Update `vite.config.ts`: `remix()` → `reactRouter()`.
5. Create `app/routes.ts` with `flatRoutes()` from `@react-router/fs-routes`.
6. Update all imports from `@remix-run/*` to `react-router`.
7. Run `react-router typegen` and fix type errors — `Route.*` types replace `LoaderFunctionArgs` etc.

Breaking changes: `json()` removed (return plain objects), `defer()` simplified (return promises directly), types auto-generated from `./+types/`, single fetch default (turbo-stream encoding).

## Key Conventions

- Place server-only code in `.server.ts` files — never bundled for client.
- Use `<Form>` over `<form>` for progressive enhancement with client-side navigation.
- Prefer `redirect()` from actions after successful mutations (POST/redirect/GET).
- Use `shouldRevalidate` export to control which loaders re-run after mutations.
- Use `useNavigation()` for pending UI, `useNavigate()` for programmatic navigation.
- Use `invariant()` or explicit null checks before accessing params.
