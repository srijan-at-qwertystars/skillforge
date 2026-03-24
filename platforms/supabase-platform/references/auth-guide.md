# Supabase Auth Deep-Dive Reference

> Dense, practical reference for implementing Supabase Auth correctly.

---

## Table of Contents

1. [Auth Architecture](#1-auth-architecture)
2. [Email/Password Flow](#2-emailpassword-flow)
3. [OAuth Providers](#3-oauth-providers)
4. [Magic Links](#4-magic-links)
5. [Phone Auth](#5-phone-auth)
6. [MFA/TOTP](#6-mfatotp)
7. [Custom Claims & JWT Hooks](#7-custom-claims--jwt-hooks)
8. [Auth Hooks](#8-auth-hooks)
9. [Session Management](#9-session-management)
10. [Server-Side Auth (SSR)](#10-server-side-auth-ssr)
11. [Auth in React/Next.js](#11-auth-in-reactnextjs)
12. [Auth Middleware Patterns](#12-auth-middleware-patterns)
13. [Custom Auth UI](#13-custom-auth-ui)
14. [Security Best Practices](#14-security-best-practices)

---

## 1. Auth Architecture

Supabase Auth is powered by **GoTrue**, an open-source JWT-based auth server. All user data lives in the `auth` schema (`auth.users`, `auth.identities`, `auth.sessions`, `auth.refresh_tokens`, `auth.mfa_factors`, `auth.flow_state`).

### JWT Structure

On login, GoTrue issues an **access token** (short-lived JWT, default 3600s) and a **refresh token** (long-lived, for obtaining new access tokens). Key access token fields: `sub` (user UUID = `auth.uid()`), `role`, `email`, `app_metadata`, `aal`.

### How PostgREST Uses the JWT

PostgREST validates the JWT, sets role to `authenticated`, and exposes `auth.uid()` / `auth.jwt()` in RLS:

```sql
CREATE POLICY "Users see own data" ON profiles
  FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Admins only" ON admin_table
  FOR ALL USING ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');
```

### Token Lifecycle

1. User authenticates → access + refresh tokens issued, stored in `localStorage`
2. `supabase-js` auto-refreshes at ~80% of token lifetime
3. Refresh token rotation: each refresh invalidates old token, issues new pair
4. Expired/revoked refresh token → re-authentication required

---

## 2. Email/Password Flow

### Sign Up & Sign In

```typescript
const { data, error } = await supabase.auth.signUp({
  email: 'user@example.com',
  password: 'securePassword123!',
  options: {
    data: { full_name: 'Ada Lovelace' },  // → user_metadata
    emailRedirectTo: 'https://myapp.com/auth/callback',
  },
});
// data.session is null until email confirmed (default)

const { data, error } = await supabase.auth.signInWithPassword({
  email: 'user@example.com', password: 'securePassword123!',
});
```

### Password Reset

```typescript
// Step 1: Send reset email
await supabase.auth.resetPasswordForEmail('user@example.com', {
  redirectTo: 'https://myapp.com/auth/reset-password',
});
// Step 2: After redirect (PASSWORD_RECOVERY event fires)
await supabase.auth.updateUser({ password: 'newPassword456!' });
```

### Email Change & Templates

- `await supabase.auth.updateUser({ email: 'new@example.com' })` — confirms via both old and new email
- Email templates: Dashboard → Auth → Email Templates (vars: `{{ .ConfirmationURL }}`, `{{ .Token }}`, `{{ .TokenHash }}`)

---

## 3. OAuth Providers

### Setup Pattern

1. Create OAuth credentials with provider. Redirect URI: `https://<project-ref>.supabase.co/auth/v1/callback`
2. Add provider in Dashboard → Auth → Providers
3. Trigger sign-in:

```typescript
await supabase.auth.signInWithOAuth({
  provider: 'google',
  options: {
    redirectTo: 'https://myapp.com/auth/callback',
    scopes: 'openid email profile',
    queryParams: { access_type: 'offline', prompt: 'consent' },
  },
});
```

### Provider Notes

| Provider | Scopes | Gotchas |
|---|---|---|
| **Google** | `openid email profile` | Must enable consent screen. `hd` restricts domain |
| **GitHub** | `read:user user:email` | Email may be private. No refresh tokens |
| **Discord** | `identify email` | Email not always verified |
| **Apple** | `name email` | Name only sent on first auth |
| **Azure AD** | `openid email profile` | Set `azure_tenant` in config |

### OAuth Callback (Next.js)

In `app/auth/callback/route.ts`, extract `code` from search params, call `supabase.auth.exchangeCodeForSession(code)`, redirect on success. See Section 11 for full example.

### Linking & PKCE

- Auto-links accounts with same verified email
- Manual: `supabase.auth.linkIdentity({ provider: 'github' })` / `unlinkIdentity(identity)`
- **PKCE** is default in `@supabase/ssr` — handled automatically

---

## 4. Magic Links

```typescript
await supabase.auth.signInWithOtp({
  email: 'user@example.com',
  options: { emailRedirectTo: '...', shouldCreateUser: true },
});
```

- GoTrue generates single-use token → user clicks email link → session created
- Tokens expire in 24h (configurable)
- For SSR, verify via `supabase.auth.verifyOtp({ token_hash, type })` in callback route
- **Rate limit:** 30 emails/hour/address

---

## 5. Phone Auth

```typescript
// Send OTP (E.164 format required)
await supabase.auth.signInWithOtp({ phone: '+15551234567' });

// Verify OTP
const { data } = await supabase.auth.verifyOtp({
  phone: '+15551234567', token: '123456', type: 'sms',
});
```

SMS providers (Dashboard → Auth → Phone Provider): **Twilio**, **MessageBird**, **Vonage**. Phone+password signup also supported via `signUp({ phone, password })`.

---

## 6. MFA/TOTP

### Enrollment

```typescript
// Step 1: Enroll — get QR code
const { data } = await supabase.auth.mfa.enroll({
  factorType: 'totp', friendlyName: 'Authenticator App',
});
// data.id (factor ID), data.totp.qr_code (data URI)

// Step 2: Challenge + verify
const { data: ch } = await supabase.auth.mfa.challenge({ factorId: data.id });
await supabase.auth.mfa.verify({
  factorId: data.id, challengeId: ch.id, code: '123456',
});
// Session upgraded to aal2
```

### Assurance Levels

- **aal1** — single-factor | **aal2** — multi-factor (aal1 + TOTP)
- Check: `supabase.auth.mfa.getAuthenticatorAssuranceLevel()` → `{ currentLevel, nextLevel }`
- Enforce in RLS: `(auth.jwt() ->> 'aal') = 'aal2'`
- Manage: `mfa.listFactors()`, `mfa.unenroll({ factorId })`

---

## 7. Custom Claims & JWT Hooks

### app_metadata vs user_metadata

| Field | Writeable By | Use |
|---|---|---|
| `user_metadata` | User (`updateUser()`) | Display name, avatar |
| `app_metadata` | Server only | Roles, permissions |

Both in JWT. **Never trust `user_metadata` for authorization.**

### Custom Claims Hook

```sql
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE claims JSONB; user_role TEXT;
BEGIN
  SELECT role INTO user_role FROM public.user_roles
    WHERE user_id = (event->>'user_id')::UUID;
  claims := jsonb_set(event->'claims', '{user_role}',
    to_jsonb(COALESCE(user_role, 'user')));
  RETURN jsonb_set(event, '{claims}', claims);
END; $$;

GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook FROM authenticated, anon, public;
GRANT SELECT ON public.user_roles TO supabase_auth_admin;
```

Register in Dashboard → Auth → Hooks. Use in RLS: `(auth.jwt() -> 'user_role')::TEXT = '"admin"'`

**Claims only update on JWT refresh** — call `supabase.auth.refreshSession()` after role changes.

---

## 8. Auth Hooks

| Hook | Trigger | Use Case |
|---|---|---|
| **Custom Access Token** | Before JWT issued | Custom claims, roles |
| **MFA Verification** | On MFA check | Custom validation |
| **Password Verification** | On password check | Breach checking |
| **Send SMS** | SMS OTP triggered | Custom SMS provider |
| **Send Email** | Auth email triggered | Custom email (Resend, SendGrid) |

All hooks: receive JSONB `event`, return JSONB. Example:

```sql
CREATE OR REPLACE FUNCTION public.custom_send_email(event JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  PERFORM net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.resend_api_key'),
      'Content-Type', 'application/json'),
    body := jsonb_build_object('from', 'noreply@myapp.com', 'to', event->'user'->>'email',
      'subject', 'Your login link',
      'html', '<a href="' || (event->'email_data'->>'confirmation_url') || '">Log in</a>'));
  RETURN jsonb_build_object('success', true);
END; $$;
```

---

## 9. Session Management

### Configuration

```typescript
const supabase = createClient(url, anonKey, {
  auth: { autoRefreshToken: true, persistSession: true, detectSessionInUrl: true },
});
// For React Native: add storage option with getItem/setItem/removeItem
```

### Auth State Events

Listen via `onAuthStateChange`: `SIGNED_IN`, `SIGNED_OUT`, `TOKEN_REFRESHED`, `USER_UPDATED`, `PASSWORD_RECOVERY`, `MFA_CHALLENGE_VERIFIED`, `INITIAL_SESSION`. Call `subscription.unsubscribe()` on unmount.

### Sign Out

```typescript
await supabase.auth.signOut();                      // current device
await supabase.auth.signOut({ scope: 'global' });   // all devices
```

---

## 10. Server-Side Auth (SSR)

SSR requires **cookies** (not localStorage). Install `@supabase/ssr`.

### Browser Client

`createBrowserClient(url, anonKey)` — used in client components.

### Server Client

```typescript
import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';

export async function createClient() {
  const cookieStore = await cookies();
  return createServerClient(url, anonKey, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll: (cs) => {
        try { cs.forEach(({ name, value, options }) => cookieStore.set(name, value, options)); }
        catch { /* read-only in Server Components — middleware handles refresh */ }
      },
    },
  });
}
```

**Always `getUser()` on server** — validates with GoTrue. `getSession()` reads cookies only (stale/tampered risk).

### Middleware (Token Refresh + Route Protection)

```typescript
// middleware.ts
export async function middleware(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });
  const supabase = createServerClient(url, anonKey, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (cs) => {
        cs.forEach(({ name, value }) => request.cookies.set(name, value));
        supabaseResponse = NextResponse.next({ request });
        cs.forEach(({ name, value, options }) => supabaseResponse.cookies.set(name, value, options));
      },
    },
  });
  // getUser() triggers token refresh
  const { data: { user } } = await supabase.auth.getUser();
  if (!user && request.nextUrl.pathname.startsWith('/dashboard'))
    return NextResponse.redirect(new URL('/login', request.url));
  return supabaseResponse;
}
export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg)$).*)'],
};
```

---

## 11. Auth in React/Next.js

### Auth Context Provider

```typescript
'use client';
const AuthContext = createContext<{ user: User | null; session: Session | null; loading: boolean }>(
  { user: null, session: null, loading: true });

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const supabase = createClient();
  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => { setSession(session); setLoading(false); });
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (_ev, session) => { setSession(session); setLoading(false); });
    return () => subscription.unsubscribe();
  }, []);
  return (<AuthContext.Provider value={{ user: session?.user ?? null, session, loading }}>
    {children}</AuthContext.Provider>);
}
export const useAuth = () => useContext(AuthContext);
```

### Server Component Auth & Callback

```typescript
// app/dashboard/page.tsx — server component
const supabase = await createClient();
const { data: { user } } = await supabase.auth.getUser();
if (!user) redirect('/login');
const { data: projects } = await supabase.from('projects').select('*'); // RLS scopes to user

// app/auth/callback/route.ts — handles OAuth, magic link, email confirm
export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get('code');
  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(`${origin}${searchParams.get('next') ?? '/dashboard'}`);
  }
  return NextResponse.redirect(`${origin}/auth/error`);
}
```

---

## 12. Auth Middleware Patterns

### Role-Based Access & Redirects

```typescript
const { data: { user } } = await supabase.auth.getUser();
const publicRoutes = ['/login', '/signup', '/auth/callback', '/'];
if (publicRoutes.includes(pathname)) return supabaseResponse;
if (!user) {
  const url = new URL('/login', request.url);
  url.searchParams.set('redirectTo', pathname);
  return NextResponse.redirect(url);
}
if (user && pathname === '/login')
  return NextResponse.redirect(new URL('/dashboard', request.url));
if (pathname.startsWith('/admin') && user.app_metadata?.role !== 'admin')
  return NextResponse.redirect(new URL('/unauthorized', request.url));
```

---

## 13. Custom Auth UI

### Login Form

```typescript
'use client';
export function LoginForm() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const supabase = createClient();
  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault(); setError(null); setLoading(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) setError(error.message); // "Invalid login credentials" | "Email not confirmed"
    setLoading(false);
  };
  const handleOAuth = (provider: 'google' | 'github') =>
    supabase.auth.signInWithOAuth({ provider, options: { redirectTo: `${location.origin}/auth/callback` } });
  return (
    <form onSubmit={handleLogin}>
      <input type="email" value={email} onChange={e => setEmail(e.target.value)} required />
      <input type="password" value={password} onChange={e => setPassword(e.target.value)} required />
      {error && <p className="text-red-500">{error}</p>}
      <button type="submit" disabled={loading}>{loading ? 'Signing in...' : 'Sign in'}</button>
      <button type="button" onClick={() => handleOAuth('google')}>Google</button>
    </form>
  );
}
```

### Signup with Email Verification

```typescript
const { data, error } = await supabase.auth.signUp({ email, password });
if (data.user && !data.session) {
  // Show "check your email" UI
  // Resend: supabase.auth.resend({ type: 'signup', email })
}
```

---

## 14. Security Best Practices

### PKCE vs Implicit

**Always use PKCE for SSR** (default in `@supabase/ssr`). Tokens exchanged server-side, never in URL. Implicit (fragment-based) is default for SPAs via `createClient`.

### Redirect URL Allowlisting

Dashboard → Auth → URL Configuration. Supabase rejects unlisted redirects.
```
https://myapp.com/**
http://localhost:3000/**
https://preview-*.vercel.app/**
```

### Rate Limits

Sign up/in: 30/hour/IP | Token refresh: 360/hour/IP | OTP/magic link/reset: 30/hour/email

### Service Role Key & Session Invalidation

The `service_role` key bypasses RLS — **never expose to client** (no `NEXT_PUBLIC_` prefix):

```typescript
const supabaseAdmin = createClient(
  process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { auth: { autoRefreshToken: false, persistSession: false } }
);
await supabaseAdmin.auth.admin.deleteUser(userId);
await supabaseAdmin.auth.admin.updateUserById(userId, { app_metadata: { role: 'admin' } });
// Invalidate sessions: supabaseAdmin.auth.admin.signOut(userId, 'global')
```

### Security Checklist

- [ ] PKCE flow for SSR apps
- [ ] Redirect URLs allowlisted
- [ ] Service role key server-side only
- [ ] Email confirmation enabled in production
- [ ] `getUser()` for server-side auth (not `getSession()`)
- [ ] RLS uses `auth.uid()`, not client-supplied IDs
- [ ] Authorization via `app_metadata` (not `user_metadata`)
- [ ] Global sign-out for security events
- [ ] Rate limiting configured
- [ ] Cookies: `httpOnly`, `secure`, `sameSite: 'lax'`
