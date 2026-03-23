/**
 * webauthn-server.ts — Express server module for WebAuthn registration and authentication.
 *
 * Provides Express routes for the full WebAuthn ceremony lifecycle:
 *   - POST /register/options  — Generate registration options
 *   - POST /register/verify   — Verify registration response
 *   - POST /authenticate/options — Generate authentication options
 *   - POST /authenticate/verify  — Verify authentication response
 *
 * Dependencies:
 *   npm install @simplewebauthn/server express express-session
 *   npm install -D @types/express @types/express-session
 *
 * Usage:
 *   import { createWebAuthnRouter } from './webauthn-server';
 *   app.use('/api/webauthn', createWebAuthnRouter({
 *     rpName: 'My App',
 *     rpID: 'example.com',
 *     origin: 'https://example.com',
 *   }));
 */

import { Router, Request, Response } from 'express';
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from '@simplewebauthn/server';
import type {
  GenerateRegistrationOptionsOpts,
  VerifiedRegistrationResponse,
  GenerateAuthenticationOptionsOpts,
  VerifiedAuthenticationResponse,
} from '@simplewebauthn/server';
import type {
  AuthenticatorTransportFuture,
  CredentialDeviceType,
} from '@simplewebauthn/types';
import { isoUint8Array } from '@simplewebauthn/server/helpers';

// --- Types ---

export interface WebAuthnServerConfig {
  rpName: string;
  rpID: string;
  origin: string | string[];
}

export interface StoredCredential {
  credentialID: Uint8Array;
  credentialPublicKey: Uint8Array;
  counter: number;
  transports?: AuthenticatorTransportFuture[];
  deviceType: CredentialDeviceType;
  backedUp: boolean;
  aaguid?: string;
  createdAt: Date;
  lastUsedAt?: Date;
  friendlyName?: string;
}

/**
 * Database interface — implement this with your actual database.
 * All methods must be async-safe.
 */
export interface CredentialStore {
  getUser(userId: string): Promise<{ id: string; email: string; displayName: string } | null>;
  getUserByEmail(email: string): Promise<{ id: string; email: string; displayName: string } | null>;
  getCredentialsByUserId(userId: string): Promise<StoredCredential[]>;
  getCredentialById(credentialId: Uint8Array): Promise<(StoredCredential & { userId: string }) | null>;
  saveCredential(userId: string, credential: StoredCredential): Promise<void>;
  updateCredentialCounter(credentialId: Uint8Array, newCounter: number): Promise<void>;
  deleteCredential(userId: string, credentialId: Uint8Array): Promise<void>;
}

// Extend express-session to include our WebAuthn challenge data
declare module 'express-session' {
  interface SessionData {
    currentChallenge?: string;
    challengeUserId?: string;
    userId?: string;
  }
}

// --- In-Memory Credential Store (for development only) ---

export class InMemoryCredentialStore implements CredentialStore {
  private users = new Map<string, { id: string; email: string; displayName: string }>();
  private credentials = new Map<string, StoredCredential & { userId: string }>();

  async getUser(userId: string) {
    return this.users.get(userId) ?? null;
  }

  async getUserByEmail(email: string) {
    for (const user of this.users.values()) {
      if (user.email === email) return user;
    }
    return null;
  }

  async getCredentialsByUserId(userId: string): Promise<StoredCredential[]> {
    const results: StoredCredential[] = [];
    for (const cred of this.credentials.values()) {
      if (cred.userId === userId) results.push(cred);
    }
    return results;
  }

  async getCredentialById(credentialId: Uint8Array) {
    const key = Buffer.from(credentialId).toString('base64url');
    return this.credentials.get(key) ?? null;
  }

  async saveCredential(userId: string, credential: StoredCredential) {
    const key = Buffer.from(credential.credentialID).toString('base64url');
    this.credentials.set(key, { ...credential, userId });
  }

  async updateCredentialCounter(credentialId: Uint8Array, newCounter: number) {
    const key = Buffer.from(credentialId).toString('base64url');
    const cred = this.credentials.get(key);
    if (cred) {
      cred.counter = newCounter;
      cred.lastUsedAt = new Date();
    }
  }

  async deleteCredential(userId: string, credentialId: Uint8Array) {
    const key = Buffer.from(credentialId).toString('base64url');
    this.credentials.delete(key);
  }

  /** Helper for development: add a test user. */
  addUser(user: { id: string; email: string; displayName: string }) {
    this.users.set(user.id, user);
  }
}

// --- Router Factory ---

export function createWebAuthnRouter(
  config: WebAuthnServerConfig,
  store?: CredentialStore
): Router {
  const router = Router();
  const credentialStore = store ?? new InMemoryCredentialStore();
  const { rpName, rpID, origin } = config;

  /**
   * POST /register/options
   * Generate registration options for the authenticated user.
   * Requires: authenticated session (req.session.userId).
   */
  router.post('/register/options', async (req: Request, res: Response) => {
    try {
      const userId = req.session.userId;
      if (!userId) {
        return res.status(401).json({ error: 'Authentication required' });
      }

      const user = await credentialStore.getUser(userId);
      if (!user) {
        return res.status(404).json({ error: 'User not found' });
      }

      const existingCredentials = await credentialStore.getCredentialsByUserId(userId);

      const opts: GenerateRegistrationOptionsOpts = {
        rpName,
        rpID,
        userName: user.email,
        userID: isoUint8Array.fromUTF8String(user.id),
        attestationType: 'none',
        authenticatorSelection: {
          residentKey: 'required',
          userVerification: 'preferred',
        },
        excludeCredentials: existingCredentials.map((cred) => ({
          id: cred.credentialID,
          transports: cred.transports,
        })),
        supportedAlgorithmIDs: [-7, -257], // ES256, RS256
      };

      const options = await generateRegistrationOptions(opts);

      // Store challenge in session for verification
      req.session.currentChallenge = options.challenge;
      req.session.challengeUserId = userId;

      return res.json(options);
    } catch (error) {
      console.error('Registration options error:', error);
      return res.status(500).json({ error: 'Failed to generate registration options' });
    }
  });

  /**
   * POST /register/verify
   * Verify a registration response and store the new credential.
   */
  router.post('/register/verify', async (req: Request, res: Response) => {
    try {
      const userId = req.session.challengeUserId;
      const expectedChallenge = req.session.currentChallenge;

      if (!userId || !expectedChallenge) {
        return res.status(400).json({ error: 'No pending registration challenge' });
      }

      // Clear challenge immediately (single-use)
      delete req.session.currentChallenge;
      delete req.session.challengeUserId;

      let verification: VerifiedRegistrationResponse;
      try {
        verification = await verifyRegistrationResponse({
          response: req.body,
          expectedChallenge,
          expectedOrigin: origin,
          expectedRPID: rpID,
        });
      } catch (error) {
        console.error('Registration verification failed:', error);
        return res.status(400).json({
          error: 'Verification failed',
          details: error instanceof Error ? error.message : 'Unknown error',
        });
      }

      if (!verification.verified || !verification.registrationInfo) {
        return res.status(400).json({ error: 'Registration verification failed' });
      }

      const { credential, credentialDeviceType, credentialBackedUp, aaguid } =
        verification.registrationInfo;

      // Determine friendly name from User-Agent
      const ua = req.headers['user-agent'] ?? 'Unknown device';
      const friendlyName = deriveFriendlyName(ua, credentialDeviceType);

      const storedCredential: StoredCredential = {
        credentialID: credential.id,
        credentialPublicKey: credential.publicKey,
        counter: credential.counter,
        transports: req.body.response?.transports,
        deviceType: credentialDeviceType,
        backedUp: credentialBackedUp,
        aaguid,
        createdAt: new Date(),
        friendlyName,
      };

      await credentialStore.saveCredential(userId, storedCredential);

      return res.json({
        verified: true,
        credentialId: Buffer.from(credential.id).toString('base64url'),
        credentialDeviceType,
        credentialBackedUp,
        friendlyName,
      });
    } catch (error) {
      console.error('Registration verify error:', error);
      return res.status(500).json({ error: 'Internal server error' });
    }
  });

  /**
   * POST /authenticate/options
   * Generate authentication options.
   * If username is provided, include allowCredentials for that user.
   * If conditional:true, return options for discoverable credential flow.
   */
  router.post('/authenticate/options', async (req: Request, res: Response) => {
    try {
      const { username, conditional } = req.body ?? {};

      const opts: GenerateAuthenticationOptionsOpts = {
        rpID,
        userVerification: 'preferred',
        timeout: 300_000,
      };

      // For non-discoverable credentials, include allowCredentials
      if (username && !conditional) {
        const user = await credentialStore.getUserByEmail(username);
        if (user) {
          const credentials = await credentialStore.getCredentialsByUserId(user.id);
          opts.allowCredentials = credentials.map((cred) => ({
            id: cred.credentialID,
            transports: cred.transports,
          }));
        }
        // Don't reveal whether the user exists — return valid options either way
      }

      const options = await generateAuthenticationOptions(opts);

      req.session.currentChallenge = options.challenge;

      return res.json(options);
    } catch (error) {
      console.error('Authentication options error:', error);
      return res.status(500).json({ error: 'Failed to generate authentication options' });
    }
  });

  /**
   * POST /authenticate/verify
   * Verify an authentication response.
   */
  router.post('/authenticate/verify', async (req: Request, res: Response) => {
    try {
      const expectedChallenge = req.session.currentChallenge;
      if (!expectedChallenge) {
        return res.status(400).json({ error: 'No pending authentication challenge' });
      }

      // Clear challenge (single-use)
      delete req.session.currentChallenge;

      // Look up the credential by ID
      const credentialIdBytes = isoUint8Array.fromHex(
        Buffer.from(req.body.rawId, 'base64url').toString('hex')
      );
      const storedCred = await credentialStore.getCredentialById(credentialIdBytes);

      if (!storedCred) {
        return res.status(401).json({ error: 'Credential not found' });
      }

      let verification: VerifiedAuthenticationResponse;
      try {
        verification = await verifyAuthenticationResponse({
          response: req.body,
          expectedChallenge,
          expectedOrigin: origin,
          expectedRPID: rpID,
          credential: {
            id: storedCred.credentialID,
            publicKey: storedCred.credentialPublicKey,
            counter: storedCred.counter,
            transports: storedCred.transports,
          },
        });
      } catch (error) {
        console.error('Authentication verification failed:', error);
        return res.status(401).json({
          error: 'Authentication failed',
          details: error instanceof Error ? error.message : 'Unknown error',
        });
      }

      if (!verification.verified) {
        return res.status(401).json({ error: 'Authentication verification failed' });
      }

      // Update counter
      const { newCounter } = verification.authenticationInfo;
      await credentialStore.updateCredentialCounter(storedCred.credentialID, newCounter);

      // Set authenticated session
      req.session.userId = storedCred.userId;

      return res.json({
        verified: true,
        userId: storedCred.userId,
      });
    } catch (error) {
      console.error('Authentication verify error:', error);
      return res.status(500).json({ error: 'Internal server error' });
    }
  });

  return router;
}

// --- Helpers ---

function deriveFriendlyName(userAgent: string, deviceType: CredentialDeviceType): string {
  const ua = userAgent.toLowerCase();
  if (ua.includes('iphone')) return 'iPhone';
  if (ua.includes('ipad')) return 'iPad';
  if (ua.includes('mac')) return 'Mac';
  if (ua.includes('android')) return 'Android';
  if (ua.includes('windows')) return 'Windows';
  if (ua.includes('linux')) return 'Linux';
  if (deviceType === 'multiDevice') return 'Passkey';
  return 'Security Key';
}
