/**
 * TypeScript OAuth2 client with PKCE, token refresh, and error handling.
 *
 * Features:
 * - Authorization code flow with PKCE (S256)
 * - Automatic token refresh with mutex to prevent race conditions
 * - Configurable token storage interface
 * - OpenID Connect discovery support
 * - Comprehensive error handling with typed OAuth errors
 *
 * Usage:
 *   const client = new OAuth2Client({
 *     clientId: 'your-client-id',
 *     authorizationEndpoint: 'https://auth.example.com/authorize',
 *     tokenEndpoint: 'https://auth.example.com/oauth/token',
 *     redirectUri: 'https://app.example.com/callback',
 *     scopes: ['openid', 'profile', 'email'],
 *   });
 *
 *   // Start login
 *   const authUrl = await client.createAuthorizationUrl();
 *   window.location.href = authUrl;
 *
 *   // Handle callback
 *   const tokens = await client.handleCallback(window.location.search);
 *
 *   // Get valid access token (auto-refreshes if needed)
 *   const token = await client.getAccessToken();
 */

import crypto from 'node:crypto';

// ─── Types ───────────────────────────────────────────────────────────────────

export interface OAuth2ClientConfig {
  clientId: string;
  clientSecret?: string;
  authorizationEndpoint: string;
  tokenEndpoint: string;
  redirectUri: string;
  scopes: string[];
  /** Token storage adapter (default: in-memory) */
  tokenStore?: TokenStore;
  /** Seconds before expiry to trigger refresh (default: 60) */
  refreshBufferSec?: number;
  /** OIDC discovery URL — if set, endpoints are auto-configured */
  discoveryUrl?: string;
}

export interface TokenSet {
  accessToken: string;
  refreshToken?: string;
  idToken?: string;
  expiresAt: number; // Unix timestamp in milliseconds
  scope?: string;
  tokenType: string;
}

export interface TokenStore {
  get(): TokenSet | null;
  save(tokens: TokenSet): void;
  clear(): void;
}

export interface PKCEPair {
  verifier: string;
  challenge: string;
}

export interface AuthorizationState {
  state: string;
  codeVerifier: string;
  nonce?: string;
  redirectUri: string;
  createdAt: number;
}

export class OAuthError extends Error {
  constructor(
    public errorCode: string,
    public errorDescription: string,
    public errorUri?: string,
  ) {
    super(`${errorCode}: ${errorDescription}`);
    this.name = 'OAuthError';
  }

  get isRecoverable(): boolean {
    return ['temporarily_unavailable', 'server_error'].includes(this.errorCode);
  }

  get requiresReauth(): boolean {
    return [
      'invalid_grant',
      'login_required',
      'consent_required',
      'interaction_required',
    ].includes(this.errorCode);
  }
}

// ─── Token Storage ───────────────────────────────────────────────────────────

class InMemoryTokenStore implements TokenStore {
  private tokens: TokenSet | null = null;

  get(): TokenSet | null {
    return this.tokens;
  }

  save(tokens: TokenSet): void {
    this.tokens = { ...tokens };
  }

  clear(): void {
    this.tokens = null;
  }
}

// ─── PKCE Utilities ──────────────────────────────────────────────────────────

function generateCodeVerifier(): string {
  return crypto.randomBytes(32).toString('base64url');
}

function generateCodeChallenge(verifier: string): string {
  return crypto.createHash('sha256').update(verifier).digest('base64url');
}

function generatePKCE(): PKCEPair {
  const verifier = generateCodeVerifier();
  return {
    verifier,
    challenge: generateCodeChallenge(verifier),
  };
}

function generateRandomString(bytes = 16): string {
  return crypto.randomBytes(bytes).toString('base64url');
}

// ─── OAuth2 Client ───────────────────────────────────────────────────────────

export class OAuth2Client {
  private config: Required<
    Pick<OAuth2ClientConfig, 'clientId' | 'redirectUri' | 'scopes' | 'refreshBufferSec'>
  > &
    OAuth2ClientConfig;
  private tokenStore: TokenStore;
  private pendingStates = new Map<string, AuthorizationState>();
  private refreshPromise: Promise<TokenSet> | null = null;

  constructor(config: OAuth2ClientConfig) {
    this.config = {
      ...config,
      refreshBufferSec: config.refreshBufferSec ?? 60,
    };
    this.tokenStore = config.tokenStore ?? new InMemoryTokenStore();
  }

  /**
   * Auto-configure endpoints from OIDC discovery document.
   */
  async discover(discoveryUrl?: string): Promise<void> {
    const url = discoveryUrl ?? this.config.discoveryUrl;
    if (!url) throw new Error('No discovery URL provided');

    const response = await fetch(url, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(10_000),
    });

    if (!response.ok) {
      throw new Error(`Discovery failed: ${response.status} ${response.statusText}`);
    }

    const doc = (await response.json()) as Record<string, unknown>;
    if (typeof doc.authorization_endpoint === 'string') {
      this.config.authorizationEndpoint = doc.authorization_endpoint;
    }
    if (typeof doc.token_endpoint === 'string') {
      this.config.tokenEndpoint = doc.token_endpoint;
    }
  }

  /**
   * Create the authorization URL. Redirect the user to this URL.
   * Returns the full URL string.
   */
  createAuthorizationUrl(extraParams?: Record<string, string>): string {
    const pkce = generatePKCE();
    const state = generateRandomString();
    const nonce = generateRandomString();

    // Store PKCE verifier and state for callback validation
    this.pendingStates.set(state, {
      state,
      codeVerifier: pkce.verifier,
      nonce,
      redirectUri: this.config.redirectUri,
      createdAt: Date.now(),
    });

    // Clean up old pending states (>10 minutes)
    this.cleanupPendingStates();

    const params = new URLSearchParams({
      response_type: 'code',
      client_id: this.config.clientId,
      redirect_uri: this.config.redirectUri,
      scope: this.config.scopes.join(' '),
      state,
      nonce,
      code_challenge: pkce.challenge,
      code_challenge_method: 'S256',
      ...extraParams,
    });

    return `${this.config.authorizationEndpoint}?${params.toString()}`;
  }

  /**
   * Handle the OAuth callback. Pass the full query string from the callback URL.
   * Validates state, exchanges the code for tokens, and stores them.
   */
  async handleCallback(queryString: string): Promise<TokenSet> {
    const params = new URLSearchParams(
      queryString.startsWith('?') ? queryString.slice(1) : queryString,
    );

    // Check for errors from the authorization server
    const error = params.get('error');
    if (error) {
      throw new OAuthError(
        error,
        params.get('error_description') ?? 'Authorization failed',
        params.get('error_uri') ?? undefined,
      );
    }

    const code = params.get('code');
    const returnedState = params.get('state');

    if (!code) throw new OAuthError('invalid_request', 'Missing authorization code');
    if (!returnedState) throw new OAuthError('invalid_request', 'Missing state parameter');

    // Validate state and retrieve PKCE verifier
    const pendingState = this.pendingStates.get(returnedState);
    if (!pendingState) {
      throw new OAuthError(
        'invalid_request',
        'State mismatch — possible CSRF attack or expired state',
      );
    }
    this.pendingStates.delete(returnedState);

    // Exchange code for tokens
    const tokens = await this.exchangeCode(code, pendingState.codeVerifier);
    this.tokenStore.save(tokens);
    return tokens;
  }

  /**
   * Get a valid access token. Automatically refreshes if the token is expired
   * or about to expire. Uses a mutex to prevent concurrent refresh races.
   *
   * @throws {OAuthError} If refresh fails with an unrecoverable error
   */
  async getAccessToken(): Promise<string> {
    const tokens = this.tokenStore.get();
    if (!tokens) {
      throw new OAuthError('invalid_grant', 'No tokens available — user must authenticate');
    }

    const bufferMs = this.config.refreshBufferSec * 1000;
    if (Date.now() < tokens.expiresAt - bufferMs) {
      return tokens.accessToken;
    }

    // Token is expired or about to expire — refresh
    if (!tokens.refreshToken) {
      this.tokenStore.clear();
      throw new OAuthError('invalid_grant', 'Token expired and no refresh token available');
    }

    const refreshed = await this.refreshAccessToken(tokens.refreshToken);
    return refreshed.accessToken;
  }

  /**
   * Refresh the access token using a refresh token.
   * Uses a mutex to ensure only one refresh happens at a time.
   */
  async refreshAccessToken(refreshToken: string): Promise<TokenSet> {
    // Mutex: if a refresh is already in progress, wait for it
    if (this.refreshPromise) {
      return this.refreshPromise;
    }

    this.refreshPromise = this.performRefresh(refreshToken);
    try {
      const tokens = await this.refreshPromise;
      this.tokenStore.save(tokens);
      return tokens;
    } catch (error) {
      if (error instanceof OAuthError && error.requiresReauth) {
        this.tokenStore.clear();
      }
      throw error;
    } finally {
      this.refreshPromise = null;
    }
  }

  /**
   * Revoke the current tokens (if the provider supports revocation).
   */
  async logout(revocationEndpoint?: string): Promise<void> {
    const tokens = this.tokenStore.get();
    if (tokens?.refreshToken && revocationEndpoint) {
      try {
        await this.revokeToken(revocationEndpoint, tokens.refreshToken, 'refresh_token');
      } catch {
        // Best-effort revocation — clear local tokens regardless
      }
    }
    this.tokenStore.clear();
  }

  /**
   * Check if the user is authenticated (has tokens).
   */
  isAuthenticated(): boolean {
    return this.tokenStore.get() !== null;
  }

  /**
   * Get the current token set (if any).
   */
  getTokenSet(): TokenSet | null {
    return this.tokenStore.get();
  }

  // ─── Private Methods ────────────────────────────────────────────────────────

  private async exchangeCode(code: string, codeVerifier: string): Promise<TokenSet> {
    const body = new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: this.config.redirectUri,
      client_id: this.config.clientId,
      code_verifier: codeVerifier,
    });

    if (this.config.clientSecret) {
      body.set('client_secret', this.config.clientSecret);
    }

    return this.tokenRequest(body);
  }

  private async performRefresh(refreshToken: string): Promise<TokenSet> {
    const body = new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: this.config.clientId,
    });

    if (this.config.clientSecret) {
      body.set('client_secret', this.config.clientSecret);
    }

    return this.tokenRequest(body);
  }

  private async tokenRequest(body: URLSearchParams): Promise<TokenSet> {
    const response = await fetch(this.config.tokenEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
      },
      body,
      signal: AbortSignal.timeout(15_000),
    });

    const data = (await response.json()) as Record<string, unknown>;

    if (!response.ok || typeof data.error === 'string') {
      throw new OAuthError(
        (data.error as string) ?? 'server_error',
        (data.error_description as string) ?? `Token request failed with status ${response.status}`,
        (data.error_uri as string) ?? undefined,
      );
    }

    const expiresIn = typeof data.expires_in === 'number' ? data.expires_in : 3600;

    return {
      accessToken: data.access_token as string,
      refreshToken: (data.refresh_token as string) ?? undefined,
      idToken: (data.id_token as string) ?? undefined,
      expiresAt: Date.now() + expiresIn * 1000,
      scope: (data.scope as string) ?? undefined,
      tokenType: (data.token_type as string) ?? 'Bearer',
    };
  }

  private async revokeToken(
    endpoint: string,
    token: string,
    tokenTypeHint: string,
  ): Promise<void> {
    const body = new URLSearchParams({
      token,
      token_type_hint: tokenTypeHint,
      client_id: this.config.clientId,
    });

    if (this.config.clientSecret) {
      body.set('client_secret', this.config.clientSecret);
    }

    await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
      signal: AbortSignal.timeout(10_000),
    });
  }

  private cleanupPendingStates(): void {
    const maxAge = 10 * 60 * 1000; // 10 minutes
    const now = Date.now();
    for (const [key, state] of this.pendingStates) {
      if (now - state.createdAt > maxAge) {
        this.pendingStates.delete(key);
      }
    }
  }
}
