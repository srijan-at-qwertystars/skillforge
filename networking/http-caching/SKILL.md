---
name: http-caching
description: >
  Use when user asks about HTTP caching headers, Cache-Control directives,
  ETags, CDN caching, cache invalidation strategies, stale-while-revalidate,
  Vary header, or browser caching behavior. Do NOT use for application-level
  caching (Redis, Memcached), database query caching, or general HTTP protocol
  questions unrelated to caching.
---

# HTTP Caching

## Cache-Control Directives

Set `Cache-Control` on every cacheable response. Combine directives with commas.

| Directive | Scope | Effect |
|---|---|---|
| `max-age=N` | Browser + shared | Fresh for N seconds from response time |
| `s-maxage=N` | Shared caches only | Overrides `max-age` at CDN/proxy layer |
| `no-cache` | All | Store response but revalidate before every use |
| `no-store` | All | Never store — not in memory, not on disk |
| `private` | Browser only | Prohibit CDN/proxy caching (personalized content) |
| `public` | All | Explicitly cacheable by any cache |
| `immutable` | All | Resource will not change while fresh — skip revalidation |
| `must-revalidate` | All | Once stale, must revalidate — never serve stale |
| `stale-while-revalidate=N` | All | Serve stale for N seconds while revalidating in background |
| `stale-if-error=N` | All | Serve stale for N seconds if origin returns 5xx |

### Header Examples

Fingerprinted static asset (cache forever):
```http
Cache-Control: public, max-age=31536000, immutable
```

API response cached at CDN, short browser TTL:
```http
Cache-Control: public, max-age=0, s-maxage=300, stale-while-revalidate=60
```

Personalized page — browser only:
```http
Cache-Control: private, max-age=0, must-revalidate
```

Sensitive data — never cache:
```http
Cache-Control: no-store
```

## ETag and Last-Modified

Use conditional requests to avoid re-downloading unchanged resources.

### ETag Flow

1. Origin responds with `ETag: "a1b2c3"`.
2. Browser sends `If-None-Match: "a1b2c3"` on next request.
3. If unchanged, origin returns `304 Not Modified` (no body).

Strong ETag — byte-identical:
```http
ETag: "33a64df551425fcc55e4d42a148795d9f25f89d4"
```

Weak ETag — semantically equivalent:
```http
ETag: W/"v2.6"
```

Prefer strong ETags. Use weak ETags when compression or minification may produce byte-different but equivalent representations.

### Last-Modified Flow

1. Origin responds with `Last-Modified: Wed, 15 Jan 2025 08:00:00 GMT`.
2. Browser sends `If-Modified-Since: Wed, 15 Jan 2025 08:00:00 GMT`.
3. Origin returns `304` if unchanged.

ETags are more precise than `Last-Modified`. Use both for maximum compatibility.

### Combined Header Example
```http
Cache-Control: public, max-age=0, s-maxage=3600, stale-while-revalidate=300
ETag: "a1b2c3d4"
Last-Modified: Wed, 15 Jan 2025 08:00:00 GMT
```

## Vary Header and Content Negotiation

`Vary` tells caches which request headers produce different response variants. Each unique combination of Vary header values creates a separate cache entry.

```http
Vary: Accept-Encoding
```

Use `Vary: Accept-Encoding` when serving compressed responses. Without it, a gzip-compressed response may be served to a client that only accepts `br`.

```http
Vary: Accept-Encoding, Accept-Language
```

Add `Accept-Language` only if the origin returns different content per language at the same URL.

### Rules

- Include the minimum set of headers that actually change the response.
- Never use `Vary: *` — it effectively disables caching.
- Adding `Vary: Cookie` or `Vary: Authorization` destroys CDN hit rates. Use `Cache-Control: private` instead.
- Each additional Vary header multiplies cache entries. Keep the Vary surface small.

## CDN Caching Strategies

### Origin Shield

Place a shield (mid-tier cache) between edge PoPs and the origin:

- Collapses concurrent cache misses into a single origin fetch.
- Reduces origin load during traffic spikes or cache-clear events.
- Deploy the shield in a region close to the origin for lowest latency.
- Configure longer TTLs at the shield than at the edge.

### Cache Keys

The cache key determines what constitutes a unique cached object.

- Normalize URL paths (`/index.html` → `/`).
- Strip marketing query parameters (`utm_source`, `fbclid`).
- Include only query parameters that change the response.
- Avoid including cookies in cache keys unless they control content variants.

### Purge Patterns

**Single URL purge:** Invalidate one specific object by its URL.

**Wildcard/prefix purge:** Invalidate all objects matching a path prefix (e.g., `/api/v2/*`).

**Surrogate-Key (tag-based) purge:** Tag responses with logical identifiers and purge by tag.

```http
Surrogate-Key: product-123 category-electronics
```

When product 123 changes, purge all objects tagged `product-123` regardless of URL.

**Soft purge:** Mark objects as stale instead of deleting. The CDN serves stale content if the origin is unavailable, improving resilience.

## Cache Invalidation Patterns

### Versioned URLs (Recommended)

Embed a content hash or version in the filename:
```
/assets/app.3f2a9c.js
/assets/style.7b1e4d.css
```

Set `Cache-Control: public, max-age=31536000, immutable`. When content changes, the filename changes — no purge needed.

### Query String Cache Busting

```
/api/config?v=20250115
```

Less reliable — some CDNs ignore query strings by default. Prefer path-based versioning.

### Deploy-Triggered Purge

Automate cache purges in CI/CD pipelines:
```bash
# Fastly
curl -X POST "https://api.fastly.com/service/$SID/purge_all" \
  -H "Fastly-Key: $TOKEN"

# CloudFront
aws cloudfront create-invalidation \
  --distribution-id $DIST_ID \
  --paths "/*"
```

### Surrogate Keys for Granular Invalidation

Tag responses at the origin:
```http
Surrogate-Key: user-profile user-42 team-7
```

Purge only affected tags on data change — avoids over-invalidation.

## Caching Strategies by Content Type

### Static Assets (JS, CSS, Images, Fonts)

```http
Cache-Control: public, max-age=31536000, immutable
```
Use fingerprinted filenames. Never reuse a URL with different content.

### API Responses

```http
Cache-Control: public, max-age=0, s-maxage=60, stale-while-revalidate=30
ETag: "response-hash"
Vary: Accept-Encoding, Authorization
```
Short CDN TTL with background revalidation. Include ETag for conditional requests.

### HTML Pages

```http
Cache-Control: public, max-age=0, s-maxage=300, stale-while-revalidate=60, must-revalidate
```
Short TTL so users get fresh content. Never set long `max-age` on HTML — it makes deploying updates impossible until caches expire.

### Authenticated / Personalized Responses

```http
Cache-Control: private, no-cache
Vary: Cookie
```
Cache in the browser only. Always revalidate. Never cache at CDN layer.

### Immutable Config / Manifests

```http
Cache-Control: public, max-age=86400, stale-if-error=604800
ETag: "config-v5"
```
Moderate TTL with long error fallback window.

## Service Worker Caching Strategies

### Cache-First

Serve from cache. Fall back to network on miss. Update cache with network response.

Best for: static assets, app shell, fonts, icons.

```js
async function cacheFirst(request, cacheName) {
  const cached = await caches.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  const cache = await caches.open(cacheName);
  cache.put(request, response.clone());
  return response;
}
```

### Network-First

Try network. Fall back to cache if offline or on error. Update cache with fresh response.

Best for: API data, news feeds, user-generated content.

```js
async function networkFirst(request, cacheName) {
  try {
    const response = await fetch(request);
    const cache = await caches.open(cacheName);
    cache.put(request, response.clone());
    return response;
  } catch {
    return caches.match(request);
  }
}
```

### Stale-While-Revalidate

Return cached response immediately. Fetch update in background for next load.

Best for: avatars, semi-dynamic content, analytics scripts.

```js
async function staleWhileRevalidate(request, cacheName) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);
  const fetchPromise = fetch(request).then(response => {
    cache.put(request, response.clone());
    return response;
  });
  return cached || fetchPromise;
}
```

### Cache Versioning

Version cache names. Clean up old caches on `activate`:

```js
const CACHE_VERSION = 'v3';
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys.filter(k => k !== CACHE_VERSION).map(k => caches.delete(k))
      )
    )
  );
});
```

## Debugging Cache Issues

### curl Commands

Check response headers:
```bash
curl -sI https://example.com/asset.js | grep -iE 'cache-control|etag|age|x-cache|vary'
```

Test conditional request:
```bash
curl -s -o /dev/null -w "%{http_code}" \
  -H 'If-None-Match: "a1b2c3"' https://example.com/asset.js
# Expect 304 if ETag matches
```

Bypass cache:
```bash
curl -H "Cache-Control: no-cache" -H "Pragma: no-cache" https://example.com/page
```

### Browser DevTools

1. Open Network tab → check "Disable cache" to test origin responses.
2. Look at the `Size` column: `(disk cache)` or `(memory cache)` = served from browser cache.
3. Check `Age` header — seconds since the CDN cached the response.
4. Look for `X-Cache: HIT` / `MISS` headers from CDN.
5. `304` status = successful conditional request (saved bandwidth).

### Common Diagnostic Headers

| Header | Meaning |
|---|---|
| `Age: 120` | Object has been in CDN cache for 120 seconds |
| `X-Cache: HIT` | CDN served from cache |
| `X-Cache: MISS` | CDN fetched from origin |
| `CF-Cache-Status: DYNAMIC` | Cloudflare did not cache (no caching rule matched) |

## Anti-Patterns

### Caching Authenticated Responses at CDN

Never set `public` or `s-maxage` on responses that contain user-specific data. One user's data leaks to another.

Fix: Use `Cache-Control: private, no-cache` or omit caching entirely.

### Missing Vary Header

Serving gzipped content without `Vary: Accept-Encoding` → a compressed response may be served to a client that cannot decompress it.

Fix: Always set `Vary: Accept-Encoding` when using content encoding.

### Over-Caching HTML

Setting `max-age=86400` on HTML pages → users see stale pages for up to 24 hours after a deploy, with no way to force a refresh.

Fix: Use `max-age=0` with `s-maxage` and `stale-while-revalidate` for CDN caching.

### Setting Long max-age Without Immutable Filenames

Caching `/app.js` with `max-age=31536000` without filename hashing → updating the file requires waiting a year or users manually clearing caches.

Fix: Use fingerprinted filenames (`app.3f2a9c.js`) with `immutable`.

### Using no-cache When You Mean no-store

`no-cache` still stores the response — it just revalidates every time. For truly sensitive data (banking, medical), use `no-store`.

### Over-Varying

`Vary: User-Agent` creates a separate cache entry per user-agent string — thousands of variants, near-zero hit rate.

Fix: Normalize to a handful of variants (mobile/desktop) at the CDN edge, or remove the Vary and serve responsive content.

### Cache Stampede on Expiry

When a popular object expires, hundreds of concurrent requests hit the origin simultaneously.

Fix: Use `stale-while-revalidate` so one background request refreshes while stale content is served. Configure request coalescing at the CDN or origin shield.

<!-- tested: pass -->
