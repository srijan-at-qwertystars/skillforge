/**
 * Route Template — React Router v7 Framework Mode
 *
 * Copy this file to app/routes/<name>.tsx and customize.
 * Run `npx react-router typegen` after adding to generate types.
 */
import type { Route } from "./+types/ROUTE_NAME";
import {
  Form,
  useNavigation,
  useRouteError,
  isRouteErrorResponse,
} from "react-router";

// ---------------------------------------------------------------------------
// Loader — runs on the server for GET requests
// ---------------------------------------------------------------------------
export async function loader({ request, params }: Route.LoaderArgs) {
  // Access URL search params
  const url = new URL(request.url);
  const page = Number(url.searchParams.get("page") ?? "1");

  // Pass request.signal to downstream fetches for cancellation
  // const data = await fetch("...", { signal: request.signal });

  // Throw Response for expected errors
  // if (!data) throw new Response("Not Found", { status: 404 });

  return {
    page,
    // items: data,
  };
}

// ---------------------------------------------------------------------------
// Action — runs on the server for non-GET form submissions
// ---------------------------------------------------------------------------
export async function action({ request, params }: Route.ActionArgs) {
  const formData = await request.formData();
  const intent = formData.get("intent");

  // Validate
  const errors: Record<string, string> = {};
  // if (!formData.get("name")) errors.name = "Name is required";
  if (Object.keys(errors).length > 0) {
    return { errors };
  }

  // Perform mutation based on intent
  switch (intent) {
    case "create":
      // await db.item.create({ data: { ... } });
      break;
    case "delete":
      // await db.item.delete({ where: { id: params.id } });
      break;
    default:
      return { errors: { form: `Unknown intent: ${intent}` } };
  }

  // Redirect after successful mutation (Post/Redirect/Get)
  // return redirect("/success");
  return { success: true };
}

// ---------------------------------------------------------------------------
// Meta — page title and meta tags
// ---------------------------------------------------------------------------
export function meta({ data }: Route.MetaArgs) {
  return [
    { title: "Page Title" },
    { name: "description", content: "Page description for SEO" },
    { property: "og:title", content: "Page Title" },
  ];
}

// ---------------------------------------------------------------------------
// Links — stylesheets, preloads, canonical URLs
// ---------------------------------------------------------------------------
export function links(): Route.LinkDescriptors {
  return [
    // { rel: "stylesheet", href: "/styles/page.css" },
    // { rel: "canonical", href: "https://example.com/page" },
    // { rel: "preload", href: "/fonts/inter.woff2", as: "font", type: "font/woff2", crossOrigin: "anonymous" },
  ];
}

// ---------------------------------------------------------------------------
// Headers — HTTP response headers
// ---------------------------------------------------------------------------
export function headers({ loaderHeaders }: Route.HeadersArgs) {
  return {
    "Cache-Control": loaderHeaders.get("Cache-Control") ?? "private, max-age=0",
  };
}

// ---------------------------------------------------------------------------
// Component — the route's UI
// ---------------------------------------------------------------------------
export default function RoutePage({ loaderData, actionData }: Route.ComponentProps) {
  const navigation = useNavigation();
  const isSubmitting = navigation.state === "submitting";

  return (
    <div>
      <h1>Route Page</h1>

      {actionData?.errors?.form && (
        <div role="alert" className="error">
          {actionData.errors.form}
        </div>
      )}

      <Form method="post">
        {/* Form fields */}
        <input type="hidden" name="intent" value="create" />
        <button type="submit" disabled={isSubmitting}>
          {isSubmitting ? "Saving…" : "Save"}
        </button>
      </Form>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Error Boundary — catches errors from loader, action, or rendering
// ---------------------------------------------------------------------------
export function ErrorBoundary() {
  const error = useRouteError();

  if (isRouteErrorResponse(error)) {
    return (
      <div role="alert">
        <h1>
          {error.status} {error.statusText}
        </h1>
        <p>{error.data}</p>
      </div>
    );
  }

  return (
    <div role="alert">
      <h1>Unexpected Error</h1>
      <p>{error instanceof Error ? error.message : "An unknown error occurred"}</p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// shouldRevalidate — control when this route's loader reruns (optional)
// ---------------------------------------------------------------------------
export function shouldRevalidate({
  currentUrl,
  nextUrl,
  defaultShouldRevalidate,
}: Route.ShouldRevalidateFunctionArgs) {
  // Skip revalidation when only hash changes
  if (currentUrl.pathname === nextUrl.pathname) {
    return false;
  }
  return defaultShouldRevalidate;
}
