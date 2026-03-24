# Keycloak Integration Guide

## Table of Contents

- [Spring Boot 3 Integration](#spring-boot-3-integration)
- [Node.js / Express Integration](#nodejs--express-integration)
- [React SPA Integration](#react-spa-integration)
- [Angular Integration](#angular-integration)
- [Next.js Integration](#nextjs-integration)
- [Nginx Reverse Proxy Auth](#nginx-reverse-proxy-auth)
- [Apache Reverse Proxy Auth](#apache-reverse-proxy-auth)
- [Kong Gateway Integration](#kong-gateway-integration)
- [APISIX Gateway Integration](#apisix-gateway-integration)
- [Kubernetes Ingress Auth](#kubernetes-ingress-auth)
- [Mobile Apps (PKCE Flow)](#mobile-apps-pkce-flow)

---

## Spring Boot 3 Integration

### Dependencies

```xml
<!-- pom.xml -->
<dependencies>
    <!-- Resource Server (JWT validation) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
    </dependency>
    <!-- Client (login flow, token relay) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-oauth2-client</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-security</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
</dependencies>
```

### Application Configuration

```yaml
# application.yml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: https://auth.example.com/realms/my-realm
          jwk-set-uri: https://auth.example.com/realms/my-realm/protocol/openid-connect/certs
      client:
        registration:
          keycloak:
            client-id: my-spring-app
            client-secret: ${KEYCLOAK_CLIENT_SECRET}
            scope: openid,profile,email
            authorization-grant-type: authorization_code
            redirect-uri: "{baseUrl}/login/oauth2/code/{registrationId}"
        provider:
          keycloak:
            issuer-uri: https://auth.example.com/realms/my-realm
            user-name-attribute: preferred_username
```

### Resource Server Configuration (API)

```java
package com.example.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.converter.Converter;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.web.SecurityFilterChain;

import java.util.*;
import java.util.stream.Collectors;
import java.util.stream.Stream;

@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class ResourceServerConfig {

    @Bean
    public SecurityFilterChain resourceServerFilterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .sessionManagement(session ->
                session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/public/**").permitAll()
                .requestMatchers("/api/admin/**").hasRole("admin")
                .requestMatchers("/api/user/**").hasAnyRole("user", "admin")
                .requestMatchers("/actuator/health").permitAll()
                .anyRequest().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt
                    .jwtAuthenticationConverter(keycloakJwtConverter())
                )
            );
        return http.build();
    }

    @Bean
    public JwtAuthenticationConverter keycloakJwtConverter() {
        var converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(new KeycloakGrantedAuthoritiesConverter());
        converter.setPrincipalClaimName("preferred_username");
        return converter;
    }

    /**
     * Extracts both realm_access.roles and resource_access.{client}.roles
     * from the Keycloak JWT and converts them to Spring Security authorities.
     */
    static class KeycloakGrantedAuthoritiesConverter
            implements Converter<Jwt, Collection<GrantedAuthority>> {

        @Override
        public Collection<GrantedAuthority> convert(Jwt jwt) {
            Stream<String> realmRoles = extractRealmRoles(jwt);
            Stream<String> clientRoles = extractClientRoles(jwt);

            return Stream.concat(realmRoles, clientRoles)
                .map(role -> new SimpleGrantedAuthority("ROLE_" + role))
                .collect(Collectors.toSet());
        }

        private Stream<String> extractRealmRoles(Jwt jwt) {
            Map<String, Object> realmAccess = jwt.getClaim("realm_access");
            if (realmAccess == null) return Stream.empty();
            @SuppressWarnings("unchecked")
            List<String> roles = (List<String>) realmAccess.get("roles");
            return roles != null ? roles.stream() : Stream.empty();
        }

        private Stream<String> extractClientRoles(Jwt jwt) {
            Map<String, Object> resourceAccess = jwt.getClaim("resource_access");
            if (resourceAccess == null) return Stream.empty();
            return resourceAccess.values().stream()
                .filter(v -> v instanceof Map)
                .flatMap(v -> {
                    @SuppressWarnings("unchecked")
                    List<String> roles = (List<String>) ((Map<String, Object>) v).get("roles");
                    return roles != null ? roles.stream() : Stream.empty();
                });
        }
    }
}
```

### OAuth2 Client Configuration (Web App with Login)

```java
@Configuration
public class OAuth2ClientConfig {

    @Bean
    public SecurityFilterChain clientFilterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/", "/login", "/css/**", "/js/**").permitAll()
                .anyRequest().authenticated()
            )
            .oauth2Login(oauth2 -> oauth2
                .defaultSuccessUrl("/dashboard", true)
                .failureUrl("/login?error=true")
            )
            .logout(logout -> logout
                .logoutSuccessUrl("/")
                .addLogoutHandler(keycloakLogoutHandler())
            );
        return http.build();
    }

    /**
     * Propagate logout to Keycloak (RP-initiated logout)
     */
    @Bean
    public OidcClientInitiatedLogoutSuccessHandler keycloakLogoutHandler() {
        // Triggers backchannel logout to Keycloak
        return new OidcClientInitiatedLogoutSuccessHandler(clientRegistrationRepository);
    }

    @Autowired
    private ClientRegistrationRepository clientRegistrationRepository;
}
```

### Controller Example

```java
@RestController
@RequestMapping("/api")
public class ApiController {

    @GetMapping("/user/profile")
    public Map<String, Object> getProfile(@AuthenticationPrincipal Jwt jwt) {
        return Map.of(
            "username", jwt.getClaim("preferred_username"),
            "email", jwt.getClaim("email"),
            "roles", jwt.getClaim("realm_access")
        );
    }

    @PreAuthorize("hasRole('admin')")
    @GetMapping("/admin/users")
    public String adminEndpoint() {
        return "Admin-only content";
    }

    @PreAuthorize("hasAuthority('ROLE_document_editor')")
    @PostMapping("/documents")
    public String createDocument() {
        return "Document created";
    }
}
```

### Multi-Tenant Configuration

```java
@Bean
public JwtIssuerAuthenticationManagerResolver multiTenantResolver() {
    return JwtIssuerAuthenticationManagerResolver.fromTrustedIssuers(
        "https://auth.example.com/realms/tenant-a",
        "https://auth.example.com/realms/tenant-b",
        "https://auth.example.com/realms/tenant-c"
    );
}

@Bean
public SecurityFilterChain multiTenantFilter(HttpSecurity http) throws Exception {
    http.oauth2ResourceServer(oauth2 -> oauth2
        .authenticationManagerResolver(multiTenantResolver()));
    return http.build();
}
```

---

## Node.js / Express Integration

### Resource Server (JWT Validation Middleware)

```javascript
// auth.js — Keycloak JWT validation middleware
const jwt = require('jsonwebtoken');
const jwksClient = require('jwks-rsa');

const KEYCLOAK_URL = process.env.KEYCLOAK_URL || 'https://auth.example.com';
const REALM = process.env.KEYCLOAK_REALM || 'my-realm';
const EXPECTED_ISSUER = `${KEYCLOAK_URL}/realms/${REALM}`;

const client = jwksClient({
  jwksUri: `${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/certs`,
  cache: true,
  cacheMaxEntries: 5,
  cacheMaxAge: 600000, // 10 minutes
  rateLimit: true,
  jwksRequestsPerMinute: 10,
});

function getSigningKey(header, callback) {
  client.getSigningKey(header.kid, (err, key) => {
    if (err) return callback(err);
    callback(null, key.getPublicKey());
  });
}

function authenticate(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or invalid Authorization header' });
  }

  const token = authHeader.split(' ')[1];
  jwt.verify(token, getSigningKey, {
    issuer: EXPECTED_ISSUER,
    algorithms: ['RS256'],
    clockTolerance: 30,
  }, (err, decoded) => {
    if (err) {
      console.error('Token verification failed:', err.message);
      return res.status(401).json({ error: 'Invalid token', details: err.message });
    }
    req.user = decoded;
    req.user.roles = extractRoles(decoded);
    next();
  });
}

function extractRoles(decodedToken) {
  const roles = new Set();
  // Realm roles
  if (decodedToken.realm_access?.roles) {
    decodedToken.realm_access.roles.forEach(r => roles.add(r));
  }
  // Client roles
  if (decodedToken.resource_access) {
    Object.values(decodedToken.resource_access).forEach(client => {
      if (client.roles) client.roles.forEach(r => roles.add(r));
    });
  }
  return [...roles];
}

function requireRole(...roles) {
  return (req, res, next) => {
    if (!req.user || !req.user.roles) {
      return res.status(403).json({ error: 'No roles found' });
    }
    const hasRole = roles.some(role => req.user.roles.includes(role));
    if (!hasRole) {
      return res.status(403).json({ error: 'Insufficient permissions', required: roles });
    }
    next();
  };
}

module.exports = { authenticate, requireRole };
```

### Express App with OpenID Connect Login

```javascript
// app.js — Full Express app with Keycloak OIDC
const express = require('express');
const session = require('express-session');
const passport = require('passport');
const { Strategy: OidcStrategy } = require('passport-openidconnect');
const { authenticate, requireRole } = require('./auth');

const app = express();

// Session for web login flow
app.use(session({
  secret: process.env.SESSION_SECRET || 'change-me-in-production',
  resave: false,
  saveUninitialized: false,
  cookie: { secure: process.env.NODE_ENV === 'production', maxAge: 3600000 },
}));
app.use(passport.initialize());
app.use(passport.session());

// Configure OIDC strategy for web login
passport.use('keycloak', new OidcStrategy({
  issuer: `${process.env.KEYCLOAK_URL}/realms/${process.env.KEYCLOAK_REALM}`,
  authorizationURL: `${process.env.KEYCLOAK_URL}/realms/${process.env.KEYCLOAK_REALM}/protocol/openid-connect/auth`,
  tokenURL: `${process.env.KEYCLOAK_URL}/realms/${process.env.KEYCLOAK_REALM}/protocol/openid-connect/token`,
  userInfoURL: `${process.env.KEYCLOAK_URL}/realms/${process.env.KEYCLOAK_REALM}/protocol/openid-connect/userinfo`,
  clientID: process.env.KEYCLOAK_CLIENT_ID,
  clientSecret: process.env.KEYCLOAK_CLIENT_SECRET,
  callbackURL: process.env.CALLBACK_URL || 'http://localhost:3000/auth/callback',
  scope: 'openid profile email',
}, (issuer, profile, context, idToken, accessToken, refreshToken, done) => {
  // Store tokens in user session
  profile.accessToken = accessToken;
  profile.refreshToken = refreshToken;
  profile.idToken = idToken;
  return done(null, profile);
}));

passport.serializeUser((user, done) => done(null, user));
passport.deserializeUser((user, done) => done(null, user));

// Web login routes
app.get('/auth/login', passport.authenticate('keycloak'));

app.get('/auth/callback',
  passport.authenticate('keycloak', { failureRedirect: '/auth/login' }),
  (req, res) => res.redirect('/dashboard')
);

app.get('/auth/logout', (req, res) => {
  const idTokenHint = req.user?.idToken;
  req.logout(() => {
    const logoutUrl = `${process.env.KEYCLOAK_URL}/realms/${process.env.KEYCLOAK_REALM}` +
      `/protocol/openid-connect/logout?id_token_hint=${idTokenHint}` +
      `&post_logout_redirect_uri=${encodeURIComponent('http://localhost:3000/')}`;
    res.redirect(logoutUrl);
  });
});

// Protected web page
app.get('/dashboard', (req, res) => {
  if (!req.isAuthenticated()) return res.redirect('/auth/login');
  res.json({ message: 'Dashboard', user: req.user.displayName });
});

// API routes with JWT auth (no session needed)
app.get('/api/public/health', (req, res) => res.json({ status: 'ok' }));
app.get('/api/profile', authenticate, (req, res) => {
  res.json({ username: req.user.preferred_username, roles: req.user.roles });
});
app.get('/api/admin', authenticate, requireRole('admin'), (req, res) => {
  res.json({ message: 'Admin area' });
});

app.listen(3000, () => console.log('Server running on port 3000'));
```

### Package Dependencies

```json
{
  "dependencies": {
    "express": "^4.18.0",
    "express-session": "^1.17.0",
    "jsonwebtoken": "^9.0.0",
    "jwks-rsa": "^3.1.0",
    "passport": "^0.7.0",
    "passport-openidconnect": "^0.1.0"
  }
}
```

---

## React SPA Integration

### Using react-oidc-context

```bash
npm install oidc-client-ts react-oidc-context
```

### Auth Provider Setup

```tsx
// src/auth/AuthProvider.tsx
import { AuthProvider as OidcAuthProvider } from 'react-oidc-context';
import { WebStorageStateStore } from 'oidc-client-ts';
import type { User } from 'oidc-client-ts';

const oidcConfig = {
  authority: `${import.meta.env.VITE_KEYCLOAK_URL}/realms/${import.meta.env.VITE_KEYCLOAK_REALM}`,
  client_id: import.meta.env.VITE_KEYCLOAK_CLIENT_ID,
  redirect_uri: window.location.origin + '/callback',
  post_logout_redirect_uri: window.location.origin + '/',
  scope: 'openid profile email',
  response_type: 'code',

  // Silent refresh configuration
  automaticSilentRenew: true,
  silent_redirect_uri: window.location.origin + '/silent-refresh.html',

  // Token storage
  userStore: new WebStorageStateStore({ store: window.sessionStorage }),

  // Keycloak-specific settings
  metadata: {
    end_session_endpoint:
      `${import.meta.env.VITE_KEYCLOAK_URL}/realms/${import.meta.env.VITE_KEYCLOAK_REALM}/protocol/openid-connect/logout`,
  },

  onSigninCallback: () => {
    // Remove OIDC query params from URL after login
    window.history.replaceState({}, document.title, window.location.pathname);
  },
};

export function AuthProvider({ children }: { children: React.ReactNode }) {
  return (
    <OidcAuthProvider {...oidcConfig}>
      {children}
    </OidcAuthProvider>
  );
}

// Helper to extract Keycloak roles from the access token
export function extractRoles(user: User | null): string[] {
  if (!user?.access_token) return [];
  try {
    const payload = JSON.parse(atob(user.access_token.split('.')[1]));
    const realmRoles = payload.realm_access?.roles || [];
    const clientRoles = Object.values(payload.resource_access || {})
      .flatMap((client: any) => client.roles || []);
    return [...new Set([...realmRoles, ...clientRoles])];
  } catch {
    return [];
  }
}
```

### Protected Routes and Components

```tsx
// src/components/ProtectedRoute.tsx
import { useAuth } from 'react-oidc-context';
import { Navigate } from 'react-router-dom';
import { extractRoles } from '../auth/AuthProvider';

interface ProtectedRouteProps {
  children: React.ReactNode;
  requiredRoles?: string[];
}

export function ProtectedRoute({ children, requiredRoles = [] }: ProtectedRouteProps) {
  const auth = useAuth();

  if (auth.isLoading) {
    return <div className="loading">Loading...</div>;
  }

  if (!auth.isAuthenticated) {
    // Redirect to Keycloak login
    auth.signinRedirect();
    return <div>Redirecting to login...</div>;
  }

  if (requiredRoles.length > 0) {
    const userRoles = extractRoles(auth.user);
    const hasRequiredRole = requiredRoles.some(role => userRoles.includes(role));
    if (!hasRequiredRole) {
      return <Navigate to="/unauthorized" replace />;
    }
  }

  return <>{children}</>;
}
```

### API Client with Token Management

```tsx
// src/api/client.ts
import { User } from 'oidc-client-ts';

let currentUser: User | null = null;

export function setCurrentUser(user: User | null) {
  currentUser = user;
}

export async function apiFetch(url: string, options: RequestInit = {}): Promise<Response> {
  if (!currentUser?.access_token) {
    throw new Error('Not authenticated');
  }

  // Check if token is about to expire (within 30 seconds)
  const expiresAt = currentUser.expires_at || 0;
  if (Date.now() / 1000 > expiresAt - 30) {
    // The oidc-client-ts library handles silent refresh automatically
    // This is a fallback check
    console.warn('Token is about to expire. Silent refresh should handle this.');
  }

  const response = await fetch(url, {
    ...options,
    headers: {
      ...options.headers,
      'Authorization': `Bearer ${currentUser.access_token}`,
      'Content-Type': 'application/json',
    },
  });

  if (response.status === 401) {
    // Token expired or invalid — trigger re-authentication
    window.location.href = '/';
  }

  return response;
}
```

### App Entry Point

```tsx
// src/App.tsx
import { useAuth } from 'react-oidc-context';
import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { AuthProvider } from './auth/AuthProvider';
import { ProtectedRoute } from './components/ProtectedRoute';
import { setCurrentUser } from './api/client';
import { useEffect } from 'react';

function AppRoutes() {
  const auth = useAuth();

  useEffect(() => {
    setCurrentUser(auth.user ?? null);
  }, [auth.user]);

  return (
    <div>
      <nav>
        {auth.isAuthenticated ? (
          <>
            <span>Welcome, {auth.user?.profile.preferred_username}</span>
            <button onClick={() => auth.signoutRedirect()}>Logout</button>
          </>
        ) : (
          <button onClick={() => auth.signinRedirect()}>Login</button>
        )}
      </nav>
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/callback" element={<CallbackPage />} />
        <Route path="/dashboard" element={
          <ProtectedRoute><Dashboard /></ProtectedRoute>
        } />
        <Route path="/admin" element={
          <ProtectedRoute requiredRoles={['admin']}><AdminPanel /></ProtectedRoute>
        } />
      </Routes>
    </div>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <AppRoutes />
      </BrowserRouter>
    </AuthProvider>
  );
}
```

### Silent Refresh HTML

Create `public/silent-refresh.html`:

```html
<!DOCTYPE html>
<html>
<body>
  <script>
    // This page is loaded in a hidden iframe for silent token refresh.
    // The oidc-client-ts library handles the callback automatically.
    parent.postMessage(window.location.href, window.location.origin);
  </script>
</body>
</html>
```

---

## Angular Integration

### Installation

```bash
npm install angular-auth-oidc-client
```

### Module Configuration

```typescript
// app.config.ts (standalone Angular 17+)
import { ApplicationConfig } from '@angular/core';
import { provideAuth, LogLevel } from 'angular-auth-oidc-client';

export const appConfig: ApplicationConfig = {
  providers: [
    provideAuth({
      config: {
        authority: 'https://auth.example.com/realms/my-realm',
        redirectUrl: window.location.origin + '/callback',
        postLogoutRedirectUri: window.location.origin,
        clientId: 'my-angular-app',
        scope: 'openid profile email',
        responseType: 'code',
        silentRenew: true,
        silentRenewUrl: window.location.origin + '/silent-renew.html',
        useRefreshToken: true,
        logLevel: LogLevel.Warn,
        secureRoutes: ['https://api.example.com/'],
        customParamsAuthRequest: {
          kc_locale: 'en',
        },
      },
    }),
  ],
};
```

### Auth Guard

```typescript
// auth.guard.ts
import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { OidcSecurityService } from 'angular-auth-oidc-client';
import { map, take } from 'rxjs/operators';

export const authGuard: CanActivateFn = () => {
  const oidcService = inject(OidcSecurityService);
  const router = inject(Router);

  return oidcService.isAuthenticated$.pipe(
    take(1),
    map(({ isAuthenticated }) => {
      if (!isAuthenticated) {
        oidcService.authorize();
        return false;
      }
      return true;
    })
  );
};

export const roleGuard = (requiredRoles: string[]): CanActivateFn => {
  return () => {
    const oidcService = inject(OidcSecurityService);
    const router = inject(Router);

    return oidcService.getUserData().pipe(
      take(1),
      map(userData => {
        const realmRoles = userData?.realm_access?.roles || [];
        const hasRole = requiredRoles.some(role => realmRoles.includes(role));
        if (!hasRole) {
          router.navigate(['/unauthorized']);
          return false;
        }
        return true;
      })
    );
  };
};
```

### HTTP Interceptor

```typescript
// auth.interceptor.ts
import { HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';
import { OidcSecurityService } from 'angular-auth-oidc-client';
import { switchMap, take } from 'rxjs/operators';

export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const oidcService = inject(OidcSecurityService);

  // Only add token for configured secure routes
  if (!req.url.startsWith('https://api.example.com/')) {
    return next(req);
  }

  return oidcService.getAccessToken().pipe(
    take(1),
    switchMap(token => {
      if (token) {
        req = req.clone({
          setHeaders: { Authorization: `Bearer ${token}` },
        });
      }
      return next(req);
    })
  );
};
```

---

## Next.js Integration

### Using next-auth with Keycloak Provider

```bash
npm install next-auth
```

### Auth Configuration

```typescript
// app/api/auth/[...nextauth]/route.ts (App Router)
import NextAuth from 'next-auth';
import KeycloakProvider from 'next-auth/providers/keycloak';
import type { NextAuthOptions } from 'next-auth';

export const authOptions: NextAuthOptions = {
  providers: [
    KeycloakProvider({
      clientId: process.env.KEYCLOAK_CLIENT_ID!,
      clientSecret: process.env.KEYCLOAK_CLIENT_SECRET!,
      issuer: `${process.env.KEYCLOAK_URL}/realms/${process.env.KEYCLOAK_REALM}`,
    }),
  ],
  callbacks: {
    async jwt({ token, account, profile }) {
      // Persist the access_token and roles from Keycloak in the JWT
      if (account) {
        token.accessToken = account.access_token;
        token.refreshToken = account.refresh_token;
        token.expiresAt = account.expires_at;
        token.idToken = account.id_token;
      }

      // Extract roles from the access token
      if (token.accessToken) {
        try {
          const payload = JSON.parse(
            Buffer.from((token.accessToken as string).split('.')[1], 'base64').toString()
          );
          token.roles = payload.realm_access?.roles || [];
        } catch {
          token.roles = [];
        }
      }

      // Handle token refresh
      if (Date.now() < ((token.expiresAt as number) ?? 0) * 1000) {
        return token;
      }
      return await refreshAccessToken(token);
    },

    async session({ session, token }) {
      session.accessToken = token.accessToken as string;
      session.roles = (token.roles as string[]) || [];
      session.error = token.error as string | undefined;
      return session;
    },
  },
  events: {
    async signOut({ token }) {
      // Propagate logout to Keycloak
      if (token.idToken) {
        const logoutUrl = `${process.env.KEYCLOAK_URL}/realms/${process.env.KEYCLOAK_REALM}` +
          `/protocol/openid-connect/logout?id_token_hint=${token.idToken}`;
        await fetch(logoutUrl);
      }
    },
  },
};

async function refreshAccessToken(token: any) {
  try {
    const response = await fetch(
      `${process.env.KEYCLOAK_URL}/realms/${process.env.KEYCLOAK_REALM}/protocol/openid-connect/token`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'refresh_token',
          client_id: process.env.KEYCLOAK_CLIENT_ID!,
          client_secret: process.env.KEYCLOAK_CLIENT_SECRET!,
          refresh_token: token.refreshToken as string,
        }),
      }
    );

    const data = await response.json();
    if (!response.ok) throw new Error(data.error);

    return {
      ...token,
      accessToken: data.access_token,
      refreshToken: data.refresh_token ?? token.refreshToken,
      expiresAt: Math.floor(Date.now() / 1000) + data.expires_in,
      idToken: data.id_token ?? token.idToken,
    };
  } catch (error) {
    return { ...token, error: 'RefreshAccessTokenError' };
  }
}

const handler = NextAuth(authOptions);
export { handler as GET, handler as POST };
```

### Server Component Usage

```typescript
// app/dashboard/page.tsx
import { getServerSession } from 'next-auth';
import { authOptions } from '../api/auth/[...nextauth]/route';
import { redirect } from 'next/navigation';

export default async function DashboardPage() {
  const session = await getServerSession(authOptions);

  if (!session) {
    redirect('/api/auth/signin');
  }

  const isAdmin = session.roles?.includes('admin');

  return (
    <div>
      <h1>Dashboard</h1>
      <p>Welcome, {session.user?.name}</p>
      {isAdmin && <AdminPanel />}
    </div>
  );
}
```

### Middleware for Route Protection

```typescript
// middleware.ts
export { default } from 'next-auth/middleware';

export const config = {
  matcher: ['/dashboard/:path*', '/admin/:path*', '/api/protected/:path*'],
};
```

---

## Nginx Reverse Proxy Auth

Use `auth_request` to validate tokens against Keycloak's introspection endpoint
before allowing access to upstream services.

```nginx
# /etc/nginx/conf.d/keycloak-auth.conf

# Internal endpoint for token validation
location = /_oauth2_introspect {
    internal;
    proxy_method POST;
    proxy_pass https://auth.example.com/realms/my-realm/protocol/openid-connect/token/introspect;
    proxy_set_header Content-Type "application/x-www-form-urlencoded";
    proxy_set_body "token=$http_x_auth_token&token_type_hint=access_token&client_id=nginx-gateway&client_secret=nginx-secret";
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
}

# Protected upstream
server {
    listen 443 ssl;
    server_name api.example.com;

    ssl_certificate /etc/ssl/certs/api.crt;
    ssl_certificate_key /etc/ssl/private/api.key;

    location /api/ {
        # Extract token from Authorization header
        set $auth_token "";
        if ($http_authorization ~* "^Bearer (.+)$") {
            set $auth_token $1;
        }
        proxy_set_header X-Auth-Token $auth_token;

        auth_request /_oauth2_introspect;
        auth_request_set $auth_status $upstream_status;

        # Pass user info to upstream
        auth_request_set $auth_user $upstream_http_x_auth_user;
        proxy_set_header X-Auth-User $auth_user;

        proxy_pass http://backend:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        error_page 401 = @error401;
    }

    location @error401 {
        return 401 '{"error": "unauthorized", "message": "Valid bearer token required"}';
        add_header Content-Type application/json;
    }
}
```

---

## Apache Reverse Proxy Auth

Use `mod_auth_openidc` for Apache-based OIDC integration:

```apache
# /etc/apache2/sites-available/keycloak-protected.conf
LoadModule auth_openidc_module modules/mod_auth_openidc.so

OIDCProviderMetadataURL https://auth.example.com/realms/my-realm/.well-known/openid-configuration
OIDCClientID my-apache-client
OIDCClientSecret my-client-secret
OIDCRedirectURI https://app.example.com/redirect_uri
OIDCCryptoPassphrase a-random-secret-used-for-encryption
OIDCScope "openid profile email"
OIDCSessionInactivityTimeout 3600
OIDCSessionMaxDuration 28800

<VirtualHost *:443>
    ServerName app.example.com
    SSLEngine on

    <Location /protected>
        AuthType openid-connect
        Require valid-user
        # Pass claims as headers to backend
        OIDCPassClaimsAs headers
    </Location>

    <Location /admin>
        AuthType openid-connect
        Require claim realm_access.roles:admin
    </Location>

    ProxyPass / http://backend:8080/
    ProxyPassReverse / http://backend:8080/
</VirtualHost>
```

---

## Kong Gateway Integration

### Using Kong OIDC Plugin

```bash
# Enable the OIDC plugin on a service
curl -X POST http://kong-admin:8001/services/my-api/plugins \
  --data "name=openid-connect" \
  --data "config.issuer=https://auth.example.com/realms/my-realm" \
  --data "config.client_id=kong-gateway" \
  --data "config.client_secret=kong-secret" \
  --data "config.redirect_uri=https://api.example.com/callback" \
  --data "config.scopes=openid profile email" \
  --data "config.auth_methods=authorization_code,session" \
  --data "config.consumer_claim=preferred_username" \
  --data "config.consumer_by=username"
```

### Declarative Configuration (kong.yml)

```yaml
_format_version: "3.0"

services:
  - name: my-api
    url: http://backend:8080
    routes:
      - name: my-api-route
        paths:
          - /api
    plugins:
      - name: openid-connect
        config:
          issuer: https://auth.example.com/realms/my-realm
          client_id: kong-gateway
          client_secret: kong-secret
          scopes:
            - openid
            - profile
          bearer_token_param_type:
            - header
          verify_signature: true
          verify_claims: true
          upstream_headers_claims:
            - preferred_username
            - email
          upstream_headers_names:
            - X-User-Name
            - X-User-Email
```

---

## APISIX Gateway Integration

```yaml
# apisix/conf.yaml — Route with Keycloak OIDC
routes:
  - uri: /api/*
    upstream:
      type: roundrobin
      nodes:
        "backend:8080": 1
    plugins:
      openid-connect:
        client_id: apisix-gateway
        client_secret: apisix-secret
        discovery: https://auth.example.com/realms/my-realm/.well-known/openid-configuration
        scope: openid profile email
        bearer_only: true
        realm: my-realm
        introspection_endpoint_auth_method: client_secret_post
        set_userinfo_header: true
        access_token_in_authorization_header: true
```

---

## Kubernetes Ingress Auth

### Using Nginx Ingress with oauth2-proxy

```yaml
# oauth2-proxy deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth2-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: oauth2-proxy
  template:
    metadata:
      labels:
        app: oauth2-proxy
    spec:
      containers:
        - name: oauth2-proxy
          image: quay.io/oauth2-proxy/oauth2-proxy:latest
          args:
            - --provider=keycloak-oidc
            - --oidc-issuer-url=https://auth.example.com/realms/my-realm
            - --client-id=oauth2-proxy
            - --client-secret=$(CLIENT_SECRET)
            - --email-domain=*
            - --upstream=static://200
            - --http-address=0.0.0.0:4180
            - --cookie-secret=$(COOKIE_SECRET)
            - --cookie-secure=true
            - --set-xauthrequest=true
            - --pass-access-token=true
          env:
            - name: CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: oauth2-proxy-secret
                  key: client-secret
            - name: COOKIE_SECRET
              valueFrom:
                secretKeyRef:
                  name: oauth2-proxy-secret
                  key: cookie-secret
---
apiVersion: v1
kind: Service
metadata:
  name: oauth2-proxy
spec:
  selector:
    app: oauth2-proxy
  ports:
    - port: 4180
      targetPort: 4180
```

### Ingress with auth-url

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: protected-app
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "https://oauth2-proxy.example.com/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://oauth2-proxy.example.com/oauth2/start?rd=$scheme://$host$escaped_request_uri"
    nginx.ingress.kubernetes.io/auth-response-headers: "X-Auth-Request-User,X-Auth-Request-Email,X-Auth-Request-Access-Token"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - app.example.com
      secretName: app-tls
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 8080
```

---

## Mobile Apps (PKCE Flow)

### iOS (Swift) — Using AppAuth

```swift
import AppAuth

class KeycloakAuth {
    private let issuer = URL(string: "https://auth.example.com/realms/my-realm")!
    private let clientId = "my-mobile-app"
    private let redirectUri = URL(string: "com.example.myapp://callback")!
    private var currentAuthFlow: OIDExternalUserAgentSession?
    private var authState: OIDAuthState?

    func login(presenting viewController: UIViewController, completion: @escaping (Result<String, Error>) -> Void) {
        OIDAuthorizationService.discoverConfiguration(forIssuer: issuer) { config, error in
            guard let config = config else {
                completion(.failure(error ?? NSError(domain: "auth", code: -1)))
                return
            }

            let request = OIDAuthorizationRequest(
                configuration: config,
                clientId: self.clientId,
                clientSecret: nil,  // Public client — no secret
                scopes: [OIDScopeOpenID, OIDScopeProfile, OIDScopeEmail],
                redirectURL: self.redirectUri,
                responseType: OIDResponseTypeCode,
                additionalParameters: ["kc_locale": "en"]
            )
            // PKCE is automatically applied by AppAuth

            self.currentAuthFlow = OIDAuthState.authState(
                byPresenting: request,
                presenting: viewController
            ) { authState, error in
                if let authState = authState {
                    self.authState = authState
                    completion(.success(authState.lastTokenResponse?.accessToken ?? ""))
                } else {
                    completion(.failure(error ?? NSError(domain: "auth", code: -1)))
                }
            }
        }
    }

    func getValidAccessToken(completion: @escaping (String?) -> Void) {
        authState?.performAction { accessToken, idToken, error in
            // AppAuth automatically refreshes the token if needed
            completion(accessToken)
        }
    }
}
```

### Android (Kotlin) — Using AppAuth

```kotlin
// build.gradle
// implementation 'net.openid:appauth:0.11.1'

class KeycloakAuthManager(private val context: Context) {
    private val issuerUri = Uri.parse("https://auth.example.com/realms/my-realm")
    private val clientId = "my-mobile-app"
    private val redirectUri = Uri.parse("com.example.myapp://callback")
    private var authState: AuthState? = null

    fun startLogin(activity: Activity, requestCode: Int) {
        AuthorizationServiceConfiguration.fetchFromIssuer(issuerUri) { config, ex ->
            if (config == null) {
                Log.e("Auth", "Failed to fetch config", ex)
                return@fetchFromIssuer
            }
            authState = AuthState(config)

            val authRequest = AuthorizationRequest.Builder(
                config,
                clientId,
                ResponseTypeValues.CODE,
                redirectUri
            )
                .setScopes("openid", "profile", "email")
                .setCodeVerifier(CodeVerifierUtil.generateRandomCodeVerifier())  // PKCE
                .build()

            val authService = AuthorizationService(context)
            val authIntent = authService.getAuthorizationRequestIntent(authRequest)
            activity.startActivityForResult(authIntent, requestCode)
        }
    }

    fun handleAuthResponse(intent: Intent, callback: (String?) -> Unit) {
        val response = AuthorizationResponse.fromIntent(intent)
        val exception = AuthorizationException.fromIntent(intent)
        authState?.update(response, exception)

        if (response != null) {
            val authService = AuthorizationService(context)
            authService.performTokenRequest(response.createTokenExchangeRequest()) { tokenResponse, tokenEx ->
                authState?.update(tokenResponse, tokenEx)
                callback(tokenResponse?.accessToken)
            }
        }
    }

    fun getAccessToken(callback: (String?) -> Unit) {
        authState?.performActionWithFreshTokens(AuthorizationService(context))
        { accessToken, _, _ ->
            callback(accessToken)
        }
    }
}
```

### React Native — Using react-native-app-auth

```typescript
// auth.ts
import { authorize, refresh, revoke, AuthConfiguration } from 'react-native-app-auth';

const config: AuthConfiguration = {
  issuer: 'https://auth.example.com/realms/my-realm',
  clientId: 'my-mobile-app',
  redirectUrl: 'com.example.myapp://callback',
  scopes: ['openid', 'profile', 'email'],
  usePKCE: true,
  // Android-specific
  dangerouslyAllowInsecureHttpRequests: false,
};

export async function login() {
  try {
    const result = await authorize(config);
    return {
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
      idToken: result.idToken,
      expiresAt: result.accessTokenExpirationDate,
    };
  } catch (error) {
    console.error('Login failed:', error);
    throw error;
  }
}

export async function refreshTokens(refreshToken: string) {
  try {
    const result = await refresh(config, { refreshToken });
    return {
      accessToken: result.accessToken,
      refreshToken: result.refreshToken || refreshToken,
      expiresAt: result.accessTokenExpirationDate,
    };
  } catch (error) {
    console.error('Token refresh failed:', error);
    throw error;
  }
}

export async function logout(tokenToRevoke: string) {
  try {
    await revoke(config, { tokenToRevoke, sendClientId: true });
  } catch (error) {
    console.error('Logout failed:', error);
  }
}
```

### Mobile App Configuration in Keycloak

For mobile apps, configure the client in Keycloak:

```bash
# Create a public client for mobile apps
curl -X POST "$KC_URL/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "my-mobile-app",
    "enabled": true,
    "publicClient": true,
    "directAccessGrantsEnabled": false,
    "standardFlowEnabled": true,
    "redirectUris": [
      "com.example.myapp://callback",
      "com.example.myapp:/callback"
    ],
    "webOrigins": [],
    "attributes": {
      "pkce.code.challenge.method": "S256"
    }
  }'
```

Key settings for mobile clients:

- **Public client**: `true` (no client secret)
- **PKCE**: Enforce `S256`
- **Redirect URIs**: Use custom URL schemes (`com.example.myapp://callback`)
- **Direct Access Grants**: Disabled (no password grant)
- **Consent Required**: Consider enabling for third-party apps
- **Refresh Token**: Enable rotation for security
