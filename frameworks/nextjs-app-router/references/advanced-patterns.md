# Advanced Next.js App Router Patterns

## Table of Contents

- [Parallel Routes Deep Dive](#parallel-routes-deep-dive)
- [Intercepting Routes](#intercepting-routes)
- [Route Handlers with Streaming](#route-handlers-with-streaming)
- [Server Action Patterns](#server-action-patterns)
- [Partial Prerendering (PPR)](#partial-prerendering-ppr)
- [React cache + unstable_cache](#react-cache--unstable_cache)
- [On-Demand ISR](#on-demand-isr)
- [Internationalization (i18n Routing)](#internationalization-i18n-routing)
- [Multi-Tenant Architecture](#multi-tenant-architecture)
- [Composing Layouts](#composing-layouts)
- [Error Boundaries Hierarchy](#error-boundaries-hierarchy)
- [Middleware Patterns](#middleware-patterns)

---

## Parallel Routes Deep Dive

Parallel routes render multiple pages in the same layout simultaneously via `@slot` folders. The layout receives each slot as a named prop alongside `children`.

### Basic Setup

```
app/dashboard/
  layout.tsx              # receives children + slot props
  page.tsx                # children slot (default)
  @analytics/
    page.tsx              # analytics slot
    loading.tsx           # independent loading state
  @team/
    page.tsx              # team slot
    error.tsx             # independent error boundary
```

```tsx
// app/dashboard/layout.tsx
export default function DashboardLayout({
  children,
  analytics,
  team,
}: {
  children: React.ReactNode;
  analytics: React.ReactNode;
  team: React.ReactNode;
}) {
  return (
    <div>
      <main>{children}</main>
      <aside className="grid grid-cols-2 gap-4">
        {analytics}
        {team}
      </aside>
    </div>
  );
}
```

### Modal Pattern with @modal

The most common parallel route pattern — show a modal overlay while preserving the background page.

```
app/
  layout.tsx
  page.tsx                       # feed page
  @modal/
    (.)photo/[id]/page.tsx       # modal intercept
    default.tsx                  # return null when no modal
  photo/[id]/
    page.tsx                     # full photo page (direct navigation)
```

```tsx
// app/layout.tsx
export default function RootLayout({
  children,
  modal,
}: {
  children: React.ReactNode;
  modal: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>
        {children}
        {modal}
      </body>
    </html>
  );
}
```

```tsx
// app/@modal/(.)photo/[id]/page.tsx
import { Modal } from "@/components/modal";
import { getPhoto } from "@/lib/data";

export default async function PhotoModal({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const photo = await getPhoto(id);

  return (
    <Modal>
      <img src={photo.url} alt={photo.alt} />
      <p>{photo.description}</p>
    </Modal>
  );
}
```

```tsx
// app/@modal/default.tsx — REQUIRED: renders nothing when no modal is active
export default function Default() {
  return null;
}
```

### Conditional Rendering with Parallel Routes

Use parallel routes to render different UI based on auth state or feature flags without client-side checks.

```tsx
// app/dashboard/layout.tsx
import { auth } from "@/auth";

export default async function Layout({
  children,
  admin,
  viewer,
}: {
  children: React.ReactNode;
  admin: React.ReactNode;
  viewer: React.ReactNode;
}) {
  const session = await auth();
  const isAdmin = session?.user?.role === "admin";

  return (
    <div>
      {children}
      {isAdmin ? admin : viewer}
    </div>
  );
}
```

### default.tsx Explained

When navigating client-side, Next.js preserves slot state. On hard refresh (full page load), slots without a matching `page.tsx` for the current URL need a `default.tsx` — otherwise Next.js returns 404.

**Rule:** Every `@slot` folder should have a `default.tsx` that returns `null` or a sensible fallback.

---

## Intercepting Routes

Intercepting routes let you load a route from another part of the app within the current layout — used for modals, previews, and inline expansions.

### Convention Prefixes

| Prefix | Intercepts |
|--------|------------|
| `(.)` | Same level |
| `(..)` | One level up |
| `(..)(..)` | Two levels up |
| `(...)` | From app root |

### Photo Gallery Modal Pattern

```
app/
  layout.tsx
  @modal/
    (.)photo/[id]/page.tsx      # intercepted: show as modal
    default.tsx
  feed/
    page.tsx                     # contains <Link href="/photo/123">
  photo/[id]/
    page.tsx                     # direct URL: full page
```

Soft navigation (clicking link) → intercepted route renders in `@modal` slot.
Hard navigation (direct URL, refresh) → `photo/[id]/page.tsx` renders as full page.

### Shopping Cart Slide-Over

```
app/
  layout.tsx
  @drawer/
    (.)cart/page.tsx             # slide-over cart
    default.tsx
  cart/
    page.tsx                     # full cart page
  products/
    page.tsx
```

```tsx
// app/@drawer/(.)cart/page.tsx
"use client";
import { useRouter } from "next/navigation";

export default function CartDrawer() {
  const router = useRouter();
  return (
    <div className="fixed inset-y-0 right-0 w-96 bg-white shadow-xl">
      <button onClick={() => router.back()}>Close</button>
      {/* Cart contents */}
    </div>
  );
}
```

---

## Route Handlers with Streaming

Route handlers can stream responses using Web Streams API for real-time data, SSE, and large payloads.

### Server-Sent Events (SSE)

```tsx
// app/api/events/route.ts
export const runtime = "nodejs"; // required for long-lived connections

export async function GET() {
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    async start(controller) {
      const send = (data: object) => {
        controller.enqueue(
          encoder.encode(`data: ${JSON.stringify(data)}\n\n`)
        );
      };

      // Send heartbeat every 30s
      const heartbeat = setInterval(() => send({ type: "ping" }), 30000);

      // Example: stream DB changes
      const unsubscribe = subscribeToChanges((change) => {
        send({ type: "update", payload: change });
      });

      // Cleanup on client disconnect
      // Note: AbortSignal not available in all runtimes
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    },
  });
}
```

### Streaming JSON (NDJSON)

```tsx
// app/api/export/route.ts
export async function GET() {
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    async start(controller) {
      const cursor = db.user.findManyCursor({ batchSize: 100 });
      for await (const batch of cursor) {
        for (const user of batch) {
          controller.enqueue(encoder.encode(JSON.stringify(user) + "\n"));
        }
      }
      controller.close();
    },
  });

  return new Response(stream, {
    headers: { "Content-Type": "application/x-ndjson" },
  });
}
```

---

## Server Action Patterns

### Optimistic Updates

Use `useOptimistic` to show immediate UI feedback while the server action runs.

```tsx
"use client";
import { useOptimistic } from "react";
import { toggleLike } from "@/app/actions";

export function LikeButton({
  postId,
  initialLiked,
  initialCount,
}: {
  postId: string;
  initialLiked: boolean;
  initialCount: number;
}) {
  const [optimistic, setOptimistic] = useOptimistic(
    { liked: initialLiked, count: initialCount },
    (state, newLiked: boolean) => ({
      liked: newLiked,
      count: state.count + (newLiked ? 1 : -1),
    })
  );

  async function handleToggle() {
    setOptimistic(!optimistic.liked);
    await toggleLike(postId);
  }

  return (
    <form action={handleToggle}>
      <button type="submit">
        {optimistic.liked ? "❤️" : "🤍"} {optimistic.count}
      </button>
    </form>
  );
}
```

### Progressive Enhancement

Server Actions work without JavaScript — forms submit as POST requests.

```tsx
// app/actions.ts
"use server";
import { redirect } from "next/navigation";
import { z } from "zod";

const schema = z.object({
  email: z.string().email(),
  message: z.string().min(10).max(1000),
});

export async function submitContact(formData: FormData) {
  const result = schema.safeParse({
    email: formData.get("email"),
    message: formData.get("message"),
  });

  if (!result.success) {
    return { errors: result.error.flatten().fieldErrors };
  }

  await db.contact.create({ data: result.data });
  redirect("/thank-you");
}
```

```tsx
// app/contact/page.tsx — works with JS disabled
import { submitContact } from "@/app/actions";

export default function ContactPage() {
  return (
    <form action={submitContact}>
      <input name="email" type="email" required />
      <textarea name="message" required minLength={10} />
      <button type="submit">Send</button>
    </form>
  );
}
```

### File Upload via Server Action

```tsx
"use server";

export async function uploadFile(formData: FormData) {
  const file = formData.get("file") as File;
  if (!file || file.size === 0) return { error: "No file provided" };

  const maxSize = 10 * 1024 * 1024; // 10MB
  if (file.size > maxSize) return { error: "File too large" };

  const allowedTypes = ["image/jpeg", "image/png", "image/webp"];
  if (!allowedTypes.includes(file.type)) return { error: "Invalid file type" };

  const bytes = await file.arrayBuffer();
  const buffer = Buffer.from(bytes);

  const filename = `${Date.now()}-${file.name}`;
  const path = `./public/uploads/${filename}`;
  await writeFile(path, buffer);

  return { url: `/uploads/${filename}` };
}
```

### useActionState for Form State

```tsx
"use client";
import { useActionState } from "react";
import { createUser } from "@/app/actions";

export function SignupForm() {
  const [state, formAction, isPending] = useActionState(createUser, {
    errors: {},
  });

  return (
    <form action={formAction}>
      <input name="email" />
      {state.errors?.email && <p className="text-red-500">{state.errors.email}</p>}
      <input name="password" type="password" />
      {state.errors?.password && <p className="text-red-500">{state.errors.password}</p>}
      <button type="submit" disabled={isPending}>
        {isPending ? "Creating..." : "Sign Up"}
      </button>
    </form>
  );
}
```

---

## Partial Prerendering (PPR)

PPR combines static and dynamic rendering in a single route. The static shell is served instantly from CDN; dynamic parts stream in via Suspense boundaries.

### Enable PPR

```ts
// next.config.ts
const nextConfig = {
  experimental: {
    ppr: true,
  },
};
export default nextConfig;
```

### Per-Route PPR (Incremental Adoption)

```tsx
// app/product/[id]/page.tsx
export const experimental_ppr = true;

import { Suspense } from "react";
import { ProductInfo } from "./product-info";
import { Reviews } from "./reviews";
import { RecommendedProducts } from "./recommended";

export default async function ProductPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;

  return (
    <div>
      {/* Static: prerendered at build */}
      <ProductInfo id={id} />

      {/* Dynamic: streams in at request time */}
      <Suspense fallback={<ReviewsSkeleton />}>
        <Reviews productId={id} />
      </Suspense>

      <Suspense fallback={<RecommendedSkeleton />}>
        <RecommendedProducts productId={id} />
      </Suspense>
    </div>
  );
}
```

**How it works:** Static parts become the prerendered shell. Each `<Suspense>` boundary that contains dynamic data (cookies, headers, uncached fetches) becomes a "hole" that streams in at request time.

---

## React cache + unstable_cache

### React `cache()` — Request-Level Dedup

Deduplicates calls within a single server render. Resets on every request.

```tsx
import { cache } from "react";
import { db } from "@/lib/db";

// Called in layout AND page — only hits DB once per request
export const getCurrentUser = cache(async () => {
  const session = await auth();
  if (!session?.user?.id) return null;
  return db.user.findUnique({
    where: { id: session.user.id },
    include: { preferences: true },
  });
});
```

### `unstable_cache` — Cross-Request Caching

Caches results across multiple requests with time-based or tag-based revalidation. This is the Data Cache for non-fetch data.

```tsx
import { unstable_cache } from "next/cache";
import { db } from "@/lib/db";

export const getCachedProducts = unstable_cache(
  async (category: string) => {
    return db.product.findMany({
      where: { category },
      orderBy: { createdAt: "desc" },
    });
  },
  ["products-by-category"],  // cache key prefix
  {
    revalidate: 3600,          // revalidate every hour
    tags: ["products"],        // invalidate with revalidateTag("products")
  }
);
```

### Combining Both

```tsx
import { cache } from "react";
import { unstable_cache } from "next/cache";

// Inner: cross-request cache with 1h TTL
const getProductsFromDB = unstable_cache(
  async (category: string) => db.product.findMany({ where: { category } }),
  ["products"],
  { revalidate: 3600, tags: ["products"] }
);

// Outer: dedup within a single request
export const getProducts = cache(async (category: string) => {
  return getProductsFromDB(category);
});
```

---

## On-Demand ISR

Revalidate specific pages or cache tags programmatically — from webhooks, Server Actions, or Route Handlers.

### Path-Based Revalidation

```tsx
// app/api/revalidate/route.ts
import { revalidatePath } from "next/cache";
import { NextRequest, NextResponse } from "next/server";

export async function POST(request: NextRequest) {
  const secret = request.headers.get("x-revalidate-secret");
  if (secret !== process.env.REVALIDATE_SECRET) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { path } = await request.json();
  revalidatePath(path);        // revalidate specific path
  // revalidatePath("/", "layout");  // revalidate everything

  return NextResponse.json({ revalidated: true, now: Date.now() });
}
```

### Tag-Based Revalidation

```tsx
// Data fetching with tag
const posts = await fetch("https://api.example.com/posts", {
  next: { tags: ["posts"] },
});

// Revalidation endpoint
import { revalidateTag } from "next/cache";

export async function POST(request: NextRequest) {
  const { tag } = await request.json();
  revalidateTag(tag); // invalidate all entries with this tag
  return NextResponse.json({ revalidated: true });
}
```

### CMS Webhook Pattern

```tsx
// app/api/cms-webhook/route.ts
import { revalidateTag } from "next/cache";
import { headers } from "next/headers";

export async function POST(request: NextRequest) {
  const headersList = await headers();
  const signature = headersList.get("x-webhook-signature");

  if (!verifySignature(signature, await request.text())) {
    return NextResponse.json({ error: "Invalid signature" }, { status: 401 });
  }

  const { type, slug } = await request.json();

  switch (type) {
    case "post.published":
    case "post.updated":
      revalidateTag(`post-${slug}`);
      revalidateTag("posts-list");
      break;
    case "post.deleted":
      revalidateTag("posts-list");
      break;
  }

  return NextResponse.json({ revalidated: true });
}
```

---

## Internationalization (i18n Routing)

Next.js App Router doesn't have built-in i18n routing. Use middleware + route groups.

### Middleware-Based Locale Detection

```tsx
// middleware.ts
import { NextRequest, NextResponse } from "next/server";
import { match } from "@formatjs/intl-localematcher";
import Negotiator from "negotiator";

const locales = ["en", "es", "fr", "de"];
const defaultLocale = "en";

function getLocale(request: NextRequest): string {
  const headers = { "accept-language": request.headers.get("accept-language") || "" };
  const languages = new Negotiator({ headers }).languages();
  return match(languages, locales, defaultLocale);
}

export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Check if pathname has a locale
  const hasLocale = locales.some(
    (locale) => pathname.startsWith(`/${locale}/`) || pathname === `/${locale}`
  );
  if (hasLocale) return;

  // Redirect to locale-prefixed path
  const locale = getLocale(request);
  request.nextUrl.pathname = `/${locale}${pathname}`;
  return NextResponse.redirect(request.nextUrl);
}

export const config = {
  matcher: ["/((?!_next|api|favicon.ico).*)"],
};
```

### File Structure

```
app/
  [lang]/
    layout.tsx
    page.tsx
    about/
      page.tsx
    dictionaries/
      en.json
      es.json
      fr.json
```

### Dictionary Loading

```tsx
// app/[lang]/dictionaries.ts
const dictionaries = {
  en: () => import("./dictionaries/en.json").then((m) => m.default),
  es: () => import("./dictionaries/es.json").then((m) => m.default),
  fr: () => import("./dictionaries/fr.json").then((m) => m.default),
};

export const getDictionary = async (locale: string) => {
  return dictionaries[locale as keyof typeof dictionaries]();
};
```

```tsx
// app/[lang]/page.tsx
import { getDictionary } from "./dictionaries";

export default async function Home({
  params,
}: {
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  const dict = await getDictionary(lang);
  return <h1>{dict.home.title}</h1>;
}

export async function generateStaticParams() {
  return [{ lang: "en" }, { lang: "es" }, { lang: "fr" }];
}
```

---

## Multi-Tenant Architecture

Serve different tenants from the same Next.js app using subdomains or path prefixes.

### Subdomain-Based Tenancy

```tsx
// middleware.ts
import { NextRequest, NextResponse } from "next/server";

export function middleware(request: NextRequest) {
  const hostname = request.headers.get("host") || "";
  const subdomain = hostname.split(".")[0];

  // Skip for main domain and special subdomains
  if (subdomain === "www" || subdomain === "app" || !subdomain) {
    return NextResponse.next();
  }

  // Rewrite to tenant-specific path
  const url = request.nextUrl.clone();
  url.pathname = `/tenant/${subdomain}${url.pathname}`;
  return NextResponse.rewrite(url);
}
```

```
app/
  tenant/
    [domain]/
      layout.tsx       # loads tenant config/theme
      page.tsx
      settings/
        page.tsx
```

```tsx
// app/tenant/[domain]/layout.tsx
import { getTenantConfig } from "@/lib/tenants";
import { notFound } from "next/navigation";

export default async function TenantLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ domain: string }>;
}) {
  const { domain } = await params;
  const tenant = await getTenantConfig(domain);
  if (!tenant) notFound();

  return (
    <div style={{ "--brand-color": tenant.brandColor } as React.CSSProperties}>
      <header>{tenant.name}</header>
      {children}
    </div>
  );
}
```

---

## Composing Layouts

### Nested Layout Patterns

Layouts compose automatically by nesting folders. Each layout wraps its children.

```
app/
  layout.tsx                    # Root: html, body, providers
  (marketing)/
    layout.tsx                  # Marketing: navbar, footer
    page.tsx
    pricing/page.tsx
  (app)/
    layout.tsx                  # App: sidebar, no footer
    dashboard/
      layout.tsx                # Dashboard: tabs
      page.tsx
      analytics/page.tsx
```

### Per-Route Layout Override

Use route groups to apply different root layouts.

```tsx
// app/(marketing)/layout.tsx
export default function MarketingLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <MarketingNavbar />
      <main>{children}</main>
      <Footer />
    </>
  );
}

// app/(app)/layout.tsx
export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <Sidebar />
      <main className="flex-1">{children}</main>
    </div>
  );
}
```

### Layout with Data

Layouts fetch data once — shared across all child routes without refetching.

```tsx
// app/(app)/layout.tsx
import { getCurrentUser } from "@/lib/auth";
import { redirect } from "next/navigation";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) redirect("/login");

  return (
    <div className="flex">
      <Sidebar user={user} />
      <main className="flex-1 p-6">{children}</main>
    </div>
  );
}
```

---

## Error Boundaries Hierarchy

Error boundaries in Next.js are hierarchical: `error.tsx` catches errors in its segment and children, but NOT in its own `layout.tsx`.

### Hierarchy

```
app/
  layout.tsx          ← NOT caught by app/error.tsx
  error.tsx           ← catches errors in app/page.tsx
  page.tsx
  global-error.tsx    ← catches errors in root layout (replaces entire <html>)
  dashboard/
    layout.tsx        ← caught by app/error.tsx
    error.tsx         ← catches errors in dashboard/page.tsx and below
    page.tsx
    settings/
      page.tsx        ← caught by dashboard/error.tsx
```

### global-error.tsx

Catches root layout errors. Must render its own `<html>` and `<body>`.

```tsx
// app/global-error.tsx
"use client";

export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <html>
      <body>
        <h2>Something went wrong!</h2>
        <p>Error: {error.message}</p>
        <button onClick={() => reset()}>Try again</button>
      </body>
    </html>
  );
}
```

### Error Recovery with reset()

```tsx
// app/dashboard/error.tsx
"use client";
import { useEffect } from "react";

export default function DashboardError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    // Log to error reporting service
    reportError(error);
  }, [error]);

  return (
    <div className="p-6 text-center">
      <h2>Dashboard Error</h2>
      <p className="text-gray-600">{error.message}</p>
      <button
        onClick={reset}
        className="mt-4 px-4 py-2 bg-blue-500 text-white rounded"
      >
        Retry
      </button>
    </div>
  );
}
```

---

## Middleware Patterns

### A/B Testing

```tsx
// middleware.ts
import { NextRequest, NextResponse } from "next/server";

export function middleware(request: NextRequest) {
  // Check for existing assignment
  let bucket = request.cookies.get("ab-bucket")?.value;

  if (!bucket) {
    // Assign randomly: 50/50 split
    bucket = Math.random() < 0.5 ? "control" : "variant";
  }

  const response = NextResponse.next();

  // Set cookie for sticky assignment (30 days)
  response.cookies.set("ab-bucket", bucket, {
    maxAge: 60 * 60 * 24 * 30,
    httpOnly: true,
    sameSite: "lax",
  });

  // Pass bucket to server components via header
  response.headers.set("x-ab-bucket", bucket);

  // Or rewrite to different page variant
  if (request.nextUrl.pathname === "/pricing" && bucket === "variant") {
    return NextResponse.rewrite(new URL("/pricing-v2", request.url));
  }

  return response;
}
```

### Geo-Routing

```tsx
// middleware.ts
export function middleware(request: NextRequest) {
  const country = request.geo?.country || "US";
  const city = request.geo?.city || "Unknown";

  // Country-based redirects
  const countryRedirects: Record<string, string> = {
    DE: "/de",
    FR: "/fr",
    JP: "/ja",
  };

  if (
    countryRedirects[country] &&
    !request.nextUrl.pathname.startsWith(countryRedirects[country])
  ) {
    return NextResponse.redirect(
      new URL(countryRedirects[country] + request.nextUrl.pathname, request.url)
    );
  }

  // Pass geo data to server components
  const response = NextResponse.next();
  response.headers.set("x-user-country", country);
  response.headers.set("x-user-city", city);
  return response;
}
```

### Bot Detection

```tsx
// middleware.ts
const BOT_PATTERNS = [
  /googlebot/i,
  /bingbot/i,
  /slurp/i,
  /duckduckbot/i,
  /baiduspider/i,
  /yandexbot/i,
  /facebookexternalhit/i,
  /twitterbot/i,
  /linkedinbot/i,
];

export function middleware(request: NextRequest) {
  const ua = request.headers.get("user-agent") || "";
  const isBot = BOT_PATTERNS.some((pattern) => pattern.test(ua));

  if (isBot) {
    // Serve pre-rendered content for SEO bots
    const response = NextResponse.next();
    response.headers.set("x-is-bot", "true");
    // Skip client-side hydration hints
    response.headers.set("x-middleware-cache", "no-cache");
    return response;
  }

  return NextResponse.next();
}
```

### Rate Limiting (Simple In-Memory)

```tsx
// middleware.ts
const rateLimit = new Map<string, { count: number; resetTime: number }>();

function isRateLimited(ip: string, limit = 100, windowMs = 60000): boolean {
  const now = Date.now();
  const record = rateLimit.get(ip);

  if (!record || now > record.resetTime) {
    rateLimit.set(ip, { count: 1, resetTime: now + windowMs });
    return false;
  }

  record.count++;
  return record.count > limit;
}

export function middleware(request: NextRequest) {
  if (request.nextUrl.pathname.startsWith("/api/")) {
    const ip = request.headers.get("x-forwarded-for") || "unknown";

    if (isRateLimited(ip)) {
      return NextResponse.json(
        { error: "Too many requests" },
        { status: 429, headers: { "Retry-After": "60" } }
      );
    }
  }

  return NextResponse.next();
}
```

### Combining Middleware Patterns

```tsx
// middleware.ts
import { NextRequest, NextResponse } from "next/server";

export function middleware(request: NextRequest) {
  const response = NextResponse.next();
  const pathname = request.nextUrl.pathname;

  // 1. Security headers (all routes)
  response.headers.set("X-Frame-Options", "DENY");
  response.headers.set("X-Content-Type-Options", "nosniff");
  response.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");

  // 2. Rate limit API routes
  if (pathname.startsWith("/api/")) {
    const ip = request.headers.get("x-forwarded-for") || "unknown";
    if (isRateLimited(ip)) {
      return NextResponse.json({ error: "Rate limited" }, { status: 429 });
    }
  }

  // 3. Auth check for protected routes
  if (pathname.startsWith("/dashboard") || pathname.startsWith("/settings")) {
    const token = request.cookies.get("session")?.value;
    if (!token) {
      const loginUrl = new URL("/login", request.url);
      loginUrl.searchParams.set("callbackUrl", pathname);
      return NextResponse.redirect(loginUrl);
    }
  }

  // 4. Geo-based locale
  const country = request.geo?.country;
  if (country) {
    response.headers.set("x-user-country", country);
  }

  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
```
