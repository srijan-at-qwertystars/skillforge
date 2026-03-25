// =============================================================================
// Netlify Serverless Function Template — TypeScript
//
// Place in: netlify/functions/<name>.ts
// Endpoint: /.netlify/functions/<name>
//
// Install types: npm install -D @netlify/functions
// Docs: https://docs.netlify.com/functions/overview/
// =============================================================================

import type {
  Handler,
  HandlerEvent,
  HandlerContext,
  HandlerResponse,
} from "@netlify/functions";

// --- Types ---

interface RequestBody {
  name: string;
  email: string;
  message?: string;
}

interface ApiResponse<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
  timestamp: string;
}

// --- Constants ---

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": process.env.ALLOWED_ORIGIN || "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
};

// --- Helpers ---

function jsonResponse<T>(
  statusCode: number,
  body: ApiResponse<T>
): HandlerResponse {
  return {
    statusCode,
    headers: {
      ...CORS_HEADERS,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  };
}

function successResponse<T>(data: T, statusCode = 200): HandlerResponse {
  return jsonResponse(statusCode, {
    success: true,
    data,
    timestamp: new Date().toISOString(),
  });
}

function errorResponse(
  error: string,
  statusCode = 500
): HandlerResponse {
  return jsonResponse(statusCode, {
    success: false,
    error,
    timestamp: new Date().toISOString(),
  });
}

function parseBody<T>(body: string | null): T {
  if (!body) throw new Error("Request body is required");
  return JSON.parse(body) as T;
}

// --- Auth Helper (Netlify Identity) ---

function getUser(context: HandlerContext) {
  return context.clientContext?.user || null;
}

function requireAuth(context: HandlerContext) {
  const user = getUser(context);
  if (!user) throw new AuthError("Authentication required");
  return user;
}

class AuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}

// --- Route Handlers ---

async function handleGet(
  event: HandlerEvent,
  _context: HandlerContext
): Promise<HandlerResponse> {
  const { name } = event.queryStringParameters || {};

  // Example: fetch from database or external API
  const data = {
    message: `Hello, ${name || "World"}!`,
    path: event.path,
  };

  return successResponse(data);
}

async function handlePost(
  event: HandlerEvent,
  _context: HandlerContext
): Promise<HandlerResponse> {
  const body = parseBody<RequestBody>(event.body);

  // Validate required fields
  if (!body.name || !body.email) {
    return errorResponse("Name and email are required", 400);
  }

  // Example: save to database, send email, call external API
  const result = {
    id: crypto.randomUUID(),
    ...body,
    createdAt: new Date().toISOString(),
  };

  return successResponse(result, 201);
}

// --- Main Handler ---

export const handler: Handler = async (
  event: HandlerEvent,
  context: HandlerContext
): Promise<HandlerResponse> => {
  // Handle CORS preflight
  if (event.httpMethod === "OPTIONS") {
    return { statusCode: 204, headers: CORS_HEADERS, body: "" };
  }

  try {
    switch (event.httpMethod) {
      case "GET":
        return await handleGet(event, context);
      case "POST":
        return await handlePost(event, context);
      default:
        return errorResponse(
          `Method ${event.httpMethod} not allowed`,
          405
        );
    }
  } catch (error) {
    if (error instanceof AuthError) {
      return errorResponse(error.message, 401);
    }

    console.error("Unhandled error:", error);
    return errorResponse("Internal server error", 500);
  }
};
