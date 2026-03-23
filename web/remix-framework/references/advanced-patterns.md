# Advanced Patterns — Remix / React Router v7

> Dense, production-grade patterns for building sophisticated full-stack apps
> with React Router v7 framework mode (formerly Remix).

## Table of Contents

- [Optimistic UI with useFetcher](#optimistic-ui-with-usefetcher)
- [Resource Routes](#resource-routes)
- [Streaming with defer/Await](#streaming-with-deferawait)
- [Nested Error Boundaries](#nested-error-boundaries)
- [Parallel Data Loading](#parallel-data-loading)
- [Client-Side Cache Management](#client-side-cache-management)
- [Form Validation Patterns](#form-validation-patterns)
- [File Uploads](#file-uploads)
- [WebSocket Integration](#websocket-integration)
- [Server-Sent Events (SSE)](#server-sent-events-sse)
- [Custom Server Entry](#custom-server-entry)

---

## Optimistic UI with useFetcher

Show the expected result immediately while the server processes the mutation.
`useFetcher` is ideal because it does NOT trigger a navigation.

```tsx
// app/routes/todos.tsx
import { useFetcher } from "react-router";

function TodoItem({ todo }: { todo: { id: string; title: string; completed: boolean } }) {
  const fetcher = useFetcher();

  // Derive optimistic state from the in-flight submission
  const optimisticCompleted =
    fetcher.formData
      ? fetcher.formData.get("completed") === "true"
      : todo.completed;

  return (
    <fetcher.Form method="post" action={`/todos/${todo.id}/toggle`}>
      <input type="hidden" name="completed" value={String(!todo.completed)} />
      <button
        className={optimisticCompleted ? "line-through text-gray-400" : ""}
        disabled={fetcher.state !== "idle"}
      >
        {todo.title}
      </button>
    </fetcher.Form>
  );
}
```

### Key rules

1. **Read `fetcher.formData`** to derive optimistic state — it contains the submitted form values before the server responds.
2. **Fall back to server data** when `fetcher.formData` is `undefined` (idle state).
3. **Handle failures** — if the action returns errors, `fetcher.data` will contain them after the round-trip. Reset UI accordingly.
4. **Multiple fetchers** — each `useFetcher()` instance is independent. Use `fetcher.key` to scope.

### Optimistic list additions

```tsx
function AddTodo() {
  const fetcher = useFetcher();
  const isAdding = fetcher.state === "submitting";

  return (
    <>
      <fetcher.Form method="post">
        <input name="title" required />
        <button>Add</button>
      </fetcher.Form>
      {isAdding && (
        <li className="opacity-50">
          {fetcher.formData?.get("title") as string}
        </li>
      )}
    </>
  );
}
```

---

## Resource Routes

Resource routes export a `loader` and/or `action` but **no default component**.
They serve non-HTML responses — JSON APIs, images, PDFs, RSS, sitemaps, webhooks.

```ts
// app/routes/api.products.ts  (no default export = resource route)
import type { Route } from "./+types/api.products";

export async function loader({ request }: Route.LoaderArgs) {
  const url = new URL(request.url);
  const q = url.searchParams.get("q") ?? "";
  const products = await db.product.findMany({
    where: { name: { contains: q } },
  });
  return Response.json(products);
}

export async function action({ request }: Route.ActionArgs) {
  if (request.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }
  const body = await request.json();
  const product = await db.product.create({ data: body });
  return Response.json(product, { status: 201 });
}
```

### Common resource route uses

| Use Case          | Response                                      |
|-------------------|-----------------------------------------------|
| JSON API          | `Response.json(data)`                         |
| CSV export        | `new Response(csv, { headers: { "Content-Type": "text/csv" } })` |
| Image generation  | `new Response(buffer, { headers: { "Content-Type": "image/png" } })` |
| RSS feed          | `new Response(xml, { headers: { "Content-Type": "application/rss+xml" } })` |
| Sitemap           | `new Response(xml, { headers: { "Content-Type": "application/xml" } })` |
| Webhook receiver  | Action that processes incoming POST payloads   |

### CORS on resource routes

```ts
export async function loader({ request }: Route.LoaderArgs) {
  const data = await getData();
  return Response.json(data, {
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    },
  });
}
```

---

## Streaming with defer/Await

In React Router v7, you no longer call `defer()`. Return un-awaited promises
directly from the loader; the framework streams them automatically.

```tsx
export async function loader({ params }: Route.LoaderArgs) {
  // Critical data — awaited, blocks rendering
  const product = await db.product.findUnique({ where: { id: params.id } });
  if (!product) throw new Response("Not Found", { status: 404 });

  // Non-critical data — NOT awaited, streamed in
  const reviews = db.review.findMany({ where: { productId: params.id } });
  const recommendations = db.product.findMany({ where: { categoryId: product.categoryId }, take: 4 });

  return { product, reviews, recommendations };
}

export default function ProductPage({ loaderData }: Route.ComponentProps) {
  const { product, reviews, recommendations } = loaderData;

  return (
    <div>
      <h1>{product.name}</h1>
      <p>{product.description}</p>

      <Suspense fallback={<ReviewsSkeleton />}>
        <Await resolve={reviews}>
          {(resolvedReviews) => <ReviewList reviews={resolvedReviews} />}
        </Await>
      </Suspense>

      <Suspense fallback={<RecommendationsSkeleton />}>
        <Await resolve={recommendations}>
          {(recs) => <ProductGrid products={recs} />}
        </Await>
      </Suspense>
    </div>
  );
}
```

### Rules

- **Always await critical data** that the page cannot render without.
- **Never await non-critical data** — let it stream. Users see the page faster.
- **Wrap each `<Await>` in its own `<Suspense>`** for independent loading states.
- **Error handling**: `<Await>` accepts an `errorElement` prop for per-stream error UI.

---

## Nested Error Boundaries

Each route module can export its own `ErrorBoundary`. Errors bubble up to the
nearest ancestor boundary — parent layouts remain interactive.

```tsx
// app/routes/dashboard.analytics.tsx
export function ErrorBoundary() {
  const error = useRouteError();

  if (isRouteErrorResponse(error)) {
    return (
      <div className="p-4 bg-red-50 rounded">
        <h2>Analytics Error ({error.status})</h2>
        <p>{error.data}</p>
        <Link to="/dashboard">← Back to dashboard</Link>
      </div>
    );
  }

  return (
    <div className="p-4 bg-red-50 rounded">
      <h2>Something went wrong</h2>
      <p>{error instanceof Error ? error.message : "Unknown error"}</p>
    </div>
  );
}
```

### Strategy

- **Root**: Catch-all boundary with full HTML shell (renders even if `<head>` setup fails).
- **Layout routes**: Boundary keeps nav/sidebar visible while content area shows error.
- **Leaf routes**: Granular error messages specific to the feature.
- **Throw `Response` objects** (e.g., `throw new Response("Forbidden", { status: 403 })`) for expected errors so you can distinguish them via `isRouteErrorResponse()`.

---

## Parallel Data Loading

React Router runs **all matched route loaders in parallel** automatically. Exploit
this by structuring routes so each segment loads its own data.

```
URL: /dashboard/analytics/sales

Loaders executed in parallel:
  1. root.tsx          → loader() fetches user session
  2. dashboard.tsx     → loader() fetches nav items, notifications
  3. dashboard.analytics.tsx → loader() fetches analytics config
  4. dashboard.analytics.sales.tsx → loader() fetches sales data
```

### Anti-pattern: waterfall in a single loader

```tsx
// ❌ BAD — sequential fetches in one loader
export async function loader() {
  const user = await getUser();          // 200ms
  const posts = await getPosts(user.id); // 300ms — waits for user
  return { user, posts };                // Total: 500ms
}

// ✅ GOOD — parallel fetches
export async function loader() {
  const [user, posts] = await Promise.all([
    getUser(),
    getPosts(),  // doesn't depend on user
  ]);
  return { user, posts };  // Total: 300ms
}
```

---

## Client-Side Cache Management

React Router automatically revalidates all loaders after every action. You can
control this with `shouldRevalidate`:

```tsx
export function shouldRevalidate({
  currentUrl,
  nextUrl,
  formAction,
  formMethod,
  defaultShouldRevalidate,
}: ShouldRevalidateFunctionArgs) {
  // Skip revalidation if only the search params changed
  if (currentUrl.pathname === nextUrl.pathname) {
    return false;
  }
  return defaultShouldRevalidate;
}
```

### Client-side caching with stale-while-revalidate

```tsx
export function headers() {
  return {
    "Cache-Control": "public, max-age=60, stale-while-revalidate=300",
  };
}
```

### Using `clientLoader` for client-side cache

```tsx
let cache = new Map<string, { data: any; timestamp: number }>();
const CACHE_TTL = 30_000; // 30 seconds

export async function clientLoader({ serverLoader, params }: Route.ClientLoaderArgs) {
  const key = `product-${params.id}`;
  const cached = cache.get(key);

  if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
    return cached.data;
  }

  const data = await serverLoader();
  cache.set(key, { data, timestamp: Date.now() });
  return data;
}

clientLoader.hydrate = true; // run on initial hydration too
```

---

## Form Validation Patterns

### Server-side validation with typed errors

```tsx
type ActionErrors = {
  fieldErrors?: { email?: string; password?: string };
  formError?: string;
};

export async function action({ request }: Route.ActionArgs) {
  const form = await request.formData();
  const email = String(form.get("email"));
  const password = String(form.get("password"));

  const fieldErrors: ActionErrors["fieldErrors"] = {};
  if (!email.includes("@")) fieldErrors.email = "Invalid email address";
  if (password.length < 8) fieldErrors.password = "Must be at least 8 characters";

  if (Object.keys(fieldErrors).length > 0) {
    return { fieldErrors } satisfies ActionErrors;
  }

  await createUser({ email, password });
  return redirect("/dashboard");
}
```

### Reusable validation with Zod

```tsx
import { z } from "zod";

const SignupSchema = z.object({
  email: z.string().email("Invalid email"),
  password: z.string().min(8, "At least 8 characters"),
  confirmPassword: z.string(),
}).refine(d => d.password === d.confirmPassword, {
  message: "Passwords don't match",
  path: ["confirmPassword"],
});

export async function action({ request }: Route.ActionArgs) {
  const form = Object.fromEntries(await request.formData());
  const result = SignupSchema.safeParse(form);

  if (!result.success) {
    return { errors: result.error.flatten().fieldErrors };
  }

  await createUser(result.data);
  return redirect("/dashboard");
}
```

---

## File Uploads

### Streaming uploads with `parseFormData`

```tsx
// app/routes/upload.tsx
import { parseFormData, type FileUpload } from "@remix-run/form-data-parser";
import { LocalFileStorage } from "@remix-run/file-storage/local";

const storage = new LocalFileStorage("./uploads");

export async function action({ request }: Route.ActionArgs) {
  const uploadHandler = async (fileUpload: FileUpload) => {
    if (fileUpload.fieldName === "avatar") {
      const key = `avatars/${Date.now()}-${fileUpload.name}`;
      await storage.set(key, fileUpload);
      return key;
    }
  };

  const formData = await parseFormData(request, uploadHandler);
  const avatarKey = formData.get("avatar") as string;

  return { success: true, avatarKey };
}

export default function UploadPage() {
  return (
    <Form method="post" encType="multipart/form-data">
      <input type="file" name="avatar" accept="image/*" />
      <button type="submit">Upload</button>
    </Form>
  );
}
```

### S3 uploads

Replace `LocalFileStorage` with your S3 client. Stream directly from the
request to S3 using `fileUpload.stream` — never buffer the entire file in memory.

---

## WebSocket Integration

WebSockets require a custom server — they can't run through the standard
React Router request handler.

```ts
// server.ts
import express from "express";
import { createRequestHandler } from "@react-router/express";
import { WebSocketServer } from "ws";

const app = express();
app.use(express.static("build/client"));
app.all("*", createRequestHandler({ build: () => import("./build/server/index.js") }));

const server = app.listen(3000);

const wss = new WebSocketServer({ server });
wss.on("connection", (ws, req) => {
  // Parse cookies from req.headers.cookie for auth
  ws.on("message", (msg) => {
    // Broadcast to all clients
    wss.clients.forEach((client) => {
      if (client.readyState === 1) client.send(msg.toString());
    });
  });
});
```

Client-side hook:
```tsx
function useWebSocket(url: string) {
  const [messages, setMessages] = useState<string[]>([]);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    const ws = new WebSocket(url);
    wsRef.current = ws;
    ws.onmessage = (e) => setMessages((prev) => [...prev, e.data]);
    return () => ws.close();
  }, [url]);

  const send = useCallback((msg: string) => wsRef.current?.send(msg), []);
  return { messages, send };
}
```

---

## Server-Sent Events (SSE)

Use a resource route to create an SSE endpoint:

```ts
// app/routes/api.events.ts
export async function loader({ request }: Route.LoaderArgs) {
  const stream = new ReadableStream({
    start(controller) {
      const encoder = new TextEncoder();

      const send = (event: string, data: unknown) => {
        controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
      };

      // Send initial data
      send("connected", { time: Date.now() });

      // Periodic updates
      const interval = setInterval(() => {
        send("heartbeat", { time: Date.now() });
      }, 30_000);

      // Clean up on client disconnect
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

Client-side consumption:
```tsx
function useSSE(url: string) {
  const [data, setData] = useState<any>(null);

  useEffect(() => {
    const source = new EventSource(url);
    source.addEventListener("heartbeat", (e) => setData(JSON.parse(e.data)));
    return () => source.close();
  }, [url]);

  return data;
}
```

---

## Custom Server Entry

Override the default entry points for full control over SSR rendering and
server startup.

### entry.server.tsx

```tsx
// app/entry.server.tsx
import { isbot } from "isbot";
import { renderToPipeableStream } from "react-dom/server";
import type { EntryContext } from "react-router";
import { ServerRouter } from "react-router";

export default function handleRequest(
  request: Request,
  responseStatusCode: number,
  responseHeaders: Headers,
  routerContext: EntryContext,
) {
  const userAgent = request.headers.get("user-agent") ?? "";
  const callbackName = isbot(userAgent) ? "onAllReady" : "onShellReady";

  return new Promise((resolve, reject) => {
    const { pipe, abort } = renderToPipeableStream(
      <ServerRouter context={routerContext} url={request.url} />,
      {
        [callbackName]() {
          const body = new PassThrough();
          responseHeaders.set("Content-Type", "text/html");
          resolve(
            new Response(body as any, {
              headers: responseHeaders,
              status: responseStatusCode,
            })
          );
          pipe(body);
        },
        onShellError: reject,
        onError(error) {
          responseStatusCode = 500;
          console.error(error);
        },
      }
    );
    setTimeout(abort, 10_000); // 10s timeout
  });
}
```

### entry.client.tsx

```tsx
// app/entry.client.tsx
import { startTransition, StrictMode } from "react";
import { hydrateRoot } from "react-dom/client";
import { HydratedRouter } from "react-router/dom";

startTransition(() => {
  hydrateRoot(
    document,
    <StrictMode>
      <HydratedRouter />
    </StrictMode>
  );
});
```

These files are optional — React Router provides sensible defaults. Override
them only when you need custom streaming behavior, bot detection, error
reporting integration, or performance instrumentation.
