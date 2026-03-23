---
name: react-server-components
description:
  positive: "Use when user works with React Server Components, Next.js App Router, server vs client component boundaries, 'use client'/'use server' directives, server actions, streaming SSR, or RSC data fetching patterns."
  negative: "Do NOT use for React class components, legacy Next.js Pages Router, Create React App, or general React hooks unrelated to RSC."
---

# React Server Components (RSC)

## Server vs Client Component Mental Model

Think of your component tree as two zones:

- **Server zone** — runs only on the server. Zero JS shipped to the browser. Direct access to databases, file system, env secrets. Default in Next.js App Router.
- **Client zone** — hydrated in the browser. Required for state, event handlers, browser APIs (`window`, `localStorage`), and effects.

**Decision rule:** default to Server Component. Add `'use client'` only when the component needs interactivity, state, or browser APIs.

| Need | Component |
|---|---|
| Database/API fetch | Server |
| Render markdown, static content | Server |
| Access env secrets | Server |
| `useState`, `useReducer` | Client |
| `onClick`, `onChange`, event handlers | Client |
| `useEffect`, `useRef` | Client |
| `window`, `localStorage`, `IntersectionObserver` | Client |
| Third-party interactive widgets | Client |

## `'use client'` and `'use server'` Directives

### `'use client'`

Place at the **top of the file** (before any imports). Marks the file—and all its transitive imports—as client code.

```tsx
'use client';

import { useState } from 'react';

export function Counter() {
  const [count, setCount] = useState(0);
  return <button onClick={() => setCount(count + 1)}>{count}</button>;
}
```

**Rules:**
- Must be the first statement (after comments). No expressions above it.
- Every module imported by a `'use client'` file becomes client code.
- Push the boundary as deep as possible—mark the leaf component, not the layout.
- A Server Component can import and render a Client Component. A Client Component cannot `import` a Server Component directly (but can receive one as `children` or a prop).

### `'use server'`

Marks an async function (or all exports of a file) as a **Server Action** callable from the client.

```tsx
// app/actions.ts
'use server';

export async function createPost(formData: FormData) {
  const title = formData.get('title') as string;
  await db.post.create({ data: { title } });
  revalidatePath('/posts');
}
```

**Rules:**
- Can only be applied to `async` functions.
- Arguments and return values must be serializable (no functions, classes, or DOM nodes).
- Place at function level inside a Server Component or at file level for a dedicated actions file.

## Data Fetching in Server Components

Server Components are `async`—fetch data directly in the component body. No `useEffect`, no loading state management, no client-side fetch libraries needed.

```tsx
// app/posts/page.tsx — Server Component (default)
import { db } from '@/lib/db';

export default async function PostsPage() {
  const posts = await db.post.findMany({ orderBy: { createdAt: 'desc' } });

  return (
    <ul>
      {posts.map((post) => (
        <li key={post.id}>{post.title}</li>
      ))}
    </ul>
  );
}
```

**Key points:**
- `fetch()` calls in Server Components are automatically deduped per request in Next.js.
- Access databases, ORMs, or internal services directly—no API route needed.
- Never expose API keys or secrets; they stay on the server.

## Server Actions

### Form Handling

```tsx
// app/posts/new/page.tsx
import { createPost } from '@/app/actions';

export default function NewPostPage() {
  return (
    <form action={createPost}>
      <input name="title" required />
      <button type="submit">Create</button>
    </form>
  );
}
```

### Mutations with Validation and Error Handling

```tsx
'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';

const PostSchema = z.object({ title: z.string().min(1).max(200) });

export async function createPost(formData: FormData) {
  const parsed = PostSchema.safeParse({ title: formData.get('title') });
  if (!parsed.success) {
    return { error: parsed.error.flatten().fieldErrors };
  }
  await db.post.create({ data: parsed.data });
  revalidatePath('/posts');
  return { success: true };
}
```

### Calling from Client Components

```tsx
'use client';

import { useActionState } from 'react';
import { createPost } from '@/app/actions';

export function PostForm() {
  const [state, formAction, isPending] = useActionState(createPost, null);

  return (
    <form action={formAction}>
      <input name="title" />
      {state?.error && <p className="error">{state.error.title}</p>}
      <button disabled={isPending}>
        {isPending ? 'Saving…' : 'Create'}
      </button>
    </form>
  );
}
```

### Programmatic Invocation

```tsx
'use client';

import { deletePost } from '@/app/actions';
import { useTransition } from 'react';

export function DeleteButton({ postId }: { postId: string }) {
  const [isPending, startTransition] = useTransition();

  return (
    <button
      disabled={isPending}
      onClick={() => startTransition(() => deletePost(postId))}
    >
      {isPending ? 'Deleting…' : 'Delete'}
    </button>
  );
}
```

## Composition Patterns

### Server Component Wrapping Client Component

Pass server-fetched data as props to interactive client leaves:

```tsx
// app/dashboard/page.tsx (Server)
import { getMetrics } from '@/lib/data';
import { MetricsChart } from '@/components/MetricsChart';

export default async function DashboardPage() {
  const metrics = await getMetrics();
  return <MetricsChart data={metrics} />;
}
```

```tsx
// components/MetricsChart.tsx (Client)
'use client';
export function MetricsChart({ data }: { data: Metric[] }) {
  // Interactive chart with D3, Recharts, etc.
}
```

### Passing Server Components as Children

A Client Component can render Server Component content via `children`:

```tsx
// components/Sidebar.tsx (Client)
'use client';
export function Sidebar({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = useState(true);
  return open ? <aside>{children}</aside> : null;
}
```

```tsx
// app/layout.tsx (Server)
import { Sidebar } from '@/components/Sidebar';
import { NavLinks } from '@/components/NavLinks'; // Server Component

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <Sidebar>
        <NavLinks /> {/* Server Component rendered inside Client */}
      </Sidebar>
      <main>{children}</main>
    </div>
  );
}
```

## Streaming and Suspense Boundaries

Wrap slow-loading server components in `<Suspense>` to stream HTML progressively:

```tsx
import { Suspense } from 'react';
import { RevenueChart } from '@/components/RevenueChart';
import { LatestInvoices } from '@/components/LatestInvoices';

export default function DashboardPage() {
  return (
    <div>
      <h1>Dashboard</h1>
      <Suspense fallback={<ChartSkeleton />}>
        <RevenueChart />
      </Suspense>
      <Suspense fallback={<InvoiceSkeleton />}>
        <LatestInvoices />
      </Suspense>
    </div>
  );
}
```

Each `<Suspense>` boundary streams its content independently. The shell renders instantly; slow data fills in as it resolves.

Use `loading.tsx` for route-level streaming (auto-wraps `page.tsx` in Suspense):

```tsx
// app/dashboard/loading.tsx
export default function Loading() {
  return <DashboardSkeleton />;
}
```

## Caching and Revalidation

### Fetch Cache Options

```tsx
// Static — cached indefinitely (default in production)
const data = await fetch('https://api.example.com/posts', {
  cache: 'force-cache',
});

// Dynamic — never cached
const data = await fetch('https://api.example.com/posts', {
  cache: 'no-store',
});

// Time-based revalidation (ISR)
const data = await fetch('https://api.example.com/posts', {
  next: { revalidate: 60 },
});

// Tag-based revalidation
const data = await fetch('https://api.example.com/posts', {
  next: { tags: ['posts'] },
});
```

### Route Segment Config

```tsx
// Force dynamic rendering for an entire route
export const dynamic = 'force-dynamic';

// Set default revalidation for all fetches in a layout/page
export const revalidate = 3600;
```

### On-Demand Revalidation in Server Actions

```tsx
'use server';

import { revalidatePath, revalidateTag } from 'next/cache';

export async function updatePost(id: string, formData: FormData) {
  await db.post.update({ where: { id }, data: { title: formData.get('title') as string } });
  revalidateTag('posts');    // Invalidate all fetches tagged 'posts'
  revalidatePath('/posts');  // Revalidate the /posts route
}
```

## Common Patterns

### Parallel Data Fetching (Avoid Waterfalls)

```tsx
export default async function Page() {
  // BAD — sequential waterfall
  // const user = await getUser();
  // const posts = await getPosts();

  // GOOD — parallel
  const [user, posts] = await Promise.all([getUser(), getPosts()]);
  return <Profile user={user} posts={posts} />;
}
```

### Extract Only the Interactive Part

```tsx
// Server Component — static content stays on server
export default async function ProductPage({ params }: { params: { id: string } }) {
  const product = await getProduct(params.id);
  return (
    <article>
      <h1>{product.name}</h1>
      <p>{product.description}</p>
      <AddToCartButton productId={product.id} price={product.price} />
    </article>
  );
}
```

## File Conventions (Next.js App Router)

| File | Purpose |
|---|---|
| `page.tsx` | Route UI. Makes folder publicly accessible. |
| `layout.tsx` | Shared UI wrapping child routes. Preserves state across navigations. |
| `loading.tsx` | Instant loading UI (Suspense fallback for the route). |
| `error.tsx` | Error boundary. Must be `'use client'`. Receives `error` and `reset` props. |
| `not-found.tsx` | UI for `notFound()` calls or unmatched routes. |
| `template.tsx` | Like layout but re-mounts on navigation (no state preservation). |
| `default.tsx` | Fallback for parallel routes when no match. |
| `route.ts` | API endpoint (GET, POST, etc.). Cannot coexist with `page.tsx` in same folder. |
| `middleware.ts` | Runs before requests. Use for auth, redirects, headers. Place at project root. |

### Error Boundary Example

```tsx
'use client';

export default function Error({ error, reset }: { error: Error; reset: () => void }) {
  return (
    <div>
      <h2>Something went wrong</h2>
      <p>{error.message}</p>
      <button onClick={() => reset()}>Try again</button>
    </div>
  );
}
```

## Migration from Pages Router to App Router

1. **Create `app/` directory** alongside `pages/`. Both can coexist during migration.
2. **Move layouts first.** Convert `_app.tsx` and `_document.tsx` into `app/layout.tsx`:
   ```tsx
   // app/layout.tsx
   export default function RootLayout({ children }: { children: React.ReactNode }) {
     return (
       <html lang="en">
         <body>{children}</body>
       </html>
     );
   }
   ```
3. **Migrate routes incrementally.** Move one `pages/foo.tsx` → `app/foo/page.tsx` at a time.
4. **Replace data fetching:**
   - `getServerSideProps` → async Server Component with direct data fetch.
   - `getStaticProps` → async Server Component + `export const revalidate = N`.
   - `getStaticPaths` → `generateStaticParams()`.
5. **Move API routes** from `pages/api/` to `app/api/route.ts` using the Route Handler API.
6. **Update client-side routing** from `next/router` to `next/navigation` (`useRouter`, `usePathname`, `useSearchParams`).

## Performance: Reducing Client Bundle and Selective Hydration

- **Default to Server Components.** Every component that stays on the server is zero bytes in the client bundle.
- **Push `'use client'` to leaves.** A `'use client'` boundary ships all its imports to the client. Keep it narrow.
- **Use dynamic imports** for heavy client components:
  ```tsx
  import dynamic from 'next/dynamic';
  const HeavyEditor = dynamic(() => import('@/components/Editor'), {
    loading: () => <EditorSkeleton />,
    ssr: false,
  });
  ```
- **Selective hydration:** Suspense boundaries let React prioritize hydrating components the user interacts with first.
- **Measure with Next.js Bundle Analyzer:**
  ```bash
  ANALYZE=true next build
  ```
- **Tree-shake aggressively.** Avoid barrel files (`index.ts` re-exports) that pull entire libraries into client bundles.

## Anti-Patterns

### 1. Placing `'use client'` Too High

```tsx
// BAD — entire page becomes client code
'use client';
export default function DashboardPage() { /* ... */ }

// GOOD — only the interactive widget is client
// DashboardPage stays as Server Component
import { InteractiveWidget } from './InteractiveWidget'; // 'use client' inside
export default async function DashboardPage() {
  const data = await getData();
  return <InteractiveWidget data={data} />;
}
```

### 2. Fetching on the Client When Server Works

```tsx
// BAD — unnecessary client fetch
'use client';
export function Posts() {
  const [posts, setPosts] = useState([]);
  useEffect(() => { fetch('/api/posts').then(r => r.json()).then(setPosts); }, []);
  return <ul>{posts.map(p => <li key={p.id}>{p.title}</li>)}</ul>;
}

// GOOD — fetch on server, zero client JS
export default async function Posts() {
  const posts = await db.post.findMany();
  return <ul>{posts.map(p => <li key={p.id}>{p.title}</li>)}</ul>;
}
```

### 3. Over-Serializing Props

Pass only the data the client component needs. Do not pass entire ORM models or deeply nested objects that include server-only fields.

```tsx
// BAD
<ClientChart data={fullDatabaseRecord} />

// GOOD
<ClientChart points={record.dataPoints} label={record.label} />
```

### 4. Disabling Cache Globally

Do not set `export const dynamic = 'force-dynamic'` in root layout. Scope `cache: 'no-store'` or `dynamic` config to the specific routes that need it.

### 5. Importing Server-Only Code in Client Components

Use the `server-only` package to enforce boundaries:

```bash
npm install server-only
```

```tsx
// lib/db.ts
import 'server-only';
import { PrismaClient } from '@prisma/client';
export const db = new PrismaClient();
```

Importing this file in a `'use client'` module triggers a build error—catching leaks at compile time.

<!-- tested: pass -->
