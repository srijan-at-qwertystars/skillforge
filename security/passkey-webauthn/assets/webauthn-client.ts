/**
 * webauthn-client.ts — Browser-side WebAuthn module using @simplewebauthn/browser.
 *
 * Provides registration, authentication, and conditional UI with proper error
 * handling, AbortController management, and feature detection.
 *
 * Dependencies:
 *   npm install @simplewebauthn/browser @simplewebauthn/types
 *
 * Usage:
 *   import { WebAuthnClient } from './webauthn-client';
 *   const client = new WebAuthnClient('/api/webauthn');
 *   await client.register();
 *   await client.authenticate();
 *   await client.startConditionalUI();
 */

import {
  startRegistration,
  startAuthentication,
  browserSupportsWebAuthn,
  browserSupportsWebAuthnAutofill,
  platformAuthenticatorIsAvailable,
} from '@simplewebauthn/browser';

import type {
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialRequestOptionsJSON,
  RegistrationResponseJSON,
  AuthenticationResponseJSON,
} from '@simplewebauthn/types';

// --- Types ---

export interface WebAuthnClientConfig {
  /** Base URL for WebAuthn API endpoints (e.g., '/api/webauthn'). */
  basePath: string;
  /** Timeout for fetch requests in milliseconds. Default: 10000. */
  fetchTimeout?: number;
}

export interface WebAuthnCapabilities {
  webauthnSupported: boolean;
  platformAuthenticatorAvailable: boolean;
  conditionalUIAvailable: boolean;
}

export interface RegistrationResult {
  verified: boolean;
  credentialId?: string;
  credentialDeviceType?: string;
  credentialBackedUp?: boolean;
}

export interface AuthenticationResult {
  verified: boolean;
  userId?: string;
}

export type WebAuthnErrorType =
  | 'not_supported'
  | 'user_cancelled'
  | 'already_registered'
  | 'security_error'
  | 'network_error'
  | 'server_error'
  | 'unknown';

export class WebAuthnError extends Error {
  constructor(
    public readonly type: WebAuthnErrorType,
    message: string,
    public readonly originalError?: unknown
  ) {
    super(message);
    this.name = 'WebAuthnError';
  }
}

// --- Client Implementation ---

export class WebAuthnClient {
  private basePath: string;
  private fetchTimeout: number;
  private conditionalAbort: AbortController | null = null;

  constructor(config: string | WebAuthnClientConfig) {
    if (typeof config === 'string') {
      this.basePath = config;
      this.fetchTimeout = 10_000;
    } else {
      this.basePath = config.basePath;
      this.fetchTimeout = config.fetchTimeout ?? 10_000;
    }
  }

  /**
   * Detect WebAuthn capabilities of the current browser and device.
   */
  async getCapabilities(): Promise<WebAuthnCapabilities> {
    const webauthnSupported = browserSupportsWebAuthn();
    let platformAuthenticatorAvailable = false;
    let conditionalUIAvailable = false;

    if (webauthnSupported) {
      platformAuthenticatorAvailable = await platformAuthenticatorIsAvailable();
      conditionalUIAvailable = await browserSupportsWebAuthnAutofill();
    }

    return {
      webauthnSupported,
      platformAuthenticatorAvailable,
      conditionalUIAvailable,
    };
  }

  /**
   * Register a new passkey for the current authenticated user.
   *
   * Flow:
   *   1. Fetch registration options from server.
   *   2. Prompt user via browser WebAuthn API.
   *   3. Send response to server for verification.
   *
   * @throws {WebAuthnError} On failure with categorized error type.
   */
  async register(): Promise<RegistrationResult> {
    this.abortConditionalUI();

    if (!browserSupportsWebAuthn()) {
      throw new WebAuthnError('not_supported', 'WebAuthn is not supported in this browser.');
    }

    // Step 1: Get registration options from server
    const optionsJSON = await this.fetchJSON<PublicKeyCredentialCreationOptionsJSON>(
      `${this.basePath}/register/options`,
      { method: 'POST' }
    );

    // Step 2: Start browser registration ceremony
    let attResp: RegistrationResponseJSON;
    try {
      attResp = await startRegistration({ optionsJSON });
    } catch (error) {
      throw this.categorizeError(error, 'registration');
    }

    // Step 3: Send to server for verification
    const result = await this.fetchJSON<RegistrationResult>(
      `${this.basePath}/register/verify`,
      {
        method: 'POST',
        body: JSON.stringify(attResp),
      }
    );

    return result;
  }

  /**
   * Authenticate with an existing passkey (modal flow).
   *
   * For conditional UI (autofill), use startConditionalUI() instead.
   *
   * @param username - Optional username hint for non-discoverable credentials.
   * @throws {WebAuthnError} On failure.
   */
  async authenticate(username?: string): Promise<AuthenticationResult> {
    this.abortConditionalUI();

    if (!browserSupportsWebAuthn()) {
      throw new WebAuthnError('not_supported', 'WebAuthn is not supported in this browser.');
    }

    // Step 1: Get authentication options
    const body = username ? JSON.stringify({ username }) : undefined;
    const optionsJSON = await this.fetchJSON<PublicKeyCredentialRequestOptionsJSON>(
      `${this.basePath}/authenticate/options`,
      { method: 'POST', body }
    );

    // Step 2: Start browser authentication ceremony
    let assertionResp: AuthenticationResponseJSON;
    try {
      assertionResp = await startAuthentication({ optionsJSON });
    } catch (error) {
      throw this.categorizeError(error, 'authentication');
    }

    // Step 3: Verify on server
    const result = await this.fetchJSON<AuthenticationResult>(
      `${this.basePath}/authenticate/verify`,
      {
        method: 'POST',
        body: JSON.stringify(assertionResp),
      }
    );

    return result;
  }

  /**
   * Start conditional UI (passkey autofill) authentication.
   *
   * Call this early on the login page — before user interaction.
   * The browser will show passkey options in the autofill dropdown.
   * Requires an input with autocomplete="username webauthn".
   *
   * @param onSuccess - Callback when user selects a passkey from autofill.
   * @param onError - Optional error callback.
   */
  async startConditionalUI(
    onSuccess: (result: AuthenticationResult) => void,
    onError?: (error: WebAuthnError) => void
  ): Promise<void> {
    const caps = await this.getCapabilities();
    if (!caps.conditionalUIAvailable) return;

    this.abortConditionalUI();
    this.conditionalAbort = new AbortController();

    try {
      // Get options for discoverable credential flow (no allowCredentials)
      const optionsJSON = await this.fetchJSON<PublicKeyCredentialRequestOptionsJSON>(
        `${this.basePath}/authenticate/options`,
        { method: 'POST', body: JSON.stringify({ conditional: true }) }
      );

      const assertionResp = await startAuthentication({
        optionsJSON,
        useBrowserAutofill: true,
      });

      const result = await this.fetchJSON<AuthenticationResult>(
        `${this.basePath}/authenticate/verify`,
        {
          method: 'POST',
          body: JSON.stringify(assertionResp),
        }
      );

      onSuccess(result);
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') {
        return; // Intentional abort, not an error
      }
      const webAuthnError = this.categorizeError(error, 'authentication');
      onError?.(webAuthnError);
    }
  }

  /**
   * Abort any active conditional UI ceremony.
   * Must be called before starting a modal registration or authentication.
   */
  abortConditionalUI(): void {
    if (this.conditionalAbort) {
      this.conditionalAbort.abort();
      this.conditionalAbort = null;
    }
  }

  // --- Private helpers ---

  private async fetchJSON<T>(url: string, init: RequestInit = {}): Promise<T> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.fetchTimeout);

    try {
      const response = await fetch(url, {
        ...init,
        headers: {
          'Content-Type': 'application/json',
          ...init.headers,
        },
        credentials: 'same-origin',
        signal: controller.signal,
      });

      if (!response.ok) {
        const errorBody = await response.text().catch(() => '');
        throw new WebAuthnError(
          'server_error',
          `Server returned ${response.status}: ${errorBody}`
        );
      }

      return await response.json();
    } catch (error) {
      if (error instanceof WebAuthnError) throw error;
      if (error instanceof DOMException && error.name === 'AbortError') {
        throw new WebAuthnError('network_error', 'Request timed out');
      }
      throw new WebAuthnError('network_error', 'Network request failed', error);
    } finally {
      clearTimeout(timeout);
    }
  }

  private categorizeError(error: unknown, ceremony: string): WebAuthnError {
    if (error instanceof WebAuthnError) return error;

    if (error instanceof DOMException) {
      switch (error.name) {
        case 'NotAllowedError':
          return new WebAuthnError(
            'user_cancelled',
            `${ceremony} was cancelled or timed out.`,
            error
          );
        case 'InvalidStateError':
          return new WebAuthnError(
            'already_registered',
            'This authenticator is already registered.',
            error
          );
        case 'SecurityError':
          return new WebAuthnError(
            'security_error',
            'Security error — check origin and rpId configuration.',
            error
          );
        case 'NotSupportedError':
          return new WebAuthnError(
            'not_supported',
            'Authenticator does not support the requested algorithm.',
            error
          );
      }
    }

    return new WebAuthnError(
      'unknown',
      `Unexpected error during ${ceremony}: ${String(error)}`,
      error
    );
  }
}
