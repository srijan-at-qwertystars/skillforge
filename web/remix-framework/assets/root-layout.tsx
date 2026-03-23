/**
 * Root Layout — React Router v7 Framework Mode
 *
 * This is the top-level route module. It wraps every page in the app
 * with <html>, <head>, and <body> tags, global styles, scroll restoration,
 * and the root error boundary.
 */
import {
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
  useRouteError,
  isRouteErrorResponse,
} from "react-router";
import type { Route } from "./+types/root";

// Import global stylesheet (Tailwind or custom)
import "./app.css";

// ---------------------------------------------------------------------------
// Links — global stylesheets, favicons, fonts
// ---------------------------------------------------------------------------
export function links(): Route.LinkDescriptors {
  return [
    // Preconnect to font CDN for faster loading
    { rel: "preconnect", href: "https://fonts.googleapis.com" },
    {
      rel: "preconnect",
      href: "https://fonts.gstatic.com",
      crossOrigin: "anonymous",
    },
    // Web font
    {
      rel: "stylesheet",
      href: "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap",
    },
    // Favicon
    { rel: "icon", href: "/favicon.ico", sizes: "48x48" },
    { rel: "icon", href: "/favicon.svg", type: "image/svg+xml" },
    { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
    // Manifest
    { rel: "manifest", href: "/site.webmanifest" },
  ];
}

// ---------------------------------------------------------------------------
// Meta — default meta tags for the entire app
// ---------------------------------------------------------------------------
export function meta(): Route.MetaDescriptors {
  return [
    { charSet: "utf-8" },
    { name: "viewport", content: "width=device-width, initial-scale=1" },
    { title: "My App" },
    { name: "description", content: "A production React Router v7 application" },
    { name: "theme-color", content: "#ffffff" },
    // Open Graph
    { property: "og:type", content: "website" },
    { property: "og:site_name", content: "My App" },
  ];
}

// ---------------------------------------------------------------------------
// Loader — root-level data available to all routes
// ---------------------------------------------------------------------------
export async function loader({ request }: Route.LoaderArgs) {
  // Example: load user session, theme preference, feature flags
  // const user = await getOptionalUser(request);
  return {
    // user,
    ENV: {
      NODE_ENV: process.env.NODE_ENV,
      // Expose only safe, public env vars
    },
  };
}

// ---------------------------------------------------------------------------
// Layout — the HTML document shell
// ---------------------------------------------------------------------------
export function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="h-full">
      <head>
        <Meta />
        <Links />
      </head>
      <body className="h-full bg-white text-gray-900 antialiased">
        {children}

        {/* Restores scroll position on back/forward navigation */}
        <ScrollRestoration />

        {/* Inline env vars for client-side access */}
        <script
          dangerouslySetInnerHTML={{
            __html: `window.ENV = ${JSON.stringify({
              NODE_ENV: process.env.NODE_ENV,
            })}`,
          }}
        />

        {/* React Router scripts (hydration, client-side routing) */}
        <Scripts />
      </body>
    </html>
  );
}

// ---------------------------------------------------------------------------
// App — renders child routes via Outlet
// ---------------------------------------------------------------------------
export default function App({ loaderData }: Route.ComponentProps) {
  return <Outlet />;
}

// ---------------------------------------------------------------------------
// Error Boundary — root-level catch-all for unhandled errors
// ---------------------------------------------------------------------------
export function ErrorBoundary() {
  const error = useRouteError();

  if (isRouteErrorResponse(error)) {
    return (
      <main className="flex min-h-screen items-center justify-center p-4">
        <div className="text-center">
          <h1 className="text-6xl font-bold text-gray-300">{error.status}</h1>
          <p className="mt-2 text-xl text-gray-600">{error.statusText}</p>
          {error.data && <p className="mt-4 text-gray-500">{error.data}</p>}
          <a
            href="/"
            className="mt-6 inline-block rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700"
          >
            Go Home
          </a>
        </div>
      </main>
    );
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-4">
      <div className="text-center">
        <h1 className="text-4xl font-bold text-red-600">Something went wrong</h1>
        <p className="mt-2 text-gray-600">
          {error instanceof Error ? error.message : "An unexpected error occurred"}
        </p>
        <a
          href="/"
          className="mt-6 inline-block rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700"
        >
          Go Home
        </a>
      </div>
    </main>
  );
}
