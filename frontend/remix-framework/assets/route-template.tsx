/**
 * Route Module Template — Remix / React Router v7
 *
 * Copy this file and rename to your route (e.g., app/routes/posts.$postId.tsx).
 * Then update the types import path and implement your logic.
 *
 * Exports: loader, action, meta, headers, links, handle, shouldRevalidate,
 *          default component, ErrorBoundary
 */

import type { Route } from "./+types/ROUTE_NAME";
import { data, redirect, Form, isRouteErrorResponse, useRouteError } from "react-router";
import { Suspense } from "react";
import { Await } from "react-router";

// ---------------------------------------------------------------------------
// Loader — server-side data fetching (runs on SSR and client navigations)
// ---------------------------------------------------------------------------
export async function loader({ request, params, context }: Route.LoaderArgs) {
  const url = new URL(request.url);

  // Example: fetch data with error handling
  // const item = await db.item.findUnique({ where: { id: params.id } });
  // if (!item) throw new Response("Not Found", { status: 404 });

  // Example: parallel fetching
  // const [item, related] = await Promise.all([
  //   getItem(params.id),
  //   getRelated(params.id),
  // ]);

  // Example: streaming non-critical data (don't await the promise)
  // const comments = getComments(params.id); // returns Promise, not awaited

  return {
    message: "Hello, World!",
    // item,
    // related,
    // comments, // streamed — use <Await> in component
  };
}

// ---------------------------------------------------------------------------
// Action — server-side mutation handler (runs on non-GET form submissions)
// ---------------------------------------------------------------------------
export async function action({ request, params, context }: Route.ActionArgs) {
  const formData = await request.formData();
  const intent = formData.get("intent");

  switch (intent) {
    case "create": {
      // const title = formData.get("title") as string;
      // if (!title) return data({ errors: { title: "Required" } }, { status: 400 });
      // const item = await db.item.create({ data: { title } });
      // return redirect(`/items/${item.id}`);
      break;
    }

    case "update": {
      // const title = formData.get("title") as string;
      // await db.item.update({ where: { id: params.id }, data: { title } });
      // return { success: true };
      break;
    }

    case "delete": {
      // await db.item.delete({ where: { id: params.id } });
      // return redirect("/items");
      break;
    }

    default:
      throw new Response(`Invalid intent: ${intent}`, { status: 400 });
  }
}

// ---------------------------------------------------------------------------
// Meta — <head> meta tags
// ---------------------------------------------------------------------------
export function meta({ data, params, matches, location }: Route.MetaArgs) {
  if (!data) {
    return [{ title: "Not Found" }];
  }

  return [
    { title: "Page Title" },
    { name: "description", content: "Page description" },
    // Open Graph
    // { property: "og:title", content: "OG Title" },
    // { property: "og:description", content: "OG Description" },
    // { property: "og:image", content: "https://example.com/og.png" },
    // Canonical URL
    // { tagName: "link", rel: "canonical", href: `https://example.com${location.pathname}` },
  ];
}

// ---------------------------------------------------------------------------
// Headers — HTTP response headers
// ---------------------------------------------------------------------------
export function headers({ loaderHeaders, parentHeaders }: Route.HeadersArgs) {
  return {
    "Cache-Control": loaderHeaders.get("Cache-Control") ?? "no-cache",
  };
}

// ---------------------------------------------------------------------------
// Links — <link> elements for stylesheets, fonts, etc.
// ---------------------------------------------------------------------------
export function links(): Route.LinkDescriptors {
  return [
    // { rel: "stylesheet", href: "/styles/page.css" },
    // { rel: "preload", href: "/fonts/inter.woff2", as: "font", type: "font/woff2", crossOrigin: "anonymous" },
  ];
}

// ---------------------------------------------------------------------------
// Handle — arbitrary data exposed via useMatches() (breadcrumbs, i18n, etc.)
// ---------------------------------------------------------------------------
export const handle = {
  // breadcrumb: (match: UIMatch) => <Link to={match.pathname}>Page</Link>,
  // i18n: ["common"],
};

// ---------------------------------------------------------------------------
// shouldRevalidate — control when this route's loader re-runs
// ---------------------------------------------------------------------------
export function shouldRevalidate({
  currentUrl,
  nextUrl,
  formMethod,
  defaultShouldRevalidate,
}: {
  currentUrl: URL;
  nextUrl: URL;
  formMethod?: string;
  defaultShouldRevalidate: boolean;
}) {
  // Example: skip revalidation if only search params changed
  // if (currentUrl.pathname === nextUrl.pathname) return false;
  return defaultShouldRevalidate;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------
export default function RouteName({ loaderData, actionData }: Route.ComponentProps) {
  return (
    <div>
      <h1>Route Template</h1>
      <p>{loaderData.message}</p>

      {/* Example: Form with action */}
      {/*
      <Form method="post">
        <input name="title" required />
        <button type="submit" name="intent" value="create">Create</button>
      </Form>
      */}

      {/* Example: Streamed data */}
      {/*
      <Suspense fallback={<p>Loading comments...</p>}>
        <Await resolve={loaderData.comments} errorElement={<p>Error loading comments</p>}>
          {(comments) => (
            <ul>
              {comments.map((c) => <li key={c.id}>{c.text}</li>)}
            </ul>
          )}
        </Await>
      </Suspense>
      */}
    </div>
  );
}

// ---------------------------------------------------------------------------
// ErrorBoundary — catches loader, action, and render errors
// ---------------------------------------------------------------------------
export function ErrorBoundary() {
  const error = useRouteError();

  // Thrown Response (expected errors: 404, 403, etc.)
  if (isRouteErrorResponse(error)) {
    return (
      <div className="error-container">
        <h1>
          {error.status} {error.statusText}
        </h1>
        <p>{error.data}</p>
      </div>
    );
  }

  // Thrown Error (unexpected failures)
  return (
    <div className="error-container">
      <h1>Unexpected Error</h1>
      <p>{error instanceof Error ? error.message : "An unknown error occurred"}</p>
      {process.env.NODE_ENV === "development" && error instanceof Error && (
        <pre>{error.stack}</pre>
      )}
    </div>
  );
}
