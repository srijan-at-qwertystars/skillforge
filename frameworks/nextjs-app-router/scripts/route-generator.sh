#!/usr/bin/env bash
# route-generator.sh — Generate a Next.js App Router route with all conventions
# Usage: ./route-generator.sh <route-path> [--api]
# Examples:
#   ./route-generator.sh dashboard/settings     → src/app/dashboard/settings/{page,layout,loading,error}.tsx
#   ./route-generator.sh blog/[slug]            → src/app/blog/[slug]/{page,layout,loading,error}.tsx
#   ./route-generator.sh api/users --api        → src/app/api/users/route.ts (API route handler only)

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <route-path> [--api]"
  echo ""
  echo "Examples:"
  echo "  $0 dashboard/settings"
  echo "  $0 blog/[slug]"
  echo "  $0 api/users --api"
  exit 1
fi

ROUTE_PATH="$1"
IS_API=false

if [ "${2:-}" = "--api" ]; then
  IS_API=true
fi

# Determine base directory
if [ -d "src/app" ]; then
  BASE_DIR="src/app"
elif [ -d "app" ]; then
  BASE_DIR="app"
else
  echo "Error: No app/ or src/app/ directory found. Run from project root."
  exit 1
fi

FULL_PATH="$BASE_DIR/$ROUTE_PATH"
mkdir -p "$FULL_PATH"

# Extract route name for component naming
ROUTE_NAME=$(basename "$ROUTE_PATH" | sed 's/\[//g; s/\]//g; s/\.\.\.//g')
# Convert to PascalCase
COMPONENT_NAME=$(echo "$ROUTE_NAME" | sed -r 's/(^|-)(\w)/\U\2/g')

if [ "$IS_API" = true ]; then
  # Generate API route handler
  cat > "$FULL_PATH/route.ts" << ROUTE
import { NextRequest, NextResponse } from "next/server";

export async function GET(request: NextRequest) {
  try {
    // TODO: implement GET handler
    return NextResponse.json({ message: "OK" });
  } catch (error) {
    console.error("GET /${ROUTE_PATH} error:", error);
    return NextResponse.json(
      { error: "Internal Server Error" },
      { status: 500 }
    );
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    // TODO: validate and process request body
    return NextResponse.json({ message: "Created" }, { status: 201 });
  } catch (error) {
    console.error("POST /${ROUTE_PATH} error:", error);
    return NextResponse.json(
      { error: "Internal Server Error" },
      { status: 500 }
    );
  }
}
ROUTE

  echo "✅ API route created: $FULL_PATH/route.ts"
  exit 0
fi

# Detect if route has dynamic segments
HAS_PARAMS=false
PARAMS_TYPE=""
if echo "$ROUTE_PATH" | grep -q '\['; then
  HAS_PARAMS=true
  # Extract param names for type definition
  PARAMS_TYPE=$(echo "$ROUTE_PATH" | grep -oP '\[\[?\.\.\.]?\K\w+' | head -1)
fi

# Generate page.tsx
if [ "$HAS_PARAMS" = true ]; then
  cat > "$FULL_PATH/page.tsx" << PAGE
export default async function ${COMPONENT_NAME}Page({
  params,
}: {
  params: Promise<{ ${PARAMS_TYPE}: string }>;
}) {
  const { ${PARAMS_TYPE} } = await params;

  return (
    <div>
      <h1>${COMPONENT_NAME}</h1>
      <p>Param: {${PARAMS_TYPE}}</p>
    </div>
  );
}
PAGE
else
  cat > "$FULL_PATH/page.tsx" << PAGE
export default function ${COMPONENT_NAME}Page() {
  return (
    <div>
      <h1>${COMPONENT_NAME}</h1>
    </div>
  );
}
PAGE
fi

# Generate layout.tsx
cat > "$FULL_PATH/layout.tsx" << LAYOUT
export default function ${COMPONENT_NAME}Layout({
  children,
}: {
  children: React.ReactNode;
}) {
  return <section>{children}</section>;
}
LAYOUT

# Generate loading.tsx
cat > "$FULL_PATH/loading.tsx" << LOADING
export default function ${COMPONENT_NAME}Loading() {
  return (
    <div className="flex items-center justify-center p-8">
      <div className="animate-spin h-8 w-8 border-4 border-gray-300 border-t-blue-500 rounded-full" />
    </div>
  );
}
LOADING

# Generate error.tsx
cat > "$FULL_PATH/error.tsx" << 'ERROR'
"use client";

import { useEffect } from "react";

export default function ErrorBoundary({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <div className="flex flex-col items-center justify-center gap-4 p-8">
      <h2 className="text-xl font-semibold">Something went wrong</h2>
      <p className="text-gray-600">{error.message}</p>
      <button
        onClick={reset}
        className="px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600"
      >
        Try again
      </button>
    </div>
  );
}
ERROR

echo "✅ Route generated: $FULL_PATH/"
echo "   ├── page.tsx"
echo "   ├── layout.tsx"
echo "   ├── loading.tsx"
echo "   └── error.tsx"
