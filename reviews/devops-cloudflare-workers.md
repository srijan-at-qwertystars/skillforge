# Review: cloudflare-workers

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:
- `npx wrangler init my-worker` (SKILL.md line 48) is deprecated. Cloudflare now recommends `npm create cloudflare@latest my-worker` (C3 CLI). The init-worker.sh script also doesn't use C3, though it builds manually which is acceptable for a scaffolding helper.
- Subrequest limit inconsistency: SKILL.md main body correctly states 10,000 for paid plans, but references/troubleshooting.md (line 120) states "1,000 (paid — increased from 50 on Bundled plans)". The current correct limit is 10,000 subrequests/request on paid plans.
- Runtime limits table, KV/D1/R2/DO/Queue APIs, Hono patterns, wrangler.toml config, vitest-pool-workers testing, and all code examples are accurate and current.
- YAML frontmatter has name + description with positive AND negative triggers. Body is 499 lines (under 500). Imperative voice used throughout. All references/, scripts/, assets/ files are properly linked.
- Trigger description is well-scoped: correctly targets CF Workers ecosystem terms and explicitly excludes Lambda, Vercel, Fastly, and generic Node.js/Deno/Bun.

## Detail

### Structure ✅
- YAML frontmatter: name ✅, description ✅, positive triggers ✅, negative triggers ✅
- Body: 499 lines (under 500 limit) ✅
- Imperative voice throughout ✅
- Code examples with I/O comments ✅
- Resources linked in tables to references/, scripts/, assets/ ✅

### Content
- Wrangler CLI: mostly correct, `wrangler init` deprecated (minor)
- Runtime limits table: all values verified correct against official docs
- KV API (put/get/getWithMetadata/delete/list): correct ✅
- D1 API (prepare/bind/all/first/run/batch): correct ✅
- R2 API (put/get/head/delete/list/multipart): correct ✅
- Durable Objects (storage, blockConcurrencyWhile, WebSocket hibernation, alarms): correct ✅
- Queues (send/sendBatch/ack/retry): correct ✅
- Hono integration (typed bindings, middleware, sub-router, app.request testing): correct ✅
- Workers AI (run, streaming, embeddings): correct ✅

### Triggers ✅
- Would trigger for: wrangler, wrangler.toml, Workers KV, D1, R2, DO, Queues, Hono on Workers, Miniflare
- Would NOT trigger for: AWS Lambda, Vercel Edge Functions, Fastly Compute, generic Node.js
- Edge case: "serverless edge functions on Cloudflare" correctly included as positive trigger
