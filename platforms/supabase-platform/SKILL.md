---
name: supabase-platform
description: >
  Use when working with Supabase projects, Supabase Auth (email, OAuth, magic links, MFA),
  Supabase Row Level Security (RLS), Supabase Realtime subscriptions (broadcast, presence,
  postgres changes), Supabase Edge Functions (Deno), Supabase Storage (buckets, policies),
  PostgREST API queries, Supabase CLI, supabase-js client, database migrations, or type
  generation. Also use for self-hosting Supabase or configuring Supabase infrastructure.
  Do NOT use for Firebase, AWS Amplify, raw PostgreSQL without Supabase context, general
  SQL questions unrelated to Supabase, or other BaaS platforms like Appwrite or Parse.
---

# Supabase Platform Patterns

## Architecture Overview

Supabase wraps PostgreSQL with these services:
- **PostgREST** — auto-generated REST API from your schema
- **GoTrue** — auth service issuing JWTs, stored in `auth.users`
- **Realtime** — Elixir service using PostgreSQL logical replication + WebSockets
- **Storage** — S3-compatible file storage with metadata in Postgres
- **Edge Functions** — Deno-based serverless functions
- **Kong/API Gateway** — unified entry point routing to all services

All services share JWT-based auth. RLS policies in PostgreSQL enforce security at the database layer.

## Project Setup

### Install CLI and initialize:
```bash
npm install -g supabase
supabase init
supabase start          # starts local Postgres, Studio, API, Auth, etc.
supabase status         # shows local URLs and keys
```

### Install client SDK:
```bash
npm install @supabase/supabase-js
```

## Client Initialization

### Browser/SSR client (TypeScript):
```typescript
import { createClient } from '@supabase/supabase-js'
import type { Database } from './supabase.types'

const supabase = createClient<Database>(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
)
```

### Server-side admin client (bypasses RLS):
```typescript
const supabaseAdmin = createClient<Database>(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { auth: { autoRefreshToken: false, persistSession: false } }
)
```

Never expose the service role key to the client. Use `anon` key for browser/mobile.

## Authentication

### Email/password signup:
```typescript
const { data, error } = await supabase.auth.signUp({
  email: 'user@example.com',
  password: 'secure-password',
})
```

### Magic link (passwordless):
```typescript
const { data, error } = await supabase.auth.signInWithOtp({
  email: 'user@example.com',
  options: {
    emailRedirectTo: 'https://yourapp.com/auth/callback',
    shouldCreateUser: true,
  },
})
```

### OAuth:
```typescript
const { data, error } = await supabase.auth.signInWithOAuth({
  provider: 'google',
  options: { redirectTo: `${window.location.origin}/auth/callback` },
})
```

### Listen to auth state changes:
```typescript
const { data: { subscription } } = supabase.auth.onAuthStateChange(
  (event, session) => {
    // event: 'SIGNED_IN' | 'SIGNED_OUT' | 'TOKEN_REFRESHED' | etc.
  }
)
// Cleanup: subscription.unsubscribe()
```

### Server-side session verification (e.g., Next.js API route):
```typescript
const { data: { user }, error } = await supabase.auth.getUser(jwt)
```

Always use `getUser()` for server-side verification — it validates the JWT against GoTrue. Never trust `getSession()` alone on the server.

### Auth best practices:
- Configure allowed redirect URLs in dashboard to prevent phishing
- Use custom SMTP in production for email deliverability
- Implement proper session refresh handling in SPAs

## Row Level Security (RLS)

### Enable RLS on every table exposed via the API:
```sql
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;
```

### Basic ownership policy:
```sql
-- Users read own rows
CREATE POLICY "Users read own posts" ON public.posts
  FOR SELECT USING (user_id = auth.uid());

-- Users insert own rows
CREATE POLICY "Users create own posts" ON public.posts
  FOR INSERT WITH CHECK (user_id = auth.uid());

-- Users update own rows
CREATE POLICY "Users update own posts" ON public.posts
  FOR UPDATE USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Users delete own rows
CREATE POLICY "Users delete own posts" ON public.posts
  FOR DELETE USING (user_id = auth.uid());
```

### Multi-tenant / org-based policy:
```sql
CREATE FUNCTION auth.user_org_id() RETURNS uuid AS $$
  SELECT org_id FROM public.profiles WHERE id = auth.uid()
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE POLICY "Org isolation" ON public.projects
  FOR ALL USING (org_id = auth.user_org_id());
```

### Role-based access:
```sql
CREATE POLICY "Admins can do anything" ON public.posts
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );
```

### RLS critical rules:
- Enable RLS on ALL tables in the `public` schema
- Index columns referenced in policies (`user_id`, `org_id`)
- Write separate policies per operation (SELECT, INSERT, UPDATE, DELETE)
- Test from client SDK, not SQL editor (SQL editor bypasses RLS)

## Database Queries via PostgREST

### Select with filters:
```typescript
const { data, error } = await supabase
  .from('posts')
  .select('id, title, author:profiles(name)')
  .eq('status', 'published')
  .order('created_at', { ascending: false })
  .limit(10)
// Returns: { data: [{ id, title, author: { name } }], error: null }
```

### Insert:
```typescript
const { data, error } = await supabase
  .from('posts')
  .insert({ title: 'Hello', user_id: userId })
  .select()
  .single()
```

### Upsert:
```typescript
const { data, error } = await supabase
  .from('profiles')
  .upsert({ id: userId, name: 'Updated Name' }, { onConflict: 'id' })
  .select()
  .single()
```

### RPC (call database functions):
```typescript
const { data, error } = await supabase.rpc('search_posts', {
  query_text: 'supabase',
  match_count: 10,
})
```

### Pagination pattern:
```typescript
const PAGE_SIZE = 20
const { data, error } = await supabase
  .from('posts')
  .select('*', { count: 'exact' })
  .range(page * PAGE_SIZE, (page + 1) * PAGE_SIZE - 1)
```

## Realtime Subscriptions

### Subscribe to database changes:
```typescript
const channel = supabase
  .channel('posts-changes')
  .on('postgres_changes',
    { event: 'INSERT', schema: 'public', table: 'posts' },
    (payload) => { console.log('New post:', payload.new) }
  )
  .subscribe()
```

Enable realtime on specific tables in the Supabase dashboard first.

### Broadcast (ephemeral, high-frequency):
```typescript
const channel = supabase.channel('room-1')
channel.on('broadcast', { event: 'cursor' }, (payload) => {
  // Handle cursor position update
})
channel.subscribe()
channel.send({ type: 'broadcast', event: 'cursor', payload: { x: 100, y: 200 } })
```

### Presence (track online users):
```typescript
const channel = supabase.channel('online-users')
channel.on('presence', { event: 'sync' }, () => {
  const state = channel.presenceState()
})
channel.subscribe(async (status) => {
  if (status === 'SUBSCRIBED') {
    await channel.track({ user_id: userId, username: 'alice' })
  }
})
```

### Cleanup subscriptions on unmount:
```typescript
useEffect(() => {
  const channel = supabase.channel('my-channel')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'messages' },
      (payload) => handleChange(payload))
    .subscribe()
  return () => { supabase.removeChannel(channel) }
}, [])
```

### Realtime rules:
- Use broadcast for high-frequency ephemeral events (cursors, typing)
- Enable postgres_changes selectively — only on tables that need it
- Always unsubscribe on component unmount to prevent leaks

## Storage

### Create a bucket:
```typescript
const { data, error } = await supabase.storage.createBucket('avatars', {
  public: true,
  allowedMimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
  fileSizeLimit: 2 * 1024 * 1024, // 2MB
})
```

### Upload a file:
```typescript
const { data, error } = await supabase.storage
  .from('avatars')
  .upload(`${userId}/avatar.png`, file, {
    cacheControl: '3600',
    upsert: true,
  })
```

### Get public URL (public bucket):
```typescript
const { data } = supabase.storage.from('avatars').getPublicUrl('user1/avatar.png')
// data.publicUrl => full URL
```

### Signed URL (private bucket, temporary access):
```typescript
const { data, error } = await supabase.storage
  .from('documents')
  .createSignedUrl('user1/report.pdf', 3600) // 1 hour
```

### Storage RLS policies:
```sql
-- Users upload to own folder
CREATE POLICY "User upload" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Users read own files
CREATE POLICY "User read" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
```

Organize files as `{user_id}/{filename}` for clean per-user isolation.

## Edge Functions
```typescript
// supabase/functions/hello/index.ts
Deno.serve(async (req) => {
  const { name } = await req.json()
  return new Response(JSON.stringify({ message: `Hello, ${name}!` }), {
    headers: { 'Content-Type': 'application/json' },
  })
})
```

### Edge function with Supabase client:
```typescript
import { createClient } from 'npm:@supabase/supabase-js@2'

Deno.serve(async (req) => {
  const authHeader = req.headers.get('Authorization')!
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  )
  const { data: { user } } = await supabase.auth.getUser()
  const { data } = await supabase.from('profiles').select().eq('id', user!.id).single()
  return Response.json(data)
})
```

### Multi-route with Hono:
```typescript
import { Hono } from 'npm:hono@4'
const app = new Hono().basePath('/api')
app.get('/health', (c) => c.json({ status: 'ok' }))
app.post('/process', async (c) => {
  const body = await c.req.json()
  return c.json({ processed: true, input: body })
})
Deno.serve(app.fetch)
```

### Edge function rules:
- Use `Deno.serve()` — the old `import { serve }` pattern is deprecated
- Pin dependency versions: `npm:package@1.2.3`, not bare specifiers
- Auto-injected env vars: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_DB_URL`
- Write files only to `/tmp`
- Use `EdgeRuntime.waitUntil(promise)` for background tasks after response
- Deploy: `supabase functions deploy my-function`
- Test locally: `supabase functions serve`

## Migrations and Type Generation

### Create a migration:
```bash
supabase migration new create_posts_table
# Edit: supabase/migrations/<timestamp>_create_posts_table.sql
```

### Example migration:
```sql
CREATE TABLE public.posts (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title text NOT NULL,
  content text,
  status text DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'archived')),
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;
CREATE INDEX idx_posts_user_id ON public.posts(user_id);
CREATE INDEX idx_posts_status ON public.posts(status);
```

### Apply migrations:
```bash
supabase db reset         # reset local DB and replay all migrations
supabase db push          # push migrations to remote project
```

### Generate TypeScript types:
```bash
# From local database
supabase gen types typescript --local > src/supabase.types.ts

# From remote project
supabase gen types typescript --project-id <ref> > src/supabase.types.ts
```

Regenerate types after every schema change. Add to CI/CD pipeline.

### Using generated types:
```typescript
import type { Database } from './supabase.types'
type Post = Database['public']['Tables']['posts']['Row']
type PostInsert = Database['public']['Tables']['posts']['Insert']
type PostUpdate = Database['public']['Tables']['posts']['Update']
```

## Self-Hosting

Use Docker Compose — see [assets/docker-compose.yml](assets/docker-compose.yml) for a complete stack.
```bash
git clone https://github.com/supabase/supabase
cd supabase/docker
cp .env.example .env     # edit secrets, JWT, SMTP config
docker compose up -d
```

Critical: change default JWT secret, anon/service role keys. Configure SMTP, backups, TLS reverse proxy.

## Production Checklist

### Security:
- RLS enabled on every public table with tested policies
- Service role key never in client code or version control
- Custom SMTP configured for auth emails
- Database connection pooling via Supavisor

### Performance:
- Indexes on all RLS-referenced columns and common query filters
- Realtime enabled only on tables that need it
- Use `.select('col1, col2')` instead of `.select('*')` for large tables

### Reliability:
- Point-in-time recovery (PITR) enabled for production
- Database migrations versioned in source control
- Types regenerated in CI after migration changes
- Error handling on every Supabase client call

### Monitoring:
- Enable `pg_stat_statements` for query performance
- Monitor realtime WebSocket connection counts and storage usage

## Common Pitfalls

- **Forgetting RLS**: Tables without RLS are fully public via the anon key
- **Using `getSession()` on server**: Use `getUser()` — it actually validates the JWT
- **Unindexed RLS columns**: Causes full table scans on every query
- **Overusing postgres_changes**: Use broadcast for high-frequency events instead
- **Bare imports in Edge Functions**: Always use `npm:` or `jsr:` prefixes with pinned versions
- **Not cleaning up subscriptions**: Causes memory leaks and excessive connections
- **Mixing anon/service keys**: anon for client, service role for server admin only

## References

Deep-dive guides in `references/`:

- **[rls-patterns.md](references/rls-patterns.md)** — Comprehensive RLS guide: policy types, USING vs WITH CHECK, auth functions, ownership/RBAC/multi-tenant patterns, performance tuning, testing strategies, common mistakes
- **[auth-guide.md](references/auth-guide.md)** — Auth deep dive: email/password, OAuth, magic links, phone, MFA/TOTP, custom claims, JWT hooks, SSR auth, React/Next.js patterns, middleware, custom UI
- **[troubleshooting.md](references/troubleshooting.md)** — Common issues and fixes: RLS blocking, auth tokens, realtime, storage, edge functions, migrations, types, connection pooling, rate limits, CORS, PostgREST gotchas

## Scripts

Executable helpers in `scripts/`:

- **[setup-supabase-local.sh](scripts/setup-supabase-local.sh)** — Set up local dev environment (install CLI, init project, start services, create initial migration, generate types)
- **[generate-types.sh](scripts/generate-types.sh)** — Generate TypeScript types from local or remote schema with diff support
- **[rls-audit.sh](scripts/rls-audit.sh)** — Audit RLS policies: find tables without RLS, empty policies, permissive anti-patterns, missing indexes

## Assets

Templates and boilerplate in `assets/`:

- **[supabase-client.ts](assets/supabase-client.ts)** — Type-safe client setup (browser, admin, SSR) with auth helpers and error handling
- **[middleware.ts](assets/middleware.ts)** — Next.js App Router middleware for Supabase auth with cookie-based session refresh
- **[migration-template.sql](assets/migration-template.sql)** — SQL migration template with RLS policies, indexes, and updated_at trigger
- **[edge-function-template.ts](assets/edge-function-template.ts)** — Deno edge function with CORS, auth, method routing, and structured errors
- **[docker-compose.yml](assets/docker-compose.yml)** — Self-hosted Supabase stack (Postgres, GoTrue, PostgREST, Realtime, Storage, Kong, Studio)
