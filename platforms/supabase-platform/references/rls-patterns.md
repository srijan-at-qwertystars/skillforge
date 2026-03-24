# Supabase Row Level Security (RLS) — Complete Reference

## Table of Contents

1. [RLS Fundamentals](#1-rls-fundamentals)
2. [Policy Types](#2-policy-types)
3. [USING vs WITH CHECK](#3-using-vs-with-check)
4. [Auth Functions](#4-auth-functions)
5. [Ownership Policies](#5-ownership-policies)
6. [Role-Based Access](#6-role-based-access)
7. [Multi-Tenant / Org Patterns](#7-multi-tenant--org-patterns)
8. [Public vs Private Data](#8-public-vs-private-data)
9. [RLS with Joins and Foreign Tables](#9-rls-with-joins-and-foreign-tables)
10. [Performance](#10-performance)
11. [Testing RLS](#11-testing-rls)
12. [Common Mistakes](#12-common-mistakes)

---

## 1. RLS Fundamentals

Row Level Security is a PostgreSQL feature that filters rows per-query. When enabled, queries that match no policy return zero rows (not errors). Supabase exposes Postgres via PostgREST — all client SDK requests arrive as `anon` or `authenticated`. RLS is the primary access control layer.

```sql
ALTER TABLE posts ENABLE ROW LEVEL SECURITY;
```

**FORCE ROW LEVEL SECURITY** — by default the table owner (`postgres`) bypasses RLS. `FORCE` applies policies to the owner too. Most Supabase apps don't need `FORCE` — the `service_role` key intentionally bypasses RLS for admin work, and client roles are always subject to RLS.

```sql
ALTER TABLE posts FORCE ROW LEVEL SECURITY;
```

The `service_role` key connects as a superuser-like role that bypasses RLS. Never expose it to clients.

---

## 2. Policy Types

```sql
CREATE POLICY "Read own"   ON posts FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Create own" ON posts FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "Update own" ON posts FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY "Delete own" ON posts FOR DELETE TO authenticated USING (user_id = auth.uid());
```

`FOR ALL` covers all four operations but prefer separate policies when logic differs.

### PERMISSIVE vs RESTRICTIVE

Policies are **PERMISSIVE** by default; multiple permissive policies combine with **OR**. **RESTRICTIVE** policies combine with **AND**. Final check: `(any permissive passes) AND (all restrictive pass)`.

```sql
CREATE POLICY "See own"    ON posts FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "See public" ON posts FOR SELECT TO authenticated USING (is_public = true);
-- User sees: (user_id = uid OR is_public = true)

CREATE POLICY "Not banned" ON posts FOR SELECT TO authenticated AS RESTRICTIVE
  USING (is_banned = false);
-- Final: (user_id = uid OR is_public) AND (is_banned = false)
```

Use descriptive policy names — they appear in error messages and `pg_policies`.

---

## 3. USING vs WITH CHECK

| Clause | Filters | Used By |
|--------|---------|---------|
| `USING` | Existing rows | SELECT, UPDATE (old row), DELETE |
| `WITH CHECK` | New/modified rows | INSERT, UPDATE (new row) |

SELECT and DELETE use only `USING`. INSERT uses only `WITH CHECK`. UPDATE needs **both** — `USING` selects which rows can be targeted, `WITH CHECK` validates the result after modification.

```sql
-- Moderators can update any post but cannot reassign ownership
CREATE POLICY "Mod update" ON posts FOR UPDATE TO authenticated
  USING (is_moderator(auth.uid()))
  WITH CHECK (user_id = (SELECT user_id FROM posts WHERE id = posts.id));
```

Omitting `WITH CHECK` on UPDATE means PostgreSQL reuses the `USING` expression — correct only when both should be identical.

---

## 4. Auth Functions

| Function | Returns | Notes |
|----------|---------|-------|
| `auth.uid()` | `uuid` | JWT `sub` claim. NULL for anon. |
| `auth.role()` | `text` | `'authenticated'` or `'anon'`. |
| `auth.jwt()` | `jsonb` | Full JWT payload. |

```sql
USING (email = (auth.jwt()->>'email'))
USING ((auth.jwt()->'user_metadata'->>'email_verified')::boolean = true)
```

### Custom Claims via app_metadata

```sql
-- Set server-side
UPDATE auth.users SET raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}'::jsonb
WHERE id = 'USER_UUID';

-- Use in policy
USING ((auth.jwt()->'app_metadata'->>'role') = 'admin')
```

### Raw JWT via current_setting

```sql
CREATE OR REPLACE FUNCTION get_my_org_id() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT (current_setting('request.jwt.claims', true)::jsonb->'app_metadata'->>'org_id')::uuid;
$$;
```

The `true` argument returns NULL instead of error when unset.

---

## 5. Ownership Policies

The most common pattern — users own rows and access only their own data.

```sql
CREATE TABLE documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) NOT NULL DEFAULT auth.uid(),
  title text NOT NULL,
  content text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Read own"   ON documents FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Create own" ON documents FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "Update own" ON documents FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY "Delete own" ON documents FOR DELETE TO authenticated USING (user_id = auth.uid());
```

The `DEFAULT auth.uid()` on `user_id` lets clients omit it; the `WITH CHECK` on INSERT rejects any attempt to set someone else's ID.

---

## 6. Role-Based Access

### Via Profiles Table (simple, adds a subquery per check)

```sql
CREATE TABLE profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id),
  role text NOT NULL DEFAULT 'user' CHECK (role IN ('user','moderator','admin'))
);
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Read own" ON profiles FOR SELECT TO authenticated USING (id = auth.uid());

CREATE POLICY "Admins delete any post" ON posts FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));
```

### Via JWT app_metadata (preferred — no subquery)

```sql
CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT coalesce((auth.jwt()->'app_metadata'->>'role') = 'admin', false);
$$;

CREATE POLICY "Admins manage all" ON posts FOR ALL TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());
```

### SECURITY DEFINER Helpers

When a helper must read tables the caller can't access directly:

```sql
CREATE OR REPLACE FUNCTION public.get_user_role(uid uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT role FROM profiles WHERE id = uid; $$;
```

Always set `search_path` to prevent injection. Mark `STABLE`. Keep the function body minimal.

---

## 7. Multi-Tenant / Org Patterns

### Schema

```sql
CREATE TABLE organizations (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL);
CREATE TABLE org_members (
  org_id uuid REFERENCES organizations(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('owner','admin','member')),
  PRIMARY KEY (org_id, user_id)
);
CREATE TABLE projects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid REFERENCES organizations(id) NOT NULL, name text NOT NULL
);
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
```

### Policies

```sql
CREATE POLICY "See own orgs" ON organizations FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM org_members WHERE org_id = organizations.id AND user_id = auth.uid()));

CREATE POLICY "See org projects" ON projects FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM org_members WHERE org_id = projects.org_id AND user_id = auth.uid()));

CREATE POLICY "Admins create projects" ON projects FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM org_members WHERE org_id = projects.org_id
    AND user_id = auth.uid() AND role IN ('admin','owner')
  ));
```

### RLS on the Membership Table Itself

Critical — without this, subqueries in other policies can't read `org_members`:

```sql
CREATE POLICY "See co-members" ON org_members FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM org_members m WHERE m.org_id = org_members.org_id AND m.user_id = auth.uid()));

CREATE POLICY "Owners add members" ON org_members FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM org_members m WHERE m.org_id = org_members.org_id AND m.user_id = auth.uid() AND m.role = 'owner'
  ));
```

### Helper Function + JWT Tenant Isolation

```sql
CREATE OR REPLACE FUNCTION public.user_has_org_access(check_org_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT EXISTS (SELECT 1 FROM org_members WHERE org_id = check_org_id AND user_id = auth.uid()); $$;

-- Or embed org_id in JWT for zero-query isolation
CREATE POLICY "Tenant isolation" ON projects FOR ALL TO authenticated
  USING (org_id = (auth.jwt()->'app_metadata'->>'org_id')::uuid)
  WITH CHECK (org_id = (auth.jwt()->'app_metadata'->>'org_id')::uuid);
```

---

## 8. Public vs Private Data

```sql
-- Public read, authenticated write
CREATE POLICY "Public read"   ON articles FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Auth insert"   ON articles FOR INSERT TO authenticated WITH CHECK (author_id = auth.uid());
CREATE POLICY "Author update" ON articles FOR UPDATE TO authenticated
  USING (author_id = auth.uid()) WITH CHECK (author_id = auth.uid());
```

### Anonymous Access

```sql
CREATE POLICY "Anon published" ON articles FOR SELECT TO anon USING (status = 'published');
CREATE POLICY "Auth drafts"    ON articles FOR SELECT TO authenticated
  USING (author_id = auth.uid() OR status = 'published');
```

### Mixing Public and Private Rows (is_public boolean)

```sql
CREATE POLICY "Public rows"  ON posts FOR SELECT TO anon, authenticated USING (is_public = true);
CREATE POLICY "Own rows"     ON posts FOR SELECT TO authenticated USING (user_id = auth.uid());
-- Permissive OR: visible if is_public OR user_id = auth.uid()
```

---

## 9. RLS with Joins and Foreign Tables

Each table in a JOIN is filtered **independently** by its own policies. You must have policies on every table in the query.

```sql
-- Both posts and comments are independently filtered
SELECT posts.title, comments.body FROM posts
JOIN comments ON comments.post_id = posts.id;
```

### Subqueries in Policies

```sql
CREATE POLICY "See comments on own posts" ON comments FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM posts WHERE posts.id = comments.post_id AND posts.user_id = auth.uid()));
```

RLS on `posts` also applies inside this subquery (runs as `authenticated`).

### Circular Dependencies

When table A's policy queries B and B's policy queries A, use a `SECURITY DEFINER` function to break the cycle:

```sql
CREATE OR REPLACE FUNCTION public.is_team_member(tid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT EXISTS (SELECT 1 FROM team_members WHERE team_id = tid AND user_id = auth.uid()); $$;

CREATE POLICY "Members see team" ON teams FOR SELECT TO authenticated
  USING (public.is_team_member(id));
```

---

## 10. Performance

Policy expressions execute per row. Index every column used in policies:

```sql
CREATE INDEX idx_posts_user_id ON posts (user_id);
CREATE INDEX idx_org_members_org_user ON org_members (org_id, user_id);
```

**SECURITY DEFINER helpers** avoid nested RLS evaluation (redundant subquery execution). **Denormalize** when possible — embedding `org_id` in the JWT and comparing directly is faster than an `EXISTS` subquery.

```sql
-- Fast: direct JWT comparison
USING (org_id = (auth.jwt()->'app_metadata'->>'org_id')::uuid)
-- Slow: subquery per row
USING (EXISTS (SELECT 1 FROM org_members WHERE org_id = projects.org_id AND user_id = auth.uid()))
```

Mark helper functions `STABLE` (not `VOLATILE`) so the planner can optimize. For hierarchical data, use materialized paths (`ltree`) to avoid recursive queries.

### Diagnosing Slow Policies

```sql
SELECT query, calls, mean_exec_time FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 20;

-- Test with EXPLAIN ANALYZE under RLS
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"USER_UUID","role":"authenticated"}';
EXPLAIN ANALYZE SELECT * FROM posts;
ROLLBACK;
```

---

## 11. Testing RLS

### SET LOCAL (SQL Editor / psql)

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"d0a1b2c3-...","role":"authenticated","app_metadata":{"role":"admin"}}';
SELECT * FROM posts;  -- RLS applies
ROLLBACK;
```

### supabase-js

```typescript
const anon = createClient(URL, ANON_KEY);
const { data } = await anon.from('posts').select('*'); // only public rows

const authed = createClient(URL, ANON_KEY);
await authed.auth.signInWithPassword({ email: 'test@example.com', password: 'pw' });
const { data: mine } = await authed.from('posts').select('*'); // only own rows

const { error } = await authed.from('posts').update({ user_id: 'OTHER' }).eq('id', 'X');
// error: policy violation
```

### pgTAP Tests

```sql
BEGIN;
SELECT plan(2);
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"aaaa-bbbb","role":"authenticated"}';

SELECT is_empty($$SELECT * FROM posts WHERE user_id = 'cccc-dddd'$$, 'Cannot see other users');
SELECT throws_ok($$INSERT INTO posts (user_id, title) VALUES ('cccc-dddd','Hack')$$, NULL, NULL, 'Cannot insert as other user');

SELECT * FROM finish();
ROLLBACK;
```

**Warning**: The Dashboard SQL Editor runs as `postgres` and **bypasses RLS**. Always test from a client or use `SET LOCAL role`.

---

## 12. Common Mistakes

**1. Forgetting to enable RLS** — the table is fully public. Audit with:
```sql
SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND NOT rowsecurity;
```

**2. Missing WITH CHECK on UPDATE** — users can change `user_id` to someone else's ID.

**3. Unindexed policy columns** — causes full table scans on every query.

**4. VOLATILE helper functions** — prevents planner optimization. Always use `STABLE`.

**5. Overly permissive `USING (true)` on ALL** — gives full CRUD to every authenticated user.

**6. Testing only in SQL Editor** — bypasses RLS. Policies that look correct may silently block client access.

**7. Circular policy dependencies** — table A's policy reads B, B's reads A. Fix with `SECURITY DEFINER`.

**8. Missing policies on join tables** — `EXISTS (SELECT 1 FROM org_members ...)` returns false if `org_members` has RLS but no SELECT policy.

**9. Client-side filtering as "security"** — `.eq('user_id', uid)` is UX, not access control.

**10. NULL auth.uid() in negations** — `NOT (user_id = auth.uid())` is NULL when uid is NULL. Use explicit checks:
```sql
USING (user_id IS NOT NULL AND user_id = auth.uid())
```

### Debug: List All Policies

```sql
SELECT tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies WHERE schemaname = 'public' ORDER BY tablename;
```

---

## Quick Reference

| Operation | USING | WITH CHECK |
|-----------|-------|------------|
| SELECT | ✅ Required | ❌ Not used |
| INSERT | ❌ Not used | ✅ Required |
| UPDATE | ✅ Old row | ✅ New row |
| DELETE | ✅ Required | ❌ Not used |

**Combining**: `(P1 OR P2 OR ... Pn) AND (R1 AND R2 AND ... Rn)` — at least one permissive must match; all restrictive must match.
