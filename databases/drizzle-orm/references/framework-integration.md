# Drizzle ORM — Framework Integration Guide

## Table of Contents

- [Next.js App Router](#nextjs-app-router)
- [Remix / React Router](#remix--react-router)
- [SvelteKit](#sveltekit)
- [Hono](#hono)
- [tRPC Integration](#trpc-integration)
- [Database Providers](#database-providers)
  - [Neon Serverless](#neon-serverless)
  - [Turso / LibSQL](#turso--libsql)
  - [PlanetScale](#planetscale)
  - [Supabase](#supabase)
  - [Vercel Postgres](#vercel-postgres)
  - [Cloudflare D1](#cloudflare-d1)

## Next.js App Router

### Database Client Singleton

Prevent connection leaks during hot reloads:

```typescript
// src/db/index.ts
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from './schema';

const globalForDb = globalThis as unknown as { conn: postgres.Sql | undefined };
const conn = globalForDb.conn ?? postgres(process.env.DATABASE_URL!);
if (process.env.NODE_ENV !== 'production') globalForDb.conn = conn;
export const db = drizzle(conn, { schema });
```

### Server Components

Query directly in async Server Components — no API route needed:

```typescript
// app/users/page.tsx
import { db } from '@/db';
import { users } from '@/db/schema';

export default async function UsersPage() {
  const allUsers = await db.select().from(users).orderBy(desc(users.createdAt));
  return <ul>{allUsers.map((u) => <li key={u.id}>{u.name}</li>)}</ul>;
}
```

### Server Actions

```typescript
'use server';
import { db } from '@/db';
import { users } from '@/db/schema';
import { revalidatePath } from 'next/cache';
import { z } from 'zod';

const CreateUserSchema = z.object({ name: z.string().min(1), email: z.string().email() });

export async function createUser(formData: FormData) {
  const parsed = CreateUserSchema.safeParse({
    name: formData.get('name'), email: formData.get('email'),
  });
  if (!parsed.success) return { error: parsed.error.flatten() };
  await db.insert(users).values(parsed.data);
  revalidatePath('/users');
}
```

### Edge Runtime

For edge routes/middleware, use HTTP-based drivers (no TCP sockets on edge):

```typescript
// app/api/users/route.ts
import { neon } from '@neondatabase/serverless';
import { drizzle } from 'drizzle-orm/neon-http';
export const runtime = 'edge';

export async function GET() {
  const db = drizzle(neon(process.env.DATABASE_URL!));
  const result = await db.select().from(schema.users);
  return Response.json(result);
}
```

**Edge constraints**: No `pg`/`postgres` (require TCP) — use Neon HTTP, Vercel Postgres, or PlanetScale HTTP. No filesystem access. Instantiate client per-request.

## Remix / React Router

### Setup

```typescript
// app/db.server.ts (`.server.ts` excludes from client bundle)
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from './db/schema';

const client = postgres(process.env.DATABASE_URL!);
export const db = drizzle(client, { schema });
```

### Loader Pattern (Data Loading)

```typescript
// app/routes/users.tsx
import { json, type LoaderFunctionArgs } from '@remix-run/node';
import { useLoaderData } from '@remix-run/react';
import { db } from '~/db.server';
import { users } from '~/db/schema';

export async function loader({ request }: LoaderFunctionArgs) {
  const search = new URL(request.url).searchParams.get('q');
  const result = await db.select().from(users)
    .where(search ? ilike(users.name, `%${search}%`) : undefined)
    .limit(50);
  return json({ users: result });
}

export default function UsersRoute() {
  const { users } = useLoaderData<typeof loader>();
  return <ul>{users.map((u) => <li key={u.id}>{u.name}</li>)}</ul>;
}
```

### Action Pattern (Mutations)

```typescript
// app/routes/users.new.tsx
import { redirect, json, type ActionFunctionArgs } from '@remix-run/node';
import { db } from '~/db.server';
import { users } from '~/db/schema';

export async function action({ request }: ActionFunctionArgs) {
  const formData = await request.formData();
  const name = String(formData.get('name'));
  const email = String(formData.get('email'));
  if (!name || !email) return json({ error: 'Name and email required' }, { status: 400 });
  await db.insert(users).values({ name, email });
  return redirect('/users');
}
```

For Remix on Cloudflare Workers, use D1 or HTTP-based drivers (see Database Providers).

## SvelteKit

### Setup

```typescript
// src/lib/server/db.ts
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from './schema';
import { DATABASE_URL } from '$env/static/private';

const client = postgres(DATABASE_URL);
export const db = drizzle(client, { schema });
```

### Page Server Load

```typescript
// src/routes/users/+page.server.ts
import { db } from '$lib/server/db';
import { users } from '$lib/server/schema';
import type { PageServerLoad, Actions } from './$types';

export const load: PageServerLoad = async () => {
  const allUsers = await db.select().from(users).orderBy(desc(users.createdAt));
  return { users: allUsers };
};
```

### Form Actions

```typescript
export const actions: Actions = {
  create: async ({ request }) => {
    const data = await request.formData();
    const name = data.get('name')?.toString();
    const email = data.get('email')?.toString();
    if (!name || !email) return fail(400, { error: 'Missing fields' });
    await db.insert(users).values({ name, email });
    return { success: true };
  },
};
```

### Hooks (Middleware)

Inject the db into request context:

```typescript
// src/hooks.server.ts
export const handle: Handle = async ({ event, resolve }) => {
  event.locals.db = db;
  return resolve(event);
};
// Declare in src/app.d.ts: interface Locals { db: typeof db }
```

## Hono

### Standard Node.js / Bun

```typescript
import { Hono } from 'hono';
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from './schema';

const db = drizzle(postgres(process.env.DATABASE_URL!), { schema });
const app = new Hono();

app.get('/users', async (c) => {
  return c.json(await db.select().from(schema.users));
});

app.get('/users/:id', async (c) => {
  const user = await db.query.users.findFirst({
    where: eq(schema.users.id, Number(c.req.param('id'))),
    with: { posts: true },
  });
  return user ? c.json(user) : c.json({ error: 'Not found' }, 404);
});

app.post('/users', async (c) => {
  const [user] = await db.insert(schema.users).values(await c.req.json()).returning();
  return c.json(user, 201);
});

export default app;
```

### Cloudflare Workers + D1

```typescript
import { Hono } from 'hono';
import { drizzle } from 'drizzle-orm/d1';

type Bindings = { DB: D1Database };
const app = new Hono<{ Bindings: Bindings }>();

app.use('*', async (c, next) => {
  c.set('db', drizzle(c.env.DB, { schema }));
  await next();
});

app.get('/users', async (c) => {
  return c.json(await c.get('db').select().from(schema.users));
});

export default app;
```

## tRPC Integration

### Setup with Drizzle context

```typescript
// server/trpc.ts
import { initTRPC } from '@trpc/server';
import { db } from './db';

export const createContext = () => ({ db });
const t = initTRPC.context<ReturnType<typeof createContext>>().create();
export const router = t.router;
export const publicProcedure = t.procedure;
```

### Router with Drizzle queries

```typescript
// server/routers/users.ts
import { z } from 'zod';
import { router, publicProcedure } from '../trpc';
import { users } from '../db/schema';

export const usersRouter = router({
  list: publicProcedure
    .input(z.object({ search: z.string().optional(), limit: z.number().max(100).default(20) }))
    .query(async ({ ctx, input }) => {
      return ctx.db.select().from(users)
        .where(input.search ? ilike(users.name, `%${input.search}%`) : undefined)
        .limit(input.limit);
    }),

  getById: publicProcedure
    .input(z.object({ id: z.number() }))
    .query(({ ctx, input }) => ctx.db.query.users.findFirst({
      where: eq(users.id, input.id), with: { posts: true },
    })),

  create: publicProcedure
    .input(z.object({ name: z.string().min(1), email: z.string().email() }))
    .mutation(async ({ ctx, input }) => {
      const [user] = await ctx.db.insert(users).values(input).returning();
      return user;
    }),
});
```

**End-to-end type safety**: tRPC infers types from Zod schemas, Drizzle infers return types from schema — no manual types needed.

## Database Providers

### Neon Serverless

```typescript
// Option 1: HTTP driver (Edge/serverless — no persistent connection)
import { neon } from '@neondatabase/serverless';
import { drizzle } from 'drizzle-orm/neon-http';
const db = drizzle(neon(process.env.DATABASE_URL!));

// Option 2: WebSocket driver (Node.js/serverless with connection pooling)
import { Pool, neonConfig } from '@neondatabase/serverless';
import { drizzle } from 'drizzle-orm/neon-serverless';
import ws from 'ws';
neonConfig.webSocketConstructor = ws;
const db = drizzle(new Pool({ connectionString: process.env.DATABASE_URL! }), { schema });
```

Use the **pooled connection string** (`-pooler` suffix) for serverless.

### Turso / LibSQL

```typescript
import { drizzle } from 'drizzle-orm/libsql';
import { createClient } from '@libsql/client';

const client = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN!,
});
export const db = drizzle(client, { schema });
```

In `drizzle.config.ts`, use `dialect: 'turso'` with the same credentials.

### PlanetScale

```typescript
import { drizzle } from 'drizzle-orm/planetscale-serverless';
import { Client } from '@planetscale/database';

const client = new Client({ host: process.env.DATABASE_HOST, username: process.env.DATABASE_USERNAME, password: process.env.DATABASE_PASSWORD });
export const db = drizzle(client, { schema });
```

**Note**: MySQL dialect. No `.returning()` — use `insertId` from result.

### Supabase

```typescript
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';

// Transaction mode (serverless — port 6543): disable prepared statements
const client = postgres(process.env.DATABASE_URL!, { prepare: false });
export const db = drizzle(client);

// Session mode (long-running servers — port 5432):
// const client = postgres(process.env.DIRECT_URL!);
```

**Important**: Supavisor in transaction mode doesn't support prepared statements — always use `{ prepare: false }`.

### Vercel Postgres

```typescript
import { drizzle } from 'drizzle-orm/vercel-postgres';
import { sql as vercelSql } from '@vercel/postgres';
import * as schema from './schema';

export const db = drizzle(vercelSql, { schema });
// Works in both Node.js and Edge runtimes
```

### Cloudflare D1

```typescript
// src/index.ts (Cloudflare Worker)
import { drizzle } from 'drizzle-orm/d1';
import * as schema from './schema';

export interface Env { DB: D1Database; }

export default {
  async fetch(request: Request, env: Env) {
    const db = drizzle(env.DB, { schema });
    return Response.json(await db.select().from(schema.users));
  },
};
```

**D1 specifics**: SQLite dialect (`sqliteTable`). No `.returning()`. Run migrations via `wrangler d1 migrations apply` or Drizzle's `push`. Bind the database via `wrangler.toml` `[[d1_databases]]`.
