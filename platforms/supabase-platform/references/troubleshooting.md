# Supabase Troubleshooting Guide

Dense, solution-oriented reference for diagnosing and fixing common Supabase issues.

## Table of Contents

1. [RLS Blocking Queries](#1-rls-blocking-queries)
2. [Auth Token Issues](#2-auth-token-issues)
3. [Realtime Not Working](#3-realtime-not-working)
4. [Storage Upload Failures](#4-storage-upload-failures)
5. [Edge Function Issues](#5-edge-function-issues)
6. [Migration Conflicts](#6-migration-conflicts)
7. [Type Generation](#7-type-generation)
8. [Connection Pooling / Supavisor](#8-connection-pooling--supavisor)
9. [Rate Limits](#9-rate-limits)
10. [CORS Issues](#10-cors-issues)
11. [PostgREST Query Gotchas](#11-postgrest-query-gotchas)

---

## 1. RLS Blocking Queries

**Symptom:** `.from('table').select('*')` returns `{ data: [], error: null }` despite rows existing.
**Cause:** RLS is enabled but no SELECT policy grants access. PostgREST silently filters rows — no error is thrown.
**Fix:**
1. Verify RLS status: `SELECT relname, relrowsecurity FROM pg_class WHERE relname = 'your_table';`
2. List policies: `SELECT * FROM pg_policies WHERE tablename = 'your_table';`
3. Add the missing policy:
```sql
CREATE POLICY "Users read own rows" ON your_table
  FOR SELECT USING (auth.uid() = user_id);
```

**Symptom:** `new row violates row-level security policy for table "X"`.
**Cause:** Missing INSERT or UPDATE policy, or the WITH CHECK clause rejects the row being written. The user may pass the SELECT check but fail on INSERT/UPDATE.
**Fix:**
```sql
-- Check existing INSERT policies
SELECT * FROM pg_policies WHERE tablename = 'your_table' AND cmd = 'INSERT';
-- Add the policy
CREATE POLICY "Users insert own rows" ON your_table
  FOR INSERT WITH CHECK (auth.uid() = user_id);
```

**Symptom:** Data exposed publicly — anyone with the anon key reads everything.
**Cause:** Tables don't have RLS enabled by default. Creating a table via SQL or Dashboard doesn't protect it.
**Fix:**
```sql
ALTER TABLE your_table ENABLE ROW LEVEL SECURITY;
ALTER TABLE your_table FORCE ROW LEVEL SECURITY;  -- also enforce for table owner
```

**Symptom:** Policies seem correct but still don't work.
**Cause:** The SQL Editor bypasses RLS (runs as `postgres`). Policies relying on `auth.uid()` return NULL there. Policy may also reference wrong column names or misread JWT structure.
**Debug:** Create an RPC to inspect auth context from the client SDK:
```sql
CREATE OR REPLACE FUNCTION debug_auth() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object('uid', auth.uid(), 'role', auth.role(), 'jwt', auth.jwt());
$$;
```
Call via client: `supabase.rpc('debug_auth')`. Always test RLS through the client SDK, never the SQL Editor. To test in raw SQL, simulate a user:
```sql
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"<user-uuid>","role":"authenticated"}';
SELECT * FROM your_table;  -- now subject to RLS
RESET ROLE;
```

**Prevention:** Enable RLS immediately after table creation. Write policies for all four operations (SELECT, INSERT, UPDATE, DELETE). Test from a real client, not the SQL Editor.

---

## 2. Auth Token Issues

**Symptom:** `{ message: "JWT expired", status: 401 }`
**Cause:** Access token expired (default lifetime: 3600s / 1 hour) and the client didn't refresh it.
**Fix:**
- Ensure `supabase.auth.onAuthStateChange()` is registered early in the app — auto-refresh depends on this listener being active before any API calls.
- Check system clock on client/server — clock skew causes premature expiry.
```typescript
// Register at app root, before any data fetching
const { data: { subscription } } = supabase.auth.onAuthStateChange((event, session) => {
  // Handle TOKEN_REFRESHED, SIGNED_IN, SIGNED_OUT
});
return () => subscription.unsubscribe(); // only on full unmount
```

**Symptom:** Token not auto-refreshing; user gets logged out unexpectedly.
**Cause:** `onAuthStateChange` listener wasn't set up, was torn down prematurely, or the refresh token itself expired (default: 1 week, configurable in Dashboard → Auth → Token Expiry).
**Fix:** Register the listener at app root and only unsubscribe on full app unmount. If refresh tokens expire, the user must re-authenticate.

**Symptom:** `invalid JWT: unable to parse or verify signature`
**Cause:** Wrong key used for verification. Common confusions: anon key vs service_role key vs JWT secret. Or the JWT was signed with a different project's secret.
**Fix:** Verify you're using the correct key from Dashboard → Settings → API. The JWT secret is different from both API keys.

**Symptom:** Missing auth header — API returns 401 on custom fetch calls.
**Cause:** Custom fetch calls don't automatically include the Supabase session token.
**Fix:**
```typescript
const { data: { session } } = await supabase.auth.getSession();
fetch(url, {
  headers: {
    'Authorization': `Bearer ${session?.access_token}`,
    'apikey': SUPABASE_ANON_KEY,
  },
});
```

**`getSession()` vs `getUser()` — critical distinction:**
- `getSession()`: reads from local storage. Fast, no network call, but **can return stale or tampered data**. Use for client-side UI rendering.
- `getUser()`: validates token against the Supabase Auth server. Slower, requires network, but **trustworthy**. Use on the server and for security-sensitive checks.
- **Rule:** Server-side / middleware → always `getUser()`. Client-side display → `getSession()` is fine.

**Symptom:** PKCE flow errors — `invalid_grant` after OAuth redirect.
**Cause:** PKCE (default for SSR) requires the code verifier from the initial request to be available when exchanging the code. It's stored in cookies.
**Fix:** Ensure your callback route calls `supabase.auth.exchangeCodeForSession(code)`. Verify cookies: check `SameSite`, `Secure`, domain settings. If using middleware, ensure it doesn't strip auth cookies.

**Symptom:** Auth state lost on page refresh.
**Cause:** Storage mechanism unavailable (SSR without cookie adapter), localStorage cleared, or `persistSession: false`.
**Fix:** For SSR frameworks (Next.js, SvelteKit, Nuxt), use `@supabase/ssr` with cookie-based storage. Check browser DevTools → Application → Local Storage for `sb-<ref>-auth-token`.

**Symptom:** Custom claims not appearing in JWT.
**Cause:** Adding columns to `auth.users` doesn't modify the JWT payload. Claims must be injected via a hook.
**Fix:** Configure an access token hook in Dashboard → Auth → Hooks:
```sql
CREATE OR REPLACE FUNCTION custom_access_token_hook(event jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE claims jsonb; user_role text;
BEGIN
  SELECT role INTO user_role FROM public.profiles WHERE id = (event->>'user_id')::uuid;
  claims := jsonb_set(event->'claims', '{user_role}', to_jsonb(user_role));
  RETURN jsonb_set(event, '{claims}', claims);
END; $$;
```

---

## 3. Realtime Not Working

**Symptom:** Subscription callback never fires. No errors, no events.
**Cause:** The table is not enabled for Realtime. Tables do NOT publish to Realtime by default.
**Fix:**
```sql
ALTER PUBLICATION supabase_realtime ADD TABLE your_table;
```
Or enable via Dashboard → Database → Replication → toggle the table on.

**Symptom:** Channel joins successfully but authenticated user receives no `postgres_changes` events.
**Cause:** RLS applies to Realtime subscriptions. The user must have a SELECT policy covering the rows being changed. If the policy is `auth.uid() = user_id`, the user only sees their own row changes.
**Fix:** Ensure the user's SELECT policy covers the rows. Debug by running the equivalent SELECT query via the client SDK — if it returns no rows, Realtime won't send events either.

**Symptom:** `WebSocket connection to 'wss://...' failed` or `Channel join timed out`.
**Cause:** Network instability, proxy/firewall blocking WebSocket upgrades, or concurrent connection limit exceeded (free: 200, Pro: 500).
**Fix:**
- Check connection count in Dashboard → Realtime → Inspector.
- If behind a corporate proxy, ensure WebSocket upgrade headers (`Connection: Upgrade`, `Upgrade: websocket`) are allowed.
- The client auto-reconnects, but verify system events are handled.

**Symptom:** `Too many channels` or new subscriptions silently fail.
**Cause:** Each client can join up to 100 channels. Each unique filter combination (table + event + filter) is a separate channel.
**Fix:** Consolidate subscriptions — listen to broader filters and route in callback. Remove channels when done: `supabase.removeChannel(channel)`. Always unsubscribe on component unmount.

**Debug template:**
```typescript
const channel = supabase.channel('debug')
  .on('postgres_changes', { event: '*', schema: 'public', table: 'messages' },
    (payload) => console.log('Change:', payload))
  .on('system', {}, (payload) => console.log('System:', payload))
  .subscribe((status) => console.log('Status:', status));
```

---

## 4. Storage Upload Failures

**`Payload too large` (413):** File exceeds bucket size limit (free: 50MB, Pro: up to 5GB). Configure in Dashboard → Storage → bucket → Settings.

**`invalid_mime_type` (422):** Bucket restricts MIME types. Update allowed types in bucket settings.

**`new row violates row-level security policy` (403):** Storage uses RLS on `storage.objects`.
```sql
CREATE POLICY "Users upload to own folder" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]);
```

**Public URL returns 400:** Bucket isn't public. `getPublicUrl()` generates a URL regardless but it won't resolve. Toggle in Dashboard or use `createSignedUrl()` for private buckets.

**CORS errors on upload:** Typically occurs with custom domains. Ensure your origin is in Storage CORS config. The default config allows `*`.

**Signed URL expired (400):** Regenerate with longer TTL: `createSignedUrl('path', 3600)` (seconds).

---

## 5. Edge Function Issues

**Cold start latency (2–5s):** Deno Deploy spins down idle functions. Keep bundles small. Ping with a cron if latency is critical.

**`Module not found` / import errors:** Deno doesn't support bare specifiers. Use URL imports or an import map:
```typescript
// Use URL imports
import { z } from 'https://esm.sh/zod@3.22.0';
// Or configure import_map.json and reference in supabase/config.toml
```

**Env vars undefined:** Secrets must be set with `supabase secrets set MY_VAR=value` — `.env` files only work locally. For local dev, create `supabase/.env.local`.

**CORS preflight failure:** Edge Functions must explicitly handle OPTIONS:
```typescript
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders });
  return new Response(JSON.stringify(data), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});
```

**`Body already consumed`:** `req.json()` / `req.text()` can only be called once. Read to a variable first: `const body = await req.text(); const parsed = JSON.parse(body);`

**Timeout (60s default):** Optimize logic, offload to database functions, or use `EdgeRuntime.waitUntil()` for fire-and-forget work.

**Debug:** `supabase functions logs my-function --scroll` or `supabase functions serve my-function --env-file supabase/.env.local` for local dev.

---

## 6. Migration Conflicts

**`relation "X" already exists` on push:** Remote schema was modified outside migrations (drift). Pull current state: `supabase db pull`. Or repair: `supabase migration repair --status applied <version>`.

**Team migration conflicts:** Two devs created migrations with different timestamps referencing each other's objects.
**Fix:** Pull latest migrations from VCS first. If conflicts exist:
```bash
supabase migration squash          # Combine into one
supabase db diff -f combined_fix   # Or generate fresh diff
```

**`supabase db reset` fails (`database is being accessed`):** Stop services first: `supabase stop && supabase start`, then `supabase db reset`.

**Remote schema drift:** Changes via Dashboard SQL Editor don't create migration files.
**Fix:** `supabase db diff -f fix_drift --linked` to capture drift as a migration, then `supabase db push`.

**Prevention:** Never modify remote schema directly. Run `supabase db diff` before creating new migrations. Coordinate migration creation across the team.

---

## 7. Type Generation

**Types stale after schema change:** Regenerate:
```bash
supabase gen types typescript --linked > src/types/database.types.ts  # from remote
supabase gen types typescript --local > src/types/database.types.ts   # from local
```
Add as a script in `package.json` for convenience.

**`gen types` connection errors:** Ensure project is linked (`supabase link --project-ref <ref>`) or local is running (`supabase start`).

**Nullable confusion:** Columns without `NOT NULL` are typed as `T | null`. Use generated helper types:
```typescript
type Row = Database['public']['Tables']['profiles']['Row'];       // read shape
type Insert = Database['public']['Tables']['profiles']['Insert'];  // write shape (defaults optional)
type Update = Database['public']['Tables']['profiles']['Update'];  // all optional
```

**RPC types wrong or `unknown`:** Functions must be in the `public` schema. Use explicit return types (`RETURNS TABLE(...)`) instead of `RETURNS record`. Regenerate after changing signatures.

---

## 8. Connection Pooling / Supavisor

**`too many connections for role "postgres"`:** Direct connections exhaust PostgreSQL slots (free: 60, Pro: 200+). Serverless functions are the usual culprit.
**Fix:** Use the pooled connection string (port 6543) for app code. Use direct (port 5432) only for migrations.

| Use Case | Connection | Port |
|---|---|---|
| App queries / Serverless | Pooled (Supavisor) | 6543 |
| Migrations / psql | Direct | 5432 |

**`prepared statement does not exist`:** Transaction-mode pooling (Supavisor default) doesn't support prepared statements.
**Fix:** Add `?pgbouncer=true` to the connection string. For Prisma, set `directUrl` for migrations separately.

**IPv4/IPv6 issues:** Supabase resolves to IPv6 by default. Some environments only support IPv4. Use the connection pooler (supports IPv4) or enable the IPv4 add-on in Dashboard → Settings → Database.

---

## 9. Rate Limits

**Symptom:** `{ message: "Rate limit exceeded", statusCode: 429 }` from PostgREST API.
**Cause:** Free tier: 500 requests/second, Pro: 1000 req/s. These limits apply to all PostgREST API calls combined.
**Fix:**
- Batch operations: use `.upsert()` with arrays instead of individual inserts in loops.
- Cache frequently-read data client-side.
- Use database functions (RPC) to consolidate multiple queries into one call.
- For read-heavy workloads, consider adding a caching layer (e.g., Redis, Vercel KV).

**Symptom:** Auth emails not arriving, or `Email rate limit exceeded`.
**Cause:** Default Supabase email limits: 2 emails/hour per user, 4 emails/hour project-wide on free tier.
**Fix:** Configure a custom SMTP provider (Resend, SendGrid, Postmark) in Dashboard → Auth → SMTP Settings. This bypasses Supabase email rate limits. Always use custom SMTP in production. Implement client-side debouncing on "resend" buttons.

**Symptom:** Realtime subscriptions stop working or new connections rejected.
**Cause:** Free: 200 concurrent connections, 2M messages/month. Pro: 500 connections, 5M messages/month.
**Fix:** Monitor in Dashboard → Realtime. Unsubscribe on component unmount. Use broadcast for ephemeral messages (lower overhead than postgres_changes). Pool connections — one subscription per table, not per component.

**Checking current limits:** Dashboard → Settings → API → Rate Limiting. Use `supabase inspect db` commands to monitor connection and query stats locally.

---

## 10. CORS Issues

**Preflight blocked:** `Response to preflight request doesn't pass access control check`.
**Cause:** Server (usually Edge Function) doesn't handle OPTIONS or return CORS headers.
**Fix template:**
```typescript
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
};
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders });
  // Include corsHeaders in all responses, including errors
  return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
});
```

**Custom domain CORS:** Update `Access-Control-Allow-Origin` to match the new domain. For multiple origins:
```typescript
const origin = req.headers.get('origin') || '';
const allowed = ['https://myapp.com', 'https://www.myapp.com'];
const corsOrigin = allowed.includes(origin) ? origin : allowed[0];
```

**Storage CORS:** Separate from PostgREST/Edge Function CORS. The client SDK handles it by default. Custom CDN setups must pass through CORS headers.

---

## 11. PostgREST Query Gotchas

**Symptom:** `Could not find a relationship between 'X' and 'Y' in the schema cache`.
**Cause:** PostgREST infers joins from foreign keys. Fails when: no FK exists, FK is in a non-public schema, or there are multiple FKs to the same table (ambiguous).
**Fix:** Disambiguate with the `!hint` syntax:
```typescript
// Two FKs from messages to profiles — specify which to use
const { data } = await supabase.from('messages')
  .select('*, sender:profiles!sender_id(*), receiver:profiles!receiver_id(*)');
```
If no FK exists, create one or use an RPC function for the join.

**Symptom:** `column reference "id" is ambiguous`.
**Cause:** Filtering with `.eq('id', value)` when both parent and joined table have an `id` column.
**Fix:** Qualify the column with the table name:
```typescript
.eq('orders.id', orderId)          // filter on parent table
.eq('products.category', 'books')  // filter on joined table (use !inner for the join)
```

**Symptom:** `count()` returns null or the response includes all rows.
**Cause:** `count` must be specified in the select options, not as a column name.
**Fix:**
```typescript
// Wrong — tries to select a column called "count"
const { data } = await supabase.from('posts').select('count');

// Right — returns only the count
const { count } = await supabase.from('posts').select('*', { count: 'exact', head: true });
// 'exact': slow, accurate. 'planned': fast, approximate. 'estimated': balanced.
```

**Symptom:** Confused by empty arrays vs null in nested selects.
**Explanation:** One-to-many returns `[]` when no related rows exist. Many-to-one returns `null` when the FK column is null. This is intentional PostgREST behavior, not a bug.

**Symptom:** Text search returns no results or syntax errors.
**Cause:** PostgREST text search uses PostgreSQL's `to_tsquery` syntax, not simple substring matching.
**Fix:**
```typescript
// Full-text search (requires a tsvector column or GIN index)
.textSearch('title', 'hello & world', { type: 'websearch' })

// For simple pattern matching, use ilike
.ilike('title', '%hello%')
```

**Symptom:** Cannot order parent table by a column from a joined (embedded) table.
**Cause:** PostgREST does not support `ORDER BY` on embedded resource columns.
**Fix:** Use a database view or function that flattens the data. Or create a computed column:
```sql
CREATE FUNCTION post_comment_count(posts) RETURNS bigint AS $$
  SELECT count(*) FROM comments WHERE post_id = $1.id;
$$ LANGUAGE sql STABLE;
-- Query: .select('*, comment_count:post_comment_count').order('comment_count', { ascending: false })
```

**Symptom:** Embedded resources are nested but you want them flat.
**Fix:** Use the spread `...` operator (requires one-to-one or many-to-one relationship):
```typescript
// Nested (default): { id: 1, profile: { name: 'Alice' } }
.select('id, profile:profiles(name)')

// Flat with spread: { id: 1, name: 'Alice' }
.select('id, ...profiles(name)')
```

**Prevention:** Define explicit foreign keys — PostgREST relies on them for all joins. Use `!inner` when you want INNER JOIN behavior (exclude parent rows with no match). Test complex queries in the SQL Editor first, then translate to client SDK. Use `explain: true` (client v2.39+) to inspect generated SQL.
