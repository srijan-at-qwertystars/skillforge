# Review: supabase-platform

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

1. **`auth.user_org_id()` in auth schema (line 146-148)**: Creating functions in the `auth` schema works but is discouraged on cloud-hosted Supabase. Recommend using `public` schema with `SECURITY DEFINER` instead, as the `auth` schema is managed by Supabase and could be affected by platform updates.

2. **Missing `getClaims()` for server-side JWT verification**: The skill correctly advises `getUser()` over `getSession()` on the server (line 110), but newer Supabase projects (with asymmetric JWT keys, now the default) should prefer `auth.getClaims(jwt)` for lower-latency local verification. Worth mentioning as an alternative.

3. **Missing per-function `deno.json` for Edge Functions**: Current best practice is to include a `deno.json` config per Edge Function for dependency management and import maps. The skill covers `npm:` prefixes correctly but omits this config pattern.

4. **Missing `alter publication supabase_realtime add table <table>` SQL**: Line 232 says "Enable realtime on specific tables in the Supabase dashboard first" but doesn't provide the SQL equivalent for migrations/CI workflows.

5. **Missing `supabase link` command**: The CLI section covers `init`, `start`, `status`, migrations, and type gen, but omits `supabase link --project-ref <ref>` which is required to connect local dev to a remote project before `db push` or remote type generation.

## Structure

- ✅ YAML frontmatter: `name` and `description` present
- ✅ Positive triggers: Supabase Auth, RLS, Realtime, Edge Functions, Storage, PostgREST, CLI, supabase-js, migrations, type gen, self-hosting
- ✅ Negative triggers: Firebase, AWS Amplify, raw PostgreSQL, general SQL, Appwrite, Parse
- ✅ Body: 496 lines (under 500 limit)
- ✅ Imperative voice, no filler
- ✅ Examples with input/output patterns throughout
- ✅ All `references/`, `scripts/`, and `assets/` files exist and are linked

## Content Verification (web-searched)

- ✅ `createClient` signature and options — correct for supabase-js v2
- ✅ `auth.signUp`, `signInWithOtp`, `signInWithOAuth` — correct signatures and options
- ✅ `onAuthStateChange` event types — correct
- ✅ RLS `USING` vs `WITH CHECK` semantics — correct
- ✅ PostgREST query patterns (`.from().select().eq().order().limit()`) — correct
- ✅ Realtime channel API (`.channel().on('postgres_changes', ...).subscribe()`) — correct v2 pattern
- ✅ Storage APIs (`createBucket`, `upload`, `getPublicUrl`, `createSignedUrl`) — correct
- ✅ Storage RLS with `storage.foldername(name)` — correct syntax
- ✅ Edge Functions `Deno.serve()` — correct (old `import { serve }` is deprecated)
- ✅ `EdgeRuntime.waitUntil()` for background tasks — verified, correct
- ✅ CLI commands (`init`, `start`, `migration new`, `db reset`, `db push`, `gen types`) — all correct
- ✅ `npm:` and `jsr:` import prefixes for Deno — correct

## Trigger Assessment

- Would correctly trigger for: Supabase Auth, RLS, Realtime, Edge Functions, Storage, PostgREST, CLI, supabase-js, migrations, self-hosting
- Would NOT falsely trigger for: Firebase, Amplify, Appwrite, Parse, raw PostgreSQL, general SQL
- Description is specific and comprehensive with clear boundaries
