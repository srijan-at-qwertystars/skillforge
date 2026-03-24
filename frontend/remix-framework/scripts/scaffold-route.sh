#!/usr/bin/env bash
set -euo pipefail

# scaffold-route.sh — Generate a new Remix / React Router v7 route module
#
# Usage:
#   ./scaffold-route.sh <route-path>
#
# Examples:
#   ./scaffold-route.sh posts.\$postId       → app/routes/posts.$postId.tsx
#   ./scaffold-route.sh dashboard.settings   → app/routes/dashboard.settings.tsx
#   ./scaffold-route.sh _index               → app/routes/_index.tsx
#   ./scaffold-route.sh api.users            → app/routes/api.users.tsx
#
# The script creates a route file with loader, action, meta, error boundary,
# and component boilerplate. It detects the app directory from react-router.config.ts
# or defaults to "app".

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <route-path>"
  echo ""
  echo "Examples:"
  echo "  $0 posts.\\\$postId"
  echo "  $0 dashboard.settings"
  echo "  $0 _index"
  exit 1
fi

ROUTE_PATH="$1"
ROUTE_FILENAME="${ROUTE_PATH}.tsx"

# Find project root (look for package.json)
PROJECT_ROOT="$(pwd)"
while [[ ! -f "$PROJECT_ROOT/package.json" && "$PROJECT_ROOT" != "/" ]]; do
  PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done

if [[ ! -f "$PROJECT_ROOT/package.json" ]]; then
  echo "Error: Could not find package.json. Run this script from within a project."
  exit 1
fi

# Detect app directory
APP_DIR="app"
if [[ -f "$PROJECT_ROOT/react-router.config.ts" ]]; then
  DETECTED=$(grep -oP 'appDirectory:\s*"([^"]+)"' "$PROJECT_ROOT/react-router.config.ts" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  if [[ -n "$DETECTED" ]]; then
    APP_DIR="$DETECTED"
  fi
fi

ROUTES_DIR="$PROJECT_ROOT/$APP_DIR/routes"
OUTPUT_FILE="$ROUTES_DIR/$ROUTE_FILENAME"

# Check if file already exists
if [[ -f "$OUTPUT_FILE" ]]; then
  echo "Error: Route file already exists: $OUTPUT_FILE"
  exit 1
fi

# Create routes directory if needed
mkdir -p "$ROUTES_DIR"

# Derive a human-readable route name for display purposes
ROUTE_NAME=$(echo "$ROUTE_PATH" | sed 's/\.\$/\//g; s/\./\//g; s/_index/index/g; s/\$//g; s/_//g')
COMPONENT_NAME=$(echo "$ROUTE_PATH" | sed 's/[._$]/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1' | sed 's/ //g')

# Detect if this is likely a resource route (api. prefix)
IS_RESOURCE=false
if [[ "$ROUTE_PATH" == api.* || "$ROUTE_PATH" == api/* ]]; then
  IS_RESOURCE=true
fi

# Generate the types import path
TYPES_IMPORT="./+types/${ROUTE_PATH}"

if [[ "$IS_RESOURCE" == true ]]; then
  # Resource route template (no component)
  cat > "$OUTPUT_FILE" << TEMPLATE
import type { Route } from "${TYPES_IMPORT}";

export async function loader({ request, params }: Route.LoaderArgs) {
  const url = new URL(request.url);
  // TODO: Implement data fetching
  return Response.json({ message: "OK" });
}

export async function action({ request, params }: Route.ActionArgs) {
  switch (request.method) {
    case "POST": {
      const body = await request.json();
      // TODO: Implement creation
      return Response.json({ created: true }, { status: 201 });
    }
    case "PUT": {
      const body = await request.json();
      // TODO: Implement update
      return Response.json({ updated: true });
    }
    case "DELETE": {
      // TODO: Implement deletion
      return Response.json({ deleted: true });
    }
    default:
      return new Response("Method not allowed", { status: 405 });
  }
}
TEMPLATE
else
  # Full route module template
  cat > "$OUTPUT_FILE" << TEMPLATE
import type { Route } from "${TYPES_IMPORT}";
import { Form, isRouteErrorResponse, useRouteError } from "react-router";

export async function loader({ request, params }: Route.LoaderArgs) {
  // TODO: Implement data loading
  return { message: "Hello from ${ROUTE_NAME}" };
}

export async function action({ request, params }: Route.ActionArgs) {
  const formData = await request.formData();
  const intent = formData.get("intent");

  switch (intent) {
    // TODO: Implement form actions
    default:
      throw new Response("Invalid intent", { status: 400 });
  }
}

export function meta({ data }: Route.MetaArgs) {
  return [
    { title: "${COMPONENT_NAME}" },
    { name: "description", content: "${COMPONENT_NAME} page" },
  ];
}

export function headers({ loaderHeaders }: Route.HeadersArgs) {
  return {
    "Cache-Control": loaderHeaders.get("Cache-Control") ?? "no-cache",
  };
}

export default function ${COMPONENT_NAME}({ loaderData, actionData }: Route.ComponentProps) {
  return (
    <div>
      <h1>${COMPONENT_NAME}</h1>
      <p>{loaderData.message}</p>
    </div>
  );
}

export function ErrorBoundary() {
  const error = useRouteError();

  if (isRouteErrorResponse(error)) {
    return (
      <div>
        <h1>
          {error.status} {error.statusText}
        </h1>
        <p>{error.data}</p>
      </div>
    );
  }

  return (
    <div>
      <h1>Error</h1>
      <p>{error instanceof Error ? error.message : "An unexpected error occurred"}</p>
    </div>
  );
}
TEMPLATE
fi

echo "✅ Created route: $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "  1. Run 'npx react-router typegen' to generate types"
echo "  2. Implement the loader and action logic"
if [[ "$IS_RESOURCE" == false ]]; then
  echo "  3. Add the route to app/routes.ts (if not using flat routes)"
fi
