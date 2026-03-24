# Advanced Service Worker Patterns

## Table of Contents

- [Navigation Preload](#navigation-preload)
- [Streaming Responses](#streaming-responses)
- [BroadcastChannel Communication](#broadcastchannel-communication)
- [Client Claims](#client-claims)
- [Cache Versioning](#cache-versioning)
- [Runtime Caching with Workbox Recipes](#runtime-caching-with-workbox-recipes)
- [Service Worker Update UX](#service-worker-update-ux)
- [Background Fetch API](#background-fetch-api)
- [Content Indexing API](#content-indexing-api)
- [Web Periodic Background Sync](#web-periodic-background-sync)

---

## Navigation Preload

Eliminates SW boot delay by starting the network request in parallel with SW startup. Critical for network-first navigation strategies.

### Enable

```js
// In activate event
self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      if (self.registration.navigationPreload) {
        await self.registration.navigationPreload.enable();
      }
    })()
  );
});
```

### Use in Fetch

```js
self.addEventListener('fetch', (event) => {
  if (event.request.mode === 'navigate') {
    event.respondWith(
      (async () => {
        try {
          // Use preloaded response if available
          const preloadResponse = await event.preloadResponse;
          if (preloadResponse) return preloadResponse;
          return await fetch(event.request);
        } catch {
          return caches.match('/offline.html');
        }
      })()
    );
  }
});
```

### Custom Preload Header

```js
await self.registration.navigationPreload.setHeaderValue('json_fragment');
// Server reads Service-Worker-Navigation-Preload header to return partial data
```

### With Workbox

```js
import { enable } from 'workbox-navigation-preload';
import { NetworkFirst } from 'workbox-strategies';
import { registerRoute, NavigationRoute } from 'workbox-routing';

enable();
registerRoute(new NavigationRoute(
  new NetworkFirst({ cacheName: 'pages', networkTimeoutSeconds: 3 })
));
```

**When to use:** Dynamic HTML pages, SSR content, personalized pages. Not needed for cache-first app shells. Supported in all major browsers except Firefox (fallback gracefully).

---

## Streaming Responses

Construct responses from multiple sources and start rendering before the full response is ready.

### Stitching Cached Shell + Network Content

```js
self.addEventListener('fetch', (event) => {
  if (event.request.mode === 'navigate') {
    event.respondWith(
      (async () => {
        const stream = new ReadableStream({
          async start(controller) {
            const encoder = new TextEncoder();
            // Serve cached header immediately
            const header = await caches.match('/shell-header.html');
            controller.enqueue(encoder.encode(await header.text()));
            // Fetch body from network
            try {
              const body = await fetch(`/api/page-content?url=${event.request.url}`);
              const reader = body.body.getReader();
              while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                controller.enqueue(value);
              }
            } catch {
              controller.enqueue(encoder.encode('<p>Content unavailable offline</p>'));
            }
            // Cached footer
            const footer = await caches.match('/shell-footer.html');
            controller.enqueue(encoder.encode(await footer.text()));
            controller.close();
          },
        });
        return new Response(stream, {
          headers: { 'Content-Type': 'text/html; charset=utf-8' },
        });
      })()
    );
  }
});
```

**Use case:** First paint within milliseconds (cached header), body streams in progressively. Ideal for news sites, dashboards, any SSR page.

---

## BroadcastChannel Communication

Simple cross-context messaging (SW ↔ all open tabs) without manual client enumeration.

### Service Worker → All Clients

```js
// sw.js
const channel = new BroadcastChannel('app-channel');
channel.postMessage({ type: 'CACHE_UPDATED', url: '/api/data' });
channel.postMessage({ type: 'SW_ACTIVATED', version: '2.0.0' });
```

### Client → Service Worker (and Other Tabs)

```js
// app.js
const channel = new BroadcastChannel('app-channel');
channel.onmessage = (event) => {
  switch (event.data.type) {
    case 'CACHE_UPDATED':
      refreshUI(event.data.url);
      break;
    case 'SW_ACTIVATED':
      showUpdateBanner(event.data.version);
      break;
  }
};
// Cleanup
window.addEventListener('beforeunload', () => channel.close());
```

### vs postMessage

| Feature | BroadcastChannel | postMessage |
|---------|-----------------|-------------|
| Setup | One line | Client enumeration needed |
| Targets | All contexts at once | One client at a time |
| Cross-tab | Built-in | Manual |
| Cleanup | `.close()` | Remove listeners |

**Prefer BroadcastChannel** for broadcasting. Use `postMessage` for targeted single-client messages.

---

## Client Claims

Control when a new SW takes over existing pages.

### Immediate Takeover

```js
// sw.js — install event
self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting()); // Skip waiting phase
});

// sw.js — activate event
self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim()); // Control all open pages immediately
});
```

### Controlled Takeover (Safer)

```js
// sw.js — only skipWaiting when told
self.addEventListener('message', (event) => {
  if (event.data?.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

// app.js — user clicks "Update Now"
navigator.serviceWorker.controller?.postMessage({ type: 'SKIP_WAITING' });
navigator.serviceWorker.addEventListener('controllerchange', () => {
  window.location.reload();
});
```

**Rule:** Use immediate (`skipWaiting` + `clients.claim`) for non-breaking updates. Use controlled takeover when the new SW changes cache structure or API contracts.

---

## Cache Versioning

### Strategy 1: Versioned Cache Names

```js
const APP_VERSION = '2.1.0';
const CACHES = {
  static: `static-${APP_VERSION}`,
  dynamic: `dynamic-${APP_VERSION}`,
  images: `images-${APP_VERSION}`,
};

self.addEventListener('activate', (event) => {
  const expectedCaches = new Set(Object.values(CACHES));
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(
        names
          .filter((name) => !expectedCaches.has(name))
          .map((name) => caches.delete(name))
      )
    )
  );
});
```

### Strategy 2: Content-Hash File Names (Build Tool)

Build tools produce `main.a1b2c3.js`. No cache busting needed — different URL = different cache entry. Workbox `precacheAndRoute` handles this automatically via its revision manifest.

### Strategy 3: Shared Long-Lived Caches

Keep image/font caches across SW versions (they rarely change). Only version app shell caches:

```js
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(
        names
          .filter((n) => n.startsWith('static-') && n !== CACHES.static)
          .map((n) => caches.delete(n))
      )
    )
  );
});
```

---

## Runtime Caching with Workbox Recipes

One-liner recipes for common patterns:

```js
import { pageCache, imageCache, staticResourceCache, googleFontsCache, offlineFallback } from 'workbox-recipes';

// Network-first for pages with 3s timeout
pageCache();

// Cache-first for static assets (JS, CSS)
staticResourceCache();

// Cache-first for images, max 60 entries, 30 days
imageCache();

// Cache Google Fonts (both stylesheet and font files)
googleFontsCache();

// Offline fallback page
offlineFallback({ pageFallback: '/offline.html' });
```

### Custom Recipe

```js
import { registerRoute } from 'workbox-routing';
import { StaleWhileRevalidate } from 'workbox-strategies';
import { ExpirationPlugin } from 'workbox-expiration';
import { CacheableResponsePlugin } from 'workbox-cacheable-response';

// API cache: SWR with 5-min expiration, max 50 entries
registerRoute(
  ({ url }) => url.pathname.startsWith('/api/'),
  new StaleWhileRevalidate({
    cacheName: 'api-responses',
    plugins: [
      new CacheableResponsePlugin({ statuses: [0, 200] }),
      new ExpirationPlugin({ maxEntries: 50, maxAgeSeconds: 5 * 60 }),
    ],
  })
);
```

---

## Service Worker Update UX

### Pattern 1: "Update Available" Banner

```js
// app.js
const registration = await navigator.serviceWorker.register('/sw.js');

registration.addEventListener('updatefound', () => {
  const newWorker = registration.installing;
  newWorker.addEventListener('statechange', () => {
    if (newWorker.state === 'installed' && navigator.serviceWorker.controller) {
      showUpdateBanner(); // New SW waiting — show "Refresh" button
    }
  });
});

function showUpdateBanner() {
  const banner = document.createElement('div');
  banner.innerHTML = `
    <p>New version available!</p>
    <button id="update-btn">Update</button>
  `;
  document.body.appendChild(banner);
  document.getElementById('update-btn').addEventListener('click', () => {
    registration.waiting.postMessage({ type: 'SKIP_WAITING' });
  });
}

navigator.serviceWorker.addEventListener('controllerchange', () => {
  window.location.reload();
});
```

### Pattern 2: Workbox Window

```js
import { Workbox } from 'workbox-window';

const wb = new Workbox('/sw.js');
wb.addEventListener('waiting', () => {
  if (confirm('New version available. Reload?')) {
    wb.messageSkipWaiting();
    wb.addEventListener('controlling', () => window.location.reload());
  }
});
wb.register();
```

### Pattern 3: Silent Update on Navigation

```js
// Auto-update when user navigates — no banner needed
navigator.serviceWorker.addEventListener('controllerchange', () => {
  // Only reload if no unsaved data
  if (!hasUnsavedChanges()) window.location.reload();
});
```

---

## Background Fetch API

Large downloads that survive browser tab close. Shows download progress in system UI.

```js
// Client — initiate background fetch
const reg = await navigator.serviceWorker.ready;
const bgFetch = await reg.backgroundFetch.fetch('podcast-ep-42', [
  '/media/episode-42-part1.mp3',
  '/media/episode-42-part2.mp3',
], {
  title: 'Downloading Episode 42',
  icons: [{ sizes: '192x192', src: '/icons/podcast.png', type: 'image/png' }],
  downloadTotal: 120 * 1024 * 1024, // 120 MB estimate
});

// Monitor progress
bgFetch.addEventListener('progress', () => {
  const pct = Math.round((bgFetch.downloaded / bgFetch.downloadTotal) * 100);
  updateProgressUI(pct);
});
```

```js
// sw.js — handle completion
self.addEventListener('backgroundfetchsuccess', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open('podcasts');
      const records = await event.registration.matchAll();
      for (const record of records) {
        await cache.put(record.request, await record.responseReady);
      }
      event.updateUI({ title: 'Episode 42 ready!' });
    })()
  );
});

self.addEventListener('backgroundfetchfail', (event) => {
  console.error('Background fetch failed:', event.registration.id);
});

self.addEventListener('backgroundfetchabort', (event) => {
  console.log('Background fetch aborted:', event.registration.id);
});
```

**Support:** Chromium-based browsers. Feature-detect with `'backgroundFetch' in ServiceWorkerRegistration.prototype`.

---

## Content Indexing API

Register offline-available content for OS-level discovery (e.g., Android "Offline content" in Chrome).

```js
// Add content to index
const reg = await navigator.serviceWorker.ready;
await reg.index.add({
  id: 'article-123',
  title: 'Understanding Service Workers',
  description: 'A deep dive into SW lifecycle and caching',
  url: '/articles/service-workers',
  icons: [{ src: '/icons/article.png', sizes: '192x192', type: 'image/png' }],
  category: 'article', // article | homepage | video | audio
});

// List indexed content
const entries = await reg.index.getAll();

// Remove from index
await reg.index.delete('article-123');
```

```js
// sw.js — user deletes from OS UI
self.addEventListener('contentdelete', (event) => {
  event.waitUntil(
    caches.open('articles').then((cache) => cache.delete(event.id))
  );
});
```

**Support:** Chromium-based only. Always feature-detect: `'index' in ServiceWorkerRegistration.prototype`.

---

## Web Periodic Background Sync

Periodically wake the SW to refresh content (even when app is closed).

### Registration

```js
const reg = await navigator.serviceWorker.ready;
const status = await navigator.permissions.query({ name: 'periodic-background-sync' });

if (status.state === 'granted' && 'periodicSync' in reg) {
  await reg.periodicSync.register('news-refresh', {
    minInterval: 12 * 60 * 60 * 1000, // 12 hours minimum
  });
}
```

### Handler

```js
// sw.js
self.addEventListener('periodicsync', (event) => {
  if (event.tag === 'news-refresh') {
    event.waitUntil(
      (async () => {
        const cache = await caches.open('news');
        const response = await fetch('/api/latest-news');
        await cache.put('/api/latest-news', response);
        // Notify open clients
        const channel = new BroadcastChannel('app-channel');
        channel.postMessage({ type: 'NEWS_UPDATED' });
      })()
    );
  }
});
```

### Constraints

- **Chromium-only.** Always provide manual refresh fallback.
- `minInterval` is a hint — browser decides actual frequency based on site engagement score.
- Requires the site to be installed as a PWA on desktop, or have high engagement on mobile.
- Unregister: `await reg.periodicSync.unregister('news-refresh');`
- List tags: `const tags = await reg.periodicSync.getTags();`
