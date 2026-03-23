#!/usr/bin/env bash
# create-route.sh — Generate a new React Router v7 route module
#
# Usage:
#   ./create-route.sh <route-path> [--resource] [--layout]
#
# Examples:
#   ./create-route.sh products.\$id          # Dynamic route: /products/:id
#   ./create-route.sh dashboard._index       # Dashboard index route
#   ./create-route.sh api.users --resource   # Resource route (no component)
#   ./create-route.sh dashboard --layout     # Layout route with Outlet
#
# Creates the file in app/routes/ with loader, action, component, meta,
# links, and error boundary boilerplate.

set -euo pipefail

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Parse arguments ---
ROUTE_PATH=""
IS_RESOURCE=false
IS_LAYOUT=false

for arg in "$@"; do
  case "$arg" in
    --resource) IS_RESOURCE=true ;;
    --layout)   IS_LAYOUT=true ;;
    --help|-h)
      head -16 "$0" | tail -14
      exit 0
      ;;
    *)
      if [[ -z "$ROUTE_PATH" ]]; then
        ROUTE_PATH="$arg"
      else
        echo -e "${RED}Error: unexpected argument '$arg'${NC}" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$ROUTE_PATH" ]]; then
  echo -e "${RED}Error: route path is required${NC}" >&2
  echo "Usage: $0 <route-path> [--resource] [--layout]"
  exit 1
fi

# --- Find app/routes directory ---
ROUTES_DIR="app/routes"
if [[ ! -d "$ROUTES_DIR" ]]; then
  echo -e "${RED}Error: $ROUTES_DIR directory not found. Run from project root.${NC}" >&2
  exit 1
fi

# --- Determine file path ---
FILENAME="${ROUTE_PATH}.tsx"
FILEPATH="${ROUTES_DIR}/${FILENAME}"

if [[ -f "$FILEPATH" ]]; then
  echo -e "${RED}Error: $FILEPATH already exists${NC}" >&2
  exit 1
fi

# --- Derive type import path ---
TYPE_PATH="./+types/${ROUTE_PATH}"

# --- Generate content ---
if $IS_RESOURCE; then
  cat > "$FILEPATH" << EOF
import type { Route } from "${TYPE_PATH}";

/**
 * Resource route — no default export, serves non-HTML responses.
 * URL: /${ROUTE_PATH//\./\/}
 */

export async function loader({ request, params }: Route.LoaderArgs) {
  // TODO: implement data fetching
  const data = {};
  return Response.json(data, {
    headers: {
      "Cache-Control": "public, max-age=60",
    },
  });
}

export async function action({ request, params }: Route.ActionArgs) {
  const method = request.method;

  if (method === "POST") {
    const body = await request.json();
    // TODO: handle creation
    return Response.json({ success: true }, { status: 201 });
  }

  return Response.json({ error: "Method not allowed" }, { status: 405 });
}
EOF
elif $IS_LAYOUT; then
  cat > "$FILEPATH" << EOF
import type { Route } from "${TYPE_PATH}";
import { Outlet, useRouteError, isRouteErrorResponse } from "react-router";

export async function loader({ request }: Route.LoaderArgs) {
  // TODO: load shared layout data (nav items, user info, etc.)
  return {};
}

export function meta({ data }: Route.MetaArgs) {
  return [{ title: "${ROUTE_PATH} | App" }];
}

export default function ${ROUTE_PATH^}Layout({ loaderData }: Route.ComponentProps) {
  return (
    <div>
      <nav>{/* shared navigation */}</nav>
      <main>
        <Outlet />
      </main>
    </div>
  );
}

export function ErrorBoundary() {
  const error = useRouteError();

  if (isRouteErrorResponse(error)) {
    return (
      <div>
        <h1>{error.status} {error.statusText}</h1>
        <p>{error.data}</p>
      </div>
    );
  }

  return (
    <div>
      <h1>Error</h1>
      <p>{error instanceof Error ? error.message : "Unknown error"}</p>
    </div>
  );
}
EOF
else
  cat > "$FILEPATH" << EOF
import type { Route } from "${TYPE_PATH}";
import { Form, useRouteError, isRouteErrorResponse } from "react-router";

export async function loader({ request, params }: Route.LoaderArgs) {
  // TODO: fetch data
  return {};
}

export async function action({ request, params }: Route.ActionArgs) {
  const formData = await request.formData();
  // TODO: handle mutation

  // Return validation errors or redirect
  return { success: true };
}

export function meta({ data }: Route.MetaArgs) {
  return [
    { title: "${ROUTE_PATH} | App" },
    { name: "description", content: "TODO: add description" },
  ];
}

export function links() {
  return [];
}

export default function ${ROUTE_PATH^}Page({ loaderData, actionData }: Route.ComponentProps) {
  return (
    <div>
      <h1>${ROUTE_PATH}</h1>
      {/* TODO: implement UI */}
    </div>
  );
}

export function ErrorBoundary() {
  const error = useRouteError();

  if (isRouteErrorResponse(error)) {
    return (
      <div>
        <h1>{error.status} {error.statusText}</h1>
        <p>{error.data}</p>
      </div>
    );
  }

  return (
    <div>
      <h1>Unexpected Error</h1>
      <p>{error instanceof Error ? error.message : "Unknown error"}</p>
    </div>
  );
}
EOF
fi

echo -e "${GREEN}✓ Created ${FILEPATH}${NC}"
if $IS_RESOURCE; then
  echo -e "  Type: ${YELLOW}resource route${NC} (no UI)"
elif $IS_LAYOUT; then
  echo -e "  Type: ${YELLOW}layout route${NC} (renders <Outlet />)"
else
  echo -e "  Type: ${YELLOW}page route${NC} (loader + action + component)"
fi
echo -e "  Run: ${YELLOW}npx react-router typegen${NC} to generate types"
