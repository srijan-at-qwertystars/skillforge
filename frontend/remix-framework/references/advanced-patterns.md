# Advanced Remix / React Router v7 Patterns

## Table of Contents

- [Optimistic UI with useFetcher](#optimistic-ui-with-usefetcher)
- [Parallel Loaders](#parallel-loaders)
- [Resource Routes for API Endpoints](#resource-routes-for-api-endpoints)
- [Streaming with defer](#streaming-with-defer)
- [Nested Error Boundaries](#nested-error-boundaries)
- [Route-Level Caching with headers](#route-level-caching-with-headers)
- [Meta Function Patterns](#meta-function-patterns)
- [Error Boundary Patterns (Route Error vs Unexpected)](#error-boundary-patterns)
- [Route Groups](#route-groups)
- [Pathless Layouts](#pathless-layouts)
- [Remix + React Router v7 Bridge Patterns](#remix--react-router-v7-bridge-patterns)

---

## Optimistic UI with useFetcher

Optimistic UI immediately reflects user intent before the server confirms. `useFetcher` is ideal because it doesn't trigger navigation and exposes `fetcher.formData` for reading submitted values.

### Basic Optimistic Toggle

```tsx
import { useFetcher } from "react-router";

function FavoriteButton({ item }: { item: { id: string; isFavorite: boolean } }) {
  const fetcher = useFetcher();

  // Use the optimistic value if a submission is in flight
  const isFavorite = fetcher.formData
    ? fetcher.formData.get("favorite") === "true"
    : item.isFavorite;

  return (
    <fetcher.Form method="post" action={`/items/${item.id}/favorite`}>
      <input type="hidden" name="favorite" value={String(!isFavorite)} />
      <button type="submit" aria-label={isFavorite ? "Remove favorite" : "Add favorite"}>
        {isFavorite ? "★" : "☆"}
      </button>
    </fetcher.Form>
  );
}
```

### Optimistic List with Multiple Fetchers

When items in a list can each be independently mutated:

```tsx
function TodoList({ todos }: { todos: Todo[] }) {
  return (
    <ul>
      {todos.map((todo) => (
        <TodoItem key={todo.id} todo={todo} />
      ))}
    </ul>
  );
}

function TodoItem({ todo }: { todo: Todo }) {
  const fetcher = useFetcher();
  const isDeleting = fetcher.formData != null;

  // Hide the item optimistically when deleting
  if (isDeleting) return null;

  const isCompleted = fetcher.formData
    ? fetcher.formData.get("completed") === "true"
    : todo.completed;

  return (
    <li style={{ opacity: fetcher.state === "submitting" ? 0.6 : 1 }}>
      <fetcher.Form method="post" action={`/todos/${todo.id}`}>
        <input type="hidden" name="completed" value={String(!isCompleted)} />
        <button type="submit">{isCompleted ? "✓" : "○"}</button>
        <span className={isCompleted ? "line-through" : ""}>{todo.title}</span>
      </fetcher.Form>
      <fetcher.Form method="post" action={`/todos/${todo.id}/delete`}>
        <button type="submit">🗑</button>
      </fetcher.Form>
    </li>
  );
}
```

### Optimistic Create with Pending Items

```tsx
function NewTodo() {
  const fetcher = useFetcher();
  const isAdding = fetcher.state === "submitting";

  return (
    <>
      {isAdding && (
        <li className="opacity-50">
          <span>{fetcher.formData?.get("title")}</span>
          <span>Adding...</span>
        </li>
      )}
      <fetcher.Form method="post" action="/todos">
        <input name="title" required placeholder="New todo..." />
        <button type="submit" disabled={isAdding}>Add</button>
      </fetcher.Form>
    </>
  );
}
```

### Error Recovery from Optimistic Updates

When an optimistic action fails, `fetcher.data` contains the error response and the UI reverts automatically:

```tsx
function LikeButton({ postId, likeCount }: { postId: string; likeCount: number }) {
  const fetcher = useFetcher<{ error?: string }>();

  const optimisticCount = fetcher.formData
    ? likeCount + 1
    : likeCount;

  return (
    <div>
      <fetcher.Form method="post" action={`/posts/${postId}/like`}>
        <button type="submit">♥ {optimisticCount}</button>
      </fetcher.Form>
      {fetcher.data?.error && <p className="text-red-500">{fetcher.data.error}</p>}
    </div>
  );
}
```

---

## Parallel Loaders

Remix automatically runs loaders for all matched routes in parallel. Maximize this by structuring routes so independent data fetches live in separate route segments.

### Nested Route Parallelism

```
routes/
  dashboard.tsx          → loader fetches user dashboard config
  dashboard.analytics.tsx → loader fetches analytics data
  dashboard.notifications.tsx → loader fetches notifications
```

Both `dashboard.tsx` and `dashboard.analytics.tsx` loaders execute simultaneously when visiting `/dashboard/analytics`.

### Manual Parallel Fetching Within a Loader

When a single loader needs multiple independent data sources:

```tsx
export async function loader({ params, request }: Route.LoaderArgs) {
  // Start all fetches simultaneously
  const [product, reviews, recommendations] = await Promise.all([
    getProduct(params.id),
    getReviews(params.id),
    getRecommendations(params.id),
  ]);

  if (!product) throw new Response("Not found", { status: 404 });
  return { product, reviews, recommendations };
}
```

### Hybrid: Parallel Critical + Streamed Non-Critical

```tsx
export async function loader({ params }: Route.LoaderArgs) {
  // Start all fetches immediately
  const productPromise = getProduct(params.id);
  const reviewsPromise = getReviews(params.id);
  const recommendationsPromise = getRecommendations(params.id);

  // Wait for critical data
  const product = await productPromise;
  if (!product) throw new Response("Not found", { status: 404 });

  // Return non-critical as promises (streamed)
  return {
    product,
    reviews: reviewsPromise,
    recommendations: recommendationsPromise,
  };
}
```

---

## Resource Routes for API Endpoints

Resource routes are route modules that don't export a default component. They serve as pure server endpoints.

### RESTful API Resource Route

```tsx
// app/routes/api.users.ts
import type { Route } from "./+types/api.users";

export async function loader({ request }: Route.LoaderArgs) {
  const url = new URL(request.url);
  const page = parseInt(url.searchParams.get("page") ?? "1");
  const limit = parseInt(url.searchParams.get("limit") ?? "20");
  const users = await db.user.findMany({ skip: (page - 1) * limit, take: limit });
  const total = await db.user.count();

  return Response.json({
    data: users,
    meta: { page, limit, total, totalPages: Math.ceil(total / limit) },
  });
}

export async function action({ request }: Route.ActionArgs) {
  switch (request.method) {
    case "POST": {
      const body = await request.json();
      const user = await db.user.create({ data: body });
      return Response.json(user, { status: 201 });
    }
    default:
      return new Response("Method not allowed", { status: 405 });
  }
}
```

### Image/File Serving Resource Route

```tsx
// app/routes/images.$id.ts
export async function loader({ params }: Route.LoaderArgs) {
  const image = await getImageFromStorage(params.id);
  if (!image) throw new Response("Not found", { status: 404 });

  return new Response(image.buffer, {
    headers: {
      "Content-Type": image.mimeType,
      "Cache-Control": "public, max-age=31536000, immutable",
      "Content-Length": String(image.size),
    },
  });
}
```

### Server-Sent Events (SSE) Resource Route

```tsx
// app/routes/sse.notifications.ts
export async function loader({ request }: Route.LoaderArgs) {
  const stream = new ReadableStream({
    start(controller) {
      const encoder = new TextEncoder();
      const send = (data: string) => {
        controller.enqueue(encoder.encode(`data: ${data}\n\n`));
      };

      const interval = setInterval(() => {
        send(JSON.stringify({ time: Date.now() }));
      }, 1000);

      request.signal.addEventListener("abort", () => {
        clearInterval(interval);
        controller.close();
      });
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

---

## Streaming with defer

Streaming lets you send the HTML shell immediately with critical data, then stream in non-critical data as it resolves.

### Multi-Stream Pattern

```tsx
import { Suspense } from "react";
import { Await } from "react-router";

export async function loader({ params }: Route.LoaderArgs) {
  // Start all fetches before awaiting anything
  const commentsPromise = getComments(params.id);
  const relatedPromise = getRelated(params.id);
  const statsPromise = getStats(params.id);

  // Only await what's needed for initial render
  const post = await getPost(params.id);
  if (!post) throw new Response("Not found", { status: 404 });

  return {
    post,
    comments: commentsPromise,
    related: relatedPromise,
    stats: statsPromise,
  };
}

export default function Post({ loaderData }: Route.ComponentProps) {
  return (
    <article>
      <h1>{loaderData.post.title}</h1>
      <p>{loaderData.post.content}</p>

      <Suspense fallback={<StatsSkeleton />}>
        <Await resolve={loaderData.stats}>
          {(stats) => <StatsPanel stats={stats} />}
        </Await>
      </Suspense>

      <Suspense fallback={<CommentsSkeleton />}>
        <Await resolve={loaderData.comments}>
          {(comments) => <CommentList comments={comments} />}
        </Await>
      </Suspense>

      <Suspense fallback={<RelatedSkeleton />}>
        <Await resolve={loaderData.related}>
          {(related) => <RelatedPosts posts={related} />}
        </Await>
      </Suspense>
    </article>
  );
}
```

### Error Handling in Streamed Data

```tsx
<Suspense fallback={<Spinner />}>
  <Await resolve={loaderData.comments} errorElement={<p>Could not load comments.</p>}>
    {(comments) => <CommentList comments={comments} />}
  </Await>
</Suspense>
```

### Conditional Streaming

Stream data only when it makes sense — don't stream above-the-fold content:

```tsx
export async function loader({ params, request }: Route.LoaderArgs) {
  const isBot = request.headers.get("User-Agent")?.includes("bot");

  const product = await getProduct(params.id);
  const reviews = isBot
    ? await getReviews(params.id)   // Await for bots/SEO
    : getReviews(params.id);        // Stream for users

  return { product, reviews };
}
```

---

## Nested Error Boundaries

Each route segment can export its own `ErrorBoundary`, creating granular error isolation.

### Layout-Preserving Error Boundaries

```
root.tsx (ErrorBoundary — last resort)
└── dashboard.tsx (ErrorBoundary — preserves nav)
    ├── dashboard.analytics.tsx (ErrorBoundary — only analytics fails)
    └── dashboard.settings.tsx (no ErrorBoundary — bubbles to dashboard)
```

When `dashboard.analytics.tsx` throws, only the analytics panel shows an error. The dashboard layout (nav, sidebar) remains functional.

### Root Error Boundary with Document Shell

```tsx
// app/root.tsx
export function ErrorBoundary() {
  const error = useRouteError();

  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Error</title>
      </head>
      <body>
        <div className="error-container">
          {isRouteErrorResponse(error) ? (
            <>
              <h1>{error.status}</h1>
              <p>{error.statusText}</p>
            </>
          ) : (
            <>
              <h1>Unexpected Error</h1>
              <p>{error instanceof Error ? error.message : "Unknown error"}</p>
            </>
          )}
          <a href="/">Go Home</a>
        </div>
      </body>
    </html>
  );
}
```

### Retry Pattern in Error Boundaries

```tsx
export function ErrorBoundary() {
  const error = useRouteError();
  const revalidator = useRevalidator();

  return (
    <div className="error-panel">
      <h2>Something went wrong</h2>
      <p>{error instanceof Error ? error.message : "Unknown error"}</p>
      <button
        onClick={() => revalidator.revalidate()}
        disabled={revalidator.state === "loading"}
      >
        {revalidator.state === "loading" ? "Retrying..." : "Try Again"}
      </button>
    </div>
  );
}
```

---

## Route-Level Caching with headers

The `headers` export controls HTTP caching per route. Remix uses the deepest matching route's headers by default.

### Static Content Caching

```tsx
export function headers(): HeadersInit {
  return {
    "Cache-Control": "public, max-age=3600, s-maxage=86400",
  };
}
```

### Dynamic Caching from Loader

```tsx
export function headers({ loaderHeaders }: Route.HeadersArgs) {
  return {
    "Cache-Control": loaderHeaders.get("Cache-Control") ?? "no-cache",
    "Server-Timing": loaderHeaders.get("Server-Timing") ?? "",
  };
}
```

### Parent-Child Header Merging

```tsx
export function headers({ loaderHeaders, parentHeaders }: Route.HeadersArgs) {
  // Use the shorter cache time between parent and child
  const parentMaxAge = parseCacheControl(parentHeaders.get("Cache-Control"));
  const childMaxAge = parseCacheControl(loaderHeaders.get("Cache-Control"));
  const maxAge = Math.min(parentMaxAge, childMaxAge);

  return {
    "Cache-Control": `public, max-age=${maxAge}`,
  };
}
```

### CDN Cache with Stale-While-Revalidate

```tsx
export function headers(): HeadersInit {
  return {
    "Cache-Control": "public, max-age=60, s-maxage=300, stale-while-revalidate=3600",
    Vary: "Cookie, Accept-Language",
  };
}
```

---

## Meta Function Patterns

The `meta` export returns an array of meta descriptors. Child routes override parent meta entirely (they don't merge).

### Basic SEO Meta

```tsx
export function meta({ data }: Route.MetaArgs) {
  if (!data) return [{ title: "Not Found" }];

  return [
    { title: `${data.post.title} | My Blog` },
    { name: "description", content: data.post.excerpt },
    { property: "og:title", content: data.post.title },
    { property: "og:description", content: data.post.excerpt },
    { property: "og:image", content: data.post.imageUrl },
    { property: "og:type", content: "article" },
    { name: "twitter:card", content: "summary_large_image" },
  ];
}
```

### Merging Parent Meta

To preserve parent meta while adding child-specific tags:

```tsx
export function meta({ data, matches }: Route.MetaArgs) {
  // Get parent meta, filtering out tags we want to override
  const parentMeta = matches.flatMap((match) => match.meta ?? []);
  const filtered = parentMeta.filter(
    (m) => !("title" in m) && !("name" in m && m.name === "description")
  );

  return [
    ...filtered,
    { title: data.product.name },
    { name: "description", content: data.product.description },
  ];
}
```

### Dynamic Canonical URL

```tsx
export function meta({ data, location }: Route.MetaArgs) {
  const canonicalUrl = `https://example.com${location.pathname}`;
  return [
    { title: data.page.title },
    { tagName: "link", rel: "canonical", href: canonicalUrl },
  ];
}
```

---

## Error Boundary Patterns

In React Router v7, `CatchBoundary` has been removed. Use `ErrorBoundary` + `isRouteErrorResponse` for all error handling.

### Distinguishing Error Types

```tsx
export function ErrorBoundary() {
  const error = useRouteError();

  // Thrown Response (expected errors: 404, 403, etc.)
  if (isRouteErrorResponse(error)) {
    switch (error.status) {
      case 404:
        return <NotFoundPage />;
      case 403:
        return <ForbiddenPage />;
      case 401:
        return <UnauthorizedPage />;
      default:
        return <GenericErrorPage status={error.status} message={error.statusText} />;
    }
  }

  // Thrown Error (unexpected failures)
  if (error instanceof Error) {
    return (
      <div>
        <h1>Application Error</h1>
        <pre>{error.stack}</pre>
      </div>
    );
  }

  // Unknown throw value
  return <h1>Unknown Error</h1>;
}
```

### Error Boundary with Logging

```tsx
export function ErrorBoundary() {
  const error = useRouteError();

  useEffect(() => {
    if (!isRouteErrorResponse(error)) {
      // Report unexpected errors to monitoring service
      reportError(error instanceof Error ? error : new Error(String(error)));
    }
  }, [error]);

  // ... render error UI
}
```

---

## Route Groups

Route groups organize routes without affecting the URL structure. Use `prefix` in `routes.ts` or pathless layout routes.

### Logical Grouping with routes.ts

```tsx
// app/routes.ts
import { type RouteConfig, route, index, layout, prefix } from "@react-router/dev/routes";

export default [
  // Public routes
  index("routes/home.tsx"),
  route("about", "routes/about.tsx"),
  route("pricing", "routes/pricing.tsx"),

  // Auth routes (share an auth layout)
  layout("routes/_auth/layout.tsx", [
    route("login", "routes/_auth/login.tsx"),
    route("register", "routes/_auth/register.tsx"),
    route("forgot-password", "routes/_auth/forgot-password.tsx"),
  ]),

  // Dashboard routes (authenticated, share dashboard layout)
  layout("routes/dashboard/layout.tsx", [
    ...prefix("dashboard", [
      index("routes/dashboard/index.tsx"),
      route("settings", "routes/dashboard/settings.tsx"),
      route("billing", "routes/dashboard/billing.tsx"),
    ]),
  ]),

  // Admin routes (separate layout, authorization check)
  layout("routes/admin/layout.tsx", [
    ...prefix("admin", [
      index("routes/admin/index.tsx"),
      route("users", "routes/admin/users.tsx"),
      route("users/:id", "routes/admin/user-detail.tsx"),
    ]),
  ]),
] satisfies RouteConfig;
```

### File-Based Route Groups (Flat Routes)

With `flatRoutes()`, use underscore prefix for pathless grouping:

```
routes/
  _index.tsx              → /
  _auth.tsx               → layout (no URL segment)
  _auth.login.tsx         → /login
  _auth.register.tsx      → /register
  _dashboard.tsx          → layout (no URL segment)
  _dashboard.overview.tsx → /overview
  _dashboard.settings.tsx → /settings
```

---

## Pathless Layouts

Pathless layouts wrap child routes with shared UI or data without adding a URL segment.

### Authentication Layout (Centered Card)

```tsx
// app/routes/_auth/layout.tsx
import { Outlet } from "react-router";

export default function AuthLayout() {
  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50">
      <div className="max-w-md w-full bg-white shadow-lg rounded-lg p-8">
        <Outlet />
      </div>
    </div>
  );
}
```

### Data-Providing Pathless Layout

```tsx
// app/routes/dashboard/layout.tsx
import { Outlet, redirect } from "react-router";
import type { Route } from "./+types/layout";

export async function loader({ request }: Route.LoaderArgs) {
  const user = await getUser(request);
  if (!user) throw redirect("/login");
  return { user, notifications: await getNotifications(user.id) };
}

export default function DashboardLayout({ loaderData }: Route.ComponentProps) {
  return (
    <div className="flex">
      <Sidebar user={loaderData.user} notifications={loaderData.notifications} />
      <main className="flex-1">
        <Outlet />
      </main>
    </div>
  );
}
```

---

## Remix + React Router v7 Bridge Patterns

### Gradual Migration Strategy

Run both import styles during migration using a shim:

```ts
// app/lib/remix-compat.ts
// Re-export everything from react-router so old imports still work
export {
  json,
  redirect,
  useLoaderData,
  useActionData,
  useFetcher,
  useNavigation,
  Form,
  Link,
  NavLink,
  Outlet,
  useSearchParams,
  useParams,
  useMatches,
  useRouteError,
  isRouteErrorResponse,
} from "react-router";
```

### Type Migration

```tsx
// Before (Remix v2):
import type { LoaderFunctionArgs, ActionFunctionArgs, MetaFunction } from "@remix-run/node";

export const loader = async ({ request }: LoaderFunctionArgs) => {
  return json({ data: await getData() });
};

export const meta: MetaFunction<typeof loader> = ({ data }) => {
  return [{ title: data?.data.title }];
};

// After (React Router v7):
import type { Route } from "./+types/my-route";

export async function loader({ request }: Route.LoaderArgs) {
  return { data: await getData() }; // No json() wrapper needed
}

export function meta({ data }: Route.MetaArgs) {
  return [{ title: data.data.title }];
}
```

### Single Fetch Migration

React Router v7 uses single fetch by default (one request for all loaders). Key differences:

- Responses are encoded with turbo-stream instead of JSON
- Return plain objects, not `json()` calls
- Headers and status codes use the `data()` utility:

```tsx
import { data } from "react-router";

export async function action({ request }: Route.ActionArgs) {
  const errors = validate(await request.formData());
  if (errors) {
    return data({ errors }, { status: 400 });
  }
  // ...
}
```

### Handling Both Old and New Route Conventions

During migration, you may have mixed route file conventions. Use `routes.ts` to explicitly map them:

```tsx
// app/routes.ts
import { type RouteConfig, route } from "@react-router/dev/routes";
import { flatRoutes } from "@react-router/fs-routes";

const fsRoutes = flatRoutes({ rootDirectory: "routes" });

export default [
  ...fsRoutes,
  // Manually add routes that don't follow conventions
  route("legacy-page", "legacy-routes/old-page.tsx"),
] satisfies RouteConfig;
```
