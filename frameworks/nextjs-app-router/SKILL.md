---
name: nextjs-app-router
description: |
  Use when working with Next.js App Router (app/ directory). TRIGGER: next.config.js/ts present, app/ directory with page.tsx/layout.tsx, imports from "next/navigation" or "next/image" or "next/link" or "next/font" or "next/headers", "use client" directive, Server Components, Server Actions, route handlers (route.ts), generateMetadata, generateStaticParams, middleware.ts, next/form, revalidatePath, revalidateTag, loading.tsx, error.tsx, not-found.tsx, parallel routes (@slot), intercepting routes, route groups ((group)), dynamic segments [slug]. DO NOT TRIGGER for: Next.js Pages Router (pages/ directory, getServerSideProps, getStaticProps, _app.tsx, _document.tsx), Remix, SvelteKit, Astro, Nuxt, plain React without Next.js, or Vite-only React projects. This skill covers Next.js 14+ and 15 App Router patterns exclusively.
---

# Next.js App Router

## Architecture

Next.js App Router uses the `app/` directory for file-based routing. Every folder is a route segment. Special files define UI and behavior per segment. All components are **React Server Components by default** — they render on the server, ship zero JS to the client, and can directly `await` async data.

### Project Structure

```
app/
  layout.tsx          # Root layout (required, wraps all pages)
  page.tsx            # "/" route
  globals.css
  blog/
    page.tsx          # "/blog"
    [slug]/
      page.tsx        # "/blog/:slug"
  dashboard/
    layout.tsx        # Nested layout for /dashboard/*
    page.tsx
    settings/
      page.tsx
    @analytics/       # Parallel route slot
      page.tsx
  (marketing)/        # Route group (no URL segment)
    about/
      page.tsx        # "/about"
  api/
    users/
      route.ts        # API handler: GET/POST /api/users
middleware.ts          # Edge middleware at project root
next.config.ts         # Configuration
```

## Route File Conventions

| File | Purpose |
|------|---------|
| `page.tsx` | Makes route publicly accessible. Required for a route to render. |
| `layout.tsx` | Shared UI wrapping child routes. Persists across navigations. Does NOT remount. |
| `template.tsx` | Like layout but remounts on every navigation. Use for enter/exit animations. |
| `loading.tsx` | Instant loading UI via React Suspense. Shown while page/data loads. |
| `error.tsx` | Error boundary for the segment. Must be `"use client"`. Receives `error` and `reset` props. |
| `not-found.tsx` | UI for `notFound()` calls or unmatched routes. |
| `route.ts` | API route handler. Cannot coexist with `page.tsx` in same folder. |
| `default.tsx` | Fallback for parallel route slots when no match exists. |

## Server Components vs Client Components

**Server Components (default):** Render on server. Can `await` data, access DB/filesystem, keep secrets safe. Ship zero JS.

**Client Components:** Add `"use client"` at file top. Required for: `useState`, `useEffect`, `useRef`, event handlers (`onClick`, `onChange`), browser APIs, third-party UI libs (date pickers, maps, rich editors).

### Rules

- Default to Server Components. Only add `"use client"` when you need interactivity or browser APIs.
- Server Components can import Client Components. Client Components CANNOT import Server Components — pass them as `children` or props instead.
- Move `"use client"` as far down the tree as possible. Wrap only the interactive leaf, not the entire page.

```tsx
// app/dashboard/page.tsx — Server Component (default)
import { db } from "@/lib/db";
import { LikeButton } from "./like-button";

export default async function DashboardPage() {
  const stats = await db.stats.findMany();
  return <div><h1>Dashboard</h1><p>Total: {stats.totalUsers}</p><LikeButton /></div>;
}
```

```tsx
// app/dashboard/like-button.tsx
"use client";
import { useState } from "react";

export function LikeButton() {
  const [liked, setLiked] = useState(false);
  return <button onClick={() => setLiked(!liked)}>{liked ? "❤️" : "🤍"}</button>;
}
```

## Data Fetching

### In Server Components

Fetch data directly with `async/await`. Next.js 15 does NOT cache fetches by default — opt in explicitly.

```tsx
// app/products/page.tsx
async function getProducts() {
  const res = await fetch("https://api.example.com/products", {
    next: { revalidate: 3600 }, // ISR: revalidate every hour
  });
  if (!res.ok) throw new Error("Failed to fetch");
  return res.json();
}

export default async function ProductsPage() {
  const products = await getProducts();
  return <ul>{products.map((p) => <li key={p.id}>{p.name}</li>)}</ul>;
}
```

### Fetch Cache Options

| Option | Behavior |
|--------|----------|
| `{ cache: "no-store" }` | Always fresh. No caching. (Default in Next.js 15) |
| `{ cache: "force-cache" }` | Cache indefinitely until manual invalidation. |
| `{ next: { revalidate: N } }` | ISR — stale-while-revalidate every N seconds. |
| `{ next: { tags: ["products"] } }` | Tag-based cache. Invalidate with `revalidateTag("products")`. |

### Request Memoization

Multiple `fetch()` calls to the same URL with same options during a single render are automatically deduplicated. No extra work needed.

### React `cache()` for Non-Fetch Data

```tsx
import { cache } from "react";
import { db } from "@/lib/db";

export const getUser = cache(async (id: string) => {
  return db.user.findUnique({ where: { id } });
});
```

## Server Actions

Define mutations that run on the server. Mark with `"use server"` at function level or file level.

```tsx
// app/actions.ts
"use server";

import { revalidatePath } from "next/cache";
import { db } from "@/lib/db";

export async function createPost(formData: FormData) {
  const title = formData.get("title") as string;
  const body = formData.get("body") as string;

  await db.post.create({ data: { title, body } });
  revalidatePath("/posts");
}
```

```tsx
// app/posts/new/page.tsx
import { createPost } from "@/app/actions";

export default function NewPostPage() {
  return (
    <form action={createPost}>
      <input name="title" required />
      <textarea name="body" required />
      <button type="submit">Create</button>
    </form>
  );
}
```

### Server Action Patterns

- Use `revalidatePath("/path")` to purge cached pages after mutation.
- Use `revalidateTag("tag")` for granular cache invalidation.
- Use `redirect("/path")` from `next/navigation` after successful mutations.
- For optimistic UI, pair with `useOptimistic` in a Client Component.
- Validate inputs with Zod on the server. Never trust client data.

## Dynamic Routes

```
app/blog/[slug]/page.tsx        → /blog/my-post       params: { slug: "my-post" }
app/shop/[...path]/page.tsx     → /shop/a/b/c          params: { path: ["a","b","c"] }
app/docs/[[...slug]]/page.tsx   → /docs OR /docs/a/b   params: { slug?: string[] }
```

```tsx
// app/blog/[slug]/page.tsx
export default async function BlogPost({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params; // Next.js 15: params is async
  const post = await getPost(slug);
  return <article><h1>{post.title}</h1><div>{post.content}</div></article>;
}

export async function generateStaticParams() {
  const posts = await getAllPosts();
  return posts.map((post) => ({ slug: post.slug }));
}
```

**Next.js 15 breaking change:** `params` and `searchParams` are now `Promise`-based. Always `await` them.

## Route Groups, Parallel Routes, Intercepting Routes

### Route Groups `(name)`

Organize routes without affecting URL. Each group can have its own `layout.tsx`.

```
app/(marketing)/about/page.tsx   → /about
app/(shop)/products/page.tsx     → /products
```

Render multiple pages simultaneously in the same layout. Prefix folder with `@`.

```
app/dashboard/layout.tsx         → receives @analytics and @team as props
app/dashboard/@analytics/page.tsx
app/dashboard/@team/page.tsx
app/dashboard/page.tsx
```

```tsx
// app/dashboard/layout.tsx
export default function Layout({
  children, analytics, team,
}: {
  children: React.ReactNode; analytics: React.ReactNode; team: React.ReactNode;
}) {
  return <div>{children}<div className="grid grid-cols-2">{analytics}{team}</div></div>;
}
```

### Intercepting Routes

Use `(.)`, `(..)`, `(..)(..)`, `(...)` prefixes to intercept navigation and show modals while preserving URL.

```
app/@modal/(.)photo/[id]/page.tsx  → intercepts /photo/[id] in current layout
```

## Middleware

Place `middleware.ts` at project root. Runs on Edge Runtime before every matched request.

```tsx
import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

export function middleware(request: NextRequest) {
  const token = request.cookies.get("session")?.value;
  if (!token && request.nextUrl.pathname.startsWith("/dashboard")) {
    return NextResponse.redirect(new URL("/login", request.url));
  }
  const response = NextResponse.next();
  response.headers.set("x-custom-header", "middleware-applied");
  return response;
}

export const config = {
  matcher: ["/dashboard/:path*", "/api/:path*"],
};
```

- Use `matcher` to scope. Exclude static assets: `"/((?!_next/static|_next/image|favicon.ico).*)"`.
- Cannot use Node.js APIs (fs, db). Edge-compatible code only.
- Keep thin — auth checks and redirects only. No heavy computation.

## Metadata API

```tsx
// Static metadata — app/about/page.tsx
export const metadata: Metadata = {
  title: "About Us",
  description: "Learn more about our company",
  openGraph: { title: "About Us", images: ["/og-about.png"] },
};
```

```tsx
// Dynamic metadata — app/blog/[slug]/page.tsx
export async function generateMetadata(
  { params }: { params: Promise<{ slug: string }> }
): Promise<Metadata> {
  const { slug } = await params;
  const post = await getPost(slug);
  return { title: post.title, description: post.excerpt, openGraph: { images: [post.coverImage] } };
}
```

### Special Metadata Files

Place in route folder: `opengraph-image.tsx`, `twitter-image.tsx`, `icon.tsx`, `sitemap.ts`, `robots.ts`.

```tsx
// app/opengraph-image.tsx — generates OG image at build/request time
import { ImageResponse } from "next/og";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";
export default function OGImage() {
  return new ImageResponse(<div style={{ fontSize: 72 }}>My Site</div>, size);
}
```

## Streaming and Suspense

### Automatic with loading.tsx

Place `loading.tsx` in any route segment. Next.js wraps `page.tsx` in a Suspense boundary automatically.

### Manual Suspense Boundaries

```tsx
export default function Page() {
  return (
    <div>
      <h1>Dashboard</h1>
      <Suspense fallback={<p>Loading stats...</p>}><AsyncStats /></Suspense>
      <Suspense fallback={<p>Loading feed...</p>}><AsyncFeed /></Suspense>
    </div>
  );
}
```

Each Suspense boundary streams independently. Fast sections appear first. Use granular boundaries around slow data sources.

## Caching Architecture (Next.js 15)

| Layer | Scope | Default (v15) | Control |
|-------|-------|---------------|---------|
| Request Memoization | Per-render | ON | Automatic dedup of same fetch calls |
| Data Cache | Cross-request | OFF | `cache: "force-cache"` or `revalidate` |
| Full Route Cache | Build time | Static routes only | `dynamic` segment config |
| Router Cache | Client | 30s dynamic, 5min static | `router.refresh()`, `revalidatePath` |

**Key v15 change:** Data Cache is OFF by default. Explicitly opt in with `cache: "force-cache"` or `next: { revalidate: N }`.

### Segment Config

```tsx
// Force dynamic rendering for entire route
export const dynamic = "force-dynamic";

// Or force static
export const dynamic = "force-static";

// ISR at route level
export const revalidate = 3600;
```

## API Routes (Route Handlers)

```tsx
// app/api/users/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const page = searchParams.get("page") ?? "1";
  const users = await db.user.findMany({ skip: (+page - 1) * 10, take: 10 });
  return NextResponse.json(users);
}

export async function POST(request: NextRequest) {
  const body = await request.json();
  const user = await db.user.create({ data: body });
  return NextResponse.json(user, { status: 201 });
}
```

## Image Optimization

```tsx
import Image from "next/image";
import heroImg from "@/public/hero.jpg";

// Local: auto width/height, blur placeholder
<Image src={heroImg} alt="Hero" placeholder="blur" priority />

// Remote: must specify dimensions + configure remotePatterns in next.config.ts
<Image src="https://cdn.example.com/photo.jpg" alt="Photo" width={800} height={600} />
```

Use `priority` on LCP images. Use `sizes` for responsive. Prefer `fill` with `object-fit` for dynamic aspect ratios.

## Authentication Patterns

### Middleware + Auth.js (NextAuth v5)

```tsx
// auth.ts
import NextAuth from "next-auth";
import GitHub from "next-auth/providers/github";
export const { handlers, auth, signIn, signOut } = NextAuth({ providers: [GitHub] });

// app/api/auth/[...nextauth]/route.ts
import { handlers } from "@/auth";
export const { GET, POST } = handlers;

// middleware.ts — protect routes
export { auth as middleware } from "@/auth";
export const config = { matcher: ["/dashboard/:path*"] };
```

### Server Component Auth Check

```tsx
import { auth } from "@/auth";
import { redirect } from "next/navigation";

export default async function ProtectedPage() {
  const session = await auth();
  if (!session) redirect("/login");
  return <p>Welcome {session.user?.name}</p>;
}
```

## Deployment

### Vercel (zero-config)

Push to Git. Vercel auto-detects Next.js. Supports all features: SSR, ISR, middleware, Edge.

### Docker (standalone)

Set `output: "standalone"` in next.config.ts. See [`assets/Dockerfile`](assets/Dockerfile) for production multi-stage build.

```ts
const nextConfig = { output: "standalone" };
```

### Static Export

`output: "export"` in next.config.ts. No SSR, no middleware, no route handlers, no ISR. Pure static HTML/CSS/JS.

## Performance

### Dynamic Imports

```tsx
import dynamic from "next/dynamic";
const HeavyChart = dynamic(() => import("@/components/chart"), {
  loading: () => <p>Loading chart...</p>,
  ssr: false,
});
```

### Font Optimization

```tsx
import { Inter } from "next/font/google";
const inter = Inter({ subsets: ["latin"] });

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en" className={inter.className}><body>{children}</body></html>;
}
```

### Partial Prerendering (Experimental)

Enable with `experimental: { ppr: true }`. Static shell from CDN, dynamic Suspense holes stream in. See [`references/advanced-patterns.md`](references/advanced-patterns.md#partial-prerendering-ppr).

## Common Pitfalls

1. **"use client" too high.** Don't mark `layout.tsx` or `page.tsx` as client. Extract interactive parts into small Client Components.
2. **Forgetting `await params`.** Next.js 15 makes `params` and `searchParams` async. Always `await` them.
3. **Importing server code in client.** Client Components cannot import `"use server"` modules directly — use them via `action` prop or call from event handlers.
4. **Stale data after mutation.** Call `revalidatePath` or `revalidateTag` in Server Actions. Don't rely on auto-invalidation.
5. **Middleware doing too much.** Keep middleware thin — auth checks and redirects only. No DB queries, no heavy computation.
6. **Missing `error.tsx` boundaries.** Without them, errors bubble up and crash the entire page. Add `error.tsx` per major segment.
7. **`route.ts` next to `page.tsx`.** They conflict. API routes and pages cannot coexist in the same folder.
8. **Not using `loading.tsx`.** Missing loading states cause blank screens during navigation. Add them to data-heavy routes.
9. **Hydration mismatches.** Don't use `Date.now()`, `Math.random()`, or browser-only globals in shared render paths. Guard with `useEffect`.
10. **Over-fetching in layouts.** Layouts don't re-render on navigation. Fetch route-specific data in `page.tsx`, not `layout.tsx`.

---

## References

Deep-dive guides (self-contained, with TOC):

- **[`references/advanced-patterns.md`](references/advanced-patterns.md)** — Parallel routes, intercepting routes, streaming, server action patterns, PPR, caching, ISR, i18n, multi-tenant, layouts, error boundaries, middleware
- **[`references/troubleshooting.md`](references/troubleshooting.md)** — "use client" issues, hydration, caching, server actions, static/dynamic, bundles, images, deployment, TypeScript, RSC compat
- **[`references/deployment-guide.md`](references/deployment-guide.md)** — Vercel, Docker, Node.js, static export, CDN, env vars, health checks, logging, monitoring, Edge vs Node, self-hosted ISR

## Scripts

Run from project root:

- **[`scripts/nextjs-init.sh`](scripts/nextjs-init.sh)** `<project-name>` — Scaffold Next.js 15 + TypeScript + Tailwind + ESLint + `src/`
- **[`scripts/route-generator.sh`](scripts/route-generator.sh)** `<path> [--api]` — Generate page, layout, loading, error (or route handler with `--api`)
- **[`scripts/component-generator.sh`](scripts/component-generator.sh)** `<name> <server|client>` — Generate component with proper conventions

## Assets

Production templates — copy and adapt:

- **[`assets/next.config.ts`](assets/next.config.ts)** — Images, security headers, redirects, rewrites, standalone output
- **[`assets/middleware.ts`](assets/middleware.ts)** — Auth, locale detection, rate limiting, security headers
- **[`assets/Dockerfile`](assets/Dockerfile)** — Multi-stage standalone build, non-root user, health check
- **[`assets/docker-compose.yml`](assets/docker-compose.yml)** — Next.js + Postgres + Redis dev environment
- **[`assets/server-action-template.ts`](assets/server-action-template.ts)** — Zod validation, error handling, revalidation, CRUD
