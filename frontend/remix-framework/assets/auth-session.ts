/**
 * Cookie-Based Session Authentication Template
 *
 * Place this file at: app/services/session.server.ts
 * The .server.ts suffix ensures it's never bundled for the client.
 *
 * Usage in routes:
 *   import { requireUser, createUserSession, destroyUserSession } from "~/services/session.server";
 *
 *   // In a loader — protect a route
 *   export async function loader({ request }: Route.LoaderArgs) {
 *     const user = await requireUser(request);
 *     return { user };
 *   }
 *
 *   // In a login action — create session
 *   export async function action({ request }: Route.ActionArgs) {
 *     const user = await authenticateUser(email, password);
 *     return createUserSession(user.id, "/dashboard");
 *   }
 *
 *   // In a logout action — destroy session
 *   export async function action({ request }: Route.ActionArgs) {
 *     return destroyUserSession(request);
 *   }
 */

import { createCookieSessionStorage, redirect } from "react-router";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const SESSION_SECRET = process.env.SESSION_SECRET;
if (!SESSION_SECRET) {
  throw new Error("SESSION_SECRET environment variable is required");
}

const SESSION_MAX_AGE = 60 * 60 * 24 * 30; // 30 days

// ---------------------------------------------------------------------------
// Session Storage
// ---------------------------------------------------------------------------

const sessionStorage = createCookieSessionStorage({
  cookie: {
    name: "__session",
    httpOnly: true,
    maxAge: SESSION_MAX_AGE,
    path: "/",
    sameSite: "lax",
    secrets: [SESSION_SECRET],
    secure: process.env.NODE_ENV === "production",
  },
});

export { sessionStorage };

// ---------------------------------------------------------------------------
// Session Helpers
// ---------------------------------------------------------------------------

/** Get the session from the request Cookie header */
async function getSession(request: Request) {
  return sessionStorage.getSession(request.headers.get("Cookie"));
}

/** Get the user ID stored in the session, or null */
export async function getUserId(request: Request): Promise<string | null> {
  const session = await getSession(request);
  const userId = session.get("userId");
  return typeof userId === "string" ? userId : null;
}

/**
 * Require a valid user session. Redirects to login if no session exists.
 * Use in loaders for protected routes.
 */
export async function requireUserId(
  request: Request,
  redirectTo: string = new URL(request.url).pathname
): Promise<string> {
  const userId = await getUserId(request);
  if (!userId) {
    const searchParams = new URLSearchParams([["redirectTo", redirectTo]]);
    throw redirect(`/login?${searchParams}`);
  }
  return userId;
}

/**
 * Require a full user object. Fetches user from DB after verifying session.
 * Redirects to login if session is invalid or user doesn't exist.
 */
export async function requireUser(request: Request) {
  const userId = await requireUserId(request);

  // TODO: Replace with your actual user lookup
  const user = await getUserById(userId);

  if (!user) {
    // User in session but not in DB — destroy stale session
    throw await destroyUserSession(request);
  }

  return user;
}

// ---------------------------------------------------------------------------
// Session Mutations
// ---------------------------------------------------------------------------

/**
 * Create a new user session and redirect.
 * Call after successful authentication (login/signup).
 */
export async function createUserSession(
  userId: string,
  redirectTo: string,
  remember: boolean = true
) {
  const session = await sessionStorage.getSession();
  session.set("userId", userId);

  return redirect(redirectTo, {
    headers: {
      "Set-Cookie": await sessionStorage.commitSession(session, {
        maxAge: remember ? SESSION_MAX_AGE : undefined,
      }),
    },
  });
}

/**
 * Destroy the user session and redirect to login.
 * Call from a logout action.
 */
export async function destroyUserSession(request: Request) {
  const session = await getSession(request);
  return redirect("/login", {
    headers: {
      "Set-Cookie": await sessionStorage.destroySession(session),
    },
  });
}

// ---------------------------------------------------------------------------
// Flash Messages
// ---------------------------------------------------------------------------

/**
 * Set a flash message in the session.
 * Flash messages are shown once and then cleared.
 */
export async function setFlashMessage(
  request: Request,
  message: string,
  type: "success" | "error" | "info" = "info"
) {
  const session = await getSession(request);
  session.flash("flashMessage", JSON.stringify({ message, type }));
  return {
    "Set-Cookie": await sessionStorage.commitSession(session),
  };
}

/**
 * Get and clear the flash message from the session.
 * Returns the message and headers to commit the session (clearing the flash).
 */
export async function getFlashMessage(request: Request) {
  const session = await getSession(request);
  const raw = session.get("flashMessage");
  const flash = raw ? (JSON.parse(raw) as { message: string; type: string }) : null;

  return {
    flash,
    headers: {
      "Set-Cookie": await sessionStorage.commitSession(session),
    },
  };
}

// ---------------------------------------------------------------------------
// Placeholder: Replace with your actual user model
// ---------------------------------------------------------------------------

interface User {
  id: string;
  email: string;
  name: string;
}

async function getUserById(id: string): Promise<User | null> {
  // TODO: Replace with your database query
  // Example with Prisma:
  //   return prisma.user.findUnique({ where: { id } });
  throw new Error("getUserById not implemented — replace with your user lookup");
}
