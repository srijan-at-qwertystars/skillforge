/**
 * NextAuth.js (Auth.js) configuration template with multiple OAuth providers,
 * JWT callbacks, and session management.
 *
 * Features:
 * - Multiple providers (Google, GitHub, Microsoft, Auth0, Okta, Keycloak)
 * - JWT callback with access token persistence and refresh
 * - Session callback exposing user roles and provider info
 * - Account linking by verified email
 * - Sign-in/sign-out event handlers
 *
 * Usage:
 *   // app/api/auth/[...nextauth]/route.ts (App Router)
 *   import NextAuth from 'next-auth';
 *   import { authOptions } from './nextauth-config';
 *   const handler = NextAuth(authOptions);
 *   export { handler as GET, handler as POST };
 *
 *   // pages/api/auth/[...nextauth].ts (Pages Router)
 *   import NextAuth from 'next-auth';
 *   import { authOptions } from './nextauth-config';
 *   export default NextAuth(authOptions);
 *
 * Environment variables required:
 *   NEXTAUTH_SECRET          — Random secret for JWT encryption
 *   NEXTAUTH_URL             — App URL (e.g., https://app.example.com)
 *   GOOGLE_CLIENT_ID         — Google OAuth client ID
 *   GOOGLE_CLIENT_SECRET     — Google OAuth client secret
 *   GITHUB_CLIENT_ID         — GitHub OAuth App client ID
 *   GITHUB_CLIENT_SECRET     — GitHub OAuth App client secret
 *   AZURE_AD_CLIENT_ID       — Azure AD app client ID
 *   AZURE_AD_CLIENT_SECRET   — Azure AD app client secret
 *   AZURE_AD_TENANT_ID       — Azure AD tenant ID
 *   AUTH0_CLIENT_ID          — Auth0 app client ID
 *   AUTH0_CLIENT_SECRET      — Auth0 app client secret
 *   AUTH0_ISSUER             — Auth0 issuer URL (https://your-domain.auth0.com)
 *   OKTA_CLIENT_ID           — Okta app client ID
 *   OKTA_CLIENT_SECRET       — Okta app client secret
 *   OKTA_ISSUER              — Okta issuer URL
 *   KEYCLOAK_CLIENT_ID       — Keycloak client ID
 *   KEYCLOAK_CLIENT_SECRET   — Keycloak client secret
 *   KEYCLOAK_ISSUER          — Keycloak issuer URL (https://host/realms/realm)
 */

import type { AuthOptions, Account, Profile, User, Session } from 'next-auth';
import type { JWT } from 'next-auth/jwt';
import GoogleProvider from 'next-auth/providers/google';
import GitHubProvider from 'next-auth/providers/github';
import AzureADProvider from 'next-auth/providers/azure-ad';
import Auth0Provider from 'next-auth/providers/auth0';
import OktaProvider from 'next-auth/providers/okta';
import KeycloakProvider from 'next-auth/providers/keycloak';

// ─── Type Extensions ─────────────────────────────────────────────────────────

declare module 'next-auth' {
  interface Session {
    accessToken?: string;
    error?: string;
    user: {
      id: string;
      name?: string | null;
      email?: string | null;
      image?: string | null;
      roles?: string[];
      provider?: string;
    };
  }
}

declare module 'next-auth/jwt' {
  interface JWT {
    accessToken?: string;
    refreshToken?: string;
    accessTokenExpires?: number;
    error?: string;
    provider?: string;
    providerAccountId?: string;
    roles?: string[];
  }
}

// ─── Token Refresh ───────────────────────────────────────────────────────────

async function refreshAccessToken(token: JWT): Promise<JWT> {
  const provider = token.provider;

  // Provider-specific refresh endpoints and parameters
  const refreshConfigs: Record<string, { tokenUrl: string; extraParams?: Record<string, string> }> =
    {
      google: {
        tokenUrl: 'https://oauth2.googleapis.com/token',
      },
      azure_ad: {
        tokenUrl: `https://login.microsoftonline.com/${process.env.AZURE_AD_TENANT_ID}/oauth2/v2.0/token`,
      },
      auth0: {
        tokenUrl: `${process.env.AUTH0_ISSUER}/oauth/token`,
      },
      okta: {
        tokenUrl: `${process.env.OKTA_ISSUER}/v1/token`,
      },
      keycloak: {
        tokenUrl: `${process.env.KEYCLOAK_ISSUER}/protocol/openid-connect/token`,
      },
    };

  const config = provider ? refreshConfigs[provider] : undefined;
  if (!config || !token.refreshToken) {
    return { ...token, error: 'RefreshTokenUnavailable' };
  }

  // Map provider to its client credentials env vars
  const clientCredentials: Record<string, { id: string; secret: string }> = {
    google: {
      id: process.env.GOOGLE_CLIENT_ID!,
      secret: process.env.GOOGLE_CLIENT_SECRET!,
    },
    azure_ad: {
      id: process.env.AZURE_AD_CLIENT_ID!,
      secret: process.env.AZURE_AD_CLIENT_SECRET!,
    },
    auth0: {
      id: process.env.AUTH0_CLIENT_ID!,
      secret: process.env.AUTH0_CLIENT_SECRET!,
    },
    okta: {
      id: process.env.OKTA_CLIENT_ID!,
      secret: process.env.OKTA_CLIENT_SECRET!,
    },
    keycloak: {
      id: process.env.KEYCLOAK_CLIENT_ID!,
      secret: process.env.KEYCLOAK_CLIENT_SECRET!,
    },
  };

  const creds = clientCredentials[provider!];
  if (!creds) {
    return { ...token, error: 'RefreshTokenUnavailable' };
  }

  try {
    const body = new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: token.refreshToken,
      client_id: creds.id,
      client_secret: creds.secret,
      ...config.extraParams,
    });

    const response = await fetch(config.tokenUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    });

    const data = await response.json();

    if (!response.ok) {
      console.error('Token refresh failed:', data);
      return { ...token, error: 'RefreshTokenError' };
    }

    return {
      ...token,
      accessToken: data.access_token,
      accessTokenExpires: Date.now() + (data.expires_in ?? 3600) * 1000,
      // Some providers rotate refresh tokens
      refreshToken: data.refresh_token ?? token.refreshToken,
      error: undefined,
    };
  } catch (error) {
    console.error('Token refresh error:', error);
    return { ...token, error: 'RefreshTokenError' };
  }
}

// ─── Auth Configuration ──────────────────────────────────────────────────────

export const authOptions: AuthOptions = {
  // ── Providers ────────────────────────────────────────────────────────────

  providers: [
    GoogleProvider({
      clientId: process.env.GOOGLE_CLIENT_ID!,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET!,
      authorization: {
        params: {
          access_type: 'offline', // Required for refresh token
          prompt: 'consent', // Force consent to always get refresh token
          scope: 'openid email profile',
        },
      },
    }),

    GitHubProvider({
      clientId: process.env.GITHUB_CLIENT_ID!,
      clientSecret: process.env.GITHUB_CLIENT_SECRET!,
      authorization: {
        params: {
          scope: 'read:user user:email',
        },
      },
    }),

    AzureADProvider({
      clientId: process.env.AZURE_AD_CLIENT_ID!,
      clientSecret: process.env.AZURE_AD_CLIENT_SECRET!,
      tenantId: process.env.AZURE_AD_TENANT_ID!,
      authorization: {
        params: {
          scope: 'openid email profile offline_access User.Read',
        },
      },
    }),

    Auth0Provider({
      clientId: process.env.AUTH0_CLIENT_ID!,
      clientSecret: process.env.AUTH0_CLIENT_SECRET!,
      issuer: process.env.AUTH0_ISSUER!,
      authorization: {
        params: {
          scope: 'openid email profile offline_access',
          audience: process.env.AUTH0_AUDIENCE, // Set if using a custom API
        },
      },
    }),

    OktaProvider({
      clientId: process.env.OKTA_CLIENT_ID!,
      clientSecret: process.env.OKTA_CLIENT_SECRET!,
      issuer: process.env.OKTA_ISSUER!,
    }),

    KeycloakProvider({
      clientId: process.env.KEYCLOAK_CLIENT_ID!,
      clientSecret: process.env.KEYCLOAK_CLIENT_SECRET!,
      issuer: process.env.KEYCLOAK_ISSUER!,
    }),
  ],

  // ── Session Strategy ─────────────────────────────────────────────────────

  session: {
    strategy: 'jwt',
    maxAge: 24 * 60 * 60, // 24 hours
  },

  // ── JWT Configuration ────────────────────────────────────────────────────

  jwt: {
    maxAge: 24 * 60 * 60, // Must match session.maxAge
  },

  // ── Pages (customize as needed) ──────────────────────────────────────────

  pages: {
    signIn: '/auth/signin',
    // error: '/auth/error',
    // signOut: '/auth/signout',
  },

  // ── Callbacks ────────────────────────────────────────────────────────────

  callbacks: {
    /**
     * Controls whether a user is allowed to sign in.
     * Use this to restrict access by email domain, role, or provider.
     */
    async signIn({ user, account, profile }): Promise<boolean | string> {
      // Example: restrict to a specific email domain
      // if (user.email && !user.email.endsWith('@yourcompany.com')) {
      //   return '/auth/unauthorized';
      // }

      // Example: require email verification (Google, Auth0)
      // if (profile && 'email_verified' in profile && !profile.email_verified) {
      //   return false;
      // }

      return true;
    },

    /**
     * Called whenever a JWT is created or updated.
     * Persist the access token and refresh token from the provider.
     */
    async jwt({ token, account, user, trigger }): Promise<JWT> {
      // Initial sign in — persist provider tokens
      if (account && user) {
        return {
          ...token,
          accessToken: account.access_token ?? undefined,
          refreshToken: account.refresh_token ?? undefined,
          accessTokenExpires: account.expires_at
            ? account.expires_at * 1000
            : Date.now() + 3600 * 1000,
          provider: account.provider,
          providerAccountId: account.providerAccountId,
          sub: user.id,
        };
      }

      // Return existing token if it hasn't expired
      if (token.accessTokenExpires && Date.now() < token.accessTokenExpires - 60_000) {
        return token;
      }

      // Token is expired or about to expire — try to refresh
      // Note: GitHub tokens don't expire by default (no refresh needed)
      if (token.provider === 'github') {
        return token;
      }

      return refreshAccessToken(token);
    },

    /**
     * Called whenever a session is checked.
     * Add custom properties to the session object available on the client.
     */
    async session({ session, token }): Promise<Session> {
      if (token) {
        session.user.id = token.sub ?? '';
        session.user.provider = token.provider;
        session.user.roles = token.roles;
        session.accessToken = token.accessToken;

        // Surface token refresh errors to the client
        if (token.error) {
          session.error = token.error;
        }
      }

      return session;
    },
  },

  // ── Events ───────────────────────────────────────────────────────────────

  events: {
    async signIn({ user, account }) {
      console.log(`User signed in: ${user.email} via ${account?.provider}`);
    },

    async signOut({ token }) {
      console.log(`User signed out: ${token.sub}`);

      // Optionally revoke tokens at the provider
      // if (token.provider === 'keycloak' && token.accessToken) {
      //   await fetch(`${process.env.KEYCLOAK_ISSUER}/protocol/openid-connect/logout`, {
      //     method: 'POST',
      //     headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      //     body: new URLSearchParams({
      //       client_id: process.env.KEYCLOAK_CLIENT_ID!,
      //       client_secret: process.env.KEYCLOAK_CLIENT_SECRET!,
      //       refresh_token: token.refreshToken!,
      //     }),
      //   });
      // }
    },
  },

  // ── Debug ────────────────────────────────────────────────────────────────

  debug: process.env.NODE_ENV === 'development',
};
