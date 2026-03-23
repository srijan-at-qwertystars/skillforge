---
name: nextjs-patterns
description:
  positive: "Use when user builds with Next.js, asks about App Router, Server Components, Server Actions, route handlers, middleware, ISR, dynamic routes, layouts, loading/error boundaries, or Next.js deployment."
  negative: "Do NOT use for plain React without Next.js (use react-server-components or react-state-management skills), Remix, Nuxt.js, or SvelteKit."
---

# Next.js 15 App Router Patterns & Best Practices

## App Router Architecture

Use the `/app` directory. Each folder is a route segment. Special files define UI behavior:

```
app/
├── layout.tsx       # Persistent layout (navbars, sidebars). Receives children.
├── page.tsx         # Route UI (/)
├── loading.tsx      # Auto Suspense boundary — show skeleton immediately
├── error.tsx        # Error boundary (must be 'use client'). Props: error, reset.
├── not-found.tsx    # 404 UI (triggered by notFound())
├── template.tsx     # Like layout but remounts on navigation (enter animations)
├── dashboard/
│   ├── layout.tsx   # Nested layout for /dashboard/*
│   └── page.tsx
└── (marketing)/     # Route group — no URL segment
    └── about/page.tsx
```

## Server Components vs Client Components

All components are Server Components by default. Add `'use client'` only when needed.

**Use Server Components for:**
- Data fetching (direct DB/API access)
- Accessing backend resources (fs, env vars, secrets)
- Keeping sensitive logic off the client
- Reducing client JS bundle

**Use Client Components (`'use client'`) for:**
- Event handlers (onClick, onChange)
- React hooks (useState, useEffect, useRef)
- Browser APIs (localStorage, IntersectionObserver)
- Third-party client-only libraries

### Composition Pattern

Push `'use client'` to the leaves. Pass Server Components as `children` to Client Components:

```tsx
// Server Component — fetches data, passes server-rendered children into client wrapper
import { ClientSidebar } from './client-sidebar';

export default async function DashboardPage() {
  const data = await fetchData();
  return <ClientSidebar><ServerContent data={data} /></ClientSidebar>;
}

// client-sidebar.tsx
'use client';
import { useState, type ReactNode } from 'react';
export function ClientSidebar({ children }: { children: ReactNode }) {
  const [open, setOpen] = useState(true);
  return <div className="flex"><nav>{open && <SideNav />}</nav><main>{children}</main></div>;
}
```

## Server Actions

Mark async functions with `'use server'`. Use for mutations, form submissions, and data writes.

```tsx
'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { z } from 'zod';

const Schema = z.object({ title: z.string().min(1), content: z.string().min(1) });

export async function createPost(prevState: unknown, formData: FormData) {
  const parsed = Schema.safeParse({
    title: formData.get('title'), content: formData.get('content'),
  });
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors };
  await db.post.create({ data: parsed.data });
  revalidatePath('/posts');
  redirect('/posts');
}
```

### Form with useActionState

```tsx
'use client';
import { useActionState } from 'react';
import { createPost } from './actions';

export function CreatePostForm() {
  const [state, action, pending] = useActionState(createPost, { error: null });
  return (
    <form action={action}>
      <input name="title" required disabled={pending} />
      {state?.error?.title && <p>{state.error.title}</p>}
      <button disabled={pending}>{pending ? 'Saving...' : 'Create'}</button>
    </form>
  );
}
```

### Optimistic Updates

```tsx
'use client';
import { useOptimistic, useTransition } from 'react';
import { addTodo } from './actions';

export function TodoList({ todos }: { todos: Todo[] }) {
  const [optimistic, addOptimistic] = useOptimistic(
    todos, (state, newTodo: Todo) => [...state, newTodo],
  );
  const [, startTransition] = useTransition();

  async function handleAdd(formData: FormData) {
    const text = formData.get('text') as string;
    startTransition(() => {
      addOptimistic({ id: crypto.randomUUID(), text, pending: true });
      addTodo(text); // Server Action calls revalidatePath internally
    });
  }

  return (
    <form action={handleAdd}>
      <input name="text" required />
      <ul>{optimistic.map((t) => (
        <li key={t.id} style={{ opacity: t.pending ? 0.5 : 1 }}>{t.text}</li>
      ))}</ul>
    </form>
  );
}
```

## Data Fetching

Fetch data directly in Server Components. No `getServerSideProps` or `getStaticProps` in App Router.

```tsx
// app/posts/page.tsx
export default async function PostsPage() {
  const posts = await fetch('https://api.example.com/posts', {
    next: { revalidate: 60, tags: ['posts'] }, // ISR: revalidate every 60s
  }).then((r) => r.json());

  return <PostList posts={posts} />;
}
```

### Streaming with Suspense

Wrap slow components in `<Suspense>` to stream content progressively:

```tsx
import { Suspense } from 'react';

export default function Page() {
  return (
    <>
      <h1>Dashboard</h1>
      <Suspense fallback={<StatsSkeleton />}>
        <SlowStats />
      </Suspense>
      <Suspense fallback={<ChartSkeleton />}>
        <SlowChart />
      </Suspense>
    </>
  );
}
```

## Route Handlers

Define API endpoints in `app/api/*/route.ts`. Export named HTTP method functions.

```tsx
import { NextRequest, NextResponse } from 'next/server';

export async function GET(request: NextRequest) {
  const page = Number(request.nextUrl.searchParams.get('page')) || 1;
  const posts = await db.post.findMany({ skip: (page - 1) * 10, take: 10 });
  return NextResponse.json(posts);
}

export async function POST(request: NextRequest) {
  const body = await request.json();
  const post = await db.post.create({ data: body });
  return NextResponse.json(post, { status: 201 });
}
```

### Streaming Response

```tsx
export async function GET() {
  const stream = new ReadableStream({
    async start(controller) {
      for (const chunk of dataChunks) {
        controller.enqueue(new TextEncoder().encode(JSON.stringify(chunk) + '\n'));
      }
      controller.close();
    },
  });
  return new Response(stream, { headers: { 'Content-Type': 'text/plain' } });
}
```

## Dynamic Routes

```
app/blog/[slug]/page.tsx           → /blog/hello-world
app/docs/[...segments]/page.tsx    → /docs/a/b/c (catch-all, required)
app/shop/[[...path]]/page.tsx      → /shop OR /shop/a/b (optional catch-all)
```

### generateStaticParams

Pre-render dynamic routes at build time:

```tsx
// app/blog/[slug]/page.tsx
export async function generateStaticParams() {
  const posts = await db.post.findMany({ select: { slug: true } });
  return posts.map((post) => ({ slug: post.slug }));
}

export default async function BlogPost({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const post = await db.post.findUnique({ where: { slug } });
  if (!post) notFound();
  return <article>{post.content}</article>;
}
```

## Middleware

Create `middleware.ts` at project root. Runs at the edge before every matched request.

```tsx
import { NextRequest, NextResponse } from 'next/server';

export function middleware(request: NextRequest) {
  const token = request.cookies.get('session')?.value;
  if (!token && request.nextUrl.pathname.startsWith('/dashboard')) {
    return NextResponse.redirect(new URL('/login', request.url));
  }
  // Geo-based routing
  if (request.nextUrl.pathname === '/' && request.geo?.country === 'DE') {
    return NextResponse.rewrite(new URL('/de', request.url));
  }
  const response = NextResponse.next();
  response.headers.set('x-request-id', crypto.randomUUID());
  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};
```

Keep middleware lean. No DB queries or heavy computation. Use for auth checks, redirects, rewrites, headers, A/B testing.

## Caching

Next.js 15 disables fetch caching by default. Opt in explicitly.

| Cache | Scope | Duration | Invalidation |
|---|---|---|---|
| Request Memoization | Per-request, server | Single render | Automatic |
| Data Cache | Cross-request, server | Persistent | `revalidateTag`, `revalidatePath`, time-based |
| Full Route Cache | Cross-request, server | Persistent | Revalidation, redeployment |
| Router Cache | Client (browser) | Session | `router.refresh()`, navigation |

### Cache Control

```tsx
await fetch(url);                                   // No cache (default in v15)
await fetch(url, { cache: 'force-cache' });         // Cache persistently
await fetch(url, { next: { revalidate: 60 } });     // ISR — revalidate every 60s
await fetch(url, { next: { tags: ['products'] } }); // Tag-based invalidation

// Invalidate in Server Actions
'use server';
import { revalidateTag, revalidatePath } from 'next/cache';
revalidateTag('products');
revalidatePath('/products');
```

### `use cache` Directive (Next.js 15+)

```tsx
async function getProducts() {
  'use cache';
  return await db.product.findMany();
}
```

## Metadata and SEO

## Static Metadata
```tsx
import type { Metadata } from 'next';
export const metadata: Metadata = {
  title: { default: 'My App', template: '%s | My App' },
  description: 'App description',
  openGraph: { type: 'website', locale: 'en_US' },
};
```

### Dynamic Metadata

```tsx
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params;
  const post = await getPost(slug);
  return { title: post.title, description: post.excerpt, openGraph: { images: [post.coverImage] } };
}
```

### Sitemap and Robots

```tsx
// app/sitemap.ts
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const posts = await db.post.findMany({ select: { slug: true, updatedAt: true } });
  return posts.map((p) => ({ url: `https://example.com/blog/${p.slug}`, lastModified: p.updatedAt }));
}

// app/robots.ts
export default function robots(): MetadataRoute.Robots {
  return { rules: { userAgent: '*', allow: '/' }, sitemap: 'https://example.com/sitemap.xml' };
}
```

## Image and Font Optimization

```tsx
import Image from 'next/image';
<Image src="/hero.jpg" alt="Hero" width={1200} height={600} priority placeholder="blur" />
// Remote images: configure remotePatterns in next.config.ts
```

```tsx
import { Inter } from 'next/font/google';
const inter = Inter({ subsets: ['latin'], display: 'swap' });

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en" className={inter.className}><body>{children}</body></html>;
}
```

## Parallel Routes and Intercepting Routes

### Parallel Routes (`@slot`)

Render multiple pages simultaneously in the same layout:

```
app/dashboard/
├── layout.tsx       # Receives @analytics and @team as props
├── @analytics/page.tsx
└── @team/page.tsx
```

```tsx
export default function Layout({ children, analytics, team }: {
  children: React.ReactNode; analytics: React.ReactNode; team: React.ReactNode;
}) {
  return <div>{children}<div className="grid grid-cols-2">{analytics}{team}</div></div>;
}
```

### Intercepting Routes

Use `(.)`, `(..)`, `(...)` prefixes to intercept routes for modals:

```
app/@modal/(.)photo/[id]/page.tsx   # Intercepts /photo/[id] as modal overlay
app/photo/[id]/page.tsx             # Direct navigation shows full page
```

## Authentication Patterns

### Middleware Auth Guard

```tsx
// middleware.ts
const publicPaths = ['/login', '/register', '/api/auth'];

export function middleware(request: NextRequest) {
  const isPublic = publicPaths.some((p) => request.nextUrl.pathname.startsWith(p));
  const token = request.cookies.get('session')?.value;
  if (!isPublic && !token) {
    return NextResponse.redirect(new URL('/login', request.url));
  }
}
```

### Server-Side Session Check

```tsx
import { cookies } from 'next/headers';

export async function getSession() {
  const token = (await cookies()).get('session')?.value;
  if (!token) return null;
  return await verifyToken(token);
}

// In a page — redirect if unauthenticated
import { getSession } from '@/lib/auth';
import { redirect } from 'next/navigation';

export default async function Dashboard() {
  const session = await getSession();
  if (!session) redirect('/login');
  return <h1>Welcome, {session.user.name}</h1>;
}
```

### NextAuth.js v5 (Auth.js)

```tsx
import NextAuth from 'next-auth';
import GitHub from 'next-auth/providers/github';
export const { handlers, signIn, signOut, auth } = NextAuth({ providers: [GitHub] });

// app/api/auth/[...nextauth]/route.ts
export { GET, POST } from '@/auth';
```

## Deployment

### Vercel (recommended)

Zero-config. Push to Git. Automatic edge functions, ISR, image optimization.

### Docker / Standalone

```js
// next.config.ts
export default { output: 'standalone' };
```

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./ && RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
CMD ["node", "server.js"]
```

### Static Export

```js
export default { output: 'export' }; // Fully static — no server needed
```

## Performance

- **Bundle analysis:** `ANALYZE=true next build` with `@next/bundle-analyzer`.
- **Lazy loading:** Use `next/dynamic` for heavy client components:
```tsx
import dynamic from 'next/dynamic';
const HeavyChart = dynamic(() => import('./heavy-chart'), { loading: () => <Skeleton />, ssr: false });
```
- **Turbopack:** `next dev --turbopack` for faster dev builds.
- **`next/image`:** Always use. Automatic WebP/AVIF, lazy loading, responsive sizes.
- **Prefetching:** `<Link>` prefetches visible routes. Use `prefetch={false}` for low-priority links.

## Anti-Patterns

**Over-using `'use client'`:** Do not add `'use client'` to top-level layouts or pages. Push interactivity to leaf components. Every `'use client'` boundary increases client bundle size.

**Waterfall fetching:** Do not `await` sequential independent fetches. Use `Promise.all`:
```tsx
// BAD: const user = await getUser(); const posts = await getPosts(user.id);
const [user, posts] = await Promise.all([getUser(), getPosts(userId)]); // GOOD
```

**Fetching in Client Components when Server Components suffice:** Avoid `useEffect` + `fetch` when server-side data access works. Keep non-interactive components as Server Components.

**Ignoring cache invalidation after mutations:** Always call `revalidatePath` or `revalidateTag` in Server Actions after writes.

**Using API routes for server-only data:** Prefer direct DB/API calls in Server Components over `/api` routes for read-only data.

**Large middleware:** No DB queries or heavy computation. Redirects, rewrites, headers, and lightweight auth only.
