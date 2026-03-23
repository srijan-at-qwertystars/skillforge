---
name: remix-framework
description: >
  USE when building Remix apps, React Router v7 framework-mode apps, or migrating
  from Remix v1/v2 to React Router v7. TRIGGERS: create-remix, remix.config,
  react-router.config, @remix-run/*, @react-router/*, loader function, action
  function, useLoaderData, useActionData, useFetcher, remix vite, flatRoutes,
  ErrorBoundary in route modules, createCookieSessionStorage, entry.server,
  entry.client, root.tsx route module, nested routing with Outlet, progressive
  enhancement with Form component, defer/Await streaming, deployment adapters
  for Cloudflare/Vercel/Deno. DO NOT USE for plain React Router library-mode
  (no SSR, no loaders), Next.js, Gatsby, Astro, or generic React SPA projects
  without server-side data loading.
---

# Remix / React Router v7 Framework Skill

## Critical Context

Remix v2 merged into React Router v7. The framework formerly called "Remix" is now **React Router v7 in framework mode**. All `@remix-run/*` packages map to `react-router` or `@react-router/*`. New projects use `npx create-react-router@latest`. Existing Remix v2 projects migrate via `npx codemod remix/2/react-router/upgrade`.

## Project Setup

### New Project (React Router v7 Framework Mode)
```bash
npx create-react-router@latest my-app
cd my-app && npm install && npm run dev
```

### Vite Config
```ts
// vite.config.ts
import { reactRouter } from "@react-router/dev/vite";
import { defineConfig } from "vite";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig({
  plugins: [reactRouter(), tsconfigPaths()],
});
```

### React Router Config
```ts
// react-router.config.ts — set ssr: false for SPA mode
import type { Config } from "@react-router/dev/config";
export default { ssr: true } satisfies Config;
```

Scripts: `react-router dev`, `react-router build`, `react-router-serve ./build/server/index.js`, `react-router typegen && tsc`.

## Architecture

Core principle: **nested routes with colocated data loading**. Every route module can export `loader` (GET data), `action` (mutations), `default` (component), `ErrorBoundary`, `meta`, `links`, `headers`, and `handle`.

Data flows server→client. Loaders run on the server for initial SSR and on navigation. Actions run server-side on non-GET form submissions. After an action, all loaders on the page revalidate automatically.

```
Request → Match Routes → Run Loaders → Render Components → HTML Response
POST    → Match Routes → Run Action  → Revalidate Loaders → Render
```

## File-Based Routing

Define routes in `app/routes.ts`:
```ts
import type { RouteConfig } from "@react-router/dev/routes";
import { flatRoutes } from "@react-router/fs-routes";

export default flatRoutes() satisfies RouteConfig;
```

### File Naming Conventions
| File                          | URL                  | Notes                    |
|-------------------------------|----------------------|--------------------------|
| `routes/_index.tsx`           | `/`                  | Index route              |
| `routes/about.tsx`            | `/about`             | Static segment           |
| `routes/products.$id.tsx`     | `/products/:id`      | Dynamic param            |
| `routes/docs.$.tsx`           | `/docs/*`            | Splat/catch-all          |
| `routes/dashboard.tsx`        | `/dashboard`         | Layout route (has Outlet)|
| `routes/dashboard._index.tsx` | `/dashboard`         | Dashboard index          |
| `routes/dashboard.settings.tsx`| `/dashboard/settings`| Nested under dashboard   |
| `routes/_auth.tsx`            | N/A                  | Pathless layout          |
| `routes/_auth.login.tsx`      | `/login`             | Shares _auth layout      |

Layout routes render an `<Outlet />` for child routes. Pathless layouts (prefixed with `_`) group routes under a shared UI without adding a URL segment.

### Manual Route Config (Alternative)
```ts
// app/routes.ts
import { type RouteConfig, route, layout, index } from "@react-router/dev/routes";

export default [
  index("routes/home.tsx"),
  route("about", "routes/about.tsx"),
  layout("routes/dashboard-layout.tsx", [
    route("dashboard", "routes/dashboard.tsx"),
    route("dashboard/settings", "routes/settings.tsx"),
  ]),
] satisfies RouteConfig;
```

## Data Loading

### Loader (GET requests)
```tsx
// app/routes/products.$id.tsx
import type { Route } from "./+types/products.$id";

export async function loader({ params, request }: Route.LoaderArgs) {
  const product = await db.product.findUnique({ where: { id: params.id } });
  if (!product) throw new Response("Not Found", { status: 404 });
  return { product };
}

export default function ProductPage({ loaderData }: Route.ComponentProps) {
  const { product } = loaderData;
  return <h1>{product.name}</h1>;
}
```

In React Router v7, `loaderData` is passed as a prop to the component. The `useLoaderData()` hook also works for backward compatibility.

### Streaming with Suspense (replaces defer)
In v7, skip `defer()`. Return un-awaited promises directly; React Router streams them:
```tsx
export async function loader({ params }: Route.LoaderArgs) {
  const product = await db.product.findUnique({ where: { id: params.id } });
  const reviews = db.review.findMany({ where: { productId: params.id } }); // NOT awaited
  return { product, reviews };
}

export default function ProductPage({ loaderData }: Route.ComponentProps) {
  return (
    <>
      <h1>{loaderData.product.name}</h1>
      <Suspense fallback={<p>Loading reviews…</p>}>
        <Await resolve={loaderData.reviews}>
          {(reviews) => <ReviewList reviews={reviews} />}
        </Await>
      </Suspense>
    </>
  );
}
```

## Mutations

### Action (POST/PUT/DELETE)
```tsx
import { redirect } from "react-router";

export async function action({ request, params }: Route.ActionArgs) {
  const formData = await request.formData();
  const name = formData.get("name") as string;

  const errors: Record<string, string> = {};
  if (!name) errors.name = "Name is required";
  if (Object.keys(errors).length) return { errors };

  await db.product.update({ where: { id: params.id }, data: { name } });
  return redirect(`/products/${params.id}`);
}

export default function EditProduct({ loaderData, actionData }: Route.ComponentProps) {
  return (
    <Form method="post">
      <input name="name" defaultValue={loaderData.product.name} />
      {actionData?.errors?.name && <p className="error">{actionData.errors.name}</p>}
      <button type="submit">Save</button>
    </Form>
  );
}
```

### useFetcher (Non-navigation mutations)
Use `useFetcher` for mutations that should not trigger a full navigation (e.g., like buttons, inline edits, add-to-cart):
```tsx
import { useFetcher } from "react-router";

function LikeButton({ postId }: { postId: string }) {
  const fetcher = useFetcher();
  const isSubmitting = fetcher.state === "submitting";

  return (
    <fetcher.Form method="post" action={`/posts/${postId}/like`}>
      <button disabled={isSubmitting}>
        {isSubmitting ? "Liking…" : "♥ Like"}
      </button>
    </fetcher.Form>
  );
}
```

## Forms and Progressive Enhancement

Always use the `<Form>` component from `react-router` instead of plain `<form>`. It enables:
- Client-side navigation on submission (no full page reload when JS loads)
- Automatic fallback to standard HTML form if JS fails (progressive enhancement)
- Pending UI via `useNavigation()` hook

```tsx
import { Form, useNavigation } from "react-router";

export default function ContactForm() {
  const navigation = useNavigation();
  const isSubmitting = navigation.state === "submitting";

  return (
    <Form method="post">
      <input name="email" type="email" required />
      <textarea name="message" required />
      <button disabled={isSubmitting}>
        {isSubmitting ? "Sending…" : "Send"}
      </button>
    </Form>
  );
}
```

## Error Handling

Export `ErrorBoundary` from any route module to catch errors in loaders, actions, or rendering:
```tsx
import { isRouteErrorResponse, useRouteError } from "react-router";

export function ErrorBoundary() {
  const error = useRouteError();

  if (isRouteErrorResponse(error)) {
    return (
      <div>
        <h1>{error.status} {error.statusText}</h1>
        <p>{error.data}</p>
      </div>
    );
  }

  return (
    <div>
      <h1>Unexpected Error</h1>
      <p>{error instanceof Error ? error.message : "Unknown error"}</p>
    </div>
  );
}
```

Throw `Response` objects from loaders/actions for expected errors (404, 403). Throw `Error` for unexpected failures. The nearest `ErrorBoundary` in the route hierarchy catches them — parent layouts remain rendered.

## Meta and Links

```tsx
import type { Route } from "./+types/products.$id";

export function meta({ data }: Route.MetaArgs) {
  return [
    { title: data.product.name },
    { name: "description", content: data.product.summary },
    { property: "og:title", content: data.product.name },
  ];
}

export function links() {
  return [
    { rel: "stylesheet", href: "/styles/product.css" },
    { rel: "canonical", href: "https://example.com/products" },
  ];
}
```

`meta` merges with parent route meta by default in v2+. To replace parent meta entirely, filter it out in the child.

## Cookie and Session Management

```tsx
// app/sessions.server.ts
import { createCookieSessionStorage } from "react-router";

export const { getSession, commitSession, destroySession } =
  createCookieSessionStorage({
    cookie: {
      name: "__session",
      httpOnly: true,
      maxAge: 60 * 60 * 24 * 7, // 1 week
      path: "/",
      sameSite: "lax",
      secrets: [process.env.SESSION_SECRET!],
      secure: process.env.NODE_ENV === "production",
    },
  });
```

### Using Sessions in Loaders/Actions
```tsx
export async function loader({ request }: Route.LoaderArgs) {
  const session = await getSession(request.headers.get("Cookie"));
  const userId = session.get("userId");
  if (!userId) throw redirect("/login");
  const user = await db.user.findUnique({ where: { id: userId } });
  return { user };
}

export async function action({ request }: Route.ActionArgs) {
  const session = await getSession(request.headers.get("Cookie"));
  session.set("userId", user.id);
  return redirect("/dashboard", {
    headers: { "Set-Cookie": await commitSession(session) },
  });
}
```

## Authentication Patterns

### Login Action
```tsx
// app/routes/login.tsx
export async function action({ request }: Route.ActionArgs) {
  const form = await request.formData();
  const email = form.get("email") as string;
  const password = form.get("password") as string;

  const user = await verifyLogin(email, password);
  if (!user) return { error: "Invalid credentials" };

  const session = await getSession(request.headers.get("Cookie"));
  session.set("userId", user.id);
  return redirect("/dashboard", {
    headers: { "Set-Cookie": await commitSession(session) },
  });
}
```

### Require Auth Helper
```tsx
// app/utils/auth.server.ts
export async function requireUser(request: Request) {
  const session = await getSession(request.headers.get("Cookie"));
  const userId = session.get("userId");
  if (!userId) throw redirect("/login");
  const user = await db.user.findUniqueOrThrow({ where: { id: userId } });
  return user;
}

// Use in any protected loader:
export async function loader({ request }: Route.LoaderArgs) {
  const user = await requireUser(request);
  return { user };
}
```

## Deployment Adapters

### Node.js (default)
```bash
npm install @react-router/node @react-router/serve
react-router build
react-router-serve ./build/server/index.js
```

### Cloudflare Workers
```bash
npm create cloudflare@latest -- my-app --framework=react-router
```
Cloudflare bindings available via `context.cloudflare.env` in loaders/actions.

### Vercel
```bash
npm install @vercel/react-router
```
```ts
// react-router.config.ts
import { vercelPreset } from "@vercel/react-router/vite";
export default { presets: [vercelPreset()] } satisfies Config;
```

### Custom Express Server
```ts
import express from "express";
import { createRequestHandler } from "@react-router/express";
const app = express();
app.use(express.static("build/client"));
app.all("*", createRequestHandler({ build: () => import("./build/server/index.js") }));
app.listen(3000);
```

## CSS Strategies

### CSS Modules
```tsx
import styles from "./Button.module.css";
export function Button({ children }) {
  return <button className={styles.primary}>{children}</button>;
}
```
Works out of the box with Vite. No extra config needed.

### Tailwind CSS
```bash
npm install -D tailwindcss @tailwindcss/vite
```
```ts
// vite.config.ts
import tailwindcss from "@tailwindcss/vite";
export default defineConfig({
  plugins: [tailwindcss(), reactRouter(), tsconfigPaths()],
});
```
```css
/* app/app.css */
@import "tailwindcss";
```

### Vanilla Extract
Install `@vanilla-extract/css` and `@vanilla-extract/vite-plugin`. Add `vanillaExtractPlugin()` to Vite plugins. Create `*.css.ts` files with typed styles.

## Testing Patterns

### Unit Testing Loaders/Actions (Vitest)
```ts
test("loader returns product", async () => {
  const request = new Request("http://localhost/products/1");
  const result = await loader({ request, params: { id: "1" }, context: {} });
  expect(result.product).toBeDefined();
});
```

### Component Testing with `createRoutesStub`
```tsx
import { createRoutesStub } from "react-router";
import { render, screen } from "@testing-library/react";

test("renders product page", async () => {
  const Stub = createRoutesStub([{
    path: "/products/:id",
    Component: ProductPage,
    loader: () => ({ product: { id: "1", name: "Widget" } }),
  }]);
  render(<Stub initialEntries={["/products/1"]} />);
  expect(await screen.findByText("Widget")).toBeInTheDocument();
});
```

## Migration: Remix v1/v2 → React Router v7

Run `npx codemod remix/2/react-router/upgrade` to automate package renames and import rewrites. See [references/migration-guide.md](references/migration-guide.md) for the full v1 → v2 → v7 walkthrough with breaking changes and post-migration checklist.

## Common Pitfalls

1. **Returning `json()` or `defer()`** — Unnecessary in v7. Return plain objects. `json()` is removed.
2. **Server code in client bundles** — Suffix server-only files with `.server.ts`. The bundler strips them from client builds.
3. **Missing `ErrorBoundary` in root** — Always export `ErrorBoundary` from `root.tsx`.
4. **Stale `useLoaderData` types** — Run `react-router typegen --watch` during development.
5. **Cookie secrets in client code** — Keep session logic in `.server.ts` files.
6. **Not revalidating after actions** — Revalidation is automatic. Don't manually refetch.
7. **Using `useEffect` for data fetching** — Use loaders instead.
8. **Ignoring `request.signal`** — Pass `request.signal` to fetch calls in loaders.
9. **Pathless layout confusion** — `_layout.tsx` = pathless layout. `layout.tsx` = `/layout` URL.
10. **Missing `Outlet` in layout routes** — Layout routes must render `<Outlet />`.

---

## References

In-depth guides in `references/`:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Optimistic UI with useFetcher, resource routes, streaming with Suspense/Await, nested error boundaries, parallel data loading, client-side cache management, form validation (Zod), file uploads, WebSocket integration, SSE endpoints, custom server entry
- **[troubleshooting.md](references/troubleshooting.md)** — Hydration mismatches, loader/action type errors, cookie handling gotchas, CORS with resource routes, build failures, Vite plugin conflicts, module resolution, deployment problems (Node, Cloudflare, Vercel, Fly.io), debugging techniques
- **[migration-guide.md](references/migration-guide.md)** — Step-by-step Remix v1 → v2 (future flags, flat routes, CatchBoundary removal) → React Router v7 (codemod, package mapping, API changes, adapter migration), post-migration checklist

## Scripts

Executable helpers in `scripts/`:

- **[create-route.sh](scripts/create-route.sh)** — Generate a route file with loader, action, component, meta, error boundary. Supports `--resource` and `--layout` flags.
  ```bash
  ./scripts/create-route.sh products.\$id
  ./scripts/create-route.sh api.users --resource
  ```
- **[setup-project.sh](scripts/setup-project.sh)** — Bootstrap a new project with Tailwind, TypeScript strict, Vitest, ESLint/Prettier, optional Docker.
  ```bash
  ./scripts/setup-project.sh my-app --docker
  ```
- **[check-routes.sh](scripts/check-routes.sh)** — Analyze route tree, detect URL conflicts, list params, find missing error boundaries.
  ```bash
  ./scripts/check-routes.sh
  ```

## Assets

Templates and configs in `assets/`:

- **[route-template.tsx](assets/route-template.tsx)** — Complete route module with typed loader/action, meta, links, headers, error boundary, shouldRevalidate
- **[root-layout.tsx](assets/root-layout.tsx)** — Production root layout with fonts, favicon, scroll restoration, env injection, error boundary
- **[vite.config.ts](assets/vite.config.ts)** — Vite config for RR v7 with Tailwind, source maps, chunk splitting, proxy, CSS modules
- **[docker-compose.yml](assets/docker-compose.yml)** — Docker Compose with app + PostgreSQL + Redis for local development
<!-- tested: needs-fix -->
