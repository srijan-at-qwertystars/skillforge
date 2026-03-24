/**
 * edge-function-template.ts — Supabase Edge Function (Deno Deploy)
 *
 * This is a template for a Supabase Edge Function using the modern Deno.serve() API.
 *
 * Features:
 *   - CORS preflight handling
 *   - JWT authentication via Supabase Auth
 *   - Request method routing (GET, POST, PUT, DELETE)
 *   - Structured JSON error responses
 *   - Type-safe database queries
 *
 * Deployment:
 *   supabase functions new my-function
 *   # Replace the generated index.ts with this template
 *   supabase functions deploy my-function
 *
 * Local testing:
 *   supabase functions serve my-function --env-file .env.local
 *   curl -i http://localhost:54321/functions/v1/my-function \
 *     -H "Authorization: Bearer <anon-key>"
 *
 * Deno-specific notes:
 *   - Edge Functions run on Deno, not Node.js — use URL imports or import maps
 *   - `Deno.env.get()` reads environment variables (no process.env)
 *   - Top-level await is supported
 *   - npm packages can be imported via `npm:` specifier (e.g., `import _ from "npm:lodash"`)
 */

// ---------------------------------------------------------------------------
// Imports (use esm.sh or deno.land for Deno-compatible modules)
// ---------------------------------------------------------------------------
// @deno-types is a Deno-specific directive that provides type information.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// CORS Headers
// ---------------------------------------------------------------------------

/**
 * CORS headers included in every response.
 * Adjust `Access-Control-Allow-Origin` for production — avoid using "*" if
 * your function handles sensitive data.
 */
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*", // TODO: restrict to your domain in production
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "Authorization, Content-Type, x-client-info, apikey",
  "Access-Control-Max-Age": "86400", // Cache preflight for 24 hours
};

// ---------------------------------------------------------------------------
// Response Helpers
// ---------------------------------------------------------------------------

/** Return a JSON success response. */
function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

/** Return a structured JSON error response. */
function errorResponse(
  message: string,
  status = 400,
  code?: string
): Response {
  return new Response(
    JSON.stringify({
      error: { message, code: code ?? `HTTP_${status}` },
    }),
    {
      status,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    }
  );
}

// ---------------------------------------------------------------------------
// Auth Helpers
// ---------------------------------------------------------------------------

/**
 * Extract the JWT from the Authorization header and create an authenticated
 * Supabase client scoped to the calling user.
 *
 * The client respects RLS policies, so queries return only rows the user
 * is authorized to see.
 *
 * @throws Returns an error response if the token is missing or invalid.
 */
async function getAuthenticatedClient(
  req: Request
): Promise<{ client: SupabaseClient; userId: string } | Response> {
  const authHeader = req.headers.get("Authorization");

  if (!authHeader?.startsWith("Bearer ")) {
    return errorResponse("Missing or malformed Authorization header", 401, "UNAUTHORIZED");
  }

  const token = authHeader.replace("Bearer ", "");

  // Create a Supabase client authenticated as the requesting user
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    {
      global: {
        headers: { Authorization: `Bearer ${token}` },
      },
    }
  );

  // Verify the token and get the user
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();

  if (error || !user) {
    return errorResponse(
      error?.message ?? "Invalid or expired token",
      401,
      "UNAUTHORIZED"
    );
  }

  return { client: supabase, userId: user.id };
}

/**
 * Create a Supabase admin client using the service role key.
 * This client bypasses RLS — use only when necessary.
 */
function getAdminClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } }
  );
}

// ---------------------------------------------------------------------------
// Request Handlers
// ---------------------------------------------------------------------------

/** Handle GET requests — fetch data. */
async function handleGet(
  client: SupabaseClient,
  userId: string,
  url: URL
): Promise<Response> {
  // Example: fetch user's items with optional pagination
  const page = parseInt(url.searchParams.get("page") ?? "1", 10);
  const limit = Math.min(parseInt(url.searchParams.get("limit") ?? "20", 10), 100);
  const offset = (page - 1) * limit;

  const { data, error, count } = await client
    .from("items") // TODO: replace with your table name
    .select("*", { count: "exact" })
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .range(offset, offset + limit - 1);

  if (error) {
    return errorResponse(error.message, 500, "DB_ERROR");
  }

  return jsonResponse({ data, pagination: { page, limit, total: count } });
}

/** Handle POST requests — create data. */
async function handlePost(
  client: SupabaseClient,
  userId: string,
  req: Request
): Promise<Response> {
  // Parse and validate the request body
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return errorResponse("Invalid JSON in request body", 400, "INVALID_JSON");
  }

  // Basic validation — extend with a schema validator (e.g., Zod) for production
  if (!body.title || typeof body.title !== "string") {
    return errorResponse("Field 'title' is required and must be a string", 422, "VALIDATION_ERROR");
  }

  const { data, error } = await client
    .from("items") // TODO: replace with your table name
    .insert({
      user_id: userId,
      title: body.title,
      description: body.description ?? null,
    })
    .select()
    .single();

  if (error) {
    return errorResponse(error.message, 500, "DB_ERROR");
  }

  return jsonResponse({ data }, 201);
}

/** Handle PUT requests — update data. */
async function handlePut(
  client: SupabaseClient,
  userId: string,
  req: Request,
  url: URL
): Promise<Response> {
  const id = url.searchParams.get("id");
  if (!id) {
    return errorResponse("Query parameter 'id' is required", 400, "MISSING_ID");
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return errorResponse("Invalid JSON in request body", 400, "INVALID_JSON");
  }

  const { data, error } = await client
    .from("items") // TODO: replace with your table name
    .update({
      title: body.title,
      description: body.description,
    })
    .eq("id", id)
    .eq("user_id", userId) // RLS should handle this, but defense-in-depth
    .select()
    .single();

  if (error) {
    return errorResponse(error.message, 500, "DB_ERROR");
  }

  return jsonResponse({ data });
}

/** Handle DELETE requests — remove data. */
async function handleDelete(
  client: SupabaseClient,
  userId: string,
  url: URL
): Promise<Response> {
  const id = url.searchParams.get("id");
  if (!id) {
    return errorResponse("Query parameter 'id' is required", 400, "MISSING_ID");
  }

  const { error } = await client
    .from("items") // TODO: replace with your table name
    .delete()
    .eq("id", id)
    .eq("user_id", userId);

  if (error) {
    return errorResponse(error.message, 500, "DB_ERROR");
  }

  return jsonResponse({ success: true }, 200);
}

// ---------------------------------------------------------------------------
// Main Entry Point
// ---------------------------------------------------------------------------

/**
 * Deno.serve() is the modern Deno pattern for HTTP servers.
 * It replaces the older `serve()` import from std/http.
 * Supabase Edge Functions automatically route requests here.
 */
Deno.serve(async (req: Request): Promise<Response> => {
  // Handle CORS preflight requests
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: CORS_HEADERS,
    });
  }

  try {
    // Authenticate the request
    const authResult = await getAuthenticatedClient(req);

    // If authResult is a Response, authentication failed — return the error
    if (authResult instanceof Response) {
      return authResult;
    }

    const { client, userId } = authResult;
    const url = new URL(req.url);

    // Route to the appropriate handler based on HTTP method
    switch (req.method) {
      case "GET":
        return await handleGet(client, userId, url);
      case "POST":
        return await handlePost(client, userId, req);
      case "PUT":
        return await handlePut(client, userId, req, url);
      case "DELETE":
        return await handleDelete(client, userId, url);
      default:
        return errorResponse(`Method ${req.method} not allowed`, 405, "METHOD_NOT_ALLOWED");
    }
  } catch (err) {
    // Catch-all for unexpected errors — never leak stack traces in production
    console.error("Unhandled error:", err);

    const message =
      Deno.env.get("ENVIRONMENT") === "development" && err instanceof Error
        ? err.message
        : "Internal server error";

    return errorResponse(message, 500, "INTERNAL_ERROR");
  }
});
