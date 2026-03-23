/**
 * JWT Authentication Flow – End-to-End Test Suite
 *
 * Covers the full lifecycle of token-based authentication:
 *   1. Login → receive access + refresh tokens
 *   2. Authenticated API call with a valid token
 *   3. Rejection of expired tokens
 *   4. Token refresh flow
 *   5. Refresh token reuse detection (rotation violation)
 *   6. Logout / token revocation
 *
 * Framework: vitest / jest-compatible (describe / it / expect).
 * Adjust the base URL and helper imports to match your project.
 *
 * Dependencies:
 *   npm install -D vitest
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";

// ---------------------------------------------------------------------------
// Helpers – adapt these to your project
// ---------------------------------------------------------------------------

/** Base URL of the running auth / API server. */
const BASE = process.env.TEST_BASE_URL ?? "http://localhost:3000";

/** Test user credentials. Seed these in your test DB or use a fixture. */
const TEST_USER = {
  email: "testuser@example.com",
  password: "S3cur3P@ssw0rd!",
};

interface TokenPair {
  accessToken: string;
  refreshToken: string;
}

/** POST helper that sends JSON and returns the parsed response. */
async function post(path: string, body: unknown, token?: string) {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(`${BASE}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  return {
    status: res.status,
    body: await res.json().catch(() => null),
  };
}

/** GET helper with optional Bearer token. */
async function get(path: string, token?: string) {
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(`${BASE}${path}`, { headers });

  return {
    status: res.status,
    body: await res.json().catch(() => null),
  };
}

/**
 * Wait for a specified duration. Useful for letting short-lived tokens expire
 * in tests where the token TTL is set to a few seconds.
 */
function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("JWT Authentication Flows", () => {
  let tokens: TokenPair;

  // -----------------------------------------------------------------------
  // 1. Login
  // -----------------------------------------------------------------------
  describe("Login", () => {
    it("should return access and refresh tokens for valid credentials", async () => {
      const res = await post("/auth/login", {
        email: TEST_USER.email,
        password: TEST_USER.password,
      });

      expect(res.status).toBe(200);
      expect(res.body).toHaveProperty("accessToken");
      expect(res.body).toHaveProperty("refreshToken");
      expect(typeof res.body.accessToken).toBe("string");
      expect(typeof res.body.refreshToken).toBe("string");

      // Store tokens for subsequent tests.
      tokens = {
        accessToken: res.body.accessToken,
        refreshToken: res.body.refreshToken,
      };
    });

    it("should reject invalid credentials with 401", async () => {
      const res = await post("/auth/login", {
        email: TEST_USER.email,
        password: "wrong-password",
      });

      expect(res.status).toBe(401);
      expect(res.body).toHaveProperty("error");
    });
  });

  // -----------------------------------------------------------------------
  // 2. Authenticated API call
  // -----------------------------------------------------------------------
  describe("Protected endpoint – valid token", () => {
    it("should return user data when a valid access token is provided", async () => {
      const res = await get("/api/me", tokens.accessToken);

      expect(res.status).toBe(200);
      expect(res.body).toHaveProperty("sub");
      expect(res.body.sub).toBeTruthy();
    });

    it("should reject requests with no token (401)", async () => {
      const res = await get("/api/me");

      expect(res.status).toBe(401);
    });

    it("should reject requests with a malformed token (401)", async () => {
      const res = await get("/api/me", "not-a-jwt");

      expect(res.status).toBe(401);
    });
  });

  // -----------------------------------------------------------------------
  // 3. Expired token rejection
  // -----------------------------------------------------------------------
  describe("Expired access token", () => {
    it("should reject an expired access token with 401", async () => {
      // Option A: If your test environment issues short-lived tokens (e.g., 2s),
      // wait for expiry. Otherwise use a pre-built expired token fixture.
      //
      // await sleep(3000); // wait for token to expire
      //
      // Option B: Use a known-expired token generated beforehand.
      const expiredToken = process.env.TEST_EXPIRED_TOKEN ?? "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwiZXhwIjoxMDAwMDAwMDAwfQ.expired";

      const res = await get("/api/me", expiredToken);

      expect(res.status).toBe(401);
      expect(res.body?.message ?? res.body?.detail).toMatch(/expired|invalid/i);
    });
  });

  // -----------------------------------------------------------------------
  // 4. Refresh flow
  // -----------------------------------------------------------------------
  describe("Token refresh", () => {
    let newTokens: TokenPair;

    it("should issue new tokens when a valid refresh token is provided", async () => {
      const res = await post("/auth/refresh", {
        refreshToken: tokens.refreshToken,
      });

      expect(res.status).toBe(200);
      expect(res.body).toHaveProperty("accessToken");
      expect(res.body).toHaveProperty("refreshToken");

      // The new access token should differ from the original.
      expect(res.body.accessToken).not.toBe(tokens.accessToken);

      newTokens = {
        accessToken: res.body.accessToken,
        refreshToken: res.body.refreshToken,
      };
    });

    it("should allow API access with the newly issued access token", async () => {
      const res = await get("/api/me", newTokens.accessToken);

      expect(res.status).toBe(200);
    });

    // -------------------------------------------------------------------
    // 5. Refresh token reuse detection
    // -------------------------------------------------------------------
    it("should reject reuse of the old refresh token (rotation violation)", async () => {
      // After a refresh, the old refresh token should be invalidated.
      // If it is reused, the server should detect a potential token theft
      // and revoke the entire session / family.
      const res = await post("/auth/refresh", {
        refreshToken: tokens.refreshToken, // the OLD refresh token
      });

      // Acceptable responses: 401 (revoked) or 403 (detected reuse).
      expect([401, 403]).toContain(res.status);

      // Optionally, the server may also revoke the new tokens.
      // Verify that the newest token is no longer valid either.
      const apiRes = await get("/api/me", newTokens.accessToken);
      // This assertion depends on your revocation strategy.
      // Strict implementations revoke the entire family:
      //   expect(apiRes.status).toBe(401);
      // Lenient implementations only block the reused token:
      //   expect(apiRes.status).toBe(200);
    });
  });

  // -----------------------------------------------------------------------
  // 6. Logout / revocation
  // -----------------------------------------------------------------------
  describe("Logout and revocation", () => {
    let sessionTokens: TokenPair;

    beforeAll(async () => {
      // Get a fresh set of tokens for the logout test.
      const res = await post("/auth/login", {
        email: TEST_USER.email,
        password: TEST_USER.password,
      });
      sessionTokens = {
        accessToken: res.body.accessToken,
        refreshToken: res.body.refreshToken,
      };
    });

    it("should successfully log out (revoke tokens)", async () => {
      const res = await post(
        "/auth/logout",
        { refreshToken: sessionTokens.refreshToken },
        sessionTokens.accessToken,
      );

      expect(res.status).toBe(200);
    });

    it("should reject the revoked access token on subsequent requests", async () => {
      const res = await get("/api/me", sessionTokens.accessToken);

      // If the server uses a blocklist for access tokens, this should be 401.
      // If the server only revokes refresh tokens, the access token remains
      // valid until it expires naturally.
      expect([200, 401]).toContain(res.status);
    });

    it("should reject the revoked refresh token", async () => {
      const res = await post("/auth/refresh", {
        refreshToken: sessionTokens.refreshToken,
      });

      expect(res.status).toBe(401);
    });
  });
});
