# Review: nextjs-patterns

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues: Non-standard description format. 501 lines (1 over limit). Dockerfile syntax error on line 454: `COPY package*.json ./ && RUN npm ci` — COPY and RUN are separate Dockerfile instructions, cannot be chained with &&. Should be two lines. All other code examples are correct.

Comprehensive Next.js 15 App Router guide. Covers architecture (special files, folder convention), Server vs Client Components (composition pattern), Server Actions (validation/useActionState/optimistic updates with React 19), data fetching (Suspense streaming, ISR), route handlers (streaming response), dynamic routes (generateStaticParams with Promise params), middleware (auth/geo/headers), caching (4-layer table, use cache directive), metadata/SEO (static/dynamic/sitemap/robots), image/font optimization, parallel and intercepting routes, authentication patterns (middleware guard/NextAuth v5), deployment (Vercel/Docker standalone/static export), performance, and anti-patterns.
