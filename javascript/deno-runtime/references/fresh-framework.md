# Fresh Framework Deep Dive

## Table of Contents

- [Overview](#overview)
- [Getting Started](#getting-started)
- [Project Structure](#project-structure)
- [Islands Architecture](#islands-architecture)
- [Route Handlers](#route-handlers)
- [Dynamic Routes and Parameters](#dynamic-routes-and-parameters)
- [Middleware](#middleware)
- [Layouts](#layouts)
- [Static Files](#static-files)
- [Plugins](#plugins)
- [Form Submissions](#form-submissions)
- [WebSocket in Fresh](#websocket-in-fresh)
- [State Management](#state-management)
- [Error Handling](#error-handling)
- [Deployment to Deno Deploy](#deployment-to-deno-deploy)
- [SEO Patterns](#seo-patterns)
- [Streaming and Partials](#streaming-and-partials)
- [Testing Fresh Apps](#testing-fresh-apps)
- [Performance Optimization](#performance-optimization)

---

## Overview

Fresh is a full-stack web framework for Deno. Key principles:

- **No build step** — Source files are served and rendered just-in-time
- **Islands architecture** — Ship zero JS by default; hydrate only interactive components
- **Server-side rendering** — All pages are SSR'd for fast Time to First Byte (TTFB)
- **File-based routing** — Routes map to files in the `routes/` directory
- **TypeScript-first** — Full type safety throughout
- **Preact** — Uses Preact for component rendering (lightweight React alternative)

---

## Getting Started

### Create a New Project

```bash
# Scaffold a new Fresh project
deno run -Ar jsr:@fresh/init my-app
cd my-app

# Start development server
deno task dev
```

### Minimal deno.json for Fresh

```jsonc
{
  "tasks": {
    "dev": "deno run -A --watch=static/,routes/ dev.ts",
    "build": "deno run -A dev.ts build",
    "preview": "deno run -A main.ts",
    "start": "deno run -A main.ts"
  },
  "imports": {
    "$fresh/": "https://deno.land/x/fresh@1.7.3/",
    "preact": "https://esm.sh/preact@10.22.0",
    "preact/": "https://esm.sh/preact@10.22.0/",
    "@preact/signals": "https://esm.sh/*@preact/signals@1.2.3",
    "@preact/signals-core": "https://esm.sh/*@preact/signals-core@1.7.0"
  },
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "preact"
  }
}
```

---

## Project Structure

```
my-app/
├── deno.json           # Project config with imports and tasks
├── dev.ts              # Development entry point
├── main.ts             # Production entry point
├── fresh.gen.ts        # Auto-generated manifest (do not edit)
├── routes/
│   ├── _app.tsx        # App wrapper (layout shell)
│   ├── _layout.tsx     # Layout wrapper
│   ├── _middleware.ts  # Global middleware
│   ├── _404.tsx        # Custom 404 page
│   ├── _500.tsx        # Custom 500 page
│   ├── index.tsx       # Homepage (/)
│   ├── about.tsx       # /about
│   ├── blog/
│   │   ├── index.tsx   # /blog
│   │   └── [slug].tsx  # /blog/:slug (dynamic route)
│   └── api/
│       └── users.ts    # /api/users (API-only route)
├── islands/
│   ├── Counter.tsx     # Interactive island component
│   └── SearchBar.tsx   # Another island
├── components/
│   ├── Header.tsx      # Static (non-island) component
│   └── Footer.tsx
├── static/
│   ├── favicon.ico
│   ├── logo.svg
│   └── styles.css
└── utils/
    ├── db.ts
    └── auth.ts
```

### Special Files

| File | Purpose |
|------|---------|
| `_app.tsx` | Outermost HTML shell (`<html>`, `<head>`, `<body>`) |
| `_layout.tsx` | Layout wrapper for sibling/child routes |
| `_middleware.ts` | Middleware that runs before route handlers |
| `_404.tsx` | Custom 404 Not Found page |
| `_500.tsx` | Custom 500 Internal Server Error page |
| `fresh.gen.ts` | Auto-generated route manifest |

---

## Islands Architecture

Islands are the core concept in Fresh. Only components in `islands/` are hydrated (sent as JavaScript to the browser). Everything else is pure HTML.

### Creating an Island

```tsx
// islands/Counter.tsx
import { useSignal } from "@preact/signals";

export default function Counter(props: { start: number }) {
  const count = useSignal(props.start);

  return (
    <div class="counter">
      <p>Count: {count}</p>
      <button onClick={() => count.value--}>-</button>
      <button onClick={() => count.value++}>+</button>
    </div>
  );
}
```

### Using Islands in Routes

```tsx
// routes/index.tsx
import Counter from "../islands/Counter.tsx";

export default function Home() {
  return (
    <div>
      <h1>Welcome</h1>
      <p>This text is static HTML — no JS shipped.</p>

      {/* Only Counter gets hydrated on the client */}
      <Counter start={0} />
    </div>
  );
}
```

### Island Props Constraints

Props passed to islands must be serializable (JSON-compatible):

```tsx
// ✅ Valid props: strings, numbers, booleans, arrays, plain objects
<Counter start={5} />
<UserCard user={{ name: "Alice", id: "u001" }} />

// ❌ Invalid props: functions, classes, Dates, Maps, Sets
<Counter onChange={(v) => console.log(v)} />  // Function — will not serialize
```

### Nested Islands

Islands can be nested, and each is independently hydrated:

```tsx
// islands/Dashboard.tsx
import Chart from "./Chart.tsx";
import FilterBar from "./FilterBar.tsx";

export default function Dashboard(props: { data: DataPoint[] }) {
  return (
    <div>
      <FilterBar options={["day", "week", "month"]} />
      <Chart data={props.data} />
    </div>
  );
}
```

### Static Components (Non-Islands)

Components in `components/` are rendered server-side only. No JS is shipped.

```tsx
// components/Header.tsx — server-rendered, zero JS
export default function Header(props: { title: string }) {
  return (
    <header>
      <nav>
        <a href="/">Home</a>
        <a href="/about">About</a>
        <a href="/blog">Blog</a>
      </nav>
      <h1>{props.title}</h1>
    </header>
  );
}
```

---

## Route Handlers

Routes can export HTTP method handlers and/or a default component.

### API Route (Handler Only)

```typescript
// routes/api/users.ts
import { FreshContext } from "$fresh/server.ts";

export const handler = {
  async GET(_req: Request, ctx: FreshContext) {
    const users = await db.listUsers();
    return Response.json(users);
  },

  async POST(req: Request, _ctx: FreshContext) {
    const body = await req.json();
    const user = await db.createUser(body);
    return Response.json(user, { status: 201 });
  },

  async PUT(req: Request, _ctx: FreshContext) {
    const body = await req.json();
    const user = await db.updateUser(body);
    return Response.json(user);
  },

  async DELETE(req: Request, ctx: FreshContext) {
    const url = new URL(req.url);
    const id = url.searchParams.get("id");
    await db.deleteUser(id!);
    return new Response(null, { status: 204 });
  },
};
```

### Page Route (Handler + Component)

```tsx
// routes/dashboard.tsx
import { FreshContext, Handlers, PageProps } from "$fresh/server.ts";

interface DashboardData {
  stats: { users: number; revenue: number };
  recentOrders: Order[];
}

export const handler: Handlers<DashboardData> = {
  async GET(_req: Request, ctx: FreshContext) {
    const stats = await db.getStats();
    const recentOrders = await db.getRecentOrders();
    return ctx.render({ stats, recentOrders });
  },
};

export default function Dashboard({ data }: PageProps<DashboardData>) {
  return (
    <div>
      <h1>Dashboard</h1>
      <div class="stats">
        <p>Users: {data.stats.users}</p>
        <p>Revenue: ${data.stats.revenue}</p>
      </div>
      <h2>Recent Orders</h2>
      <ul>
        {data.recentOrders.map((order) => (
          <li key={order.id}>{order.name} — ${order.total}</li>
        ))}
      </ul>
    </div>
  );
}
```

### Single Handler Function

```typescript
// routes/api/health.ts — simple single-method handler
export const handler = (_req: Request, _ctx: FreshContext): Response => {
  return Response.json({ status: "ok", timestamp: Date.now() });
};
```

---

## Dynamic Routes and Parameters

### Path Parameters

```tsx
// routes/blog/[slug].tsx — matches /blog/my-post
import { FreshContext, Handlers, PageProps } from "$fresh/server.ts";

export const handler: Handlers = {
  async GET(_req: Request, ctx: FreshContext) {
    const slug = ctx.params.slug;
    const post = await db.getPost(slug);
    if (!post) return ctx.renderNotFound();
    return ctx.render(post);
  },
};

export default function BlogPost({ data }: PageProps) {
  return (
    <article>
      <h1>{data.title}</h1>
      <time>{data.publishedAt}</time>
      <div dangerouslySetInnerHTML={{ __html: data.content }} />
    </article>
  );
}
```

### Multiple Parameters

```tsx
// routes/users/[userId]/posts/[postId].tsx
// Matches: /users/123/posts/456
export const handler: Handlers = {
  GET(_req, ctx) {
    const { userId, postId } = ctx.params;
    // ...
  },
};
```

### Catch-All Routes

```tsx
// routes/docs/[...path].tsx — matches /docs/a/b/c
export const handler: Handlers = {
  GET(_req, ctx) {
    const path = ctx.params.path; // "a/b/c"
    // ...
  },
};
```

### Route Groups

```
routes/
├── (marketing)/
│   ├── index.tsx       # / (marketing layout)
│   └── pricing.tsx     # /pricing
├── (app)/
│   ├── dashboard.tsx   # /dashboard (app layout)
│   └── settings.tsx    # /settings
```

Route groups `(name)` organize routes without affecting URL paths.

---

## Middleware

Middleware runs before route handlers. Use `_middleware.ts` files.

### Basic Middleware

```typescript
// routes/_middleware.ts — runs for ALL routes
import { FreshContext } from "$fresh/server.ts";

export async function handler(req: Request, ctx: FreshContext) {
  const start = performance.now();
  const resp = await ctx.next();
  const elapsed = performance.now() - start;
  resp.headers.set("X-Response-Time", `${elapsed.toFixed(1)}ms`);
  console.log(`${req.method} ${new URL(req.url).pathname} — ${elapsed.toFixed(1)}ms`);
  return resp;
}
```

### Authentication Middleware

```typescript
// routes/api/_middleware.ts — only for /api/* routes
import { FreshContext } from "$fresh/server.ts";

export async function handler(req: Request, ctx: FreshContext) {
  const token = req.headers.get("Authorization")?.replace("Bearer ", "");

  if (!token) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }

  try {
    const user = await verifyToken(token);
    ctx.state.user = user;
    return ctx.next();
  } catch {
    return Response.json({ error: "Invalid token" }, { status: 403 });
  }
}
```

### Chaining Multiple Middleware

```typescript
// routes/_middleware.ts — array of middleware functions
import { FreshContext } from "$fresh/server.ts";

function corsMiddleware(req: Request, ctx: FreshContext) {
  const resp = ctx.next();
  // CORS headers added after route handler
  return resp.then((r) => {
    r.headers.set("Access-Control-Allow-Origin", "*");
    r.headers.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE");
    return r;
  });
}

function loggingMiddleware(req: Request, ctx: FreshContext) {
  console.log(`${req.method} ${new URL(req.url).pathname}`);
  return ctx.next();
}

export const handler = [loggingMiddleware, corsMiddleware];
```

---

## Layouts

### App Wrapper (_app.tsx)

The outermost shell — wraps every page:

```tsx
// routes/_app.tsx
import { FreshContext } from "$fresh/server.ts";

export default function App(_req: Request, ctx: FreshContext) {
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>My App</title>
        <link rel="stylesheet" href="/styles.css" />
      </head>
      <body>
        <ctx.Component />
      </body>
    </html>
  );
}
```

### Layout Wrapper (_layout.tsx)

Wraps child routes in a shared layout:

```tsx
// routes/_layout.tsx — applies to all routes at this level
import { FreshContext } from "$fresh/server.ts";
import Header from "../components/Header.tsx";
import Footer from "../components/Footer.tsx";

export default function Layout(_req: Request, ctx: FreshContext) {
  return (
    <div class="layout">
      <Header title="My Site" />
      <main>
        <ctx.Component />
      </main>
      <Footer />
    </div>
  );
}
```

### Nested Layouts

```
routes/
├── _layout.tsx           # Root layout (Header + Footer)
├── index.tsx             # Uses root layout
├── admin/
│   ├── _layout.tsx       # Admin layout (sidebar)
│   ├── index.tsx         # /admin — uses both layouts
│   └── users.tsx         # /admin/users
```

```tsx
// routes/admin/_layout.tsx
export default function AdminLayout(_req: Request, ctx: FreshContext) {
  return (
    <div class="admin-layout">
      <aside>
        <nav>
          <a href="/admin">Dashboard</a>
          <a href="/admin/users">Users</a>
          <a href="/admin/settings">Settings</a>
        </nav>
      </aside>
      <section class="admin-content">
        <ctx.Component />
      </section>
    </div>
  );
}
```

---

## Static Files

Files in the `static/` directory are served directly.

### Serving Static Files

```
static/
├── favicon.ico        # /favicon.ico
├── logo.svg           # /logo.svg
├── styles.css         # /styles.css
└── images/
    └── hero.webp      # /images/hero.webp
```

### Referencing in Components

```tsx
export default function Home() {
  return (
    <div>
      <img src="/logo.svg" alt="Logo" />
      <link rel="stylesheet" href="/styles.css" />
    </div>
  );
}
```

### Asset Hashing (Cache Busting)

Fresh supports asset references with automatic hash-based cache busting:

```tsx
import { asset } from "$fresh/runtime.ts";

export default function Page() {
  return (
    <head>
      <link rel="stylesheet" href={asset("/styles.css")} />
      <script src={asset("/app.js")}></script>
    </head>
  );
}
```

---

## Plugins

Fresh supports plugins for extending functionality.

### Using Built-in Plugins

```typescript
// main.ts
import { start } from "$fresh/server.ts";
import manifest from "./fresh.gen.ts";
import twindPlugin from "$fresh/plugins/twind.ts";
import twindConfig from "./twind.config.ts";

await start(manifest, {
  plugins: [twindPlugin(twindConfig)],
});
```

### Creating a Custom Plugin

```typescript
// plugins/analytics.ts
import { Plugin } from "$fresh/server.ts";

export function analyticsPlugin(trackingId: string): Plugin {
  return {
    name: "analytics",
    render(ctx) {
      ctx.render();
      return {
        scripts: [
          {
            entrypoint: "analytics",
            state: { trackingId },
          },
        ],
      };
    },
    entrypoints: {
      analytics: `
        export default function(state) {
          // Initialize analytics with state.trackingId
          console.log("Analytics loaded:", state.trackingId);
        }
      `,
    },
  };
}
```

### Tailwind CSS Plugin

```typescript
// main.ts
import { start } from "$fresh/server.ts";
import manifest from "./fresh.gen.ts";
import tailwind from "$fresh/plugins/tailwind.ts";

await start(manifest, {
  plugins: [tailwind()],
});
```

```css
/* static/styles.css */
@tailwind base;
@tailwind components;
@tailwind utilities;
```

---

## Form Submissions

Fresh handles forms using standard HTML form submissions with server-side handlers.

### Basic Form

```tsx
// routes/contact.tsx
import { Handlers, PageProps } from "$fresh/server.ts";

interface FormData {
  success?: boolean;
  errors?: Record<string, string>;
  values?: Record<string, string>;
}

export const handler: Handlers<FormData> = {
  GET(_req, ctx) {
    return ctx.render({});
  },

  async POST(req, ctx) {
    const form = await req.formData();
    const name = form.get("name")?.toString() ?? "";
    const email = form.get("email")?.toString() ?? "";
    const message = form.get("message")?.toString() ?? "";

    const errors: Record<string, string> = {};
    if (!name) errors.name = "Name is required";
    if (!email.includes("@")) errors.email = "Valid email required";
    if (!message) errors.message = "Message is required";

    if (Object.keys(errors).length > 0) {
      return ctx.render({ errors, values: { name, email, message } });
    }

    await db.saveContact({ name, email, message });
    return ctx.render({ success: true });
  },
};

export default function ContactPage({ data }: PageProps<FormData>) {
  if (data.success) {
    return <p class="success">Thank you! We'll be in touch.</p>;
  }

  return (
    <form method="POST">
      <div>
        <label for="name">Name</label>
        <input name="name" id="name" value={data.values?.name ?? ""} />
        {data.errors?.name && <span class="error">{data.errors.name}</span>}
      </div>
      <div>
        <label for="email">Email</label>
        <input name="email" id="email" type="email" value={data.values?.email ?? ""} />
        {data.errors?.email && <span class="error">{data.errors.email}</span>}
      </div>
      <div>
        <label for="message">Message</label>
        <textarea name="message" id="message">{data.values?.message ?? ""}</textarea>
        {data.errors?.message && <span class="error">{data.errors.message}</span>}
      </div>
      <button type="submit">Send</button>
    </form>
  );
}
```

### File Upload

```tsx
// routes/upload.tsx
export const handler: Handlers = {
  async POST(req, ctx) {
    const form = await req.formData();
    const file = form.get("file") as File;

    if (!file || file.size === 0) {
      return ctx.render({ error: "No file selected" });
    }

    const bytes = new Uint8Array(await file.arrayBuffer());
    await Deno.writeFile(`./uploads/${file.name}`, bytes);

    return ctx.render({ success: true, filename: file.name });
  },
};
```

---

## WebSocket in Fresh

### WebSocket Route

```typescript
// routes/api/ws.ts
export const handler = {
  GET(req: Request) {
    if (req.headers.get("upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 400 });
    }

    const { socket, response } = Deno.upgradeWebSocket(req);

    socket.onopen = () => {
      console.log("Client connected");
    };

    socket.onmessage = (event) => {
      const data = JSON.parse(event.data);
      // Echo back with server timestamp
      socket.send(JSON.stringify({
        ...data,
        serverTime: Date.now(),
      }));
    };

    socket.onclose = () => {
      console.log("Client disconnected");
    };

    return response;
  },
};
```

### WebSocket Island (Client)

```tsx
// islands/LiveChat.tsx
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";

export default function LiveChat() {
  const messages = useSignal<string[]>([]);
  const input = useSignal("");
  const ws = useSignal<WebSocket | null>(null);

  useEffect(() => {
    const socket = new WebSocket(`wss://${location.host}/api/ws`);

    socket.onmessage = (event) => {
      const data = JSON.parse(event.data);
      messages.value = [...messages.value, data.text];
    };

    ws.value = socket;
    return () => socket.close();
  }, []);

  const send = () => {
    ws.value?.send(JSON.stringify({ text: input.value }));
    input.value = "";
  };

  return (
    <div class="chat">
      <div class="messages">
        {messages.value.map((msg, i) => <p key={i}>{msg}</p>)}
      </div>
      <input
        value={input}
        onInput={(e) => input.value = (e.target as HTMLInputElement).value}
        onKeyDown={(e) => e.key === "Enter" && send()}
      />
      <button onClick={send}>Send</button>
    </div>
  );
}
```

---

## State Management

### Using Preact Signals

```tsx
// islands/TodoApp.tsx
import { useSignal, useComputed } from "@preact/signals";

interface Todo {
  id: number;
  text: string;
  done: boolean;
}

export default function TodoApp() {
  const todos = useSignal<Todo[]>([]);
  const input = useSignal("");
  const remaining = useComputed(
    () => todos.value.filter((t) => !t.done).length,
  );

  const addTodo = () => {
    if (!input.value.trim()) return;
    todos.value = [
      ...todos.value,
      { id: Date.now(), text: input.value, done: false },
    ];
    input.value = "";
  };

  const toggleTodo = (id: number) => {
    todos.value = todos.value.map((t) =>
      t.id === id ? { ...t, done: !t.done } : t
    );
  };

  return (
    <div>
      <h2>Todos ({remaining} remaining)</h2>
      <input
        value={input}
        onInput={(e) => input.value = (e.target as HTMLInputElement).value}
        onKeyDown={(e) => e.key === "Enter" && addTodo()}
      />
      <button onClick={addTodo}>Add</button>
      <ul>
        {todos.value.map((todo) => (
          <li key={todo.id}>
            <input
              type="checkbox"
              checked={todo.done}
              onChange={() => toggleTodo(todo.id)}
            />
            <span style={{ textDecoration: todo.done ? "line-through" : "" }}>
              {todo.text}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
```

### Server State via ctx.state

```typescript
// routes/_middleware.ts
export async function handler(req: Request, ctx: FreshContext) {
  ctx.state.user = await getSessionUser(req);
  ctx.state.theme = req.headers.get("Cookie")?.includes("theme=dark") ? "dark" : "light";
  return ctx.next();
}

// routes/profile.tsx — access state set by middleware
export const handler: Handlers = {
  GET(_req, ctx) {
    const user = ctx.state.user;
    if (!user) return new Response(null, { status: 302, headers: { Location: "/login" } });
    return ctx.render(user);
  },
};
```

---

## Error Handling

### Custom 404 Page

```tsx
// routes/_404.tsx
export default function NotFound() {
  return (
    <div class="error-page">
      <h1>404 — Page Not Found</h1>
      <p>The page you're looking for doesn't exist.</p>
      <a href="/">Go Home</a>
    </div>
  );
}
```

### Custom 500 Page

```tsx
// routes/_500.tsx
import { PageProps } from "$fresh/server.ts";

export default function Error500({ error }: PageProps) {
  return (
    <div class="error-page">
      <h1>500 — Internal Server Error</h1>
      <p>Something went wrong. Please try again later.</p>
    </div>
  );
}
```

### Handler Error Boundaries

```typescript
export const handler: Handlers = {
  async GET(req, ctx) {
    try {
      const data = await riskyOperation();
      return ctx.render(data);
    } catch (err) {
      console.error("Handler error:", err);
      return new Response("Internal Error", { status: 500 });
    }
  },
};
```

---

## Deployment to Deno Deploy

### Using deployctl

```bash
# Install
deno install -gArf jsr:@deno/deployctl

# Deploy (production)
deployctl deploy --project=my-fresh-app --prod main.ts

# Deploy (preview)
deployctl deploy --project=my-fresh-app main.ts
```

### GitHub Actions Deployment

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: denoland/setup-deno@v2
        with:
          deno-version: v2.x
      - name: Build
        run: deno task build
      - uses: denoland/deployctl@v1
        with:
          project: my-fresh-app
          entrypoint: main.ts
```

### Environment Variables on Deploy

Set via dashboard or CLI:

```bash
deployctl deploy \
  --project=my-app \
  --env=DATABASE_URL=postgres://... \
  --env=API_KEY=secret123 \
  --prod main.ts
```

Access in code:

```typescript
const dbUrl = Deno.env.get("DATABASE_URL");
```

### Deploy Limitations

- No `Deno.Command` (subprocesses)
- No `Deno.dlopen` (FFI)
- Limited filesystem (read-only, no writes to local disk)
- Use Deno KV for persistence (globally replicated)
- Max request timeout: 60 seconds
- Max response size: 20 MB

---

## SEO Patterns

### Dynamic Meta Tags

```tsx
// routes/blog/[slug].tsx
export const handler: Handlers = {
  async GET(_req, ctx) {
    const post = await db.getPost(ctx.params.slug);
    if (!post) return ctx.renderNotFound();
    return ctx.render(post);
  },
};

export default function BlogPost({ data }: PageProps) {
  return (
    <>
      <Head>
        <title>{data.title} | My Blog</title>
        <meta name="description" content={data.excerpt} />
        <meta property="og:title" content={data.title} />
        <meta property="og:description" content={data.excerpt} />
        <meta property="og:image" content={data.coverImage} />
        <meta property="og:type" content="article" />
        <meta name="twitter:card" content="summary_large_image" />
        <link rel="canonical" href={`https://myblog.com/blog/${data.slug}`} />
      </Head>
      <article>
        <h1>{data.title}</h1>
        <div dangerouslySetInnerHTML={{ __html: data.content }} />
      </article>
    </>
  );
}
```

### Sitemap Generation

```typescript
// routes/sitemap.xml.ts
export const handler = {
  async GET() {
    const posts = await db.listPosts();
    const staticPages = ["/", "/about", "/contact", "/blog"];

    const urls = [
      ...staticPages.map((path) => ({
        loc: `https://myblog.com${path}`,
        changefreq: "weekly",
        priority: path === "/" ? "1.0" : "0.8",
      })),
      ...posts.map((post) => ({
        loc: `https://myblog.com/blog/${post.slug}`,
        lastmod: post.updatedAt,
        changefreq: "monthly",
        priority: "0.6",
      })),
    ];

    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.map((u) => `  <url>
    <loc>${u.loc}</loc>
    ${u.lastmod ? `<lastmod>${u.lastmod}</lastmod>` : ""}
    <changefreq>${u.changefreq}</changefreq>
    <priority>${u.priority}</priority>
  </url>`).join("\n")}
</urlset>`;

    return new Response(xml, {
      headers: { "Content-Type": "application/xml" },
    });
  },
};
```

### robots.txt

```typescript
// routes/robots.txt.ts
export const handler = {
  GET() {
    return new Response(
      `User-agent: *
Allow: /
Disallow: /api/
Disallow: /admin/
Sitemap: https://myblog.com/sitemap.xml`,
      { headers: { "Content-Type": "text/plain" } },
    );
  },
};
```

### Structured Data (JSON-LD)

```tsx
export default function BlogPost({ data }: PageProps) {
  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "BlogPosting",
    headline: data.title,
    author: { "@type": "Person", name: data.author },
    datePublished: data.publishedAt,
    image: data.coverImage,
  };

  return (
    <>
      <Head>
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
      </Head>
      <article>{/* ... */}</article>
    </>
  );
}
```

---

## Streaming and Partials

### Streaming HTML Responses

Fresh supports streaming server-side rendering for faster TTFB:

```tsx
// Async components stream content as it becomes available
export default async function Dashboard() {
  // This starts rendering immediately
  return (
    <div>
      <h1>Dashboard</h1>
      <Suspense fallback={<p>Loading stats...</p>}>
        <AsyncStats />
      </Suspense>
    </div>
  );
}

async function AsyncStats() {
  const stats = await slowDatabaseQuery(); // Streams in when ready
  return <div class="stats">{/* render stats */}</div>;
}
```

### Partials (SPA-like Navigation)

Fresh supports partial page updates for SPA-like navigation without full page reloads:

```tsx
// Use f-client-nav to enable client-side navigation
export default function App(_req: Request, ctx: FreshContext) {
  return (
    <html>
      <body f-client-nav>
        <nav>
          <a href="/">Home</a>
          <a href="/about">About</a>
        </nav>
        <ctx.Component />
      </body>
    </html>
  );
}
```

---

## Testing Fresh Apps

### Testing Route Handlers

```typescript
import { assertEquals } from "@std/assert";
import { handler } from "./routes/api/users.ts";

Deno.test("GET /api/users returns users", async () => {
  const req = new Request("http://localhost/api/users");
  const ctx = createFreshContext(req);
  const resp = await handler.GET(req, ctx);

  assertEquals(resp.status, 200);
  const data = await resp.json();
  assertEquals(Array.isArray(data), true);
});
```

### Testing with Fresh Test Utils

```typescript
import { createHandler } from "$fresh/server.ts";
import manifest from "./fresh.gen.ts";

Deno.test("integration test", async () => {
  const handler = await createHandler(manifest);
  const resp = await handler(new Request("http://localhost/"));
  assertEquals(resp.status, 200);
  const body = await resp.text();
  assertEquals(body.includes("<h1>"), true);
});
```

---

## Performance Optimization

### Minimize Island Count

Each island adds JavaScript to the client. Keep islands small and focused:

```tsx
// Bad: Entire page is an island
// islands/Dashboard.tsx — ships lots of JS

// Good: Only interactive parts are islands
// components/Dashboard.tsx (server-rendered)
//   └── islands/FilterDropdown.tsx (small, interactive)
//   └── islands/Chart.tsx (interactive)
```

### Lazy Loading Islands

```tsx
// Use Intersection Observer for below-fold islands
import { IS_BROWSER } from "$fresh/runtime.ts";

export default function LazyChart(props: ChartProps) {
  if (!IS_BROWSER) {
    return <div class="chart-placeholder">Loading chart...</div>;
  }
  // Render chart only on client
  return <Chart {...props} />;
}
```

### Static Asset Optimization

```tsx
// Use modern image formats
<img src="/images/hero.webp" alt="Hero" loading="lazy" decoding="async" />

// Preload critical assets
<Head>
  <link rel="preload" href="/styles.css" as="style" />
  <link rel="preload" href="/fonts/inter.woff2" as="font" type="font/woff2" crossorigin />
</Head>
```
