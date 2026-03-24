/**
 * supabase-client.ts — Supabase Client Setup & Auth Helpers
 *
 * This module provides three client variants for different contexts:
 *
 *   1. `supabase`         — Browser client (anon key, respects RLS)
 *   2. `supabaseAdmin`    — Server-only admin client (service role, bypasses RLS)
 *   3. `createServerSupabaseClient()` — SSR client (cookie-based, for Next.js App Router)
 *
 * Usage:
 *   import { supabase } from './supabase-client'           // Client-side
 *   import { supabaseAdmin } from './supabase-client'      // Server actions / API routes
 *   import { createServerSupabaseClient } from './supabase-client' // RSC / middleware
 */

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { cookies } from "next/headers";
import type { Database } from "./supabase.types";

// ---------------------------------------------------------------------------
// Environment Variable Validation
// ---------------------------------------------------------------------------

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(
      `Missing required environment variable: ${name}. ` +
        `Add it to your .env.local file or deployment environment.`
    );
  }
  return value;
}

/**
 * Public Supabase URL — safe to expose in the browser.
 * Set via NEXT_PUBLIC_SUPABASE_URL in your .env.local
 */
const SUPABASE_URL =
  process.env.NEXT_PUBLIC_SUPABASE_URL ?? requireEnv("NEXT_PUBLIC_SUPABASE_URL");

/**
 * Anon (public) key — safe to expose in the browser.
 * This key respects Row Level Security policies.
 */
const SUPABASE_ANON_KEY =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ??
  requireEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY");

/**
 * Service role key — NEVER expose this in the browser.
 * This key bypasses all RLS policies and has full database access.
 * Only available in server-side code.
 */
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

// ---------------------------------------------------------------------------
// 1. Browser Client
// ---------------------------------------------------------------------------

/**
 * Browser-side Supabase client.
 *
 * - Uses the anon key (respects RLS)
 * - Manages auth sessions via localStorage
 * - Use this for all client-side data fetching
 *
 * Example:
 *   const { data, error } = await supabase.from('profiles').select('*')
 */
export const supabase: SupabaseClient<Database> = createClient<Database>(
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  {
    auth: {
      // Persist sessions in the browser
      persistSession: true,
      // Automatically refresh tokens before they expire
      autoRefreshToken: true,
      // Detect sessions from URL fragments (for OAuth redirects)
      detectSessionInUrl: true,
    },
  }
);

// ---------------------------------------------------------------------------
// 2. Server / Admin Client (Service Role — Bypasses RLS)
// ---------------------------------------------------------------------------

/**
 * Server-side admin client with service role privileges.
 *
 * ⚠️  WARNING: This client bypasses ALL Row Level Security policies.
 * Only use in:
 *   - Server Actions
 *   - API routes
 *   - Background jobs / webhooks
 *   - Database seeding / admin operations
 *
 * NEVER import this in client-side code or expose the service role key.
 *
 * Example:
 *   const { data } = await supabaseAdmin.from('profiles').select('*')
 *   // Returns ALL profiles regardless of RLS
 */
export const supabaseAdmin: SupabaseClient<Database> = createClient<Database>(
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY,
  {
    auth: {
      // No need for session persistence on the server
      persistSession: false,
      // Disable auto-refresh — the service role key doesn't expire
      autoRefreshToken: false,
    },
  }
);

// ---------------------------------------------------------------------------
// 3. Server Client for SSR (Cookie-Based — Next.js App Router)
// ---------------------------------------------------------------------------

/**
 * Create a Supabase client for Server Components, Server Actions, and Route Handlers.
 *
 * This client reads/writes auth tokens via cookies, making it compatible with
 * Next.js App Router's server-side rendering.
 *
 * Must be called within a request context (where `cookies()` is available).
 *
 * Example (Server Component):
 *   const supabase = await createServerSupabaseClient()
 *   const { data: { user } } = await supabase.auth.getUser()
 *
 * Example (Server Action):
 *   'use server'
 *   const supabase = await createServerSupabaseClient()
 *   await supabase.from('profiles').update({ full_name: 'New Name' })
 */
export async function createServerSupabaseClient(): Promise<
  SupabaseClient<Database>
> {
  const cookieStore = await cookies();

  return createServerClient<Database>(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) => {
            cookieStore.set(name, value, options);
          });
        } catch {
          // `setAll` can fail in Server Components (read-only context).
          // This is expected — the middleware will handle cookie refreshes.
        }
      },
    },
  });
}

// ---------------------------------------------------------------------------
// Auth Helper Functions
// ---------------------------------------------------------------------------

/** Represents the authenticated user returned by Supabase Auth. */
export type AuthUser = Awaited<
  ReturnType<SupabaseClient["auth"]["getUser"]>
>["data"]["user"];

/**
 * Get the currently authenticated user, or null if not signed in.
 *
 * Works in both client and server contexts:
 *   - Client: uses the browser `supabase` client
 *   - Server: pass a server client from `createServerSupabaseClient()`
 *
 * Example:
 *   const user = await getCurrentUser()
 *   if (user) console.log(user.email)
 */
export async function getCurrentUser(
  client: SupabaseClient<Database> = supabase
): Promise<AuthUser> {
  const {
    data: { user },
    error,
  } = await client.auth.getUser();

  if (error) {
    console.error("Error fetching current user:", error.message);
    return null;
  }

  return user;
}

/**
 * Require an authenticated user or throw an error.
 *
 * Use in Server Actions or API routes where authentication is mandatory.
 *
 * Example:
 *   const user = await requireAuth(supabase)
 *   // user is guaranteed to be non-null here
 *
 * @throws Error if the user is not authenticated
 */
export async function requireAuth(
  client: SupabaseClient<Database> = supabase
): Promise<NonNullable<AuthUser>> {
  const user = await getCurrentUser(client);

  if (!user) {
    throw new Error("Authentication required. Please sign in.");
  }

  return user;
}

/**
 * Sign out the current user and clear the session.
 *
 * Example:
 *   await signOut()
 *   router.push('/login')
 */
export async function signOut(
  client: SupabaseClient<Database> = supabase
): Promise<void> {
  const { error } = await client.auth.signOut();
  if (error) {
    console.error("Error signing out:", error.message);
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Typed Query Helpers
// ---------------------------------------------------------------------------

/**
 * Table names available in the database, derived from the generated types.
 * Use these with the typed query helpers for compile-time safety.
 */
export type TableName = keyof Database["public"]["Tables"];

/**
 * Row type for a given table — the shape returned by SELECT queries.
 */
export type Row<T extends TableName> = Database["public"]["Tables"][T]["Row"];

/**
 * Insert type for a given table — the shape accepted by INSERT queries.
 */
export type InsertRow<T extends TableName> =
  Database["public"]["Tables"][T]["Insert"];

/**
 * Update type for a given table — the shape accepted by UPDATE queries.
 */
export type UpdateRow<T extends TableName> =
  Database["public"]["Tables"][T]["Update"];

// ---------------------------------------------------------------------------
// Error Handling Wrapper
// ---------------------------------------------------------------------------

/** Structured result from a Supabase query. */
export type QueryResult<T> =
  | { data: T; error: null }
  | { data: null; error: { message: string; code?: string } };

/**
 * Execute a Supabase query with structured error handling.
 *
 * Wraps the Supabase query builder and returns a discriminated union
 * for clean error handling without try/catch.
 *
 * Example:
 *   const result = await safeQuery(
 *     supabase.from('profiles').select('*').eq('id', userId).single()
 *   )
 *
 *   if (result.error) {
 *     console.error(result.error.message)
 *     return
 *   }
 *
 *   console.log(result.data) // fully typed
 */
export async function safeQuery<T>(
  query: PromiseLike<{ data: T | null; error: { message: string; code?: string } | null }>
): Promise<QueryResult<T>> {
  try {
    const { data, error } = await query;

    if (error) {
      return { data: null, error: { message: error.message, code: error.code } };
    }

    if (data === null) {
      return { data: null, error: { message: "Query returned no data" } };
    }

    return { data, error: null };
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown query error";
    return { data: null, error: { message } };
  }
}
