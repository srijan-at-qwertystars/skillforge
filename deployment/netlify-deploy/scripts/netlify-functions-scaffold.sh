#!/usr/bin/env bash
# =============================================================================
# netlify-functions-scaffold.sh — Scaffold Netlify Functions
#
# Usage:
#   ./netlify-functions-scaffold.sh <type> <name> [options]
#
# Types:
#   serverless    Standard serverless function (Node.js/TypeScript)
#   edge          Edge function (Deno runtime, CDN edge)
#   scheduled     Scheduled function (cron-based)
#   background    Background function (long-running, up to 15 min)
#
# Options:
#   --dir <path>        Functions directory (default: netlify/functions)
#   --edge-dir <path>   Edge functions dir (default: netlify/edge-functions)
#   --js                Generate JavaScript instead of TypeScript
#   --method <methods>  HTTP methods to handle (e.g., "GET,POST")
#   --path <pattern>    URL path pattern for edge functions
#   --schedule <cron>   Cron expression for scheduled functions
#
# Examples:
#   ./netlify-functions-scaffold.sh serverless get-users
#   ./netlify-functions-scaffold.sh edge geo-redirect --path "/shop/*"
#   ./netlify-functions-scaffold.sh scheduled daily-sync --schedule "0 0 * * *"
#   ./netlify-functions-scaffold.sh background process-images
#   ./netlify-functions-scaffold.sh serverless submit-form --method "POST"
#   ./netlify-functions-scaffold.sh serverless hello --js
# =============================================================================
set -euo pipefail

# --- Parse Arguments ---

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <type> <name> [options]"
  echo "Types: serverless | edge | scheduled | background"
  echo "Run with --help for full usage."
  exit 1
fi

TYPE="$1"
NAME="$2"
shift 2

FUNCTIONS_DIR="netlify/functions"
EDGE_DIR="netlify/edge-functions"
LANG="ts"
METHODS="GET,POST"
URL_PATH=""
SCHEDULE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) FUNCTIONS_DIR="$2"; shift 2 ;;
    --edge-dir) EDGE_DIR="$2"; shift 2 ;;
    --js) LANG="js"; shift ;;
    --method) METHODS="$2"; shift 2 ;;
    --path) URL_PATH="$2"; shift 2 ;;
    --schedule) SCHEDULE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^# =====/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Scaffold Functions ---

scaffold_serverless() {
  local dir="$FUNCTIONS_DIR"
  local file="${dir}/${NAME}.${LANG}"
  mkdir -p "$dir"

  if [[ -f "$file" ]]; then
    echo "✗ File already exists: $file"
    exit 1
  fi

  if [[ "$LANG" == "ts" ]]; then
    cat > "$file" << 'TYPESCRIPT'
import type { Handler, HandlerEvent, HandlerContext, HandlerResponse } from "@netlify/functions";

interface RequestBody {
  // Define your request body shape
  [key: string]: unknown;
}

export const handler: Handler = async (
  event: HandlerEvent,
  context: HandlerContext
): Promise<HandlerResponse> => {
  const { httpMethod, queryStringParameters, body, headers, path } = event;

  // CORS headers
  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  };

  // Handle preflight
  if (httpMethod === "OPTIONS") {
    return { statusCode: 204, headers: corsHeaders, body: "" };
  }

  try {
    switch (httpMethod) {
      case "GET": {
        const name = queryStringParameters?.name || "World";
        return {
          statusCode: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          body: JSON.stringify({ message: `Hello, ${name}!` }),
        };
      }

      case "POST": {
        const data: RequestBody = JSON.parse(body || "{}");
        // Process data...
        return {
          statusCode: 201,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          body: JSON.stringify({ success: true, data }),
        };
      }

      default:
        return {
          statusCode: 405,
          headers: corsHeaders,
          body: JSON.stringify({ error: `Method ${httpMethod} not allowed` }),
        };
    }
  } catch (error) {
    console.error("Function error:", error);
    return {
      statusCode: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      body: JSON.stringify({ error: "Internal server error" }),
    };
  }
};
TYPESCRIPT
  else
    cat > "$file" << 'JAVASCRIPT'
exports.handler = async (event, context) => {
  const { httpMethod, queryStringParameters, body, headers } = event;

  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  };

  if (httpMethod === "OPTIONS") {
    return { statusCode: 204, headers: corsHeaders, body: "" };
  }

  try {
    switch (httpMethod) {
      case "GET": {
        const name = queryStringParameters?.name || "World";
        return {
          statusCode: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          body: JSON.stringify({ message: `Hello, ${name}!` }),
        };
      }

      case "POST": {
        const data = JSON.parse(body || "{}");
        return {
          statusCode: 201,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          body: JSON.stringify({ success: true, data }),
        };
      }

      default:
        return {
          statusCode: 405,
          headers: corsHeaders,
          body: JSON.stringify({ error: `Method ${httpMethod} not allowed` }),
        };
    }
  } catch (error) {
    console.error("Function error:", error);
    return {
      statusCode: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      body: JSON.stringify({ error: "Internal server error" }),
    };
  }
};
JAVASCRIPT
  fi

  echo "✓ Created serverless function: $file"
  echo "  → Endpoint: /.netlify/functions/${NAME}"
}

scaffold_edge() {
  local dir="$EDGE_DIR"
  local file="${dir}/${NAME}.${LANG}"
  local path_pattern="${URL_PATH:-"/${NAME}/*"}"
  mkdir -p "$dir"

  if [[ -f "$file" ]]; then
    echo "✗ File already exists: $file"
    exit 1
  fi

  if [[ "$LANG" == "ts" ]]; then
    cat > "$file" << TYPESCRIPT
import type { Context } from "@netlify/edge-functions";

export default async (request: Request, context: Context) => {
  // Available context:
  //   context.geo     — { city, country, subdivision, latitude, longitude, timezone }
  //   context.ip      — client IP address
  //   context.next()  — pass through to origin / next middleware
  //   context.json()  — helper to return JSON
  //   context.rewrite() — rewrite to different URL
  //   Netlify.env.get("VAR") — access environment variables

  const url = new URL(request.url);
  const country = context.geo.country?.code || "US";

  // Option 1: Transform the origin response
  const response = await context.next();
  const html = await response.text();
  const modified = html.replace("{{COUNTRY}}", country);

  return new Response(modified, {
    status: response.status,
    headers: response.headers,
  });

  // Option 2: Return a direct response (bypass origin)
  // return context.json({ country, path: url.pathname });
};

export const config = { path: "${path_pattern}" };
TYPESCRIPT
  else
    cat > "$file" << JAVASCRIPT
export default async (request, context) => {
  const url = new URL(request.url);
  const country = context.geo.country?.code || "US";

  const response = await context.next();
  const html = await response.text();
  const modified = html.replace("{{COUNTRY}}", country);

  return new Response(modified, {
    status: response.status,
    headers: response.headers,
  });
};

export const config = { path: "${path_pattern}" };
JAVASCRIPT
  fi

  echo "✓ Created edge function: $file"
  echo "  → Path: ${path_pattern}"
  echo ""
  echo "  Register in netlify.toml:"
  echo "  [[edge_functions]]"
  echo "    path = \"${path_pattern}\""
  echo "    function = \"${NAME}\""
}

scaffold_scheduled() {
  local dir="$FUNCTIONS_DIR"
  local file="${dir}/${NAME}.${LANG}"
  local cron="${SCHEDULE:-"0 0 * * *"}"
  mkdir -p "$dir"

  if [[ -f "$file" ]]; then
    echo "✗ File already exists: $file"
    exit 1
  fi

  if [[ "$LANG" == "ts" ]]; then
    cat > "$file" << TYPESCRIPT
import { schedule } from "@netlify/functions";

// Cron: ${cron}
// ┌────────── minute (0-59)
// │ ┌──────── hour (0-23)
// │ │ ┌────── day of month (1-31)
// │ │ │ ┌──── month (1-12)
// │ │ │ │ ┌── day of week (0-6, Sun=0)
// │ │ │ │ │
// * * * * *

export const handler = schedule("${cron}", async (event) => {
  console.log("Scheduled function triggered at:", new Date().toISOString());
  console.log("Next run:", event.next_run);

  try {
    // Your scheduled work here
    // Examples:
    //   - Clean up stale data
    //   - Send digest emails
    //   - Sync with external APIs
    //   - Generate reports
    //   - Warm caches

    console.log("Scheduled task completed successfully");
    return { statusCode: 200 };
  } catch (error) {
    console.error("Scheduled task failed:", error);
    return { statusCode: 500 };
  }
});
TYPESCRIPT
  else
    cat > "$file" << JAVASCRIPT
const { schedule } = require("@netlify/functions");

// Cron: ${cron}
module.exports.handler = schedule("${cron}", async (event) => {
  console.log("Scheduled function triggered at:", new Date().toISOString());

  try {
    // Your scheduled work here
    console.log("Scheduled task completed successfully");
    return { statusCode: 200 };
  } catch (error) {
    console.error("Scheduled task failed:", error);
    return { statusCode: 500 };
  }
});
JAVASCRIPT
  fi

  echo "✓ Created scheduled function: $file"
  echo "  → Schedule: ${cron}"
  echo ""
  echo "  Alternative: register in netlify.toml:"
  echo "  [functions.\"${NAME}\"]"
  echo "    schedule = \"${cron}\""
}

scaffold_background() {
  local dir="$FUNCTIONS_DIR"
  local file="${dir}/${NAME}-background.${LANG}"
  mkdir -p "$dir"

  if [[ -f "$file" ]]; then
    echo "✗ File already exists: $file"
    exit 1
  fi

  if [[ "$LANG" == "ts" ]]; then
    cat > "$file" << 'TYPESCRIPT'
import type { Handler, HandlerEvent, HandlerResponse } from "@netlify/functions";

// Background function — runs up to 15 minutes (Pro plan required)
// The caller receives 202 Accepted immediately.
// The return value is ignored by Netlify.

interface BackgroundPayload {
  // Define your payload shape
  taskId: string;
  data: Record<string, unknown>;
}

export const handler: Handler = async (event: HandlerEvent): Promise<HandlerResponse> => {
  const startTime = Date.now();

  try {
    const payload: BackgroundPayload = JSON.parse(event.body || "{}");
    console.log(`Background task started: ${payload.taskId}`);

    // --- Your long-running work here ---
    // Examples:
    //   - Process large file uploads
    //   - Generate PDFs or reports
    //   - Batch API calls
    //   - Data migration / ETL
    //   - Send bulk emails
    //   - Video/image processing

    // Simulate work
    await doWork(payload);

    // Optionally notify completion via webhook/email
    if (process.env.WEBHOOK_URL) {
      await fetch(process.env.WEBHOOK_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          taskId: payload.taskId,
          status: "completed",
          duration: Date.now() - startTime,
        }),
      });
    }

    console.log(`Background task completed in ${Date.now() - startTime}ms`);
  } catch (error) {
    console.error("Background task failed:", error);

    // Notify failure
    if (process.env.WEBHOOK_URL) {
      await fetch(process.env.WEBHOOK_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          status: "failed",
          error: (error as Error).message,
        }),
      });
    }
  }

  // Return value is ignored for background functions
  return { statusCode: 200, body: "" };
};

async function doWork(payload: BackgroundPayload): Promise<void> {
  // Replace with your actual work
  console.log("Processing:", payload);
}
TYPESCRIPT
  else
    cat > "$file" << 'JAVASCRIPT'
// Background function — runs up to 15 minutes (Pro plan required)
// The caller receives 202 Accepted immediately.

exports.handler = async (event) => {
  const startTime = Date.now();

  try {
    const payload = JSON.parse(event.body || "{}");
    console.log(`Background task started: ${payload.taskId}`);

    // Your long-running work here
    await doWork(payload);

    if (process.env.WEBHOOK_URL) {
      await fetch(process.env.WEBHOOK_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          taskId: payload.taskId,
          status: "completed",
          duration: Date.now() - startTime,
        }),
      });
    }

    console.log(`Background task completed in ${Date.now() - startTime}ms`);
  } catch (error) {
    console.error("Background task failed:", error);
  }

  return { statusCode: 200, body: "" };
};

async function doWork(payload) {
  console.log("Processing:", payload);
}
JAVASCRIPT
  fi

  echo "✓ Created background function: $file"
  echo "  → Endpoint: /.netlify/functions/${NAME}-background"
  echo "  → Caller receives 202 immediately; function runs up to 15 min"
  echo "  → Requires Netlify Pro plan or higher"
}

# --- Generate TypeScript Types ---

generate_types() {
  local dir="$FUNCTIONS_DIR"
  local file="${dir}/types.d.ts"

  if [[ -f "$file" ]]; then
    echo "  (types.d.ts already exists — skipping)"
    return
  fi

  cat > "$file" << 'TYPES'
// Shared TypeScript types for Netlify Functions
// Auto-generated by netlify-functions-scaffold.sh

/** Standard API response wrapper */
export interface ApiResponse<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
  meta?: {
    page?: number;
    total?: number;
    timestamp: string;
  };
}

/** Netlify Identity user from context.clientContext */
export interface NetlifyUser {
  email: string;
  sub: string;
  app_metadata: {
    provider: string;
    roles: string[];
  };
  user_metadata: {
    full_name?: string;
    avatar_url?: string;
  };
}

/** Common event query parameters */
export interface PaginationParams {
  page?: string;
  limit?: string;
  sort?: string;
  order?: "asc" | "desc";
}

/** Webhook payload base */
export interface WebhookPayload {
  event: string;
  timestamp: string;
  data: Record<string, unknown>;
  signature?: string;
}
TYPES

  echo "✓ Created shared types: $file"
}

# --- Execute ---

case "$TYPE" in
  serverless) scaffold_serverless ;;
  edge)       scaffold_edge ;;
  scheduled)  scaffold_scheduled ;;
  background) scaffold_background ;;
  *)
    echo "✗ Unknown function type: $TYPE"
    echo "  Valid types: serverless, edge, scheduled, background"
    exit 1
    ;;
esac

# Generate types for TS projects
if [[ "$LANG" == "ts" ]]; then
  generate_types
fi

echo ""
echo "Done! Test locally with: netlify dev"
