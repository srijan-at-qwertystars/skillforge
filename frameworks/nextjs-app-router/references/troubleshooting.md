# Next.js App Router Troubleshooting Guide

## Table of Contents

- ["use client" Boundary Confusion](#use-client-boundary-confusion)
- [Hydration Mismatches](#hydration-mismatches)
- [Caching Unexpected Behavior](#caching-unexpected-behavior)
- [Server Action Errors](#server-action-errors)
- [Middleware Issues](#middleware-issues)
- [Static Generation Failures](#static-generation-failures)
- [Dynamic Rendering When Static Expected](#dynamic-rendering-when-static-expected)
- [Large Bundle Size Diagnosis](#large-bundle-size-diagnosis)
- [Memory Issues During Build](#memory-issues-during-build)
- [Image Optimization Errors](#image-optimization-errors)
- [Deployment Issues](#deployment-issues)
- [TypeScript Strict Mode Conflicts](#typescript-strict-mode-conflicts)
- [Third-Party Library RSC Compatibility](#third-party-library-rsc-compatibility)

---

## "use client" Boundary Confusion

### Problem: "You're importing a component that needs X. It only works in a Client Component"

**Cause:** Using React hooks (`useState`, `useEffect`, `useRef`, `useContext`) or browser APIs in a Server Component.

**Fix:**

```tsx
// ❌ Wrong: hook in server component
// app/counter/page.tsx
import { useState } from "react"; // Error!

// ✅ Fix: extract to client component
// app/counter/counter-button.tsx
"use client";
import { useState } from "react";
export function CounterButton() {
  const [count, setCount] = useState(0);
  return <button onClick={() => setCount(count + 1)}>{count}</button>;
}

// app/counter/page.tsx (Server Component)
import { CounterButton } from "./counter-button";
export default function Page() {
  return <div><h1>Counter</h1><CounterButton /></div>;
}
```

### Problem: "Cannot import Server Component into Client Component"

**Cause:** Client Components cannot import Server Components.

**Fix:** Pass server components as children or props:

```tsx
// ❌ Wrong
"use client";
import { ServerData } from "./server-data"; // Error!

// ✅ Fix: composition via children
"use client";
export function ClientWrapper({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = useState(true);
  return open ? <div>{children}</div> : null;
}

// In a Server Component:
import { ClientWrapper } from "./client-wrapper";
import { ServerData } from "./server-data";

export default function Page() {
  return (
    <ClientWrapper>
      <ServerData /> {/* Server Component passed as children */}
    </ClientWrapper>
  );
}
```

### Problem: "use client" marks the entire subtree as client

**Cause:** Placing `"use client"` too high in the component tree.

**Fix:** Push `"use client"` to leaf components. Only the interactive pieces need it.

```tsx
// ❌ Bad: entire page is client
// app/dashboard/page.tsx
"use client"; // Everything below ships JS

// ✅ Good: only interactive parts are client
// app/dashboard/page.tsx (Server Component)
import { SearchBar } from "./search-bar"; // "use client" in this file only
import { DataTable } from "./data-table"; // Server Component

export default async function Page() {
  const data = await fetchData(); // Works! This is a Server Component
  return <div><SearchBar /><DataTable data={data} /></div>;
}
```

---

## Hydration Mismatches

### Problem: "Text content does not match server-rendered HTML"

**Common causes and fixes:**

```tsx
// ❌ Cause 1: Date/time rendering
export default function Page() {
  return <p>Current time: {new Date().toLocaleTimeString()}</p>;
  // Server and client render different times
}

// ✅ Fix: render time-sensitive content only on client
"use client";
import { useState, useEffect } from "react";
export function CurrentTime() {
  const [time, setTime] = useState<string>();
  useEffect(() => setTime(new Date().toLocaleTimeString()), []);
  return <p>Current time: {time ?? "Loading..."}</p>;
}
```

```tsx
// ❌ Cause 2: Browser-only globals
export default function Page() {
  return <p>Width: {window.innerWidth}</p>; // window undefined on server
}

// ✅ Fix: guard with useEffect
"use client";
import { useState, useEffect } from "react";
export function WindowWidth() {
  const [width, setWidth] = useState(0);
  useEffect(() => setWidth(window.innerWidth), []);
  return <p>Width: {width}</p>;
}
```

```tsx
// ❌ Cause 3: Conditional rendering based on typeof window
export function Nav() {
  if (typeof window !== "undefined") {
    return <MobileNav />; // Different on server vs client
  }
  return <DesktopNav />;
}

// ✅ Fix: use useEffect for client detection
"use client";
export function Nav() {
  const [isMobile, setIsMobile] = useState(false);
  useEffect(() => {
    setIsMobile(window.innerWidth < 768);
  }, []);
  return isMobile ? <MobileNav /> : <DesktopNav />;
}
```

```tsx
// ❌ Cause 4: Invalid HTML nesting
<p><div>nested block in inline</div></p>
// ✅ Fix: use valid HTML nesting
<div><div>nested block in block</div></div>
```

### Debugging Hydration Errors

1. Check browser console — React 18+ shows detailed hydration mismatch info
2. Use `suppressHydrationWarning` ONLY for expected differences (e.g., timestamps)
3. Search for `typeof window`, `navigator`, `document`, `localStorage` in shared render paths
4. Check third-party components for browser-only code

---

## Caching Unexpected Behavior

### Problem: Stale data after mutation

**Cause:** Forgot to revalidate after mutating data.

```tsx
// ❌ Missing revalidation
"use server";
export async function updateUser(formData: FormData) {
  await db.user.update({ where: { id: "1" }, data: { name: formData.get("name") as string } });
  // Data updates in DB but page still shows old data
}

// ✅ Fix: revalidate after mutation
"use server";
import { revalidatePath } from "next/cache";
export async function updateUser(formData: FormData) {
  await db.user.update({ where: { id: "1" }, data: { name: formData.get("name") as string } });
  revalidatePath("/profile"); // Purge cached page
}
```

### Problem: Data always stale despite revalidation

**Cause:** Multiple caching layers. Router Cache on client may still serve stale data.

```tsx
// Force client-side cache refresh
"use client";
import { useRouter } from "next/navigation";

export function RefreshButton() {
  const router = useRouter();
  return <button onClick={() => router.refresh()}>Refresh</button>;
  // router.refresh() bypasses Router Cache
}
```

### Problem: fetch() not caching when expected (Next.js 15)

**Cause:** Next.js 15 changed default — `fetch()` is NOT cached by default.

```tsx
// Next.js 14: cached by default
const data = await fetch("https://api.example.com/data"); // cached

// Next.js 15: NOT cached by default
const data = await fetch("https://api.example.com/data"); // fresh every request

// ✅ Opt in to caching
const data = await fetch("https://api.example.com/data", {
  cache: "force-cache", // or next: { revalidate: 3600 }
});
```

### Problem: unstable_cache not invalidating

```tsx
// ✅ Ensure tags match exactly
const getData = unstable_cache(
  async () => db.items.findMany(),
  ["items"],           // cache key
  { tags: ["items"] }  // revalidation tag
);

// Must use exact same tag to invalidate
revalidateTag("items"); // ✅ matches
revalidateTag("item");  // ❌ doesn't match
```

### Debugging Caching

1. Add `logging.fetches` to next.config.ts: `{ logging: { fetches: { fullUrl: true } } }`
2. Check build output: `○` = static, `λ` = dynamic, `●` = ISR
3. Check response headers: `x-nextjs-cache` header shows HIT/MISS/STALE
4. Use `cache: "no-store"` temporarily to confirm data source is correct

---

## Server Action Errors

### Problem: "Server actions must be async functions"

```tsx
// ❌ Wrong
"use server";
export function updateName(formData: FormData) { /* ... */ }

// ✅ Fix: must be async
"use server";
export async function updateName(formData: FormData) { /* ... */ }
```

### Problem: "Cannot find server action" or action not executing

**Causes:**
1. Missing `"use server"` directive
2. Server action not exported
3. Importing from wrong file

```tsx
// ✅ File-level directive: all exports are server actions
"use server";
export async function action1() { /* ... */ }
export async function action2() { /* ... */ }

// ✅ Function-level directive: inline in Server Component
export default function Page() {
  async function handleSubmit(formData: FormData) {
    "use server";
    // ...
  }
  return <form action={handleSubmit}>...</form>;
}
```

### Problem: Server action returns non-serializable data

**Cause:** Server actions can only return serializable values (JSON-compatible).

```tsx
// ❌ Wrong: returning Date object, Map, Set, class instances
export async function getUser() {
  "use server";
  return { name: "Alice", joinedAt: new Date() }; // Date is not serializable
}

// ✅ Fix: serialize before returning
export async function getUser() {
  "use server";
  const user = await db.user.findFirst();
  return { name: user.name, joinedAt: user.joinedAt.toISOString() };
}
```

### Problem: Server action form data is empty

```tsx
// ❌ Missing name attribute
<input type="text" /> // formData.get("name") → null

// ✅ Fix: add name attribute
<input type="text" name="username" /> // formData.get("username") → "value"
```

---

## Middleware Issues

### Problem: Middleware cold starts / slow middleware

**Cause:** Middleware runs on Edge Runtime with cold start overhead.

**Fixes:**
- Keep middleware minimal — auth token check, redirect, header set
- Don't import heavy libraries (no Zod, no ORM)
- Use `matcher` to limit which routes trigger middleware
- Avoid `fetch()` calls in middleware when possible

```tsx
// ✅ Optimal matcher — skip static assets
export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
```

### Problem: Middleware can't access Node.js APIs

**Cause:** Middleware uses Edge Runtime, which doesn't support Node.js APIs.

```tsx
// ❌ Won't work in middleware
import { readFileSync } from "fs";      // No filesystem
import { createHash } from "crypto";    // No node:crypto

// ✅ Use Web APIs instead
const hash = await crypto.subtle.digest("SHA-256", data); // Web Crypto API
```

### Problem: Infinite redirect loop in middleware

```tsx
// ❌ Causes loop: redirects /login to /login
export function middleware(request: NextRequest) {
  const token = request.cookies.get("session")?.value;
  if (!token) {
    return NextResponse.redirect(new URL("/login", request.url));
  }
}

// ✅ Fix: exclude the redirect target
export function middleware(request: NextRequest) {
  const token = request.cookies.get("session")?.value;
  if (!token && !request.nextUrl.pathname.startsWith("/login")) {
    return NextResponse.redirect(new URL("/login", request.url));
  }
}
```

---

## Static Generation Failures

### Problem: "Dynamic server usage" during static build

**Cause:** Using dynamic functions (`cookies()`, `headers()`, `searchParams`) in a statically-generated route.

```tsx
// ❌ Forces dynamic rendering
import { cookies } from "next/headers";

export default async function Page() {
  const cookieStore = await cookies();
  const theme = cookieStore.get("theme"); // Cannot know at build time
}

// ✅ Option 1: Make route dynamic
export const dynamic = "force-dynamic";

// ✅ Option 2: Move dynamic parts into Suspense boundaries (with PPR)
import { Suspense } from "react";

export default function Page() {
  return (
    <div>
      <StaticContent />
      <Suspense fallback={<div>Loading...</div>}>
        <DynamicThemedContent /> {/* cookies() call here */}
      </Suspense>
    </div>
  );
}
```

### Problem: generateStaticParams not generating expected pages

```tsx
// ✅ Ensure you return all expected params
export async function generateStaticParams() {
  const posts = await db.post.findMany({ select: { slug: true } });
  // Must return array of param objects
  return posts.map((post) => ({
    slug: post.slug, // key must match [slug] segment name
  }));
}

// For nested dynamic routes:
// app/blog/[category]/[slug]/page.tsx
export async function generateStaticParams() {
  const posts = await db.post.findMany({
    select: { category: true, slug: true },
  });
  return posts.map((post) => ({
    category: post.category,
    slug: post.slug,
  }));
}
```

### Problem: Build timeout for large number of static pages

```tsx
// ✅ Use dynamicParams to generate on-demand
export const dynamicParams = true; // default — generates at request time if not in generateStaticParams

// Generate only high-traffic pages at build time
export async function generateStaticParams() {
  const topPosts = await db.post.findMany({
    orderBy: { views: "desc" },
    take: 100, // Only prebuild top 100
    select: { slug: true },
  });
  return topPosts.map((post) => ({ slug: post.slug }));
}
```

---

## Dynamic Rendering When Static Expected

### Problem: Route is dynamic but should be static

**Diagnosis:** Check build output. `λ` = dynamic, `○` = static.

**Common causes of unwanted dynamic rendering:**

```tsx
// ❌ Cause 1: Uncached fetch (Next.js 15 default)
const data = await fetch("https://api.example.com/data");
// ✅ Fix: cache it
const data = await fetch("https://api.example.com/data", { cache: "force-cache" });

// ❌ Cause 2: Using cookies() or headers()
import { cookies } from "next/headers";
const theme = (await cookies()).get("theme");
// ✅ Fix: move to client component or Suspense boundary

// ❌ Cause 3: Using searchParams
export default async function Page({ searchParams }: { searchParams: Promise<{ q: string }> }) {
  const { q } = await searchParams;  // Forces dynamic
}
// ✅ Fix: use client-side useSearchParams() if page should be static

// ❌ Cause 4: noStore() or connection()
import { unstable_noStore as noStore } from "next/cache";
noStore(); // Forces dynamic
```

**Debug with segment config:**

```tsx
// Force static to find what's breaking
export const dynamic = "force-static"; // Build error will point to dynamic usage
```

---

## Large Bundle Size Diagnosis

### Analyze Bundle

```bash
# Install and run bundle analyzer
npm install @next/bundle-analyzer
```

```ts
// next.config.ts
import withBundleAnalyzer from "@next/bundle-analyzer";

const nextConfig = {};

export default process.env.ANALYZE === "true"
  ? withBundleAnalyzer({ enabled: true })(nextConfig)
  : nextConfig;
```

```bash
ANALYZE=true npm run build
```

### Common Fixes

```tsx
// ❌ Importing entire library
import { format } from "date-fns"; // imports ALL of date-fns

// ✅ Import specific function
import format from "date-fns/format";

// ❌ Large client-side import
import { marked } from "marked"; // ships to client

// ✅ Use dynamic import with ssr: false
const Markdown = dynamic(() => import("@/components/markdown-renderer"), {
  ssr: false,
});

// ❌ Including server-only code in client bundle
"use client";
import { db } from "@/lib/db"; // Prisma client in browser bundle!

// ✅ Use server-only package to prevent this
// lib/db.ts
import "server-only"; // Throws build error if imported in client component
import { PrismaClient } from "@prisma/client";
export const db = new PrismaClient();
```

### Check What's in Client Bundle

```bash
# Check specific page bundle
npx next build --debug
# Look at .next/analyze/ for treemap
```

---

## Memory Issues During Build

### Problem: JavaScript heap out of memory

```bash
# Increase Node.js memory limit
NODE_OPTIONS="--max-old-space-size=8192" npm run build

# Or in package.json
{
  "scripts": {
    "build": "NODE_OPTIONS='--max-old-space-size=8192' next build"
  }
}
```

### Common Causes

1. **Too many static pages:** Reduce `generateStaticParams` output, use `dynamicParams: true`
2. **Large images imported directly:** Use `next/image` with remote URLs instead of static imports
3. **Heavy dependencies in build:** Check for unnecessary `import` in server components
4. **Circular dependencies:** Use `npx madge --circular ./app` to detect

---

## Image Optimization Errors

### Problem: "Invalid src prop on next/image"

```tsx
// ❌ Remote image without configured domain
<Image src="https://random-cdn.com/photo.jpg" alt="" width={800} height={600} />

// ✅ Fix: add to next.config.ts
const nextConfig = {
  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "random-cdn.com",
        pathname: "/**",
      },
    ],
  },
};
```

### Problem: Image optimization not working in production (self-hosted)

```tsx
// ✅ Option 1: Use a CDN loader
const nextConfig = {
  images: {
    loader: "custom",
    loaderFile: "./lib/image-loader.ts",
  },
};

// lib/image-loader.ts
export default function cloudinaryLoader({
  src,
  width,
  quality,
}: {
  src: string;
  width: number;
  quality?: number;
}) {
  const params = [`w_${width}`, `q_${quality || 75}`];
  return `https://res.cloudinary.com/demo/image/upload/${params.join(",")}/${src}`;
}
```

```tsx
// ✅ Option 2: Disable optimization for static export
const nextConfig = {
  images: {
    unoptimized: true, // required for output: "export"
  },
};
```

### Problem: "Unable to optimize image" in development

**Cause:** Sharp not installed or incompatible.

```bash
npm install sharp
# For specific platforms:
npm install --platform=linux --arch=x64 sharp
```

---

## Deployment Issues

### Vercel vs Self-Hosted Differences

| Feature | Vercel | Self-Hosted |
|---------|--------|-------------|
| ISR | Automatic | Requires cache handler |
| Image Optimization | Built-in CDN | Needs Sharp installed |
| Middleware | Edge network | Single Node.js process |
| Streaming | Full support | Requires Node 18+ |
| `revalidateTag` | Distributed | Single-server only (unless custom cache) |

### Problem: ISR not working on self-hosted

```ts
// next.config.ts — custom cache handler for self-hosted ISR
const nextConfig = {
  cacheHandler: require.resolve("./cache-handler.mjs"),
  cacheMaxMemorySize: 0, // disable in-memory cache, use custom handler
};
```

```js
// cache-handler.mjs (Redis example)
import { createClient } from "redis";

const client = createClient({ url: process.env.REDIS_URL });
await client.connect();

export default class CacheHandler {
  async get(key) {
    const data = await client.get(key);
    return data ? JSON.parse(data) : null;
  }

  async set(key, data, ctx) {
    const ttl = ctx.revalidate || 60;
    await client.set(key, JSON.stringify(data), { EX: ttl });
  }

  async revalidateTag(tags) {
    // Implement tag-based invalidation
    for (const tag of tags) {
      const keys = await client.sMembers(`tag:${tag}`);
      for (const key of keys) {
        await client.del(key);
      }
    }
  }
}
```

### Problem: Environment variables not available

```bash
# ❌ Client-side access to server variable
console.log(process.env.DATABASE_URL); // undefined in browser

# ✅ Use NEXT_PUBLIC_ prefix for client-side variables
NEXT_PUBLIC_API_URL=https://api.example.com  # Available in browser
DATABASE_URL=postgresql://...                 # Server only

# ❌ Build-time vs runtime confusion
# NEXT_PUBLIC_ vars are inlined at BUILD time, not runtime
# If you need runtime client vars, use a route handler or env endpoint
```

### Problem: Docker container crashes with standalone output

```dockerfile
# ✅ Correct standalone Dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production

# standalone output includes required node_modules
COPY --from=builder /app/.next/standalone ./
# static and public must be copied separately
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
CMD ["node", "server.js"]
```

---

## TypeScript Strict Mode Conflicts

### Problem: params/searchParams type errors (Next.js 15)

```tsx
// ❌ Next.js 14 types (no longer correct in 15)
export default function Page({ params }: { params: { slug: string } }) {
  return <p>{params.slug}</p>;
}

// ✅ Next.js 15: params is Promise
export default async function Page({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  return <p>{slug}</p>;
}
```

### Problem: Metadata types

```tsx
import type { Metadata, ResolvingMetadata } from "next";

// ✅ Correct generateMetadata signature
export async function generateMetadata(
  { params }: { params: Promise<{ slug: string }> },
  parent: ResolvingMetadata
): Promise<Metadata> {
  const { slug } = await params;
  const post = await getPost(slug);
  const parentMetadata = await parent;

  return {
    title: post.title,
    openGraph: {
      images: [post.image, ...(parentMetadata.openGraph?.images || [])],
    },
  };
}
```

### Problem: Route handler types

```tsx
// ✅ Correct route handler types
import { type NextRequest, NextResponse } from "next/server";

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  return NextResponse.json({ id });
}
```

---

## Third-Party Library RSC Compatibility

### Problem: "Module not found" or "X is not a function" with RSC

**Cause:** Many libraries use browser APIs or React hooks internally and don't support Server Components.

### Check Compatibility

```tsx
// ❌ Library uses useState internally
import DatePicker from "react-datepicker"; // Error in Server Component

// ✅ Fix 1: wrap in client component
// components/date-picker-wrapper.tsx
"use client";
import DatePicker from "react-datepicker";
export { DatePicker };

// ✅ Fix 2: dynamic import with ssr: false
import dynamic from "next/dynamic";
const DatePicker = dynamic(() => import("react-datepicker"), { ssr: false });
```

### Common Libraries Requiring "use client" Wrappers

| Library | Needs Client Wrapper | Notes |
|---------|---------------------|-------|
| `react-hook-form` | Yes | Uses hooks extensively |
| `framer-motion` | Yes | Browser APIs + hooks |
| `react-query / @tanstack/react-query` | Yes | Client-side state |
| `zustand` | Yes | Client-side store |
| `react-hot-toast` | Yes | DOM manipulation |
| `chart.js / recharts` | Yes | Canvas/SVG rendering |
| `react-markdown` | Partial | Works in RSC if no plugins need client |
| `date-fns` | No | Pure functions, RSC-safe |
| `zod` | No | Pure validation, RSC-safe |
| `clsx / tailwind-merge` | No | Pure functions, RSC-safe |

### Pattern: Provider Wrapper

```tsx
// components/providers.tsx
"use client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ThemeProvider } from "next-themes";
import { Toaster } from "react-hot-toast";

const queryClient = new QueryClient();

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <QueryClientProvider client={queryClient}>
      <ThemeProvider attribute="class" defaultTheme="system">
        {children}
        <Toaster />
      </ThemeProvider>
    </QueryClientProvider>
  );
}

// app/layout.tsx (Server Component)
import { Providers } from "@/components/providers";

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
```

### Using `server-only` Package

Prevent server code from accidentally being imported in client components:

```bash
npm install server-only
```

```tsx
// lib/db.ts
import "server-only"; // Build error if imported in "use client" file

import { PrismaClient } from "@prisma/client";
export const db = new PrismaClient();
```

```tsx
// lib/secrets.ts
import "server-only";

export function getSecretKey() {
  return process.env.SECRET_KEY!;
}
```
