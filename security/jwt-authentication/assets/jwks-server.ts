/**
 * Minimal JWKS Endpoint Server (Node.js / Express)
 *
 * Serves a JSON Web Key Set at /.well-known/jwks.json for JWT consumers.
 *
 * Features:
 *   - Serves multiple public keys (supports key rotation)
 *   - Cache-Control headers to reduce unnecessary fetches
 *   - Loads keys from PEM files on disk or from environment variables
 *   - Health-check endpoint
 *
 * Dependencies:
 *   npm install express jose
 *   npm install -D @types/express @types/node tsx
 *
 * Usage:
 *   # Keys from PEM files:
 *   JWKS_KEY_DIR=./keys node --import tsx jwks-server.ts
 *
 *   # Keys from environment variables (base64-encoded PEM):
 *   JWKS_KEY_0="base64(pem)" JWKS_KEY_0_KID="key-2024-01" node --import tsx jwks-server.ts
 */

import express, { type Request, type Response } from "express";
import { exportJWK, importSPKI, type JWK } from "jose";
import * as fs from "node:fs";
import * as path from "node:path";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PORT = parseInt(process.env.PORT ?? "3100", 10);

/**
 * How long downstream caches (and CDNs) should consider the JWKS fresh.
 * A short max-age ensures rotated keys propagate quickly.
 */
const CACHE_MAX_AGE_SEC = parseInt(process.env.JWKS_CACHE_MAX_AGE ?? "300", 10);

/** Algorithm family for all keys served by this endpoint. */
const ALGORITHM = "RS256";

// ---------------------------------------------------------------------------
// Key loading
// ---------------------------------------------------------------------------

interface NamedKey {
  kid: string;
  pem: string;
}

/**
 * Load public keys from PEM files in the directory specified by JWKS_KEY_DIR.
 * Each file should be named `<kid>.pem` and contain an RSA public key in
 * SPKI / PEM format.
 */
function loadKeysFromDir(dir: string): NamedKey[] {
  if (!fs.existsSync(dir)) {
    console.warn(`JWKS_KEY_DIR "${dir}" does not exist – skipping directory keys`);
    return [];
  }

  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".pem"))
    .map((f) => ({
      kid: path.basename(f, ".pem"),
      pem: fs.readFileSync(path.join(dir, f), "utf-8"),
    }));
}

/**
 * Load public keys from environment variables.
 *
 * Convention:
 *   JWKS_KEY_0  = base64-encoded PEM of the public key
 *   JWKS_KEY_0_KID = key ID (kid) for that key
 *   JWKS_KEY_1  = ...
 *   JWKS_KEY_1_KID = ...
 */
function loadKeysFromEnv(): NamedKey[] {
  const keys: NamedKey[] = [];
  for (let i = 0; ; i++) {
    const b64 = process.env[`JWKS_KEY_${i}`];
    if (!b64) break;

    const kid = process.env[`JWKS_KEY_${i}_KID`] ?? `key-${i}`;
    const pem = Buffer.from(b64, "base64").toString("utf-8");
    keys.push({ kid, pem });
  }
  return keys;
}

// ---------------------------------------------------------------------------
// JWK conversion
// ---------------------------------------------------------------------------

/** Convert an RSA public key PEM to a JWK object with standard fields. */
async function pemToJwk(namedKey: NamedKey): Promise<JWK> {
  const keyObj = await importSPKI(namedKey.pem, ALGORITHM);
  const jwk = await exportJWK(keyObj);

  return {
    ...jwk,
    kid: namedKey.kid,
    alg: ALGORITHM,
    use: "sig",
    key_ops: ["verify"],
  };
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  // 1. Load keys from all sources.
  const dirKeys = loadKeysFromDir(process.env.JWKS_KEY_DIR ?? "./keys");
  const envKeys = loadKeysFromEnv();
  const allNamedKeys = [...dirKeys, ...envKeys];

  if (allNamedKeys.length === 0) {
    console.error(
      "No keys found. Provide PEM files in JWKS_KEY_DIR or set JWKS_KEY_<n> env vars.",
    );
    process.exit(1);
  }

  // 2. Convert all keys to JWK format once at startup.
  const jwks = await Promise.all(allNamedKeys.map(pemToJwk));
  const jwksDocument = { keys: jwks };

  console.log(
    `Loaded ${jwks.length} key(s): ${jwks.map((k) => k.kid).join(", ")}`,
  );

  // 3. Set up Express.
  const app = express();

  // -----------------------------------------------------------------------
  // JWKS endpoint
  // -----------------------------------------------------------------------
  app.get("/.well-known/jwks.json", (_req: Request, res: Response) => {
    res.set({
      "Content-Type": "application/json",
      "Cache-Control": `public, max-age=${CACHE_MAX_AGE_SEC}, must-revalidate`,
      // Prevent MIME-type sniffing
      "X-Content-Type-Options": "nosniff",
    });
    res.json(jwksDocument);
  });

  // -----------------------------------------------------------------------
  // Health check
  // -----------------------------------------------------------------------
  app.get("/healthz", (_req: Request, res: Response) => {
    res.json({ status: "ok", keys: jwks.length });
  });

  // -----------------------------------------------------------------------
  // Start listening
  // -----------------------------------------------------------------------
  app.listen(PORT, () => {
    console.log(`JWKS server listening on http://0.0.0.0:${PORT}`);
    console.log(`  JWKS endpoint: http://0.0.0.0:${PORT}/.well-known/jwks.json`);
    console.log(`  Health check:  http://0.0.0.0:${PORT}/healthz`);
    console.log(`  Cache TTL:     ${CACHE_MAX_AGE_SEC}s`);
  });
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
