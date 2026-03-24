# Remix / React Router v7 API Quick Reference

All APIs below work in both Remix v2 and React Router v7 framework mode. Import from `"react-router"` in RR v7 or `"@remix-run/react"` / `"@remix-run/node"` in Remix v2.

---

## Route Module Exports

### loader

Server-side data loading. Runs on initial SSR and on client-side navigations.

```ts
export async function loader({ request, params, context }: Route.LoaderArgs) {
  // request: standard Web Request object
  // params: URL parameters (e.g., { id: "123" })
  // context: server context (platform-specific)
  return { data: await fetchData(params.id) };
}
```

Return plain objects (serialized automatically via turbo-stream in single fetch mode). Throw `Response` for expected errors (404, 403). Throw `Error` for unexpected failures.

### action

Server-side mutation handler. Runs on non-GET form submissions.

```ts
export async function action({ request, params, context }: Route.ActionArgs) {
  const formData = await request.formData();
  // Or: await request.json() for JSON bodies
  const result = await saveData(formData);
  return redirect(`/items/${result.id}`);
}
```

Always redirect after successful mutations (POST/Redirect/GET pattern).

### meta

Returns array of meta tag descriptors for `<head>`.

```ts
export function meta({ data, params, matches, location, error }: Route.MetaArgs) {
  return [
    { title: "Page Title" },
    { name: "description", content: "Page description" },
    { property: "og:title", content: "OG Title" },
    { tagName: "link", rel: "canonical", href: "https://example.com/page" },
  ];
}
```

Child `meta` fully replaces parent `meta` — use `matches` to merge parent meta if needed.

### links

Returns array of `<link>` elements for the route.

```ts
export function links(): Route.LinkDescriptors {
  return [
    { rel: "stylesheet", href: "/styles/page.css" },
    { rel: "preload", href: "/fonts/inter.woff2", as: "font", type: "font/woff2", crossOrigin: "anonymous" },
    { rel: "icon", href: "/favicon.png", type: "image/png" },
  ];
}
```

### headers

Controls HTTP response headers for the route.

```ts
export function headers({ loaderHeaders, parentHeaders, actionHeaders, errorHeaders }: Route.HeadersArgs) {
  return {
    "Cache-Control": loaderHeaders.get("Cache-Control") ?? "no-cache",
  };
}
```

Deepest matching route's headers win by default. Use `parentHeaders` to merge.

### handle

Arbitrary data exposed via `useMatches()`. Useful for breadcrumbs, i18n, etc.

```ts
export const handle = {
  breadcrumb: (match: UIMatch) => <Link to={match.pathname}>{match.data.title}</Link>,
  i18n: ["common", "dashboard"],
};
```

### shouldRevalidate

Controls when loaders re-run after navigations or actions.

```ts
export function shouldRevalidate({
  currentUrl, nextUrl, formMethod, formAction, defaultShouldRevalidate,
}: ShouldRevalidateFunctionArgs): boolean {
  // Skip revalidation if only search params changed
  if (currentUrl.pathname === nextUrl.pathname) return false;
  return defaultShouldRevalidate;
}
```

### ErrorBoundary

Catches loader, action, and render errors for this route and descendants (until a closer boundary).

```tsx
export function ErrorBoundary() {
  const error = useRouteError();
  if (isRouteErrorResponse(error)) {
    return <div>{error.status}: {error.statusText}</div>;
  }
  return <div>Error: {error instanceof Error ? error.message : "Unknown"}</div>;
}
```

### default (Component)

The route's UI component. Receives typed props from loader/action data.

```tsx
export default function MyPage({ loaderData, actionData, params, matches }: Route.ComponentProps) {
  return <div>{loaderData.title}</div>;
}
```

---

## Hooks

### useFetcher

Non-navigating data mutations and loads. Each fetcher has independent state.

```tsx
const fetcher = useFetcher<typeof action>();

// State
fetcher.state;     // "idle" | "submitting" | "loading"
fetcher.data;      // Last action/loader response data
fetcher.formData;  // FormData being submitted (for optimistic UI)

// Submit programmatically
fetcher.submit(formData, { method: "POST", action: "/api/save" });
fetcher.submit({ key: "value" }, { method: "POST", encType: "application/json" });

// Load data without navigation
fetcher.load("/api/data?q=search");

// Form component (like <Form> but without navigation)
<fetcher.Form method="post" action="/api/like">
  <button>Like</button>
</fetcher.Form>
```

### useNavigation

Track the state of page navigations (not fetchers).

```tsx
const navigation = useNavigation();

navigation.state;      // "idle" | "submitting" | "loading"
navigation.location;   // Location being navigated to (if any)
navigation.formData;   // FormData being submitted (if any)
navigation.formMethod; // HTTP method of the form submission
navigation.formAction; // Action URL of the form submission
```

### useLoaderData

Access the current route's loader data (legacy — prefer `Route.ComponentProps`).

```tsx
const data = useLoaderData<typeof loader>();
```

### useActionData

Access the current route's last action response (legacy — prefer `Route.ComponentProps`).

```tsx
const actionData = useActionData<typeof action>();
```

### useRouteError

Access the error caught by the nearest `ErrorBoundary`.

```tsx
const error = useRouteError();
// Returns: Response | Error | unknown
```

### useMatches

Access data from all currently matched routes.

```tsx
const matches = useMatches();
// Returns: UIMatch[] — each has { id, pathname, params, data, handle }

// Example: breadcrumbs from handle exports
const breadcrumbs = matches
  .filter((m) => m.handle?.breadcrumb)
  .map((m) => m.handle.breadcrumb(m));
```

### useRevalidator

Programmatically trigger revalidation of all route loaders.

```tsx
const revalidator = useRevalidator();

revalidator.state; // "idle" | "loading"
revalidator.revalidate(); // Trigger revalidation

// Example: revalidate on focus
useEffect(() => {
  const handler = () => revalidator.revalidate();
  window.addEventListener("focus", handler);
  return () => window.removeEventListener("focus", handler);
}, [revalidator]);
```

### useSearchParams

Read and update URL search parameters.

```tsx
const [searchParams, setSearchParams] = useSearchParams();

const query = searchParams.get("q") ?? "";
setSearchParams({ q: "new query", page: "1" });
setSearchParams((prev) => { prev.set("page", "2"); return prev; });
```

### useParams

Access URL parameters for the current route.

```tsx
const params = useParams();
// For route /posts/:id → params.id
```

### useNavigate

Programmatic navigation (prefer `<Link>` or `redirect()` when possible).

```tsx
const navigate = useNavigate();

navigate("/dashboard");
navigate(-1);                          // Go back
navigate("/login", { replace: true }); // Replace history entry
navigate(".", { relative: "path" });   // Relative navigation
```

### useLocation

Access the current location object.

```tsx
const location = useLocation();
// { pathname, search, hash, state, key }
```

### useRouteLoaderData

Access loader data from any currently matched route by route ID.

```tsx
const rootData = useRouteLoaderData<typeof rootLoader>("root");
```

---

## Utility Functions

### redirect

Create a redirect Response. Use in loaders and actions.

```ts
import { redirect } from "react-router";

return redirect("/new-path");                    // 302 (default)
return redirect("/new-path", 301);               // 301 permanent
return redirect("/new-path", {
  headers: { "Set-Cookie": await commitSession(session) },
});
```

### data

Return data with custom status or headers (replaces `json()` in RR v7).

```ts
import { data } from "react-router";

return data({ errors }, { status: 400 });
return data({ result }, {
  headers: { "Set-Cookie": cookie },
});
```

### json (Remix v2 only, removed in RR v7)

```ts
import { json } from "@remix-run/node";
return json({ data }, { status: 200, headers: {} });
```

In React Router v7, return plain objects instead. Use `data()` for custom status/headers.

### isRouteErrorResponse

Type guard for checking if an error is a thrown Response.

```ts
import { isRouteErrorResponse } from "react-router";

if (isRouteErrorResponse(error)) {
  error.status;     // number
  error.statusText; // string
  error.data;       // response body
}
```

---

## Components

### Form

Progressive enhancement form — works without JS, uses client-side navigation with JS.

```tsx
import { Form } from "react-router";

<Form method="post" action="/submit" encType="multipart/form-data">
  <input name="title" />
  <button type="submit">Save</button>
</Form>

// GET form (for search/filters — updates URL search params)
<Form method="get" action="/search">
  <input name="q" />
  <button type="submit">Search</button>
</Form>
```

Props: `method`, `action`, `encType`, `replace`, `preventScrollReset`, `navigate`, `fetcherKey`, `reloadDocument`, `viewTransition`.

### fetcher.Form

Same as `<Form>` but doesn't trigger navigation. Tied to a specific fetcher instance.

```tsx
const fetcher = useFetcher();

<fetcher.Form method="post" action="/api/like">
  <button>Like</button>
</fetcher.Form>
```

### Await

Renders the resolved value of a promise (used with streaming/defer).

```tsx
import { Await } from "react-router";

<Suspense fallback={<Spinner />}>
  <Await resolve={loaderData.comments} errorElement={<p>Error loading comments</p>}>
    {(comments) => <CommentList comments={comments} />}
  </Await>
</Suspense>
```

Props: `resolve` (Promise), `errorElement` (fallback on rejection), `children` (render function or element).

### Link

Client-side navigation link.

```tsx
import { Link } from "react-router";

<Link to="/about">About</Link>
<Link to="/about" prefetch="intent">About</Link>  // Prefetch on hover/focus
<Link to="/about" prefetch="render">About</Link>   // Prefetch immediately
<Link to="/about" prefetch="viewport">About</Link> // Prefetch when visible
```

### NavLink

Link with active state styling.

```tsx
import { NavLink } from "react-router";

<NavLink
  to="/dashboard"
  className={({ isActive, isPending }) =>
    isActive ? "active" : isPending ? "pending" : ""
  }
  end  // Only match exact path
>
  Dashboard
</NavLink>
```

### Outlet

Renders the matched child route component.

```tsx
import { Outlet } from "react-router";

export default function Layout() {
  return (
    <div>
      <Header />
      <Outlet />  {/* Child route renders here */}
      <Footer />
    </div>
  );
}
```

### ScrollRestoration

Manages scroll position across navigations. Place in root route.

```tsx
import { ScrollRestoration } from "react-router";

// In root.tsx, before </body>
<ScrollRestoration />

// With custom key (e.g., restore per-pathname instead of per-key)
<ScrollRestoration getKey={(location) => location.pathname} />
```

---

## Session & Cookie APIs

### createCookieSessionStorage

```ts
import { createCookieSessionStorage } from "react-router";

const { getSession, commitSession, destroySession } = createCookieSessionStorage({
  cookie: {
    name: "__session",
    httpOnly: true,
    maxAge: 60 * 60 * 24 * 30,
    path: "/",
    sameSite: "lax",
    secrets: ["s3cr3t"],
    secure: true,
  },
});
```

### createSessionStorage

Custom session storage (e.g., database-backed).

```ts
import { createSessionStorage } from "react-router";

const { getSession, commitSession, destroySession } = createSessionStorage({
  cookie: { name: "__session", secrets: ["s3cr3t"] },
  async createData(data, expires) { /* save to DB, return ID */ },
  async readData(id) { /* read from DB */ },
  async updateData(id, data, expires) { /* update in DB */ },
  async deleteData(id) { /* delete from DB */ },
});
```

### createCookie

Low-level signed cookie API.

```ts
import { createCookie } from "react-router";

const cookie = createCookie("prefs", {
  maxAge: 60 * 60 * 24 * 365,
  secrets: ["s3cr3t"],
});

// In loader
const prefs = (await cookie.parse(request.headers.get("Cookie"))) ?? {};

// In action
return redirect("/", {
  headers: { "Set-Cookie": await cookie.serialize({ theme: "dark" }) },
});
```

---

## Route Configuration (routes.ts)

```ts
import { type RouteConfig, route, index, layout, prefix } from "@react-router/dev/routes";

export default [
  index("routes/home.tsx"),
  route("about", "routes/about.tsx"),
  ...prefix("blog", [
    index("routes/blog/index.tsx"),
    route(":slug", "routes/blog/post.tsx"),
  ]),
  layout("routes/auth-layout.tsx", [
    route("login", "routes/login.tsx"),
    route("register", "routes/register.tsx"),
  ]),
] satisfies RouteConfig;
```

### Flat Routes (Convention-Based)

```ts
import { flatRoutes } from "@react-router/fs-routes";
export default flatRoutes() satisfies RouteConfig;
```
